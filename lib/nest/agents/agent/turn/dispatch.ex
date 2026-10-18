defmodule Nest.Agents.Agent.Turn.Dispatch do
  require Logger

  @moduledoc """
  Pure request-staging math for a turn, shared by the machine's
  `step/2` transitions and the executor.

  `tool_config_for_iteration/1`, the max-token arithmetic, the request
  message list, and the compaction plan all derive purely from the
  machine's `work` / `entry`, so the decision about *what* to send never
  depends on a side effect. The executor only performs the spawn.

  There is no compaction-specific request assembly. The compaction request
  is a **committed message** — `Nest.Agents.Agent.Machine.Compaction`
  appends it through `MessageAppender` before the call — so the
  compactor's request is the ordinary `work.ctx.messages`, bridges
  included.
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.LLM.GenerationDefaults
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
  def tool_config_for_iteration(%Machine{entry: {:compaction, _}}), do: {nil, :none}

  def tool_config_for_iteration(%Machine{work: work}) do
    if work.iteration > work.max_iterations,
      do: {nil, :none},
      else: {work.ctx.tools, work.ctx.tool_choice}
  end

  @doc """
  The message list for the current LLM request: the persisted active
  messages, for **every** request including the compactor's.

  There is nothing to append here. The compaction request is a committed
  message by the time this runs, and the append path already dropped any
  trailing unpaired tool call (`MessageList.pairing_bridge/2` answers it
  before the request lands).
  """
  @spec request_messages(Machine.t()) :: [term()]
  def request_messages(%Machine{work: work}), do: work.ctx.messages

  @doc """
  Build the request context the HTTP worker runs with: the base turn
  context plus the request messages, the iteration's tool config, and the
  resolved `max_tokens`.
  """
  @spec spawn_ctx(Machine.t(), [term()]) :: map()
  def spawn_ctx(%Machine{entry: {:compaction, _}} = machine, messages) do
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

  @doc """
  The user-turn preflight decision for a projected message list.

  A machine with **no** known limit (a hand-built fixture, or a config that sets
  none) has nothing to measure against, so everything fits — the same reading
  `Response.reply_fits?/2` and the reply gate's fit guard use.

  A limit that is present but **not positive** is a misconfiguration, not
  "unlimited": `context_limit` is resolved from the dot config's
  `context-limit` (`Nest.DotConfig`) or a provider's `default_context_limit`
  (`Nest.Models`), and neither should ever be 0. Treating it as unlimited would
  hide the misconfiguration until the provider rejected the request, so the turn
  takes the visible overflow path instead: the agent blocks on
  `:context_overflow` and the operator gets the banner.
  """
  @spec preflight_decision([term()], integer() | nil) ::
          :fits | :needs_compaction | :cannot_compact
  def preflight_decision(_messages, nil), do: :fits

  def preflight_decision(_messages, limit) when is_integer(limit) and limit <= 0 do
    Logger.warning(
      "[preflight] context limit #{limit} is not usable (a misconfigured " <>
        "`context-limit` or provider default); blocking the turn on :context_overflow"
    )

    :cannot_compact
  end

  def preflight_decision(messages, limit) do
    PreFlight.check_messages(messages, limit, Reserve.compaction_reserve(limit))
  end

  @doc """
  Build the persisted user message for `content` in `mode`. The mode is
  encoded both on `metadata.mode` and as a `[mode: <name>]\\n` prefix on
  the text part, so it round-trips through the store and the wire.

  `extra_metadata` is merged over the mode: the drain's `fulfilled_ids` ride
  there (`Inbox.build_drained_message/3`), which is how a restored transcript
  tells a backgrounded promise that was kept from one that was lost.
  """
  @spec build_user_message(String.t(), String.t(), map()) :: {:user, User.t()}
  def build_user_message(content, mode, extra_metadata \\ %{}) do
    {:user,
     %User{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: "[mode: #{mode}]\n#{content}"}],
       metadata: Map.merge(%{"mode" => mode}, extra_metadata),
       api_logs: []
     }}
  end

  @doc """
  Pure compaction plan: `{:ok, request_message}` when the compactor can
  run, or `{:error, :system_oversized | :reserve_exhausted}`.

  `request_message` is the `[mode: compact]` request the caller **appends
  through `MessageAppender`** before dispatching the compactor. It is a
  committed message, not a request-only addition, so the compactor's
  request is the ordinary message list — there is no alternation bridge to
  build here. The appender's own `MessageList.pairing_bridge/2` inserts one
  if the tail needs it, and persists it, so nothing is sent that is not in
  the transcript.

  The budget is computed against the messages as they are **before** the
  append, deliberately: `compute_summary_budget/4` accounts for the
  request's own size explicitly, so appending it first would double-count
  it.
  """
  @spec compaction_plan(Machine.t()) ::
          {:ok, term()} | {:error, :system_oversized | :reserve_exhausted}
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
               work.focus
             ) do
          {:ok, _n, request_message} -> {:ok, request_message}
          {:error, :reserve_exhausted} -> {:error, :reserve_exhausted}
        end
    end
  end

  # Render the system prompt from the cached vocation (production), or
  # from the system message at position 0 (test fixtures without a
  # vocation).
  defp system_prompt(ctx, messages) do
    if ctx[:vocation] do
      {system_prompt, _tools, _vocation} =
        SystemPrompt.compose_vocation_config(
          ctx.vocation,
          ctx.mounts,
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

  defp sane_default(ctx) do
    GenerationDefaults.default_max_tokens(ctx.client_config.model) || 32_000
  end
end
