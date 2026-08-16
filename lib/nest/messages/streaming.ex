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

  require Logger

  alias Nest.Messages.Assistant

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
  Start a new tool call with the given id and name. Also
  prepends a `%{type: {:tool_use, id}}` marker segment so the
  `init` partial payload and the finalized parts list both
  preserve the tool call's position relative to surrounding
  text/thinking.
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
        segments: [%{type: {:tool_use, id}} | acc.segments],
        current_block: {:tool_use, id}
    }
  end

  # Defensive fallthrough: a malformed event with a non-binary
  # id or name (e.g. `id: :by_index` leaking through from a
  # provider that didn't resolve the index) would otherwise
  # raise `FunctionClauseError` and crash the Agent. Skip the
  # event with a warning instead — we don't invent ids, so
  # any later `append_tool_call_args/3` for the same call
  # also won't find a matching entry and will itself skip.
  def start_tool_call(%AssistantAccumulator{} = acc, id, name) do
    Logger.warning(
      "Streaming.start_tool_call: skipping event with non-binary " <>
        "id=#{inspect(id)} or name=#{inspect(name)}"
    )

    acc
  end

  @doc """
  Append argument JSON fragment to a tool call. O(1) — the
  buffer is an IO list, not a string.
  """
  @spec append_tool_call_args(AssistantAccumulator.t(), String.t(), String.t()) ::
          AssistantAccumulator.t()
  def append_tool_call_args(%AssistantAccumulator{} = acc, id, fragment)
      when is_binary(id) and is_binary(fragment) do
    case Map.fetch(acc.tool_calls, id) do
      {:ok, %PartialToolCall{} = partial} ->
        new_partial = %PartialToolCall{
          partial
          | arguments_buffer: [fragment | partial.arguments_buffer]
        }

        %AssistantAccumulator{
          acc
          | tool_calls: Map.put(acc.tool_calls, id, new_partial)
        }

      :error ->
        Logger.warning(
          "Streaming.append_tool_call_args: skipping fragment for " <>
            "unknown tool_call_id=#{inspect(id)} (no matching start)"
        )

        acc
    end
  end

  # Defensive fallthrough for non-binary id/fragment — the
  # caller passed something we can't append to a tool call.
  # Skip rather than crash the Agent.
  def append_tool_call_args(%AssistantAccumulator{} = acc, id, fragment) do
    Logger.warning(
      "Streaming.append_tool_call_args: skipping event with non-binary " <>
        "id=#{inspect(id)} or fragment=#{inspect(fragment)}"
    )

    acc
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
  Converts the IO-list buffers to binaries and assembles the
  parts list in the order the events arrived.
  """
  @spec finalize(AssistantAccumulator.t()) :: Assistant.t()
  def finalize(%AssistantAccumulator{} = acc) do
    parts = build_parts(acc)

    %Assistant{
      index: acc.index,
      parts: parts,
      timestamp: acc.timestamp
    }
  end

  # Walk the segments (which include both text/thinking blocks
  # AND tool-use markers; segments are stored in reverse) and
  # emit a Part in the order the events arrived. When a segment
  # is a `{:tool_use, id}` marker, we splice in the matching
  # `ToolUse` part (built from the completed tool_calls map) at
  # that position. Tool calls are de-duplicated by id.
  defp build_parts(acc) do
    tool_call_by_id =
      acc.tool_calls
      |> Map.values()
      |> Enum.filter(& &1.complete?)
      |> Map.new(fn partial ->
        {partial.id,
         %Nest.Messages.Part.ToolUse{
           id: partial.id,
           name: partial.name,
           arguments: parse_arguments(partial.arguments_buffer)
         }}
      end)

    # Segments are stored in reverse chronological order
    # (prepend is O(1) on the agent's hot path). We walk them
    # in reverse to get chronological order, and prepend each
    # new part to the accumulator so the final list is also
    # in chronological order — no final reverse needed.
    {parts, _emitted} =
      acc.segments
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn seg, {acc_parts, emitted} ->
        parts_for_segment(seg, acc.thinking_signature, tool_call_by_id, emitted, acc_parts)
      end)

    Enum.reject(parts, &empty_part?/1)
  end

  # Each segment in `acc.segments` is either a `:text` /
  # `:thinking` block (with its IO-list content) or a
  # `{:tool_use, id}` marker (no content — the args went
  # straight into the tool_calls map). For text/thinking,
  # emit a Part with the flattened binary content. For
  # tool-use markers, splice in the matching `Part.ToolUse`
  # (built from the completed tool_calls map) and skip
  # any subsequent segments for the same id.
  defp parts_for_segment(
         %{type: :text, content: content},
         _signature,
         _tc_by_id,
         _emitted,
         acc_parts
       ) do
    # Segment content is stored in reverse order (each fragment is
    # prepended for O(1)); reverse here so the text reads in arrival
    # order. Without this the finalized message is word-reversed.
    text = content |> Enum.reverse() |> IO.iodata_to_binary()
    {[%Nest.Messages.Part.Text{text: text} | acc_parts], MapSet.new()}
  end

  defp parts_for_segment(
         %{type: :thinking, content: content},
         signature,
         _tc_by_id,
         _emitted,
         acc_parts
       ) do
    # See the `:text` clause: segment content is prepended, so reverse
    # it to keep thinking in arrival order.
    text = content |> Enum.reverse() |> IO.iodata_to_binary()
    part = %Nest.Messages.Part.Thinking{thinking: text, signature: signature}
    {[part | acc_parts], MapSet.new()}
  end

  defp parts_for_segment(
         %{type: {:tool_use, id}},
         _signature,
         tc_by_id,
         emitted,
         acc_parts
       ) do
    if MapSet.member?(emitted, id) do
      {acc_parts, emitted}
    else
      case Map.get(tc_by_id, id) do
        nil ->
          {acc_parts, emitted}

        part ->
          {[part | acc_parts], MapSet.put(emitted, id)}
      end
    end
  end

  defp parts_for_segment(_other, _sig, _tc, _emitted, acc_parts), do: {acc_parts, MapSet.new()}

  defp empty_part?(%Nest.Messages.Part.Text{text: text}), do: text in [nil, ""]
  defp empty_part?(%Nest.Messages.Part.Thinking{thinking: text}), do: text in [nil, ""]
  defp empty_part?(_), do: false

  @doc """
  Convert accumulator to JSON-compatible map for wire format.
  Converts the IO-list buffers to strings.
  """
  @spec to_json(AssistantAccumulator.t()) :: map()
  def to_json(%AssistantAccumulator{} = acc) do
    %{
      "index" => acc.index,
      "role" => "assistant",
      # `text_buffer` is stored in reverse order (each fragment is
      # prepended for O(1)); reverse here so the wire content reads in
      # arrival order rather than word-reversed.
      "content" => acc.text_buffer |> Enum.reverse() |> IO.iodata_to_binary(),
      "charsEnd" => acc.chars_sent,
      "timestamp" => acc.timestamp,
      # Segments are stored in reverse order (most recent first)
      # for O(1) prepending. Reverse here for the wire format.
      # Tool-use markers (`%{type: {:tool_use, id}}`) carry no
      # content of their own — the partial JSON lives in the
      # `toolCalls` map keyed by id — so we serialize them as
      # `{"type": "tool_use", "id": id}` for the JS to splice
      # into its `parts` list.
      "segments" =>
        acc.segments
        |> Enum.reverse()
        |> Enum.map(fn
          %{type: {:tool_use, id}} ->
            %{"type" => "tool_use", "id" => id}

          %{type: type, content: content} ->
            # Each segment's content is also prepend-ordered (see
            # `update_segments/4`); reverse it before flattening.
            %{"type" => type, "content" => content |> Enum.reverse() |> IO.iodata_to_binary()}
        end),
      # In-flight tool calls with their partial JSON argument
      # buffers as strings. Used by the JS store's
      # `normalizePartial` to rebuild `parts` entries so a
      # client joining mid-stream sees an in-progress tool
      # call alongside any text/thinking. The JS detects the
      # "still streaming" state by checking whether the
      # argument is a string (vs. a parsed map in the
      # finalized `chat:message` payload).
      "toolCalls" =>
        acc.tool_calls
        |> Enum.map(fn {_id, partial} ->
          %{
            "id" => partial.id,
            "name" => partial.name,
            # `arguments_buffer` is stored in reverse order (each
            # fragment is prepended for O(1)); reverse here so the wire
            # arguments are in arrival order, matching `parse_arguments/1`.
            "arguments" => partial.arguments_buffer |> Enum.reverse() |> IO.iodata_to_binary()
          }
        end),
      "currentType" => acc.current_block
    }
  end

  @doc """
  Nil-safe wrapper around `to_json/1` for embedding an accumulator
  in a wire payload (e.g. `state.public_info.partial`,
  `init_payload.partial`). Returns `nil` for nil input so callers
  don't have to pattern-match.
  """
  @spec to_json_safe(AssistantAccumulator.t() | nil) :: map() | nil
  def to_json_safe(nil), do: nil
  def to_json_safe(%AssistantAccumulator{} = acc), do: to_json(acc)

  # Update segments in O(1). Segments are stored in REVERSE
  # chronological order (most recent first) so the head is
  # always the current segment — prepending to the head is O(1).
  # Callers reverse the list at serialization time.
  # Returns `{reversed_segments, current_segment}`.
  #
  # Segments are one of:
  #   - `%{type: :text | :thinking, content: IO.iodata()}` — for
  #     streamed text/thinking blocks.
  #   - `%{type: {:tool_use, id}}` — a marker for an in-flight
  #     tool call. The actual partial-JSON arguments live in
  #     `tool_calls` keyed by id, not in the segment.
  #
  # The "merge into current" clause below uses `is_tuple/1` on
  # `current.type` to skip tool-use markers: a marker has no
  # `:content` key, so we can't splice into it. Markers always
  # open a fresh segment via the catch-all clause.
  defp update_segments([], type, content, _current_block) do
    new_segment = %{type: type, content: [content]}
    {[new_segment], new_segment}
  end

  defp update_segments([current | rest], _type, content, current_block)
       when current.type == current_block and not is_tuple(current.type) do
    new_current = %{current | content: [content | current.content]}
    {[new_current | rest], new_current}
  end

  defp update_segments(segments, type, content, _current_block) do
    new_segment = %{type: type, content: [content]}
    {[new_segment | segments], new_segment}
  end

  defp parse_arguments(buffer) do
    buffer |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode() |> handle_decode_result()
  end

  defp handle_decode_result({:ok, decoded}) when is_map(decoded), do: decoded
  defp handle_decode_result({:ok, _}), do: %{}
  defp handle_decode_result({:error, _}), do: %{}
end
