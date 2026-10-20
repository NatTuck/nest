defmodule Nest.Agents.AgentChatModeTest do
  @moduledoc """
  Tests for `Agent.chat/3`'s mode resolution: the mode a chat turn runs in, the
  `[mode: X]` prefix and `metadata.mode` the user message carries, and the
  stickiness of `state.live.mode` between turns.

  The modes are the two code constants in `Nest.Modes` (`plan` and `act`), so
  they are **not** per-vocation data any more: a name this build implements is
  used as-is, and anything else — the old `"chat"`, a stale row, a client that
  made one up — falls back to `Nest.Modes.default/0`. Every fixture here
  therefore names a real mode, and none of them builds a `vocations.modes` map.

  See `agent_chat_test.exs` for the chat-streaming coverage.
  """
  use Nest.DataCase, async: true

  import Mimic

  # `Agent.chat/2` is a `GenServer.cast`, so a fence placed after it covers the
  # *whole* turn: here a mocked LLM call. 500 ms is not a bound for that under
  # load — a whole mocked turn measured p50 18.7 ms / max 34.3 ms across 40
  # samples in the full suite, but p50 926 ms / max 1534 ms (39 of 40 over
  # 500 ms) under 48 CPU burners. Re-measured in the full suite at
  # `max_cases: 16`, the turn's *first* frame (the user message) took 992 ms —
  # the suite's documented scheduling-race cost (`notes/sketchy-slow-tests.md`
  # §2/§10: every `start_agent/1` serializes on the global `Mimic.Coordinator`,
  # and the single `Nest.Agents.Supervisor` callback performs each whole agent
  # start). 2000 ms is the `#21` cap on every test-side timeout, clears that
  # measured spread with headroom, and still fails a genuinely stuck turn — as a
  # stuck turn, not as a flake.
  @turn_fence_ms 2_000

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Modes

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "chat/3 with mode" do
    test "an agent nothing has said anything about is in the permissive default" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # The mode is a per-agent runtime property seeded from the space's
      # blueprint; with no blueprint it is `Nest.Modes.default/0`.
      assert Agent.get_public_info(pid, 1_000).current_mode == Modes.default()
      assert Modes.default() == "act"
    end

    test "a user message carries the resolved mode in its header and metadata" do
      # The idle path's row is the whole of the design here: the mode the turn
      # will run in is stated in the row's header *and* on its metadata, and
      # both come from one builder (`Dispatch.build_user_message/3`). If you are
      # changing this test you are almost certainly changing that design — talk
      # to the team first. (It is the case
      # `agent_user_message_mode_prefix_test.exs` used to pin alone, under the
      # retired `[mode: X]` prefix: the same setup and the same assertion, so the
      # two are one test now.)
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Hello", nil, nil, true)

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[From user | mode: act]\nHello"}],
                         metadata: %{"mode" => "act"}
                       }}},
                     @turn_fence_ms

      await_idle()
    end

    test "an unknown mode falls back to the default" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Hello", "nonexistent-mode", nil, true)

      assert_receive {:chat_message,
                      {:user,
                       %{
                         parts: [%Part.Text{text: "[From user | mode: act]\nHello"}],
                         metadata: %{"mode" => "act"}
                       }}},
                     @turn_fence_ms

      # The fallback is written to `state.live.mode` and so reaches the status
      # frame's `currentMode`, rather than leaving a mode nothing can honour.
      # The frame is the turn's last, so it is also the fence.
      assert_receive {:chat_status, %{status: "idle", currentMode: "act"}}, @turn_fence_ms
    end

    test "state.live.mode is updated to the resolved mode after a chat (sticky mode)" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Initial state: the mode the row carries. The modes are code constants
      # (`Nest.Modes`) and what is per-agent is *which* one, seeded from the
      # space's blueprint — so an agent nothing has said anything about is in
      # the permissive one.
      assert Agent.get_public_info(pid, 1_000).current_mode == "act"

      :ok = Agent.chat(pid, "Plan this", "plan", nil, true)
      await_idle()
      assert Agent.get_public_info(pid, 1_000).current_mode == "plan"

      # The next chat without an explicit mode uses the updated
      # `state.live.mode` — `handle_chat/4`'s `requested_mode || state.live.mode`
      # fallback.
      :ok = Agent.chat(pid, "And another", nil, nil, true)
      await_idle()
      assert Agent.get_public_info(pid, 1_000).current_mode == "plan"
    end
  end

  describe "origin marker" do
    test "tags a human chat but not a spawn-style kickoff" do
      # The Ctrl/Cmd+Up recall list shows only rows tagged `origin: "human"`.
      # The channel passes `human?: true`; `agents-spawn`'s `query` kickoff
      # passes `false` (`SubAgent.handle_spawn_request/3`), so a prompt nobody
      # typed can never reach that list.
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "typed by a human", nil, "alice", true)

      assert_receive {:chat_message,
                      {:user, %{metadata: %{"mode" => "act", "origin" => "human"}}}},
                     @turn_fence_ms

      await_idle()

      :ok = Agent.chat(pid, "kickoff nobody typed", nil, nil, false)

      assert_receive {:chat_message, {:user, %{metadata: metadata}}}, @turn_fence_ms
      refute Map.has_key?(metadata, "origin")

      await_idle()
    end
  end

  # Wait for the turn's last frame: `Agent.chat/2` is a `GenServer.cast`, so the
  # `"idle"` `chat:status` broadcast is emitted at the end of the turn and every
  # earlier frame of that turn precedes it in this mailbox (the same fence
  # `agent_chat_test.exs` uses). Arrival decides the outcome; `@turn_fence_ms` is
  # only the failure bound. The fence reads the frames the *test* pid is
  # subscribed to, so it needs no agent pid.
  defp await_idle do
    assert_receive {:chat_status, %{status: "idle"}}, @turn_fence_ms
  end
end
