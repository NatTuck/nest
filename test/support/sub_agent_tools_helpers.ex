defmodule Nest.Agents.SubAgentToolsHelpers do
  @moduledoc """
  The harness the sub-agent tool tests share.

  Both files drive the same pair of real agents — a coordinator on a vocation
  that exposes the `agents` tool group, and a specialist spawned into the same
  space with its LLM client swapped for `MockClient` — so the fixtures
  (`coordinator_state/1`, `start_mocked_specialist/3`), the idle fence
  (`await_idle/1`), and the transcript readers (`query_results/1`,
  `agent_texts/1`) live here rather than being duplicated across them.

  Split out of `Nest.Agents.Agent.SubAgentToolsTest` (credo's file cap) when its
  `agents-query` test was split into the two outcomes it actually pins
  (`Nest.Agents.Agent.SubAgentQueryDeliveryTest`).
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  # The idle fence's bound, in ms. It is a failure bound, not the
  # synchronisation: the wait is decided by the arrival of the agent's own
  # `{:chat_status, %{name: …, status: "idle"}}` frame. 1000 ms is the suite's
  # cap on a test-side fence (the teardown probe in `AgentTestLifecycle` is the
  # one documented exception).
  #
  # Sizing, from the measurements this replaced: a turn here is a mocked LLM
  # call, a real sub-agent spawn or peer delivery (DB writes, a registry
  # insert, a new process), and a second mocked LLM call. In the full suite at
  # 24-way concurrency the whole turn measured p50 18.7 ms / max 34.3 ms over
  # 40 samples; under 48 CPU burners, p50 926 ms / max 1534 ms (39 of 40 over
  # 500 ms). 1000 ms clears the in-suite spread with headroom and still fails a
  # genuinely stuck turn — as a stuck turn, not as a flake. See
  # `notes/sketchy-slow-tests.md`.
  @idle_fence_ms 1_000

  @doc """
  Start a real coordinator agent in `space_id` and return its runtime state.

  `spawn_agent_in_space/3` needs a real parent (name + persisted row for
  `parent_id`), which is what this provides.
  """
  @spec coordinator_state(integer()) :: term()
  def coordinator_state(space_id) do
    coordinator_name = "coord-#{System.unique_integer([:positive])}"

    {:ok, ^coordinator_name} =
      Nest.Agents.create_agent(space_id, %{name: "qwen3.5-plus", provider: "model-studio"},
        name: coordinator_name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    AgentTestHelpers.ensure_cleanup(coordinator_name)
    {:ok, pid} = Supervisor.get_agent(space_id, coordinator_name)
    :sys.get_state(pid, 1_000)
  end

  @doc """
  The coordinator's vocation: the `agents` tool group plus `context`.
  """
  @spec upsert_tools_vocation() :: integer()
  def upsert_tools_vocation do
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

  @doc """
  A distinct vocation for a spawned specialist. Returns its slug.
  """
  @spec specialist_vocation_slug() :: String.t()
  def specialist_vocation_slug do
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

  @doc """
  Spawn an independent specialist into `space_id` (via the same
  `Supervisor.spawn_agent_in_space/3` the `agents-spawn` tool uses) and wire it
  up to answer a query:

    * Swap its HTTP client to `MockClient` so its chat turn pulls from a
      per-pid queue instead of a real API.
    * Start that queue and seed `pending` (a single text response, or a list of
      `MockClient` queue items).
    * Allow the specialist pid to use the test process's sandbox connection,
      since `spawn_agent_in_space/3` starts it under the app supervisor (not
      `start_agent/1`), so it doesn't inherit the test's `$callers` — without
      this its message-append DB writes would raise
      `DBConnection.OwnershipError`.

  Returns the specialist's pid; stops it on exit.
  """
  @spec start_mocked_specialist(integer(), String.t(), String.t() | [term()]) :: pid()
  def start_mocked_specialist(space_id, name, response) when is_binary(response) do
    start_mocked_specialist(space_id, name, [{:text, response}])
  end

  def start_mocked_specialist(space_id, name, pending) do
    vocation_slug = specialist_vocation_slug()
    state = coordinator_state(space_id)

    assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation_slug)

    {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)

    # `spawn_agent_in_space/3` does not subscribe this test pid (only
    # `AgentTestHelpers.start_agent/1` does, for the agents it starts), so the
    # call site has to: `await_idle/1` fences on this agent's own idle frame,
    # and a subscription installed after the turn settled would miss it.
    AgentTestHelpers.subscribe_to_agent(space_id, name)

    Sandbox.allow(Nest.Repo, self(), pid)

    :sys.replace_state(
      pid,
      fn st ->
        %{st | client_config: %{st.client_config | client: MockClient}}
      end,
      1_000
    )

    MockClient.start_link(pid)
    Enum.each(pending, &MockClient.put_pending(pid, &1))

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
    pid
  end

  @doc """
  Wait for every given agent to end its turn, on the frame that decides it:
  that agent's own `{:chat_status, %{name: name, status: "idle"}}` broadcast.

  One `assert_receive` per agent, and the arrival of its frame is the whole
  decision — never a poll of `Machine.status_for/1`, which re-reads the state
  the frame already announced and would let a broadcast regression pass as
  success.

  The test pid must already be subscribed to every named agent's topic:
  `AgentTestHelpers.start_agent/1` does that for the agents it starts, and
  `start_mocked_specialist/3` does it for the specialists it spawns. A
  subscription installed after a turn settled would miss the frame it waits
  for, so it has to be in place before the turn.
  """
  @spec await_idle([String.t()] | String.t()) :: :ok
  def await_idle(names) when is_list(names) do
    Enum.each(names, &await_idle/1)
  end

  def await_idle(name) do
    assert_receive {:chat_status, %{name: ^name, status: "idle"}}, @idle_fence_ms
    :ok
  end

  @doc """
  The `agents-query` tool results the coordinator's transcript holds.
  """
  @spec query_results(pid()) :: [Part.ToolResult.t()]
  def query_results(pid) do
    state = :sys.get_state(pid, 1_000)

    Enum.flat_map(state.chat_state.messages, fn
      {:tool, %{parts: parts}} ->
        Enum.filter(parts, &match?(%Part.ToolResult{name: "agents-query"}, &1))

      _ ->
        []
    end)
  end

  @doc """
  The text of every `{:user, _}` message in an agent's transcript.
  """
  @spec agent_texts(pid()) :: [String.t()]
  def agent_texts(pid) do
    state = :sys.get_state(pid, 1_000)

    for {:user, %{parts: parts}} <- state.chat_state.messages, do: parts_text(parts)
  end

  # The text of a message's parts. Private on purpose: `AgentTurnTestHelpers`
  # exports a `text_of/1` for a *message* tuple, and the two would be an
  # ambiguous import for a test that uses both harnesses.
  defp parts_text(parts) do
    Enum.map_join(parts || [], "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end
end
