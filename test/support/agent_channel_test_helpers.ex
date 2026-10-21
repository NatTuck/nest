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

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Persistence

  # `connect/3` is a macro from `Phoenix.ChannelTest` that needs
  # `@endpoint` from the caller. Tests that need a fresh socket
  # connection just inline `connect(UserSocket, %{"token" =>
  # Process.get(:agent_test_token)})` from their own body — the
  # macro expansion happens at the call site where `@endpoint`
  # is set by `NestWeb.ChannelCase`.

  @doc """
  Seed a small archive for the `chat:history` tests.

  System at 0, a human prompt at 1, a delivered peer message at 2 (user role,
  no `origin`), assistant at 3, then a compaction boundary (and marker row) at
  4. The agent owns the system row.

  The peer row is there so the `role: "user"` recall projection is pinned to
  exclude it: that projection filters on `origin: "human"`, and a delivered row
  is untagged.
  """
  def seed_archive(space_id, name) do
    for message <- [
          {:user,
           %User{
             index: 1,
             parts: [%Part.Text{text: "archived question"}],
             metadata: User.source_metadata(:composed)
           }},
          {:user,
           %User{
             index: 2,
             parts: [%Part.Text{text: "[Message from agent \"peer\"]\narchived delivery"}]
           }},
          {:assistant, %Assistant{index: 3, parts: [%Part.Text{text: "archived answer"}]}}
        ] do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end

    {:ok, _} = Persistence.record_compaction(space_id, name, 4, 4)
  end

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

        # A username unique to this test. `users.username` is a unique index, and
        # a fixed name makes every concurrent channel test wait on the previous
        # one's *uncommitted* index entry — released only when that test's
        # sandbox transaction rolls back, i.e. at the end of that test. Measured
        # across the suite: 368 user inserts costing 12.1 s of database time at
        # ~33 ms each (61% of all query time), against ~1.4 ms for every other
        # insert here. It is also what made the channel tests serialise: with a
        # per-test name there is no other transaction to wait for.
        username = "agent-channel-tester-#{System.unique_integer([:positive])}"

        {:ok, user, _role} =
          Accounts.create_user(
            %{username: username, password: "password123"},
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
