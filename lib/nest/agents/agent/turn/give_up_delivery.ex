defmodule Nest.Agents.Agent.Turn.GiveUpDelivery do
  @moduledoc """
  Getting the reply give-up's notices to the requesters (issue #31 §1.6).

  `Machine.GiveUp` decides *that* the runtime gives up and words the notice;
  this module delivers it and reports a refusal. It is an effect module the
  executor calls, the way it calls `MessageAppender`.

  ## Why the resolution and the delivery are split

  Resolving a requester is a registry lookup (`Supervisor.get_running_agent/2`),
  deliberately *not* the supervisor's loading `get_agent/2`: a peer that sent us
  a query was running by definition, so a name that is not running now is a
  refusal — telling a requester no answer is coming must never resurrect a
  stopped peer and start a turn on it. The lookup runs in the agent's own
  process, so its refusals are reported before the settle continues.

  The *delivery* runs in a supervised task, because it is a call into the
  requester: two agents that queried each other, or one that queried itself,
  would otherwise block each other's settle for the call timeout.

  Either way the executor discharges the debt synchronously — the give-up has
  happened whatever the delivery does — and a refusal is logged and broadcast as
  a `chat:notification`, so the operator sees the refusal as well as the log. A give-up
  that cannot reach its requester is never swallowed: the runtime is dropping an
  obligation, and the requester would otherwise wait on an answer that is not
  coming.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.GiveUp
  alias Nest.Agents.Agent.Timeline

  # How long the stop path will wait for a child to answer a state read or write.
  # The synchronous stop (a user Stop, an archive, a parent stopping its
  # children) runs this per child, so the default 5 s of `:sys.get_state/1`
  # would let one unresponsive child delay a Stop by 5 s. A child that cannot
  # answer in a second is not going to have its debt given up: the debt is
  # logged as lost by its `terminate/2` instead, which is the accepted
  # disposition for a process that is going away (issue #31 decision 12).
  @state_timeout 1_000

  @doc """
  Give up the replies `pid` still owes, before it is stopped.

  A stop or an archive *ends* the agent (issue #31 decision 12), so its peers
  hear that no answer is coming before the process is gone. That give-up cannot
  come from the machine — there is no settle left to emit the action — and
  `Agent.terminate/2` is the wrong home for it: a terminate during a supervisor
  shutdown must not read the database or start processes. So the supervisor's
  stop path (`Nest.Agents.Supervisor.stop_one/3`, which both `stop_agent/2` and
  `archive_agent/2` go through, passing the reason they want logged) calls this
  first.

  A *reload* is the accepted loss instead: the agent comes back with a fresh
  machine, and `Inbox.log_lost_replies/1` records what went with the old one.

  Never raises and never blocks a dying process for long: the state read is
  bounded by `@state_timeout` (a child that does not answer in time has its debt
  reported as lost instead), the resolution happens here, and the deliveries run
  in a task.
  """
  @spec give_up_before_stop(pid(), atom()) :: :ok
  def give_up_before_stop(pid, reason) do
    if pid == self() do
      # The agent is archiving or stopping itself, so reading its own state
      # through `:sys` would deadlock it against itself. Its `terminate/2`
      # records the loss instead (`Inbox.log_lost_replies/1`).
      :ok
    else
      state = :sys.get_state(pid, @state_timeout)

      case Machine.owed_senders(state.live.machine) do
        [] -> :ok
        senders -> give_up(pid, state, senders, reason)
      end
    end
  rescue
    # A process that is already dying, a state shape this cannot read, or a
    # child that did not answer the read inside the bounded timeout: the stop
    # must still happen, and the debt is then reported as lost by the
    # `terminate/2` that follows.
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Tell the requesters, then discharge the debt on the way out, exactly as the
  # executor's `{:give_up_replies, _}` action does. Without the discharge the
  # terminate that follows would report the peers as lost
  # (`Inbox.log_lost_replies/1`) when they have just been told.
  #
  # Exactly the senders that were told, not the whole map: the read and the
  # write are two system messages, so a `:query` can be delivered in between.
  # Its debt belongs to a requester that has *not* been told anything, and
  # `discharge_all/1` would erase it with no notice — leaving the requester
  # waiting and `terminate/2` with an empty map to report.
  defp give_up(pid, state, senders, reason) do
    deliver(state, senders, reason)

    :sys.replace_state(
      pid,
      fn state ->
        machine = Enum.reduce(senders, state.live.machine, &Machine.discharge_reply(&2, &1))
        %{state | live: %{state.live | machine: machine}}
      end,
      @state_timeout
    )

    :ok
  end

  @doc """
  Tell every requester in `senders` that no answer is coming. Never raises: a
  give-up must not take the giving-up agent's settle down with it.
  """
  @spec deliver(Agent.t(), [String.t()], atom()) :: :ok
  def deliver(state, senders, reason) do
    text = GiveUp.notice_text(state.name)
    targets = Enum.flat_map(senders, &resolve(state, &1, reason))

    if targets != [], do: start_delivery(state, targets, text, reason)
    :ok
  end

  # A requester that cannot be resolved is a refusal, not a silent drop.
  defp resolve(state, sender, reason) do
    case Nest.Agents.Supervisor.get_running_agent(state.space_id, sender) do
      {:ok, pid} -> [{sender, pid}]
      {:error, why} -> refuse(state, sender, reason, why)
    end
  rescue
    error -> refuse(state, sender, reason, {:error, error})
  catch
    :exit, why -> refuse(state, sender, reason, {:exit, why})
  end

  defp refuse(state, sender, reason, why) do
    log_failure(state.space_id, state.name, sender, reason, why)
    []
  end

  defp start_delivery(state, targets, text, reason) do
    agent_pid = self()
    space_id = state.space_id
    name = state.name

    case Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
           Process.put(:"$callers", [agent_pid])
           Enum.each(targets, &deliver_one(space_id, name, &1, text, reason))
         end) do
      {:ok, _pid} ->
        :ok

      {:error, why} ->
        # No task means no notice for any of them: report each requester by
        # name, so the log and the banner name the peers that were not told.
        Enum.each(targets, fn {sender, _pid} -> refuse(state, sender, reason, why) end)
    end
  end

  defp deliver_one(space_id, name, {sender, pid}, text, reason) do
    case Agent.deliver_message(pid, name, text, :notice) do
      {:ok, _disposition} -> :ok
      {:error, why} -> log_failure(space_id, name, sender, reason, why)
    end
  rescue
    # A raise here must not take the remaining notices with it: the debt is
    # already discharged, so a requester this task never reports would wait on
    # an answer that is not coming.
    error -> log_failure(space_id, name, sender, reason, {:error, error})
  catch
    # The requester can die between the registry lookup and the call.
    :exit, why -> log_failure(space_id, name, sender, reason, {:exit, why})
    :throw, why -> log_failure(space_id, name, sender, reason, {:throw, why})
  end

  defp log_failure(space_id, name, sender, reason, why) do
    Logger.warning(
      "[agent:#{name}] reply give-up (#{reason}) could not reach #{sender}: #{inspect(why)}"
    )

    # The refusal is the one place a give-up is known to have failed, so it is
    # recorded here rather than inferred from a missing `gave_up` event.
    Timeline.give_up_refused(space_id, name, sender, why)

    Broadcasts.notification(space_id, name, %{
      type: "reply_give_up_failed",
      message: "Could not tell #{sender} that no reply is coming: #{GiveUp.failure_reason(why)}."
    })
  end
end
