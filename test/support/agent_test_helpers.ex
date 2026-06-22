defmodule Nest.Agents.AgentTestHelpers do
  @moduledoc """
  Shared setup and helpers for `Nest.Agents.AgentTest` and its
  split files. The setup creates the per-test MockClient queue and
  `start_agent/1` starts an agent with that queue.
  """

  import ExUnit.Callbacks

  def start_agent(attrs) do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Nest.Agents.Agent, attrs})

    # In async mode, Mimic stubs are per-test-process by default.
    # The agent's `handle_info` and chat task run in separate
    # processes and need explicit access to stubs set on
    # `Mimic.expect(Req, :get, ...)` etc. No-op for tests that
    # don't use Mimic.
    Mimic.allow(Nest.LLM.OpenAIClient, self(), pid)
    Mimic.allow(Req, self(), pid)
    Mimic.allow(Nest.DotConfig, self(), pid)

    # Swap the agent's client_config.client to MockClient and start
    # a per-agent queue. The agent threads its pid through
    # `build_run_opts/1`, so the chat task (in a separate process)
    # calls MockClient.run/2 and finds this test's queue via
    # `opts[:agent_pid]`.
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: Nest.LLM.MockClient}}
    end)

    # Transfer any pre-existing queued items from the test-pid queue
    # (set up in `setup`) to the per-agent queue. This handles
    # tests that call `MockClient.set_*` before `start_agent/1`.
    test_pid = Process.get(:nest_test_agent_pid)

    if test_pid && test_pid != pid do
      items = Nest.LLM.MockClient.take_pending(test_pid)
      Nest.LLM.MockClient.start_link(pid)
      Enum.each(items, &Nest.LLM.MockClient.put_pending(pid, &1))
    else
      Nest.LLM.MockClient.start_link(pid)
    end

    Process.put(:nest_test_agent_pid, pid)
    # NB: no MockClient.clear() here — that would wipe the
    # transferred items.

    on_exit(fn ->
      Nest.LLM.MockClient.stop(pid)
      Process.put(:nest_test_agent_pid, test_pid)
    end)

    {pid, agent_id}
  end

  def get_system_prompt(pid) do
    GenServer.call(pid, :get_system_prompt)
  end
end
