defmodule Nest.Blueprints.MaxAgentsTest do
  @moduledoc """
  `max_agents` — the blueprint property that caps a space's non-archived agents
  (#225). Three things are pinned here, none of which needs a running agent:

    * the changeset keeps the column a positive integer or `nil` ("no opinion");
    * the resolvers: `Spaces.max_agents_for_space/1` returns the space's own
      snapshot — seeded from the blueprint at creation (Grading 20, Coding Team
      10), default 5 when the blueprint names none, and independent of later
      blueprint changes — while `Blueprints.max_agents/1` returns the blueprint's
      value or `nil` ("no opinion");
    * the encoded blueprint carries the field, so a client can see the cap.

  Enforcement (the gate refusing a start over the cap) lives in
  `Nest.Agents.AgentLimitTest`, which drives the real create/spawn routes.
  """
  use Nest.DataCase, async: true

  alias Nest.Blueprints
  alias Nest.BlueprintsFixtures
  alias Nest.Spaces

  defp space_attrs(attrs) do
    Map.merge(
      %{
        name: "cap-#{System.unique_integer([:positive])}",
        workspace_path: File.cwd!()
      },
      attrs
    )
  end

  describe "changeset validation" do
    test "accepts a positive cap or none, and refuses zero, negative, and non-integer" do
      # The two seeded tiers are legal values, and `nil` is the "no opinion"
      # every other blueprint keeps.
      assert {:ok, grading} =
               Blueprints.create_blueprint(%{
                 name: "grading-#{System.unique_integer([:positive])}",
                 root_vocation: "grader",
                 max_agents: 20
               })

      assert grading.max_agents == 20

      assert {:ok, unset} =
               Blueprints.create_blueprint(%{
                 name: "unset-#{System.unique_integer([:positive])}",
                 root_vocation: "grader"
               })

      assert unset.max_agents == nil

      # Zero and negative are not team sizes; a non-integer is refused on type
      # by `cast/3` before the number validator runs.
      for bad <- [0, -3, "many"] do
        assert {:error, changeset} =
                 Blueprints.create_blueprint(%{
                   name: "bad-#{System.unique_integer([:positive])}",
                   root_vocation: "grader",
                   max_agents: bad
                 })

        assert [_message] = errors_on(changeset).max_agents
      end

      # An existing blueprint can be given a cap after the fact.
      assert {:ok, updated} = Blueprints.update_blueprint(unset, %{max_agents: 10})
      assert updated.max_agents == 10
    end
  end

  describe "the cap the gate reads" do
    test "resolves the space's snapshot, seeded from the blueprint at creation" do
      grading = BlueprintsFixtures.blueprint_fixture(%{max_agents: 20})
      coding_team = BlueprintsFixtures.blueprint_fixture(%{max_agents: 10})
      unset = BlueprintsFixtures.blueprint_fixture()

      {:ok, grading_space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: grading.id}))
      {:ok, team_space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: coding_team.id}))
      {:ok, unset_space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: unset.id}))
      {:ok, bare_space} = Spaces.create_space(nil, space_attrs(%{}))

      # The tiers the seed script sets, copied onto the space at creation and
      # read back through the space-level resolver the gate calls.
      assert Spaces.max_agents_for_space(grading_space.id) == 20
      assert Spaces.max_agents_for_space(team_space.id) == 10

      # No blueprint opinion (unset column, or no blueprint) seeds the default 5
      # onto the space — the space always owns a concrete cap.
      assert Spaces.max_agents_for_space(unset_space.id) == 5
      assert Spaces.max_agents_for_space(bare_space.id) == 5

      # Model B: the space owns its cap independently of the blueprint. Changing
      # the blueprint after creation does not move an existing space's limit.
      assert {:ok, _} = Blueprints.update_blueprint(grading, %{max_agents: 3})
      assert Spaces.max_agents_for_space(grading_space.id) == 20

      # The blueprint-level resolver is total: nil id, missing row, unset column.
      assert Blueprints.max_agents(grading.id) == 3
      assert Blueprints.max_agents(nil) == nil
      assert Blueprints.max_agents(-1) == nil
      assert Blueprints.max_agents(unset.id) == nil
    end
  end

  describe "the wire" do
    test "the encoded blueprint carries max_agents" do
      blueprint = BlueprintsFixtures.blueprint_fixture(%{max_agents: 20})
      encoded = blueprint |> Jason.encode!() |> Jason.decode!()
      assert encoded["max_agents"] == 20

      # An unset cap encodes as null, not a missing key — a client can tell
      # "no opinion" from a field the server forgot to ship.
      unset = BlueprintsFixtures.blueprint_fixture()
      assert (unset |> Jason.encode!() |> Jason.decode!())["max_agents"] == nil
    end
  end
end
