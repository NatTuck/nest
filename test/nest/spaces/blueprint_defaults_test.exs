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

  A space created with **no blueprint at all** falls back to the column's `true`
  through this same code path, and `Nest.Spaces.NetworkAccessTest`'s "defaults
  to true for a new space, and for a missing row" already asserts it against the
  persisted row, so it is not repeated here.
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

    # `false` is the direction that can only pass if the default is applied at
    # all — an untouched column is already `true`. The `true` blueprint then pins
    # that what gets applied is the blueprint's own value rather than a
    # hardcoded `false`.
    assert {:ok, space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: offline.id}))
    assert space.network_access == false

    assert {:ok, space} = Spaces.create_space(nil, space_attrs(%{blueprint_id: online.id}))
    assert space.network_access == true
  end

  test "an explicit value wins over the blueprint's default" do
    online = BlueprintsFixtures.blueprint_fixture(%{default_net: true})

    # The interesting direction: an explicit `false` must not be read as
    # "unnamed" and replaced by the blueprint's `true`. The reverse pairing
    # (explicit `true` over an `offline` blueprint) leaves the attrs untouched
    # through the same clause of `named_network_access?/1`, so it cannot fail
    # independently of this one.
    assert {:ok, space} =
             Spaces.create_space(
               nil,
               space_attrs(%{blueprint_id: online.id, network_access: false})
             )

    assert space.network_access == false
  end

  test "an empty string counts as unnamed" do
    offline = BlueprintsFixtures.blueprint_fixture(%{default_net: false})

    # Not the same hazard as an absent key (covered by the first test): a blank
    # that reached the changeset would be read as "no choice" and become `true`,
    # so `""` is the value that tells a blank-aware check from a nil-aware one.
    assert {:ok, space} =
             Spaces.create_space(
               nil,
               space_attrs(%{blueprint_id: offline.id, network_access: ""})
             )

    assert space.network_access == false
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
