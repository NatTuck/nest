defmodule Nest.Agents.Agent.SubAgentToolsTest do
  @moduledoc """
  E2E test that drives a coordinator's full chat turn through
  `MockClient.run/2` and confirms the unified `agents-spawn`,
  `agents-list`, and `agents-query` tools produce correctly-paired
  `assistant[tool] → tool[result]` messages.

  ## Pipeline under test

    1. Coordinator Agent A starts with a vocation whose
       `tools` include the `agents-spawn`, `agents-list`, and `agents-query` tools.
    2. A's MockClient FIFO returns a tool call for the tool
       under test, then a final text response.
    3. `ToolLoop` intercepts the sub-agent tool, routes it
       through the coordinator GenServer (`:spawn_agent_request`)
       or reads the space inline (`agents-list`), and returns
       a synthetic `ToolResult`.
    4. The coordinator's next MockClient run produces the
       final text; A goes `:idle`.

  `agents-query`'s own test lives in
  `Nest.Agents.Agent.SubAgentQueryDeliveryTest`: its delivery confirmation
  races the peer's answer against the coordinator's tool batch (issue #36), so
  each outcome is pinned there with a gate rather than a fence. The fixtures
  both files share live in `Nest.Agents.SubAgentToolsHelpers`.

  ## What's stubbed

    * Nothing chats with the spawned specialist, so no
      `Nest.Agents.chat/2` stub is needed (unlike the
      `clone_agent` flow). The specialist is created and
      left idle.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.Agents.SubAgentToolsHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  setup do
    {:ok, vid: upsert_tools_vocation()}
  end

  test "agents-spawn tool creates a specialist and returns its name", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    specialist_slug = specialist_vocation_slug()
    space_id = AgentTestHelpers.current_space_id()

    # The spawn broadcasts `agent:created` on the space topic (#41) so the
    # sidebar can add the child live. Subscribe before the chat so the
    # broadcast can't slip past us.
    Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(space_id))

    MockClient.set_tool_response(%{
      text: "spawning",
      tool_calls: [
        %{
          id: "call_spawn_1",
          name: "agents-spawn",
          arguments: %{"name" => specialist_name, "vocation" => specialist_slug}
        }
      ]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "spin up a specialist")
    await_idle(coordinator_pid)

    # The live-add broadcast carries the space_id the sidebar groups by.
    # `await_idle/1` is the fence: the spawn broadcasts from the coordinator's
    # own handler, so `:sys.get_state/2` on it flushes the frame before it
    # reports the idle turn.
    assert_received {:agent_created, %{"name" => ^specialist_name, "space_id" => ^space_id}}

    # The specialist exists in the space.
    assert {:ok, _info} = Nest.Agents.get_info(space_id, specialist_name)
    on_exit(fn -> _ = Supervisor.stop_agent(space_id, specialist_name) end)

    # The coordinator's tool message carries the spawn result.
    coordinator_state = :sys.get_state(coordinator_pid, 1_000)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-spawn"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               name: "agents-spawn",
               content: content,
               is_error: false
             }
           ] = tool_msg.parts

    assert content =~ specialist_name
  end

  test "agents-spawn with a model argument spawns the child on that model", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    specialist_slug = specialist_vocation_slug()

    MockClient.set_tool_response(%{
      text: "spawning",
      tool_calls: [
        %{
          id: "call_spawn_model_1",
          name: "agents-spawn",
          arguments: %{
            "name" => specialist_name,
            "vocation" => specialist_slug,
            "model" => "pegasus/pegasus-default-only"
          }
        }
      ]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "spin up a specialist on pegasus")
    await_idle(coordinator_pid)

    space_id = AgentTestHelpers.current_space_id()
    {:ok, specialist_pid} = Supervisor.get_agent(space_id, specialist_name)
    child_state = :sys.get_state(specialist_pid, 1_000)
    assert child_state.model == %{name: "pegasus-default-only", provider: "pegasus"}

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, specialist_name) end)
  end

  test "agents-spawn with an unparseable model argument reports an error", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    MockClient.set_tool_response(%{
      text: "spawning",
      tool_calls: [
        %{
          id: "call_spawn_bad_model_1",
          name: "agents-spawn",
          arguments: %{"name" => "never-spawns", "model" => "not-a-valid-model"}
        }
      ]
    })

    MockClient.set_response("coordinator done")

    log =
      capture_log(fn ->
        :ok = Agent.chat(coordinator_pid, "spin up a specialist on a bad model")
        await_idle(coordinator_pid)
      end)

    assert log =~ "is_error=true tool result"

    coordinator_state = :sys.get_state(coordinator_pid, 1_000)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-spawn"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               name: "agents-spawn",
               content: content,
               is_error: true
             }
           ] = tool_msg.parts

    assert content =~ "invalid_model"
  end

  test "agents-list tool returns the space's running and persisted non-archived agents", %{
    vid: vid
  } do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = AgentTestHelpers.current_space_id()

    # Pre-seed a running specialist so `agents-list` has something to show.
    specialist_name = "listed-#{System.unique_integer([:positive])}"
    specialist_slug = specialist_vocation_slug()
    state = coordinator_state(space_id)

    assert {:ok, ^specialist_name} =
             Supervisor.spawn_agent_in_space(state, specialist_name, specialist_slug)

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, specialist_name) end)

    # A persisted-only (no live pid) non-archived row: the merged
    # listing must include it even though nothing is running for it,
    # and its entry must report the real vocation slug resolved from
    # the row's `vocation_id` (the row stores only the id).
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    db_only_name = "db-only-#{System.unique_integer([:positive])}"
    db_only_slug = AgentTestHelpers.vocation_slug_for_test()

    {:ok, _row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: db_only_name,
        model: model,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      })

    # An archived row must never appear.
    archived_name = "archived-#{System.unique_integer([:positive])}"

    {:ok, _row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: archived_name,
        model: model,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      })

    assert :ok = Nest.Persistence.archive_agent(space_id, archived_name)

    MockClient.set_tool_response(%{
      text: "listing",
      tool_calls: [%{id: "call_list_1", name: "agents-list", arguments: %{}}]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "who is here?")
    await_idle(coordinator_pid)

    coordinator_state = :sys.get_state(coordinator_pid, 1_000)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-list"}, &1))

        _ ->
          false
      end)

    assert [
             %Part.ToolResult{
               name: "agents-list",
               content: content,
               is_error: false
             }
           ] = tool_msg.parts

    assert content =~ specialist_name
    assert content =~ db_only_name
    refute content =~ archived_name

    # Each entry carries a real vocation slug: the running specialist's
    # from its live vocation struct, the persisted-only row's resolved
    # from its `vocation_id` (never `nil`).
    assert entry_for(content, specialist_name) =~ ~s(vocation: "#{specialist_slug}")
    assert entry_for(content, db_only_name) =~ ~s(vocation: "#{db_only_slug}")
  end

  test "agents-send tool delivers a message to a peer asynchronously", %{vid: vid} do
    {coordinator_pid, coordinator_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = AgentTestHelpers.current_space_id()

    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    start_mocked_specialist(space_id, specialist_name, "the specialist answer")

    MockClient.set_tool_response(%{
      text: "sending",
      tool_calls: [
        %{
          id: "call_send_1",
          name: "agents-send",
          arguments: %{"name" => specialist_name, "message" => "please review this"}
        }
      ]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "hand this off")
    await_idle(coordinator_pid)

    coordinator_state = :sys.get_state(coordinator_pid, 1_000)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-send"}, &1))

        _ ->
          false
      end)

    assert [%Part.ToolResult{name: "agents-send", content: content, is_error: false}] =
             tool_msg.parts

    assert content =~ "Message delivered to #{specialist_name}"

    {:ok, specialist_pid} = Nest.Agents.Registry.lookup(space_id, specialist_name)
    specialist_state = :sys.get_state(specialist_pid, 1_000)

    assert Enum.any?(specialist_state.chat_state.messages, fn
             {:user, %{parts: parts}} ->
               Enum.any?(parts, fn
                 %Part.Text{text: text} ->
                   text =~ coordinator_name and text =~ "please review this"

                 _ ->
                   false
               end)

             _ ->
               false
           end)

    await_idle(specialist_pid)
  end

  test "agents-send to a missing agent reports an error", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    MockClient.set_tool_response(%{
      text: "sending",
      tool_calls: [
        %{
          id: "call_send_missing_1",
          name: "agents-send",
          arguments: %{"name" => "ghost-agent", "message" => "anyone home?"}
        }
      ]
    })

    MockClient.set_response("coordinator done")

    log =
      capture_log(fn ->
        :ok = Agent.chat(coordinator_pid, "try to send")
        await_idle(coordinator_pid)
      end)

    assert log =~ "is_error=true tool result"

    coordinator_state = :sys.get_state(coordinator_pid, 1_000)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-send"}, &1))

        _ ->
          false
      end)

    assert [%Part.ToolResult{name: "agents-send", content: content, is_error: true}] =
             tool_msg.parts

    assert content =~ "not found"
  end

  test "agents-wait-for-idle returns immediately when every other agent is idle", %{vid: vid} do
    {coordinator_pid, coordinator_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = AgentTestHelpers.current_space_id()

    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    start_mocked_specialist(space_id, specialist_name, "the specialist answer")

    # No `names` argument: every other agent in the space, which here is
    # the (idle) specialist (plus the helper's own coordinator row). The
    # caller is never a target.
    MockClient.set_tool_response(%{
      text: "waiting",
      tool_calls: [%{id: "call_wait_1", name: "agents-wait-for-idle", arguments: %{}}]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "wait for the specialist")
    await_idle(coordinator_pid)

    coordinator_state = :sys.get_state(coordinator_pid, 1_000)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-wait-for-idle"}, &1))

        _ ->
          false
      end)

    assert [%Part.ToolResult{name: "agents-wait-for-idle", content: content, is_error: false}] =
             tool_msg.parts

    assert content =~ "All agents are already idle:"
    assert content =~ specialist_name
    refute content =~ coordinator_name
  end

  # The `agents-list` tool result content is `inspect/1` output of the
  # listing, so an individual agent's entry is one `%{...}` map inside
  # that string. `[^}]` keeps the match inside a single entry (there is
  # no nested map in an entry) regardless of the key order `inspect/1`
  # chooses.
  defp entry_for(content, name) do
    [entry] = Regex.run(~r/%\{[^}]*name: "#{name}"[^}]*\}/, content)
    entry
  end
end
