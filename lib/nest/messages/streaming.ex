defmodule Nest.Messages.Streaming do
  @moduledoc """
  Accumulator for building assistant messages during streaming.

  Handles interleaved text, thinking, and tool calls as they arrive
  from the LLM API.

  Buffers are stored as IO lists (nested lists of binaries) to avoid
  the O(n²) cost of repeated string concatenation. Convert to a
  binary via `IO.iodata_to_binary/1` only at the consumer
  boundary (finalize, to_json, etc.).
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.ToolCall

  defmodule PartialToolCall do
    @moduledoc "Partial tool call during streaming"
    defstruct [:id, :name, arguments_buffer: [], complete?: false]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: String.t() | nil,
            arguments_buffer: IO.iodata(),
            complete?: boolean()
          }
  end

  defmodule AssistantAccumulator do
    @moduledoc """
    Accumulates assistant message content during streaming.

    Tracks partial state for interleaved content blocks. Buffers
    (`text_buffer`, `thinking_buffer`) are IO lists — call
    `IO.iodata_to_binary/1` to get a string.

    `text_buffer` and `thinking_buffer` are IO lists. Call
    `IO.iodata_to_binary/1` to get a string. Use `to_json/1`
    for the canonical wire-format serialization.
    """
    defstruct [
      :index,
      :thinking_signature,
      :refusal,
      :current_block,
      :timestamp,
      text_buffer: [],
      thinking_buffer: [],
      tool_calls: %{},
      chars_sent: 0,
      segments: []
    ]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            text_buffer: IO.iodata(),
            thinking_buffer: IO.iodata(),
            thinking_signature: String.t() | nil,
            tool_calls: %{String.t() => PartialToolCall.t()},
            refusal: String.t() | nil,
            current_block: :text | :thinking | {:tool_use, String.t()} | nil,
            timestamp: DateTime.t() | nil,
            chars_sent: non_neg_integer(),
            segments: [%{type: atom(), content: IO.iodata()}]
          }
  end

  @doc """
  Initialize a new accumulator for the given message index.
  """
  @spec new(non_neg_integer()) :: AssistantAccumulator.t()
  def new(index) do
    %AssistantAccumulator{
      index: index,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Append text to the text buffer with segment tracking. O(1) —
  the buffer is an IO list, not a string.
  """
  @spec append_text(AssistantAccumulator.t(), String.t()) :: AssistantAccumulator.t()
  def append_text(%AssistantAccumulator{} = acc, text) when is_binary(text) do
    {segments, _last} = update_segments(acc.segments, :text, text, acc.current_block)

    %AssistantAccumulator{
      acc
      | text_buffer: [text | acc.text_buffer],
        current_block: :text,
        chars_sent: acc.chars_sent + String.length(text),
        segments: segments
    }
  end

  @doc """
  Append thinking text to the thinking buffer with segment
  tracking. O(1) — the buffer is an IO list, not a string.

  `chars_sent` is also incremented (so `chars_sent` tracks the
  total characters streamed, text + thinking combined) so the
  delta broadcast can compute `chars_start` in O(1).
  """
  @spec append_thinking(AssistantAccumulator.t(), String.t(), String.t() | nil) ::
          AssistantAccumulator.t()
  def append_thinking(%AssistantAccumulator{} = acc, text, signature \\ nil)
      when is_binary(text) do
    {segments, _last} = update_segments(acc.segments, :thinking, text, acc.current_block)

    %AssistantAccumulator{
      acc
      | thinking_buffer: [text | acc.thinking_buffer],
        thinking_signature: signature || acc.thinking_signature,
        current_block: :thinking,
        chars_sent: acc.chars_sent + String.length(text),
        segments: segments
    }
  end

  @doc """
  Start a new tool call with the given id and name.
  """
  @spec start_tool_call(AssistantAccumulator.t(), String.t(), String.t()) ::
          AssistantAccumulator.t()
  def start_tool_call(%AssistantAccumulator{} = acc, id, name)
      when is_binary(id) and is_binary(name) do
    partial = %PartialToolCall{
      id: id,
      name: name,
      arguments_buffer: [],
      complete?: false
    }

    %AssistantAccumulator{
      acc
      | tool_calls: Map.put(acc.tool_calls, id, partial),
        current_block: {:tool_use, id}
    }
  end

  @doc """
  Append argument JSON fragment to a tool call. O(1) — the
  buffer is an IO list, not a string.
  """
  @spec append_tool_call_args(AssistantAccumulator.t(), String.t(), String.t()) ::
          AssistantAccumulator.t()
  def append_tool_call_args(%AssistantAccumulator{} = acc, id, fragment)
      when is_binary(id) and is_binary(fragment) do
    tool_calls =
      Map.update!(acc.tool_calls, id, fn %PartialToolCall{} = partial ->
        %PartialToolCall{partial | arguments_buffer: [fragment | partial.arguments_buffer]}
      end)

    %AssistantAccumulator{acc | tool_calls: tool_calls}
  end

  @doc """
  Mark a tool call as complete.
  """
  @spec complete_tool_call(AssistantAccumulator.t(), String.t()) :: AssistantAccumulator.t()
  def complete_tool_call(%AssistantAccumulator{} = acc, id) when is_binary(id) do
    tool_calls =
      Map.update!(acc.tool_calls, id, fn %PartialToolCall{} = partial ->
        %PartialToolCall{partial | complete?: true}
      end)

    %AssistantAccumulator{acc | tool_calls: tool_calls}
  end

  @doc """
  Finalize the accumulator into a complete Assistant message.
  Converts the IO-list buffers to binaries.
  """
  @spec finalize(AssistantAccumulator.t()) :: Assistant.t()
  def finalize(%AssistantAccumulator{} = acc) do
    tool_calls =
      acc.tool_calls
      |> Map.values()
      |> Enum.filter(& &1.complete?)
      |> Enum.map(fn partial ->
        %ToolCall{
          id: partial.id,
          name: partial.name,
          arguments: parse_arguments(partial.arguments_buffer)
        }
      end)

    %Assistant{
      index: acc.index,
      content: text_to_string_or_nil(acc.text_buffer),
      thinking: text_to_string_or_nil(acc.thinking_buffer),
      tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
      refusal: acc.refusal,
      timestamp: acc.timestamp
    }
  end

  @doc """
  Convert accumulator to JSON-compatible map for wire format.
  Converts the IO-list buffers to strings.
  """
  @spec to_json(AssistantAccumulator.t()) :: map()
  def to_json(%AssistantAccumulator{} = acc) do
    %{
      "index" => acc.index,
      "role" => "assistant",
      "content" => IO.iodata_to_binary(acc.text_buffer),
      "charsEnd" => acc.chars_sent,
      "timestamp" => acc.timestamp,
      # Segments are stored in reverse order (most recent first)
      # for O(1) prepending. Reverse here for the wire format.
      "segments" =>
        acc.segments
        |> Enum.reverse()
        |> Enum.map(fn seg ->
          %{"type" => seg.type, "content" => IO.iodata_to_binary(seg.content)}
        end),
      "currentType" => acc.current_block
    }
  end

  # Update segments in O(1). Segments are stored in REVERSE
  # chronological order (most recent first) so the head is
  # always the current segment — prepending to the head is O(1).
  # Callers reverse the list at serialization time.
  # Returns `{reversed_segments, current_segment}`.
  defp update_segments([], type, content, _current_block) do
    new_segment = %{type: type, content: [content]}
    {[new_segment], new_segment}
  end

  defp update_segments([current | rest], _type, content, current_block)
       when current.type == current_block do
    new_current = %{current | content: [content | current.content]}
    {[new_current | rest], new_current}
  end

  defp update_segments(segments, type, content, _current_block) do
    new_segment = %{type: type, content: [content]}
    {[new_segment | segments], new_segment}
  end

  # Empty IO list → nil; non-empty → binary. The list is in
  # reverse insertion order (we prepend for O(1) appends), so
  # reverse before flattening. Used by `finalize/1` to match
  # the `Assistant` struct's `content | nil` shape.
  defp text_to_string_or_nil([]), do: nil

  defp text_to_string_or_nil(buffer) do
    buffer |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp parse_arguments(buffer) do
    buffer |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode() |> handle_decode_result()
  end

  defp handle_decode_result({:ok, decoded}) when is_map(decoded), do: decoded
  defp handle_decode_result({:ok, _}), do: %{}
  defp handle_decode_result({:error, _}), do: %{}
end
