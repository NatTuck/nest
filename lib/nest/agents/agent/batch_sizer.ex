defmodule Nest.Agents.Agent.BatchSizer do
  @moduledoc """
  Three-phase batch processing for tool calls: preflight, execute,
  keep-or-summarize.

  Replaces the legacy `Nest.Tokens.BudgetPlanner` heuristic (truncate
  / skip / keep as-is) with deterministic size accounting per tool.
  See `notes/extract-compaction-and-resumable-chat-turn.md` for the
  full design.

  ## Phase 1: Preflight

  Compute each tool call's projected output size using its
  per-tool policy. Sum the projections plus the current
  `state.chat_state.messages` size plus the LLM compaction reserve
  (`Nest.Tokens.Reserve.compaction_reserve/1`). If the sum
  exceeds `context_limit`, the entire batch is refused with
  per-call synthetic errors and no tools execute.

  Registered tools (those listed in `state.tools`, served via
  `Nest.Tools.get_function/2`) get a specific `projected_size/2`
  clause. The catch-all handles hallucinated names the LLM
  invents or typos — it projects off a representative error
  string, since that's what Phase 2's `LLMTools.execute_one/3`
  returns for those calls.

  When a real new tool is added to `Nest.Tools`, add a
  `projected_size/2` clause here with a regression test in
  `test/nest/agents/agent/batch_sizer_test.exs`. The catch-all
  is for the LLM's typos, not for registered-but-unprojected
  tools.

  ## Phase 2: Execute

  Run every tool in the batch. Each returns its full result
  string. Sizes are computed post-execution via
  `Nest.Tokens.Estimator.estimate/1` (which applies the 20%
  safety multiplier), so they are conservative upper bounds on
  what the LLM will tokenize.

  ## Phase 3: Keep-or-substitute (all tools)

  For each result, decide keep-full or replace-with-substitute such that
  the running total never exceeds `context_limit`. Earlier results get
  keep-full; later results get substituted as the budget tightens. An
  over-budget result is ALWAYS substituted — never kept full. The
  substitute writes the full output to the agent's scratch dir and
  returns a pointer + head of bounded size.

  ## Tool-result cap (`max_result_tokens`)

  The LLM may pass `max_result_tokens` in a tool call's arguments
  to ask for a tighter inline cap. The effective cap is computed
  once per batch as 80% of the remaining usable context window;
  the LLM may only lower the cap (raise it past the 80% default
  is clamped). Per-tool behavior when the cap is exceeded:

    * `file-read` → return `{:error, "File is X tokens
      which exceeds your requested limit of Y."}`.
    * Every other tool → write full output to tmp, return
      path-and-head substitute inline.

  `ToolLoop` runs `execute/2` for the regular tools, then cooks the
  merged regular + sub-agent entries once via `cook/2`, so the budget
  pass covers the whole batch and the invariant holds across tool
  families.

  When `ctx.context_limit` is `nil` (or non-positive), `preflight`
  matches no clause and raises — the limit is never optional, and a
  tool batch is never processed without a known context window.
  """

  alias Nest.Agents.Agent.BatchSizer.FilePolicy
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Agents.SpaceGate
  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Messages.Part
  alias Nest.Messages.Sanitize
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.RequestSize
  alias Nest.Tokens.Reserve

  require Logger

  @empty_output_placeholder "[Command executed successfully with no output]"

  # Binary shell output at or below this size is included inline
  # (as a lossy UTF-8 view) alongside the "saved to <path>" pointer,
  # so the model sees a tiny binary's contents without opening the
  # file. Larger binaries return the pointer only — the model can
  # decide whether to spend context examining the file.
  @small_binary_max_bytes 256

  # The third element is the raw result: a string for every ordinary tool, or
  # a tagged media part for a `file-read` that attached an image. The shape is
  # tagged rather than the string type being widened, so `ToolResult.content`
  # stays `String.t()` and every `is_binary` branch below keeps working.
  #
  # The second element is the result's *kind*: `:error` for a refusal, and
  # `:cancelled` for a call the space edit called off, which the model must see as
  # `is_error: true` but which is not a failure to diagnose (see `do_execute/2`).
  # `:waiting` for a result that is not a verdict at all — a wait tool's, whose
  # real result arrives later as a message (issue #54). `:waiting` sizes
  # exactly like `:ok` and differs only in the `state` the part is stamped with.
  @type entry ::
          {ToolCall.t(), :ok | :error | :cancelled | :waiting,
           String.t() | {:media, Part.Media.t()}}

  @doc """
  Run a batch of tool calls through preflight → execute →
  keep-or-substitute. Returns a list of `ToolResult` structs in
  input order, ready for the chat task to append as a single
  `{:tool, _}` message.

  Equivalent to `execute/2` followed by `cook/2`. Callers that need to
  merge results from other executors (e.g. `ToolLoop`'s sub-agent tools)
  should use those two directly so the whole batch is cooked once.

  The `ctx` map carries `messages`, `context_limit`, `tools`,
  `caps`, `agent_pid`, `mounts` (the sandbox's bind layout, for
  summarized outputs), and `agent_name`.
  """
  @spec run([ToolCall.t()], map()) :: [Part.t()]
  def run(tool_calls, ctx) when is_list(tool_calls) and is_map(ctx) do
    tool_calls |> execute(ctx) |> cook(ctx)
  end

  @doc """
  Preflight + execute a batch, returning raw `entry`s **without** cooking.

  On a preflight refusal the entries are `{:error, reason}` for every call
  (and the refusal is logged). Callers that will merge results from other
  executors must pass the combined, input-ordered entry list to `cook/2`
  so the whole batch shares one running budget.
  """
  @spec execute([ToolCall.t()], map()) :: [entry()]
  def execute([], _ctx), do: []

  def execute(tool_calls, ctx) do
    case preflight(tool_calls, ctx) do
      {:refuse, reason} -> refuse_entries(tool_calls, reason)
      {:fits, _projected} -> Enum.map(tool_calls, &execute_one(&1, ctx))
    end
  end

  @doc """
  Project the post-batch message size without running any tool, and decide
  whether the batch fits.

  Returns `{:fits, projected}` — where `projected` is exactly the content-size
  projection `projected_content_size/2` returns, the same number callers need
  for the context-usage reminder — or `{:refuse, reason}`. The comparison adds
  the compaction reserve; that stays internal.

  Handing the projection back is what keeps a response's `file-read` stats to
  one batched invocation: a caller that also needs the number would otherwise
  re-derive it, and re-deriving means a second `ProjectedSize.project_batch/2`
  and so a second `Sandbox.stat_many/3` (issue #48).

  `ctx.context_limit` is always a positive integer in the agent
  runtime; a nil/other value matches no clause and raises, so a
  tool batch is never processed with an unknown limit.
  """
  @spec preflight([ToolCall.t()], map()) :: {:fits, non_neg_integer()} | {:refuse, String.t()}
  def preflight([], ctx), do: {:fits, Budget.size(Map.get(ctx, :messages) || [])}

  def preflight(tool_calls, %{context_limit: limit} = ctx)
      when is_integer(limit) and limit > 0 do
    {projected, media} = projected_content_size_and_media(tool_calls, ctx)
    total = projected + Reserve.compaction_reserve(limit)
    messages = Map.get(ctx, :messages) || []

    cond do
      total > limit ->
        {:refuse,
         "Batch refused: projected message list ~#{total} tokens exceeds " <>
           "limit ~#{limit}. Reformulate (e.g., call context-compact first " <>
           "or use smaller tools)."}

      # The byte ceiling. Media is priced at a flat token ceiling, so this is
      # the only budget that can see it — and a refusal here is fixable by
      # compaction, which replaces the conversation with a summary and drops the
      # images. That is why the caller may route it into one: a refusal
      # compaction cannot fix is the shape that loops, and this is not it.
      not RequestSize.within?(messages, media) ->
        {:refuse, request_bytes_refusal(RequestSize.bytes(messages) + media)}

      true ->
        {:fits, projected}
    end
  end

  # One stat pass for both numbers (issue #48): the token projection and the
  # media bytes come from the same memoized sizes, so a batch is statted once
  # per response however many of these numbers a caller wants.
  defp projected_content_size_and_media(tool_calls, ctx) do
    {projected, media} = ProjectedSize.project_batch_with_media(tool_calls, ctx)
    {Budget.size(ctx.messages || []) + ceil(projected), media}
  end

  defp request_bytes_refusal(bytes) do
    "Batch refused: attaching these images would put the request at " <>
      "~#{Float.round(bytes / 1_000_000, 1)} MB, over the " <>
      "#{Float.round(RequestSize.max_bytes() / 1_000_000, 1)} MB limit. " <>
      "Call context-compact first — it replaces the conversation with a summary " <>
      "and drops the images."
  end

  @doc """
  Forward-looking content size after a batch's tool results, **excluding**
  the compaction reserve:

      Budget.size(ctx.messages) + ProjectedSize.project_batch(tool_calls, ctx)

  This is the canonical projection: `preflight/2` adds `C` and compares
  against `L`, while the context-usage reminder compares it against
  `L - C`. Both are the same predicate (`size + C <= L`), so they must
  share this one function rather than each re-deriving a projection.

  The per-tool sum lives in `ProjectedSize.project_batch/2` so the whole
  batch shares one `Sandbox.stat/3` per distinct `file-read` path
  (issue #48).
  """
  @spec projected_content_size([ToolCall.t()], map()) :: non_neg_integer()
  def projected_content_size(tool_calls, ctx) do
    projected = ProjectedSize.project_batch(tool_calls, ctx)

    # `ProjectedSize.project/2` applies a float safety padding; round up so
    # the result is an integer token count (ceil keeps it conservative).
    Budget.size(ctx.messages || []) + ceil(projected)
  end

  @doc """
  Remaining usable context window in tokens. Delegates to
  `Nest.Agents.Agent.CapCalculator.usable_remaining/1`.
  """
  defdelegate usable_remaining(ctx), to: CapCalculator

  @doc """
  The effective inline-result cap for a tool call. Delegates to
  `Nest.Agents.Agent.CapCalculator.effective_max_result_tokens/2`.
  """
  defdelegate effective_max_result_tokens(tool_call, usable), to: CapCalculator

  # ---- Phase 1: per-tool projected sizes (pre-execution) ----
  #
  # The per-tool projection and the batch sum both live in
  # `Nest.Agents.Agent.BatchSizer.ProjectedSize` (`project/2` and
  # `project_batch/2`); `projected_content_size/2` above delegates to them.

  # ---- Phase 2: execute the batch ----

  # Pre-call hook for `file-write`. Refuses the tool call
  # with a structured `{:error, reason}` if the agent has
  # not previously read the target path, or if the file on
  # disk no longer matches the recorded `{mtime, size}`.
  # The refusal flows through the same `execute_one/3`
  # error path as a missing-args or sandbox refusal, so the
  # LLM sees a tool result with `is_error: true` and can
  # retry (after `file-read`). The check + the user-facing
  # translation live in `FilePolicy` (extracted to keep
  # this module under credo/line-count rules).
  defp execute_one(%ToolCall{} = tc, ctx) do
    # The space's before-starts latch: while its environment is being edited,
    # every tool use waits here. What it then runs with is its *batch's* mounts
    # (`ctx.mounts`, `ctx.caps`) — the new values for a batch that started after
    # the write, the old ones for a batch already in flight, which the edit
    # cancels where it has a long call running. One ETS read when nothing is
    # held. `Map.get/2`, not `ctx.space_id`: a `BatchSizer` caller may build a
    # context with no space at all.
    :ok = SpaceGate.await(Map.get(ctx, :space_id))

    case FilePolicy.check(tc, ctx) do
      :ok ->
        do_execute(tc, ctx)

      {:error, _reason} = err ->
        {tc, :error, FilePolicy.error_message(err)}
    end
  end

  defp do_execute(tc, ctx) do
    case LLMTools.execute_one(ctx.tools, tc, %{
           caps: ctx.caps,
           messages: ctx.messages,
           context_limit: ctx.context_limit,
           # Per-call identity. Tools that manage per-agent resources
           # (`shell-cmd background`, `shell-list`/`wait`/`kill`) need the
           # real `{space_id, agent_name}` and the Agent pid; without these
           # they default to `{nil, nil}` / `:unknown` and operate on the
           # wrong (or no) agent. See `Nest.Tools.agent_key/1`.
           agent_pid: Map.get(ctx, :agent_pid),
           agent_name: Map.get(ctx, :agent_name),
           space_id: Map.get(ctx, :space_id),
           mounts: Map.get(ctx, :mounts),
           # The caller's own model. `file-read`'s media gate consults it: a
           # media part is re-sent on every later request, so whether this
           # model accepts media input has to be settled before one is built.
           client_config: Map.get(ctx, :client_config),
           # `file-read` needs its own call id to tie an attached media part
           # to the `ToolResult` it answers — Anthropic folds the media into
           # that result's block, OpenAI hoists it into a following message,
           # and both need to know which call it belongs to.
           tool_call_id: tc.id
         }) do
      {:ok, content} ->
        {tc, :ok, ensure_non_empty(content)}

      {:waiting, content} ->
        {tc, :waiting, ensure_non_empty(content)}

      # The space's environment changed and the edit called this call off
      # (`Nest.Agents.SpaceGate`, `Nest.Agents.Agent.cancel_tools/2`). It is not a
      # failure: the agent is told why and may re-issue the call. Its own kind so
      # that neither this function's `[error]` line nor `finalize/2`'s fires for a
      # routine space edit — the result still reaches the model as
      # `is_error: true`, because the call did not run.
      {:cancelled, reason} ->
        {tc, :cancelled, ensure_non_empty(reason)}

      {:error, reason} ->
        # Permanent diagnostic. The tool returned an error tuple
        # rather than crashing. The LLM is going to see this as
        # the tool result's content (with is_error=true). When
        # this fires for shell_cmd under parallel load, we want
        # the server-side record so we can diagnose the cause.
        Logger.error(
          "BatchSizer.do_execute: tool returned error " <>
            "tool=#{tc.name} tool_call_id=#{tc.id} " <>
            "arguments=#{inspect(tc.arguments)} reason=#{inspect(reason)}"
        )

        {tc, :error, ensure_non_empty(reason)}
    end
  end

  # ---- Phase 3: cook the raw results into final ToolResults ----
  #
  # Walk the results in input order, deciding keep-full or substitute
  # against the running total. An over-budget result is ALWAYS
  # substituted (`handle_over_cap`/`offload`), never kept full.

  @doc """
  Turn raw `entry`s into `ToolResult`s, applying the keep-or-substitute
  pass over the whole (input-ordered) list.

  This is the single budget pass. `run/2` uses it for a standalone batch,
  and `ToolLoop` uses it once over the merged regular + sub-agent entries
  so the entire batch shares one running total. Errors are logged here
  (once). When `ctx` has no positive `context_limit` (test callers), the
  entries are returned as `ToolResult`s unchanged, without error logging.
  """
  @spec cook([entry()], map()) :: [Part.t()]
  def cook(entries, %{context_limit: limit, messages: _} = ctx)
      when is_integer(limit) and limit > 0 do
    entries |> reduce_entries(ctx) |> finalize(true)
  end

  def cook(entries, _ctx), do: finalize(entries, false)

  defp reduce_entries(entries, ctx) do
    limit = ctx.context_limit
    base = Budget.size(ctx.messages || [])
    usable = usable_remaining(ctx)
    reserve = Reserve.compaction_reserve(limit)
    initial = %{running: base + reserve, limit: limit, usable: usable}

    {cooked, _final_acc} =
      Enum.map_reduce(entries, initial, fn entry, acc ->
        apply_one_with_acc(entry, ctx, acc)
      end)

    cooked
  end

  defp finalize(cooked, log_errors?) do
    Enum.flat_map(cooked, fn {tc, kind, content} ->
      if log_errors? and kind == :error do
        # Permanent diagnostic. The LLM is going to see this error
        # as a tool result and decide what to do next, but we also
        # want a server-side record so a flake in this code path
        # is observable in the log. is_error=true is the rare path
        # (bwrap failures, preflight refusals, missing tools, tool
        # function crashes). If this fires for shell-cmd under
        # parallel load, we need to know.
        Logger.error(
          "BatchSizer produced is_error=true tool result: " <>
            "tool=#{tc.name} tool_call_id=#{tc.id} " <>
            "arguments=#{inspect(tc.arguments)} " <>
            "content=#{inspect(content)}"
        )
      end

      entry_parts(tc, kind, content)
    end)
  end

  # A media entry becomes two parts: the `ToolResult` that answers the call,
  # then the media itself. The order matters. The Anthropic encoder groups
  # media under the result sharing its `tool_call_id` by walking parts in
  # order, and OpenAI's hoist appends after the results, so result-before-media
  # is what both expect; it also keeps a batch with two media reads from
  # interleaving their parts.
  defp entry_parts(tc, :ok, {:media, part}) do
    [tool_result_part(tc, media_summary(part), false), part]
  end

  # A wait tool's result carries `state: "waiting"`: the call registered a watch
  # and its real result arrives later as a message (issue #54). It is not an
  # error — the call did what it was asked — and it is not a verdict either, so
  # the panel badges it as outstanding and the machine reads it to end the turn.
  defp entry_parts(tc, :waiting, content) do
    [tool_result_part(tc, content, false, "waiting")]
  end

  defp entry_parts(tc, kind, content) do
    [tool_result_part(tc, content, kind in [:error, :cancelled])]
  end

  defp tool_result_part(tc, content, is_error?, state \\ nil) do
    %ToolResult{
      tool_call_id: tc.id,
      name: tc.name,
      arguments: tc.arguments,
      content: content,
      is_error: is_error?,
      state: state
    }
  end

  defp keep_full?(_tc, %{limit: limit, running: running}, full_size),
    do: running + full_size <= limit

  defp advance(%{running: running} = acc, by) do
    %{acc | running: running + by}
  end

  # Like `apply_one/3` but threaded through the running acc.
  # Returns `{cooked_entry, updated_acc}`.
  #
  # Decision tree:
  #   1. Compute `full_size` for the actual content.
  #   2. If the cap (`effective_max_result_tokens/2`) is set and
  #      `full_size > cap`, route per-tool (`handle_over_cap/5`):
  #        * `file-read`  → return an error result with a size hint. The cap
  #          is an upper bound on what the preflight projects rather than a
  #          matched number: `ProjectedSize.read_file_projection/2` clamps its
  #          projection to this cap, so the preflight is never *below* what
  #          this pass enforces.
  #        * every other tool → `offload/5`: write the full output to scratch
  #          and keep a bounded pointer + head inline.
  #      Note what does NOT bound that substitute: `offload/5` sizes it against
  #      `acc.limit - acc.running`, and `acc.limit` is the *context limit*, not
  #      the cap. So "nothing over the cap goes inline" holds for `file-read`
  #      and media only — it is not a property of every tool, and code that
  #      wants a cap bound must not assume it.
  #   3. Otherwise, decide keep-full vs. summarize against the
  #      running batch budget (`keep_full?/3`). The batch budget
  #      should always accommodate `full_size` post-preflight, but
  #      every tool falls back to the substitute path (`offload/5`)
  #      when it does not.
  #
  # A tool result that isn't storable text (invalid UTF-8, or valid
  # UTF-8 containing NUL — e.g. `curl` dumping a download to stdout, or
  # a hardware tool's NUL-padded output) never goes inline raw: it's
  # written to the scratch file and replaced with a non-text `saved to
  # <path>` pointer so the LLM is told the result is binary and can
  # decide whether to inspect the file. When the binary is tiny
  # (<= `@small_binary_max_bytes`), a lossy UTF-8 view is included
  # inline too.
  # A media result is priced at its modality's ceiling — the same number the
  # preflight projects — and is NEVER substituted. You cannot summarize an
  # image, so an over-cap attachment is an error the model can act on, exactly
  # like `file-read`'s text over-cap path. Falling through to the binary
  # machinery below would be worse than useless: it would write the base64 to
  # a scratch file and hand the model a pointer to something it cannot see.
  defp apply_one_with_acc({tc, :ok, {:media, part}}, _ctx, acc) do
    price = Estimator.estimate_media(part) + per_message_overhead()
    cap = cap_for(tc, acc)

    if cap && price > cap do
      error = media_over_cap_error(part, price, cap)
      error_size = Estimator.estimate(error) + per_message_overhead()
      {{tc, :error, error}, advance(acc, error_size)}
    else
      {{tc, :ok, {:media, part}}, advance(acc, price)}
    end
  end

  defp apply_one_with_acc({tc, :ok, content} = entry, ctx, acc) do
    if is_binary(content) and not Sanitize.text?(content) do
      handle_binary_shell(tc, content, ctx, acc)
    else
      size_text_result(entry, ctx, acc)
    end
  end

  # `:cancelled` is cooked exactly like `:error` — an error result whose content is
  # the reason — because the only difference is the log line `finalize/2` skips for
  # it, and the kind it keeps so that line can tell them apart.
  defp apply_one_with_acc({tc, kind, reason}, _ctx, acc) when kind in [:error, :cancelled] do
    error_size = Estimator.estimate(reason) + per_message_overhead()
    {{tc, kind, reason}, advance(acc, error_size)}
  end

  # A wait tool's result is sized exactly like an ordinary text result — it is a
  # short confirmation — and only the kind is re-tagged, so `entry_parts/3` can
  # stamp the part's `state` (issue #54).
  defp apply_one_with_acc({tc, :waiting, content}, ctx, acc) do
    {{tc, _ok, cooked}, acc} = apply_one_with_acc({tc, :ok, content}, ctx, acc)
    {{tc, :waiting, cooked}, acc}
  end

  # The original post-execution sizing path for text tool results.
  defp size_text_result({tc, :ok, content}, ctx, acc) do
    full_size = Estimator.estimate(content) + per_message_overhead()
    cap = cap_for(tc, acc)

    if cap && full_size > cap do
      handle_over_cap(tc, content, full_size, ctx, acc)
    else
      fit_in_batch_budget(tc, content, full_size, ctx, acc)
    end
  end

  # The cap for this call, or `nil` when the batch has no usable window left.
  #
  # `effective_max_result_tokens/2` requires a positive window, and a spent one
  # is reachable here: `cook/2` runs on its own for a merged regular +
  # sub-agent batch, without the preflight that would have refused it, and
  # `reduce_entries/2` sets `usable: 0` when the conversation has already
  # consumed the content budget. Treating that as "no cap" falls through to the
  # batch-budget pass, which substitutes an over-budget result — the right
  # answer, where raising would crash the turn.
  defp cap_for(tc, %{usable: usable}) when is_integer(usable) and usable > 0,
    do: effective_max_result_tokens(tc, usable)

  defp cap_for(_tc, _acc), do: nil

  # A non-text tool result: always write the raw bytes to the scratch
  # file and return a `saved to <path>` pointer inline that tells the
  # model the output is non-text/binary. The model never sees the raw
  # bytes inline (except the lossy view below). For tiny binaries a
  # lossy UTF-8 view rides along so the model can read the contents
  # without opening the file.
  defp handle_binary_shell(tc, content, ctx, acc) do
    bytes = byte_size(content)
    path = Overflow.write(content, ctx, write_prefix(tc.name), "txt")
    location = if path, do: "saved to #{path}", else: "temp file unavailable"
    pointer = "#{output_label(tc)} (non-text binary output, #{bytes} bytes) #{location}."

    inline =
      if bytes <= @small_binary_max_bytes do
        body = Overflow.to_valid_utf8(content)

        if body == "" do
          pointer
        else
          pointer <> "\n\n" <> body
        end
      else
        pointer
      end

    inline_size = Estimator.estimate(inline) + per_message_overhead()

    if acc.running + inline_size <= acc.limit do
      {{tc, :ok, inline}, advance(acc, inline_size)}
    else
      # No room for the inline view. Trim to whole lines, but pass an
      # explicit marker: a generic one would only say "written to a scratch
      # file" and drop the path. `pointer` already names the scratch file
      # and byte count (or says the temp file was unavailable), so the
      # marker reads correctly in both cases.
      budget = max(0, acc.limit - acc.running - per_message_overhead())
      no_room = pointer <> " [inline view elided]"
      trimmed = Overflow.head_text(inline, budget, no_room)
      trimmed_size = Estimator.estimate(trimmed) + per_message_overhead()
      {{tc, :ok, trimmed}, advance(acc, trimmed_size)}
    end
  end

  # Decision for tools whose output fits the inline cap but might
  # overflow the running batch budget. Same routing as
  # `handle_over_cap/5`, but the trigger is the batch budget rather
  # than the inline cap.
  defp fit_in_batch_budget(tc, content, full_size, ctx, acc) do
    if keep_full?(tc, acc, full_size) do
      {{tc, :ok, content}, advance(acc, full_size)}
    else
      offload(tc, content, ctx, acc)
    end
  end

  # Per-tool routing when the inline cap is exceeded. The cap was set by
  # `effective_max_result_tokens/2` — the LLM either asked for it (via
  # `max_result_tokens`) or got the 80% default. `file-read` returns an
  # explicit error (its caller asked for a size check); every other tool
  # is substituted with an in-budget pointer + head. We never keep an
  # over-budget result inline.
  defp handle_over_cap(%ToolCall{name: "file-read"} = tc, _content, full_size, _ctx, acc) do
    cap = effective_max_result_tokens(tc, acc.usable)
    error = "File is #{full_size} tokens which exceeds your requested limit of #{cap}."
    error_size = Estimator.estimate(error) + per_message_overhead()
    {{tc, :error, error}, advance(acc, error_size)}
  end

  defp handle_over_cap(tc, content, _full_size, ctx, acc) do
    offload(tc, content, ctx, acc)
  end

  # Media gets its own wording because the remedy differs: the model cannot
  # retry with a smaller `max_result_tokens` and get a summarized image, so it
  # has to be told the attachment was dropped rather than shortened.
  defp media_over_cap_error(%Part.Media{} = part, price, cap) do
    "File is #{human_bytes(part.bytes)} of #{part.media_type} (~#{price} tokens), which " <>
      "exceeds your requested limit of #{cap}. Media cannot be summarized or " <>
      "offloaded, so it was not attached."
  end

  defp human_bytes(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp human_bytes(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp human_bytes(bytes), do: "#{bytes} bytes"

  # The one-line text anchor that rides beside the media part. It is what
  # keeps `ToolResult.content` a string — every `is_binary` branch above
  # depends on that — and it tells the model what was attached without
  # repeating a single byte of it.
  #
  # `path` is optional by design (`new_media/1` permits `nil`), so it is left
  # out rather than interpolated as an empty string.
  defp media_summary(%Part.Media{} = part) do
    source = if part.path, do: " from #{part.path}", else: ""
    "Read #{human_bytes(part.bytes)} #{part.media_type}#{source}; attached below."
  end

  # Replace an oversized result with an in-budget pointer + head. The
  # block is sized to the remaining batch budget, so it always fits.
  # This is the ONLY path for an over-budget result — keeping the full
  # content inline would violate the budget invariant.
  defp offload(tc, content, ctx, acc) do
    budget = max(0, acc.limit - acc.running - per_message_overhead())

    inline =
      Overflow.substitute(content, ctx, output_label(tc), budget, write_prefix(tc.name))

    inline_size = Estimator.estimate(inline) + per_message_overhead()
    {{tc, :ok, inline}, advance(acc, inline_size)}
  end

  # Human-readable label for a substituted result, naming the tool and
  # (when present) its identifying argument.
  defp output_label(%ToolCall{name: "shell-cmd", arguments: args}),
    do: "Command output of '#{arg(args, "command")}'"

  defp output_label(%ToolCall{name: "shell-wait", arguments: args}),
    do: "Output of shell-wait #{arg(args, "id")}"

  defp output_label(%ToolCall{name: name}), do: "Output of #{name}"

  defp arg(args, key) when is_map(args), do: Map.get(args, key, "")
  defp arg(_args, _key), do: ""

  # Scratch-file prefix. Shell results keep the historical "exec" prefix
  # (the docs/model refer to it); everything else is named after the tool.
  defp write_prefix("shell-cmd"), do: "exec"
  defp write_prefix("shell-wait"), do: "exec"
  defp write_prefix("shell-list"), do: "exec"
  defp write_prefix(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "_")

  defp refuse_entries(tool_calls, reason) do
    # Permanent diagnostic. Preflight refused the batch (projected
    # token total exceeds the context window). The LLM will see
    # this as the tool result's content with is_error=true. Fires
    # only on oversized batches — should be rare.
    Logger.error(
      "BatchSizer refused batch (preflight): " <>
        "tool_calls=#{length(tool_calls)} reason=#{inspect(reason)}"
    )

    Enum.map(tool_calls, fn tc -> {tc, :error, reason} end)
  end

  # ---- helpers ----

  defp per_message_overhead, do: 10

  defp ensure_non_empty(""), do: @empty_output_placeholder
  defp ensure_non_empty(nil), do: @empty_output_placeholder
  # A media result is not a string and has nothing to be empty of; the media
  # clause in `apply_one_with_acc/3` is what sizes it.
  defp ensure_non_empty({:media, _part} = media), do: media
  defp ensure_non_empty(s) when is_binary(s), do: s
end
