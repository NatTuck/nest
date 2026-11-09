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

  # The preview's size. Fixed rather than derived from the budget: a substitute
  # whose size depends on the window cannot be priced by the preflight, and
  # `substitute_size/0` is what the projection reserves per call. 200 tokens is
  # enough to tell a command's failure from its output and small enough that a
  # model that then reads the file has wasted very little.
  @preview_tokens 200

  # Memo key for `substitute_size/0`.
  @substitute_size_key {__MODULE__, :substitute_size}

  @doc """
  Write `content` to the agent's scratch dir and return the inline substitute:

      <label> (<N> tokens) saved to <path>.

      <leading whole lines of the content, ~#{@preview_tokens} tokens>

  The pointer names the file and its size; the preview says what the content
  is. Neither repeats anything the caller already has: the tool's arguments are
  in the `tool_use` part immediately before this, so the label names the tool
  and nothing else.

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
  this and `substitute/5` must describe the same block — one function, so they
  cannot drift.

  Memoized in `:persistent_term`: it is a constant of this module's own format,
  and `ResultPolicy.admit/3` reads it on every result to decide whether filing
  is even worth it. Recomputing it there would put a tokenizer call on every
  admission.
  """
  @spec substitute_size() :: pos_integer()
  def substitute_size do
    case :persistent_term.get(@substitute_size_key, nil) do
      nil ->
        size =
          Estimator.estimate(
            pointer("Output of shell-cmd", 1_000_000, "/tmp/a/exec-0000000000000000.txt", "")
          ) + @preview_tokens

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
      head -> header <> "\n\n" <> head
    end
  end

  # Whole lines, so the preview never ends mid-line. A single line longer than
  # the whole budget (a minified blob) is cut by characters instead of being
  # dropped: `head_text/3` returns its marker for it, and a preview is worth
  # more than nothing.
  defp preview(content) do
    case head_text(content, @preview_tokens, "") do
      "" -> content |> String.slice(0, @preview_tokens * 4) |> String.trim_trailing()
      head -> head
    end
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
