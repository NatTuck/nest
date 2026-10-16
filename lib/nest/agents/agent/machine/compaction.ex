defmodule Nest.Agents.Agent.Machine.Compaction do
  @moduledoc """
  Pure compaction staging/resume/commit decisions.

  Split out of `Machine.Transitions` to keep that module within the
  file-length budget. `stage/2` runs the loop-breaker and plans the
  request; `resume/1` dispatches the carried entry after a commit; and
  `compaction_failed/3` enters the retryable blocked state.

  ## Give-up paths and the drain shapes

  Every `stage/2` caller can hit `{:error, :reserve_exhausted}`, and each arm
  of that branch keeps the message that caused the attempt on a wire payload
  (issue #29) rather than stranding it. The shapes it and the loop breaker
  use are the action vocabulary's two ways of disposing of a queued message
  without starting a turn from it:

    * `{:append, {:user, user}}` — the machine already holds the built
      message (the chat-request path parked it);
    * `{:drain_inbox, :append}` — the message is still queued (the drain path
      under peek-then-consume), so the executor builds it from the batch,
      appends it, and consumes it without `start_chat/3`. A bare
      `{:drain_inbox}` would re-preflight the batch and re-enter the
      compaction decision that just gave up.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Boundary
  alias Nest.Agents.Agent.Machine.Failure
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.ReplyReminder
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.LLM.Preflight
  alias Nest.Messages.NoticeTag

  @max_consecutive_compactions 3

  @doc """
  Stage a compaction turn (loop-breaker checked).

  `carried_entry` is the entry the compaction carries across the commit: the
  refused batch's `{:tool_call, …}` continuation on the preflight path, the
  `{:compact_resume, …}` a `context-compact` call leaves behind, or `nil` for a
  turn that has nothing in flight. There is deliberately no
  parameter for a pending user message — the chat-request path parks it on the
  machine (`%{m | pending_user_message: entry}`) before calling this, and the
  drain path under peek-then-consume (#26) never parks one at all, so a
  parameter for it was always `nil` at every call site.
  """
  @spec stage(Machine.t(), Machine.entry() | nil) :: {:ok, [term()], Machine.t()}
  def stage(m, carried_entry) do
    count = m.loop_count + 1

    case loop_breaker(m, count) do
      {:blocked, result} ->
        result

      :ok ->
        do_stage(%{m | loop_count: count}, carried_entry)
    end
  end

  @doc """
  Retry a failed compaction by **re-sending the existing sequence**.

  Nothing is appended and nothing is re-planned. The request message is
  already committed, so a second plan would add a *second* request with a
  different remaining-token count and double-count the request's own size
  (`Dispatch.compaction_plan/1` computes the budget against the messages as
  they are before the append, precisely so that cannot happen). The
  compactor is simply asked again over the same messages, which is why a
  retry cannot change the request.

  The loop breaker still runs, so retries stay bounded: it is the only exit
  from a compaction that keeps failing, since a committed request row can
  never be removed.
  """
  @spec retry(Machine.t()) :: {:ok, [term()], Machine.t()}
  def retry(m) do
    count = m.loop_count + 1

    case loop_breaker(m, count) do
      {:blocked, result} -> result
      :ok -> resend(m, count)
    end
  end

  defp resend(m, count) do
    carried =
      case m.mid_turn_entry do
        nil -> nil
        entry -> entry.entry
      end

    machine =
      Phase.enter(
        %{m | loop_count: count, mid_turn_entry: nil, entry: {:compaction, carried}},
        :compaction,
        :generating,
        :http
      )

    machine = %{machine | work: %{machine.work | iteration: 0, force_finalize: false}}

    {:ok, [:iterate], machine}
  end

  defp loop_breaker(m, count) do
    if count > @max_consecutive_compactions do
      reason = "compaction isn't reducing the conversation"

      {:blocked,
       Phase.block(m, :compaction_loop_detected, :compaction_loop, [
         {:broadcast, {:compaction_loop, reason, m.loop_count, @max_consecutive_compactions}, nil}
       ])}
    else
      :ok
    end
  end

  defp do_stage(m, carried_entry) do
    case Dispatch.compaction_plan(m) do
      {:ok, request_message} ->
        enter_compaction(m, request_message, carried_entry)

      {:error, :system_oversized} ->
        Phase.block(m, :context_overflow, :system_oversized, [
          {:broadcast, {:overflow, :system_oversized, "compact"}, nil},
          compaction_not_started(
            "Compaction did not start: the system prompt is too large for the " <>
              "model's context window."
          )
        ])

      {:error, :reserve_exhausted} ->
        reserve_exhausted(m)
    end
  end

  # The compaction did not start. The `context-compact` call and its synthetic
  # `"Compacting now."` result are already in the transcript — they are
  # persisted before the plan runs, so a staging failure cannot un-write them —
  # and a claim nothing follows up on is what this project's transparency rule
  # exists to prevent. The broadcast tells a connected UI; this row tells the
  # agent and anyone reading the transcript.
  #
  # Deliberately not a second tool result: that would answer the same tool call
  # twice, which the wire's pairing rule rejects.
  defp compaction_not_started(reason) do
    {:append, ContextReminder.build_user_notice(NoticeTag.tag(reason), nil)}
  end

  # The request message is appended *before* the compactor is dispatched, so
  # it is committed history from the moment it is sent. The compactor's
  # request is therefore the ordinary message list, and a failure leaves the
  # request visible instead of discarding a sequence the model has already
  # seen.
  #
  # `active_message_index` is deliberately not set here. It is the index the
  # *summary* will be stamped with, and the append that precedes the request
  # has not happened yet — so the only honest value is read at `:iterate`
  # (`Transitions`, `kind: :compaction`) from the refreshed context. The
  # append path also inserts and persists the pairing bridge if the tail
  # needs one, which is why no index arithmetic is done here at all.
  defp enter_compaction(m, request_message, carried_entry) do
    machine =
      Phase.enter(
        %{m | entry: {:compaction, carried_entry}},
        :compaction,
        :generating,
        :http
      )

    machine = %{
      machine
      | work: %{
          machine.work
          | iteration: 0,
            max_iterations: Config.configured_max_tool_iterations(),
            force_finalize: false
        }
    }

    {:ok, [{:append, request_message}, :iterate], machine}
  end

  # `:reserve_exhausted` means the model cannot fit the system prompt plus the
  # compaction request into its reserve, so re-draining would re-run
  # `start_chat/3` → `:needs_compaction` → `stage/2` → here in a tight
  # synchronous loop. Each arm keeps the message that caused the attempt on a
  # wire payload instead of stranding it (issue #29).
  defp reserve_exhausted(m) do
    overflow = {:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}

    notice =
      compaction_not_started(
        "Compaction did not start: the system prompt plus the compaction request " <>
          "exceed the compaction reserve."
      )

    cond do
      # The chat-request arm: the built message is parked on the machine and no
      # queue holds it, so append it (the `:loop_ack` precedent) before
      # anything else, and clear the slot so a later resume cannot append it
      # twice. Deliberately no trailing `{:drain_inbox}`: with a non-empty
      # queue a drain would re-preflight → `start_chat/3` →
      # `:needs_compaction` → `stage/2` → this branch again.
      (user = Phase.held_user(m)) != nil ->
        Phase.rest(%{m | pending_user_message: nil}, :chat, :reserve_exhausted, [
          overflow,
          notice,
          {:append, {:user, user}}
        ])

      # The inbox arm: under peek-then-consume (#26) the drain never consumed
      # the entries, so they are still queued and visible — and a drain here
      # would re-stage the failing compaction. Block instead; `{:unblocked}`
      # re-attempts the drain once the operator has acted.
      Boundary.inbox_count(m.work.ctx) > 0 ->
        Phase.block(m, :context_overflow, :reserve_exhausted, [overflow, notice])

      # Nothing queued and nothing parked (a manual `/compact`, the workspace
      # notice, a retry with an empty inbox): rest in `:idle`, as before. (The
      # arms above are reachable from `:compaction_failed` and `:generating`
      # too, so they *enter* `:idle` rather than "stay" there.)
      true ->
        Phase.rest(m, :chat, :reserve_exhausted, [overflow, notice])
    end
  end

  @doc """
  Build the `{:commit_compaction, data}` payload — the one place its shape is
  defined.

  Two callers commit a compactor response: `commit_compaction/2` below (the
  live path, from the compaction turn's own transition table) and `Response`'s
  `:compaction` branch. Keeping a second copy of this map is how `:preserve`
  went missing from that branch — the executor's dot access raises on the
  missing key, so the divergence is loud, but only by luck. One builder cannot
  drift from itself.
  """
  @spec commit_data(Machine.t(), Nest.LLM.RunResponse.t()) :: {map(), map()}
  def commit_data(m, response) do
    {:compaction, carried_entry} = m.entry
    {assistant_msg, sequences} = Response.assistant_with_log(m, response)

    data = %{
      summary_text: response.text || "",
      summary_assistant: assistant_msg,
      carried_entry: carried_entry,
      preserve: m.work.preserve
    }

    {data, sequences}
  end

  @doc """
  Build the commit action set for a successful compactor response.

  The request message is already committed (the staging append), so this
  commits only the summary and its marker — and the bridge, if the append
  path inserted one, is already in the segment being archived.

  `preserve` rides along in the commit data: it is turn-scoped on `work`, and
  this is its last reader before the turn ends.
  """
  @spec commit_compaction(Machine.t(), Nest.LLM.RunResponse.t()) :: {:ok, [term()], Machine.t()}
  def commit_compaction(m, response) do
    {data, sequences} = commit_data(m, response)

    actions = [
      {:merge_metrics, response.usage},
      {:set_api_log_sequences, sequences},
      {:commit_compaction, data}
    ]

    {:ok, actions, Phase.enter(m, :compaction, :committing)}
  end

  @doc "The carried entry of a compaction machine, or nil."
  @spec carried(Machine.t()) :: Machine.entry() | nil
  def carried(%{entry: {:compaction, carried}}), do: carried
  def carried(%{entry: _}), do: nil

  # --- the `(kind: :compaction, phase: :generating)` transition table ---

  # `Machine.Transitions` dispatches every event for a machine generating a
  # compaction here, so the compactor's result/error/death handling and its
  # request dispatch sit with the rest of the compaction decisions. An event
  # this slice does not name answers `{:ignore, :not_applicable, m}` — exactly
  # what `Transitions`' default clause gave it before the split.
  @doc """
  Apply one event to a machine generating a compaction.

  Split out of `Machine.Transitions` for the credo file cap; pure like the rest
  of the transition table.
  """
  @spec transition(Machine.t(), term()) ::
          {:ok, [term()], Machine.t()} | {:ignore, atom(), Machine.t()}
  def transition(%Machine{} = m, {:http_ok, ref, response}) do
    if Machine.valid_ref?(m, ref),
      do: commit_compaction(m, response),
      else: {:ignore, :stale_result, m}
  end

  def transition(%Machine{} = m, {:compaction_error, reason, carried}) do
    compaction_failed(m, reason, carried)
  end

  def transition(%Machine{} = m, {:http_error, ref, reason}) do
    if Machine.valid_ref?(m, ref),
      do: compaction_failed(m, reason, carried(m)),
      else: {:ignore, :stale_result, m}
  end

  def transition(%Machine{} = m, {:worker_crashed, ref, ex, _st}) do
    if Machine.valid_ref?(m, ref),
      do: compaction_failed(m, ex, carried(m)),
      else: {:ignore, :stale_result, m}
  end

  # The request was **not** committed, so nothing may be sent: a refused append
  # is a `{:follow, …}` that halts the action list and the phase has no worker
  # left to answer, so the default clause would wedge the agent forever.
  # `Failure.fail_turn` is the visible failure instead.
  #
  # Deliberately *not* `:compaction_failed`: a retry re-sends the committed
  # sequence, and this sequence has no request row in it — the compactor would
  # be asked to summarize with no instruction. Unreachable by construction (the
  # `{:refuse, _}` clause heals the tail before staging); it is the backstop.
  def transition(%Machine{} = m, {:append_result, :invalid, reason}) do
    Failure.fail_turn(m, %ArgumentError{message: reason}, [])
  end

  # Unreachable by construction, and deliberately NOT a `fail_turn`: `:stale`
  # comes only from `Repair.classify_live/2`'s `tool_result?` arm, and the
  # compaction request is a `{:user, _}` — so a stale outcome here would mean
  # the request was not what this phase appends. Ignoring it matches the
  # `:generating`/`:chat` sibling and cannot mask a failed append, because
  # `:invalid` (the only outcome a user append can actually produce) is above.
  def transition(%Machine{} = m, {:append_result, :stale, _}),
    do: {:ignore, :stale_append, m}

  # The compaction request is committed; spawn the compactor over the
  # ordinary message list.
  def transition(%Machine{} = m, :iterate) do
    messages = Dispatch.request_messages(m)

    case Preflight.validate_request(messages) do
      :ok ->
        # The *summary's* index, from the context `prepare/1` just rebuilt: the
        # request and any bridge are already committed with real indices, so the
        # next free index is where the summary lands. Written onto `work` as
        # well as emitted, like `do_dispatch_http/1`, because
        # `Response.assistant_with_log/2` stamps the response's API-log id from
        # it — unset, the compactor's log carried the last chat dispatch's index.
        provisional = m.work.ctx.next_message_index
        ctx = Dispatch.spawn_ctx(m, messages)
        machine = %{m | work: %{m.work | active_message_index: provisional}}
        {:ok, [{:set_streaming, provisional}, {:stage_compaction, ctx}], machine}

      {:error, violations} ->
        compaction_failed(m, Preflight.format_violations(violations), carried(m))
    end
  end

  def transition(%Machine{} = m, _event), do: {:ignore, :not_applicable, m}

  @doc "Enter the retryable `:compaction_failed` state after a failure."
  @spec compaction_failed(Machine.t(), term(), Machine.entry() | nil) ::
          {:ok, [term()], Machine.t()}
  def compaction_failed(m, reason, carried_entry) do
    msg = "Compaction failed: #{format_failure(reason)}"
    error = {:broadcast, {:compaction_error, msg}, nil}

    cond do
      match?({:assistant_response, _, _, _}, carried_entry) ->
        Phase.block(m, :compaction_failed, :compaction_failed, [error])

      carried_entry != nil ->
        machine = resume_machine(m, carried_entry)
        {:ok, [error, :iterate], machine}

      true ->
        Phase.block(m, :compaction_failed, :compaction_failed, [error])
    end
  end

  @doc "Resume after a successful compaction commit."
  @spec resume(Machine.t()) :: {:ok, [term()], Machine.t()}
  def resume(%{entry: {:compaction, carried}} = m) do
    cond do
      not is_nil(m.work.pending_notice) ->
        resume_notice(m)

      match?({:assistant_response, _, _, _}, carried) ->
        resume_carried_reply(m, carried)

      carried == nil ->
        resume_with_pending(m)

      true ->
        machine = resume_machine(m, carried)
        {:ok, [{:broadcast, :status, nil}, :iterate], machine}
    end
  end

  # The reply was carried across the compaction because persisting it would have
  # spent the reserve. The commit put it in the active segment, so the turn is
  # not over and the reply gate gets the same say it gets at any would-be-idle
  # settle: remind (and continue the turn), or rest — which gives the debt up.
  defp resume_carried_reply(m, carried) do
    m = %{m | entry: nil}

    # The reply is already in the committed segment, so the machine's own
    # messages are what the reminder would be appended to.
    case ReplyReminder.decision(m) do
      {:remind, text, m} ->
        reminder = ContextReminder.build_user_notice(NoticeTag.tag(text), nil)
        machine = Phase.init_turn(Phase.enter(m, :chat, :generating, :http), carried)
        {:ok, [{:append, reminder}, :iterate], machine}

      :settle ->
        Phase.rest(m, :chat, :compaction_carry, [{:finalize, :clean}, {:drain_inbox}])
    end
  end

  defp resume_with_pending(m) do
    case m.pending_user_message do
      nil ->
        if Boundary.inbox_count(m.work.ctx) > 0 do
          # Peek-then-consume (#26): the message that needed this compaction is
          # still queued, so re-drain it in place. Entering `:idle` first would
          # broadcast a transient idle (which resolves an idle-based wait with
          # the pre-delivery answer) and `{:finalize, :clean}` a turn that is
          # really continuing — the #15 property this path must preserve.
          machine = Phase.enter(%{m | entry: nil}, :chat, :generating, :http)
          {:ok, [{:drain_inbox}], machine}
        else
          Phase.rest(%{m | entry: nil}, :chat, :resume, [{:finalize, :clean}, {:drain_inbox}])
        end

      entry ->
        user = Phase.unwrap_user(entry)

        # The committed segment already ends on the compaction ack
        # (`Turn.Commit.ensure_assistant_tail/1`), so this append lands on
        # an assistant tail and `pairing_bridge/2` has nothing to repair.
        # The `:iterate` dispatches the request.
        #
        # Deliberately not a rest: the turn continues on the held message, so
        # the reply this machine may still owe stays live and the gate owns the
        # real settle. Resting here would broadcast a transient idle *and* give
        # the debt up for a turn that is about to carry on. (`entry` rides along
        # because the compaction's own resume may not have cleared it.)
        machine =
          Phase.enter(%{m | entry: entry}, :chat, :generating, :http)
          |> Map.put(:pending_user_message, nil)

        {:ok, [{:append, user}, :iterate], machine}
    end
  end

  defp resume_notice(m) do
    pair = WorkspaceHandler.notice_pair(m.work.pending_notice)

    Phase.rest(
      %{m | entry: nil, work: %{m.work | pending_notice: nil}},
      :chat,
      :workspace_notice,
      [{:append_many, pair}, {:drain_inbox}]
    )
  end

  defp resume_machine(m, entry) do
    machine =
      Phase.enter(
        %{m | entry: entry, work: %{m.work | pending_notice: nil}},
        :chat,
        :generating,
        :http
      )

    Phase.init_turn(machine, entry)
  end

  defp format_failure(:reserve_exhausted),
    do: "system prompt + compaction request exceed the reserve"

  defp format_failure(:consecutive_compaction_threshold),
    do: "compaction isn't reducing the conversation"

  defp format_failure(:llm_returned_empty), do: "LLM returned empty summary"
  defp format_failure(reason) when is_binary(reason), do: reason
  defp format_failure(other), do: inspect(other)
end
