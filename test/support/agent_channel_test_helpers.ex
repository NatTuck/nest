defmodule NestWeb.AgentChannelTestHelpers do
  @moduledoc """
  Shared setup for `NestWeb.AgentChannelTest` and its split files.
  `__using__/1` injects:

    * `import NestWeb.AgentChannelTestHelpers` — for any helpers
      defined here that callers want to call directly (e.g.
      `connect_test_socket/0` for multi-subscriber tests).
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

  # `connect/3` is a macro from `Phoenix.ChannelTest` that needs
  # `@endpoint` from the caller. Tests that need a fresh socket
  # connection just inline `connect(UserSocket, %{"token" =>
  # Process.get(:agent_test_token)})` from their own body — the
  # macro expansion happens at the call site where `@endpoint`
  # is set by `NestWeb.ChannelCase`.

  defmacro __using__(_opts) do
    quote do
      import NestWeb.AgentChannelTestHelpers

      alias Nest.Accounts
      alias Nest.Accounts.AuthToken
      alias Nest.Agents.AgentTestHelpers
      alias Nest.LLM.MockClient
      alias Nest.Repo
      alias NestWeb.AgentChannel
      alias NestWeb.UserSocket

      setup do
        # The UserSocket now requires a valid token on connect.
        # Tests that exercise channel joins need a real user.
        Repo.delete_all(Accounts.Invite)
        Repo.delete_all(Accounts.User)

        {:ok, user, _role} =
          Accounts.create_user(
            %{username: "agent-channel-tester", password: "password123"},
            "first-user"
          )

        token = AuthToken.sign(user.id)

        # Create the agent AS the test user so the agent's
        # `created_by_user_id` matches the connected socket.
        {_agent_pid, agent_id} =
          AgentTestHelpers.start_agent(%{
            model: %{name: "qwen3.5-plus", provider: "model-studio"},
            vocation_id: AgentTestHelpers.programmer_vocation_id_for_test(),
            created_by_user_id: user.id
          })

        space_id = AgentTestHelpers.current_space_id()
        MockClient.clear()

        # Make the token reachable for tests that need to
        # open additional channels (e.g. ones that start a
        # second agent in the middle of a test).
        Process.put(:agent_test_token, token)

        {:ok, connected} = connect(UserSocket, %{"token" => token})

        {:ok, _, socket} =
          subscribe_and_join(connected, AgentChannel, "agent:#{space_id}:#{agent_id}")

        {:ok, socket: socket, agent_id: agent_id, user: user, space_id: space_id}
      end
    end
  end
end
