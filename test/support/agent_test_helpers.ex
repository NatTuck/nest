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
    pid = start_supervised!({Agent, build_attrs(agent_id, attrs)})

    allow_mimic_stubs(pid)
    swap_to_mock_client(pid)

    test_pid = Process.get(:nest_test_agent_pid)
    transfer_mock_queue(pid, test_pid)

    Process.put(:nest_test_agent_pid, pid)
    # NB: no MockClient.clear() here — that would wipe the
    # transferred items.

    register_on_exit_cleanup(pid, agent_id, test_pid)

    {pid, agent_id}
  end

  defp build_attrs(agent_id, attrs) do
    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    Map.merge(defaults, attrs)
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
end
