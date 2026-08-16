defmodule Nest.Agents do
  @moduledoc """
  Public API for agent management.

  This module provides a high-level interface for creating, managing, and
  interacting with agents. Agent names are unique within a space, and the
  identity tuple `{space_id, name}` is carried positionally through every
  public function — it never lives in `opts`.
  """

  alias Nest.Agents.{Agent, Registry, Supervisor}
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Visibility
  alias Nest.DotConfig
  alias Nest.Persistence
  alias Nest.Vocations

  @doc """
  Creates a new agent with the given model in `space_id`.

  ## Parameters

  * `space_id` — the id of the space the agent belongs to (required)
  * `model` — a map with `:name` and optionally `:provider`
  * `opts` — additional parameters:
    * `:name` — explicit agent name (default: auto-generated)
    * `:vocation_id` — id of the vocation to use
  * `:workspace_path` — path to the workspace directory
  * `:created_by_user_id` — the owning user
  * `:shared` — visibility flag (default `false`)
  * `:parent_id` — integer `agents.id` of the spawning agent
  * `:parent_name` — readable name of the spawning agent
  * `:depth` — tree depth (default 0); children get `parent + 1`

  ## Returns

  * `{:ok, name}` — agent created successfully with readable name
  * `{:error, reason}` — failed to create agent
  """
  @spec create_agent(integer(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_agent(space_id, model, opts \\ []) when is_integer(space_id) and is_map(model) do
    attrs = %{
      name: name_or_generate(space_id, opts),
      space_id: space_id,
      model: enrich_model(model),
      vocation_id: Keyword.get(opts, :vocation_id),
      workspace_path: Keyword.get(opts, :workspace_path),
      created_by_user_id: Keyword.get(opts, :created_by_user_id),
      shared: Keyword.get(opts, :shared, false),
      parent_id: Keyword.get(opts, :parent_id),
      parent_name: Keyword.get(opts, :parent_name),
      depth: Keyword.get(opts, :depth, 0)
    }

    # `pre_spawn` renders the system prompt from the loaded `vocation`
    # struct (it needs the struct, not just the id) so the initial
    # system message row is persisted at index 0. Without this, root
    # agents were created with no system message in the DB — the
    # "hd(messages) is always a system message" invariant was broken.
    attrs = Persistence.build_agent_attrs(attrs)

    with :ok <- Agent.pre_spawn(attrs) do
      Supervisor.fetch_or_start_agent(space_id, attrs)
    end
  end

  defp name_or_generate(space_id, opts) do
    Keyword.get(opts, :name) || Supervisor.generate_unique_name_for_space(space_id)
  end

  defp enrich_model(%{provider: _} = model), do: model

  defp enrich_model(%{name: name} = model) when is_binary(name) do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.get_model(config, name) do
          nil -> model
          %{provider_name: provider} -> Map.put(model, :provider, provider)
        end

      _ ->
        model
    end
  end

  defp enrich_model(model), do: model

  @doc """
  Gets the public info of an agent by its `{space_id, name}`.
  """
  @spec get_info(integer(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_info(space_id, name) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} ->
        try do
          {:ok, Agent.get_public_info(pid)}
        catch
          :exit, _ -> {:error, :not_found}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Gets the full agent state by its `{space_id, name}`.
  """
  @spec get_agent(integer(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_agent(space_id, name) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} -> build_agent_data(pid)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_agent_data(pid) do
    info = Agent.get_public_info(pid)
    messages = Agent.get_messages(pid)
    vocation = get_vocation_info(info.vocation_id)

    agent = %{
      name: info.name,
      space_id: info.space_id,
      model: info.model,
      vocation: vocation,
      messages: messages,
      history: Agent.get_history(pid),
      status: info.status,
      partial: info.partial,
      modes: info.modes,
      default_mode: info.default_mode,
      current_mode: info.current_mode,
      context_limit: info.context_limit,
      context_limit_source: info.context_limit_source,
      usage: info.usage
    }

    {:ok, agent}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp get_vocation_info(nil), do: nil

  defp get_vocation_info(vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil -> nil
      v -> %{id: v.id, name: v.name}
    end
  end

  @doc """
  Lists all running agent names in `space_id`.
  """
  @spec list_agents_for_space(integer()) :: list(String.t())
  def list_agents_for_space(space_id) do
    Registry.list_for_space(space_id)
  end

  @doc """
  Lists public info for all running agents in `space_id`.
  """
  @spec list_agents_info_for_space(integer()) :: list(map())
  def list_agents_info_for_space(space_id) do
    space_id
    |> list_agents_for_space()
    |> Enum.map(&get_info(space_id, &1))
    |> Enum.filter(fn
      {:ok, info} -> info
      _ -> nil
    end)
    |> Enum.map(fn {:ok, info} -> info end)
  end

  @doc """
  Lists public info for the agents in `space_id` that the given
  user is allowed to see.
  """
  @spec list_visible_agents_for(integer(), integer()) :: list(map())
  def list_visible_agents_for(space_id, user_id) do
    Visibility.list_visible_agents_for(space_id, user_id)
  end

  @doc """
  Gets the messages for an agent by its `{space_id, name}`.
  """
  @spec get_messages(integer(), String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_messages(space_id, name) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} -> {:ok, Agent.get_messages(pid)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Sends a chat message to an agent in `space_id`.
  """
  @spec chat(integer(), String.t(), String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def chat(space_id, name, content, mode \\ nil) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} ->
        Agent.chat(pid, content, mode)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Signal the in-flight chat task on the named agent to stop.
  """
  @spec stop_chat(integer(), String.t(), pid()) :: :ok | {:error, :not_found}
  def stop_chat(space_id, name, from) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} ->
        Agent.stop_chat(pid, from)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retry a compaction that previously failed.
  """
  @spec retry_compaction(integer(), String.t()) :: :ok | {:error, atom()}
  def retry_compaction(space_id, name) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} -> Agent.retry_compaction(pid)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Acknowledge a `:compaction_loop_detected` status.
  """
  @spec compaction_loop_detected_ok(integer(), String.t()) :: :ok | {:error, atom()}
  def compaction_loop_detected_ok(space_id, name) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} -> Agent.compaction_loop_detected_ok(pid)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Change an agent's persisted `model` and resolved LLM client.
  """
  @spec change_model(integer(), String.t(), map()) :: :ok | {:error, term()}
  def change_model(space_id, name, new_model) when is_map(new_model) do
    case Supervisor.get_agent(space_id, name) do
      {:ok, pid} -> Agent.set_model(pid, new_model)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List agents in `space_id` whose persisted `model` no longer
  resolves to a runtime provider.
  """
  @spec list_broken_agents(integer()) :: [map()]
  def list_broken_agents(space_id) when is_integer(space_id) do
    Enum.flat_map(Persistence.fetch_all_agents_for_space(space_id), &maybe_report_broken/1)
  end

  defp maybe_report_broken(%PersistedAgent{
         name: name,
         space_id: space_id,
         model: model,
         created_by_user_id: owner_id,
         shared: shared
       }) do
    cond do
      agent_alive?(space_id, name) ->
        []

      not agent_loadable?(model) ->
        [
          %{
            name: name,
            space_id: space_id,
            model: model,
            created_by_user_id: owner_id,
            shared: shared,
            status: :model_missing
          }
        ]

      true ->
        []
    end
  end

  defp agent_alive?(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  defp agent_loadable?(model) do
    case Agent.Config.create_client_config(model) do
      {:ok, _client_config} -> true
      {:error, _reason} -> false
    end
  end
end
