defmodule Nest.Agents do
  @moduledoc """
  Public API for agent management.

  This module provides a high-level interface for creating, managing, and
  interacting with agents. It delegates to the appropriate modules in the
  supervision tree.
  """

  alias Nest.Agents.{Agent, Registry, Supervisor}
  alias Nest.Agents.PersistedAgent
  alias Nest.DotConfig
  alias Nest.Persistence
  alias Nest.Vocations

  @doc """
  Creates a new agent with the given model and optional vocation.

  ## Parameters
  - `model` - A map with `:name` and optionally other model configuration
  - `opts` - Optional parameters:
    - `:vocation_id` - ID of the vocation to use
    - `:workspace_path` - Path to the workspace directory

  ## Returns
  - `{:ok, name}` - Agent created successfully with readable name
  - `{:error, reason}` - Failed to create agent

  ## Examples

      {:ok, "clever-raven"} = Agents.create_agent(%{name: "gpt-4"})
      {:ok, "clever-raven"} = Agents.create_agent(%{name: "gpt-4"}, vocation_id: 1, workspace_path: "/tmp/workspace")

  """
  @spec create_agent(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_agent(model, opts \\ []) when is_map(model) do
    attrs = %{
      model: enrich_model(model),
      vocation_id: Keyword.get(opts, :vocation_id),
      workspace_path: Keyword.get(opts, :workspace_path)
    }

    Supervisor.fetch_or_start_agent(attrs)
  end

  # Adds `:provider` to the model map if it's missing and the model is
  # known to DotConfig. The channel sends the model map to the JS
  # client, which uses `provider` to render `provider: model-name`.
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
  Gets the public info of an agent by its name.

  ## Returns
  - `{:ok, info}` - Agent found with public info
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      {:ok, info} = Agents.get_info("clever-raven")
      # info.name, info.model, info.message_count, info.status, info.partial

  """
  @spec get_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_info(name) do
    case Supervisor.get_agent(name) do
      {:ok, pid} -> {:ok, Agent.get_public_info(pid)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Gets the full agent state by its name.

  ## Returns
  - `{:ok, agent}` - Agent found with full state including messages
  - `{:error, :not_found}` - Agent doesn't exist
  - `{:error, reason}` - Any other `Supervisor.get_agent/1` failure
    (e.g. `:timeout` if a GenServer call inside the hydration
    path blocked — `Models.list/0` is the usual culprit). The
    AgentChannel's `join/3` catches this and returns
    `{:error, %{"reason" => "agent_unavailable"}}` so the WS
    doesn't crash on a transient hydration hiccup.

  """
  @spec get_agent(String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_agent(name) do
    case Supervisor.get_agent(name) do
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
  end

  defp get_vocation_info(nil), do: nil

  defp get_vocation_info(vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil -> nil
      v -> %{id: v.id, name: v.name}
    end
  end

  @doc """
  Lists all running agent names.

  Returns a list of agent name strings.

  ## Examples

      ["clever-raven", "swift-fox"]

  """
  @spec list_agents() :: list(String.t())
  def list_agents do
    Registry.list()
  end

  @doc """
  Lists public info for all running agents.

  Returns a list of maps containing agent public info.

  ## Examples

      [%{name: "clever-raven", model: %{name: "gpt-4"}, status: :idle, message_count: 0}, ...]

  """
  @spec list_agents_info() :: list(map())
  def list_agents_info do
    list_agents()
    |> Enum.map(&get_info/1)
    |> Enum.filter(fn
      {:ok, info} -> info
      _ -> nil
    end)
    |> Enum.map(fn {:ok, info} -> info end)
  end

  @doc """
  Gets the messages for an agent by its name.

  ## Returns
  - `{:ok, messages}` - Agent found with messages
  - `{:error, :not_found}` - Agent doesn't exist

  """
  @spec get_messages(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_messages(name) do
    case Supervisor.get_agent(name) do
      {:ok, pid} -> {:ok, Agent.get_messages(pid)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Sends a chat message to an agent.

  The message is added to the agent's history and triggers a streaming
  response from the LLM.

  The optional `mode` selects the sandbox capability profile for this
  message's tool calls. When `nil`, defaults to the agent's current
  mode (first key in the vocation's `modes` map, or `"chat"` if none).
  The mode is stored on the user message and applied to subsequent
  tool calls in the same round.

  ## Returns
  - `:ok` - Message sent successfully
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      :ok = Agents.chat("clever-raven", "Hello!")
      :ok = Agents.chat("clever-raven", "Read foo.md", "plan")

  """
  @spec chat(String.t(), String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def chat(name, content, mode \\ nil) do
    case Supervisor.get_agent(name) do
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

  The `from` is the channel pid that initiated the stop; it is
  threaded through so the agent's `handle_info({:stop_chat, from}, _)`
  can forward a reply if needed (currently it does not, but
  keeping the indirection lets us add an ack later without
  breaking the channel contract).

  A no-op when the agent is idle (no in-flight chat task).
  Idempotent — multiple calls just re-set the `cancelled`
  flag on the GenServer's state.

  ## Returns
  - `:ok` - Stop signal sent (agent exists)
  - `{:error, :not_found}` - Agent doesn't exist
  """
  @spec stop_chat(String.t(), pid()) :: :ok | {:error, :not_found}
  def stop_chat(name, from) do
    case Supervisor.get_agent(name) do
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
  Retry a compaction that previously failed. The agent must be in
  `:compaction_failed` status (otherwise this is a no-op and returns
  `{:error, :not_in_compaction_failed_state}`). On success, the
  compactor runs again; on failure, the agent stays in
  `:compaction_failed` and the user can retry again.
  """
  @spec retry_compaction(String.t()) :: :ok | {:error, atom()}
  def retry_compaction(name) do
    case Supervisor.get_agent(name) do
      {:ok, pid} ->
        Agent.retry_compaction(pid)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Acknowledge a `:compaction_loop_detected` status by sending
  `:compaction_loop_detected_ok` to the agent. The handler
  transitions the agent back to `:idle` and clears the
  consecutive-compaction counter (so the next compaction
  cycle has a fresh budget). No-op if the agent isn't in the
  loop state.
  """
  @spec compaction_loop_detected_ok(String.t()) :: :ok | {:error, atom()}
  def compaction_loop_detected_ok(name) do
    case Supervisor.get_agent(name) do
      {:ok, pid} ->
        Agent.compaction_loop_detected_ok(pid)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes an agent by its name.

  ## Returns
  - `:ok` - Agent deleted successfully
  - `{:error, :not_found}` - Agent doesn't exist

  ## Examples

      :ok = Agents.delete_agent("clever-raven")

  """
  @spec delete_agent(String.t()) :: :ok | {:error, :not_found}
  def delete_agent(name) do
    Supervisor.stop_agent(name)
  end

  @doc """
  Change an agent's persisted `model` and resolved LLM client.

  Allowed only when the agent's runtime status is `:idle` or
  `:model_missing`. Returns `{:error, :agent_busy}` when the
  agent is streaming, executing tools, or in any other status.
  Returns `{:error, {:invalid_model, reason}}` when the new
  model can't be resolved to a runtime provider.

  The user-supplied `model` map can have either atom or string
  keys; both shapes are passed through to
  `Config.create_client_config/1`, which extracts the `:name`
  (or `"name"`) key for `ChatModel.new(model: name)`.

  ## Examples

      :ok = Agents.change_model("clever-raven", %{name: "claude-haiku-4-5", provider: "anthropic"})
  """
  @spec change_model(String.t(), map()) :: :ok | {:error, term()}
  def change_model(name, new_model) when is_map(new_model) do
    case Supervisor.get_agent(name) do
      {:ok, pid} -> Agent.set_model(pid, new_model)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List agents whose persisted `model` no longer resolves to a
  runtime provider. Each entry carries `name`, the unresolved
  `model` map, and a `:status` of `:model_missing`.

  Used by the lobby's `:after_join` payload so the UI can
  surface broken agents and offer the user a repair path
  (`Agents.change_model/2`). The recovery flow is independent
  of `list_agents_info/0`, which only returns live (startable)
  agents — broken agents are intentionally excluded from that
  view because their `client_config.client` would be
  `RecoveryClient`, which can't actually chat.
  """
  @spec list_broken_agents() :: [map()]
  def list_broken_agents do
    Enum.flat_map(Persistence.fetch_all_agents(), &maybe_report_broken/1)
  end

  # Decide whether a single persisted agent row should appear
  # in the lobby's `broken_agents` payload. Returns `[]` for
  # agents that are either alive in the Registry (the
  # supervisor's `get_agent/1` will hydrate them on demand) or
  # that *can* be hydrated right now (a transient inconsistency
  # we don't want to surface as broken), and `[%{name, model,
  # status: :model_missing}]` for the rest.
  defp maybe_report_broken(%PersistedAgent{name: name, model: model}) do
    cond do
      agent_alive?(name) ->
        []

      not agent_loadable?(model) ->
        [%{name: name, model: model, status: :model_missing}]

      true ->
        []
    end
  end

  defp agent_alive?(name) do
    case Registry.lookup(name) do
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
