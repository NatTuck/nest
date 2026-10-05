defmodule Nest.Persistence.AgentCompaction do
  @moduledoc """
  Offline compaction of a persisted agent's message history
  (`mix nest.compact_agent`).

  Loads a single agent (by space + name), plans an offline
  compaction, optionally summarizes and writes it, and formats a
  report. This is a standalone recovery path: it shares no code with
  the live compaction pipeline (`Machine.Compaction` / `Turn.Executor` /
  `Nest.Tokens.Compactor` / `MessageAppender`), so it still works when
  the live mechanism can't run — notably when the active history
  already exceeds the model's context window.

  The summary is produced by `AgentCompaction.Summarizer` (bounded,
  iterative fold). Dry runs make no LLM calls.
  """

  alias Nest.Agents.Agent.Config, as: AgentConfig
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.PersistedAgent
  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.LLM.Preflight
  alias Nest.Persistence
  alias Nest.Persistence.AgentCompaction.Planner
  alias Nest.Persistence.AgentCompaction.Summarizer
  alias Nest.Persistence.AgentCompaction.Writer
  alias Nest.Spaces
  alias Nest.Vocations

  @default_max_calls 64

  @type target :: {String.t(), String.t()}

  @doc """
  Run the offline compaction for `{space_name, agent_name}`.

  Returns `{:ok, plan, summary}` for an applied run (`summary` is the
  text written) or `{:ok, plan, nil}` for a dry run. `{:error, reason}`
  otherwise.
  """
  @spec run(target(), keyword()) ::
          {:ok, Planner.t(), String.t() | nil} | {:error, term()}
  def run({space_name, agent_name}, opts \\ []) do
    with {:ok, space_id, agent} <- load(space_name, agent_name),
         {:ok, context} <- build_context(agent, opts),
         {:ok, plan} <- plan_compaction(agent, space_id, context),
         :ok <- check_sequence(plan, opts) do
      finish(plan, context, opts)
    end
  end

  defp load(space_name, agent_name) do
    with {:ok, space_id} <- resolve_space(space_name),
         {:ok, agent} <- resolve_agent(space_id, agent_name) do
      {:ok, space_id, agent}
    end
  end

  defp plan_compaction(agent, space_id, context) do
    Planner.plan(agent, load_full(space_id, agent.name), context)
  end

  defp finish(plan, context, opts) do
    if Keyword.get(opts, :apply, false),
      do: apply_plan(plan, context, opts),
      else: {:ok, plan, nil}
  end

  @doc """
  Human-readable report for a dry or applied run.
  """
  @spec format_report(Planner.t(), boolean()) :: String.t()
  def format_report(%Planner{} = plan, applied?) do
    [
      "#{if applied?, do: "Applied", else: "Dry run"}: #{plan.agent_name} " <>
        "(space=#{plan.space_id}, id=#{plan.agent_id})",
      "  marker at #{plan.marker_index}",
      "  active messages: #{plan.archived_count} (orphans to delete: #{plan.orphan_count})",
      "  chunks: #{length(plan.chunks)} summarization call(s), " <>
        "#{plan.chunk_budget} input tokens/call",
      "  summary budget: #{plan.summary_budget} tokens",
      "  contexts: agent=#{plan.agent_context_limit}, " <>
        "summarizer=#{plan.summarizer_context_limit}",
      plan.truncated? && "  note: oversized message(s) truncated for summarization",
      "  new active: system@#{plan.marker_index + 1}, summary@#{plan.marker_index + 2}",
      if(applied?,
        do: "  restart the agent: its in-memory state is now stale",
        else: "  dry run: no LLM calls made; pass --apply to compact"
      )
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  # --- loading ---

  defp resolve_space(name) do
    case Spaces.get_by_name(name) do
      nil -> {:error, {:space_not_found, name}}
      %{id: id} -> {:ok, id}
    end
  end

  defp resolve_agent(space_id, name) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{} = agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, {:agent_not_found, name}}
    end
  end

  defp load_full(space_id, name), do: Persistence.load_full_messages(space_id, name)

  defp build_context(%PersistedAgent{} = agent, opts) do
    vocation = Vocations.get_vocation(agent.vocation_id)
    {agent_limit, agent_source} = Init.initial_context_limit(agent.model)
    summarizer_model = summarizer_model(agent, opts)

    case Init.initial_context_limit(summarizer_model) do
      {summarizer_limit, _source} ->
        {:ok,
         %{
           agent_context_limit: agent_limit,
           agent_context_limit_source: agent_source,
           summarizer_context_limit: summarizer_limit,
           summarizer_model: summarizer_model,
           system_prompt: render_system(agent, vocation, agent_limit, agent_source),
           fallback_system_prompt: (vocation && vocation.system_prompt) || "",
           focus: opts[:focus],
           max_calls: opts[:max_calls] || @default_max_calls
         }}
    end
  end

  defp render_system(_agent, nil, _limit, _source), do: nil

  defp render_system(agent, vocation, limit, source) do
    {system_prompt, _mode, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(
        vocation,
        agent.workspace_path,
        {limit, source},
        agent.name,
        agent.depth || 0
      )

    system_prompt
  end

  defp summarizer_model(agent, opts) do
    case normalize_model(opts[:model]) do
      nil -> agent.model
      model -> Map.put_new(model, "provider", provider_of(agent.model))
    end
  end

  defp provider_of(model), do: model[:provider] || model["provider"]

  defp normalize_model(nil), do: nil

  defp normalize_model(%{} = model) do
    Map.new(model, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {Atom.to_string(k), v}
    end)
  end

  defp normalize_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, name] when provider != "" and name != "" ->
        %{"provider" => provider, "name" => name}

      _ ->
        %{"name" => model}
    end
  end

  # --- guards ---

  defp check_sequence(%Planner{slice: slice}, opts) do
    case Preflight.validate(slice) do
      :ok ->
        :ok

      {:error, violations} ->
        if Keyword.get(opts, :force, false) do
          :ok
        else
          {:error, {:sequence_violations, Preflight.format_violations(violations)}}
        end
    end
  end

  # --- apply ---

  defp apply_plan(%Planner{} = plan, context, opts) do
    with {:ok, llm_call} <- resolve_llm_call(context, opts),
         {:ok, summary} <- Summarizer.summarize(plan, llm_call),
         :ok <- Writer.apply(plan, summary) do
      {:ok, plan, summary}
    end
  end

  defp resolve_llm_call(context, opts) do
    case Keyword.get(opts, :llm_call) do
      fun when is_function(fun, 1) ->
        {:ok, fun}

      _ ->
        with {:ok, client_config} <- build_client(context.summarizer_model) do
          {:ok, Summarizer.llm_call(client_config)}
        end
    end
  end

  defp build_client(model) do
    provider_name = provider_of(model)
    model_name = model[:name] || model["name"]

    with {:ok, dotconfig} <- DotConfig.load(),
         %DotConfig.Provider{} = provider <-
           DotConfig.get_provider(dotconfig, provider_name),
         {:ok, client_config} <- ChatModel.build_client_config(provider, model_name) do
      {:ok, %{client_config | thinking_effort: AgentConfig.resolve_thinking_effort(model)}}
    else
      nil -> {:error, {:provider_not_in_dotconfig, provider_name}}
      {:error, reason} -> {:error, reason}
    end
  end
end
