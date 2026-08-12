defmodule Nest.Agents.AgentTestHelpers do
  @moduledoc """
  Shared setup and helpers for `Nest.Agents.AgentTest` and its
  split files. The setup creates the per-test MockClient queue and
  `start_agent/1` starts an agent with that queue.

  ## Spaces

  Every test that needs an agent also needs a space. `start_agent/1`
  creates a fresh space in the test pid's sandboxed transaction
  and stashes the `space_id` in the test process dict under
  `:nest_test_space_id`. Callers that need the value can read it
  via `current_space_id/0`; everything else routes through it
  implicitly (the agent's session itself carries the `space_id`).

  The on-exit cleanup walks the agent's Supervisor child tree to
  terminate the GenServer; the `spaces` row is rolled back
  automatically by the sandbox when the test exits.

  ## Helpers split out

  The general-purpose test helpers (text serialization, index
  uniqueness checks, file cache seeding, pid-down waits) live
  in `Nest.Agents.AgentTestAssertions` and
  `Nest.Agents.AgentTestLifecycle` so this module stays under
  the credo 500-line cap.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  require Logger

  # Any vocation that gets any `agents/*` tool gets all of them
  # (matching the seed `agents_tools` invariant).
  @agents_tools ["agents/spawn", "agents/query", "agents/list", "agents/archive"]

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.AgentTestAssertions
  alias Nest.Agents.AgentTestLifecycle
  alias Nest.Agents.Supervisor
  alias Nest.DotConfig
  alias Nest.LLM.MockClient
  alias Nest.LLM.OpenAIClient
  alias Nest.Messages.Part
  alias Nest.Persistence
  alias Nest.Spaces
  alias Nest.Vocations

  defdelegate text_from_parts(parts), to: AgentTestAssertions
  defdelegate assert_unique_message_indices(state), to: AgentTestAssertions
  defdelegate record_read_file(pid, path, opts \\ []), to: AgentTestAssertions
  defdelegate wait_for_pid_down(space_id, name, timeout \\ 100), to: AgentTestLifecycle

  @space_id_key :nest_test_space_id

  @doc """
  Returns the `space_id` stored in the test process dict by the
  most recent `start_agent/1` call. Tests that bypass
  `start_agent/1` (e.g. supervisor tests) should call
  `create_test_space/0` directly and stash the result with
  `put_space_id/1`.
  """
  def current_space_id do
    case Process.get(@space_id_key) do
      nil -> raise "no test space_id set — call start_agent/1 or create_test_space/0 first"
      id -> id
    end
  end

  def put_space_id(space_id), do: Process.put(@space_id_key, space_id)

  @doc """
  Assert a shell_cmd tool result succeeded (`is_error == false`).

  When the command errored (`is_error == true`), dump the full
  result struct (including `content`, `is_error`, `tool_call_id`,
  `name`, `arguments`) via `Logger.error/1` before asserting, so a
  real shell failure (bwrap exit, tmp-dir `:enoent`, "Unknown tool")
  is visible in the test output instead of surfacing as a bare
  `is_error == false` assertion failure.
  """
  def assert_shell_ok(%Part.ToolResult{} = result) do
    if result.is_error do
      Logger.error("shell_cmd failed: #{inspect(result, pretty: true)}")
    end

    assert result.is_error == false
    result
  end

  @doc """
  Create a fresh space for the test. Returns `{:ok, space_id}`.
  The row is rolled back by the sandbox on test exit.
  """
  def create_test_space do
    {:ok, space} =
      Spaces.create_space(nil, %{
        name: "test-space-#{System.unique_integer([:positive])}",
        slug: "test-space-#{System.unique_integer([:positive])}"
      })

    Process.put(@space_id_key, space.id)
    {:ok, space.id}
  end

  def start_agent(attrs \\ %{}) do
    # Provably unique within a single BEAM (process-global monotonic).
    # Avoids the adjective-animal generator's race risk under async
    # tests and exercises the explicit-name path of
    # `Agents.create_agent/3`.
    agent_name = "agent#{System.unique_integer([:positive])}"

    # Create a fresh space for this agent. The space_id is the
    # first positional arg to `Agents.create_agent/3`; everything
    # else stays in opts.
    {:ok, space_id} = create_test_space()
    merged = build_attrs(agent_name, space_id, attrs)

    # Use the standard caller interface so the agent is registered
    # in the supervisor's `Registry` (the supervisor path). The
    # helper still does the same setup it always did (Sandbox.allow,
    # Mimic.allow, MockClient swap, queue transfer) but on the
    # supervisor-spawned pid rather than a `start_supervised!` pid.
    #
    # `Agents.create_agent/3` takes `(space_id, model, opts)`: the
    # model map carries the LLM model name (used by `enrich_model/1`
    # to look up the provider from DotConfig), and `vocation_id` /
    # `workspace_path` are opts. The agent's registry key (`name:`)
    # is also an opt — the model's `:name` is the LLM identifier
    # (e.g. "qwen3.5-plus"), NOT the agent name. Without `name:`
    # here the supervisor's `generate_unique_name_for_space/1`
    # would produce a "clever-raven"-style pair, defeating the
    # `System.unique_integer/1`-based test name.
    {:ok, name} = create_agent_via_supervisor(space_id, merged)

    {:ok, agent_pid} = Supervisor.get_agent(space_id, name)

    bridge_test_to_agent(agent_pid, space_id, name)

    {agent_pid, name}
  end

  # Hand the test process ownership links to the freshly-spawned
  # agent pid: DB sandbox checkout, Mimic stubs, MockClient swap,
  # PubSub subscription, mock-queue transfer, on_exit cleanup.
  # Factored out so `start_agent/1` doesn't blow past the credo
  # "function complexity" threshold.
  defp bridge_test_to_agent(agent_pid, space_id, name) do
    # `Process.link/1` makes the test process crash if the agent
    # dies unexpectedly. Tests that intentionally kill the agent
    # must set `Process.flag(:trap_exit, true)` and assert on the
    # resulting `:EXIT` message.
    Process.link(agent_pid)

    # Runtime writes from the agent pid — chat message appends,
    # runtime model changes — need explicit access to the test
    # pid's checked-out connection.
    Sandbox.allow(Nest.Repo, self(), agent_pid)

    # Mimic stubs are scoped to the test pid by default; the
    # spawned agent pid can't see them without explicit `allow`.
    allow_mimic_stubs(agent_pid)

    # Swap the agent's HTTP client to MockClient so chat turns use
    # the per-test queue instead of real `dashscope.aliyuncs.com`
    # requests.
    swap_to_mock_client(agent_pid)

    # Drop any prior subscription this test pid holds. The
    # `on_exit` hook in `register_on_exit_cleanup/3` runs in a
    # separate ExUnit runner process (async tests), so its
    # `Phoenix.PubSub.unsubscribe/2` doesn't reach the test
    # pid — `Registry.unregister/2` always targets `self()`.
    # Without an explicit drop here, the test pid keeps stale
    # subscriptions to dead agents' topics across tests; a
    # sibling test's `:chat_message` or `:chat_status`
    # broadcast then leaks into this test's mailbox and
    # matches `assert_received` patterns prematurely. The
    # bug surfaces most visibly in `agent_compaction_test.exs:82`
    # under parallel coverage runs.
    drop_stale_pubsub_subscription()
    subscribe_to_agent_topic(space_id, name)

    # Move pre-`start_agent/1` queued items from the test pid's
    # queue to the per-agent queue, then point `:nest_test_agent_pid`
    # at the agent pid so subsequent `MockClient.set_*` calls
    # land on the agent's queue.
    test_pid = Process.get(:nest_test_agent_pid)
    transfer_mock_queue(agent_pid, test_pid)
    Process.put(:nest_test_agent_pid, agent_pid)

    register_on_exit_cleanup(agent_pid, space_id, name)
  end

  # Tests that need `Models.list/0` to reflect auto-discovered
  # models should call `Nest.Test.ModelsTestHelpers.await_models_refresh/1`
  # directly. The default `start_agent/1` here doesn't need to
  # wait — the test config's `qwen3.5-plus` (the default model
  # name) is a static-config entry, which `Models.list/0`
  # returns immediately regardless of scan state.

  @doc """
  Standalone cleanup registration for tests that bypass
  `start_agent/1` — for example, supervisor tests that call
  `Supervisor.fetch_or_start_agent/2` directly to exercise
  the spawn API, auto-name tests that omit `name:` to test
  the registry-based generator, or terminate-during-test
  cases that want raw `Process.flag(:trap_exit, true)` +
  `Process.exit(pid, :shutdown)` semantics.

  Registers `on_exit(fn -> wait_for_pid_down(space_id, name) end)`.
  The `wait_for_pid_down/3` helper sends
  `Process.exit(pid, :shutdown)` and BLOCKS on a single
  `:DOWN` message (NOT a drain loop — see comment on
  `wait_for_pid_down/3`). This guarantees the agent
  GenServer has fully terminated (mailbox can no longer
  fire DB calls) before the test exits the cleanup
  callback — closing the parallel-test ownership race
  window.

  Note: this helper does NOT delete the `agents` DB row.
  The `DataCase` setup's automatic sandbox rollback already
  covers that — running a DB write in the on_exit process
  would fail with `DBConnection.OwnershipError` because
  the on_exit runner doesn't own the test's sandbox
  checkout. The supervisor stop is what prevents the
  next test from racing against a ghost pid's DB calls.

  Pair with `vocation_id_for_test/0` for tests that need
  a vocation but don't want the full `start_agent/1` setup.

      {:ok, name} =
        Agents.create_agent(current_space_id(), test_model(),
          name: fresh_name(),
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        )

      AgentTestHelpers.ensure_cleanup(name)
  """
  def ensure_cleanup(name) do
    space_id = current_space_id()

    on_exit(fn ->
      _ = Supervisor.stop_agent(space_id, name)
      AgentTestLifecycle.wait_for_pid_down(space_id, name)
    end)
  end

  @doc """
  Returns a `vocation_id` for use in test attrs that bypass
  `start_agent/1` (e.g. tests that call `start_supervised!({Agent, ...})`
  directly). Upserts a shared "Test Default" vocation in the
  calling process (sandboxed connection) and returns its id.

  `agents.vocation_id` is `NOT NULL`, so every test that
  starts an agent must supply one. This helper is the
  no-ceremony way to get a valid id.
  """
  def vocation_id_for_test do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "Test Default",
        description: "Default vocation for tests",
        system_prompt: "You are a helpful test assistant.",
        tools: ["context" | @agents_tools],
        modes: %{
          "chat" => %{
            "description" => "General conversation.",
            "caps" => %{
              "net" => false,
              "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
            }
          }
        }
      })

    vid
  end

  @doc """
  Returns a fresh `vocation_id` whose `:tools` list includes the
  shell/file tools (`shell_cmd`, `read_file`, `write_file`,
  `edit`) — for tests that exercise the tool-call flow and need
  the tools to actually be registered on the agent.

  Every call creates a new row (`create_vocation`, not
  `upsert_vocation`) so tests don't fight over the same row. The
  per-test `setup` blocks in the consumer files iterate
  `Vocations.delete_vocation/1` to clean up afterwards, so a fresh
  row per call is safe under `async: true` parallel runs.

  Returns `vocation.id` so the caller can pass it as
  `vocation_id:` to `start_agent/1`.
  """
  def programmer_vocation_id_for_test do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Test Programmer (#{Elixir.System.unique_integer([:positive])})",
        description: "A coding assistant that can read and write files in a workspace",
        system_prompt: "Test programmer prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context" | @agents_tools],
        # Single mode — keeps the Agent's default mode = "chat"
        # and the chat-message prefix `[mode: chat]` that tests
        # assert on. `Map.keys/1` of a single-entry map returns
        # that one key as the initial mode regardless of
        # internal hash ordering, so we're not at the mercy of
        # Elixir's map iteration order.
        modes: %{
          "chat" => %{
            "description" => "General conversation.",
            "caps" => %{
              "net" => false,
              "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
            }
          }
        }
      })

    vocation.id
  end

  defp build_attrs(agent_name, space_id, attrs) do
    defaults = %{
      name: agent_name,
      space_id: space_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      # `agents.vocation_id` is NOT NULL and FKs to `vocations.id`.
      # Insert a fresh "Test Default" vocation in the test pid's
      # sandboxed transaction; the id resolves before
      # `Agent.start_link/1` runs `Persistence.insert_agent/1`.
      # Tests that need a different vocation can override
      # `:vocation_id` (and optionally `:vocation`) in `attrs`.
      vocation_id: vocation_id_for_test(),
      vocation: nil,
      # `workspace_path` is optional in `agents.workspace_path`
      # (nullable column) and `Init.build_state/2` reads it via
      # `Map.get/2` so `nil` is fine. Tests that need a workspace
      # can override `:workspace_path` in `attrs`.
      workspace_path: nil,
      # Multi-user identity. Defaults to `nil` so tests that
      # pre-date the multi-user migration keep working
      # without changes. Tests that exercise ownership /
      # shared-agent rules should set `:created_by_user_id`
      # explicitly so the joined socket and the agent row
      # line up.
      created_by_user_id: nil,
      shared: false
    }

    merged = Map.merge(defaults, attrs)

    # Pre-fetch the vocation in the test process so the agent's
    # `init/1` has no DB work. The test process owns the sandbox
    # connection (via `DataCase.setup_sandbox`) and uses it for
    # this read; subsequent DB writes from the agent's handlers
    # need explicit `Sandbox.allow/3` (see `start_agent/1`) since
    # they happen in the spawned child pid which doesn't inherit
    # `$callers` via `start_supervised!`.
    #
    # Always overwrite `vocation` so the loaded struct wins
    # over the `nil` default — `Map.put_new_lazy` would skip
    # the upsert because the key is present (with value `nil`).
    case Map.get(merged, :vocation_id) do
      id when is_integer(id) and id != 0 ->
        Map.put(merged, :vocation, Persistence.load_vocation(id))

      _ ->
        merged
    end
  end

  # In async mode, Mimic stubs are per-test-process by default.
  # The agent's `handle_info` and chat task run in separate
  # processes and need explicit access to stubs set on
  # `Mimic.expect(Req, :get, ...)` etc. No-op for tests that
  # don't use Mimic.
  defp allow_mimic_stubs(pid) do
    Mimic.allow(OpenAIClient, self(), pid)
    Mimic.allow(Req, self(), pid)
    Mimic.allow(DotConfig, self(), pid)
  end

  # Swap the agent's client_config.client to MockClient and start
  # a per-agent queue. The agent threads its pid through
  # `build_run_opts/1`, so the chat task (in a separate process)
  # calls MockClient.run/2 and finds this test's queue via
  # `opts[:agent_pid]`.
  defp swap_to_mock_client(pid) do
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: MockClient}}
    end)
  end

  # Transfer any pre-existing queued items from the test-pid queue
  # (set up in `setup`) to the per-agent queue. This handles
  # tests that call `MockClient.set_*` before `start_agent/1`.
  defp transfer_mock_queue(pid, test_pid) do
    if test_pid && test_pid != pid do
      items = MockClient.take_pending(test_pid)
      MockClient.start_link(pid)
      Enum.each(items, &MockClient.put_pending(pid, &1))
    else
      MockClient.start_link(pid)
    end
  end

  # on_exit runs after the test's last assertion, in a SEPARATE
  # ExUnit runner process that does NOT own the test pid's
  # sandbox checkout — so any DB write here would fail with
  # `DBConnection.OwnershipError`. `Supervisor.stop_agent/2`
  # is the right cleanup: it terminates the GenServer, and the
  # sandbox's checkin (registered by `DataCase.setup_sandbox/2`)
  # rolls back the agent row automatically. `Agents.delete_agent/2`
  # (which also drops the DB row) is therefore reserved for
  # test bodies where the test pid still owns the connection.
  #
  # Order: unlink the agent first so a normal terminate doesn't
  # propagate `:EXIT` to the (already-dead) test pid. Then
  # stop the agent via the supervisor, wait for the agent
  # GenServer to fully terminate before returning (so its
  # mailbox can't fire DB calls after the test pid has
  # exited), and unsubscribe from its PubSub topic.
  #
  # Note: this on_exit runs in a SEPARATE ExUnit runner process,
  # so it CANNOT mutate the test process's process dict. Any
  # attempt to restore `:nest_test_agent_pid` / `:nest_test_subscribed_topic`
  # here would be dead code (the write wouldn't reach the test
  # pid). Those keys are instead refreshed at the start of the
  # next `start_agent/1` (see `drop_stale_pubsub_subscription/0`
  # and the `Process.put` in `bridge_test_to_agent/3`).
  #
  # The wait-for-DOWN is a SINGLE-MESSAGE receive — not a
  # drain loop. The drain loop used to live here was killed
  # with fire and can *NEVER EVER* come back.
  defp register_on_exit_cleanup(pid, space_id, agent_id) do
    on_exit(fn ->
      Process.unlink(pid)
      MockClient.stop(pid)
      _ = Supervisor.stop_agent(space_id, agent_id)
      AgentTestLifecycle.wait_for_pid_down(space_id, agent_id)
      Phoenix.PubSub.unsubscribe(Nest.PubSub, "agent:#{space_id}:#{agent_id}")
    end)
  end

  def get_system_prompt(pid) do
    GenServer.call(pid, :get_system_prompt)
  end

  # Drop any leftover PubSub subscription left over from a
  # prior test in this same pid. `on_exit` runs in a separate
  # ExUnit runner process and can't unsubscribe the test pid,
  # so each `start_agent/1` clears any topic the test pid
  # still holds before subscribing to the new agent's topic.
  # The current topic is recorded in the `:nest_test_subscribed_topic`
  # process-dict key; absence means nothing to drop.
  defp drop_stale_pubsub_subscription do
    case Process.get(:nest_test_subscribed_topic) do
      nil -> :ok
      old_topic -> Phoenix.PubSub.unsubscribe(Nest.PubSub, old_topic)
    end

    Process.delete(:nest_test_subscribed_topic)
  end

  defp subscribe_to_agent_topic(space_id, name) do
    topic = "agent:#{space_id}:#{name}"
    Phoenix.PubSub.subscribe(Nest.PubSub, topic)
    Process.put(:nest_test_subscribed_topic, topic)
  end

  # Run the agent through the supervisor path (the standard
  # caller interface). Pure data shaping — no DB writes, no
  # process spawning here; the supervisor owns both. Returns
  # the new agent's registry name on success.
  defp create_agent_via_supervisor(space_id, attrs) do
    Agents.create_agent(
      space_id,
      Map.get(attrs, :model),
      name: Map.get(attrs, :name),
      vocation_id: Map.get(attrs, :vocation_id),
      workspace_path: Map.get(attrs, :workspace_path),
      created_by_user_id: Map.get(attrs, :created_by_user_id),
      shared: Map.get(attrs, :shared, false)
    )
  end
end
