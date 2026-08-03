defmodule NestWeb.AgentChannelTestHelpers do
  @moduledoc """
  Shared setup for `NestWeb.AgentChannelTest` and its split files.
  `__using__/1` injects:

    * `import NestWeb.AgentChannelTestHelpers` — for any helpers
      defined here that callers want to call directly (none today).
    * Aliases for the modules tests need.
    * A per-test setup that creates an agent through the standard
      `Nest.Agents.AgentTestHelpers.start_agent/1` helper (link,
      `Sandbox.allow`, MockClient swap, on_exit cleanup) and joins
      the agent's `AgentChannel`.

  The join must be inlined (rather than factored into a callback
  in a shared helper module) because `socket/1` is a macro that
  requires `@endpoint` from the calling test module. Everything
  else delegates to the canonical `start_agent/1` so the setup
  and teardown match `agent_*.exs` tests.
  """

  defmacro __using__(_opts) do
    quote do
      import NestWeb.AgentChannelTestHelpers

      alias Nest.Agents.AgentTestHelpers
      alias Nest.LLM.MockClient
      alias NestWeb.AgentChannel
      alias NestWeb.UserSocket

      setup do
        {_agent_pid, agent_id} =
          AgentTestHelpers.start_agent(%{
            model: %{name: "qwen3.5-plus", provider: "model-studio"}
          })

        MockClient.clear()

        {:ok, _, socket} =
          subscribe_and_join(socket(UserSocket), AgentChannel, "agent:#{agent_id}")

        {:ok, socket: socket, agent_id: agent_id}
      end
    end
  end
end
