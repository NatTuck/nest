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

  `agents-query` is the one tool whose result is *not* the peer's answer:
  it delivers the message (the peer then owes the coordinator a reply) and
  its tool result is that delivery confirmation. The peer's answer arrives
  later as a message in the coordinator's inbox, which is what its own test
  below pins.

  ## What's stubbed

    * Nothing chats with the spawned specialist, so no
      `Nest.Agents.chat/2` stub is needed (unlike the
      `clone_agent` flow). The specialist is created and
      left idle.
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog

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

  # A turn in this file is: a mocked LLM call, a real sub-agent spawn or peer
  # delivery (DB writes, a registry insert, a new process), and a second mocked
  # LLM call. `Agent.chat/2` is a `GenServer.cast`, so a fence after it covers
  # that *whole* turn — which is why a 500 ms fence here was a race, not a
  # check. Measured for the scenario in "agents-spawn with a model argument":
  #
  #   * full suite, 24-way concurrency, 40 samples: p50 18.7 ms, max 34.3 ms
  #   * 48 CPU burners, 40 samples: p50 926 ms, max 1534 ms; 39/40 over 500 ms
  #   * the observed 1-in-40 gate failure (seed 200984, load 5.60) missed a
  #     500 ms fence outright
  #
  # 2000 ms is ~100x the in-suite median and 4x the 500 ms fence the observed
  # failure missed, and it stays under ExUnit's 5 s per-test timeout, so a stuck
  # turn still fails — as a stuck turn, not as a flake.
  @turn_fence_ms 2_000

  test "agents-spawn tool creates a specialist and returns its name", %{vid: vid} do
    {coordinator_pid, _name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    specialist_name = "specialist-#{System.unique_integer([:positive])}"
    specialist_slug = specialist_vocation_slug()
    space_id = AgentTestHelpers.current_space_id()

    # The spawn broadcasts `agent:created` on the lobby topic so the
    # sidebar can add the child live. Subscribe before the chat so the
    # broadcast can't slip past us.
    Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

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
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent:created",
                     payload: %{"name" => ^specialist_name, "space_id" => ^space_id}
                   },
                   500

    # The specialist exists in the space.
    assert {:ok, _info} = Nest.Agents.get_info(space_id, specialist_name)
    on_exit(fn -> _ = Supervisor.stop_agent(space_id, specialist_name) end)

    # The coordinator's tool message carries the spawn result.
    coordinator_state = :sys.get_state(coordinator_pid)
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
    child_state = :sys.get_state(specialist_pid)
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

    coordinator_state = :sys.get_state(coordinator_pid)
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

    coordinator_state = :sys.get_state(coordinator_pid)
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

  test "agents-query delivers the query and the answer arrives as a message", %{vid: vid} do
    {coordinator_pid, coordinator_name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = AgentTestHelpers.current_space_id()
    specialist_name = "specialist-#{System.unique_integer([:positive])}"

    # The specialist answers the way an agent is asked to: with `agents-send` back
    # to the requester, which is what discharges the reply it owes. Nothing waits
    # for that, so its turn runs alongside the coordinator's.
    start_mocked_specialist(space_id, specialist_name, [
      {:tool,
       %{
         text: "replying",
         tool_calls: [
           %{
             id: "reply_1",
             name: "agents-send",
             arguments: %{"name" => coordinator_name, "message" => "the specialist answer"}
           }
         ]
       }},
      {:text, "specialist done"}
    ])

    MockClient.set_tool_response(%{
      text: "querying",
      tool_calls: [
        %{
          id: "call_query_1",
          name: "agents-query",
          arguments: %{"name" => specialist_name, "prompt" => "what is 2+2?"}
        }
      ]
    })

    MockClient.set_response("coordinator done")
    MockClient.set_response("coordinator read the answer")

    :ok = Agent.chat(coordinator_pid, "ask the specialist")

    # The tool result is the delivery confirmation, never the answer: there is no
    # wait to return one from.
    assert Eventually.eventually(
             fn -> query_results(coordinator_pid) != [] end,
             timeout: @turn_fence_ms
           )

    assert [%Part.ToolResult{name: "agents-query", content: content, is_error: false}] =
             query_results(coordinator_pid)

    assert content =~ "Query delivered to #{specialist_name}"
    assert content =~ "owes you a reply"

    # The specialist was asked with the peer framing (the query is a peer's
    # message, decision 7)...
    assert Eventually.eventually(
             fn ->
               Enum.any?(
                 agent_texts(specialist_pid(space_id, specialist_name)),
                 &(&1 =~ "[Message from agent \"#{coordinator_name}\"]" and &1 =~ "what is 2+2?")
               )
             end,
             timeout: @turn_fence_ms
           )

    # ...and its answer arrives later as a message in the coordinator's inbox.
    assert Eventually.eventually(
             fn -> Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "the specialist answer")) end,
             timeout: @turn_fence_ms
           )

    # Both turns are over, and the reply discharged the obligation the query
    # created (a give-up notice would be in the coordinator's inbox instead).
    await_idle([coordinator_pid, specialist_pid(space_id, specialist_name)])

    state = :sys.get_state(coordinator_pid)
    AgentTestHelpers.assert_unique_message_indices(state)
    assert Machine.owed_senders(state.live.machine) == []
    refute Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "did not reply"))
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

    coordinator_state = :sys.get_state(coordinator_pid)

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
    specialist_state = :sys.get_state(specialist_pid)

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

    coordinator_state = :sys.get_state(coordinator_pid)

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

  test "agents-wait returns immediately when every other agent is idle", %{vid: vid} do
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
      tool_calls: [%{id: "call_wait_1", name: "agents-wait", arguments: %{}}]
    })

    MockClient.set_response("coordinator done")

    :ok = Agent.chat(coordinator_pid, "wait for the specialist")
    await_idle(coordinator_pid)

    coordinator_state = :sys.get_state(coordinator_pid)
    AgentTestHelpers.assert_unique_message_indices(coordinator_state)

    {:tool, tool_msg} =
      Enum.find(coordinator_state.chat_state.messages, fn
        {:tool, %{parts: parts}} ->
          Enum.any?(parts, &match?(%Part.ToolResult{name: "agents-wait"}, &1))

        _ ->
          false
      end)

    assert [%Part.ToolResult{name: "agents-wait", content: content, is_error: false}] =
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

  # The coordinator's vocation exposes the sub-agent tools.
  defp upsert_tools_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "SubAgentTools #{System.unique_integer([:positive])}",
        description: "Coordinator with sub-agent tools",
        system_prompt: "Coordinate specialists in this space.",
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

  # A distinct vocation for the spawned specialist. Returns its slug.
  defp specialist_vocation_slug do
    {:ok, %Vocations.Vocation{slug: slug}} =
      Vocations.upsert_vocation(%{
        name: "Specialist #{System.unique_integer([:positive])}",
        description: "A specialist",
        system_prompt: "You are a specialist.",
        tools: ["context"],
        modes: %{}
      })

    slug
  end

  # Spawn an independent specialist into `space_id` (via the same
  # `Supervisor.spawn_agent_in_space/3` the `agents-spawn` tool
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
  defp start_mocked_specialist(space_id, name, response) when is_binary(response) do
    start_mocked_specialist(space_id, name, [{:text, response}])
  end

  defp start_mocked_specialist(space_id, name, pending) do
    vocation_slug = specialist_vocation_slug()
    state = coordinator_state(space_id)

    assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation_slug)

    {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)
    Sandbox.allow(Nest.Repo, self(), pid)

    :sys.replace_state(pid, fn st ->
      %{st | client_config: %{st.client_config | client: MockClient}}
    end)

    MockClient.start_link(pid)
    Enum.each(pending, &MockClient.put_pending(pid, &1))

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
    pid
  end

  defp specialist_pid(space_id, name) do
    {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)
    pid
  end

  defp idle?(pid), do: Machine.status_for(:sys.get_state(pid).live.machine) == :idle

  # Wait until every given agent has settled to `:idle`.
  #
  # Polls the machine's own status rather than the `chat:status` broadcast: a
  # missed or reordered broadcast can never be the reason a test fails, and the
  # condition waited on is exactly the one the test-teardown invariant checks.
  # (Not a timing change — over 118 samples the broadcast is delivered at or
  # before the phase flips, so the two observe the same instant.)
  defp await_idle(pids) when is_list(pids) do
    assert Eventually.eventually(
             fn -> Enum.all?(pids, &idle?/1) end,
             timeout: @turn_fence_ms
           )
  end

  defp await_idle(pid), do: await_idle([pid])

  # The `agents-query` tool results the coordinator's transcript holds.
  defp query_results(pid) do
    state = :sys.get_state(pid)

    Enum.flat_map(state.chat_state.messages, fn
      {:tool, %{parts: parts}} ->
        Enum.filter(parts, &match?(%Part.ToolResult{name: "agents-query"}, &1))

      _ ->
        []
    end)
  end

  # The text of every `{:user, _}` message in an agent's transcript.
  defp agent_texts(pid) do
    state = :sys.get_state(pid)

    for {:user, %{parts: parts}} <- state.chat_state.messages, do: text_of(parts)
  end

  defp text_of(parts) do
    Enum.map_join(parts || [], "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
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
