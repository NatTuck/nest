defmodule NestWeb.LobbyChannel do
  @moduledoc """
  Channel for space and agent management operations.

  Handles:
  - Listing the user's spaces and the agents in each
  - Creating a new space (with its root agent)
  - Deleting agents
  - Changing an agent's model

  The `:after_join` resolves the user's primary space
  (`Nest.Spaces.ensure_primary_space/1`) and stashes it
  in `socket.assigns.primary_space_id`. Every operation
  that touches an agent runs against that space.

  Topic format: `"lobby"`. The wire payload of the `init`
  event includes the user's full spaces list and the
  primary space's agents, so the sidebar can render the
  selection without an extra round-trip.
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Accounts
  alias Nest.Agents
  alias Nest.Blueprints
  alias Nest.Models
  alias Nest.Spaces
  alias Nest.Vocations
  alias NestWeb.InviteJSON
  alias NestWeb.LobbyChannel.Authz
  alias NestWeb.LobbyChannel.Invites

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

  @rescan_budget_ms 5_000

  @impl true
  def handle_info(:after_join, socket) do
    user = socket.assigns.current_user

    # Resolve (or lazily create) the user's primary space.
    # The primary space is the lobby's default scope for every
    # Agents.* call on this socket.
    {:ok, primary_space} = Spaces.ensure_primary_space(user.id)
    primary_space_id = primary_space.id

    spaces = Spaces.list_for_user(user.id)
    agents = Agents.list_visible_agents_for(primary_space_id, user.id)
    vocations = Vocations.list_vocations()
    blueprints = Blueprints.list_blueprints()
    models = safe_models_list()

    push(socket, "init", %{
      spaces: spaces,
      current_space_id: primary_space_id,
      agents: agents,
      broken_agents: [],
      blueprints: blueprints,
      models: models,
      vocations: vocations,
      current_user: public_current_user(user),
      invites:
        user.id
        |> Accounts.list_user_invites()
        |> Enum.map(&InviteJSON.public_invite/1)
    })

    Phoenix.PubSub.subscribe(Nest.PubSub, "models")

    socket =
      socket
      |> assign(:primary_space_id, primary_space_id)
      |> assign(:user_id, user.id)

    fetch_broken_agents_async(socket, primary_space_id, user.id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:lobby_broken_agents_loaded, broken}, socket)
      when is_list(broken) do
    push(socket, "broken_agents_updated", %{broken_agents: broken})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:lobby_models_updated, models}, socket) when is_list(models) do
    broadcast(socket, "models_updated", %{models: models})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:models_updated, payload}, socket) when is_list(payload) do
    broadcast(socket, "models_updated", %{models: payload})
    {:noreply, socket}
  end

  # All `handle_in` clauses grouped together so the compiler
  # is happy with the multi-head pattern matching.
  @impl true
  def handle_in("create_space", payload, socket) when is_map(payload) do
    user_id = socket.assigns.user_id
    model = extract_model(Map.get(payload, "model") || %{})
    opts = build_create_opts_from_payload(payload, user_id)
    vocation_id = Keyword.fetch!(opts, :vocation_id)

    attrs = build_create_space_attrs(payload, model, vocation_id, opts)

    case Spaces.create_space_with_root_agent(user_id, attrs) do
      {:ok, %Spaces.Space{} = space, agent_name} ->
        broadcast_space_created(socket, space, agent_name, model, vocation_id, attrs)
        {:reply, {:ok, %{"space_id" => space.id, "name" => agent_name}}, socket}

      {:error, reason} ->
        Logger.error("Failed to create space: #{inspect(reason)}")
        {:reply, {:error, %{"reason" => "failed_to_create"}}, socket}
    end
  end

  @impl true
  def handle_in("change_model", %{"model" => model_params, "name" => name} = payload, socket)
      when is_map(model_params) do
    # Phase 1 followup (F3): drop the primary_space_id fallback
    # once the JS client always sends `space_id`. Today every user
    # has exactly one primary space so the fallback is safe, but
    # Phase 4 ships multi-space UI and the fallback could resolve
    # to the wrong space.
    space_id = payload["space_id"] || socket.assigns.primary_space_id
    user = socket.assigns.current_user

    case Authz.authorize_owner_or_shared(space_id, name, user) do
      {:ok, :owner} ->
        do_change_model(space_id, name, model_params, socket)

      {:ok, :shared} ->
        {:reply, {:error, %{"reason" => "shared_read_only"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("change_model", _payload, socket) do
    {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  @impl true
  def handle_in("delete_agent", payload, socket) when is_map(payload) do
    # Phase 1 followup (F3): drop the primary_space_id fallback
    # once the JS client always sends `space_id`. See the matching
    # note in `change_model/3` below.
    space_id = payload["space_id"] || socket.assigns.primary_space_id
    name = payload["name"]
    user = socket.assigns.current_user

    case Authz.authorize_owner(space_id, name, user) do
      :ok ->
        case Agents.delete_agent(space_id, name) do
          :ok ->
            broadcast(socket, "agent:deleted", %{"name" => name, "space_id" => space_id})
            {:reply, {:ok, %{}}, socket}

          {:error, :not_found} ->
            {:reply, {:error, %{"reason" => "not_found"}}, socket}
        end

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("rescan_models", _payload, socket) do
    spawn_rescan(socket)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("create_invite", payload, socket) do
    Invites.create_invite(payload, socket)
  end

  @impl true
  def handle_in("revoke_invite", payload, socket) do
    Invites.revoke_invite(payload, socket)
  end

  # -- Private helpers --

  defp fetch_broken_agents_async(_socket, space_id, user_id) do
    parent = self()

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      result =
        try do
          fetch_broken_agents(space_id, user_id)
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

  defp spawn_rescan(_socket) do
    parent = self()

    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        result = rescan_models_list(@rescan_budget_ms)
        send(parent, {:lobby_models_updated, result})
      end)

    Process.unlink(pid)
  end

  defp build_create_space_attrs(payload, model, vocation_id, opts) do
    %{
      name: payload["name"],
      slug: payload["slug"],
      blueprint_id: payload["blueprint_id"],
      model: model,
      # When the client picks a blueprint, the blueprint's
      # `root_vocation_id` should drive the root agent's
      # vocation, so we don't forward the lobby's default
      # `vocation_id` fallback. Without a blueprint we keep
      # the default-vocation behavior.
      vocation_id: maybe_vocation_id(payload, vocation_id),
      workspace_path: Keyword.get(opts, :workspace_path),
      agent_name: payload["agent_name"],
      shared: payload["shared"] == true
    }
  end

  defp maybe_vocation_id(%{"blueprint_id" => bid}, _vocation_id) when not is_nil(bid), do: nil
  defp maybe_vocation_id(_payload, vocation_id), do: vocation_id

  defp broadcast_space_created(socket, space, agent_name, model, vocation_id, attrs) do
    push(socket, "space:created", %{
      "space" => space,
      "agentName" => agent_name
    })

    broadcast_agent_created(
      socket,
      space.id,
      agent_name,
      model,
      vocation_id,
      attrs.workspace_path
    )
  end

  defp do_change_model(space_id, name, model_params, socket) do
    payload_model = build_model_map(model_params)

    case Agents.change_model(space_id, name, payload_model) do
      :ok ->
        broadcast(socket, "agent:updated", %{
          "name" => name,
          "model" => model_params,
          "space_id" => space_id
        })

        {:reply, {:ok, %{}}, socket}

      {:error, reason} ->
        {:reply, change_model_error_payload(name, reason), socket}
    end
  end

  defp extract_model(model_params) do
    %{
      name: model_params["name"] || model_params[:name],
      provider: model_params["provider"] || model_params[:provider]
    }
  end

  defp build_create_opts_from_payload(payload, current_user_id) do
    base_opts =
      build_create_opts(
        payload,
        payload["vocation_id"] || default_vocation_id(),
        payload["workspace_path"]
      )

    base_opts
    |> Keyword.put(:created_by_user_id, current_user_id)
    |> Keyword.put(:shared, payload["shared"] == true)
  end

  defp build_create_opts(payload, vocation_id, workspace_path) do
    []
    |> maybe_add_opt(:name, payload["name"])
    |> maybe_add_opt(:vocation_id, vocation_id)
    |> maybe_add_opt(:workspace_path, workspace_path)
  end

  defp broadcast_agent_created(socket, space_id, name, model, vocation_id, workspace_path) do
    broadcast(socket, "agent:created", %{
      "name" => name,
      "space_id" => space_id,
      "model" => %{"name" => model.name, "provider" => model.provider},
      "vocation_id" => vocation_id,
      "workspace_path" => workspace_path
    })
  end

  defp build_model_map(model_params) do
    %{
      name: model_params["name"] || model_params[:name],
      provider: model_params["provider"] || model_params[:provider]
    }
  end

  defp change_model_error_payload(_name, :agent_busy) do
    {:error, %{"reason" => "agent_busy"}}
  end

  defp change_model_error_payload(_name, {:invalid_model, _reason}) do
    {:error, %{"reason" => "invalid_model"}}
  end

  defp change_model_error_payload(_name, :not_found) do
    {:error, %{"reason" => "not_found"}}
  end

  defp change_model_error_payload(name, reason) do
    Logger.error("Failed to change model on agent #{inspect(name)}: #{inspect(reason)}")
    {:error, %{"reason" => to_string(reason)}}
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

  defp default_vocation_id do
    case Vocations.list_vocations() do
      [] -> nil
      [first | _] -> first.id
    end
  end

  @doc false
  def rescan_models_list(
        budget_ms \\ @rescan_budget_ms,
        runner \\ &default_rescan_runner/0
      ) do
    task = Task.async(runner)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, models} when is_list(models) -> models
      _ -> safe_models_list()
    end
  rescue
    _ -> safe_models_list()
  catch
    :exit, _ -> safe_models_list()
  end

  def default_rescan_runner do
    Models.reload_static()
    Phoenix.PubSub.subscribe(Nest.PubSub, "models")
    Models.refresh()

    receive do
      {:models_updated, _} -> :ok
    end

    Phoenix.PubSub.unsubscribe(Nest.PubSub, "models")
    Models.list()
  end
end
