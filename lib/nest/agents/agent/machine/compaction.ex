defmodule Nest.Agents.Agent.Machine.Compaction do
  @moduledoc """
  Pure compaction staging/resume/commit decisions.

  Split out of `Machine.Transitions` to keep that module within the
  file-length budget. `stage/3` runs the loop-breaker and plans the
  request; `resume/1` dispatches the carried entry after a commit; and
  `compaction_failed/3` enters the retryable blocked state.

  ## Give-up paths and the drain shapes

  Every `stage/3` caller can hit `{:error, :reserve_exhausted}`, and each arm
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
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.ReplyReminder
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.WorkspaceHandler

  @max_consecutive_compactions 3

  @doc "Stage a compaction turn (loop-breaker checked)."
  @spec stage(Machine.t(), Machine.entry() | nil, Machine.entry() | nil) ::
          {:ok, [term()], Machine.t()}
  def stage(m, carried_entry, pending_user) do
    count = m.loop_count + 1

    if count > @max_consecutive_compactions do
      reason = "compaction isn't reducing the conversation"

      Phase.block(m, :compaction_loop_detected, :compaction_loop, [
        {:broadcast, {:compaction_loop, reason, m.loop_count, @max_consecutive_compactions}, nil}
      ])
    else
      m = %{m | loop_count: count, pending_user_message: pending_user || m.pending_user_message}
      do_stage(m, carried_entry)
    end
  end

  defp do_stage(m, carried_entry) do
    case Dispatch.compaction_plan(m) do
      {:ok, staged} ->
        stage_request(m, staged, carried_entry)

      {:error, :system_oversized} ->
        Phase.block(m, :context_overflow, :system_oversized, [
          {:broadcast, {:overflow, :system_oversized, "compact"}, nil}
        ])

      {:error, :reserve_exhausted} ->
        reserve_exhausted(m)
    end
  end

  defp stage_request(m, staged, carried_entry) do
    provisional = m.work.ctx.next_message_index + length(staged)

    machine =
      Phase.enter(
        %{m | entry: {:compaction, staged, carried_entry}},
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
            force_finalize: false,
            active_message_index: provisional
        }
    }

    {:ok, [:iterate], machine}
  end

  # `:reserve_exhausted` means the model cannot fit the system prompt plus the
  # compaction request into its reserve, so re-draining would re-run
  # `start_chat/3` → `:needs_compaction` → `stage/3` → here in a tight
  # synchronous loop. Each arm keeps the message that caused the attempt on a
  # wire payload instead of stranding it (issue #29).
  defp reserve_exhausted(m) do
    overflow = {:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}

    cond do
      # The chat-request arm: the built message is parked on the machine and no
      # queue holds it, so append it (the `:loop_ack` precedent) before
      # anything else, and clear the slot so a later resume cannot append it
      # twice. Deliberately no trailing `{:drain_inbox}`: with a non-empty
      # queue a drain would re-preflight → `start_chat/3` →
      # `:needs_compaction` → `stage/3` → this branch again.
      (user = Phase.held_user(m)) != nil ->
        Phase.rest(%{m | pending_user_message: nil}, :chat, :reserve_exhausted, [
          overflow,
          {:append, {:user, user}}
        ])

      # The inbox arm: under peek-then-consume (#26) the drain never consumed
      # the entries, so they are still queued and visible — and a drain here
      # would re-stage the failing compaction. Block instead; `{:unblocked}`
      # re-attempts the drain once the operator has acted.
      Boundary.inbox_count(m.work.ctx) > 0 ->
        Phase.block(m, :context_overflow, :reserve_exhausted, [overflow])

      # Nothing queued and nothing parked (a manual `/compact`, the workspace
      # notice, a retry with an empty inbox): rest in `:idle`, as before. (The
      # arms above are reachable from `:compaction_failed` and `:generating`
      # too, so they *enter* `:idle` rather than "stay" there.)
      true ->
        Phase.rest(m, :chat, :reserve_exhausted, [overflow])
    end
  end

  @doc "Build the commit action set for a successful compactor response."
  @spec commit_compaction(Machine.t(), Nest.LLM.RunResponse.t()) :: {:ok, [term()], Machine.t()}
  def commit_compaction(m, response) do
    {:compaction, staged, carried_entry} = m.entry
    {assistant_msg, sequences} = Response.assistant_with_log(m, response)

    data = %{
      summary_text: response.text || "",
      staged: staged,
      summary_assistant: assistant_msg,
      carried_entry: carried_entry
    }

    actions = [
      {:merge_metrics, response.usage},
      {:set_api_log_sequences, sequences},
      {:commit_compaction, data}
    ]

    {:ok, actions, Phase.enter(m, :compaction, :committing)}
  end

  @doc "The carried entry of a compaction machine, or nil."
  @spec carried(Machine.t()) :: Machine.entry() | nil
  def carried(%{entry: {:compaction, _staged, carried}}), do: carried
  def carried(%{entry: _}), do: nil

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
  def resume(%{entry: {:compaction, _staged, carried}} = m) do
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
        reminder = ContextReminder.build_user_notice(text, nil)
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
