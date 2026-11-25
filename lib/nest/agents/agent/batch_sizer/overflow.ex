defmodule Nest.Agents.Agent.BatchSizer.Overflow do
  @moduledoc """
  Shared "write an oversized result to the agent's scratch dir" helpers.

  `write/4` saves the full bytes and is what `BatchSizer` and `Inbox` use to
  offload; `substitute/5` turns an oversized result into a pointer plus a short
  preview and is the single substitution path used by `BatchSizer` (regular
  tools), `BatchPlan` (the `agents-batch` aggregate) and `SubAgentResults` (the
  sub-agent tools' results).

  The scratch dir comes from `ctx.mounts` — the agent's own sub-directory of
  the space scratch dir (which the sandbox binds read-write at `/tmp`, so the
  agent sees it at `/tmp/<agent-name>`). What `write/4` returns is the
  `/tmp/<agent-name>/...` path the agent uses; the directory the bytes land
  in never reaches the LLM.

  Writing is `Nest.Sandbox.scratch_write/3`'s, not this module's: under a
  backend whose scratch directory is a host directory the bytes are written
  directly (which is what keeps an offload off the sandbox's hot path), and
  under `"docker"` the scratch is the container's own `/tmp`, which only the
  container can write, so they go through the gatekeeper instead.
  """

  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.Estimator

  # UTF-8 encoding of U+FFFD (REPLACEMENT CHARACTER), used by
  # `to_valid_utf8/1` for byte sequences that don't decode.
  @replacement_char <<0xEF, 0xBF, 0xBD>>

  @doc """
  Write `content` to a scratch file under the agent's scratch dir and return
  the `/tmp/<agent-name>/...` path, or `nil` when there is no scratch dir or
  the write fails. `prefix` distinguishes the artifact type in the filename
  (e.g. `"exec"` for shell output, `"agents-batch"` for a batch
  aggregate).

  `id` names the file (`"<prefix>-<id>.<ext>"`); when it is `nil` a
  random token is used. The inbox passes its entry id so an offloaded
  delivery is named after the note it carries (issue #62), which keeps
  the pointer's path traceable to the entry it came from.
  """
  @spec write(binary(), map(), String.t(), String.t(), String.t() | nil) :: String.t() | nil
  def write(content, ctx, prefix, ext, id \\ nil) do
    case mounts(ctx) do
      nil ->
        nil

      mounts ->
        name = "#{prefix}-#{id || token()}.#{ext}"

        try do
          Sandbox.scratch_write(mounts, name, content)
        rescue
          _ -> nil
        end
    end
  end

  defp mounts(ctx) do
    case Map.get(ctx, :mounts) do
      %Mounts{} = mounts -> mounts
      _ -> nil
    end
  end

  # The preview is a fixed-size head + tail of the content with an explicit
  # elision marker between them. Fixed rather than derived from the budget: a
  # substitute whose size depends on the window cannot be priced by the
  # preflight, and `substitute_size/0` is what the projection reserves per call.
  # The head shows what the content is, the tail shows how it ends (a command's
  # failure is usually in its last lines), and the marker says how much lies
  # between them in the file. Both halves are charged in `Estimator.estimate/1`
  # tokens — whole lines for the line path, an estimate-bounded char slice for a
  # single long line — so each half really does cost at most its budget.
  @head_tokens 120
  @tail_tokens 60

  # The elision marker is a fixed template; only the count varies. Price the
  # widest count we will ever print (10 digits covers any result that fits in
  # memory) so the marker's estimate is a constant the projection can reserve.
  @max_count_digits 10

  # Tokens for the newlines joining header/head/marker/tail and any BPE merge
  # across those seams. A fixed allowance, so the projection stays
  # budget-independent.
  @join_allowance 10

  # Memo key for `substitute_size/0`.
  @substitute_size_key {__MODULE__, :substitute_size}

  @doc """
  Write `content` to the agent's scratch dir and return the inline substitute:

      <label> (<N> tokens) saved to <path>.

      <head lines>
      … [K lines elided — read the file] …
      <tail lines>

  The pointer names the file and its size; the preview shows the head and tail
  of the content and states how many lines lie between them in the file. When
  the content fits the head + tail budgets it is shown whole with no marker,
  and a single line too long for the head budget falls back to a char head +
  char tail with a chars-elided marker. Neither repeats anything the caller
  already has: the tool's arguments are in the `tool_use` part immediately
  before this, so the label names the tool and nothing else.

  `{:ok, text}` when the file was written, `:error` when it could not be — the
  caller turns that into a clear error, because a result that is too large to
  inline and cannot be filed has to say so rather than be quietly kept or
  quietly dropped.

  `prefix` names the scratch file (see `write/4`). `content` is expected to be
  storable text — non-text results (invalid UTF-8 or NUL) are written first and
  described by the caller.
  """
  @spec substitute(binary(), map(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | :error
  def substitute(content, ctx, label, prefix, id \\ nil) do
    size = Estimator.estimate(content)

    case write(content, ctx, prefix, "txt", id) do
      nil -> :error
      path -> {:ok, pointer(label, size, path, content)}
    end
  end

  @doc """
  The size of one substitute, for the preflight's per-call projection.

  The preflight has to reserve room for the substitute a call might produce, so
  this and `substitute/5` must describe the same block — they share the header
  format, the head/tail budgets and the marker template, so they cannot drift.
  It prices the worst case: header + head budget + tail budget + the widest
  marker + the join allowance, all constants of this module's format and none
  of them the caller's budget. Every preview half is estimate-charged against
  its budget (whole lines, or an estimate-bounded char slice), so this is a
  true upper bound on any substitute, whatever the content.

  Memoized in `:persistent_term`: it is a constant of this module's own format,
  and `ResultPolicy.admit/3` reads it on every result to decide whether filing
  is even worth it. Recomputing it there would put a tokenizer call on every
  admission.
  """
  @spec substitute_size() :: pos_integer()
  def substitute_size do
    case :persistent_term.get(@substitute_size_key, nil) do
      nil ->
        widest = marker(String.duplicate("9", @max_count_digits), "chars")

        size =
          Estimator.estimate(
            pointer("Output of shell-cmd", 1_000_000, "/tmp/a/exec-0000000000000000.txt", "")
          ) +
            @head_tokens + @tail_tokens + Estimator.estimate(widest) + @join_allowance

        :persistent_term.put(@substitute_size_key, size)
        size

      size ->
        size
    end
  end

  defp pointer(label, size, path, content) do
    header = "#{label} (#{size} tokens) saved to #{path}."

    case preview(content) do
      "" -> header
      preview -> header <> "\n\n" <> preview
    end
  end

  # The preview is the head and tail of the content with an elision marker
  # between them, or the whole content when head + tail cover it. Trailing
  # whitespace is trimmed first so losing only whitespace is never labelled as
  # elision. The line path keeps whole lines (never mid-line); a first line too
  # long for the head budget falls back to the char path.
  defp preview(content) do
    trimmed = String.trim_trailing(content)
    lines = String.split(trimmed, "\n")
    {head_lines, rest} = take_head(lines, @head_tokens)

    case head_lines do
      [] -> char_preview(trimmed)
      _ -> line_preview(trimmed, head_lines, rest)
    end
  end

  defp line_preview(trimmed, head_lines, rest) do
    {tail_lines, middle} = take_tail(rest, @tail_tokens)

    case middle do
      # Head and tail cover every line: show the whole content, no marker.
      [] ->
        trimmed

      _ ->
        assemble(
          Enum.join(head_lines, "\n"),
          marker(length(middle), "lines"),
          Enum.join(tail_lines, "\n")
        )
    end
  end

  # A single line longer than the head budget (a minified blob, base64): cut by
  # characters, head and tail each bounded by their token budget, with a marker
  # stating how many characters lie between them. When the two halves cover the
  # line, show it whole.
  defp char_preview(text) do
    len = String.length(text)
    head = char_slice(text, len, @head_tokens, :head)
    tail = char_slice(text, len, @tail_tokens, :tail)
    head_len = String.length(head)
    tail_len = String.length(tail)

    if head_len + tail_len >= len do
      text
    else
      head <> marker(len - head_len - tail_len, "chars") <> tail
    end
  end

  defp assemble(head, marker, tail) do
    [head, marker, tail] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  # The elision marker. One template for both units ("lines" and "chars" are
  # the same width), so `substitute_size/0` prices a single widest marker.
  defp marker(count, unit), do: "… [#{count} #{unit} elided — read the file] …"

  # Leading whole lines within `budget`, charged per line by
  # `Estimator.estimate/1` (which carries a per-line overhead). Returns the
  # taken lines and the rest, so the caller knows exactly what was elided
  # without re-parsing a trimmed string. Shared by `head_text/3` and `preview/1`.
  defp take_head(lines, budget), do: take_head(lines, budget, [])

  defp take_head([], _budget, acc), do: {Enum.reverse(acc), []}

  defp take_head([line | rest], budget, acc) do
    cost = Estimator.estimate(line)

    if cost <= budget do
      take_head(rest, budget - cost, [line | acc])
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  # Trailing whole lines within `budget`: the head walk on the reversed list.
  # Returns the taken lines (in order) and the middle lines before them.
  defp take_tail(lines, budget) do
    {tail, middle} = lines |> Enum.reverse() |> take_head(budget)
    {Enum.reverse(tail), Enum.reverse(middle)}
  end

  # The largest leading/trailing char slice whose `Estimator.estimate/1` fits
  # `budget`. Start from a `budget * 4` char guess (~4 chars/token) and shrink
  # proportionally until it fits — dense text (base64, minified code) costs more
  # tokens per char, so a fixed char count would not be a bound. Deterministic
  # and cheap: each step tokenizes only the bounded slice, never the whole line.
  defp char_slice(text, len, budget, side) do
    fit_chars(text, min(len, budget * 4), budget, side)
  end

  defp fit_chars(_text, 0, _budget, _side), do: ""

  defp fit_chars(text, n, budget, side) do
    slice = take_chars(text, n, side)
    est = Estimator.estimate(slice)

    if est <= budget do
      slice
    else
      next = max(1, div(n * budget, est))
      fit_chars(text, min(next, n - 1), budget, side)
    end
  end

  defp take_chars(text, n, :head), do: String.slice(text, 0, n)
  defp take_chars(text, n, :tail), do: String.slice(text, -n, n)

  @doc """
  Take as many leading whole lines of `content` as fit `budget` tokens.

  Whole lines only (never mid-line). `Estimator.estimate/1` includes a
  per-line overhead, matching the rest of the sizing path.

  Never returns an empty string: when the budget can't fit even the
  first line, or `content` is empty, `no_room` is returned instead. It
  must be a non-empty self-describing marker so a caller can always tell
  that content was dropped (and where it went).

  There is deliberately no default `no_room`: every caller has to say
  where the dropped content went, so no result can claim content was
  elided without naming the file that holds it.
  """
  @spec head_text(String.t(), integer(), String.t()) :: String.t()
  def head_text(content, budget, no_room)

  def head_text("", _budget, no_room), do: no_room
  def head_text(_content, budget, no_room) when budget <= 0, do: no_room

  def head_text(content, budget, no_room) do
    {head_lines, _rest} = content |> String.split("\n") |> take_head(budget)
    join_lines(head_lines, no_room)
  end

  @doc """
  Take as many trailing whole lines of `content` as fit `budget` tokens — the
  tail counterpart of `head_text/3`, with the same whole-line and `no_room`
  contract. Used for the preview's tail so a command's final lines (where a
  failure usually is) stay visible.
  """
  @spec tail_text(String.t(), integer(), String.t()) :: String.t()
  def tail_text(content, budget, no_room)

  def tail_text("", _budget, no_room), do: no_room
  def tail_text(_content, budget, no_room) when budget <= 0, do: no_room

  def tail_text(content, budget, no_room) do
    {tail_lines, _middle} = content |> String.split("\n") |> take_tail(budget)
    join_lines(tail_lines, no_room)
  end

  defp join_lines([], no_room), do: no_room

  defp join_lines(lines, no_room) do
    case lines |> Enum.join("\n") |> String.trim_trailing() do
      "" -> no_room
      text -> text
    end
  end

  @doc """
  Lossy UTF-8 coercion: replace every invalid byte sequence, and every
  NUL (`U+0000`), with U+FFFD so the result is a string the estimator /
  message pipeline / database can handle. NUL is valid UTF-8 but Postgres
  `text`/`jsonb` rejects it, so it must be replaced too.

  `:unicode.characters_to_binary/3` decodes as much valid UTF-8 as it can
  and reports the offending remainder (as `{:error, converted, rest}` or
  `{:incomplete, converted, _}`) instead of raising. We splice in a
  replacement character for each invalid byte (dropping it so the
  recursion always makes progress) and keep decoding the remainder.
  """
  @spec to_valid_utf8(binary()) :: String.t()
  def to_valid_utf8(bin) do
    bin
    |> coerce_utf8()
    |> String.replace(<<0>>, @replacement_char)
  end

  defp coerce_utf8(<<>>), do: ""

  defp coerce_utf8(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      text when is_binary(text) ->
        text

      {:error, "", rest} ->
        # The head byte is invalid: replace it and move past it.
        @replacement_char <> coerce_utf8(drop_first_byte(rest))

      {:error, converted, rest} ->
        converted <> coerce_utf8(rest)

      {:incomplete, converted, _rest} ->
        converted <> @replacement_char
    end
  end

  defp drop_first_byte(<<_::8, rest::binary>>), do: rest

  defp token do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
