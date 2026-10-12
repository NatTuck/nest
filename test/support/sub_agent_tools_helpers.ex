defmodule Nest.Agents.SubAgentToolsHelpers do
  @moduledoc """
  The harness the sub-agent tool tests share.

  Both files drive the same pair of real agents — a coordinator on a vocation
  that exposes the `agents` tool group, and a specialist spawned into the same
  space with its LLM client swapped for `MockClient` — so the fixtures
  (`coordinator_state/1`, `start_mocked_specialist/3`), the turn fence, and the
  transcript readers (`query_results/1`, `agent_texts/1`) live here rather than
  being duplicated across them.

  Split out of `Nest.Agents.Agent.SubAgentToolsTest` (credo's file cap) when its
  `agents-query` test was split into the two outcomes it actually pins
  (`Nest.Agents.Agent.SubAgentQueryDeliveryTest`).
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  # A turn in these tests is: a mocked LLM call, a real sub-agent spawn or peer
  # delivery (DB writes, a registry insert, a new process), and a second mocked
  # LLM call. `Agent.chat/2` is a `GenServer.cast`, so a fence after it covers
  # that *whole* turn — which is why a 500 ms fence here was a race, not a
  # check. Measured for the scenario in "agents-spawn with a model argument":
  #
  #   * full suite, 24-way concurrency, 40 samples: p50 18.7 ms, max 34.3 ms
  #   * 48 CPU burners, 40 samples: p50 926 ms, max 1534 ms; 39/40 over 500 ms
  #   * the observed 1-in-40 gate failure (seed 200984, load 5.60) missed a
  #     500 ms fence outright
  #   * full suite, `max_cases: 16`: 1051 ms for the first `await_idle/1` in
  #     `sub_agent_tools_test.exs` (the peer-delivery turn), while the file's
  #     later calls settle in ~15 ms — the suite's documented scheduling-race
  #     cost (`notes/sketchy-slow-tests.md` §2/§10: `start_agent/1` serializes on
  #     the global `Mimic.Coordinator` and the single `Nest.Agents.Supervisor`)
  #     landing on a whole turn.
  #
  # 2000 ms is the `#21` cap on every test-side timeout (and so on ExUnit's
  # per-test timeout too), clears the measured spread with headroom, and still
  # fails a stuck turn — as a stuck turn, not as a flake.
  @turn_fence_ms 2_000

  @doc """
  The turn fence (`#{@turn_fence_ms}` ms) for a test's own `eventually/2`.

  See the comment on `@turn_fence_ms` for why a whole turn needs more than the
  project's 500 ms fence.
  """
  @spec turn_fence_ms() :: pos_integer()
  def turn_fence_ms, do: @turn_fence_ms

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
  Whether the agent's machine has settled to `:idle`.
  """
  @spec idle?(pid()) :: boolean()
  def idle?(pid),
    do: Machine.status_for(:sys.get_state(pid, @turn_fence_ms).live.machine) == :idle

  @doc """
  Wait until every given agent has settled to `:idle`.

  Polls the machine's own status rather than the `chat:status` broadcast: a
  missed or reordered broadcast can never be the reason a test fails, and the
  condition waited on is exactly the one the test-teardown invariant checks.
  (Not a timing change — over 118 samples the broadcast is delivered at or
  before the phase flips, so the two observe the same instant.)
  """
  @spec await_idle([pid()] | pid()) :: true
  def await_idle(pids) when is_list(pids) do
    assert Eventually.eventually(
             fn -> Enum.all?(pids, &idle?/1) end,
             timeout: @turn_fence_ms
           )
  end

  def await_idle(pid), do: await_idle([pid])

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
