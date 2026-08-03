defmodule Nest.Agents.AgentTestHelpers do
  @moduledoc """
  Shared setup and helpers for `Nest.Agents.AgentTest` and its
  split files. The setup creates the per-test MockClient queue and
  `start_agent/1` starts an agent with that queue.
  """

  import ExUnit.Callbacks
  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Supervisor
  alias Nest.DotConfig
  alias Nest.LLM.MockClient
  alias Nest.LLM.OpenAIClient
  alias Nest.Messages.Part
  alias Nest.Persistence
  alias Nest.Vocations

  def start_agent(attrs \\ %{}) do
    # Provably unique within a single BEAM (process-global monotonic).
    # Avoids the adjective-animal generator's race risk under async
    # tests and exercises the explicit-name path of
    # `Agents.create_agent/2`.
    agent_name = "agent#{System.unique_integer([:positive])}"
    merged = build_attrs(agent_name, attrs)

    # Use the standard caller interface so the agent is registered
    # in the supervisor's `Registry` (the supervisor path). The
    # helper still does the same setup it always did (Sandbox.allow,
    # Mimic.allow, MockClient swap, queue transfer) but on the
    # supervisor-spawned pid rather than a `start_supervised!` pid.
    #
    # `Agents.create_agent/2` takes `(model, opts)`: the model map
    # carries the LLM model name (used by `enrich_model/1` to look
    # up the provider from DotConfig), and `vocation_id` /
    # `workspace_path` are opts. The agent's registry key (`name:`)
    # is also an opt — the model's `:name` is the LLM identifier
    # (e.g. "qwen3.5-plus"), NOT the agent name. Without `name:`
    # here the supervisor's `generate_unique_name/0` would produce
    # a "clever-raven"-style pair, defeating the
    # `System.unique_integer/1`-based test name.
    {:ok, name} =
      Agents.create_agent(
        Map.get(merged, :model),
        name: Map.get(merged, :name),
        vocation_id: Map.get(merged, :vocation_id),
        workspace_path: Map.get(merged, :workspace_path)
      )

    {:ok, agent_pid} = Supervisor.get_agent(name)

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

    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{name}")

    # Move pre-`start_agent/1` queued items from the test pid's
    # queue to the per-agent queue, then point `:nest_test_agent_pid`
    # at the agent pid so subsequent `MockClient.set_*` calls
    # land on the agent's queue.
    test_pid = Process.get(:nest_test_agent_pid)
    transfer_mock_queue(agent_pid, test_pid)
    Process.put(:nest_test_agent_pid, agent_pid)

    register_on_exit_cleanup(agent_pid, name, test_pid)

    {agent_pid, name}
  end

  # Tests that need `Models.list/0` to reflect auto-discovered
  # models should call `Nest.Test.ModelsTestHelpers.await_models_refresh/1`
  # directly. The default `start_agent/1` here doesn't need to
  # wait — the test config's `qwen3.5-plus` (the default model
  # name) is a static-config entry, which `Models.list/0`
  # returns immediately regardless of scan state.

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
        tools: ["context"],
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

  defp build_attrs(agent_name, attrs) do
    defaults = %{
      name: agent_name,
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
      workspace_path: nil
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
  # `DBConnection.OwnershipError`. `Supervisor.stop_agent/1`
  # is the right cleanup: it terminates the GenServer, and the
  # sandbox's checkin (registered by `DataCase.setup_sandbox/2`)
  # rolls back the agent row automatically. `Agents.delete_agent/1`
  # (which also drops the DB row) is therefore reserved for
  # test bodies where the test pid still owns the connection.
  #
  # Order: unlink the agent first so a normal terminate doesn't
  # propagate `:EXIT` to the (already-dead) test pid. Then
  # stop the agent via the supervisor, unsubscribe from its
  # PubSub topic, and restore the test pid's
  # `:nest_test_agent_pid` process dict key.
  defp register_on_exit_cleanup(pid, agent_id, test_pid) do
    on_exit(fn ->
      Process.unlink(pid)
      MockClient.stop(pid)
      _ = Supervisor.stop_agent(agent_id)
      Phoenix.PubSub.unsubscribe(Nest.PubSub, "agent:#{agent_id}")
      drain_mailbox()
      Process.put(:nest_test_agent_pid, test_pid)
    end)
  end

  def get_system_prompt(pid) do
    GenServer.call(pid, :get_system_prompt)
  end

  @doc """
  Concatenate the text from a list of `Part` structs, in order.
  Used by tests that used to assert on `message.content` to
  bridge to the parts-based representation. Skips non-text
  parts.
  """
  @spec text_from_parts([Part.t()]) :: String.t()
  def text_from_parts(nil), do: ""
  def text_from_parts([]), do: ""

  def text_from_parts(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text
      %Part.Thinking{thinking: text} -> text
      %Part.Refusal{refusal: text} -> text
      _ -> ""
    end)
  end

  @doc false
  # Drain any remaining messages from the test process's
  # mailbox. Called from the on_exit hook so stale
  # messages from one test don't pollute the next
  # test's `assert_receive` patterns.
  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  @doc """
  Drain the test process's mailbox. Useful at the start
  of a test to discard any stale messages from a
  previous test.
  """
  def drain_test_mailbox do
    drain_mailbox()
  end

  @doc """
  Assert every message in `state.chat_state.messages` has a
  unique `index` field. Regression guard for the
  dual-counter bug class: a budget reminder and the next
  response used to share an index, causing the UI's
  `addChatMessage` merge to silently overwrite the reminder
  with the response. Call this at the end of any
  chat-flow integration test that drives a turn to
  completion.

  Compaction markers (which are `{:compaction, _}` tuples
  with their own `index` field) are ignored — only the four
  persisted message roles are asserted.
  """
  def assert_unique_message_indices(state) do
    indices =
      state.chat_state.messages
      |> Enum.flat_map(fn
        {_, %{index: idx}} -> [idx]
        _ -> []
      end)

    duplicates = indices -- Enum.uniq(indices)

    assert duplicates == [],
           "duplicate message indices: #{inspect(duplicates)} — dual-counter bug"
  end

  @doc """
  Seed an entry in the agent's `read_files` cache. Tests
  for the `write_file` "must read first" / "contents
  changed" policy use this to skip the streaming `read_file`
  flow and pre-populate the cache with a specific
  `{mtime, size}` pair. Bypasses the `:check_read_policy`
  introspection clause (the worker never gets a chance to
  refuse) — purely a setup helper.

  `path` MUST be the same string the LLM will pass in
  `write_file.arguments["path"]` (i.e. the agent's
  workspace-relative path; the policy check resolves
  relative paths against `client_config.workspace_path`).

  `mtime` defaults to the current POSIX mtime if omitted,
  and `size` defaults to 0. Both can be overridden when
  the test wants to assert a specific staleness error.
  """
  @spec record_read_file(pid(), String.t(), keyword()) :: :ok
  def record_read_file(pid, path, opts \\ []) do
    %{mtime: mtime, size: size} = File.stat!(path, time: :posix)

    recorded = %{
      mtime: Keyword.get(opts, :mtime, mtime),
      size: Keyword.get(opts, :size, size)
    }

    :sys.replace_state(pid, fn state ->
      new_cache = Map.put(state.chat_state.read_files, path, recorded)
      %{state | chat_state: %{state.chat_state | read_files: new_cache}}
    end)
  end
end
