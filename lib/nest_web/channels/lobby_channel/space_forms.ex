defmodule NestWeb.LobbyChannel.SpaceForms do
  @moduledoc """
  The lobby's two space-form actions: creating a space with its root agent, and
  editing a space's environment.

  Both are here because they are the channel's only payloads that describe a
  whole *space* rather than one agent — the validation, the attrs a context call
  is handed, and the frame announcing the result all belong to one of them — and
  because `NestWeb.LobbyChannel` is at its file-length cap.

  The channel keeps the `handle_in/3` heads (a client's push has to match a head
  there) and delegates the body here. It also owns the three helpers both actions
  need from a socket: `broadcast_to_user/3`, which announces on the user's
  space-set topic; `reconcile_space_subscriptions/1`, which the create path runs
  before announcing the root agent so this session is listening to the new
  space's topic first; and `build_model_map/1`, the model map a create and an
  agent edit both send.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Spaces
  alias Nest.Vocations
  alias NestWeb.ErrorPayload
  alias NestWeb.LobbyChannel
  alias NestWeb.LobbyChannel.AgentErrors
  alias NestWeb.LobbyChannel.Authz

  @doc false
  def create_space(payload, socket) do
    user_id = socket.assigns.user_id
    model = LobbyChannel.build_model_map(Map.get(payload, "model") || %{})
    opts = build_create_opts_from_payload(payload, user_id)
    vocation = Keyword.fetch!(opts, :vocation)

    attrs = build_create_space_attrs(payload, model, vocation, opts)

    case Spaces.create_space_with_root_agent(user_id, attrs) do
      {:ok, %Spaces.Space{} = space, agent_name} ->
        # Subscribe to the new space's topic BEFORE announcing the agent:
        # the announcement rides the space topic, and a channel does not
        # see its own broadcast, so this session must be listening first.
        socket = LobbyChannel.reconcile_space_subscriptions(socket)
        broadcast_space_created(socket, space, agent_name, model, vocation)

        {:reply, {:ok, %{"space_id" => space.id, "name" => agent_name, "slug" => space.slug}},
         socket}

      {:error, reason} ->
        {:reply, AgentErrors.create_payload(reason), socket}
    end
  end

  @doc false
  def edit_space(payload, socket) do
    if valid_environment_payload?(payload) do
      do_edit_space(payload, socket)
    else
      {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
    end
  end

  defp build_create_space_attrs(payload, model, vocation, opts) do
    %{
      name: payload["name"],
      slug: payload["slug"],
      blueprint_id: payload["blueprint_id"],
      model: model,
      # When the client picks a blueprint, the blueprint's
      # `root_vocation` should drive the root agent's
      # vocation, so we don't forward the lobby's default
      # `vocation` fallback. Without a blueprint we keep
      # the default-vocation behavior.
      vocation: maybe_vocation(payload, vocation),
      workspace_path: Keyword.get(opts, :workspace_path),
      # Chosen here at creation; editable afterwards through `edit_space`, which
      # is the same action as the workspace and the network. Absent or blank
      # means the default; an unknown value is refused by
      # `Space.create_changeset/2` rather than silently replaced.
      sandbox_backend: payload["sandbox_backend"],
      # A space property, editable later; absent means the column's default.
      network_access: payload["network_access"],
      agent_name: payload["agent_name"],
      shared: payload["shared"] == true
    }
  end

  defp maybe_vocation(%{"blueprint_id" => bid}, _vocation) when not is_nil(bid), do: nil
  defp maybe_vocation(_payload, vocation), do: vocation

  defp broadcast_space_created(socket, space, agent_name, model, vocation) do
    LobbyChannel.broadcast_to_user(socket, :space_created, %{
      "space" => space,
      "agentName" => agent_name
    })

    broadcast_agent_created(space.id, agent_name, model, vocation)
  end

  # The payload is `Broadcasts`'s to build (#72); this passes what the
  # space-creation path knows. The model goes in whole rather than as a
  # name/provider pair, because `Broadcasts.created_payload/2` runs it through
  # the same `model_payload/1` the status broadcast uses — so a root agent's
  # frame now carries the same model shape a subagent's does instead of a
  # narrower one.
  defp broadcast_agent_created(space_id, name, model, vocation) do
    Broadcasts.agent_created(space_id, name: name, model: model, vocation: vocation)
  end

  defp broadcast_space_updated(socket, space),
    do: LobbyChannel.broadcast_to_user(socket, :space_updated, %{"space" => space})

  # The *space* creation opts. `:workspace_path` belongs here — it is the
  # space's — and not in the root agent's, which inherits it from the row.
  defp build_create_opts_from_payload(payload, current_user_id) do
    base_opts =
      build_create_opts(
        payload,
        payload["vocation"] || default_vocation_slug(),
        payload["workspace_path"]
      )

    base_opts
    |> Keyword.put(:created_by_user_id, current_user_id)
    |> Keyword.put(:shared, payload["shared"] == true)
  end

  defp build_create_opts(payload, vocation, workspace_path) do
    []
    |> maybe_add_opt(:name, payload["name"])
    |> maybe_add_opt(:vocation, vocation)
    |> maybe_add_opt(:workspace_path, workspace_path)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_vocation_slug do
    case Vocations.list_vocations() do
      [] -> nil
      [first | _] -> first.slug
    end
  end

  # The three environment properties, from either key shape. Only these three are
  # taken: the edit is not a general space update, and `name`/`slug` have their
  # own action.
  @environment_keys ["workspace_path", "network_access", "sandbox_backend"]

  defp environment_params(payload) do
    payload
    |> Map.take(@environment_keys)
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  # A `network_access` that is not a boolean is a client bug rather than a
  # changeset refusal: the column is a boolean, and this is its only writer.
  # Answering `not_found` (the row is there) or `failed_to_edit` would both be
  # misleading about a payload the client got wrong.
  defp valid_environment_payload?(payload) do
    case Map.fetch(payload, "network_access") do
      :error -> Enum.any?(@environment_keys, &Map.has_key?(payload, &1))
      {:ok, value} -> is_boolean(value)
    end
  end

  defp do_edit_space(payload, socket) do
    space_id = payload["space_id"]

    case Authz.authorize_space_owner(space_id, socket.assigns.current_user) do
      {:ok, :owner} ->
        case Spaces.update_environment(space_id, environment_params(payload)) do
          {:ok, space} ->
            # Announced on the per-user topic like every other space-set change,
            # so the owner's other sessions show the same values — and so the
            # dialog is not the only place they exist.
            broadcast_space_updated(socket, space)
            # String keys: the reply is the wire, and the client reads
            # `network_access`/`workspace_path`/`sandbox_backend`.
            {:reply, {:ok, wire_values(Spaces.environment_values(space))}, socket}

          {:error, :not_found} ->
            {:reply, {:error, %{"reason" => "not_found"}}, socket}

          {:error, reason} ->
            {:reply, AgentErrors.edit_space_payload(reason), socket}
        end

      {:error, reason} ->
        {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}
    end
  end

  defp wire_values(values),
    do: Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end)
end
