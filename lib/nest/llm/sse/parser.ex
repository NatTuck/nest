defmodule Nest.LLM.SSE.Parser do
  @moduledoc """
  Line-buffered SSE parser for the LLM streaming wire format.

  Handles both OpenAI's anonymous `data:`-only events and
  Anthropic's named `event:` + `data:` events. Buffers raw bytes
  across chunk boundaries, splits on `\n` (CR/LF tolerant), and
  yields parsed frames when a blank line terminates one.

  Per the SSE spec, a single event may carry multiple `data:`
  lines (joined with `\n`). Both OpenAI and Anthropic only emit
  one per event in practice, but this parser follows the spec.
  """

  @type frame :: {:event, event_name :: String.t() | nil, data :: String.t()}
  @type t :: %__MODULE__{
          buffer: String.t(),
          event_name: String.t() | nil,
          data_lines: [String.t()]
        }

  defstruct buffer: "", event_name: nil, data_lines: []

  @doc """
  Initialize a fresh parser.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a chunk of raw bytes to the parser.

  Returns `{frames, parser}` where `frames` is a list of complete
  frames parsed from this chunk (in order) and `parser` is the
  updated state with any trailing partial line still buffered.
  """
  @spec feed(t(), String.t()) :: {[frame()], t()}
  def feed(%__MODULE__{} = parser, chunk) when is_binary(chunk) do
    buffer = parser.buffer <> chunk
    {lines, rest} = split_on_newlines(buffer)
    {frames, parser} = process_lines(lines, %{parser | buffer: ""})
    {frames, %{parser | buffer: rest}}
  end

  @doc """
  Flush any pending partial frame at end of stream.

  Emits the current frame even if a trailing blank line was not
  received (defensive against providers that close the connection
  without a final blank line).
  """
  @spec flush(t()) :: {[frame()], t()}
  def flush(%__MODULE__{buffer: ""} = parser) do
    {frame, parser} = emit_pending_frame(parser)
    frames = if frame, do: [frame], else: []
    {frames, %{parser | buffer: ""}}
  end

  def flush(%__MODULE__{} = parser) do
    {frame_from_buffer, parser} = process_buffer_as_line(parser)
    {frame_from_state, parser} = emit_pending_frame(parser)
    frames = [frame_from_buffer, frame_from_state] |> Enum.reject(&is_nil/1)
    {frames, %{parser | buffer: ""}}
  end

  defp process_buffer_as_line(%__MODULE__{buffer: ""} = parser) do
    {nil, parser}
  end

  defp process_buffer_as_line(%__MODULE__{} = parser) do
    {frames, parser} = process_lines([parser.buffer], %{parser | buffer: ""})

    case frames do
      [frame] -> {frame, parser}
      _ -> {nil, parser}
    end
  end

  defp split_on_newlines(buffer) do
    case :binary.matches(buffer, "\n") do
      [] ->
        {[], buffer}

      positions ->
        {last_pos, _} = List.last(positions)
        complete_len = last_pos + 1
        rest_start = complete_len
        rest_len = byte_size(buffer) - rest_start

        complete = :binary.part(buffer, 0, complete_len)

        rest =
          if rest_len == 0,
            do: "",
            else: :binary.part(buffer, rest_start, rest_len)

        {String.split(complete, "\n"), rest}
    end
  end

  defp process_lines([], parser), do: {[], parser}

  defp process_lines([line | rest], parser) do
    line = strip_cr(line)
    {frame, parser} = apply_line(line, parser)
    {more_frames, parser} = process_lines(rest, parser)
    frames = prepend_if_some(frame, more_frames)
    {frames, parser}
  end

  defp apply_line("", parser) do
    {frame, parser} = emit_pending_frame(parser)
    {frame, reset_frame_state(parser)}
  end

  defp apply_line(":" <> _comment, parser), do: {nil, parser}

  defp apply_line("event:" <> rest, parser) do
    name = rest |> String.trim() |> nil_if_empty()
    {nil, %{parser | event_name: name}}
  end

  defp apply_line("data:" <> rest, parser) do
    data = rest |> String.trim_leading(" ")
    {nil, %{parser | data_lines: [data | parser.data_lines]}}
  end

  defp apply_line(_other, parser), do: {nil, parser}

  defp emit_pending_frame(%__MODULE__{data_lines: []} = parser) do
    {nil, %{parser | event_name: nil}}
  end

  defp emit_pending_frame(%__MODULE__{} = parser) do
    data = parser.data_lines |> Enum.reverse() |> Enum.join("\n")
    frame = {:event, parser.event_name, data}
    {frame, %__MODULE__{buffer: parser.buffer, event_name: nil, data_lines: []}}
  end

  defp reset_frame_state(parser) do
    %{parser | event_name: nil, data_lines: []}
  end

  defp prepend_if_some(nil, list), do: list
  defp prepend_if_some(frame, list), do: [frame | list]

  defp strip_cr(line) do
    case line do
      <<>> ->
        <<>>

      _ ->
        size = byte_size(line)

        if :binary.last(line) == ?\r do
          :binary.part(line, 0, size - 1)
        else
          line
        end
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
end
