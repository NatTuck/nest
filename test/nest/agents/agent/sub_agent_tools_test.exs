defmodule Nest.Agents.Agent.SubAgentToolsTest do
  @moduledoc """
  E2E test that drives a coordinator's full chat turn through
  `MockClient.run/2` and confirms the unified `agents/spawn`,
  `agents/list`, and `agents/query` tools produce correctly-paired
  `assistant[tool] → tool[result]` messages.

  ## Pipeline under test

    1. Coordinator Agent A starts with a vocation whose
       `tools` include the `agents/spawn`, `agents/list`, and `agents/query` tools.
    2. A's MockClient FIFO returns a tool call for the tool
       under test, then a final text response.
    3. `ToolLoop` intercepts the sub-agent tool, routes it
       through the coordinator GenServer (`:spawn_agent_request`)
       or reads the space inline (`agents/list`), and returns
       a synthetic `ToolResult`.
    4. The coordinator's next MockClient run produces the
       final text; A goes `:idle`.

  ## What's stubbed

    * Nothing chats with the spawned specialist, so no
      `Nest.Agents.chat/2` stub is needed (unlike the
      `clone_agent` flow). The specialist is created and
      left idle.
  """

  use Nest.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  setup do
    {:ok, vid: upsert_tools_vocation()}
  end

  test "agents/spawn tool creates a specialist and returns its name", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    specialist_vid = specialist_vocation_id()

    MockClient.set_tool_response(%{
      text: "spawning",
      tool_calls: [
        %{
          id: "call_spawn_1",
          name: "agents/spawn",
          arguments: %{"name" => specialist_name, "vocation_id" => specialist_vid}
        }
      ]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "spin up a specialist")

    assert_receive {:chat_status, %{status: "idle"}}, 500

    # The specialist exists in the space.
    space_id = AgentTestHelpers.current_space_id()
    assert {:ok, _info} = Nest.Agents.get_info(space_id, specialist_name)
    on_exit(fn -> _ = Supervisor.stop_agent(space_id, specialist_name) end)

    # The coordinator's tool message carries the spawn result.
    coordinator_state = :sys.get_state(coordinator_pid)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents/spawn"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               name: "agents/spawn",
               content: content,
               is_error: false
             }
           ] = tool_msg.parts

    assert content =~ specialist_name
  end

  test "agents/list tool returns the space's running agents", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = AgentTestHelpers.current_space_id()

    # Pre-seed a specialist so `agents/list` has something to show.
    specialist_name = "listed-#{System.unique_integer([:positive])}"
    specialist_vid = specialist_vocation_id()
    state = coordinator_state(space_id)

    assert {:ok, ^specialist_name} =
             Supervisor.spawn_agent_in_space(state, specialist_name, specialist_vid)

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, specialist_name) end)

    MockClient.set_tool_response(%{
      text: "listing",
      tool_calls: [%{id: "call_list_1", name: "agents/list", arguments: %{}}]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "who is here?")

    assert_receive {:chat_status, %{status: "idle"}}, 500

    coordinator_state = :sys.get_state(coordinator_pid)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents/list"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               name: "agents/list",
               content: content,
               is_error: false
             }
           ] = tool_msg.parts

    assert content =~ specialist_name
  end

  test "agents/query tool sends a chat to a specialist and returns its response", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = AgentTestHelpers.current_space_id()

    # Create a specialist in the coordinator's space, swapped to
    # MockClient so it can answer the query's chat turn.
    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    start_mocked_specialist(space_id, specialist_name, "the specialist answer")

    MockClient.set_tool_response(%{
      text: "querying",
      tool_calls: [
        %{
          id: "call_query_1",
          name: "agents/query",
          arguments: %{"name" => specialist_name, "prompt" => "what is 2+2?"}
        }
      ]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "ask the specialist")

    assert_receive {:chat_status, %{status: "idle"}}, 500

    coordinator_state = :sys.get_state(coordinator_pid)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents/query"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               name: "agents/query",
               content: content,
               is_error: false
             }
           ] = tool_msg.parts

    assert content =~ "the specialist answer"
  end

  # The coordinator's vocation exposes the sub-agent tools.
  defp upsert_tools_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SubAgentTools #{System.unique_integer([:positive])}",
        description: "Coordinator with sub-agent tools",
        system_prompt: "Coordinate specialists in this space.",
        tools: ["agents/spawn", "agents/list", "agents/query", "context"],
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    vid
  end

  # A distinct vocation for the spawned specialist.
  defp specialist_vocation_id do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "Specialist #{System.unique_integer([:positive])}",
        description: "A specialist",
        system_prompt: "You are a specialist.",
        tools: ["context"],
        modes: %{}
      })

    vid
  end

  # Spawn an independent specialist into `space_id` (via the same
  # `Supervisor.spawn_agent_in_space/3` the `agents/spawn` tool
  # uses) and wire it up to answer a query:
  #
  #   * Swap its HTTP client to `MockClient` so its chat turn
  #     pulls from a per-pid queue instead of a real API.
  #   * Start that queue and seed `response`.
  #   * Allow the specialist pid to use the test process's
  #     sandbox connection, since `spawn_agent_in_space/3` starts
  #     it under the app supervisor (not `start_agent/1`), so it
  #     doesn't inherit the test's `$callers` — without this its
  #     message-append DB writes would raise
  #     `DBConnection.OwnershipError`.
  defp start_mocked_specialist(space_id, name, response) do
    vid = specialist_vocation_id()
    state = coordinator_state(space_id)

    assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vid)

    {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)
    Sandbox.allow(Nest.Repo, self(), pid)

    :sys.replace_state(pid, fn st ->
      %{st | client_config: %{st.client_config | client: MockClient}}
    end)

    MockClient.start_link(pid)
    MockClient.put_pending(pid, {:text, response})

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
  end

  # Start a real coordinator agent in `space_id` and return its
  # runtime state. `spawn_agent_in_space/3` needs a real parent
  # (name + persisted row for `parent_id`).
  defp coordinator_state(space_id) do
    coordinator_name = "coord-#{System.unique_integer([:positive])}"

    {:ok, ^coordinator_name} =
      Nest.Agents.create_agent(space_id, %{name: "qwen3.5-plus", provider: "model-studio"},
        name: coordinator_name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    AgentTestHelpers.ensure_cleanup(coordinator_name)
    {:ok, pid} = Supervisor.get_agent(space_id, coordinator_name)
    :sys.get_state(pid)
  end
end
