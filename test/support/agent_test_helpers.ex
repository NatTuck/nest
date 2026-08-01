defmodule Nest.Agents.AgentTestHelpers do
  @moduledoc """
  Shared setup and helpers for `Nest.Agents.AgentTest` and its
  split files. The setup creates the per-test MockClient queue and
  `start_agent/1` starts an agent with that queue.
  """

  import ExUnit.Callbacks
  import ExUnit.Assertions

  alias Nest.Agents.Agent
  alias Nest.DotConfig
  alias Nest.LLM.MockClient
  alias Nest.LLM.OpenAIClient
  alias Nest.Messages.Part
  alias Nest.Persistence
  alias Nest.Vocations

  def start_agent(attrs) do
    agent_name = "test-agent-#{System.unique_integer([:positive])}"
    merged = build_attrs(agent_name, attrs)

    # When persistence is enabled, the Agent's `init/1` calls
    # `persist_initial_system_message/1` → `AgentPersistence.append_message/3`
    # → `Persistence.insert_message/2`. That function looks up
    # the agent row by name and returns `{:error, :agent_not_found}`
    # if it doesn't exist — it does NOT upsert. Without an
    # existing row, every test that enables persistence fires
    # a "Failed to persist message: :agent_not_found" warning
    # during init (and again for every subsequent message append,
    # including during teardown).
    #
    # Insert the row here when persistence is enabled and the
    # caller provided a real vocation_id. The `0` sentinel
    # default would violate the FK constraint; tests that need
    # a real row should pass one via `vocation_id_for_test/0`.
    if persistence_enabled?() and Map.get(merged, :vocation_id) != 0 do
      {:ok, _} =
        Persistence.insert_agent(%{
          name: merged.name,
          model: merged.model,
          vocation_id: merged.vocation_id
        })
    end

    pid = start_supervised!({Agent, merged})

    allow_mimic_stubs(pid)
    swap_to_mock_client(pid)

    # Wait for Nest.Models to populate its cache so the
    # agent's model resolution (which already happened in
    # init/1 above) had a populated cache. Also future agent
    # state changes that look up the model benefit.
    ensure_models_loaded()

    test_pid = Process.get(:nest_test_agent_pid)
    transfer_mock_queue(pid, test_pid)

    Process.put(:nest_test_agent_pid, pid)
    # NB: no MockClient.clear() here — that would wipe the
    # transferred items.

    register_on_exit_cleanup(pid, agent_name, test_pid)

    {pid, agent_name}
  end

  # `Nest.Models.init/1` returns `models: %{}` and asynchronously
  # sends itself `:query_auto_providers` to populate the cache
  # from auto-discovery providers. By the time `start_agent/1`
  # starts an agent (which calls `ChatModel.new/1` →
  # `Models.list/0`), the cache is usually still empty —
  # causing the agent's model-resolution probe to fail with
  # `ModelNotFoundError` and log "could not resolve model" from
  # `Agent.init/1`. Force a refresh and synchronously wait for
  # the GenServer to drain before starting the agent so the
  # static models from `test/data/config.toml` (`qwen3.5-plus`,
  # `pegasus-default-only`, etc.) are visible.
  def ensure_models_loaded do
    Nest.Models.refresh()
    _ = :sys.get_state(Nest.Models)
    :ok
  end

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
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
      # `agents.vocation_id` is NOT NULL, so every test must
      # supply one. Use a sentinel id (never dereferenced) plus
      # `vocation: nil` to short-circuit the system-prompt
      # composition to a minimal default. Tests that need a
      # real vocation (e.g. for the compaction regeneration
      # path) should pass an explicit `vocation_id:` plus
      # `vocation:` from `vocation_id_for_test/0`.
      vocation_id: 0,
      vocation: nil
    }

    merged = Map.merge(defaults, attrs)

    # Pre-fetch the vocation in the test process so the agent's
    # `init/1` has no DB work. The test process owns the sandbox
    # connection (via `DataCase.setup_sandbox`) and uses it for
    # this read; subsequent DB writes from the agent's handlers
    # walk `$callers` back to the test pid and use the same
    # connection. No `Sandbox.allow/3` per agent pid needed.
    #
    # Always overwrite `vocation` so the loaded struct wins
    # over the `nil` default — `Map.put_new_lazy` would skip
    # the upsert because the key is present (with value `nil`).
    if Map.get(merged, :vocation_id) == 0 do
      merged
    else
      vocation_id = Map.fetch!(merged, :vocation_id)
      Map.put(merged, :vocation, Persistence.load_vocation(vocation_id))
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

  # on_exit runs after the test's last assertion. Unsubscribe from
  # the agent's PubSub topic first (so late broadcasts from the
  # still-cleaning-up chat task can't land in the next test's
  # mailbox) then drain anything the test process already
  # received. The unsubscribe + drain is sufficient — `send/2`
  # messages from the chat task (e.g. the `:stopped` reply) are
  # already in the mailbox by the time the test ends.
  defp register_on_exit_cleanup(pid, agent_id, test_pid) do
    on_exit(fn ->
      MockClient.stop(pid)
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
