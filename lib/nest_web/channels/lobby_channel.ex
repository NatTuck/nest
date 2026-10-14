defmodule NestWeb.LobbyChannel do
  @moduledoc """
  Channel for space and agent management operations.

  Handles:
  - Listing the user's spaces and the agents in each
  - Creating a new space (with its root agent)
  - Deleting agents
  - Changing an agent's model

  The `:after_join` loads the user's spaces and the agents
  across all of them (so the sidebar can render every space's
  agent tree). Every operation that touches an agent carries
  its `space_id` explicitly in the payload.

  Topic format: `"lobby"`. The wire payload of the `init`
  event includes the user's full spaces list and the agents
  across all spaces, so the sidebar can render the selection
  without an extra round-trip.
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Accounts
  alias Nest.Agents
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Blueprints
  alias Nest.Models
  alias Nest.Spaces
  alias Nest.Vocations
  alias NestWeb.InviteJSON
  alias NestWeb.LobbyChannel.AgentErrors
  alias NestWeb.LobbyChannel.Authz
  alias NestWeb.LobbyChannel.Invites
  alias NestWeb.LobbyChannel.ProbeCache
  alias NestWeb.LobbyChannel.Providers

  @impl true
  def join("lobby", _payload, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  # `Models.list/0` is a `GenServer.call/2` to the `Nest.Models`
  # GenServer with the default 5000ms timeout. Auto-discovery probes
  # for slow providers can stack up and surface as `:exit` from the
  # call. The lobby's `:after_join` is the user's first WS frame —
  # a hung frame makes the lobby look broken even when the rest of
  # the system is fine. Catch the exit and surface an empty catalog
  # so the JS side can render whatever it has.
  defp safe_models_list do
    Models.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @impl true
  def handle_info(:after_join, socket) do
    user = socket.assigns.current_user

    # Assign `user_id` before subscribing to anything. Every frame handler
    # below keys off `socket.assigns.user_id` — notably the
    # `{:spaces_changed, _}` guard, which would otherwise fall through to the
    # drop clause — so the assign must not be something a later reader can
    # outrun. Today nothing can be handled between here and the end of this
    # function (`:after_join` is a single `handle_info/2`, and `join/3`
    # self-sends it before any client push can arrive), but doing it first
    # keeps that true by construction rather than by the accident that this
    # body has not been split up yet.
    socket = assign(socket, :user_id, user.id)

    # Subscribe BEFORE the reads below. A frame that lands while we are
    # reading is queued in this process's mailbox and handled after the
    # `init` push, so the client always applies the newer state last.
    Phoenix.PubSub.subscribe(Nest.PubSub, Spaces.user_topic(user.id))
    space_subs = subscribe_space_topics(user.id)

    spaces = Spaces.list_for_user(user.id)
    archived_spaces = Spaces.list_archived_for_user(user.id)
    agents = visible_agents_across_spaces(spaces, user.id)
    archived_agents = archived_agents_across_spaces(spaces, user.id)
    vocations = Vocations.list_vocations()
    blueprints = Blueprints.list_blueprints()
    models = safe_models_list()

    push(socket, "init", %{
      spaces: spaces,
      archived_spaces: archived_spaces,
      agents: agents,
      archived_agents: archived_agents,
      broken_agents: [],
      blueprints: blueprints,
      models: models,
      vocations: vocations,
      providers: Providers.providers(),
      suggested_name: Spaces.suggest_name(),
      current_user: public_current_user(user),
      invites:
        user.id
        |> Accounts.list_user_invites()
        |> Enum.map(&InviteJSON.public_invite/1)
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "models")

    socket = assign(socket, :space_subs, space_subs)

    fetch_broken_agents_async(socket, spaces, user.id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:lobby_broken_agents_loaded, broken}, socket)
      when is_list(broken) do
    push(socket, "broken_agents_updated", %{broken_agents: broken})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:models_updated, payload}, socket) when is_list(payload) do
    broadcast(socket, "models_updated", %{models: payload})
    {:noreply, socket}
  end

  # Terminal event for a scan. Answer every push waiting on that scan.
  # The catalog itself already went out via `models_updated`, so there
  # is no separate client push here.
  @impl true
  def handle_info({:models_scan_complete, %{scan_id: scan_id}}, socket) do
    pending = Map.get(socket.assigns, :pending_rescan, [])

    {matching, rest} = Enum.split_with(pending, fn {id, _ref} -> id == scan_id end)

    Enum.each(matching, fn {_id, ref} -> reply(ref, {:ok, %{"scan_id" => scan_id}}) end)

    {:noreply, assign(socket, :pending_rescan, rest)}
  end

  # A space's agent changed status. The frame arrives on the space topic, so
  # only clients whose user can see that space are reached (#53).
  @impl true
  def handle_info({:agent_status, payload}, socket) do
    push(socket, "agent:status", payload)
    {:noreply, socket}
  end

  # Agent lifecycle (#41). Same shape as `{:agent_status, _}`: the frame
  # arrives on the space topic the channel subscribed to, and `push/3`
  # delivers it to this client only. Every one of the user's sessions holds
  # its own subscription, so they all get it — and no other user does, which
  # is what the pre-#41 global `"lobby"` broadcast could not promise.
  @impl true
  def handle_info({:agent_created, payload}, socket) do
    push(socket, "agent:created", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_archived, payload}, socket) do
    push(socket, "agent:archived", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_updated, payload}, socket) do
    push(socket, "agent:updated", payload)
    {:noreply, socket}
  end

  # This user's space *set* changed — another session created/archived/
  # unarchived/deleted a space (or, once sharing lands, a membership
  # change). Re-read the visible set and make our subscriptions match.
  # Unlike a `broadcast/3` on this channel's own topic, a PubSub frame
  # arrives here as a plain message, so the session that made the change
  # sees it too.
  @impl true
  def handle_info({:spaces_changed, user_id}, socket) when user_id == socket.assigns.user_id do
    {:noreply, reconcile_space_subscriptions(socket)}
  end

  def handle_info({:spaces_changed, _user_id}, socket), do: {:noreply, socket}

  # Space lifecycle rides the per-user topic (#41) for the same reason the
  # agent frames ride the space topic: `space:archived` names a space, and
  # only its owner's sessions should hear about it.
  @impl true
  def handle_info({:space_created, payload}, socket) do
    push(socket, "space:created", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:space_archived, payload}, socket) do
    push(socket, "space:archived", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:space_unarchived, payload}, socket) do
    push(socket, "space:unarchived", payload)
    {:noreply, socket}
  end

  # Anything else on a topic we subscribed to is a frame we do not know.
  # Without this clause a single unrecognised PubSub message would raise a
  # `FunctionClauseError` in `handle_info/2` and take the whole channel
  # down, disconnecting the client's lobby. The channel subscribes to two
  # topic families now (per-space and per-user), so an unknown tag is a
  # live possibility rather than a theoretical one: log it and carry on.
  @impl true
  def handle_info(message, socket) do
    Logger.warning("LobbyChannel ignoring unknown PubSub frame: #{inspect(message)}")
    {:noreply, socket}
  end

  # All `handle_in` clauses grouped together so the compiler
  # is happy with the multi-head pattern matching.
  @impl true
  def handle_in("create_space", payload, socket) when is_map(payload) do
    user_id = socket.assigns.user_id
    model = extract_model(Map.get(payload, "model") || %{})
    opts = build_create_opts_from_payload(payload, user_id)
    vocation = Keyword.fetch!(opts, :vocation)

    attrs = build_create_space_attrs(payload, model, vocation, opts)

    case Spaces.create_space_with_root_agent(user_id, attrs) do
      {:ok, %Spaces.Space{} = space, agent_name} ->
        # Subscribe to the new space's topic BEFORE announcing the agent:
        # the announcement rides the space topic, and a channel does not
        # see its own broadcast, so this session must be listening first.
        socket = reconcile_space_subscriptions(socket)
        broadcast_space_created(socket, space, agent_name, model, vocation, attrs)

        {:reply, {:ok, %{"space_id" => space.id, "name" => agent_name, "slug" => space.slug}},
         socket}

      {:error, reason} ->
        {:reply, AgentErrors.create_payload(reason), socket}
    end
  end

  @impl true
  def handle_in(
        "change_model",
        %{"model" => model_params, "name" => name, "space_id" => space_id},
        socket
      )
      when is_map(model_params) do
    case Authz.authorize_owner_or_shared(space_id, name, socket.assigns.current_user) do
      {:ok, :owner} -> do_change_model(space_id, name, model_params, socket)
      {:ok, :shared} -> {:reply, {:error, %{"reason" => "shared_read_only"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("change_model", _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @impl true
  def handle_in(
        "edit_agent",
        %{"model" => mp, "name" => name, "space_id" => sid} = payload,
        s
      )
      when is_map(mp) do
    case Authz.authorize_owner_or_shared(sid, name, s.assigns.current_user) do
      {:ok, :owner} -> do_edit_agent(sid, s, name, mp, Map.get(payload, "workspace_path"))
      {:ok, :shared} -> {:reply, {:error, %{"reason" => "shared_read_only"}}, s}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, s}
    end
  end

  def handle_in("edit_agent", _payload, s),
    do: {:reply, {:error, %{"reason" => "invalid_payload"}}, s}

  @impl true
  def handle_in("rescan_models", _payload, socket) do
    # `Nest.Models` broadcasts one `models_updated` per provider as it
    # answers, then a single `models_scan_complete` when the scan is
    # genuinely done (all providers answered, or the deadline fired).
    # We hold each push open and reply only on that terminal event so
    # the client's "rescanning" state tracks the whole scan rather
    # than the first partial. The channel process is never blocked:
    # `socket_ref/1` + `reply/2` answer later from `handle_info/2`.
    scan_id = Models.rescan()
    pending = Map.get(socket.assigns, :pending_rescan, [])

    {:noreply, assign(socket, :pending_rescan, [{scan_id, socket_ref(socket)} | pending])}
  end

  @impl true
  def handle_in("suggest_space_name", _payload, socket),
    do: {:reply, {:ok, %{"name" => Spaces.suggest_name()}}, socket}

  @impl true
  def handle_in("archive_space", %{"space_id" => space_id}, socket)
      when is_integer(space_id) do
    user = socket.assigns.current_user

    case Authz.authorize_space_owner(space_id, user) do
      {:ok, :owner} ->
        # The owner check already resolved the space, so archiving
        # can only succeed here (no `:not_found` possible).
        _ = Spaces.archive_space(space_id)
        broadcast_space_archived(socket, space_id)
        {:reply, {:ok, %{}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("archive_space", _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @impl true
  def handle_in("unarchive_space", %{"space_id" => space_id}, socket)
      when is_integer(space_id) do
    user = socket.assigns.current_user

    case Authz.authorize_space_owner(space_id, user) do
      {:ok, :owner} ->
        # The owner check already resolved the space, so restoring
        # can only succeed here (no `:not_found` possible).
        _ = Spaces.unarchive_space(space_id)
        broadcast_space_unarchived(socket, space_id)
        {:reply, {:ok, %{}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("unarchive_space", _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @impl true
  def handle_in(
        "unarchive_agent",
        %{"name" => name, "space_id" => space_id},
        socket
      )
      when is_binary(name) and is_integer(space_id) do
    case Authz.authorize_owner_or_shared(space_id, name, socket.assigns.current_user) do
      {:ok, :owner} ->
        case Agents.unarchive_agent(space_id, name) do
          :ok ->
            {:reply, {:ok, %{}}, socket}

          {:error, {:parent_archived, parent}} ->
            {:reply, {:error, %{"reason" => "parent_archived", "parent" => parent}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
        end

      {:ok, :shared} ->
        {:reply, {:error, %{"reason" => "shared_read_only"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("unarchive_agent", _payload, socket),
    do: {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}

  @impl true
  def handle_in("create_invite", payload, socket), do: Invites.create_invite(payload, socket)

  @impl true
  def handle_in("revoke_invite", payload, socket), do: Invites.revoke_invite(payload, socket)

  @impl true
  def handle_in("probe_cache_stats", payload, socket), do: ProbeCache.stats(payload, socket)

  @impl true
  def handle_in("clear_probe_cache", payload, socket), do: ProbeCache.clear(payload, socket)

  @impl true
  def handle_in("save_providers", payload, socket) do
    case Authz.authorize_admin(socket.assigns.current_user) do
      {:ok, :admin} -> Providers.save(payload, socket)
      {:error, _reason} -> {:reply, {:error, %{"reason" => "forbidden"}}, socket}
    end
  end

  # -- Private helpers --

  # Subscribe this channel process to every space the user can see, and
  # return the subscribed id set. The visible set is the authority (never
  # client input); a future membership table slots in right here.
  defp subscribe_space_topics(user_id) do
    user_id |> visible_space_ids() |> subscribe_space_ids()
  end

  defp visible_space_ids(user_id) do
    (Spaces.list_for_user(user_id) ++ Spaces.list_archived_for_user(user_id))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp subscribe_space_ids(ids) do
    Enum.each(ids, &Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(&1)))
    ids
  end

  # Bring the space subscriptions in line with the user's current visible
  # set. Idempotent, so it is safe to call from several paths.
  defp reconcile_space_subscriptions(socket) do
    have = Map.get(socket.assigns, :space_subs, MapSet.new())
    wanted = visible_space_ids(socket.assigns.user_id)

    wanted
    |> MapSet.difference(have)
    |> subscribe_space_ids()

    have
    |> MapSet.difference(wanted)
    |> Enum.each(&Phoenix.PubSub.unsubscribe(Nest.PubSub, Broadcasts.space_topic(&1)))

    assign(socket, :space_subs, wanted)
  end

  # Agents visible to `user_id` across every space in `spaces`,
  # flattened into one list. The sidebar renders a per-space agent
  # tree, so the init payload carries every space's agents rather
  # than a single "primary" space's.
  defp visible_agents_across_spaces(spaces, user_id) do
    Enum.flat_map(spaces, fn %Spaces.Space{id: space_id} ->
      Agents.list_visible_agents_for(space_id, user_id)
    end)
  end

  defp archived_agents_across_spaces(spaces, user_id) do
    Enum.flat_map(spaces, fn %Spaces.Space{id: space_id} ->
      Agents.list_archived_agents_for(space_id, user_id)
    end)
  end

  defp fetch_broken_agents_async(_socket, spaces, user_id) do
    parent = self()

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      result =
        try do
          Enum.flat_map(spaces, fn %Spaces.Space{id: space_id} ->
            fetch_broken_agents(space_id, user_id)
          end)
        catch
          _, _ -> []
        end

      send(parent, {:lobby_broken_agents_loaded, result})
    end)

    :ok
  end

  @doc false
  defp fetch_broken_agents(space_id, user_id) do
    Agents.list_broken_agents(space_id)
    |> Enum.filter(fn broken ->
      row_owner = broken_agent_owner(broken)
      row_shared = broken_agent_shared?(broken)

      row_owner == user_id or row_shared
    end)
  rescue
    e ->
      Logger.debug("fetch_broken_agents rescued: #{Exception.message(e)}")
      []
  catch
    kind, reason ->
      Logger.debug("fetch_broken_agents caught #{kind}: #{inspect(reason)}")
      []
  end

  defp broken_agent_owner(%{created_by_user_id: id}), do: id
  defp broken_agent_owner(_), do: nil

  defp broken_agent_shared?(%{shared: shared}), do: shared == true
  defp broken_agent_shared?(_), do: false

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
      agent_name: payload["agent_name"],
      shared: payload["shared"] == true
    }
  end

  defp maybe_vocation(%{"blueprint_id" => bid}, _vocation) when not is_nil(bid), do: nil
  defp maybe_vocation(_payload, vocation), do: vocation

  defp broadcast_space_archived(socket, space_id),
    do: broadcast_to_user(socket, :space_archived, %{"space_id" => space_id})

  defp broadcast_space_unarchived(socket, space_id),
    do: broadcast_to_user(socket, :space_unarchived, %{"space_id" => space_id})

  defp broadcast_space_created(socket, space, agent_name, model, vocation, attrs) do
    broadcast_to_user(socket, :space_created, %{
      "space" => space,
      "agentName" => agent_name
    })

    broadcast_agent_created(
      space.id,
      agent_name,
      model,
      vocation,
      attrs.workspace_path
    )
  end

  # Announce a space-set change on the per-user topic (#41). Every lobby
  # channel of this user is subscribed, so all of their sessions hear it and
  # no other user does — the pre-#41 `broadcast(socket, …)` went to the shared
  # `"lobby"` topic, which every connected user is on.
  defp broadcast_to_user(socket, tag, payload) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      Spaces.user_topic(socket.assigns.user_id),
      {tag, payload}
    )
  end

  defp do_change_model(space_id, name, model_params, socket) do
    case Agents.change_model(space_id, name, build_model_map(model_params)) do
      :ok ->
        Broadcasts.agent_updated(space_id, %{
          "name" => name,
          "model" => model_params,
          "space_id" => space_id
        })

        {:reply, {:ok, %{}}, socket}

      {:error, reason} ->
        {:reply, AgentErrors.change_model_payload(name, reason), socket}
    end
  end

  defp do_edit_agent(space_id, s, name, mp, workspace_path) do
    case Agents.edit_agent(space_id, name, build_model_map(mp), workspace_path) do
      :ok ->
        Broadcasts.agent_updated(space_id, %{
          "name" => name,
          "model" => mp,
          "workspace_path" => workspace_path,
          "space_id" => space_id
        })

        {:reply, {:ok, %{}}, s}

      {:error, reason} ->
        {:reply, AgentErrors.edit_payload(name, reason), s}
    end
  end

  defp extract_model(model_params) do
    %{
      name: model_params["name"] || model_params[:name],
      provider: model_params["provider"] || model_params[:provider],
      thinking_level: model_params["thinking_level"] || model_params[:thinking_level]
    }
  end

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

  defp broadcast_agent_created(space_id, name, model, vocation, workspace_path) do
    Broadcasts.agent_created(space_id, %{
      "name" => name,
      "space_id" => space_id,
      "model" => %{"name" => model.name, "provider" => model.provider},
      "vocation" => vocation,
      "workspace_path" => workspace_path
    })
  end

  defp build_model_map(model_params) do
    %{
      name: model_params["name"] || model_params[:name],
      provider: model_params["provider"] || model_params[:provider],
      thinking_level: model_params["thinking_level"] || model_params[:thinking_level]
    }
  end

  defp public_current_user(%Nest.Accounts.User{} = user) do
    %{
      id: user.id,
      username: user.username,
      is_admin: user.is_admin
    }
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_vocation_slug do
    case Vocations.list_vocations() do
      [] -> nil
      [first | _] -> first.slug
    end
  end
end
