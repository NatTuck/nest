defmodule NestWeb.LobbyChannel.AgentSpawn do
  @moduledoc """
  The lobby's `spawn_agent` action (#209): one more agent at the top of a space,
  a peer of its root.

  Split out of `NestWeb.LobbyChannel` the way the other subjects are
  (`SpaceForms`, `Invites`, `SpaceFeed`): the channel keeps the `handle_in/3`
  head — a client's push has to match a head there — and this owns the decision.

  ## Who may spawn

  The space's owner, and only the owner (`Authz.fetch_owned_space/2`, the same
  rule `edit_space` and `archive_space` check with
  `Authz.authorize_space_owner/2`). A caller who is not the owner is answered
  `forbidden`.

  ## What the agent inherits

  The space's blueprint decides the vocation when the client names none
  (`Nest.Spaces.resolve_agent_vocation/2`), exactly as it does for a root agent;
  an explicit slug wins over the blueprint, and an unknown one is the
  `vocation_not_found` refusal the space-create path already answers with. The
  model is the client's, and it is **required**: an agent created without one
  starts blocked on `:model_missing` until somebody picks a model, which is a
  state to recover from, not a way to spawn. A payload that names none is
  refused `model_required`. The check is on *presence* — a name that resolves to
  nothing is the create path's behaviour too (`Agents.enrich_model/1` leaves an
  unknown name alone), and the client only offers names from the catalogue.

  The blueprint's `spawnable_vocations` whitelist is **not** consulted, on
  purpose: it constrains what an *agent* may spawn (`SpawnVocation.resolve/2`),
  and a manual spawn is the space's owner acting.

  The new agent is **top level**: no `parent_id`, `depth` 0. It is a peer of the
  space's root, which is what the issue asks for — the tree gains a second root,
  not a child of the first. It is also private to its creator (`shared` is
  `false`, the default), because the payload carries no sharing decision and the
  space has none to inherit: sharing is a per-agent property.

  ## The announcement

  On success the frame is the one the space-creation path emits
  (`Broadcasts.agent_created/2`), on the space topic: without it no other
  client's sidebar tree learns about the new agent. The reply carries the name
  the server settled on, which is generated when the client named none.
  """

  alias Nest.Agents
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Spaces
  alias NestWeb.ErrorPayload
  alias NestWeb.LobbyChannel
  alias NestWeb.LobbyChannel.AgentErrors
  alias NestWeb.LobbyChannel.Authz

  @doc """
  Create an agent in `payload["space_id"]` and announce it.

  `payload["name"]` is optional (the server generates one) and so is
  `payload["vocation"]` (a slug); `payload["model"]` is required and must name a
  model. A payload whose keys are present with the wrong type is
  `invalid_payload` — it is a client bug, not a refusal the user can act on.
  """
  def spawn_agent(%{"space_id" => space_id} = payload, socket) when is_integer(space_id) do
    with :ok <- validate_payload(payload),
         {:ok, model} <- model_map(payload["model"]) do
      authorized_spawn(space_id, payload, model, socket)
    else
      :invalid_payload -> invalid(socket)
      :model_required -> {:reply, {:error, %{"reason" => "model_required"}}, socket}
    end
  end

  def spawn_agent(_payload, socket), do: invalid(socket)

  # Owner only, like every other space-level action (`edit_space`,
  # `archive_space`): the agents in a space are its owner's to grow. A caller
  # who is not the owner is `forbidden`, and a space that does not exist is
  # `not_found` — both the codes the neighbouring actions answer with. The check
  # returns the row, which the vocation resolution needs.
  defp authorized_spawn(space_id, payload, model, socket) do
    case Authz.fetch_owned_space(space_id, socket.assigns.current_user) do
      {:ok, space} -> spawn_in_space(space, payload, model, socket)
      {:error, reason} -> {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  # An archived space is out of service: `archive_space` stopped its agents and
  # released its sandbox. The UI cannot reach this (an archived slug renders the
  # restore notice, not the feed), but the channel is the boundary — and the real
  # case is a dialog left open while the space is archived from another tab.
  defp spawn_in_space(%{archived: true}, _payload, _model, socket) do
    {:reply, {:error, ErrorPayload.from_reason(:space_archived)}, socket}
  end

  defp spawn_in_space(space, payload, model, socket) do
    case Spaces.resolve_agent_vocation(space, payload["vocation"]) do
      {:ok, vocation} -> create(space.id, payload, model, vocation, socket)
      {:error, reason} -> {:reply, create_payload(reason, space.id), socket}
    end
  end

  defp create(space_id, payload, model, vocation, socket) do
    case Agents.create_agent(space_id, model,
           name: payload["name"],
           vocation_id: vocation.id,
           created_by_user_id: socket.assigns.user_id
         ) do
      {:ok, name} ->
        # The same frame the space-creation path emits, on the space topic: the
        # sidebar trees of every session watching this space are built from it.
        Broadcasts.agent_created(space_id, name: name, model: model, vocation: vocation.slug)
        {:reply, {:ok, %{"name" => name}}, socket}

      # The create path's own arm for this is the generic `failed_to_create`,
      # whose message is about a space. A spawn knows the name it asked for, so
      # it says which one is taken.
      {:error, :duplicate_name} ->
        {:reply, duplicate_reply(payload["name"]), socket}

      {:error, reason} ->
        {:reply, create_payload(reason, space_id), socket}
    end
  end

  # A create failure in a space is not a failed *space* creation, and
  # `AgentErrors` logs the context it is given.
  defp create_payload(reason, space_id) do
    AgentErrors.create_payload(
      reason,
      {"Failed to spawn an agent in space #{space_id}", "failed_to_create"}
    )
  end

  defp duplicate_reply(name) when is_binary(name) and name != "" do
    {:error,
     %{
       "reason" => "duplicate_name",
       "message" => "An agent named #{inspect(name)} already exists in this space."
     }}
  end

  # Defensive: a generated name is free by construction, so this arm is only
  # reachable if a generator ever hands back a taken one.
  defp duplicate_reply(_name) do
    {:error,
     %{
       "reason" => "duplicate_name",
       "message" => "Could not find a free name for the new agent; try again."
     }}
  end

  # The model the agent is created with: the client's map, which must name a
  # model. A map without a name is the same as no map — `build_model_map/1`
  # turns it into `name: nil`, and the agent would start blocked.
  defp model_map(%{"name" => name} = model) when is_binary(name) and name != "",
    do: {:ok, LobbyChannel.build_model_map(model)}

  defp model_map(_model), do: :model_required

  # A payload key that is absent or nil says nothing; one that is present must
  # have the type the create path will hand it on as. `nil` is spelled out
  # because JSON clients send it for "unset" as readily as they omit the key.
  defp validate_payload(payload) do
    valid =
      optional?(payload, "name", &is_binary/1) and
        optional?(payload, "vocation", &is_binary/1) and
        optional?(payload, "model", &is_map/1)

    if valid, do: :ok, else: :invalid_payload
  end

  defp optional?(payload, key, type) do
    case Map.fetch(payload, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} -> type.(value)
    end
  end

  defp invalid(socket), do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
end
