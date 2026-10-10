defmodule Nest.Agents.Agent.BatchSizer.Overflow do
  @moduledoc """
  Shared "write an oversized result to the agent's scratch dir" helpers.

  `write/4` saves the full bytes and is what `BatchSizer` and `Inbox` use to
  offload; `substitute/5` turns an oversized result into an in-budget inline
  block (a pointer + head) and is the single summarization path used by
  `BatchSizer` (regular tools), `BatchPlan` (the `agents-batch` aggregate) and
  `SubAgentResults` (the sub-agent tools' results).

  The scratch dir is `ctx.tmp_path` — the agent's own sub-directory of the
  space scratch dir (which the sandbox binds read-write at `/tmp`, so the
  agent sees it at `/tmp/<agent-name>`). Writing on the host directly
  (rather than through the sandbox gatekeeper) is intentional internal
  scratch management, mirroring `BatchSizer`. The HOST backing path stays
  internal: `write/4` returns the sandbox spelling the agent must use, so
  the host layout never reaches the LLM.
  """

  alias Nest.Tokens.Estimator

  # UTF-8 encoding of U+FFFD (REPLACEMENT CHARACTER), used by
  # `to_valid_utf8/1` for byte sequences that don't decode.
  @replacement_char <<0xEF, 0xBF, 0xBD>>

  @doc """
  Write `content` to a scratch file under `ctx.tmp_path` and return
  the path, or `nil` when the tmp dir is unavailable or the write
  fails. `prefix` distinguishes the artifact type in the filename
  (e.g. `"exec"` for shell output, `"agents-batch"` for a batch
  aggregate).
  """
  @spec write(binary(), map(), String.t(), String.t()) :: String.t() | nil
  def write(content, ctx, prefix, ext) do
    case Map.get(ctx, :tmp_path) do
      nil ->
        nil

      dir ->
        name = "#{prefix}-#{token()}.#{ext}"
        # HOST PATH: `dir` is the agent's host scratch directory, and `path`
        # is where the bytes are written. Neither is ever returned — the LLM
        # must only ever see the sandbox spelling (`/tmp/<agent>/...`), which
        # is what `Nest.Sandbox.sandbox_tmp_path/1` produces below.
        path = Path.join(dir, name)

        try do
          File.write!(path, content)
          Path.join(Nest.Sandbox.sandbox_tmp_path(dir), name)
        rescue
          _ -> nil
        end
    end
  end

  @doc """
  Build an in-budget inline substitute for an oversized tool result.

  Writes the full `content` to the agent's scratch dir and returns:

      <label> (<N> tokens) saved to <path>.

      <leading whole lines that fit the head budget>

  truncated (line-aligned) so `Estimator.estimate/1` of the result is at
  most `budget` tokens. The result is always valid UTF-8 and always fits;
  callers must not inline the full `content` instead. It is also never
  empty: when there is no budget for any of the content, the marker names
  the scratch file so the model still knows that content was elided and
  where to find it.

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
    header = "#{label} (#{size} tokens) #{location}."

    block = header <> "\n\n" <> head_text(content, head_budget(header), no_room)
    truncate_to_fit(block, budget, no_room)
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
