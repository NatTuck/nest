defmodule Nest.Agents.Agent.ModePersistenceTest do
  @moduledoc """
  The mode is a *persisted* per-agent property: the row is what a restart reads
  and what a spawn's inheritance reads, so a mode that only lives in memory is a
  mode that silently reverts.

  `Nest.Persistence.build_insert_base/2` builds the row field by field, and it did
  not carry `:mode` — so `PreSpawn.put_mode/1`'s derivation was discarded at the
  insert and the column's default `"act"` won. The consequences are all things the
  design requires: a blueprint's `default_mode` never reached the row, a spawn's
  inheritance read a stale one, and a restart widened a child that was spawned
  read-only.

  The test goes through the real start path rather than the builder, because the
  builder is the thing that looked right.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.BlueprintsFixtures
  alias Nest.Persistence
  alias Nest.Spaces
  alias Nest.VocationsFixtures

  setup do
    {:ok, user, _role} =
      Nest.Accounts.create_user(
        %{
          username: "mode-persist-#{System.unique_integer([:positive])}",
          password: "password123"
        },
        "first-user"
      )

    {:ok, user_id: user.id}
  end

  test "a blueprint's default_mode reaches the root agent's row", %{user_id: user_id} do
    blueprint = blueprint_with_default_mode("plan")

    assert {:ok, %Spaces.Space{} = space, name} = create_space(user_id, blueprint.id)
    on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)

    # The *row*, not the process: `live.mode` is initialised from the attrs, so a
    # `current_mode`-only assertion would pass while the column held `"act"` — which
    # is exactly the state the missing field produced.
    assert {:ok, %{mode: "plan"}} = Persistence.fetch_agent(space.id, name)

    assert {:ok, pid} = Supervisor.get_agent(space.id, name)
    assert Agent.get_public_info(pid, 1_000).current_mode == "plan"
  end

  defp blueprint_with_default_mode(mode) do
    vocation = VocationsFixtures.vocation_fixture()

    BlueprintsFixtures.blueprint_fixture(%{root_vocation: vocation.slug, default_mode: mode})
  end

  defp create_space(user_id, blueprint_id) do
    unique = System.unique_integer([:positive])

    Spaces.create_space_with_root_agent(user_id, %{
      name: "mode-#{unique}",
      slug: "mode-#{unique}",
      blueprint_id: blueprint_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      workspace_path: AgentTestHelpers.default_test_workspace()
    })
  end
end
