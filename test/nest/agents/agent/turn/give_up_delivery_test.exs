defmodule Nest.Agents.Agent.Turn.GiveUpDeliveryTest do
  @moduledoc """
  The give-up's delivery refusals (`Turn.GiveUpDelivery`).

  The debt is discharged whether or not the notice lands, so a refusal that was
  swallowed would leave a peer waiting forever: each one is logged and broadcast
  as a `chat:notification` naming the requester it could not reach.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.GiveUpDelivery
  alias Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  test "a requester whose inbox is full is reported, and the debt is discharged anyway" do
    {peer_pid, peer_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: AgentTestHelpers.programmer_vocation_id_for_test()
      })

    space_id = AgentTestHelpers.current_space_id()

    # The cap exists to bound a runaway peer producer, and the give-up is not
    # exempt from it: a full inbox refuses the notice.
    :sys.replace_state(peer_pid, fn state ->
      %{state | live: %{state.live | inbox: List.duplicate(entry(), 100)}}
    end)

    giver = giver(space_id)
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{giver.name}")

    # The notification is asserted inside the capture because it is broadcast
    # after the warning, which is what proves the warning landed.
    log =
      capture_log(fn ->
        assert :ok = GiveUpDelivery.deliver(giver, [peer_name], :no_reminder)

        # The banner words the refusal the operator can act on, which the log
        # line does not have to.
        assert_receive {:chat_notification, %{type: "reply_give_up_failed", message: message}},
                       500

        assert message =~ "the agent's inbox is full"
      end)

    assert log =~ "reply give-up (no_reminder) could not reach #{peer_name}: :inbox_full"
  end

  test "a requester that dies between the lookup and the call is reported" do
    # No database involved: the lookup is stubbed, and only the notice and the
    # refusal report are real.
    space_id = 1
    dead = dead_pid()

    Mimic.stub(Nest.Agents.Supervisor, :get_running_agent, fn _space, _name -> {:ok, dead} end)
    giver = giver(space_id)
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{giver.name}")

    log =
      capture_log(fn ->
        assert :ok = GiveUpDelivery.deliver(giver, ["peer"], :stopped)
        assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 500
      end)

    assert log =~ "reply give-up (stopped) could not reach peer"
    assert log =~ "noproc"
  end

  test "a persisted peer that is not running is refused, not resurrected" do
    # The harness links the test process to the agent, so a test that stops one
    # must trap the exit and assert on it.
    Process.flag(:trap_exit, true)

    {peer_pid, peer_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: AgentTestHelpers.programmer_vocation_id_for_test()
      })

    space_id = AgentTestHelpers.current_space_id()

    # The peer is persisted but stopped: its row stays, its process goes.
    assert :ok = Nest.Agents.Supervisor.stop_agent(space_id, peer_name)
    assert_receive {:EXIT, ^peer_pid, :shutdown}, 500

    assert Eventually.eventually(
             fn -> Nest.Agents.Registry.lookup(space_id, peer_name) == {:error, :not_found} end,
             timeout: 500
           )

    assert {:ok, _row} = Nest.Persistence.fetch_agent(space_id, peer_name)

    giver = giver(space_id)
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{giver.name}")

    # A refused resolution must not start a delivery task at all: with no
    # targets, `deliver/3` never reaches `start_delivery/4`.
    Mimic.stub(Task.Supervisor, :start_child, fn _sup, _fun ->
      flunk("a refused resolution must not start a delivery task")
    end)

    log =
      capture_log(fn ->
        assert :ok = GiveUpDelivery.deliver(giver, [peer_name], :stopped)

        assert_receive {:chat_notification, %{type: "reply_give_up_failed", message: message}},
                       500

        assert message =~ peer_name
      end)

    # The refusal *reason* is pinned: a resolution that had loaded the peer
    # would have delivered to it — or failed to reach it for some other reason —
    # instead of refusing it as not running.
    assert log =~ "reply give-up (stopped) could not reach #{peer_name}: :not_found"

    # "Never resurrect a stopped peer": resolving through `get_agent/2` would
    # load the row and start a turn on it, so the refusal is what keeps the peer
    # gone — no process, no registry entry, nothing loaded.
    assert {:error, :not_found} = Nest.Agents.Supervisor.get_running_agent(space_id, peer_name)
    assert Nest.Agents.Registry.lookup(space_id, peer_name) == {:error, :not_found}
  end

  test "a delivery task that cannot be started names every requester it could not reach" do
    space_id = 1
    dead = dead_pid()

    Mimic.stub(Nest.Agents.Supervisor, :get_running_agent, fn _space, _name -> {:ok, dead} end)
    Mimic.stub(Task.Supervisor, :start_child, fn _sup, _fun -> {:error, :max_children} end)
    giver = giver(space_id)
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{giver.name}")

    log =
      capture_log(fn ->
        assert :ok = GiveUpDelivery.deliver(giver, ["peer-a", "peer-b"], :stopped)
        assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 500
        assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 500
      end)

    # One refusal per requester, each named: a comma-joined target list would
    # read as a single peer called "peer-a, peer-b".
    assert log =~ "could not reach peer-a: :max_children"
    assert log =~ "could not reach peer-b: :max_children"
  end

  describe "give_up_before_stop/2" do
    test "only the senders it told are discharged, so a debt incurred meanwhile survives" do
      # intentional: the read and the write are two system messages, so a
      # `:query` can be delivered in between. Its debt belongs to a requester
      # that was told nothing — `discharge_all/1` would erase it with no notice,
      # and the `terminate/2` that follows would report an empty map as lost.
      {pid, _name} = start_agent_owing(["peer"])

      Mimic.stub(Nest.Agents.Supervisor, :get_running_agent, fn _space, _sender ->
        # The in-between query: a debt on the agent from a requester this
        # give-up knows nothing about.
        :sys.replace_state(pid, fn state ->
          %{
            state
            | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["late"])}
          }
        end)

        {:error, :not_found}
      end)

      log =
        capture_log(fn ->
          assert :ok = GiveUpDelivery.give_up_before_stop(pid, :stopped)
        end)

      assert log =~ "reply give-up (stopped) could not reach peer: :not_found"

      # The sender that was told is gone; the one that arrived in the window is
      # still owed.
      assert Machine.owed_senders(:sys.get_state(pid).live.machine) == ["late"]

      # ...and the debt asserted above is cleared before the test ends, so the
      # agent's own teardown does not log a loss this test has already proved.
      clear_debt(pid)
    end

    test "an agent stopping itself reads no state of its own" do
      {pid, _name} = start_agent_owing(["peer"])

      # Called *in the agent's own process*: reading its own state through `:sys`
      # would deadlock it against itself, so the arm is a no-op — the debt is
      # reported as lost by `terminate/2` (`Inbox.log_lost_replies/1`).
      :sys.replace_state(pid, fn state ->
        assert :ok = GiveUpDelivery.give_up_before_stop(self(), :stopped)
        state
      end)

      assert Machine.owed_senders(:sys.get_state(pid).live.machine) == ["peer"]
      clear_debt(pid)
    end

    test "a debt-free agent resolves no requester at all" do
      {pid, _name} = start_agent_owing([])

      Mimic.stub(Nest.Agents.Supervisor, :get_running_agent, fn _space, _sender ->
        flunk("a debt-free agent has no requester to resolve")
      end)

      assert :ok = GiveUpDelivery.give_up_before_stop(pid, :stopped)
    end

    test "a process that is gone, or whose state this cannot read, still stops" do
      # A dead pid: the read exits with `:noproc`.
      assert :ok = GiveUpDelivery.give_up_before_stop(dead_pid(), :stopped)

      # A live process that answers the read with a state this cannot read: the
      # `live.machine` access raises. (Elixir's `Agent`, not the one this file
      # aliases.)
      {:ok, opaque} = Elixir.Agent.start_link(fn -> %{} end)
      assert :ok = GiveUpDelivery.give_up_before_stop(opaque, :stopped)
    end
  end

  # A real agent holding a reply debt to each of `senders`, so the stop path has
  # something to give up.
  defp start_agent_owing(senders) do
    {pid, name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: AgentTestHelpers.programmer_vocation_id_for_test()
      })

    :sys.replace_state(pid, fn state ->
      %{state | live: %{state.live | machine: Machine.owe_replies(state.live.machine, senders)}}
    end)

    {pid, name}
  end

  # Drop every obligation without telling anyone: what a test does after it has
  # asserted on the debt, so the agent's own teardown has nothing to report.
  defp clear_debt(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | live: %{state.live | machine: Machine.discharge_all(state.live.machine)}}
    end)
  end

  # The agent that is giving up: only its name and space matter for the notice
  # and the refusal report.
  defp giver(space_id) do
    %Agent{name: "giver-#{System.unique_integer([:positive])}", space_id: space_id}
  end

  defp entry do
    %{
      from: "peer",
      content: "queued",
      timestamp: DateTime.utc_now(),
      kind: :agent,
      mode: nil
    }
  end

  # A pid that is already gone, so a call to it exits with `:noproc`.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end
end
