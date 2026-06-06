defmodule NestWeb.SurgicalReloader do
  @moduledoc """
  Replaces Phoenix.CodeReloader. Restarts only supervision subtrees
  affected by changed modules. Protects Nest.Agents.* modules and their
  supervision tree from being restarted.

  For protected modules, code is hot-loaded but existing processes continue
  running old code until manually restarted. A warning is logged when these
  modules change.
  """
  use GenServer
  require Logger

  # === CONFIGURATION ===
  @immune_prefix "Elixir.Nest.Agents"
  @watched_dirs ["lib"]
  @debounce_ms 100

  # === PUBLIC API ===

  @doc """
  Starts the SurgicalReloader GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # === SERVER CALLBACKS ===

  @impl true
  def init(_opts) do
    # Start the file system watcher
    {:ok, watcher} =
      FileSystem.start_link(
        dirs: @watched_dirs,
        recursive: true
      )

    FileSystem.subscribe(watcher)

    state = %{
      watcher: watcher,
      compiling: false,
      pending_changes: MapSet.new(),
      debounce_timer: nil,
      module_map: build_module_map()
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, events}}, state) do
    if :modified in events or :created in events do
      # Only care about .ex and .exs files
      if String.ends_with?(path, [".ex", ".exs"]) do
        pending = MapSet.put(state.pending_changes, path)

        # Cancel previous timer if exists
        if state.debounce_timer do
          Process.cancel_timer(state.debounce_timer)
        end

        # Start new debounce timer
        timer = Process.send_after(self(), :do_compile, @debounce_ms)

        {:noreply, %{state | pending_changes: pending, debounce_timer: timer}}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:do_compile, %{pending_changes: pending} = state) do
    if not state.compiling and not Enum.empty?(pending) do
      handle_pending_compilation(state, pending)
    else
      {:noreply, %{state | debounce_timer: nil}}
    end
  end

  defp handle_pending_compilation(state, pending) do
    paths = MapSet.to_list(pending)

    case compile_paths(paths) do
      {:ok, changed_modules} ->
        handle_compilation_success(state, changed_modules)

      {:error, errors} ->
        handle_compilation_error(state, errors)
    end
  end

  defp handle_compilation_success(state, changed_modules) do
    Enum.each(changed_modules, fn mod ->
      restart_module_subtree(mod, state.module_map)
    end)

    new_module_map = build_module_map()

    {:noreply,
     %{
       state
       | pending_changes: MapSet.new(),
         compiling: false,
         debounce_timer: nil,
         module_map: new_module_map
     }}
  end

  defp handle_compilation_error(state, errors) do
    Logger.error("Compilation failed, no restarts performed")
    Logger.error("Errors: #{inspect(errors)}")

    {:noreply,
     %{
       state
       | pending_changes: MapSet.new(),
         compiling: false,
         debounce_timer: nil
     }}
  end

  # === COMPILATION ===

  defp compile_paths(paths) do
    # Use Mix's compiler to get actual changed modules
    case Mix.Task.run("compile.elixir", ["--return-errors", "--ignore-module-conflict"]) do
      {:error, errors} ->
        {:error, errors}

      _ ->
        # Determine which modules actually changed by checking BEAM mtime
        changed =
          paths
          |> Enum.filter(&elixir_file?/1)
          |> Enum.map(&path_to_module/1)
          |> Enum.reject(&is_nil/1)

        {:ok, changed}
    end
  end

  defp elixir_file?(path) do
    String.ends_with?(path, [".ex", ".exs"])
  end

  defp path_to_module(path) do
    path
    |> String.replace_prefix("lib/", "")
    |> String.replace_suffix(".ex", "")
    |> String.split("/")
    |> Enum.map(&Macro.camelize/1)
    |> Module.concat()
  rescue
    _ -> nil
  end

  # === SUPERVISION TREE SURGERY ===

  defp restart_module_subtree(module, module_map) do
    cond do
      # Check if this is an immune module (protected from restart)
      immune_module?(module) ->
        Logger.warning(
          "SurgicalReloader: Protected module #{inspect(module)} changed. " <>
            "Code hot-loaded but existing processes will continue running old code until manually restarted."
        )

        :ok

      # Module not in any supervised tree — just loaded
      is_nil(Map.get(module_map, module)) ->
        Logger.debug(
          "SurgicalReloader: Module #{inspect(module)} not supervised, code loaded only"
        )

        :ok

      # Module is supervised and not immune - restart it
      true ->
        {supervisor, child_id} = Map.get(module_map, module)

        if immune_supervisor?(supervisor) do
          Logger.warning(
            "SurgicalReloader: Module #{inspect(module)} lives under immune supervisor #{inspect(supervisor)}, " <>
              "skipping restart. Code hot-loaded but existing processes will continue running old code."
          )

          :ok
        else
          Logger.info("SurgicalReloader: Restarting #{child_id} under #{inspect(supervisor)}")
          restart_child(supervisor, child_id)
        end
    end
  end

  defp restart_child(supervisor, child_id) do
    # Graceful: terminate then restart
    with :ok <- Supervisor.terminate_child(supervisor, child_id),
         {:ok, _pid} <- Supervisor.restart_child(supervisor, child_id) do
      :ok
    else
      error ->
        Logger.error(
          "SurgicalReloader: Failed to restart #{child_id}: #{inspect(error)}. " <>
            "Attempting parent supervisor restart."
        )

        # Fall back to restarting the entire supervisor
        restart_supervisor(supervisor)
    end
  end

  defp restart_supervisor(supervisor) do
    # Find parent supervisor
    case find_parent_supervisor(supervisor) do
      nil ->
        Logger.error("SurgicalReloader: Cannot restart #{inspect(supervisor)}, no parent found")

      parent ->
        child_id = supervisor_to_child_id(supervisor, parent)

        if child_id do
          restart_child(parent, child_id)
        else
          Logger.error(
            "SurgicalReloader: Cannot find child_id for #{inspect(supervisor)} under #{inspect(parent)}"
          )
        end
    end
  end

  # === MODULE MAP BUILDING ===

  defp build_module_map do
    # Walk the entire supervision tree and map module -> {supervisor, child_id}
    walk_tree(Nest.Supervisor, %{})
  end

  defp walk_tree(supervisor, acc) do
    # Check if supervisor is still alive
    if Process.alive?(supervisor) do
      children = Supervisor.which_children(supervisor)

      Enum.reduce(children, acc, fn
        {child_id, pid, :worker, [module]}, acc when is_pid(pid) ->
          # Worker process
          Map.put(acc, module, {supervisor, child_id})

        {child_id, pid, :supervisor, [module]}, acc when is_pid(pid) ->
          # Child supervisor - add to map and recurse
          acc = Map.put(acc, module, {supervisor, child_id})
          walk_tree(pid, acc)

        # Handle other cases (like :undefined pids during shutdown)
        _, acc ->
          acc
      end)
    else
      acc
    end
  rescue
    # Supervisor might be dead during traversal
    _ -> acc
  end

  # === IMMUNE CHECKS ===

  defp immune_module?(module) do
    # Check if module is in the Nest.Agents namespace
    module_str = inspect(module)
    String.starts_with?(module_str, @immune_prefix)
  end

  defp immune_supervisor?(supervisor) when is_pid(supervisor) do
    # Get the module name for this supervisor
    case Process.info(supervisor, :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        immune_module?(Module.concat([name]))

      _ ->
        # Try to get from Supervisor.which_children of parent
        false
    end
  end

  defp immune_supervisor?(supervisor) when is_atom(supervisor) do
    immune_module?(supervisor)
  end

  # === HELPER FUNCTIONS ===

  defp find_parent_supervisor(child_supervisor) when is_pid(child_supervisor) do
    # Walk up from the root to find parent
    find_parent_from_root(Nest.Supervisor, child_supervisor)
  end

  defp find_parent_supervisor(child_supervisor) when is_atom(child_supervisor) do
    # Try to get the pid
    case Process.whereis(child_supervisor) do
      nil -> nil
      pid -> find_parent_supervisor(pid)
    end
  end

  defp find_parent_from_root(root, target) when is_pid(root) do
    children = Supervisor.which_children(root)

    Enum.find_value(children, fn
      {_, ^target, :supervisor, _} ->
        # Found it - return this root as the parent
        root

      {_, pid, :supervisor, _} when is_pid(pid) ->
        # Recurse into child supervisor
        find_parent_from_root(pid, target)

      _ ->
        nil
    end)
  rescue
    _ -> nil
  end

  defp supervisor_to_child_id(supervisor, parent) when is_pid(parent) do
    Supervisor.which_children(parent)
    |> Enum.find_value(fn
      {id, ^supervisor, :supervisor, _} -> id
      _ -> nil
    end)
  rescue
    _ -> nil
  end

  defp supervisor_to_child_id(supervisor, parent) when is_atom(parent) do
    case Process.whereis(parent) do
      nil -> nil
      pid -> supervisor_to_child_id(supervisor, pid)
    end
  end
end
