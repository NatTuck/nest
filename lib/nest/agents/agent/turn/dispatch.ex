defmodule Nest.Agents.Agent.Turn.Dispatch do
  @moduledoc """
  Pure request-staging math for a turn, shared by the machine's
  `step/2` transitions and the executor.

  `tool_config_for_iteration/1`, the max-token arithmetic, the request
  message list (persisted messages plus any staged compaction additions),
  and the compaction plan all derive purely from the machine's `work` /
  `entry`, so the decision about *what* to send never depends on a side
  effect. The executor only performs the spawn.
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.LLM.GenerationDefaults
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Compactor, as: TokensCompactor
  alias Nest.Tokens.PreFlight
  alias Nest.Tokens.Reserve

  @doc """
  The `{tools, tool_choice}` pair for the next request. At/over the cap
  this is the "final" call with `tools: nil, tool_choice: :none`; the
  compactor always sends `tools: nil, tool_choice: :none`.
  """
  @spec tool_config_for_iteration(Machine.t()) :: {list() | nil, :auto | :none}
  def tool_config_for_iteration(%Machine{entry: {:compaction, _, _}}), do: {nil, :none}

  def tool_config_for_iteration(%Machine{work: work}) do
    if work.iteration > work.max_iterations,
      do: {nil, :none},
      else: {work.ctx.tools, work.ctx.tool_choice}
  end

  @doc """
  The message list for the current LLM request. The compactor's request
  is the persisted active messages (minus a trailing unpaired tool call)
  followed by the staged additions; every other request is the messages
  list as-is.
  """
  @spec request_messages(Machine.t()) :: [term()]
  def request_messages(%Machine{entry: {:compaction, staged, _}, work: work}) do
    work.ctx.messages
    |> MessageList.drop_trailing_unpaired_tool_call()
    |> Kernel.++(staged)
  end

  def request_messages(%Machine{work: work}), do: work.ctx.messages

  @doc """
  Build the request context the HTTP worker runs with: the base turn
  context plus the request messages, the iteration's tool config, and the
  resolved `max_tokens`.
  """
  @spec spawn_ctx(Machine.t(), [term()]) :: map()
  def spawn_ctx(%Machine{entry: {:compaction, _, _}} = machine, messages) do
    put_spawn(machine, messages, compactor_max_tokens(machine, messages))
  end

  def spawn_ctx(%Machine{} = machine, messages) do
    put_spawn(machine, messages, ordinary_max_tokens(machine))
  end

  defp put_spawn(machine, messages, max_tokens) do
    {tools, tool_choice} = tool_config_for_iteration(machine)

    machine.work.ctx
    |> Map.put(:messages, messages)
    |> Map.put(:tools, tools)
    |> Map.put(:tool_choice, tool_choice)
    |> Map.put(:max_tokens, max_tokens)
  end

  @doc "The ordinary-turn output cap: `min(model_default, 0.20L)`, at least 1."
  @spec ordinary_max_tokens(Machine.t()) :: pos_integer()
  def ordinary_max_tokens(%Machine{work: work}) do
    max(1, min(sane_default(work.ctx), round(0.20 * work.ctx.context_limit)))
  end

  @doc "The compactor output cap: `min(L - size(input), model_default)`, at least 1."
  @spec compactor_max_tokens(Machine.t(), [term()]) :: pos_integer()
  def compactor_max_tokens(%Machine{work: work}, input) do
    max(1, min(work.ctx.context_limit - Budget.size(input), sane_default(work.ctx)))
  end

  @doc "The user-turn preflight decision for a projected message list."
  @spec preflight_decision([term()], pos_integer()) :: :fits | :needs_compaction | :cannot_compact
  def preflight_decision(messages, limit) do
    PreFlight.check_messages(messages, limit, Reserve.compaction_reserve(limit))
  end

  @doc """
  Build the persisted user message for `content` in `mode`. The mode is
  encoded both on `metadata.mode` and as a `[mode: <name>]\\n` prefix on
  the text part, so it round-trips through the store and the wire.
  """
  @spec build_user_message(String.t(), String.t()) :: {:user, User.t()}
  def build_user_message(content, mode) do
    {:user,
     %User{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: "[mode: #{mode}]\n#{content}"}],
       metadata: %{"mode" => mode},
       api_logs: []
     }}
  end

  @doc """
  Pure compaction plan: `{:ok, staged}` when the compactor can run, or
  `{:error, :system_oversized | :reserve_exhausted}`.

  `staged` is the request-only additions (assistant bridge when the wire
  tail is `:user`, then the `[mode: compact]` suffix). Nothing is
  persisted here. The caller sets the machine's entry from `staged` before
  building the spawn context with `spawn_ctx/2`.
  """
  @spec compaction_plan(Machine.t()) ::
          {:ok, [term()]} | {:error, :system_oversized | :reserve_exhausted}
  def compaction_plan(%Machine{work: work}) do
    messages = work.ctx.messages || []
    system_prompt = system_prompt(work.ctx, messages)

    cond do
      is_nil(system_prompt) ->
        {:error, :reserve_exhausted}

      not SystemPrompt.within_size_budget?(
        system_prompt,
        work.ctx.context_limit
      ) ->
        {:error, :system_oversized}

      true ->
        case TokensCompactor.compute_summary_budget(
               work.ctx.context_limit,
               system_prompt,
               messages,
               nil
             ) do
          {:ok, _n, suffix} -> {:ok, stage_request(messages, suffix)}
          {:error, :reserve_exhausted} -> {:error, :reserve_exhausted}
        end
    end
  end

  # Render the system prompt from the cached vocation (production), or
  # from the system message at position 0 (test fixtures without a
  # vocation).
  defp system_prompt(ctx, messages) do
    if ctx[:vocation] do
      {system_prompt, _mode, _tools, _vocation} =
        SystemPrompt.compose_vocation_config(
          ctx.vocation,
          ctx.workspace_path,
          {ctx.context_limit, ctx.context_limit_source},
          ctx.agent_name,
          ctx.depth
        )

      system_prompt
    else
      case Enum.find(messages, &match?({:system, _}, &1)) do
        nil ->
          nil

        {:system, %Nest.Messages.System{parts: parts}} ->
          Enum.map_join(parts, "", &text_or_empty/1)
      end
    end
  end

  defp text_or_empty(%Part.Text{text: text}), do: text || ""
  defp text_or_empty(_), do: ""

  defp stage_request(messages, suffix) do
    base = MessageList.drop_trailing_unpaired_tool_call(messages)

    if MessageList.last_wire_role(base) == :user do
      [synthetic_assistant_bridge(), suffix]
    else
      [suffix]
    end
  end

  # The request-only alternation bridge; persisted with the summary on a
  # successful commit.
  defp synthetic_assistant_bridge do
    {:assistant,
     %Nest.Messages.Assistant{
       parts: [%Part.Text{text: "Let me pause to summarize."}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end

  defp sane_default(ctx) do
    GenerationDefaults.default_max_tokens(ctx.client_config.model) || 32_000
  end
end
