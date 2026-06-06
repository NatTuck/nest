defmodule Nest.Messages.Streaming do
  @moduledoc """
  Accumulator for building assistant messages during streaming.

  Handles interleaved text, thinking, and tool calls as they arrive
  from the LLM API.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.ToolCall

  defmodule PartialToolCall do
    @moduledoc "Partial tool call during streaming"
    defstruct [:id, :name, :arguments_buffer, :complete?]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: String.t() | nil,
            arguments_buffer: String.t(),
            complete?: boolean()
          }
  end

  defmodule AssistantAccumulator do
    @moduledoc """
    Accumulates assistant message content during streaming.

    Tracks partial state for interleaved content blocks.
    """
    defstruct [
      :index,
      text_buffer: "",
      thinking_buffer: "",
      thinking_signature: nil,
      tool_calls: %{},
      refusal: nil,
      current_block: nil,
      timestamp: nil,
      # Streaming tracking fields
      chars_sent: 0,
      segments: []
    ]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            text_buffer: String.t(),
            thinking_buffer: String.t(),
            thinking_signature: String.t() | nil,
            tool_calls: %{String.t() => PartialToolCall.t()},
            refusal: String.t() | nil,
            current_block: :text | :thinking | {:tool_use, String.t()} | nil,
            timestamp: DateTime.t() | nil,
            chars_sent: non_neg_integer(),
            segments: [%{type: atom(), content: String.t()}]
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
  Append text to the text buffer with segment tracking.
  """
  @spec append_text(AssistantAccumulator.t(), String.t()) :: AssistantAccumulator.t()
  def append_text(%AssistantAccumulator{} = acc, text) when is_binary(text) do
    new_text_buffer = acc.text_buffer <> text
    new_chars_sent = String.length(new_text_buffer)

    # Update segments - continue existing text segment or start new one
    segments = update_segments(acc.segments, :text, text, acc.current_block)

    %AssistantAccumulator{
      acc
      | text_buffer: new_text_buffer,
        current_block: :text,
        chars_sent: new_chars_sent,
        segments: segments
    }
  end

  @doc """
  Append thinking text to the thinking buffer with segment tracking.
  """
  @spec append_thinking(AssistantAccumulator.t(), String.t(), String.t() | nil) ::
          AssistantAccumulator.t()
  def append_thinking(%AssistantAccumulator{} = acc, text, signature \\ nil)
      when is_binary(text) do
    new_thinking_buffer = acc.thinking_buffer <> text

    # Update segments - continue existing thinking segment or start new one
    segments = update_segments(acc.segments, :thinking, text, acc.current_block)

    %AssistantAccumulator{
      acc
      | thinking_buffer: new_thinking_buffer,
        thinking_signature: signature || acc.thinking_signature,
        current_block: :thinking,
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
      arguments_buffer: "",
      complete?: false
    }

    %AssistantAccumulator{
      acc
      | tool_calls: Map.put(acc.tool_calls, id, partial),
        current_block: {:tool_use, id}
    }
  end

  @doc """
  Append argument JSON fragment to a tool call.
  """
  @spec append_tool_call_args(AssistantAccumulator.t(), String.t(), String.t()) ::
          AssistantAccumulator.t()
  def append_tool_call_args(%AssistantAccumulator{} = acc, id, fragment)
      when is_binary(id) and is_binary(fragment) do
    tool_calls =
      Map.update!(acc.tool_calls, id, fn %PartialToolCall{} = partial ->
        %PartialToolCall{
          partial
          | arguments_buffer: partial.arguments_buffer <> fragment
        }
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
      content: if(acc.text_buffer == "", do: nil, else: acc.text_buffer),
      thinking: if(acc.thinking_buffer == "", do: nil, else: acc.thinking_buffer),
      tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
      refusal: acc.refusal,
      timestamp: acc.timestamp
    }
  end

  @doc """
  Convert accumulator to JSON-compatible map for wire format.
  """
  @spec to_json(AssistantAccumulator.t()) :: map()
  def to_json(%AssistantAccumulator{} = acc) do
    %{
      "index" => acc.index,
      "role" => "assistant",
      "content" => acc.text_buffer,
      "charsEnd" => acc.chars_sent,
      "timestamp" => acc.timestamp,
      "segments" =>
        Enum.map(acc.segments, fn seg -> %{"type" => seg.type, "content" => seg.content} end),
      "currentType" => acc.current_block
    }
  end

  # Update segments list - continue existing segment or start new one
  defp update_segments(segments, type, content, current_block) do
    if current_block == type and segments != [] do
      # Continue existing segment
      last_index = length(segments) - 1
      last_segment = Enum.at(segments, last_index)

      List.replace_at(segments, last_index, %{
        last_segment
        | content: last_segment.content <> content
      })
    else
      # Start new segment
      segments ++ [%{type: type, content: content}]
    end
  end

  defp parse_arguments(buffer) do
    case Jason.decode(buffer) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, _} -> %{}
      {:error, _} -> %{}
    end
  end
end
