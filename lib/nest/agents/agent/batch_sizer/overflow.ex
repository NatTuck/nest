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

  alias Nest.Name
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
  # tokens — whole lines for the line path, an estimate-bounded char slice when
  # the first line does not fit — so each half really does cost at most its budget.
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

  # The worst-case header the projection prices. The label and filename prefix
  # are the longest a caller passes (the longest tool name, `ResultPolicy.label/1`
  # and `BatchSizer.write_prefix/1`); the size carries the widest digit count we
  # will ever print (10 digits, like the marker count). The path's agent-name
  # segment is the longest a name can be (`Nest.Name.max_bytes/0`) and the id the
  # densest `token/0` can emit (16 hex chars). Name and id are ASCII, so each
  # tokenizes at raw <= bytes; an alternating letter/digit string reaches raw ==
  # bytes (no BPE merges). `worst_header/0` assembles them with no seam merges,
  # hitting the subadditive ceiling — the most any legal header can cost.
  @worst_label "Output of agents-list-archived"
  @worst_prefix "agents-list-archived"
  @widest_size 9_999_999_999
  @worst_id "1a1a1a1a1a1a1a1a"

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
  the content fits the head + tail budgets it is shown whole with no marker.
  When the first line does not fit the head budget, the preview falls back to a
  char head + char tail spanning the whole trimmed content (which may itself be
  multi-line) with a chars-elided marker. Neither repeats anything the caller
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
  It prices the worst case: the longest header (longest label and prefix, widest
  size digits, and a max-length agent name priced at its densest legal
  tokenization) + head budget + tail budget + the widest marker + the join
  allowance. All are constants of this module's format and the name rule, none
  of them the caller's budget. Every preview half is estimate-charged against
  its budget (whole lines, or an estimate-bounded char slice), so this is a
  universal upper bound on any substitute — whatever the content, and whatever
  legal agent name files it.

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
          Estimator.estimate(worst_header()) +
            @head_tokens + @tail_tokens + Estimator.estimate(widest) + @join_allowance

        :persistent_term.put(@substitute_size_key, size)
        size

      size ->
        size
    end
  end

  # The longest header `substitute/5` can produce, at the subadditive ceiling:
  # longest label and prefix, widest size digits, a max-length name and a 16-char
  # id each alternating letter/digit so raw == bytes (the most ASCII can cost),
  # and no merges across the path seams. raw(header) <= raw(label) + raw("/tmp/")
  # + max_bytes + raw(frame) + 16, and this header reaches that bound, so no legal
  # header estimates higher. The id is dense hex, not zeros: `token/0` emits
  # random hex, and an all-zeros id would merge and under-price it.
  defp worst_header do
    max = Name.max_bytes()
    name = String.duplicate("1a", div(max, 2) + 1) |> binary_part(0, max)
    path = "/tmp/#{name}/#{@worst_prefix}-#{@worst_id}.txt"
    "#{@worst_label} (#{@widest_size} tokens) saved to #{path}."
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

  # The first line does not fit the head budget (a minified blob, base64, or a
  # huge first line followed by more): cut the whole trimmed content by
  # characters, head and tail each bounded by their token budget, with a marker
  # stating how many characters lie between them. The slice spans the whole
  # content, so it may itself contain newlines. When the two halves cover it,
  # show it whole.
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
  # without re-parsing a trimmed string. `take_tail/2` is this walk reversed.
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

  # An estimate-bounded leading/trailing char slice. Start from a `budget * 4`
  # char guess (~4 chars/token) and shrink proportionally until the estimate fits
  # `budget` — dense text (base64, minified code) costs more tokens per char, so a
  # fixed char count would not be a bound. `fit_chars/4` stops at the first slice
  # that fits; BPE is not monotone in length, so this is a bound, not a maximum.
  # Deterministic and cheap: each step tokenizes only the bounded slice, never the
  # whole content.
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
