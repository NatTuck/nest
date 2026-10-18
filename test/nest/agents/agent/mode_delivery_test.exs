defmodule Nest.Agents.Agent.ModeDeliveryTest do
  @moduledoc """
  The mode a *message* carries: a peer's `set_mode` rides the delivery, so the
  change and the instruction that depends on it arrive together.

  Three things are pinned here, each the observable half of one rule:

    * the recipient's header states the mode its own turn will run in, built at
      delivery (`[Message from agent "NAME" | mode: MODE]`), and the mode it
      names is the one the drain applied;
    * a peer's change is *not* announced: it arrived on a message whose own
      header states the mode the turn runs in, so a notice would duplicate it —
      and neither is the human's, whose message carries a `[mode: X]` prefix;
    * a mode a delivered message carries is *written down* (`agents.mode`), so a
      restart restores it.

  `Nest.Agents.Agent.ModeAuthorityTest` owns the rule itself (who may move whom)
  and `Nest.Tools`' schema owns what a sender may ask for; this file owns what
  the delivery does with the answer.
  """

  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentStateHelpers, only: [set_status: 2, wait_idle: 1]
  import Nest.Agents.AgentTurnTestHelpers, only: [user_texts: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Persistence

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  defp start, do: AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})

  defp row_mode(name), do: Persistence.fetch_agent(AgentTestHelpers.current_space_id(), name)

  # The one `{:user, _}` message whose text carries `needle`.
  defp delivered(pid, needle) do
    pid
    |> Agent.get_messages(1_000)
    |> user_texts()
    |> Enum.filter(&(&1 =~ needle))
  end

  describe "the recipient's mode in a peer delivery's header" do
    test "a queued delivery's header names the mode its own turn will run in" do
      {pid, name} = start()
      MockClient.set_response("ok")

      # Busy, so the delivery queues: the mode applies when the drain delivers
      # it, never when it is queued.
      set_status(pid, :streaming)
      assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "peer note", :agent, "plan")

      Agent.stop_chat(pid, self())
      wait_idle(pid)

      # allowlist: snapshot — mode + messages
      state = :sys.get_state(pid, 1_000)

      # The mode the drain applied is the one the header named, and it is the
      # one the turn ran in — the two can never disagree, because the header is
      # built from `state.live.mode` after the peek applied it.
      assert state.live.mode == "plan"

      assert delivered(pid, "peer note") ==
               ["[mode: plan]\n[Message from agent \"peer\" | mode: plan]\npeer note"]

      # And the change is written down, so a restart restores it.
      assert {:ok, %{mode: "plan"}} = row_mode(name)
    end

    test "an idle delivery's header names the mode its own turn will run in" do
      {pid, name} = start()
      MockClient.set_response("ok")

      assert {:ok, :delivered} = Agent.deliver_note(pid, "peer", "peer note", :agent, "plan")
      wait_idle(pid)

      assert delivered(pid, "peer note") ==
               ["[mode: plan]\n[Message from agent \"peer\" | mode: plan]\npeer note"]

      assert Agent.get_public_info(pid, 1_000).current_mode == "plan"
      assert {:ok, %{mode: "plan"}} = row_mode(name)
    end
  end

  describe "a peer's change is written down and announces nothing" do
    test "a peer's set_mode reaches the row, with no notice" do
      {pid, name} = start()
      MockClient.set_response("ok")

      set_status(pid, :streaming)
      assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "peer note", :agent, "plan")

      Agent.stop_chat(pid, self())
      wait_idle(pid)

      # The change arrived on a message, and that message's header states the
      # mode the turn runs in — so nothing announces it a second time.
      assert {:ok, %{mode: "plan"}} = row_mode(name)
      assert delivered(pid, "[nest notice]") == []
    end

    test "the human's own mode is written down on either path, and announces nothing" do
      {pid, name} = start()
      MockClient.set_response("ok")
      MockClient.set_response("ok")

      # The human's own selection is stated by the delivered message's own
      # `[mode: X]` prefix, never by a notice. It is written down whether it
      # rides a chat message — applied at once — ...
      :ok = Agent.chat(pid, "do the thing", "plan", "alice", true)
      wait_idle(pid)

      assert delivered(pid, "do the thing") == ["[mode: plan]\ndo the thing"]
      assert {:ok, %{mode: "plan"}} = row_mode(name)

      # ...or a queued delivery, applied when the drain delivers it.
      set_status(pid, :streaming)
      :ok = Agent.chat(pid, "and another", "act", "alice", true)

      Agent.stop_chat(pid, self())
      wait_idle(pid)

      assert delivered(pid, "and another") == ["[mode: act]\nand another"]
      assert delivered(pid, "[nest notice]") == []
      assert Agent.get_public_info(pid, 1_000).current_mode == "act"
      assert {:ok, %{mode: "act"}} = row_mode(name)
    end
  end

  describe "the mode survives a restart" do
    test "a message-carried mode is restored from the row" do
      {pid, name} = start()
      space_id = AgentTestHelpers.current_space_id()
      MockClient.set_response("ok")

      set_status(pid, :streaming)
      assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "peer note", :agent, "plan")

      Agent.stop_chat(pid, self())
      wait_idle(pid)

      assert {:ok, %{mode: "plan"}} = row_mode(name)

      # A restart re-reads the row, so the mode the agent was working under is
      # the mode it comes back in — a message-carried change cannot be widened
      # or lost by a restart. The agent is linked to this test pid
      # (`start_agent/1`), so unlink first: its termination is the restart's
      # doing, not a crash this test should die of.
      Process.unlink(pid)
      assert {:ok, ^name} = Supervisor.restart_agent(space_id, name)
      assert {:ok, restarted} = Supervisor.get_agent(space_id, name)

      assert Agent.get_public_info(restarted, 1_000).current_mode == "plan"
    end
  end
end
