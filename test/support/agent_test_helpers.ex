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

  The in-process teardown (`AgentTestLifecycle.stop_test_agents/0`)
  stops every agent the test started, before the sandbox connection is
  checked in; the `spaces` row is rolled back automatically by the
  sandbox when the test exits. The `on_exit` hooks only watch (see
  `AgentTestLifecycle.detect_leaked_agent/2`).

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

  # Test vocations grant capabilities by group. `agents` bundles
  # spawn/query/list/archive/batch plus `models-list`.
  @tool_groups ["file", "shell", "context", "agents"]

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
  defdelegate assert_unique_message_indices(messages), to: AgentTestAssertions
  defdelegate record_read_file(pid, path, opts \\ []), to: AgentTestAssertions
  # One default, one owner: the 2-arity form delegates to `AgentTestLifecycle`'s
  # 2-arity form, so both spellings use the same `@stop_ms` bound. That bound is
  # the tight *detector* — for a caller fencing a test body on an agent that must
  # already be idle. A caller that is *cleaning up* (an `on_exit`) wants the
  # generous cleanup bound instead, and says so by passing
  # `AgentTestLifecycle.cleanup_ms/0` as the third argument rather than silently
  # inheriting the detector's 10 ms.
  defdelegate wait_for_pid_down(space_id, name), to: AgentTestLifecycle
  defdelegate wait_for_pid_down(space_id, name, timeout), to: AgentTestLifecycle

  @space_id_key :nest_test_space_id

  # Every per-agent PubSub topic this test pid is subscribed to, newest first.
  # A test may wait on more than one agent (a coordinator and its specialist, an
  # agent and a peer it owes a reply to), and a wait is a fence on the frame that
  # decides it — so the test pid has to be subscribed to *every* agent it waits
  # on, not just the last one `start_agent/1` happened to start.
  @subscribed_topics_key :nest_test_subscribed_topics

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

  @doc """
  Deliver a compaction result to an agent by driving the production
  compaction entry: put the machine into the compactor's `:generating`
  phase with `entry = {:compaction, [], carried_entry}`, then send the
  `{:http_response, ref, %RunResponse{}}` the executor's commit path
  consumes (via `Compaction.commit_compaction/2`).
  """
  def send_compaction_done(agent_pid, summary_text, carried_entry) do
    ref = make_ref()

    # Put the machine into the compactor's generating phase with an empty
    # staged request and a live worker ref, then deliver the HTTP response.
    :sys.replace_state(
      agent_pid,
      fn state ->
        machine = state.live.machine

        machine = %{
          machine
          | kind: :compaction,
            phase: :generating,
            entry: {:compaction, [], carried_entry},
            work: %{
              machine.work
              | worker_kind: :http,
                worker_ref: ref,
                active_message_index: state.chat_state.next_message_index
            }
        }

        %{state | live: %{state.live | machine: machine}}
      end,
      1_000
    )

    send(
      agent_pid,
      {:http_response, ref, %Nest.LLM.RunResponse{text: summary_text, usage: nil}}
    )
  end

  # Hand the test process ownership links to the freshly-spawned
  # agent pid: DB sandbox checkout, Mimic stubs, MockClient swap,
  # PubSub subscription, mock-queue transfer, on_exit cleanup.
  # Factored out so `start_agent/1` doesn't blow past the credo
  # "function complexity" threshold.
  defp bridge_test_to_agent(agent_pid, space_id, name) do
    # No registration needed: the per-test teardown `test` wrapper
    # (`Nest.TestSupport.AgentTestMacro`) discovers every agent whose
    # space is visible in this test's sandbox transaction via
    # `Nest.Agents.Registry.list_all/0`, including production-spawned
    # children, and asserts zero remaining (idle) agents.

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
    drop_stale_pubsub_subscriptions()
    subscribe_to_agent(space_id, name)

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

  Registers the cleanup that is safe *after* the test process (the
  SQL-sandbox connection owner) has exited: dropping this test's subscription
  to the agent's PubSub topic, and the leak check
  (`AgentTestLifecycle.detect_leaked_agent/2`) for the path where the test was
  killed at its per-test deadline. The agent itself is stopped by the test
  body's teardown (`AgentTestLifecycle.stop_test_agents/0`), which discovers
  every agent whose space is visible in this test's sandbox transaction — so an
  `on_exit` stop here would be redundant, and it would run `terminate/2` (and
  its DB work) on a connection whose owner has already exited. That is the
  `DBConnection.ConnectionError: owner ... exited` this helper used to be able
  to produce; see `register_on_exit_cleanup/3` for the full reasoning.

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

    on_exit(fn -> Phoenix.PubSub.unsubscribe(Nest.PubSub, "agent:#{space_id}:#{name}") end)

    # The in-process teardown (`AgentTestLifecycle.stop_test_agents/0`) stops
    # this agent on the normal path, but a test killed at its per-test deadline
    # skips the wrapper entirely — and an agent this helper started is *not*
    # linked to the test process, so without this it would leak with nothing to
    # notice it. `detect_leaked_agent/2` only watches, and issues no query, which
    # is what makes it safe in an `on_exit`.
    on_exit(fn -> AgentTestLifecycle.detect_leaked_agent(space_id, name) end)
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
    {id, _slug} = ensure_test_default_vocation()
    id
  end

  @doc """
  The slug of the per-test default vocation created by
  `vocation_id_for_test/0`. Ensures the row exists as a side effect, for
  tests that pass a vocation slug (e.g. the lobby `create_space`
  payload).
  """
  def vocation_slug_for_test do
    {_id, slug} = ensure_test_default_vocation()
    slug
  end

  # Create (once per test process) a uniquely-named default vocation and
  # cache `{id, slug}` in the process dict. A unique name → unique slug
  # avoids the cross-test lock contention a shared fixed-slug row would
  # cause under parallel `async: true` runs.
  defp ensure_test_default_vocation do
    case Process.get(:nest_test_default_vocation) do
      {id, slug} ->
        {id, slug}

      nil ->
        {:ok, %Vocations.Vocation{id: id, slug: slug}} =
          Vocations.create_vocation(%{
            name: "Test Default #{System.unique_integer([:positive])}",
            description: "Default vocation for tests",
            system_prompt: "You are a helpful test assistant.",
            tools: ["context", "agents"],
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

        Process.put(:nest_test_default_vocation, {id, slug})
        {id, slug}
    end
  end

  @doc """
  Returns a fresh `vocation_id` whose `:tools` list includes the
  shell/file tools (`shell-cmd`, `file-read`, `file-write`,
  `file-edit`) — for tests that exercise the tool-call flow and need
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
        tools: @tool_groups,
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

  @doc """
  Returns a fresh `vocation_id` with three modes: `"chat"` (the default,
  since `Vocations.default_mode/1` is the lexicographically first mode),
  `"plan"`, and `"review"`. For tests that need a mode the agent is not
  already in — e.g. asserting that a queued message's requested mode is
  applied when it is delivered.
  """
  def multi_mode_vocation_id_for_test do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Test Multi Mode (#{Elixir.System.unique_integer([:positive])})",
        description: "Multi-mode vocation for mode-delivery tests",
        system_prompt: "Test multi-mode prompt.",
        tools: @tool_groups,
        modes: %{
          "chat" => %{
            "description" => "General conversation.",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          },
          "plan" => %{
            "description" => "Planning.",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          },
          "review" => %{
            "description" => "Review.",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
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
  #
  # "No-op for tests that don't use Mimic" is now literal. `allow/3` is a
  # `GenServer.call` to the one global `Mimic.Coordinator`, and an allowance
  # row for a module this test owns no stub for cannot do anything: the
  # dispatch path resolves the owner and then finds no stub, so it runs the
  # original anyway. Measured on this suite: **all 377** `start_agent/1`
  # calls in a run own none of the three, so 1131 of the run's 1209
  # `allow/3` calls were provably inert — 94% of the last global rendezvous
  # in the start path. `Mimic.Coordinator` is the public ETS table Mimic
  # itself reads ownership rows from, and `{pid, module}` is the row
  # `Mimic.Server.register_owner/4` inserts for `stub`/`expect`/`reject`;
  # if Mimic ever changes either, this reads `false` and the allowances the
  # tests actually need stop being made — a loud failure, not a silent one.
  defp allow_mimic_stubs(pid) do
    [OpenAIClient, Req, DotConfig]
    |> Enum.filter(&owns_stubs?/1)
    |> Enum.each(&Mimic.allow(&1, self(), pid))
  end

  defp owns_stubs?(module), do: :ets.member(Mimic.Coordinator, {self(), module})

  # Swap the agent's client_config.client to MockClient and start
  # a per-agent queue. The agent threads its pid through
  # `build_run_opts/1`, so the chat task (in a separate process)
  # calls MockClient.run/2 and finds this test's queue via
  # `opts[:agent_pid]`.
  defp swap_to_mock_client(pid) do
    :sys.replace_state(
      pid,
      fn state ->
        %{state | client_config: %{state.client_config | client: MockClient}}
      end,
      1_000
    )
  end

  # Transfer any pre-existing queued items from the test-pid queue
  # (set up in `setup`) to the per-agent queue. This handles
  # tests that call `MockClient.set_*` before `start_agent/1`.
  defp transfer_mock_queue(pid, test_pid) do
    if test_pid && test_pid != pid do
      items = MockClient.take_pending(test_pid)

      # The test-pid queue was started by the test's own `setup`
      # (`MockClient.start_link/0`). Once its items have been moved to
      # the agent-pid queue it is never used again, and `MockClient`
      # starts it with `Agent.start/2` (unlinked, named), so nothing
      # else stops it. Stop it here — but only when the previous owner
      # is the test process itself, not an earlier agent whose queue
      # must stay alive.
      if test_pid == self(), do: MockClient.stop(test_pid)

      MockClient.start_link(pid)
      Enum.each(items, &MockClient.put_pending(pid, &1))
    else
      MockClient.start_link(pid)
    end
  end

  # on_exit runs after the test's last assertion, in a SEPARATE
  # ExUnit runner process that does NOT own the test pid's
  # sandbox checkout — so any DB work here runs on a connection
  # whose owner has already exited.
  #
  # The agent is stopped by the test body's teardown
  # (`AgentTestLifecycle.stop_test_agents/0`), which runs while the
  # checkout is still live. This hook therefore deliberately does NOT stop it:
  # `Supervisor.stop_agent/2` and `wait_for_pid_down/2` both run `terminate/2`
  # (which queries — e.g. a child's reply give-up), on that dead connection —
  # exactly the `DBConnection.ConnectionError: owner ... exited` this file used
  # to produce. Keep only what is safe once the owner is gone.
  #
  # Order: unlink the agent first so a normal terminate doesn't
  # propagate `:EXIT` to the (already-dead) test pid, then stop the mock
  # client's queue, then unsubscribe from the agent's PubSub topic.
  #
  # Note: this on_exit runs in a SEPARATE ExUnit runner process,
  # so it CANNOT mutate the test process's process dict. Any
  # attempt to restore `:nest_test_agent_pid` / `:nest_test_subscribed_topics`
  # here would be dead code (the write wouldn't reach the test
  # pid). Those keys are instead refreshed at the start of the
  # next `start_agent/1` (see `drop_stale_pubsub_subscriptions/0`
  # and the `Process.put` in `bridge_test_to_agent/3`). The
  # `unsubscribe/2` below is therefore the same kind of no-op for
  # the test pid — it only unsubscribes this runner process — and is
  # kept as the belt to `drop_stale_pubsub_subscriptions/0`'s braces.
  # The two per-test on_exit *closures*, as named functions. The registered
  # callbacks are exactly what these return, so a test can invoke the callback
  # that is really registered rather than a lookalike — a stop re-added to
  # either body is then exercised instead of escaping — and can find them by
  # their keys (`cleanup_key/2`, `leak_key/2`). Both must issue no query: they
  # run in a process that does not own this test's sandbox connection.
  @doc false
  @spec per_test_on_exit_cleanup(pid(), integer(), String.t()) :: (-> :ok)
  def per_test_on_exit_cleanup(pid, space_id, agent_id) do
    fn -> on_exit_cleanup(pid, space_id, agent_id) end
  end

  @doc false
  @spec per_test_on_exit_leak_check(integer(), String.t()) :: (-> term())
  def per_test_on_exit_leak_check(space_id, agent_id) do
    fn -> AgentTestLifecycle.detect_leaked_agent(space_id, agent_id) end
  end

  defp on_exit_cleanup(pid, space_id, agent_id) do
    Process.unlink(pid)
    MockClient.stop(pid)
    Phoenix.PubSub.unsubscribe(Nest.PubSub, "agent:#{space_id}:#{agent_id}")
  end

  defp register_on_exit_cleanup(pid, space_id, agent_id) do
    on_exit(cleanup_key(space_id, agent_id), per_test_on_exit_cleanup(pid, space_id, agent_id))
    on_exit(leak_key(space_id, agent_id), per_test_on_exit_leak_check(space_id, agent_id))
  end

  @doc false
  def cleanup_key(space_id, agent_id), do: {__MODULE__, :cleanup, space_id, agent_id}

  @doc false
  def leak_key(space_id, agent_id), do: {__MODULE__, :leak_check, space_id, agent_id}

  def get_system_prompt(pid) do
    GenServer.call(pid, :get_system_prompt)
  end

  # Drop every PubSub subscription left over from a
  # prior test in this same pid. `on_exit` runs in a separate
  # ExUnit runner process and can't unsubscribe the test pid,
  # so each `start_agent/1` clears every topic the test pid
  # still holds before subscribing to the new agent's topic.
  # The current topics are recorded in the `:nest_test_subscribed_topics`
  # process-dict key; absence means nothing to drop.
  defp drop_stale_pubsub_subscriptions do
    Enum.each(subscribed_topics(), &Phoenix.PubSub.unsubscribe(Nest.PubSub, &1))

    Process.delete(@subscribed_topics_key)
  end

  @doc """
  Subscribe this test pid to `space_id`/`name`'s per-agent topic and record it
  so the next `start_agent/1` can drop it.

  `start_agent/1` calls this for the agent it starts. A test that starts an
  agent by another path — `SubAgentToolsHelpers.start_mocked_specialist/3`'s
  `Supervisor.spawn_agent_in_space/3`, or a hand-rolled peer — must call it at
  that call site, *before* the turn it is going to wait on: the idle fence is
  an arrival (`assert_receive` on `{:chat_status, %{name: name, status:
  "idle"}}`), so a subscription installed after the turn settled would miss the
  frame it is waiting for.

  The status payload is self-identifying (`name`, `space_id`), so a test
  subscribed to several agents' topics fences on the one it is waiting for.
  """
  @spec subscribe_to_agent(integer(), String.t()) :: String.t()
  def subscribe_to_agent(space_id, name) do
    topic = "agent:#{space_id}:#{name}"

    # Idempotent: a second `Phoenix.PubSub.subscribe/2` to the same topic
    # delivers every frame twice and leaks the extra subscription, so the
    # already-subscribed case is a no-op rather than a re-subscribe.
    if topic in subscribed_topics() do
      topic
    else
      Phoenix.PubSub.subscribe(Nest.PubSub, topic)
      Process.put(@subscribed_topics_key, [topic | subscribed_topics()])
      topic
    end
  end

  defp subscribed_topics, do: Process.get(@subscribed_topics_key, [])

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
