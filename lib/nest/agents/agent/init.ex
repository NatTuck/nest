defmodule Nest.Agents.Agent.Init do
  @moduledoc """
  Initial state construction for the agent GenServer.
  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays small.

  The `init/1` callback delegates to `build_state/2` here for
  the struct construction (no side effects) and to
  `run_post_init/2` for the side-effectful post-init work
  (system-message broadcast, async context-limit probe,
  startup log).
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.System
  alias Nest.Tools

  @default_context_limit 128_000

  @doc """
  Build the initial state struct. Pure: no broadcasts, no
  probes, no logging. Caller must call `run_post_init/2`
  after this to perform the side effects.
  """
  @spec build_state(map(), Nest.LLM.ClientConfig.t()) :: Nest.Agents.Agent.t()
  def build_state(attrs, client_config) do
    id = Map.fetch!(attrs, :id)
    model = Map.fetch!(attrs, :model)
    vocation_id = Map.get(attrs, :vocation_id)
    workspace_path = Map.get(attrs, :workspace_path)

    # Resolve the context limit before building the system prompt
    # so the prompt can include the limit as a static piece of
    # context. The async probe (spawned in `run_post_init/2`) may
    # later overwrite the default; the system prompt's
    # `:default` wording acknowledges that.
    {context_limit, context_limit_source} = initial_context_limit(model)

    # Fetch vocation if provided; the Vocation struct is stored in
    # state so subsequent mode/caps resolution is a pure read of
    # the cached struct (no DB lookups on the per-message path).
    {system_prompt, mode, tool_names, vocation} =
      SystemPrompt.fetch_vocation_config(
        vocation_id,
        workspace_path,
        {context_limit, context_limit_source}
      )

    tmp_path = create_tmp_space(id)
    tools = Tools.get_functions(tool_names, workspace_path, tmp_path)

    {initial_messages, next_index} = initial_messages_with_system(system_prompt)

    %Nest.Agents.Agent{
      id: id,
      model: model,
      client_config: client_config,
      vocation: vocation,
      vocation_id: vocation_id,
      workspace_path: workspace_path,
      tmp_path: tmp_path,
      tools: tools,
      llm_metrics: build_llm_metrics(context_limit, context_limit_source),
      mode: mode,
      chat_state: build_chat_state(initial_messages, next_index)
    }
  end

  @doc """
  Run the post-construction side effects: broadcast the
  initial system message (if it has non-empty content), spawn
  the async context-limit probe (when the source was the
  default), and log the agent's startup info.
  """
  @spec run_post_init(Nest.Agents.Agent.t(), Nest.LLM.ClientConfig.t()) :: :ok
  def run_post_init(state, client_config) do
    # The system message is always at position 0 of
    # `state.chat_state.messages` (see
    # `initial_messages_with_system/1`). We always broadcast
    # it — even when empty — because the system message
    # exists in the LLM's view and the AGENTS.md
    # transparency rule says the UI must include everything
    # that happened. The UI decides how to render an empty
    # system message (a dimmed placeholder); we don't hide
    # it here.
    case state.chat_state.messages do
      [{:system, %System{}} | _] = messages ->
        Broadcasts.message(state.id, hd(messages))

      _ ->
        :ok
    end

    if state.llm_metrics.context_limit_source == :default do
      spawn_context_limit_probe(client_config, self())
    end

    Logger.info(
      "Agent started: #{state.id} with vocation_id: #{inspect(state.vocation_id)}, mode: #{state.mode}, tools: #{length(state.tools)}, client: #{inspect(client_config.client)}, context_limit: #{inspect(state.llm_metrics.context_limit)} (#{state.llm_metrics.context_limit_source})"
    )

    :ok
  end

  # Resolve the configured context limit from DotConfig; if absent,
  # default to 128k and let the async probe (spawned in `post_init/2`)
  # refine the value once the provider's /models endpoint has been
  # queried. The synchronous Discover call would block init/1 for up
  # to 3s on slow providers, so we keep the initial value cheap and
  # update it via handle_info.
  defp initial_context_limit(model) do
    case Nest.Agents.Agent.configured_context_limit(model_name(model)) do
      nil -> {@default_context_limit, :default}
      limit -> {limit, :config}
    end
  end

  defp model_name(model), do: model[:name] || model["name"]

  defp initial_messages_with_system(system_prompt) do
    # Always return a system message at position 0, even when
    # the composed system prompt is nil/empty. The LLM-bound
    # messages array always starts with a `{:system, _}` so
    # the Anthropic client can special-case position 0 for the
    # top-level `"system"` field without conditional logic in
    # the wire conversion. Empty content is fine — Anthropic
    # accepts it, and OpenAI's `role: "system"` with empty
    # content is a no-op.
    message =
      {:system,
       %System{
         index: 0,
         content: system_prompt || "",
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    {[message], 1}
  end

  defp build_llm_metrics(context_limit, source) do
    %Nest.Agents.Agent.LlmMetrics{
      context_limit: context_limit,
      context_limit_source: source,
      usage_totals: Broadcasts.empty_usage_totals()
    }
  end

  defp build_chat_state(messages, next_index) do
    %Nest.Agents.Agent.ChatState{
      messages: messages,
      next_message_index: next_index,
      streaming_acc: nil,
      status: :idle,
      active_message_index: 0
    }
  end

  # Forwarded to the GenServer module which owns the canonical
  # implementations. The `__` prefix marks them as internal.
  defp create_tmp_space(agent_id) do
    Nest.Agents.Agent.__create_tmp_space__(agent_id)
  end

  defp spawn_context_limit_probe(client_config, agent_pid) do
    Nest.Agents.Agent.__spawn_context_limit_probe__(client_config, agent_pid)
  end
end
