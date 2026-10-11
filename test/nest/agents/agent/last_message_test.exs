defmodule Nest.Agents.Agent.LastMessageTest do
  @moduledoc """
  Coverage for `agents-last-message` (issue #62): the explicit mid-turn content
  fetch. It reads the caller's own pending delivery from a named agent and
  consumes it, so the turn-boundary drain cannot deliver the same body again.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  setup do
    {pid, name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    %{pid: pid, name: name, space_id: AgentTestHelpers.current_space_id()}
  end

  defp ctx(pid, name, space_id) do
    %{space_id: space_id, agent_name: name, agent_pid: pid, context_limit: 100_000, messages: []}
  end

  defp fetch(pid, name, space_id, args) do
    [%ToolResult{} = result] =
      ToolLoop.execute(ctx(pid, name, space_id), nil, [
        %ToolCall{id: "m1", name: "agents-last-message", arguments: args}
      ])

    result
  end

  # Put the agent in a busy status so a delivery queues rather than draining.
  defp set_busy(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | machine: Machine.status_to_machine(state.live.machine, :streaming)
          }
      }
    end)
  end

  # Return the agent to idle so the test-lifecycle check sees nothing in flight.
  defp reset_to_idle(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | machine: Machine.status_to_machine(state.live.machine, :idle)
          }
      }
    end)
  end

  test "returns the pending delivery, with its id, and consumes it", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    set_busy(pid)
    assert {:ok, :queued} = Agent.deliver_message(pid, "bob", "the report", :agent)

    [entry] = :sys.get_state(pid).live.inbox
    assert entry.retrieved == false

    result = fetch(pid, name, space_id, %{"name" => "bob"})

    assert %ToolResult{name: "agents-last-message", is_error: false, content: content} = result
    assert content =~ "the report"
    assert content =~ "bob"
    assert content =~ entry.id

    # The entry is consumed in place: the drain will skip it.
    assert [%{retrieved: true, id: id}] = :sys.get_state(pid).live.inbox
    assert id == entry.id
    reset_to_idle(pid)
  end

  test "a second fetch finds nothing pending", %{pid: pid, name: name, space_id: space_id} do
    set_busy(pid)
    assert {:ok, :queued} = Agent.deliver_message(pid, "bob", "the report", :agent)

    assert %ToolResult{is_error: false} = fetch(pid, name, space_id, %{"name" => "bob"})

    result = fetch(pid, name, space_id, %{"name" => "bob"})

    assert %ToolResult{is_error: false, content: content} = result
    assert content == "No undelivered message from agent bob."
    reset_to_idle(pid)
  end

  test "a human message is never fetchable", %{pid: pid, name: name, space_id: space_id} do
    set_busy(pid)
    assert :ok = Agent.chat(pid, "from the human", "plan", "bob")

    result = fetch(pid, name, space_id, %{"name" => "bob"})

    assert %ToolResult{is_error: false, content: content} = result
    assert content == "No undelivered message from agent bob."
    # The human's entry is untouched.
    assert [%{kind: :user, retrieved: false}] = :sys.get_state(pid).live.inbox
    reset_to_idle(pid)
  end

  test "no pending delivery returns a clear result", %{pid: pid, name: name, space_id: space_id} do
    result = fetch(pid, name, space_id, %{"name" => "nobody"})

    assert %ToolResult{is_error: false, content: content} = result
    assert content == "No undelivered message from agent nobody."
  end

  test "a missing name is an error", %{pid: pid, name: name, space_id: space_id} do
    log =
      capture_log(fn ->
        result = fetch(pid, name, space_id, %{})

        assert %ToolResult{name: "agents-last-message", is_error: true, content: content} = result
        assert content == "Missing required argument: name."
      end)

    assert log =~ "BatchSizer produced is_error=true tool result"
  end
end
