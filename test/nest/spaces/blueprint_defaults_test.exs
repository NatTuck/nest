defmodule Nest.Spaces.BlueprintDefaultsTest do
  @moduledoc """
  A space created from a blueprint takes the blueprint's `default_net` as its
  `network_access` — but only when the caller named none.

  The "only when the caller named none" half is the whole point, and `false` is
  the case that catches a careless implementation: it is falsy, so a fallback
  written with `||` would replace an explicit "off" with the blueprint's "on".
  `nil` and `""` mean unnamed, the same way `Space.create_changeset/2` reads a
  blank backend.

  `workspace_path` is set to a real, non-`/tmp` directory because every space
  needs one from stage 4 on; `create_space/2` only checks that it was *given*
  (the sandbox gate is what checks it exists).
  """
  use Nest.DataCase, async: true

  alias Nest.BlueprintsFixtures
  alias Nest.Spaces

  defp space_attrs(attrs) do
    Map.merge(
      %{
        name: "bp-net-#{System.unique_integer([:positive])}",
        workspace_path: File.cwd!()
      },
      attrs
    )
  end

  test "takes the blueprint's default when the caller names none" do
    offline = BlueprintsFixtures.blueprint_fixture(%{default_net: false})
    online = BlueprintsFixtures.blueprint_fixture(%{default_net: true})

    assert {:ok, space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: offline.id}))
    assert space.network_access == false

    assert {:ok, space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: online.id}))
    assert space.network_access == true
  end

  test "an explicit value wins over the blueprint's default, in both directions" do
    offline = BlueprintsFixtures.blueprint_fixture(%{default_net: false})
    online = BlueprintsFixtures.blueprint_fixture(%{default_net: true})

    # The interesting direction: an explicit `false` must not be read as
    # "unnamed" and replaced by the blueprint's `true`.
    assert {:ok, space} =
             Spaces.create_space(
               nil,
               space_attrs(%{blueprint_id: online.id, network_access: false})
             )

    assert space.network_access == false

    assert {:ok, space} =
             Spaces.create_space(
               nil,
               space_attrs(%{blueprint_id: offline.id, network_access: true})
             )

    assert space.network_access == true
  end

  test "a blank value counts as unnamed" do
    offline = BlueprintsFixtures.blueprint_fixture(%{default_net: false})

    for blank <- ["", nil] do
      assert {:ok, space} =
               Spaces.create_space(
                 nil,
                 space_attrs(%{blueprint_id: offline.id, network_access: blank})
               )

      assert space.network_access == false
    end
  end

  test "keeps today's default when the space has no blueprint" do
    assert {:ok, space} = Spaces.create_space(nil, space_attrs(%{}))
    assert space.network_access == true
  end

  test "coerces a string blueprint id, and refuses a string-keyed attrs map" do
    offline = BlueprintsFixtures.blueprint_fixture(%{default_net: false})

    # The form sends an integer, a raw client need not: the id is coerced the way
    # `cast/2` coerces it, so the blueprint's default still applies rather than
    # being silently skipped.
    assert {:ok, space} =
             Spaces.create_space(nil, space_attrs(%{blueprint_id: to_string(offline.id)}))

    assert space.network_access == false

    # A fully string-keyed attrs map is *not* a shape `create_space/2` accepts:
    # it adds `:created_by_user_id` itself, which would make the map mixed-keyed,
    # and `Ecto.Changeset.cast/3` refuses those outright. Loud, not silent — so
    # there is no string-key spelling of `network_access` or `blueprint_id` to
    # support here, and pretending otherwise would be untested code.
    assert_raise Ecto.CastError, fn ->
      Spaces.create_space(nil, %{
        "name" => "bp-net-string-#{System.unique_integer([:positive])}",
        "workspace_path" => File.cwd!(),
        "blueprint_id" => offline.id
      })
    end
  end
end
