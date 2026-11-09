defmodule Nest.Agents.Agent.Turn.WorkerStartFailureTest do
  @moduledoc """
  A refused `Task.Supervisor.start_child/2` fails the turn instead of wedging the
  agent (issue #108).

  `Turn.Executor.spawn_worker/3` used to synthesize `{:worker_crashed, ref, …}`
  with a fresh ref when the supervisor refused the child. No `{:worker_started,
  …}` was ever emitted, so `work.worker_ref` was still `nil` — and every
  `{:worker_crashed, …}` clause is gated on `Machine.valid_ref?/2`, while
  `:executing_tools` had no such clause at all. The event was dropped in both
  places, and the machine rested in `:executing_tools` with no worker: not
  backgroundable, no drain, no turn boundary, and every arrival queued behind a
  batch that did not exist.

  The refusal is forced rather than reached by exhausting a supervisor: the stub
  refuses the *second* spawn the turn starts (its HTTP worker is the first, the
  tool batch the second) and hands every other call to the module Mimic renamed
  away, so the turn runs for real right up to the batch.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic
  import Nest.Agents.AgentTestHelpers

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "a refused tool-batch spawn fails the turn, and the next message is accepted" do
    MockClient.set_tool_response(%{
      text: "Running it",
      tool_calls: [%{id: "call_1", name: "shell-cmd", arguments: %{"command" => "echo hi"}}]
    })

    MockClient.set_response("After the failure")

    {pid, _name} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: programmer_vocation_id_for_test()
      })

    refuse_tool_batch(pid)

    log =
      capture_log(fn ->
        :ok = Agent.chat(pid, "Run a command")

        # The turn ends: the agent idles and the failure is announced, rather
        # than resting in `:executing_tools` waiting for a worker that was never
        # started.
        assert_receive {:chat_status, %{status: "idle"}}, 1_000
        assert_receive {:chat_error, %{content: content}}, 1_000
        assert content =~ ":max_children"

        assert Agent.get_public_info(pid, 1_000).status == :idle
      end)

    # The refusal is logged with its reason, not swallowed.
    assert log =~ "chat_crashed"
    assert log =~ ":max_children"

    messages = Agent.get_messages(pid, 1_000)

    # The batch really was requested — the assistant carrying `call_1` reached
    # the transcript — so the refusal landed in `:executing_tools`, not on the
    # HTTP worker. And the failure's terminal repair answered that call with an
    # error result, so the next request is wire-valid.
    tool_uses =
      for {:assistant, %Assistant{parts: parts}} <- messages,
          %Part.ToolUse{} = call <- parts || [],
          do: call

    assert [%Part.ToolUse{id: "call_1"}] = tool_uses

    results =
      for {:tool, %Tool{parts: parts}} <- messages,
          %Part.ToolResult{} = result <- parts || [],
          do: result

    assert [%Part.ToolResult{tool_call_id: "call_1", is_error: true}] = results

    assert MessageList.unpaired_tail_tool_uses(messages) == []

    # The next message is taken as a new turn, not queued behind a batch that
    # does not exist.
    :ok = Agent.chat(pid, "Next")

    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    assert "After the failure" in Enum.flat_map(Agent.get_messages(pid, 1_000), &texts/1)
  end

  # Refuse the *second* spawn the agent starts on `Nest.Agents.TaskSupervisor`:
  # the first is the turn's HTTP worker, the second is the tool batch. Every
  # other call is handed to the module Mimic renamed away
  # (`Mimic.Module.original/1`), so the turn runs for real up to the batch —
  # `Task.Supervisor.start_child/2` is a `GenServer.call` into the supervisor,
  # not a `Supervisor.start_child/2`, so it is delegated rather than reproduced.
  defp refuse_tool_batch(agent_pid) do
    original = Mimic.Module.original(Task.Supervisor)

    Mimic.stub(Task.Supervisor, :start_child, fn supervisor, child ->
      key = {:turn_spawns, supervisor}
      n = Process.get(key, 0) + 1
      Process.put(key, n)

      if supervisor == Nest.Agents.TaskSupervisor and n == 2,
        do: {:error, :max_children},
        else: original.start_child(supervisor, child)
    end)

    Mimic.allow(Task.Supervisor, self(), agent_pid)
  end

  defp texts({:assistant, %Assistant{parts: parts}}) when is_list(parts) do
    for %Part.Text{text: text} <- parts, do: text
  end

  defp texts(_message), do: []
end
