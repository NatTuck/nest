defmodule Nest.Agents.Agent.Machine.Compaction do
  @moduledoc """
  Pure compaction staging/resume/commit decisions.

  Split out of `Machine.Transitions` to keep that module within the
  file-length budget. `stage/3` runs the loop-breaker and plans the
  request; `resume/1` dispatches the carried entry after a commit; and
  `compaction_failed/3` enters the retryable blocked state.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.WorkspaceHandler

  @max_consecutive_compactions 3

  @doc "Stage a compaction turn (loop-breaker checked)."
  @spec stage(Machine.t(), Machine.entry() | nil, Machine.entry() | nil) ::
          {:ok, [term()], Machine.t()}
  def stage(m, carried_entry, pending_user) do
    count = m.loop_count + 1

    if count > @max_consecutive_compactions do
      machine = Phase.enter_blocked(m, :compaction_loop_detected)
      reason = "compaction isn't reducing the conversation"

      {:ok,
       [
         {:broadcast, {:compaction_loop, reason, m.loop_count, @max_consecutive_compactions}, nil}
       ], machine}
    else
      m = %{m | loop_count: count, pending_user_message: pending_user || m.pending_user_message}
      do_stage(m, carried_entry)
    end
  end

  defp do_stage(m, carried_entry) do
    case Dispatch.compaction_plan(m) do
      {:ok, staged} ->
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

      {:error, :system_oversized} ->
        machine = Phase.enter_blocked(m, :context_overflow)
        {:ok, [{:broadcast, {:overflow, :system_oversized, "compact"}, nil}], machine}

      {:error, :reserve_exhausted} ->
        machine = Phase.enter(m, :chat, :idle)
        {:ok, [{:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}], machine}
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

    cond do
      match?({:assistant_response, _, _, _}, carried_entry) ->
        machine = Phase.enter_blocked(m, :compaction_failed)
        {:ok, [{:broadcast, {:compaction_error, msg}, nil}], machine}

      carried_entry != nil ->
        machine = resume_machine(m, carried_entry)
        {:ok, [{:broadcast, {:compaction_error, msg}, nil}, :iterate], machine}

      true ->
        machine = Phase.enter_blocked(m, :compaction_failed)
        {:ok, [{:broadcast, {:compaction_error, msg}, nil}], machine}
    end
  end

  @doc "Resume after a successful compaction commit."
  @spec resume(Machine.t()) :: {:ok, [term()], Machine.t()}
  def resume(%{entry: {:compaction, _staged, carried}} = m) do
    cond do
      not is_nil(m.work.pending_notice) ->
        resume_notice(m)

      match?({:assistant_response, _, _, _}, carried) ->
        machine = Phase.enter(%{m | entry: nil}, :chat, :idle)
        {:ok, [{:finalize, :clean}, {:drain_inbox}], machine}

      carried == nil ->
        resume_with_pending(m)

      true ->
        machine = resume_machine(m, carried)
        {:ok, [{:broadcast, :status, nil}, :iterate], machine}
    end
  end

  defp resume_with_pending(m) do
    case m.pending_user_message do
      nil ->
        machine = Phase.enter(%{m | entry: nil}, :chat, :idle)
        {:ok, [{:finalize, :clean}, {:drain_inbox}], machine}

      entry ->
        user = Phase.unwrap_user(entry)

        # Append the held user at the terminal (idle) boundary so the
        # pairing bridge heals a summary_user -> user double role; the
        # following `:iterate` promotes the machine to `:generating` and
        # dispatches the request.
        machine = %{Phase.enter(%{m | entry: entry}, :chat, :idle) | pending_user_message: nil}
        {:ok, [{:append, user}, :iterate], machine}
    end
  end

  defp resume_notice(m) do
    pair = WorkspaceHandler.notice_pair(m.work.pending_notice)

    machine = Phase.enter(%{m | entry: nil, work: %{m.work | pending_notice: nil}}, :chat, :idle)
    {:ok, [{:append_many, pair}, {:drain_inbox}], machine}
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
