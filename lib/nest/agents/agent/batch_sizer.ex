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
  `Nest.Tools.get_function/3`) get a specific `projected_size/2`
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
  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve

  require Logger

  @empty_output_placeholder "[Command executed successfully with no output]"

  # Binary shell output at or below this size is included inline
  # (as a lossy UTF-8 view) alongside the "saved to <path>" pointer,
  # so the model sees a tiny binary's contents without opening the
  # file. Larger binaries return the pointer only — the model can
  # decide whether to spend context examining the file.
  @small_binary_max_bytes 256

  @type entry :: {ToolCall.t(), :ok | :error, String.t()}

  @doc """
  Run a batch of tool calls through preflight → execute →
  keep-or-substitute. Returns a list of `ToolResult` structs in
  input order, ready for the chat task to append as a single
  `{:tool, _}` message.

  Equivalent to `execute/2` followed by `cook/2`. Callers that need to
  merge results from other executors (e.g. `ToolLoop`'s sub-agent tools)
  should use those two directly so the whole batch is cooked once.

  The `ctx` map carries `messages`, `context_limit`, `tools`,
  `caps`, `agent_pid`, `tmp_path` (per-agent temp directory for
  summarized outputs), and `agent_name`.
  """
  @spec run([ToolCall.t()], map()) :: [ToolResult.t()]
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
      :fits -> Enum.map(tool_calls, &execute_one(&1, ctx))
    end
  end

  @doc """
  Project the post-batch message size without running any tool.
  Returns `:fits` or `{:refuse, reason}`.

  `ctx.context_limit` is always a positive integer in the agent
  runtime; a nil/other value matches no clause and raises, so a
  tool batch is never processed with an unknown limit.
  """
  @spec preflight([ToolCall.t()], map()) :: :fits | {:refuse, String.t()}
  def preflight([], _ctx), do: :fits

  def preflight(tool_calls, %{context_limit: limit} = ctx)
      when is_integer(limit) and limit > 0 do
    total = projected_content_size(tool_calls, ctx) + Reserve.compaction_reserve(limit)

    if total <= limit do
      :fits
    else
      {:refuse,
       "Batch refused: projected message list ~#{total} tokens exceeds " <>
         "limit ~#{limit}. Reformulate (e.g., call context-compact first " <>
         "or use smaller tools)."}
    end
  end

  @doc """
  Forward-looking content size after a batch's tool results, **excluding**
  the compaction reserve:

      Budget.size(ctx.messages) + sum(ProjectedSize.project(tc, ctx))

  This is the canonical projection: `preflight/2` adds `C` and compares
  against `L`, while the context-usage reminder compares it against
  `L - C`. Both are the same predicate (`size + C <= L`), so they must
  share this one function rather than each re-deriving a projection.
  """
  @spec projected_content_size([ToolCall.t()], map()) :: non_neg_integer()
  def projected_content_size(tool_calls, ctx) do
    projected = Enum.reduce(tool_calls, 0, fn tc, acc -> acc + projected_size(tc, ctx) end)

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
  # The per-tool projection lives in
  # `Nest.Agents.Agent.BatchSizer.ProjectedSize.project/2`. This
  # module just delegates to it.

  defp projected_size(%ToolCall{} = tc, ctx), do: ProjectedSize.project(tc, ctx)

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
           tmp_path: Map.get(ctx, :tmp_path)
         }) do
      {:ok, content} ->
        {tc, :ok, ensure_non_empty(content)}

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
  @spec cook([entry()], map()) :: [ToolResult.t()]
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
    Enum.map(cooked, fn {tc, kind, content} ->
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

      %ToolResult{
        tool_call_id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
        content: content,
        is_error: kind == :error
      }
    end)
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
  #      `full_size > cap`, route per-tool:
  #        * `shell-cmd` → write-to-tmp + path-and-head summary.
  #        * `file-read`  → return error result with size hint.
  #        * other tools  → log warning, keep full.
  #   3. Otherwise, decide keep-full vs. summarize against the
  #      running batch budget (`keep_full?/3`). The batch budget
  #      should always accommodate `full_size` post-preflight, but
  #      we fall back to the existing summary path for
  #      `shell-cmd` if it doesn't.
  #
  # A tool result that isn't valid UTF-8 (raw binary, e.g. `curl`
  # dumping a download to stdout) never goes inline raw: it's written
  # to the scratch file and replaced with a `saved to <path>` pointer
  # so the LLM can decide whether to inspect the file. When the binary
  # is tiny (<= `@small_binary_max_bytes`), a lossy UTF-8 view is
  # included inline too.
  defp apply_one_with_acc({tc, :ok, content} = entry, ctx, acc) do
    if is_binary(content) and not String.valid?(content) do
      handle_binary_shell(tc, content, ctx, acc)
    else
      size_text_result(entry, ctx, acc)
    end
  end

  defp apply_one_with_acc({tc, :error, reason}, _ctx, acc) do
    error_size = Estimator.estimate(reason) + per_message_overhead()
    {{tc, :error, reason}, advance(acc, error_size)}
  end

  # The original post-execution sizing path for text tool results.
  defp size_text_result({tc, :ok, content}, ctx, acc) do
    full_size = Estimator.estimate(content) + per_message_overhead()
    cap = effective_max_result_tokens(tc, acc.usable)

    if cap && full_size > cap do
      handle_over_cap(tc, content, full_size, ctx, acc)
    else
      fit_in_batch_budget(tc, content, full_size, ctx, acc)
    end
  end

  # A binary tool result: always write the raw bytes to the scratch file
  # and return a `saved to <path>` pointer inline. The model never sees
  # the raw bytes. For tiny binaries a lossy UTF-8 view rides along so
  # the model can read the contents without opening the file.
  defp handle_binary_shell(tc, content, ctx, acc) do
    bytes = byte_size(content)

    location =
      case Overflow.write(content, ctx, write_prefix(tc.name), "txt") do
        nil -> "temp file unavailable"
        path -> "saved to #{path}"
      end

    pointer = "#{output_label(tc)} (binary, #{bytes} bytes) #{location}."

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
      budget = max(0, acc.limit - acc.running - per_message_overhead())
      trimmed = Overflow.head_text(inline, budget)
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
  defp ensure_non_empty(s) when is_binary(s), do: s
end
