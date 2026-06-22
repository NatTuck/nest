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

      setup do
        {:ok, id} = Nest.Agents.create_agent(%{name: "qwen3.5-plus"})
        {:ok, agent_pid} = Nest.Agents.Supervisor.get_agent(id)

        # Swap the agent's client_config.client to MockClient so the
        # chat task (in a separate process) calls MockClient.run/2
        # directly, without needing `set_mimic_global` (which Mimic
        # explicitly disallows in async tests).
        :sys.replace_state(agent_pid, fn state ->
          %{state | client_config: %{state.client_config | client: Nest.LLM.MockClient}}
        end)

        Process.put(:nest_test_agent_pid, agent_pid)
        Nest.LLM.MockClient.start_link(agent_pid)
        Nest.LLM.MockClient.clear()

        on_exit(fn ->
          Nest.LLM.MockClient.stop(agent_pid)
          Process.delete(:nest_test_agent_pid)
        end)

        # Connect socket and join agent channel
        {:ok, _, socket} =
          subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

        on_exit(fn -> Nest.Test.TaskDrain.drain() end)

        {:ok, socket: socket, agent_id: id}
      end
    end
  end
end
