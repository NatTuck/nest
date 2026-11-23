defmodule Nest.Spaces.CreationParams do
  @moduledoc """
  The params a space row is created from: the caller's, plus the values that
  fall back to the space's blueprint.

  Its own module because it is the one place that has to know both the shape a
  caller may use and the defaults a space inherits, and because `Nest.Spaces` is
  at its file-length cap.

  The blueprint lookups live *here* rather than in `Nest.Spaces.Space`'s
  changeset, even though that is where the column's own default is resolved:
  `Space` is a schema, and every other module it names is a schema or a
  pure helper. Making it read `Nest.Blueprints` would invert the layering for a
  value that is only needed at the one call site that knows a `blueprint_id`.
  """

  alias Nest.Agents.StartGuard
  alias Nest.Blueprints

  @doc """
  `attrs` with `:created_by_user_id` set and the blueprint-derived defaults
  filled in, ready for `Nest.Spaces.Space.create_changeset/2`.

  `user_id` may be `nil` (a space created outside a user's session, which is
  what the test fixtures do).
  """
  @spec for_create(map(), integer() | nil) :: map()
  def for_create(attrs, user_id) do
    attrs
    |> Map.put(:created_by_user_id, user_id)
    |> put_network_access_default()
    |> put_max_agents_snapshot()
  end

  # A space created from a blueprint starts with the blueprint's `default_net`,
  # but only when the caller named none: an explicit `false` is the caller's
  # decision (the New Space form sends one when the user clears the toggle) and
  # must survive, which is why this asks "was a value named" rather than "is the
  # value truthy". A blank counts as unnamed, the same way
  # `Space.create_changeset/2` treats it for the backend.
  #
  # No blueprint, a blueprint row that is gone, or a column holding `nil` all mean
  # the same thing here — `true`, which is what a space got before a blueprint had
  # a default at all.
  defp put_network_access_default(attrs) do
    if named_network_access?(attrs) do
      attrs
    else
      Map.put(attrs, :network_access, blueprint_default_net(Map.get(attrs, :blueprint_id)))
    end
  end

  # Atom keys only, because that is the only shape `Nest.Spaces.create_space/2`
  # accepts: `for_create/2` adds `:created_by_user_id` unconditionally, so a
  # string-keyed attrs map is already mixed-keyed by the time `cast/3` sees it and
  # is refused outright — loudly, not silently.
  defp named_network_access?(attrs) do
    case Map.get(attrs, :network_access) do
      blank when blank in [nil, ""] -> false
      _value -> true
    end
  end

  # The id is still coerced the way the changeset will coerce it, rather than
  # trusted to already be an integer: a raw client may send `"42"`, which
  # `cast/2` would accept, and without this the blueprint's default would be
  # silently skipped for it.
  defp blueprint_default_net(blueprint_id) do
    with {:ok, id} <- Ecto.Type.cast(:id, blueprint_id),
         value when is_boolean(value) <- Blueprints.default_net(id) do
      value
    else
      _no_default -> true
    end
  end

  # Model B (#225): the space **copies** its blueprint's `max_agents` at creation
  # and owns the value independently thereafter — a later blueprint change does
  # not move an existing space's cap, and the edit-space screen edits the space's
  # column. An explicit caller value wins (as for the network); absent, the
  # blueprint's cap is the seed, and a blueprint that names none (or is gone, or
  # there is no blueprint) falls back to the gate's default.
  defp put_max_agents_snapshot(attrs) do
    if named_max_agents?(attrs) do
      attrs
    else
      Map.put(attrs, :max_agents, blueprint_max_agents(Map.get(attrs, :blueprint_id)))
    end
  end

  defp named_max_agents?(attrs) do
    case Map.get(attrs, :max_agents) do
      blank when blank in [nil, ""] -> false
      _value -> true
    end
  end

  defp blueprint_max_agents(blueprint_id) do
    with {:ok, id} <- Ecto.Type.cast(:id, blueprint_id),
         value when is_integer(value) <- Blueprints.max_agents(id) do
      value
    else
      _no_cap -> StartGuard.default_max_agents()
    end
  end
end
