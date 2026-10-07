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

  import Eventually
  import ExUnit.CaptureLog

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
        await_idle(pid)

        assert_receive {:chat_status, %{status: "idle"}}

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

      # The in-process turn clears its worker as `llm_error` idles the
      # agent, so wait for it to clear rather than reading immediately.
      assert eventually(
               fn -> :sys.get_state(pid).live.machine.work.active_worker == nil end,
               timeout: 1_000
             )

      state = :sys.get_state(pid)
      assert Machine.status_for(state.live.machine) == :idle
    end

    test "an error with no streamed content produces an error-only message" do
      MockClient.set_error({:stream_idle_timeout, 300_000})

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")
        await_idle(pid)

        assert_receive {:chat_status, %{status: "idle"}}

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

  # Sync on the machine reaching `:idle` rather than fencing the status
  # broadcast with a wall-clock timeout. `Turn.run/5` runs the turn's
  # effects (append the message, broadcast `chat:error`) and then broadcasts
  # the new status, all before the handler returns — so once
  # `:sys.get_state/1` reports `:idle`, the broadcasts are already in this
  # process's mailbox and the assertions below cannot race a slow error path.
  #
  # Why a 1s failure deadline, spelled out because this is a raised budget
  # (`SMELLS.md`: "any increase in a timeout is a likely smell"):
  #
  #   * The wait cannot be removed. `Agent.chat/3` is a `GenServer.cast`
  #     (`agent.ex:389`; `handle_cast` only, `callbacks.ex:59-60`), so no call
  #     returns once the turn is finished, and the idle broadcast is itself
  #     part of the contract under test. An unbounded wait would be worse: it
  #     turns a clear failure into a hang bounded only by ExUnit's 60s test
  #     timeout, which blows the 5s budget in `scripts/precommit-test.sh`.
  #   * The signal inherits the whole latency. The idle broadcast is emitted
  #     last in the turn (after the stream is consumed, usage merged, and the
  #     assistant message appended): 76ms in isolation vs 700-1000ms at
  #     `max_cases: 24` (measured; see `notes/test-suite-speedup.md`).
  #
  # So 1s is a failure deadline for the poll, not an expected duration — the
  # condition holds as soon as the error has been handled, and `eventually/2`'s
  # default is 10ms, hence the explicit value. The underlying slowness is real
  # and tracked in #21 (Elixir test timeout audit); this should drop back to
  # 500ms when the turn latency is fixed. The sibling test below carries the
  # same budget.
  defp await_idle(pid) do
    assert eventually(
             fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
             timeout: 1_000
           )
  end
end
