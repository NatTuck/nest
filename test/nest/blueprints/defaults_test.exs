defmodule Nest.Blueprints.DefaultsTest do
  @moduledoc """
  The two defaults a blueprint offers a space: `default_net`, which a new space
  takes as its `network_access` when the caller names none, and
  `default_spawnable_vocation`, which an `agents-spawn`/`agents-batch` call gets
  when it names no `vocation`.

  Kept apart from `Nest.BlueprintsTest` (blueprint CRUD) because the subject is
  different and the file-length cap is real.

  `default_spawnable_vocation` is the interesting one, because `nil` is a *value*
  here rather than a missing one: it means "this blueprint does not say", and the
  spawn refuses rather than guessing. That makes the validator's job to keep a
  set default and the whitelist from contradicting each other — a blueprint whose
  default is a slug the space may not spawn would refuse the very spawn it tells
  the model to make.
  """
  use Nest.DataCase, async: true

  alias Nest.Blueprints
  alias Nest.BlueprintsFixtures

  describe "default_net/1" do
    test "reads the column, both ways round" do
      for value <- [true, false] do
        blueprint = BlueprintsFixtures.blueprint_fixture(%{default_net: value})

        assert Blueprints.default_net(blueprint.id) == value
      end
    end

    test "is true for a blueprint that never chose, and nil when there is no blueprint" do
      blueprint = BlueprintsFixtures.blueprint_fixture()

      assert Blueprints.default_net(blueprint.id) == true
      assert Blueprints.default_net(nil) == nil
      assert Blueprints.default_net(-1) == nil
    end
  end

  describe "default_spawnable_vocation/1" do
    test "reads the column" do
      blueprint =
        BlueprintsFixtures.blueprint_fixture(%{
          spawnable_vocations: ["grader"],
          default_spawnable_vocation: "grader"
        })

      assert Blueprints.default_spawnable_vocation(blueprint.id) == "grader"
    end

    test "is nil for a blueprint that names none, and for no blueprint at all" do
      blueprint = BlueprintsFixtures.blueprint_fixture()

      assert Blueprints.default_spawnable_vocation(blueprint.id) == nil
      assert Blueprints.default_spawnable_vocation(nil) == nil
      assert Blueprints.default_spawnable_vocation(-1) == nil
    end
  end

  describe "what a client sees" do
    test "the encoded blueprint carries both defaults" do
      # The lobby's `init` payload ships the blueprint structs whole, and the New
      # Space form reads `default_net` off them to pre-fill the toggle. A field
      # missing from `@derive {Jason.Encoder, only: [...]}` would simply not
      # arrive, and the form would fall back to `true` without anything failing —
      # so the encoder list is the thing under test here, not the column.
      blueprint =
        BlueprintsFixtures.blueprint_fixture(%{
          spawnable_vocations: ["grader"],
          default_net: false,
          default_spawnable_vocation: "grader"
        })

      encoded = blueprint |> Jason.encode!() |> Jason.decode!()

      assert encoded["default_net"] == false
      assert encoded["default_spawnable_vocation"] == "grader"
      assert encoded["default_mode"] == "act"
    end
  end

  describe "default_spawnable_vocation validation" do
    test "refuses a slug outside a non-empty whitelist, naming the allowed set" do
      assert {:error, changeset} =
               Blueprints.create_blueprint(%{
                 name: "bad-default-#{System.unique_integer([:positive])}",
                 root_vocation: "grader",
                 spawnable_vocations: ["grader", "reviewer"],
                 default_spawnable_vocation: "programmer"
               })

      assert [message] = errors_on(changeset).default_spawnable_vocation
      # The message has to name what *would* work, or the fix is a guessing game.
      assert message =~ "grader"
      assert message =~ "reviewer"
      refute message =~ "programmer"
    end

    test "accepts a slug in the whitelist, and any slug when the whitelist is empty" do
      in_list =
        BlueprintsFixtures.blueprint_fixture(%{
          spawnable_vocations: ["grader"],
          default_spawnable_vocation: "grader"
        })

      assert in_list.default_spawnable_vocation == "grader"

      # `[]` is *unrestricted*, not "nothing allowed" — the same reading
      # `agents-spawn` takes — so any slug is a legal default against it.
      unrestricted =
        BlueprintsFixtures.blueprint_fixture(%{
          spawnable_vocations: [],
          default_spawnable_vocation: "anything-at-all"
        })

      assert unrestricted.default_spawnable_vocation == "anything-at-all"
    end

    test "validates against the whitelist the same changeset is setting" do
      # The stored whitelist is `[]` and the stored default is unset. Setting both
      # at once is self-consistent, so it has to be accepted: validating against
      # the *stored* whitelist would refuse it.
      blueprint = BlueprintsFixtures.blueprint_fixture(%{spawnable_vocations: []})

      assert {:ok, updated} =
               Blueprints.update_blueprint(blueprint, %{
                 spawnable_vocations: ["grader"],
                 default_spawnable_vocation: "grader"
               })

      assert updated.default_spawnable_vocation == "grader"

      # ...and the same pair in the other order of intent is still refused when
      # the two contradict.
      assert {:error, changeset} =
               Blueprints.update_blueprint(updated, %{
                 spawnable_vocations: ["reviewer"],
                 default_spawnable_vocation: "grader"
               })

      assert [_message] = errors_on(changeset).default_spawnable_vocation
    end

    test "a blank default is no default, and a non-string is refused on type" do
      # `cast/3` normalizes a blank string to `nil`, and `nil` is exactly "this
      # blueprint names no default" — a real answer, not a missing one. So a blank
      # needs no clause of its own, and this pins that it does not become an
      # empty-string slug the spawn could never resolve.
      assert {:ok, blank} =
               Blueprints.create_blueprint(%{
                 name: "blank-default-#{System.unique_integer([:positive])}",
                 root_vocation: "grader",
                 spawnable_vocations: ["grader"],
                 default_spawnable_vocation: ""
               })

      assert blank.default_spawnable_vocation == nil

      # A non-string is refused by `cast/3`'s type check before any validator of
      # ours runs, so it carries Ecto's own message rather than ours.
      assert {:error, wrong_type} =
               Blueprints.create_blueprint(%{
                 name: "wrong-type-#{System.unique_integer([:positive])}",
                 root_vocation: "grader",
                 spawnable_vocations: ["grader"],
                 default_spawnable_vocation: 7
               })

      assert [_message] = errors_on(wrong_type).default_spawnable_vocation
    end
  end
end
