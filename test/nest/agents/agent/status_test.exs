defmodule Nest.Agents.Agent.StatusTest do
  @moduledoc """
  Coverage for `agents-status` (issue #22): the message count and the index
  range it implies, the last compaction index, the current state, and the
  explicit `not_running` / unknown report for an agent with no live process.

  The refusals that are this tool's own are here too (a malformed `name`, an
  archived target). A name that does not exist in the space is not repeated
  here: it is the shared `Nest.Agents.Agent.History.Target` refusal, covered by
  `Nest.Agents.Agent.HistoryTest`.

  The `model` line is `inspect/1` of the persisted map, so the assertion spells
  out the string-keyed shape the row really holds.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Registry
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User
  alias Nest.Persistence

  setup :verify_on_exit!

  setup do
    {pid, name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    %{pid: pid, name: name, space_id: AgentTestHelpers.current_space_id()}
  end

  defp run(space_id, agent_name, args) do
    ctx = %{
      space_id: space_id,
      agent_name: agent_name,
      agent_pid: nil,
      context_limit: 100_000,
      messages: []
    }

    {[%ToolResult{} = result], log} =
      with_log(fn ->
        ToolLoop.execute(ctx, nil, [%ToolCall{id: "s1", name: "agents-status", arguments: args}])
      end)

    {result, log}
  end

  defp append(pid, {_role, _message} = message) do
    {_role, _stamped} = GenServer.call(pid, {:append_message, message})
    :ok
  end

  # A row with no process behind it, in the caller's own space.
  defp insert_row(space_id, name) do
    Persistence.insert_agent(%{
      space_id: space_id,
      name: name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: AgentTestHelpers.vocation_id_for_test()
    })
  end

  # Put the agent in a busy status so a delivery queues rather than draining.
  defp set_busy(pid) do
    :sys.replace_state(
      pid,
      fn state ->
        machine =
          state.live.machine
          |> Map.put(:owed_replies, %{"bob" => 0})
          |> Machine.status_to_machine(:streaming)

        %{state | live: %{state.live | machine: machine}}
      end,
      1_000
    )
  end

  # Return the agent to idle and drop the fixture debt, so the test-lifecycle
  # check sees nothing in flight and the stop logs no unpaid reply.
  defp reset_to_idle(pid) do
    :sys.replace_state(
      pid,
      fn state ->
        machine =
          state.live.machine
          |> Map.put(:owed_replies, %{})
          |> Machine.status_to_machine(:idle)

        %{state | live: %{state.live | machine: machine}}
      end,
      1_000
    )
  end

  test "reports the message count, the index range, the compaction boundary and the live state",
       %{pid: pid, name: name, space_id: space_id} do
    append(pid, {:user, %User{parts: [%Part.Text{text: "a question"}]}})
    append(pid, {:assistant, %Assistant{parts: [%Part.Text{text: "an answer"}]}})
    append(pid, {:user, %User{parts: [%Part.Text{text: "another question"}]}})
    append(pid, {:assistant, %Assistant{parts: [%Part.Text{text: "another answer"}]}})

    info = Agent.get_public_info(pid)

    {result, _log} = run(space_id, name, %{})

    assert %ToolResult{name: "agents-status", is_error: false, content: content} = result

    assert content ==
             "Agent \"#{name}\": idle (running)\n" <>
               "  messages: 5 (indices 0..4)\n" <>
               "  last compaction index: -1 (never compacted)\n" <>
               ~s(  model: %{"name" => "qwen3.5-plus", "provider" => "model-studio"}\n) <>
               "  vocation: #{AgentTestHelpers.vocation_slug_for_test()}\n" <>
               "  depth: 0\n" <>
               "  owed replies: none\n" <>
               "  pending inbox: 0 message(s)\n" <>
               "  context limit: #{info.context_limit}"

    # A compaction marker moves the boundary; the report says which index it is
    # at (and the count includes the marker row, as it does at runtime).
    {:ok, %PersistedAgent{id: agent_id}} = Persistence.fetch_agent(space_id, name)
    {:ok, _marker} = Persistence.record_compaction(space_id, name, 5, 4)
    Persistence.update_next_message_index_by_id(agent_id, 6)

    {compacted, _log} = run(space_id, name, %{"name" => name})

    assert %ToolResult{is_error: false, content: content} = compacted
    assert content =~ "  messages: 6 (indices 0..5)\n"
    assert content =~ "  last compaction index: 5\n"
  end

  test "a debt and a queued message are reported rather than omitted", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    # A peer's query sets a reply obligation; a delivery behind it queues.
    # Both are live state, and both are reported.
    set_busy(pid)
    assert {:ok, :queued} = Agent.deliver_note(pid, "carol", "a queued message", :agent)

    {result, _log} = run(space_id, name, %{})

    assert %ToolResult{is_error: false, content: content} = result
    assert content =~ "  owed replies: bob\n"
    assert content =~ "  pending inbox: 1 message(s)\n"
    reset_to_idle(pid)
  end

  test "a row with no live process is not_running and is never started; an empty one has no range",
       %{
         space_id: space_id,
         name: caller
       } do
    bare = "idle-#{System.unique_integer([:positive])}"
    {:ok, %PersistedAgent{id: agent_id}} = insert_row(space_id, bare)
    {:ok, _} = Persistence.insert_message(space_id, bare, {:user, %User{index: 0, parts: []}})
    Persistence.update_next_message_index_by_id(agent_id, 1)

    {:error, :not_found} = Registry.lookup(space_id, bare)

    {result, _log} = run(space_id, caller, %{"name" => bare})

    assert %ToolResult{is_error: false, content: content} = result
    assert content =~ "Agent \"#{bare}\": not_running (no live process)"

    assert content =~
             "  owed replies: unknown (no live process)\n" <>
               "  pending inbox: unknown (no live process)\n" <>
               "  context limit: unknown (no live process)"

    # The read did not start it.
    assert {:error, :not_found} = Registry.lookup(space_id, bare)

    # A row with no messages at all states the count and no range.
    empty = "empty-#{System.unique_integer([:positive])}"
    {:ok, %PersistedAgent{}} = insert_row(space_id, empty)

    {empty_result, _log} = run(space_id, caller, %{"name" => empty})

    assert %ToolResult{is_error: false, content: content} = empty_result
    assert content =~ "  messages: 0\n"
  end

  test "a registered pid that does not answer is unknown, not a state", %{
    space_id: space_id,
    name: caller
  } do
    bare = "wedged-#{System.unique_integer([:positive])}"
    {:ok, %PersistedAgent{}} = insert_row(space_id, bare)

    # A pid the registry reports as running, but which is gone by the time the
    # read lands: a non-answer must not be reported as a state.
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    Mimic.stub(Nest.Agents.Supervisor, :get_running_agent, fn _space, _name -> {:ok, pid} end)

    {result, _log} = run(space_id, caller, %{"name" => bare})

    assert %ToolResult{is_error: false, content: content} = result
    assert content =~ "Agent \"#{bare}\": unknown (the live process did not answer a status read)"
    assert content =~ "  owed replies: unknown (the live process did not answer)"
  end

  test "a malformed `name` is a refusal, not a fallback to the caller", %{
    name: name,
    space_id: space_id
  } do
    # Present but not a string is a typo, not a default: reporting the caller's
    # own status in its place would answer a question the model did not ask.
    # `nil` is included because it is given, where absent is not.
    for {bad, rendered} <- [{123, "123"}, {nil, "nil"}] do
      {result, _log} = run(space_id, name, %{"name" => bad})

      assert %ToolResult{is_error: true, content: content} = result

      assert content ==
               "Invalid `name` argument: expected a string, got: #{rendered}. " <>
                 "Omit it to target yourself."
    end
  end

  test "a vocation row that is gone is reported as unknown, not as a slug", %{
    space_id: space_id,
    name: caller
  } do
    # A dangling `vocation_id` (the FK cannot make one, but a deleted row or a
    # hand-written one can): the report says what it is rather than crashing.
    Mimic.stub(Nest.Vocations, :get_vocation, fn _id -> nil end)

    {result, _log} = run(space_id, caller, %{})

    assert %ToolResult{is_error: false, content: content} = result
    assert content =~ ~r/^  vocation: unknown \(id \d+\)$/m
  end

  test "an archived agent is a refusal", %{name: name, space_id: space_id} do
    assert :ok = Persistence.archive_agent(space_id, name)

    {result, log} = run(space_id, name, %{"name" => name})

    assert %ToolResult{is_error: true, content: content} = result

    assert content ==
             "Agent #{name} is archived, so it is out of service; " <>
               "restore it with agents-unarchive first."

    assert log =~ "BatchSizer produced is_error=true tool result"
  end
end
