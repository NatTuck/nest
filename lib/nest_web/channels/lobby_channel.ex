defmodule NestWeb.LobbyChannel do
  @moduledoc """
  Channel for agent management operations.

  Handles:
  - Listing agents and available models
  - Creating new agents
  - Deleting agents

  Broadcasts agent lifecycle events to all connected clients.
  """

  use NestWeb, :channel

  require Logger

  alias Nest.Agents
  alias Nest.Models
  alias Nest.Vocations

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

  @broken_agents_budget_ms 2_000

  # Upper bound on a single `rescan_models` round-trip. The
  # fetch itself doesn't rate-limit per provider — slow providers
  # are caught by the per-HTTP-fetch timeout inside
  # `ChatModel.list_models/1` — but we still cap the spawn so a
  # pathological case (e.g. dotconfig that re-introduces a
  # provider on every reload) doesn't pin the channel.
  @rescan_budget_ms 5_000

  @impl true
  def handle_info(:after_join, socket) do
    agents = Agents.list_agents_info()
    vocations = Vocations.list_vocations()
    models = safe_models_list()

    # Push `init` immediately with an empty `broken_agents` list.
    # The real list is fetched in a separate task so that a hung
    # `Models.list/0` probe (the underlying call chain goes through
    # `Agent.Config.create_client_config` → `ChatModel.new/1` →
    # `Models.list/0`) doesn't block this channel's WS lifecycle.
    # The follow-up `broken_agents_updated` event delivers the
    # real list once the task completes (or empty on timeout).
    push(socket, "init", %{
      agents: agents,
      broken_agents: [],
      models: models,
      vocations: vocations
    })

    spawn_broken_agents_fetch(socket)
    {:noreply, socket}
  end

  # Handle the fetch result. The follow-up `broken_agents_updated`
  # event arrives as a plain message (the spawned process is
  # `Process.unlink`'d, so this GenServer doesn't crash if the
  # fetch dies).
  @impl true
  def handle_info({:lobby_broken_agents_loaded, broken}, socket)
      when is_list(broken) do
    push(socket, "broken_agents_updated", %{broken_agents: broken})
    {:noreply, socket}
  end

  # Handle the rescan result. The follow-up `models_updated`
  # event arrives as a plain message (the spawned process is
  # `Process.unlink`'d, so this GenServer doesn't crash if the
  # rescan dies).
  @impl true
  def handle_info({:lobby_models_updated, models}, socket) when is_list(models) do
    broadcast(socket, "models_updated", %{models: models})
    {:noreply, socket}
  end

  @doc false
  # Spawn a short-lived task that walks `Agents.list_broken_agents/0`
  # and pushes the result via `broken_agents_updated`. We deliberately
  # use a `spawn` (not `Task.async/await`) so a slow `Models.list/0`
  # probe — or a `:timeout` exit — only kills the spawned process,
  # never the channel.
  defp spawn_broken_agents_fetch(_socket) do
    parent = self()

    pid =
      spawn(fn ->
        result = fetch_broken_agents()
        send(parent, {:lobby_broken_agents_loaded, result})
      end)

    # Detach: a crash in the fetch must not propagate to the
    # channel process (the lobby is otherwise fully usable).
    Process.unlink(pid)
  end

  defp fetch_broken_agents do
    task = Task.async(fn -> Agents.list_broken_agents() end)

    case Task.yield(task, @broken_agents_budget_ms) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, broken} when is_list(broken) -> broken
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp spawn_rescan(_socket) do
    parent = self()

    pid =
      spawn(fn ->
        # Trap exits so the linked `Task.async` inside
        # `rescan_models_list/1` doesn't kill this spawn
        # process when the inner task exits (the inner
        # task's `exit/1` propagates via the link; without
        # trapping, the spawn dies before `send(parent, ...)`
        # is reached). The outer `rescue _ / catch :exit,
        # _ -> safe_models_list()` handles the cleanup.
        Process.flag(:trap_exit, true)

        result = rescan_models_list(@rescan_budget_ms)
        send(parent, {:lobby_models_updated, result})
      end)

    Process.unlink(pid)
  end

  @doc false
  # Re-discover the merged model catalog and return the fresh
  # list. Public for testability — exercises the
  # `Models.refresh/1` + `:sys.get_state/1` drain + `Models.list/0`
  # round-trip on a single BEAM scheduler tick (no spawn).
  # The channel's `rescan_models` push wraps this in a
  # `spawn`-and-relay, but the helpers themselves are pure
  # functions of `Models`' state.
  #
  # The optional `budget_ms` argument is the upper bound on
  # the refresh-and-read round-trip — defaults to
  # `@rescan_budget_ms`. Tests pass a small value so the
  # timeout path is exercised without the test framework's
  # default 5_000ms timeout getting in the way.
  def rescan_models_list(budget_ms \\ @rescan_budget_ms) do
    # Wrap the whole refresh-and-read in a `Task.async` +
    # `Task.yield/3` so a hung auto-provider probe can't pin
    # the spawn indefinitely. On timeout we `:brutal_kill` the
    # task and fall through to a fresh `safe_models_list/0` so
    # the catalog still includes everything that responded in
    # time (the GenServer's `state.models` is mutated as each
    # provider finishes, so partial results are preserved).
    task =
      Task.async(fn ->
        Models.refresh(reload_static: true)
        # Drain the cast by synchronously reading state. This is
        # the canonical pattern from `test/nest/models_test.exs:79`
        # — `:sys.get_state/1` returns immediately after the
        # GenServer has processed all prior mailbox messages.
        _ = :sys.get_state(Models)
        Models.list()
      end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, models} when is_list(models) -> models
      _ -> safe_models_list()
    end
  rescue
    _ -> safe_models_list()
  catch
    :exit, _ -> safe_models_list()
  end

  @impl true
  # `rescan_models` triggers a re-discovery of the model catalog.
  # The work runs in an unlinked spawn (so a hung `Models.list/0`
  # probe doesn't crash the channel), and the channel replies
  # `:ok` immediately so the client doesn't sit on the round-trip.
  # The actual catalog lands via the follow-up `models_updated`
  # broadcast — same empty-then-real pattern as
  # `broken_agents_updated`. With `:reload_static` set, the
  # merged catalog includes any `[providers.<n>]` entries the
  # user added to `~/.config/nest/config.toml` since startup.
  def handle_in("rescan_models", _payload, socket) do
    spawn_rescan(socket)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("create_agent", %{"model" => model_params} = payload, socket) do
    # Extract model name and provider from params. The frontend
    # sends both from the lobby's model catalog; we forward the
    # provider to `Agents.create_agent` so auto-discovered models
    # (which aren't in the static DotConfig) still get a provider
    # on the wire to the ChatPage header.
    model_name = model_params["name"] || model_params[:name]
    model_provider = model_params["provider"] || model_params[:provider]

    # Extract optional vocation_id and workspace_path
    vocation_id = payload["vocation_id"]
    workspace_path = payload["workspace_path"]

    # Build opts for agent creation
    opts =
      []
      |> maybe_add_opt(:vocation_id, vocation_id)
      |> maybe_add_opt(:workspace_path, workspace_path)

    # Create the agent
    case Agents.create_agent(%{name: model_name, provider: model_provider}, opts) do
      {:ok, name} ->
        # Broadcast to all clients with full agent info
        broadcast(socket, "agent:created", %{
          "name" => name,
          "model" => %{"name" => model_name, "provider" => model_provider},
          "vocation_id" => vocation_id,
          "workspace_path" => workspace_path
        })

        {:reply, {:ok, %{"name" => name}}, socket}

      {:error, reason} ->
        Logger.error("Failed to create agent: #{inspect(reason)}")
        {:reply, {:error, %{"reason" => "failed_to_create"}}, socket}
    end
  end

  @impl true
  def handle_in("delete_agent", %{"name" => name}, socket) do
    case Agents.delete_agent(name) do
      :ok ->
        broadcast(socket, "agent:deleted", %{"name" => name})
        {:reply, {:ok, %{}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("change_model", %{"name" => name, "model" => model_params}, socket)
      when is_map(model_params) do
    payload_model = build_model_map(model_params)

    case Agents.change_model(name, payload_model) do
      :ok ->
        broadcast(socket, "agent:updated", %{"name" => name, "model" => model_params})
        {:reply, {:ok, %{}}, socket}

      {:error, reason} ->
        {:reply, change_model_error_payload(name, reason), socket}
    end
  end

  def handle_in("change_model", _payload, socket) do
    {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  # Build the atom-keyed model map from the wire-format
  # params. Tolerant of atom or string keys; the DB layer
  # reads both shapes.
  defp build_model_map(model_params) do
    %{
      name: model_params["name"] || model_params[:name],
      provider: model_params["provider"] || model_params[:provider]
    }
  end

  # Translate `Agents.change_model/2` errors into the JSON
  # shape the JS side renders. Most error atoms map 1:1; the
  # remaining ones get logged at `:error` so an unexpected
  # failure leaves a server-side trail.
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

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
