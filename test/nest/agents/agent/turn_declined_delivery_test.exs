defmodule Nest.Agents.Agent.TurnDeclinedDeliveryTest do
  @moduledoc """
  A delivery the turn boundary would not fit is *declined*, and declining leaves
  the entry exactly where it was (issue #36).

  `Machine.Backgrounding` moves an in-flight batch to the background to deliver
  a message now, but only when the boundary's own
  `Dispatch.preflight_decision/2` says the message fits. A delivery that does
  not fit is declined (`:delivery_would_not_fit`): the decision for a message
  the context cannot hold belongs to the turn boundary — `:needs_compaction`
  stages the compaction, `:cannot_compact` blocks with the overflow banner —
  and dispatching it from the backgrounding path would skip both and append a
  message the context cannot hold, with the batch's own result still to come.

  What this pins is the W1 invariant that makes the decline safe: the declined
  entry is still **queued and visible** — in the queue or in the transcript,
  never in neither — and the batch the decline refused to background is
  untouched. The unit half (the machine's own `:delivery_would_not_fit`
  decision) lives in `MachineBackgroundingTest`; this file drives it through
  the delivery entry point, where the disposition and the wire are real.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    :ok
  end

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers

  test "a delivery that would not fit stays queued and visible" do
    {pid, _name} = start_agent(%{})

    # The one thing the other fabricated-busy tests do not need: a batch that is
    # genuinely backgroundable. `set_status/2` leaves `worker_ref` nil, so a
    # delivery would no-op as `:no_batch_to_background` before ever reaching the
    # fit check — this fixture has a live worker, its ref, and an unanswered
    # `tool_use` on the tail, so the delivery reaches `deliver_or_decline/3`.
    worker = spawn(fn -> receive do: (:stop -> :ok) end)
    ref = make_ref()
    transcript = [system(0), user(1), assistant_tool(2)]

    :sys.replace_state(pid, fn state ->
      machine = %{
        state.live.machine
        | kind: :chat,
          phase: :executing_tools,
          work: %{
            state.live.machine.work
            | worker_kind: :tools,
              worker_ref: ref,
              active_worker: worker
          }
      }

      %{
        state
        | chat_state: %{state.chat_state | messages: transcript},
          live: %{state.live | machine: machine},
          # A context the delivered message cannot fit, so the boundary's own
          # decision is what declines it.
          llm_metrics: %{state.llm_metrics | context_limit: 100}
      }
    end)

    # The fixture's own decision, asserted so the test cannot pass on a limit
    # that happens to fit.
    delivered = Dispatch.build_user_message("a message that will not fit", "chat")

    assert :cannot_compact = Dispatch.preflight_decision(transcript ++ [delivered], 100)

    assert :ok = Agent.chat(pid, "a message that will not fit", nil, "alice")

    # Visible: the queue is broadcast on enqueue, and the declined drain
    # consumed nothing, so that frame is still the whole queue.
    assert_receive {:chat_inbox,
                    %{
                      count: 1,
                      messages: [%{"content" => "a message that will not fit", "kind" => "user"}]
                    }},
                   500

    state = :sys.get_state(pid)

    # Queued: the W1 invariant. The entry is in the queue, and it is not in the
    # transcript either — never in neither.
    assert [%{content: "a message that will not fit", kind: :user, from: "alice"}] =
             state.live.inbox

    refute Enum.any?(user_texts(state.chat_state.messages), &(&1 =~ "will not fit"))

    # The batch the decline refused to background is untouched: same worker,
    # same ref, no entry, and nothing killed it.
    assert Machine.status_for(state.live.machine) == :executing_tools
    assert state.live.machine.work.active_worker == worker
    assert state.live.machine.work.worker_ref == ref
    assert state.live.machine.work.backgrounded == %{}
    assert Process.alive?(worker)

    # Leave the agent idle for the teardown, with the entry dropped: the
    # decline, not the fabricated batch, is what this test pins.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | inbox: [],
              machine: Machine.status_to_machine(state.live.machine, :idle)
          }
      }
    end)

    Process.exit(worker, :kill)
  end

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index), do: {:user, %User{index: index, parts: [%Part.Text{text: "hi"}]}}

  defp assistant_tool(index) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: "c1", name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end
end
