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

  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent
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
    {parent_pid, parent_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    # The stub is scoped per-source-process; allow the coordinator pid.
    Mimic.allow(Agents, self(), parent_pid)
    space_id = AgentTestHelpers.current_space_id()

    MockClient.set_tool_response(%{
      text: "batching",
      tool_calls: [
        %{
          id: "call_batch_1",
          name: "agents-batch",
          arguments: %{"template" => "sum {item}", "items" => ["alpha", "beta", "gamma"]}
        }
      ]
    })

    MockClient.set_response("parent final")

    :ok = Agent.chat(parent_pid, "batch a thing")

    # Subscribe before collecting so the first creation can't slip past.
    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

    # The coordinator spawns children in item order (sequential `pace`),
    # so the creation broadcasts arrive in item order. Collect all three,
    # filtered by parent so a concurrent test's broadcast can't match.
    [child0, child1, child2] = collect_child_names(parent_name, 3)
    child_names = [child0, child1, child2]
    on_exit(fn -> Enum.each(child_names, fn n -> _ = Supervisor.stop_agent(space_id, n) end) end)

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

    # No children left pending, and `archive` (default true) cleaned up:
    # the coordinator archives each child after forwarding its response,
    # which runs before the parent goes idle (asserted above). The DB
    # `archived` flag is the deterministic proof (no liveness polling).
    assert parent_state.chat_state.pending_children == %{}
    assert parent_state.chat_state.archiving == MapSet.new()

    assert_children_archived(space_id, child_names)
  end

  # ---- helpers ----

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
        tools: ["agents-batch", "context-check", "context-compact"],
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
