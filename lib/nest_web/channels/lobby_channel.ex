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

    # Subscribe to the "models" PubSub topic for live updates.
    # `Models` broadcasts `{:models_updated, payload}` on every
    # scan completion and on `reload_static/0` when no scan is
    # in flight. The handler below pushes the payload to UI.
    Phoenix.PubSub.subscribe(Nest.PubSub, "models")

    fetch_broken_agents_async(socket)
    {:noreply, socket}
  end

  # Handle the fetch result. The follow-up `broken_agents_updated`
  # event arrives as a plain message (the Task is `:temporary`
  # so its death doesn't restart, and the `Task.await/2` returns
  # the result or `nil` on timeout).
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

  # PubSub-driven update from `Nest.Models`. The Models GenServer
  # broadcasts `{:models_updated, payload}` on the `"models"` topic
  # on every scan completion and on `reload_static/0` when no scan
  # is in flight. Each lobby channel that subscribed in
  # `handle_info(:after_join, ...)` re-broadcasts to its own socket.
  # Duplication across channels is bounded by the number of
  # simultaneously-connected lobby sockets — each receives its own
  # channel's broadcast, not others'. The UI can dedupe by payload
  # content if needed.
  @impl true
  def handle_info({:models_updated, payload}, socket) when is_list(payload) do
    broadcast(socket, "models_updated", %{models: payload})
    {:noreply, socket}
  end

  # Use a supervised Task that inherits this channel pid's
  # `$callers` chain (so the DB query walks back to the test
  # pid in tests, and to the application's connection pool in
  # production). A bare `spawn/1` does NOT inherit `$callers`,
  # which is why the previous design failed the
  # `DBConnection.OwnershipError` in async channel tests.
  # The `Task.await/2` bounds the wall-clock so a hung
  # `Models.list/0` probe (the slowest reachable call inside
  # `list_broken_agents/0`) can't pin the channel.
  defp fetch_broken_agents_async(_socket) do
    parent = self()

    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      # The supervised Task runs in its own pid. In async
      # channel tests that pid cannot reach the test's
      # sandboxed connection, so the inner `Repo.all(...)`
      # raises `DBConnection.OwnershipError`. The
      # `fetch_broken_agents/0` rescue returns `[]` so the
      # `broken_agents_updated` follow-up still fires —
      # but the Task.Supervisor's `invoke_mfa` wrapper
      # logs the death before the rescue can swallow it.
      # Suppress the noise at the source: a fine-grained
      # `try` here turns the raise into a normal exit,
      # which the supervisor doesn't log.
      result =
        try do
          fetch_broken_agents()
        catch
          _, _ -> []
        end

      send(parent, {:lobby_broken_agents_loaded, result})
    end)

    :ok
  end

  @doc false
  defp fetch_broken_agents do
    Agents.list_broken_agents()
  rescue
    e ->
      Logger.debug("fetch_broken_agents rescued: #{Exception.message(e)}")
      []
  catch
    kind, reason ->
      Logger.debug("fetch_broken_agents caught #{kind}: #{inspect(reason)}")
      []
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
  # The `rescan_models_list/1` helper below is grouped with
  # the helpers (after all `handle_in/3` clauses) to keep
  # the warning about clause grouping quiet.
  def handle_in("rescan_models", _payload, socket) do
    spawn_rescan(socket)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("create_agent", %{"model" => model_params} = payload, socket) do
    model_name = model_params["name"] || model_params[:name]
    model_provider = model_params["provider"] || model_params[:provider]

    # `agents.vocation_id` is NOT NULL, so the channel handler
    # must always supply one. The frontend sends the
    # user-selected `vocation_id`; when missing (e.g. the
    # `NewAgentPage` test path, or a direct API call), fall
    # back to the first available vocation.
    vocation_id = payload["vocation_id"] || default_vocation_id()
    workspace_path = payload["workspace_path"]

    # The agent's `name` (registry key, DB row primary name)
    # is independent of the model name. Per the standard
    # caller interface, the model's `:name` is the LLM
    # identifier (e.g. "qwen3.5-plus") — NOT the agent's
    # registry key. The frontend may pass an explicit
    # `name:` in the payload (the lobby lets users rename
    # before submitting); when missing, `Agents.create_agent/2`
    # falls back to the supervisor's name generator.
    opts = build_create_opts(payload, vocation_id, workspace_path)
    model = %{name: model_name, provider: model_provider}

    case Agents.create_agent(model, opts) do
      {:ok, name} ->
        broadcast_agent_created(socket, name, model, vocation_id, workspace_path)
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

  # The frontend may send keys as strings or atoms depending on
  # the codec; normalize to atoms for `Agents.create_agent/2`.
  defp build_create_opts(payload, vocation_id, workspace_path) do
    []
    |> maybe_add_opt(:name, payload["name"])
    |> maybe_add_opt(:vocation_id, vocation_id)
    |> maybe_add_opt(:workspace_path, workspace_path)
  end

  defp broadcast_agent_created(socket, name, model, vocation_id, workspace_path) do
    broadcast(socket, "agent:created", %{
      "name" => name,
      "model" => %{"name" => model.name, "provider" => model.provider},
      "vocation_id" => vocation_id,
      "workspace_path" => workspace_path
    })
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

  # First vocation in the catalog. Returns `nil` when the
  # vocations table is empty (the agent will then fail
  # to insert because `agents.vocation_id` is NOT NULL —
  # the user's seed/init must create at least one).
  defp default_vocation_id do
    case Vocations.list_vocations() do
      [] -> nil
      [first | _] -> first.id
    end
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
  #
  # The optional `runner` argument is the closure that runs
  # inside the `Task.async/1`. Production callers leave it
  # defaulted to `&default_rescan_runner/0` (the real
  # `Models.refresh` + `Models.list` round-trip). Tests pass
  # a closure directly — this avoids the
  # `set_mimic_global` + `async: false` workaround, since
  # Mimic stubs are per-process and can't reach the Task pid.
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

  # The default `Task.async` body for `rescan_models_list/2`:
  # reload `config.toml` (fast, synchronous), subscribe to the
  # `"models"` PubSub topic, kick a refresh, wait for the next
  # `{:models_updated, _}` broadcast, and return the merged catalog.
  # Pulled out as a named function so tests can substitute their own
  # closure via the `runner` arg without paying the `set_mimic_global`
  # cost.
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
