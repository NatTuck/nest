defmodule Nest.Agents.Agent.BatchSizer.Overflow do
  @moduledoc """
  Shared "write an oversized result to the agent's scratch dir" helpers.

  `write/4` saves the full bytes and is what `BatchSizer` and `Inbox` use to
  offload; `substitute/5` turns an oversized result into an in-budget inline
  block — a pointer, a head, and, when the head is short, the count of lines it
  leaves out — and is the single summarization path used by `BatchSizer`
  (regular tools), `BatchPlan` (the `agents-batch` aggregate) and
  `SubAgentResults` (the sub-agent tools' results).

  The scratch dir comes from `ctx.mounts` — the agent's own sub-directory of
  the space scratch dir (which the sandbox binds read-write at `/tmp`, so the
  agent sees it at `/tmp/<agent-name>`). What `write/4` returns is the
  `/tmp/<agent-name>/...` spelling the agent uses; the directory the bytes land
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

  @doc """
  Build an in-budget inline substitute for an oversized tool result.

  Writes the full `content` to the agent's scratch dir and returns:

      <label> (<N> tokens) saved to <path>. Below: first <shown> of <total> lines.

      <leading whole lines that fit the head budget>

  truncated (line-aligned) so `Estimator.estimate/1` of the result is at
  most `budget` tokens. The result is always valid UTF-8 and always fits;
  callers must not inline the full `content` instead. It is also never
  empty: when there is no budget for any of the content, the marker names
  the scratch file so the model still knows that content was elided and
  where to find it.

  The `Below: first <shown> of <total> lines.` clause is what keeps a short
  preview honest. The head budget is ~196 tokens, so a result showing 14 of
  2,431 lines said nothing about the other 2,417 and an agent could conclude
  there was no more. It is appended **only when something was cut**, so a
  result that fits gains nothing, and it counts the lines the model actually
  receives — the body is sized before the clause is written, so no later trim
  can make the counts describe text that is no longer there. "Cut" means the
  body differs from the content, not that the counts differ: `line_count/1`
  counts a trailing blank line as a line while the body's trailing newlines are
  trimmed, so a count comparison would label content whose only loss was
  trailing whitespace. In the no-room case there is no clause: the body *is* the
  elision marker, which already says the content was elided and where it is, and
  there are no preview lines to count.

  `label` names the result for the model (e.g. `"Command output of 'ls'"`).
  `prefix` names the scratch file (see `write/4`). `content` is expected
  to be storable text — non-text results (invalid UTF-8 or NUL) take
  `handle_binary_shell/4` instead.
  """
  @spec substitute(binary(), map(), String.t(), non_neg_integer(), String.t()) :: String.t()
  def substitute(content, ctx, label, budget, prefix) do
    size = Estimator.estimate(content)
    path = write(content, ctx, prefix, "txt")

    location = if path, do: "saved to #{path}", else: "temp file unavailable"
    no_room = elided_marker(path)
    total = line_count(content)
    header = "#{label} (#{size} tokens) #{location}."

    # The clause is part of the header line, so its cost is taken out of the
    # block budget *before* the preview is sized. Reserving the widest clause
    # this content can need (`first <total> of <total>`) makes the reservation a
    # fixed string, so the counts and the budget cannot chase each other, and the
    # body is final once it is chosen — no later trim can invalidate the counts.
    #
    # The reservation is the block's first two lines, exactly: the header with
    # its clause, and the blank line between it and the body. `estimate("")` is
    # 10, not 0 (`estimate/1` adds the per-line overhead), which is precisely
    # what that blank line costs in `head_text/3`'s line-by-line accounting — so
    # the block's per-line total is at most `budget` by construction.
    reserved = Estimator.estimate(header <> clause(total, total)) + Estimator.estimate("")
    body = head_text(content, min(head_budget(header), budget - reserved), no_room)

    if body == no_room do
      # Nothing fits below the header: the block is the header and the marker,
      # trimmed as before (a budget too small for either is the marker alone).
      truncate_to_fit(header <> "\n\n" <> no_room, budget, no_room)
    else
      # The clause is about what was *cut*, so the test is whether the body is
      # the whole content — not `shown < total`. Those differ on a trailing blank
      # line: `line_count/1` counts it as a line, while `head_text/3` trims the
      # body's trailing newlines, so `"a\n\n"` fits entirely and still had
      # `shown < total`. The body is what the model receives, so comparing it to
      # the content (modulo the whitespace `head_text/3` trims) is the honest
      # test.
      header =
        if String.trim_trailing(content) == body,
          do: header,
          else: header <> clause(line_count(body), total)

      header <> "\n\n" <> body
    end
  end

  # How much of the result the preview shows. Only ever built when something was
  # cut, so a result that fits gains no tokens at all.
  defp clause(shown, total), do: " Below: first #{shown} of #{total} lines."

  # The lines a reader sees in `text`: a trailing newline ends the last line
  # rather than starting an empty one.
  defp line_count(text) do
    lines = String.split(text, "\n")
    if List.last(lines) == "", do: length(lines) - 1, else: length(lines)
  end

  # The no-room marker for a substituted result. It always says the
  # content was elided, and names the scratch file when one was written
  # so the model can still read the full text.
  defp elided_marker(nil),
    do: "[content elided: the full result could not be written to a scratch file]"

  defp elided_marker(path), do: "[content elided: see #{path}]"

  # Head budget: ~4× the header, with a floor so a very short header
  # still yields a usable preview.
  defp head_budget(header) do
    header_tokens = Estimator.estimate(header)
    max(header_tokens * 4, header_tokens + 50)
  end

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
    head =
      content
      |> String.split("\n")
      |> Enum.reduce_while({"", 0}, fn line, {acc, used} ->
        line_tokens = Estimator.estimate(line)

        if used + line_tokens <= budget do
          {:cont, {acc <> line <> "\n", used + line_tokens}}
        else
          {:halt, {acc, used}}
        end
      end)
      |> elem(0)
      |> String.trim_trailing()

    if head == "", do: no_room, else: head
  end

  @doc """
  Trim `text` to at most `target_tokens` by taking leading whole lines.

  Never returns an empty string; see `head_text/3` for `no_room`.
  """
  @spec truncate_to_fit(String.t(), integer(), String.t()) :: String.t()
  def truncate_to_fit(text, target_tokens, no_room)

  def truncate_to_fit(_text, target_tokens, no_room) when target_tokens <= 0, do: no_room
  def truncate_to_fit(text, target_tokens, no_room), do: head_text(text, target_tokens, no_room)

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
