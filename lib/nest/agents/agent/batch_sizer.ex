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
  `state.chat_state.messages` size plus the preflight reserve.
  If the sum exceeds `context_limit`, the entire batch is
  refused with per-call synthetic errors and no tools execute.

  ## Phase 2: Execute

  Run every tool in the batch. Each returns its full result
  string. Sizes are computed post-execution via
  `Nest.Tokens.Estimator.estimate/1` (which applies the 20%
  safety multiplier), so they are conservative upper bounds on
  what the LLM will tokenize.

  ## Phase 3: Keep-or-summarize (execute_command only)

  For each `execute_command` result, decide keep-full or
  replace-with-summary such that the running total never
  exceeds `context_limit`. Earlier results get keep-full; later
  results get summarized as the budget tightens. Other tools
  are always kept full.

  ## Tool-result cap (`max_result_tokens`)

  The LLM may pass `max_result_tokens` in a tool call's arguments
  to ask for a tighter inline cap. The effective cap is computed
  once per batch as 80% of the remaining usable context window;
  the LLM may only lower the cap (raise it past the 80% default
  is clamped). Per-tool behavior when the cap is exceeded:

    * `execute_command` → write full output to tmp, return
      path-and-head summary inline.
    * `read_file`        → return `{:error, "File is X tokens
      which exceeds your requested limit of Y."}`.
    * Other tools        → log warning, keep full (cap unreachable
      in practice because their outputs are bounded by construction).

  When `ctx.context_limit` is `nil`, no cap is enforced (the
  degraded-but-hopeful path).
  """

  alias Nest.Agents.Agent.CapCalculator
  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Tokens.Estimator

  require Logger

  @preflight_reserve 8_192
  @safety_padding 1.20
  @max_read_file_bytes 100 * 1_000_000

  @empty_output_placeholder "[Command executed successfully with no output]"

  @doc """
  Run a batch of tool calls through preflight → execute →
  keep-or-summarize. Returns a list of `ToolResult` structs in
  input order, ready for the chat task to append as a single
  `{:tool, _}` message.

  The `ctx` map carries `messages`, `context_limit`, `tools`,
  `caps`, `agent_pid`, `tmp_path` (per-agent temp directory for
  summarized outputs), and `agent_name`.
  """
  @spec run([ToolCall.t()], map()) :: [ToolResult.t()]
  def run(tool_calls, ctx) when is_list(tool_calls) and is_map(ctx) do
    case preflight(tool_calls, ctx) do
      {:refuse, reason} ->
        refuse_results(tool_calls, reason)

      :fits ->
        executed = Enum.map(tool_calls, &execute_one(&1, ctx))
        cook(executed, ctx)
    end
  end

  @doc """
  Project the post-batch message size without running any tool.
  Returns `:fits` or `{:refuse, reason}`.
  """
  @spec preflight([ToolCall.t()], map()) :: :fits | {:refuse, String.t()}
  def preflight([], _ctx), do: :fits

  def preflight(tool_calls, ctx) do
    case ctx.context_limit do
      nil ->
        :fits

      limit when is_integer(limit) and limit > 0 ->
        current = Estimator.estimate_messages(ctx.messages || [])

        projected =
          tool_calls
          |> Enum.reduce(0, fn tc, acc -> acc + projected_size(tc, ctx) end)
          |> Kernel.+(@preflight_reserve)

        total = current + projected

        if total <= limit do
          :fits
        else
          {:refuse,
           "Batch refused: projected message list ~#{total} tokens exceeds " <>
             "limit ~#{limit}. Reformulate (e.g., call context.compact first " <>
             "or use smaller tools)."}
        end

      _ ->
        :fits
    end
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

  defp projected_size(%ToolCall{name: "read_file"} = tc, _ctx) do
    read_file_projection(tc)
  end

  defp projected_size(%ToolCall{name: "execute_command"}, _ctx) do
    summary_baseline_size() * @safety_padding
  end

  defp projected_size(%ToolCall{name: "write_file"}, _ctx) do
    estimator_overhead("Successfully wrote N bytes to path.txt")
  end

  defp projected_size(%ToolCall{name: "edit"}, _ctx) do
    estimator_overhead("Replaced N occurrence(s) in path.txt")
  end

  defp projected_size(%ToolCall{name: "inspect_file"}, _ctx) do
    # inspect_file's largest historical output (~256 tokens of
    # stats); metric scale-up by repeating the format's longest line.
    estimator_overhead(
      "File: path/to/file.txt\n" <>
        "Type: ASCII text\n" <>
        "Size: N bytes\n" <>
        "Lines: N\n" <>
        "Non-blank lines: N\n" <>
        "Characters: N\n" <>
        "Max line length: N\n" <>
        "Estimated tokens: ~N"
    )
  end

  defp projected_size(%ToolCall{name: "context", arguments: %{"action" => "compact"}}, _ctx) do
    Logger.warning("context.compact reached BatchSizer preflight; should be intercepted upstream")

    estimator_overhead(
      "Compacted N messages into a summary. You now have ~N tokens of working space."
    )
  end

  defp projected_size(%ToolCall{name: "context"}, _ctx) do
    estimator_overhead("Context: N messages, ~X / Y tokens (Z%)")
  end

  defp projected_size(%ToolCall{}, _ctx) do
    estimator_overhead(String.duplicate("x", 8192))
  end

  # read_file projection: stat-then-cap, then estimate from byte size.
  # The actual File.read happens in Phase 2; preflight does the cheaper
  # File.stat so the batch can be refused before doing the read work.
  defp read_file_projection(%ToolCall{arguments: args} = _tc) do
    case args do
      %{"path" => path} when is_binary(path) and path != "" ->
        case File.stat(path) do
          {:ok, %{size: bytes}} when bytes > @max_read_file_bytes ->
            estimator_overhead(
              "File is #{div(bytes, 1_000_000)} MB; read_file is capped at " <>
                "100 MB. Use inspect_file or shell_cmd with head/tail/sed " <>
                "for partial reads."
            )

          {:ok, %{size: bytes}} ->
            estimator_overhead(byte_size_to_string(bytes))

          {:error, _reason} ->
            estimator_overhead("File not found")
        end

      _ ->
        estimator_overhead("Missing required arguments: path")
    end
  end

  # ---- Phase 2: execute the batch ----

  defp execute_one(%ToolCall{} = tc, ctx) do
    case LLMTools.execute_one(ctx.tools, tc, %{caps: ctx.caps}) do
      {:ok, content} -> {tc, :ok, ensure_non_empty(content)}
      {:error, reason} -> {tc, :error, ensure_non_empty(reason)}
    end
  end

  # ---- Phase 3: cook the raw results into final ToolResults ----
  #
  # For each execute_command result, decide keep-full or summarize
  # against the running total. Other tools are kept full.

  defp cook(executed, ctx) do
    limit = ctx.context_limit
    base = Estimator.estimate_messages(ctx.messages || [])
    usable = usable_remaining(ctx)
    initial = %{running: base + @preflight_reserve, limit: limit, usable: usable}

    {cooked, _final_acc} =
      Enum.map_reduce(executed, initial, fn entry, acc ->
        apply_one_with_acc(entry, ctx, acc)
      end)

    Enum.map(cooked, fn {tc, kind, content} ->
      %ToolResult{
        tool_call_id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
        content: content,
        is_error: kind == :error
      }
    end)
  end

  defp keep_full?(_tc, %{limit: nil}, _full_size), do: true

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
  #        * `execute_command` → write-to-tmp + path-and-head summary.
  #        * `read_file`        → return error result with size hint.
  #        * other tools        → log warning, keep full.
  #   3. Otherwise, decide keep-full vs. summarize against the
  #      running batch budget (`keep_full?/3`). The batch budget
  #      should always accommodate `full_size` post-preflight, but
  #      we fall back to the existing summary path for
  #      `execute_command` if it doesn't.
  defp apply_one_with_acc({tc, :ok, content}, ctx, acc) do
    full_size = Estimator.estimate(content) + per_message_overhead()
    cap = effective_max_result_tokens(tc, acc.usable)

    if cap && full_size > cap do
      handle_over_cap(tc, content, full_size, ctx, acc)
    else
      fit_in_batch_budget(tc, content, full_size, ctx, acc)
    end
  end

  defp apply_one_with_acc({tc, :error, reason}, _ctx, acc) do
    error_size = Estimator.estimate(reason) + per_message_overhead()
    {{tc, :error, reason}, advance(acc, error_size)}
  end

  # Decision for tools whose output fits the inline cap but might
  # overflow the running batch budget. Same per-tool routing as
  # `handle_over_cap/5`, but the trigger is the batch budget rather
  # than the inline cap.
  defp fit_in_batch_budget(tc, content, full_size, ctx, acc) do
    cond do
      keep_full?(tc, acc, full_size) ->
        {{tc, :ok, content}, advance(acc, full_size)}

      tc.name == "execute_command" ->
        {summary, summary_size} = build_summary_with_size(tc, content, ctx, acc)
        {{tc, :ok, summary}, advance(acc, summary_size)}

      true ->
        Logger.warning(
          "BatchSizer: #{tc.name} overflowed post-execution budget; keeping full anyway"
        )

        {{tc, :ok, content}, advance(acc, full_size)}
    end
  end

  # Per-tool routing when the inline cap is exceeded.
  # The cap was set by `effective_max_result_tokens/2` — the LLM
  # either asked for it (via `max_result_tokens`) or got the 80%
  # default. In either case, the LLM gets a *complete* answer
  # (either the full content via tmp + summary, or an explicit
  # error explaining the rejection) — never a truncated inline
  # version.
  defp handle_over_cap(%ToolCall{name: "execute_command"} = tc, content, _full_size, ctx, acc) do
    {summary, summary_size} = build_summary_with_size(tc, content, ctx, acc)
    {{tc, :ok, summary}, advance(acc, summary_size)}
  end

  defp handle_over_cap(%ToolCall{name: "read_file"} = tc, _content, full_size, _ctx, acc) do
    cap = effective_max_result_tokens(tc, acc.usable)
    error = "File is #{full_size} tokens which exceeds your requested limit of #{cap}."
    error_size = Estimator.estimate(error) + per_message_overhead()
    {{tc, :error, error}, advance(acc, error_size)}
  end

  defp handle_over_cap(%ToolCall{name: name} = tc, content, full_size, _ctx, acc) do
    Logger.warning("BatchSizer: #{name} exceeded max_result_tokens cap; keeping full anyway")
    {{tc, :ok, content}, advance(acc, full_size)}
  end

  # Build the deterministic summary template + return its
  # measured size. No hardcoded token constants — the path,
  # command, and head are all measured via `Estimator`.
  #
  # If the assembled summary would still overflow the running
  # budget (shouldn't happen given the preflight's 20% padding,
  # but defends against pathological cases), truncate to fit.
  defp build_summary_with_size(%ToolCall{} = tc, full_content, ctx, %{
         running: running,
         limit: limit
       }) do
    path = write_to_tmp(full_content, ctx) || "(temp file unavailable)"
    summary = build_summary_inner(tc, full_content, path)

    summary_size = Estimator.estimate(summary) + per_message_overhead()

    summary =
      if not is_nil(limit) and running + summary_size > limit do
        truncate_to_fit(summary, max(0, limit - running - per_message_overhead()))
      else
        summary
      end

    summary_size = Estimator.estimate(summary) + per_message_overhead()
    {summary, summary_size}
  end

  # Inner: builds the template structure.
  defp build_summary_inner(%ToolCall{} = tc, full_content, path) do
    command = Map.get(tc.arguments || %{}, "command", "")
    token_count = Estimator.estimate(full_content)

    line1 = "Command output of '#{command}' (#{token_count} tokens) saved to #{path}."

    head_budget = summary_head_budget(line1)
    head = head_text(full_content, head_budget)

    case head do
      "" -> line1
      h -> line1 <> "\n\n" <> h
    end
  end

  # Walk the output line-by-line and take as many whole lines as
  # fit within the budget. Budget derived from line1's size plus
  # some headroom — no hardcoded constants.
  defp summary_head_budget(line1) do
    line1_tokens = Estimator.estimate(line1)
    # Roughly 4× line1 size for head is a reasonable upper bound
    # that's still under the preflight's per-call padding.
    max(line1_tokens * 4, line1_tokens + 50)
  end

  defp head_text("", _budget), do: ""

  defp head_text(_content, budget) when budget <= 0, do: ""

  defp head_text(content, budget) do
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
  end

  defp truncate_to_fit(_text, target_tokens) when target_tokens <= 0, do: ""

  defp truncate_to_fit(text, target_tokens) do
    head_text(text, target_tokens)
  end

  defp write_to_tmp(full_content, ctx) do
    case Map.get(ctx, :tmp_path) || Map.get(ctx, "tmp_path") do
      nil ->
        nil

      dir ->
        path = Path.join(dir, "exec-#{random_token()}.txt")

        try do
          File.write!(path, full_content)
          path
        rescue
          _ -> nil
        end
    end
  end

  defp random_token do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp refuse_results(tool_calls, reason) do
    Enum.map(tool_calls, fn tc ->
      %ToolResult{
        tool_call_id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
        content: reason,
        is_error: true
      }
    end)
  end

  # ---- helpers ----

  defp estimator_overhead(s), do: Estimator.estimate(s) + per_message_overhead()

  defp summary_baseline_size do
    estimator_overhead("Command output of '' (~0 tokens) saved to (temp file unavailable).")
  end

  defp per_message_overhead, do: 10

  defp byte_size_to_string(bytes), do: String.duplicate("x", bytes)

  defp ensure_non_empty(""), do: @empty_output_placeholder
  defp ensure_non_empty(nil), do: @empty_output_placeholder
  defp ensure_non_empty(s) when is_binary(s), do: s
end
