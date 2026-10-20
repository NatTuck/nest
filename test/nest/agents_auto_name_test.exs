defmodule Nest.AgentsAutoNameTest do
  @moduledoc """
  Tests the no-name path of `Agents.create_agent/3` — when the caller
  doesn't pass a name, the function delegates to
  `Supervisor.generate_unique_name_for_space/1`, which produces an
  adjective-animal pair (e.g. "clever-raven") that doesn't collide
  with any agent in the supervisor's `Registry` or the DB.

  Concurrent-safe because the uniqueness check is scoped to the *space*, not
  the BEAM: `generate_unique_name_for_space/1` builds its taken-name set from
  `Registry.list_for_space/1` (the Registry is keyed `{space_id, name}`) plus
  `Persistence.list_agent_names_for_space/1` (`where: space_id == ^space_id`),
  and `create_test_space/0` gives each test its own space. That space's row is
  uncommitted, so a concurrent test's agents are both a different registry key
  and invisible to this test's sandbox transaction. The supervisor-spawned
  agent pid performs no DB work by hard rule (`Agent.init/1`), and the DB calls
  in this body run in the test pid, which owns the connection.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor

  test "auto-generates a unique adjective-animal name" do
    {:ok, space_id} = AgentTestHelpers.create_test_space()

    # The model's `:name` is the LLM identifier, not the agent's registry key;
    # omitting the `:name` opt is what makes `create_agent/3` fall back to
    # `Supervisor.generate_unique_name_for_space/1`.
    {:ok, name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    # `start_agent/1` always passes `name:` and would never exercise the
    # fallback, so this test calls `Agents.create_agent/3` directly. Register
    # cleanup so the BEAM pid doesn't outlive the test.
    AgentTestHelpers.ensure_cleanup(name)

    assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)

    # The generated name is the live registry key, not merely a returned string.
    assert {:ok, _pid} = Supervisor.get_agent(space_id, name)
  end
end
