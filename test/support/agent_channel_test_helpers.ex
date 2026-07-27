defmodule NestWeb.AgentChannelTestHelpers do
  @moduledoc """
  Shared helpers for `NestWeb.AgentChannelTest` and its split files.
  The setup (creating an agent, swapping the client to `MockClient`,
  and joining the channel) must be inlined in each test file because
  the `socket/1` macro requires `@endpoint` from the test module.
  """

  defmacro __using__(_opts) do
    quote do
      import NestWeb.AgentChannelTestHelpers

      alias Nest.Agents
      alias Nest.Agents.Agent
      alias Nest.Agents.Supervisor
      alias Nest.LLM.MockClient
      alias NestWeb.AgentChannel
      alias NestWeb.UserSocket

      setup do
        {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})
        {:ok, agent_pid} = Supervisor.get_agent(id)

        # Swap the agent's client_config.client to MockClient so the
        # chat task (in a separate process) calls MockClient.run/2
        # directly, without needing `set_mimic_global` (which Mimic
        # explicitly disallows in async tests).
        :sys.replace_state(agent_pid, fn state ->
          %{state | client_config: %{state.client_config | client: MockClient}}
        end)

        Process.put(:nest_test_agent_pid, agent_pid)
        MockClient.start_link(agent_pid)
        MockClient.clear()

        on_exit(fn ->
          # Stop the agent GenServer last so any chat task still
          # in flight when the test asserts gets torn down with
          # it instead of outliving the test as a stray process.
          # Without this, leftover chat tasks keep calling
          # MockClient.run/2 in the background; once their message
          # accumulation trips Preflight's alternation check the
          # llm_error path broadcasts a chat:error whose log
          # entry leaks into the next test's stderr.
          if Process.alive?(agent_pid), do: Agent.terminate(agent_pid)
          MockClient.stop(agent_pid)
          Process.delete(:nest_test_agent_pid)
        end)

        # Connect socket and join agent channel
        {:ok, _, socket} =
          subscribe_and_join(socket(UserSocket), AgentChannel, "agent:#{id}")

        {:ok, socket: socket, agent_id: id}
      end
    end
  end
end
