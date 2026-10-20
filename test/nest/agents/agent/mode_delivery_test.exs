defmodule Nest.Agents.Agent.ModeDeliveryTest do
  @moduledoc """
  The mode a *message* carries: a peer's `set_mode` rides the delivery, so the
  change and the instruction that depends on it arrive together.

  Two things are pinned here, each the observable half of one rule:

    * the recipient's header states the mode its own turn will run in, built at
      delivery (`[Message from agent "NAME" | mode: MODE]`), and the mode it
      names is the one the drain applied and wrote down (`agents.mode`);
    * a change that arrives this way is *not* announced: it came on a message
      whose own header states the mode the turn runs in, so a notice would
      duplicate it — for a peer's `set_mode` and for the human's own selection,
      whose message carries a `[mode: X]` prefix.

  What a restart does with the written-down mode is `ModePersistenceTest`'s
  (`agents.mode` is the column a restart reads); this file only pins that a
  message-carried change reaches that column.

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

  describe "a peer delivery's mode" do
    test "a queued delivery's header names the mode its own turn will run in" do
      {pid, name} = start()
      MockClient.set_response("ok")

      # Busy, so the delivery queues: the mode applies when the drain delivers
      # it, never when it is queued.
      set_status(pid, :streaming)
      assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "peer note", :agent, "plan")

      Agent.stop_chat(pid, self())
      wait_idle(pid)

      # The header is rendered from the mode the drain applied
      # (`Turn.Executor.peek_inbox/1`), so it states the mode the turn ran in.
      assert delivered(pid, "peer note") ==
               ["[From agent peer | mode: plan]\npeer note"]

      # And the change is written down, so a restart restores it.
      assert {:ok, %{mode: "plan"}} = row_mode(name)

      # The change arrived on a message, and that message's header states the
      # mode the turn runs in — so nothing announces it a second time.
      assert delivered(pid, "[From nest runtime") == []
    end

    test "an idle delivery's header names the mode its own turn will run in" do
      {pid, name} = start()
      MockClient.set_response("ok")

      assert {:ok, :delivered} = Agent.deliver_note(pid, "peer", "peer note", :agent, "plan")
      wait_idle(pid)

      assert delivered(pid, "peer note") ==
               ["[From agent peer | mode: plan]\npeer note"]

      assert {:ok, %{mode: "plan"}} = row_mode(name)
    end
  end

  describe "the human's own mode is written down and announces nothing" do
    test "the human's own mode is written down on either path, and announces nothing" do
      {pid, name} = start()
      MockClient.set_response("ok")
      MockClient.set_response("ok")

      # The human's own selection is stated by the delivered message's own
      # `[mode: X]` prefix, never by a notice. It is written down whether it
      # rides a chat message — applied at once — ...
      #
      # The row also names her (`@alice`), because a direct chat and a note from
      # the same speaker must be the same framing: `Header.sender/3`'s drift
      # guard is in `HeaderTest`, and this is the producer end of it.
      :ok = Agent.chat(pid, "do the thing", "plan", "alice", true)
      wait_idle(pid)

      assert delivered(pid, "do the thing") == ["[From user @alice | mode: plan]\ndo the thing"]
      assert {:ok, %{mode: "plan"}} = row_mode(name)

      # ...or a queued delivery, applied when the drain delivers it.
      set_status(pid, :streaming)
      :ok = Agent.chat(pid, "and another", "act", "alice", true)

      Agent.stop_chat(pid, self())
      wait_idle(pid)

      # The row proves the queued delivery was drained under her mode, so the
      # absence below is anchored on a delivery that happened.
      assert {:ok, %{mode: "act"}} = row_mode(name)
      assert delivered(pid, "[From nest runtime") == []
    end
  end
end
