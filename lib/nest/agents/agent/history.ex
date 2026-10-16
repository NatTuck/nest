defmodule Nest.Agents.Agent.History do
  @moduledoc """
  Executor for the `agents-history` tool (issue #22).

  Runs in the turn's tool worker (never the calling agent's GenServer), so it is
  callable mid-turn. It reads the target's *persisted* message sequence through
  `Nest.Persistence.Messages` — the same query path `Nest.Persistence.History`
  and the channel's `chat:history` page use — so the read is a plain DB query
  that cannot touch the target's live turn, and it works whether or not the
  target has a process.

  Two modes, one per concept:

    * a **range read** (`start_index` + `length`), where a negative
      `start_index` is resolved *once* against the end of the history (`-1` is
      the last message) and the window then runs forward from there;
    * a **search** (`search`), which scans the whole history for a
      case-insensitive literal substring and returns a JSON object whose
      `matches` list carries one entry per matching message.

  Out-of-range and malformed arguments are error results naming the valid
  range, never a silent truncation and never an empty answer. The target
  resolution (and its space scoping) lives in
  `Nest.Agents.Agent.History.Target`.

  ## The index space

  An index is the message's own `index` in the agent's logical sequence, which
  is contiguous from 0: the initial system message is 0, and the row's
  `next_message_index` is the count of messages, so it is also the index the
  next append will take. That count is what a negative `start_index` is
  resolved against, and the reader verifies the window it asked for came back
  contiguous — a sequence with a gap is reported rather than quietly returning
  fewer messages than were asked for.

  ## What a message reads as

  A message renders as its role and its parts: text, `[thinking]` blocks,
  `[tool_use …]` calls, `[tool_result …]` bodies, refusals, and a
  `[media …]` marker in place of an attachment's bytes. Nothing is dropped:
  a read that silently omitted a part would describe a different conversation
  than the one in the row. Search matches the same text, so a hit is always
  something the range read would also show.
  """

  alias Nest.Agents.Agent.History.Target
  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Persistence.Messages

  # How much of a matching message's text the search snippet carries, in
  # graphemes, and how much of that is context before the match.
  @snippet_chars 200
  @snippet_lead 60

  @doc """
  Run one `agents-history` call. Returns `{:ok, content}` — a rendered range,
  or the search's JSON object — or `{:error, content}` for a malformed request,
  an unreachable target, or an out-of-range window.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, %ToolCall{} = tc) do
    args = arguments(tc)

    with {:ok, name, row} <- Target.resolve(ctx, tc) do
      case search_query(args) do
        :none -> range(ctx.space_id, name, row, args)
        {:ok, query} -> search(ctx.space_id, name, query)
        {:error, _reason} = error -> error
      end
    end
  end

  # ---- range mode ----

  defp range(space_id, name, %PersistedAgent{next_message_index: count}, args) do
    with {:ok, start_index} <- integer_arg(args, "start_index", -1),
         {:ok, length} <- length_arg(args),
         {:ok, from, to} <- window(name, count, start_index, length),
         {:ok, rows} <- load_window(space_id, name, from, to) do
      {:ok, render_range(name, count, from, to, rows)}
    end
  end

  # Resolve the Python-style index once, then validate the forward window.
  # `count` is the number of messages, so the valid index set is
  # `-count..count-1`: a negative index is an offset from the end and a
  # non-negative one an offset from the start.
  defp window(name, count, start_index, length) do
    from = if start_index < 0, do: count + start_index, else: start_index

    cond do
      count <= 0 ->
        {:error, "Agent #{name} has no messages."}

      from < 0 or from >= count ->
        {:error,
         "start_index #{start_index} is out of range: agent #{name} has #{count} " <>
           "messages, so valid indices are -#{count}..#{count - 1}."}

      from + length > count ->
        {:error,
         "start_index #{start_index} with length #{length} runs past the end: agent " <>
           "#{name} has #{count} messages (indices 0..#{count - 1}), so at most " <>
           "#{count - from} can be read from index #{from}."}

      true ->
        {:ok, from, from + length - 1}
    end
  end

  # One query for the window: `load_slice/3` returns the most recent rows with
  # `message_index <= cap`, so `cap: to, limit: to - from + 1` is exactly
  # `from..to` — the history around the window is never loaded.
  defp load_window(space_id, name, from, to) do
    expected = to - from + 1
    rows = Messages.load_slice(space_id, name, cap: to, limit: expected)

    if length(rows) == expected and index_of(hd(rows)) == from and
         index_of(List.last(rows)) == to do
      {:ok, rows}
    else
      {:error,
       "Agent #{name}'s message sequence has a gap: not every index in #{from}..#{to} " <>
         "is present, so this range cannot be read as one window."}
    end
  end

  defp render_range(name, count, from, to, rows) do
    "History of agent \"#{name}\": #{count} message(s), indices 0..#{count - 1}. " <>
      "Showing #{from}..#{to} (#{to - from + 1}).\n\n" <>
      Enum.map_join(rows, "\n\n", &render_row/1)
  end

  defp render_row({_role, %{index: index}} = message) do
    "[#{index}] #{role_of(message)}:\n#{text_of(message)}"
  end

  # ---- search mode ----

  # The search reads the agent's full logical sequence: matching is over each
  # message's text, which is only known once the rows are loaded. That is the
  # same read an agent's own load path performs
  # (`Persistence.build_attrs_for_start/2`), so it is not a new query path.
  defp search(space_id, name, query) do
    regex = Regex.compile!(Regex.escape(query), "iu")
    rows = Messages.load_full_messages(space_id, name)
    matches = Enum.flat_map(rows, &match(&1, regex))

    {:ok, Jason.encode!(%{"agent" => name, "query" => query, "matches" => matches})}
  end

  # One match per message: its index, its role, and a snippet around the first
  # occurrence in it. `text_truncated` says the message's text is longer than
  # the snippet, so the model knows to read the whole message at that index.
  defp match(message, regex) do
    text = text_of(message)

    case Regex.run(regex, text, return: :index) do
      [{offset, _length}] ->
        {snippet, truncated?} = snippet(text, offset)

        [
          %{
            "index" => index_of(message),
            "role" => role_of(message),
            "text" => snippet,
            "text_truncated" => truncated?
          }
        ]

      nil ->
        []
    end
  end

  # The snippet is grapheme-aligned: `offset` is a byte offset on a codepoint
  # boundary (the regex engine reports one), converted to a grapheme count
  # before slicing so a multi-byte character is never split.
  defp snippet(text, offset) do
    total = String.length(text)
    at = String.length(binary_part(text, 0, offset))
    from = max(at - @snippet_lead, 0)
    to = min(from + @snippet_chars, total)

    body = String.slice(text, from, to - from)
    body = if from > 0, do: "…" <> body, else: body
    body = if to < total, do: body <> "…", else: body

    {body, from > 0 or to < total}
  end

  # ---- arguments ----

  defp arguments(%ToolCall{arguments: args}) when is_map(args), do: args
  defp arguments(_tc), do: %{}

  # `search` selects the search mode. Range arguments are only meaningful
  # without it, and silently ignoring one of the two modes would answer a
  # question the model did not ask.
  defp search_query(args) do
    case Map.fetch(args, "search") do
      :error ->
        :none

      {:ok, query} when is_binary(query) and query != "" ->
        if Map.has_key?(args, "start_index") or Map.has_key?(args, "length") do
          {:error, "Pass either `search` or `start_index`/`length`, not both."}
        else
          {:ok, query}
        end

      {:ok, other} ->
        {:error,
         "Invalid `search` argument: expected a non-empty string, got: #{inspect(other)}."}
    end
  end

  defp integer_arg(args, key, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      n when is_integer(n) -> {:ok, n}
      other -> {:error, "Invalid `#{key}` argument: expected an integer, got: #{inspect(other)}."}
    end
  end

  defp length_arg(args) do
    case Map.get(args, "length") do
      nil ->
        {:ok, 1}

      n when is_integer(n) and n > 0 ->
        {:ok, n}

      other ->
        {:error,
         "Invalid `length` argument: expected a positive integer, got: #{inspect(other)}."}
    end
  end

  # ---- rendering ----

  defp index_of({_role, %{index: index}}), do: index

  defp role_of({:compaction, _marker}), do: "compaction"
  defp role_of({role, _message}), do: to_string(role)

  defp text_of({:compaction, %Compaction{archived_count: count}}),
    do: "[compaction marker: #{count} message(s) archived]"

  defp text_of({_role, %{parts: parts}}) when is_list(parts) do
    parts
    |> Enum.map(&part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text_of(_message), do: "[no readable parts]"

  defp part_text(%Part.Text{text: text}), do: text || ""

  defp part_text(%Part.Thinking{thinking: thinking}), do: "[thinking]\n" <> (thinking || "")

  defp part_text(%Part.ToolUse{name: name, arguments: arguments}),
    do: "[tool_use #{name}] #{encode(arguments)}"

  defp part_text(%Part.ToolResult{name: name, content: content, is_error: is_error}),
    do: "[tool_result #{name}#{error_tag(is_error)}]\n" <> (content || "")

  defp part_text(%Part.Refusal{refusal: refusal}), do: "[refusal] " <> (refusal || "")

  defp part_text(%Part.Media{media_type: type, bytes: bytes}),
    do: "[media #{type}, #{bytes} bytes]"

  defp part_text(other), do: "[unknown part: #{inspect(other)}]"

  defp error_tag(true), do: " (error)"
  defp error_tag(_is_error), do: ""

  defp encode(arguments) do
    case Jason.encode(arguments) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(arguments)
    end
  end
end
