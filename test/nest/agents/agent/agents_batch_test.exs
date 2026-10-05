defmodule Nest.Agents.Agent.AgentsBatchTest do
  @moduledoc """
  E2E test for the `agents-batch` fork-join tool.

  Drives a parent's full chat turn through `MockClient` where the model
  makes ONE `agents-batch` call over three items. The parent's coordinator
  fans the call out to three concurrent sub-agents (fresh specialists —
  NOT context clones), and the test synthesizes each child's completion
  with a distinct response. The parent's single `agents-batch` tool result
  must be a JSON array of the three responses **in item order**.

  ## What's stubbed

  * `Nest.Agents.chat/3` — short-circuits each child's chat cycle (the
    child's `preloaded_messages` carry the parent's unpaired tool_use,
    which the child's preflight would reject; and driving three real
    child cycles is out of scope). The child is still spawned +
    registered, so `archive` and the cast-back/usage-merge run for real.

  ## What's asserted

  * Three `agent:created` broadcasts (collected in item order).
  * The `agents-batch` tool result content is
    `["alpha-done", "beta-done", "gamma-done"]` — proving item-order
    assembly and that each slot carried its own child's response.
  * `is_error: false`, and `descendant_usage.output_tokens > 0`
    (usage-merge ran for the children).
  * `pending_children` is empty and the children were archived
    (`archive` defaults to true).
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    stub_child_chat()
    {:ok, vid: upsert_batch_vocation()}
  end

  test "agents-batch fans one templated instruction over items and returns an ordered aggregate",
       %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_1", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"]
    })

    # Subscribe before collecting so the first creation can't slip past.
    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

    # The coordinator spawns children in item order (sequential `pace`),
    # so the creation broadcasts arrive in item order. Collect all three,
    # filtered by parent so a concurrent test's broadcast can't match.
    [child0, child1, child2] = collect_child_names(parent_name, 3)
    child_names = [child0, child1, child2]
    on_exit(fn -> Enum.each(child_names, fn n -> _ = Supervisor.stop_agent(space_id, n) end) end)

    # Children are named from their item (no prefix here), not by the
    # adjective-animal generator.
    assert child_names == ["alpha", "beta", "gamma"]

    # Synthesize each child's completion in item order, each with a
    # distinct response, so an order bug would surface.
    for {name, item} <- zip(child_names, ["alpha", "beta", "gamma"]) do
      cast_child_completed(parent_pid, name, "#{item}-done")
    end

    assert_receive {:chat_status, %{status: "idle"}}, 2_000

    parent_state = :sys.get_state(parent_pid)
    AgentTestHelpers.assert_unique_message_indices(parent_state)

    # The single agents-batch tool result carries the ordered aggregate.
    {:tool, tool_msg} =
      Enum.find(parent_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-batch"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               tool_call_id: "call_batch_1",
               name: "agents-batch",
               content: content,
               is_error: false
             }
           ] = tool_msg.parts

    assert Jason.decode!(content) == ["alpha-done", "beta-done", "gamma-done"]

    # Usage-merge ran for the three children.
    assert parent_state.llm_metrics.descendant_usage.output_tokens > 0

    # No children left running, and `archive` (default true) cleaned up:
    # the coordinator archives each child after forwarding its response,
    # which runs before the parent goes idle (asserted above). The DB
    # `archived` flag is the deterministic proof (no liveness polling).
    assert Machine.pending_children(parent_state.live.machine) == %{}

    assert Enum.all?(
             child_names,
             &(Children.status(parent_state.live.machine.children, &1) == :completed)
           )

    assert_children_archived(space_id, child_names)
  end

  test "a child that dies before responding fails its slot fast and is not archived",
       %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)
    space_id = AgentTestHelpers.current_space_id()

    run_batch(parent_pid, "call_batch_die", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta", "gamma"]
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [child0, child1, child2] = collect_child_names(parent_name, 3)

    on_exit(fn ->
      Enum.each([child1, child2], fn n -> _ = Supervisor.stop_agent(space_id, n) end)
    end)

    # Kill the first child before it completes. ChildRegistry's DOWN
    # notification reaches the parent, which forwards
    # `:spawn_agent_error` to the blocked batch worker — so its slot
    # resolves immediately instead of waiting out the 5-minute timeout.
    assert :ok = Supervisor.stop_agent(space_id, child0)

    # The other two complete normally.
    cast_child_completed(parent_pid, child1, "beta-done")
    cast_child_completed(parent_pid, child2, "gamma-done")

    assert_receive {:chat_status, %{status: "idle"}}, 2_000

    parent_state = :sys.get_state(parent_pid)
    content = batch_tool_content(parent_state)

    assert [first, "beta-done", "gamma-done"] = Jason.decode!(content)
    assert String.starts_with?(first, "[error:")

    assert Machine.pending_children(parent_state.live.machine) == %{}

    # A failed child is never auto-archived (unlike a completed one).
    {:ok, failed_row} = Nest.Persistence.fetch_agent(space_id, child0)
    assert failed_row.archived == false
  end

  test "items still pending past their deadline time out into marker slots", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)

    run_batch(parent_pid, "call_batch_timeout", %{
      "template" => "sum {item}",
      "items" => ["alpha", "beta"],
      "timeout" => 1
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
    [_child0, _child1] = collect_child_names(parent_name, 2)

    assert_receive {:chat_status, %{status: "idle"}}, 2_000

    parent_state = :sys.get_state(parent_pid)

    assert [first, second] = parent_state |> batch_tool_content() |> Jason.decode!()
    assert first =~ "timed out after 1ms"
    assert second =~ "timed out after 1ms"
    assert Machine.pending_children(parent_state.live.machine) == %{}
  end

  test "a timed-out item fails the whole call under fail_fast", %{vid: vid} do
    {parent_pid, parent_name} = start_batch_parent(vid)

    log =
      capture_log(fn ->
        run_batch(parent_pid, "call_batch_fail_fast", %{
          "template" => "sum {item}",
          "items" => ["alpha"],
          "timeout" => 1,
          "on_error" => "fail_fast"
        })

        Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")
        [_child0] = collect_child_names(parent_name, 1)

        assert_receive {:chat_status, %{status: "idle"}}, 2_000
      end)

    assert log =~ "BatchSizer produced is_error=true tool result"
    assert log =~ "tool=agents-batch"

    parent_state = :sys.get_state(parent_pid)

    assert %Part.ToolResult{name: "agents-batch", is_error: true, content: content} =
             batch_tool_result(parent_state)

    assert content =~ "timed out after 1ms"
    assert Machine.pending_children(parent_state.live.machine) == %{}
  end

  # ---- helpers ----

  # Start a parent agent whose `Agents.chat/3` is stubbed (children don't
  # run a real chat cycle) and allow the coordinator to call the stub.
  defp start_batch_parent(vid) do
    {parent_pid, parent_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    Mimic.allow(Agents, self(), parent_pid)
    {parent_pid, parent_name}
  end

  # Queue a tool call as the model's first response and a final text
  # response, then kick off the parent's chat turn.
  defp run_batch(parent_pid, id, args) do
    MockClient.set_tool_response(%{
      text: "batching",
      tool_calls: [%{id: id, name: "agents-batch", arguments: args}]
    })

    MockClient.set_response("parent final")
    :ok = Agent.chat(parent_pid, "batch a thing")
  end

  defp batch_tool_result(parent_state) do
    {:tool, %{parts: [%Part.ToolResult{name: "agents-batch"} = result]}} =
      Enum.find(parent_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-batch"}, &1))

        _ ->
          false
      end)

    result
  end

  defp batch_tool_content(parent_state), do: batch_tool_result(parent_state).content

  # Collect `count` `agent:created` broadcasts for `parent_name`, in the
  # order they arrive (item order). Non-matching broadcasts from
  # concurrent tests are filtered by the `parentName` guard.
  defp collect_child_names(_parent_name, 0, acc), do: Enum.reverse(acc)

  defp collect_child_names(parent_name, n, acc) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent:created",
                     payload: %{"name" => name, "parentName" => ^parent_name}
                   },
                   5_000

    collect_child_names(parent_name, n - 1, [name | acc])
  end

  defp collect_child_names(parent_name, n), do: collect_child_names(parent_name, n, [])

  defp zip(list, list2), do: Enum.zip(list, list2)

  # Cast a child's completion to the coordinator, mimicking the
  # child's `chat_idle` cast in production.
  defp cast_child_completed(parent_pid, child_name, response) do
    usage = %{
      input_tokens: 0,
      output_tokens: 42,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 42,
      last_output: 42,
      total_input_tokens: 0,
      total_cache_read_input_tokens: 0,
      total_cache_creation_input_tokens: 0,
      context_input_tokens: 0
    }

    GenServer.cast(parent_pid, {:child_completed, child_name, response, usage})
  end

  # `archive` defaults to true, so `handle_child_completed/4` calls
  # `Supervisor.archive_agent/2` for each child as the parent processes
  # its completion — all before the parent goes idle. The DB `archived`
  # flag is set synchronously in that path, so it's a deterministic
  # proof that archiving ran (no liveness polling / DOWN waits).
  defp assert_children_archived(space_id, names) do
    Enum.each(names, fn name ->
      {:ok, row} = Nest.Persistence.fetch_agent(space_id, name)
      assert row.archived == true, "child #{name} should be marked archived in the DB"
    end)
  end

  defp stub_child_chat do
    Mimic.copy(Agents)
    Mimic.stub(Agents, :chat, fn _space_id, _name, _content -> :ok end)
  end

  # The coordinator's vocation exposes `agents-batch`. Children inherit
  # this vocation (`vocation_id` is omitted in the call), which is fine:
  # their chat cycle is stubbed.
  defp upsert_batch_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "AgentsBatch #{System.unique_integer([:positive])}",
        description: "End-to-end agents-batch test",
        system_prompt: "Batch work over items.",
        tools: ["context", "agents"],
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    vid
  end
end
