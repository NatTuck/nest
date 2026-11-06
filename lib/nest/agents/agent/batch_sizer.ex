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
  ## Phase 3: One admission for every result

  Each result goes through `Nest.Agents.Agent.ResultPolicy`: it is kept whole
  when it fits `min(requested, budget)`, written to the agent's scratch dir and
  replaced by a pointer + preview when it does not, or refused with a size hint
  when the content is already at an address the model named. A success, an
  error, a cancellation and a wait are the same question, so they take the same
  path.

  `budget` is what is left after the results admitted before it, so a batch
  shares one allowance and no result — and no batch — can exceed the window.

  ## `max_result_tokens`

  The LLM may pass `max_result_tokens` to choose the inline size for a call. It
  is the `requested` half of `min(requested, budget)`: above the tool's default
  is allowed, and only the remaining budget caps it. See `ResultPolicy`.

  `ToolLoop` runs `execute/2` for the regular tools, then admits the merged
  regular + sub-agent entries once via `cook/2`, so the whole batch shares one
  budget across tool families.

  When `ctx.context_limit` is `nil` (or non-positive), `preflight`
  matches no clause and raises — the limit is never optional, and a
  tool batch is never processed without a known context window.
  """

  alias Nest.Agents.Agent.BatchSizer.FilePolicy
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Agents.Agent.ResultPolicy
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
  admission. Returns a list of `ToolResult` structs in
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

      # The byte ceiling, and only for a batch that **adds** media: a media-free
      # batch cannot push the request past the provider's limit (text is bounded
      # by the token window, and no window holds 16 MB of it), so refusing one
      # would be a false refusal of ordinary work in a media-heavy conversation.
      #
      # Compaction fixes a refusal here, so the caller may route it into one; a
      # refusal compaction cannot fix is the shape that loops, and this is not.
      media > 0 and not RequestSize.within?(messages, media) ->
        {:refuse, request_bytes_refusal(RequestSize.bytes(messages) + media)}

      true ->
        {:fits, projected}
    end
  end

  # One stat pass for both numbers (issue #48): the token projection and the
  # media bytes come from the same memoized sizes.
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
           # they default to `{:unknown, :unknown}` and operate on the
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
  Turn raw `entry`s into `ToolResult`s, applying the admission
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
    budget =
      case ResultPolicy.window(ctx) do
        {:ok, left} -> left
        :none -> 0
      end

    {cooked, _left} = Enum.map_reduce(entries, budget, &admit_one(&1, ctx, &2))
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

  defp spend(budget, size) when is_integer(budget) and is_integer(size),
    do: max(0, budget - size)

  defp message_size(text), do: Estimator.estimate(text) + per_message_overhead()

  # One admission for every result, whatever its kind: a success, an error, a
  # cancellation and a wait are the same content question, so they take the same
  # path. Only the payload's *type* differs below, and only the two non-text
  # ones need anything the policy cannot say.
  #
  # `budget` is what is left after the results admitted before this one, so a
  # batch shares one allowance: the running total is the budget itself, which is
  # why there is no second "does it still fit the batch" check.
  defp admit_one({tc, :ok, {:media, part}}, _ctx, budget) do
    price = Estimator.estimate_media(part) + per_message_overhead()
    limit = ResultPolicy.limit(tc, budget)

    if price <= limit do
      {{tc, :ok, {:media, part}}, spend(budget, price)}
    else
      error = media_over_cap_error(part, price, limit)
      {{tc, :error, error}, spend(budget, message_size(error))}
    end
  end

  defp admit_one({tc, kind, content}, ctx, budget) when is_binary(content) do
    if Sanitize.text?(content),
      do: admit_text(tc, kind, content, ctx, budget),
      else: admit_binary(tc, kind, content, ctx, budget)
  end

  # The one place a tool result is kept, filed, or refused.
  defp admit_text(tc, kind, content, ctx, budget) do
    limit = ResultPolicy.limit(tc, budget)

    case ResultPolicy.admit(content, limit, ResultPolicy.on_over(tc.name)) do
      {:inline, size} ->
        {{tc, kind, content}, spend(budget, size + per_message_overhead())}

      {:file, size} ->
        substitute(tc, kind, content, ctx, budget, size)

      {:refuse, size} ->
        error = ResultPolicy.refusal(size, limit, tc.name)
        {{tc, :error, error}, spend(budget, message_size(error))}
    end
  end

  # A result too large to inline goes to the scratch dir and comes back as a
  # pointer + preview. When that write fails there is no quiet fallback: the
  # result becomes an error saying so, because the alternative is inlining it
  # (and relying on the send gate) or dropping it silently.
  defp substitute(tc, kind, content, ctx, budget, size) do
    case Overflow.substitute(content, ctx, ResultPolicy.label(tc.name), write_prefix(tc.name)) do
      {:ok, pointer} ->
        {{tc, kind, pointer}, spend(budget, message_size(pointer))}

      :error ->
        error = ResultPolicy.offload_failure(size)
        {{tc, :error, error}, spend(budget, message_size(error))}
    end
  end

  # Non-text output (invalid UTF-8, or NUL that jsonb rejects) never goes inline
  # raw: it is written and described by a pointer, so the model is told the
  # result is binary and where the bytes are. A tiny binary also gets a lossy
  # view inline, which is the only case where any of its bytes reach the model.
  defp admit_binary(tc, kind, content, ctx, budget) do
    bytes = byte_size(content)
    label = "#{ResultPolicy.label(tc.name)} (non-text binary output, #{bytes} bytes)"

    case Overflow.write(content, ctx, write_prefix(tc.name), "txt") do
      nil ->
        error = ResultPolicy.offload_failure(message_size(content))
        {{tc, :error, error}, spend(budget, message_size(error))}

      path ->
        pointer = "#{label} saved to #{path}."

        inline =
          if bytes <= @small_binary_max_bytes, do: binary_view(pointer, content), else: pointer

        {{tc, kind, inline}, spend(budget, message_size(inline))}
    end
  end

  # The lossy view of a small binary, appended to its pointer. There is no
  # empty-view branch: `to_valid_utf8/1` never answers `""` for a non-empty
  # binary — every byte it cannot read becomes a replacement character — and an
  # empty one is text, so it never reaches `admit_binary/5` at all.
  defp binary_view(pointer, content), do: pointer <> "\n\n" <> Overflow.to_valid_utf8(content)

  # Media gets its own wording because the remedy differs: the model cannot
  # retry with a smaller `max_result_tokens` and get a summarized image, so it
  # has to be told the attachment was dropped rather than shortened.
  defp media_over_cap_error(%Part.Media{} = part, price, limit) do
    "File is #{human_bytes(part.bytes)} of #{part.media_type} (~#{price} tokens), which " <>
      "exceeds your requested limit of #{limit}. Media cannot be summarized or " <>
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
