defmodule Nest.Agents.Agent.Init do
  @moduledoc """
  Initial state construction for the agent GenServer.
  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays small.

  The `init/1` callback delegates to `build_state/2` here for
  the struct construction (no side effects) and to
  `persist_initial_system_message/1` for the DB write of the
  initial system message row.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.TreePosition
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Tools

  @doc """
  Build the initial state struct. Pure: no DB writes, no
  broadcasts, no logging.

  The caller is responsible for providing the loaded vocation
  struct via `:vocation` in `attrs` (typically fetched via
  `Persistence.load_vocation/1` or `Vocations.get_vocation/1`
  in the calling process). This keeps `init/1` free of DB
  work, which is what lets the agent run in async tests with
  `$callers` walking instead of per-pid `Sandbox.allow`.
  """
  @spec build_state(map(), Nest.LLM.ClientConfig.t()) :: Nest.Agents.Agent.t()
  def build_state(attrs, client_config) do
    {system_prompt, mode, tool_names, cached_vocation, llm_metrics} =
      build_vocation_pipeline(attrs)

    name = Map.fetch!(attrs, :name)
    tmp_path = create_tmp_space(name)
    tools = Tools.get_functions(tool_names, Map.get(attrs, :workspace_path), tmp_path)

    {initial_messages, next_index} = initial_messages_with_system(system_prompt)
    initial_api_log_sequences = Map.get(attrs, :initial_api_log_sequences, %{})

    %Nest.Agents.Agent{
      name: name,
      space_id: Map.fetch!(attrs, :space_id),
      model: Map.fetch!(attrs, :model),
      client_config: client_config,
      vocation: cached_vocation,
      vocation_id: Map.fetch!(attrs, :vocation_id),
      workspace_path: Map.get(attrs, :workspace_path),
      tmp_path: tmp_path,
      tools: tools,
      llm_metrics: llm_metrics,
      tree_position: %TreePosition{
        parent_id: Map.get(attrs, :parent_id),
        parent_name: Map.get(attrs, :parent_name)
      },
      created_by_user_id: Map.get(attrs, :created_by_user_id),
      shared: Map.get(attrs, :shared, false),
      depth: Map.get(attrs, :depth, 0),
      chat_state: build_chat_state(initial_messages, next_index),
      live: build_live_state(initial_api_log_sequences, mode)
    }
  end

  # Vocation-derived attributes: context limit, system prompt,
  # tool list, cached vocation struct, and the `llm_metrics`
  # initializer. Kept as its own helper so `build_state/2`
  # stays under the credo ABC cap.
  defp build_vocation_pipeline(attrs) do
    model = Map.fetch!(attrs, :model)
    {context_limit, context_limit_source} = initial_context_limit(model)

    {system_prompt, mode, tool_names, cached_vocation} =
      SystemPrompt.compose_vocation_config(
        Map.get(attrs, :vocation),
        Map.get(attrs, :workspace_path),
        {context_limit, context_limit_source},
        Map.get(attrs, :name, ""),
        Map.get(attrs, :depth, 0)
      )

    tool_names = maybe_exclude_spawn(tool_names, attrs)

    {system_prompt, mode, tool_names, cached_vocation,
     build_llm_metrics(context_limit, context_limit_source)}
  end

  # Non-clone agents spawned at max depth must not be able to
  # spawn children, so `agents/spawn` is dropped from their
  # tool list. Clones never set `:exclude_spawn` — they must
  # keep the exact tool list of their parent (hard rule).
  defp maybe_exclude_spawn(tool_names, %{exclude_spawn: true}),
    do: Enum.reject(tool_names, &(&1 == "agents/spawn"))

  defp maybe_exclude_spawn(tool_names, _attrs), do: tool_names

  @doc """
  Persist the initial system message built by `build_state/2`
  into the `messages` table. No-op when persistence is disabled
  or when the agent's `chat_state.messages` list is empty.

  This function is retained for direct callers that want to
  pre-persist a system message row outside of `Agent.start_link/1`
  — for example, the regression test in `agent_persistence_test.exs`
  that pins the wrapper's idempotency contract. `Agent.init/1`
  no longer calls this; the canonical pre-spawn write lives in
  `Agent.start_link/1` itself (in the calling process's DB context).
  """
  @spec persist_initial_system_message(Nest.Agents.Agent.t()) :: :ok
  def persist_initial_system_message(state) do
    case state.chat_state.messages do
      [{:system, sys_struct} | _] when is_struct(sys_struct, System) ->
        AgentPersistence.append_message(
          state.space_id,
          state.name,
          {:system, sys_struct},
          state.chat_state.next_message_index
        )

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Seed the agent's `chat_state` from a freshly-loaded DB
  message sequence. The `preloaded` list is the ordered
  sequence returned by `Persistence.load_messages/1`
  (active + history + compaction markers). `last_compaction_index`
  is the runtime mirror of `agents.last_compaction_index`.

  Splits the sequence into `state.chat_state.history` (rows
  with `index <= last_compaction_index`) and
  `state.chat_state.messages` (rows strictly greater). The
  compaction marker row at the boundary lands in `history`
  (the `<=` rule).

  Bumps `state.chat_state.next_message_index` to one past the
  highest stamped index in the loaded list so the next
  `__append_message__/2` doesn't stamp a colliding index.

  When the persisted sequence has no system row (a legacy
  pre-system-prompt row), defensively prepends the in-memory
  system message at index 0 and shifts the boundary up by 1
  to keep the partition invariant (`history ++ messages ==
  full sequence in order`).
  """
  @spec seed_from_db(Nest.Agents.Agent.t(), [Nest.Messages.Message.t()], integer()) ::
          Nest.Agents.Agent.t()
  def seed_from_db(state, [], _last_compaction_index), do: state

  def seed_from_db(state, preloaded, last_compaction_index) do
    seed_with_system_if_needed(state, preloaded, last_compaction_index)
  end

  # When the in-memory system message is already at position 0
  # of the preloaded list, partition it as-is into history
  # and messages.
  defp seed_with_system_if_needed(state, preloaded, last_compaction_index) do
    has_system? = Enum.any?(preloaded, &match?({:system, _}, &1))

    if has_system? do
      do_seed(state, preloaded, last_compaction_index)
    else
      prepend_system(state, preloaded, last_compaction_index)
    end
  end

  defp do_seed(state, preloaded, last_compaction_index) do
    {history, messages} =
      Enum.split_with(preloaded, fn {_role, %{index: idx}} ->
        idx <= last_compaction_index
      end)

    highest_index =
      preloaded
      |> Enum.map(fn {_role, %{index: idx}} -> idx end)
      |> Enum.max(fn -> -1 end)

    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: messages,
            history: history,
            last_compaction_index: last_compaction_index,
            next_message_index: highest_index + 1
        }
    }
  end

  # Defensive prepend: pre-existing rows may have messages
  # but no persisted system row. Shift the preloaded list
  # up by one and seed the in-memory system message at
  # position 0 so the system prompt survives BEAM restart.
  defp prepend_system(state, preloaded, last_compaction_index) do
    [system | _] = state.chat_state.messages

    shifted =
      Enum.map(preloaded, fn {role, %{index: idx} = msg} ->
        {role, %{msg | index: idx + 1}}
      end)

    # After the prepend the system row sits at index 0, so
    # the partition needs to shift the boundary up by one as
    # well — the rows the caller persisted are now at their
    # original index + 1.
    do_seed(state, [system | shifted], last_compaction_index + 1)
  end

  @doc """
  Resolve the model's context limit by walking three layers,
  most-specific first.

  Used by `build_state/2` at init time, and by the compaction
  handler's `regenerate_for_compaction/2` to re-resolve after
  a Models-cache refresh or dotconfig reload.

  ## Layers

    1. Per-model static `context-limit` (in `[[providers.<name>.models]]`)
    2. Auto-discovery cache (`Nest.Models.context_limit/2`)
    3. Provider-wide `default-context-limit` on `[providers.<name>]`

  When none has a value, returns `{nil, nil}` and the system
  prompt's context-limit section is omitted entirely.

  The resolutions are captured as 0-arity closures so each
  lookup only runs when the previous tier missed — calling
  `Nest.Models.context_limit/2` once costs a `GenServer.call`,
  and `DotConfig.load/0` reads + parses TOML.
  """
  @spec initial_context_limit(map()) :: {non_neg_integer() | nil, atom() | nil}
  def initial_context_limit(model) do
    provider = model[:provider] || model["provider"]
    model_name = model_name(model)

    context_limit_layer(
      fn -> Config.configured_context_limit(model_name) end,
      fn -> Nest.Models.context_limit(provider, model_name) end,
      fn -> Config.configured_provider_default_context_limit(provider) end
    )
  end

  defp context_limit_layer(configured, cache, provider_default) do
    case configured.() do
      limit when is_integer(limit) ->
        {limit, :config}

      _ ->
        resolve_cache_or_default(cache, provider_default)
    end
  end

  defp resolve_cache_or_default(cache, provider_default) do
    case cache.() do
      {source, limit} when is_integer(limit) ->
        {limit, source}

      _ ->
        case provider_default.() do
          limit when is_integer(limit) -> {limit, :provider_default}
          _ -> {nil, nil}
        end
    end
  end

  defp model_name(model), do: model[:name] || model["name"]

  defp initial_messages_with_system(system_prompt) do
    message =
      {:system,
       %System{
         index: 0,
         parts: [%Part.Text{text: system_prompt || ""}],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    {[message], 1}
  end

  defp build_llm_metrics(context_limit, source) do
    %Nest.Agents.Agent.LlmMetrics{
      context_limit: context_limit,
      context_limit_source: source,
      usage_totals: Broadcasts.empty_usage_totals(),
      # `descendant_usage` is initialized to a fresh totals map
      # (not `nil`) so the merge helpers don't need a nil
      # branch. Children merge into this field on completion;
      # the agent's `total_usage` is computed as
      # `usage_totals + descendant_usage`.
      descendant_usage: Broadcasts.empty_usage_totals()
    }
  end

  defp build_chat_state(messages, next_index) do
    %Nest.Agents.Agent.ChatState{
      messages: messages,
      next_message_index: next_index
    }
  end

  # Per-process state always resets to defaults on init/1. The
  # only non-default seed is the API-log id sequences, which the
  # restore path precomputes from the loaded message history.
  defp build_live_state(api_log_sequences, mode) do
    %Nest.Agents.Agent.ChatState.Live{
      api_log_sequences: api_log_sequences,
      mode: mode
    }
  end

  defp create_tmp_space(agent_name) do
    Nest.Agents.Agent.__create_tmp_space__(agent_name)
  end
end
