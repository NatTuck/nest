defmodule Nest.Agents.AgentStreamErrorTest do
  @moduledoc """
  Tests for the LLM stream-error path (`LLMStreamHandler.llm_error/2`).

  When a stream fails mid-response — a dropped/incomplete connection or
  an idle timeout — the worker's `on_error` callback sends
  `{:llm_error, _}` to the Agent. The Agent must:

    1. Preserve whatever content had already streamed (as parts of the
       final assistant message) so nothing the model produced is lost.
    2. Append the error text to the same message, tagged
       `metadata: %{"error" => true}` so the UI shows the failure and
       doesn't expect a response log.
    3. Broadcast `chat:error` and transition to `:idle`.
  """
  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog

  # The turn fence. `Agent.chat/5` is a `GenServer.cast` (`agent.ex:375`), so no
  # call returns once the turn is finished and the turn's outcome is decided by
  # arrival. `Turn.run/5` runs the turn's effects — append the assistant message,
  # broadcast `chat:error` — and only then broadcasts the new status, so the idle
  # `chat_status` frame is emitted last: fencing on it proves the frames asserted
  # below are already in this process's mailbox, and that the machine has already
  # settled and cleared its worker.
  #
  # The fence is a failure bound, not an expected duration. The idle broadcast
  # inherits the whole turn's latency (after the stream is consumed, usage merged,
  # and the assistant message appended). Measured in the full suite at
  # `max_cases: 16`: 1132 ms for this error-only turn (and 992 ms for the sibling
  # in `agent_chat_mode_test.exs`), vs 76 ms in isolation. That gap is the
  # suite's documented scheduling-race cost (`notes/sketchy-slow-tests.md`
  # §2/§10): every `start_agent/1` serializes on the global `Mimic.Coordinator`,
  # and the single `Nest.Agents.Supervisor` callback performs each whole agent
  # start, so a mocked turn inherits the queue through its DB appends. 2 s — the
  # `#21` cap on test-side timeouts — clears the measured spread with headroom
  # while a genuinely stuck turn still fails as a fence.
  @turn_fence_ms 2_000

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "llm_error" do
    test "preserves streamed text and appends the error to the final assistant message" do
      # Simulate a dropped connection: some text streamed, then the
      # client reported the stream incomplete (no terminator). Queued
      # before `start_agent/1` so it lands on the per-agent queue.
      MockClient.set_stream_events(
        [{:text, "Halfway through..."}, {:error, {:stream_incomplete, :no_terminator}}],
        auto_done: false
      )

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        # The idle broadcast is the fence: it is emitted after the append and
        # `chat:error`, so the frames asserted below are already here.
        assert_receive {:chat_status, %{status: "idle"}}, @turn_fence_ms

        # The single assistant message carries the partial text AND the
        # error, tagged as an error.
        assert_received {:chat_message,
                         {:assistant, %Assistant{parts: parts, metadata: %{"error" => true}}}}

        assert Enum.any?(parts, &match?(%Part.Text{text: "Halfway through..."}, &1))

        assert Enum.any?(parts, fn
                 %Part.Text{text: text} when is_binary(text) ->
                   text =~ "stream ended unexpectedly"

                 _ ->
                   false
               end)

        assert_received {:chat_error, %{content: content}}
        assert content =~ "stream ended unexpectedly"
      end)

      # The machine settles and clears its worker before `Turn.run/5` announces
      # the new status, so the fence above already proves both; read it without
      # waiting again.
      state = :sys.get_state(pid, 1_000)
      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
    end

    test "an error with no streamed content produces an error-only message" do
      MockClient.set_error({:stream_idle_timeout, 300_000})

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        assert_receive {:chat_status, %{status: "idle"}}, @turn_fence_ms

        assert_received {:chat_message,
                         {:assistant,
                          %Assistant{
                            parts: [%Part.Text{text: text}],
                            metadata: %{"error" => true}
                          }}}

        assert text =~ "no output from the model for 300s"
        assert_received {:chat_error, %{content: content}}
        assert content =~ "no output from the model for 300s"
      end)
    end
  end
end
