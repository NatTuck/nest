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
  model is the client's map, or the same empty map a space created without one
  gets — so an absent model resolves the way a root agent's does, because it is
  the same map through the same `Agents.create_agent/3`.

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

  `payload["name"]` is optional (the server generates one), and so are
  `payload["vocation"]` (a slug) and `payload["model"]` (a map). A payload whose
  optional keys are present with the wrong type is `invalid_payload` — it is a
  client bug, not a refusal the user can act on.
  """
  def spawn_agent(%{"space_id" => space_id} = payload, socket) when is_integer(space_id) do
    if valid_payload?(payload),
      do: authorized_spawn(space_id, payload, socket),
      else: invalid(socket)
  end

  def spawn_agent(_payload, socket), do: invalid(socket)

  # Owner only, like every other space-level action (`edit_space`,
  # `archive_space`): the agents in a space are its owner's to grow. A caller
  # who is not the owner is `forbidden`, and a space that does not exist is
  # `not_found` — both the codes the neighbouring actions answer with. The check
  # returns the row, which the vocation resolution needs.
  defp authorized_spawn(space_id, payload, socket) do
    case Authz.fetch_owned_space(space_id, socket.assigns.current_user) do
      {:ok, space} -> spawn_in_space(space, payload, socket)
      {:error, reason} -> {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  defp spawn_in_space(space, payload, socket) do
    case Spaces.resolve_agent_vocation(space, payload["vocation"]) do
      {:ok, vocation} -> create(space.id, payload, vocation, socket)
      {:error, reason} -> {:reply, AgentErrors.create_payload(reason), socket}
    end
  end

  defp create(space_id, payload, vocation, socket) do
    model = LobbyChannel.build_model_map(payload["model"] || %{})

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

      {:error, reason} ->
        {:reply, AgentErrors.create_payload(reason), socket}
    end
  end

  # A payload key that is absent or nil says nothing; one that is present must
  # have the type the create path will hand it on as. `nil` is spelled out
  # because JSON clients send it for "unset" as readily as they omit the key.
  defp valid_payload?(payload) do
    optional?(payload, "name", &is_binary/1) and
      optional?(payload, "vocation", &is_binary/1) and
      optional?(payload, "model", &is_map/1)
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
