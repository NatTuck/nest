defmodule Nest.Agents.Agent.ModeSelectorTest do
  @moduledoc """
  The human's mode selector — `Nest.Agents.set_mode/3` → `Agent.set_mode/2` →
  `Callbacks.handle_call({:set_mode, mode}, …)`.

  Three things the review found were unpinned, each of which the suite was green
  through:

    * a **blocked** agent is not mid-turn, so it must take a mode change. The
      guard admitted only `:idle`/`:model_missing`, so `:needs_repair`,
      `:context_overflow`, `:compaction_failed` and `:compaction_loop_detected` —
      none of which has a live worker — were refused.
    * the change is **published**. `currentMode` only rides `chat:status`, and the
      settle loop broadcasts only on a status *change*, so a second client
      watching the agent kept the old badge.
    * the **reported outcome matches what happened**. The row is written and
      `live.mode` moved before the notice is appended, so a notice that could not
      be appended is a change with a missing announcement — not a failed change.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    :ok
  end

  import Nest.Agents.AgentTestHelpers

  test "a mode change is published, so a second subscriber's badge does not go stale" do
    {pid, name} = start_agent()
    space_id = current_space_id()

    Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.topic(space_id, name))

    assert :ok = Agent.set_mode(pid, "plan")

    # `currentMode` is the key the channel forwards to the client; before this
    # broadcast the frame only arrived when the *status* happened to change.
    assert_receive {:chat_status, %{currentMode: "plan"}}, 1_000
  end

  test "the guard admits every status that is not mid-turn, and only refuses those" do
    # `Inbox.busy_status?/1` is the one definition of "mid-turn", shared with the
    # delivery path — the selector guard must not hand-roll a second list. A
    # blocked agent has no live worker and nothing in flight, so refusing it was
    # wrong rather than merely mis-worded.
    for mid_turn <- [:streaming, :executing_tools, :compacting] do
      assert Inbox.busy_status?(mid_turn), "#{mid_turn} is mid-turn"
    end

    for not_mid_turn <- [
          :idle,
          :model_missing,
          :needs_repair,
          :context_overflow,
          :compaction_failed,
          :compaction_loop_detected
        ] do
      refute Inbox.busy_status?(not_mid_turn),
             "#{not_mid_turn} is not mid-turn and must be admitted"
    end
  end

  test "a notice that cannot be appended is still a change that happened" do
    {pid, name} = start_agent()
    space_id = current_space_id()

    Mimic.copy(MessageAppender)
    Mimic.allow(MessageAppender, self(), pid)
    Mimic.stub(MessageAppender, :handle_batch, fn state, _pair -> {:stale, state} end)

    log =
      capture_log(fn ->
        # The row and `live.mode` are written before the append, so reporting an
        # error here would tell the user the change failed when it took effect.
        assert :ok = Agent.set_mode(pid, "plan")
      end)

    assert {:ok, %{mode: "plan"}} =
             Nest.Persistence.fetch_agent(space_id, name)

    assert Agent.get_public_info(pid, 1_000).current_mode == "plan"
    assert log =~ "could not be appended"
  end
end
