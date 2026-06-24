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

  def start_agent(attrs) do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Agent, attrs})

    # In async mode, Mimic stubs are per-test-process by default.
    # The agent's `handle_info` and chat task run in separate
    # processes and need explicit access to stubs set on
    # `Mimic.expect(Req, :get, ...)` etc. No-op for tests that
    # don't use Mimic.
    Mimic.allow(OpenAIClient, self(), pid)
    Mimic.allow(Req, self(), pid)
    Mimic.allow(DotConfig, self(), pid)

    # Swap the agent's client_config.client to MockClient and start
    # a per-agent queue. The agent threads its pid through
    # `build_run_opts/1`, so the chat task (in a separate process)
    # calls MockClient.run/2 and finds this test's queue via
    # `opts[:agent_pid]`.
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: MockClient}}
    end)

    # Transfer any pre-existing queued items from the test-pid queue
    # (set up in `setup`) to the per-agent queue. This handles
    # tests that call `MockClient.set_*` before `start_agent/1`.
    test_pid = Process.get(:nest_test_agent_pid)

    if test_pid && test_pid != pid do
      items = MockClient.take_pending(test_pid)
      MockClient.start_link(pid)
      Enum.each(items, &MockClient.put_pending(pid, &1))
    else
      MockClient.start_link(pid)
    end

    Process.put(:nest_test_agent_pid, pid)
    # NB: no MockClient.clear() here — that would wipe the
    # transferred items.

    on_exit(fn ->
      MockClient.stop(pid)
      Process.put(:nest_test_agent_pid, test_pid)
    end)

    {pid, agent_id}
  end

  def get_system_prompt(pid) do
    GenServer.call(pid, :get_system_prompt)
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
end
