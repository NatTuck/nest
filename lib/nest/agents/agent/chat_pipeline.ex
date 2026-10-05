defmodule Nest.Agents.Agent.ChatPipeline do
  @moduledoc """
  Chat-handling entry point for an agent.

  The pipeline resolves the effective mode + capabilities, builds the
  user message (persisted and LLM-facing, both carrying the same
  `[mode: <name>]\\n` prefix so the mode round-trips through any store),
  then hands the turn to the settle loop. Every transition/decision after
  that point lives in `Machine.step/2`; the pipeline only prepares the
  event.
  """

  alias Nest.Agents.Agent.Turn
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Tokens.PreFlight
  alias Nest.Tokens.Reserve
  alias Nest.Vocations

  @doc """
  Handle an incoming chat turn. Returns the GenServer reply tuple.
  """
  @spec handle_chat(Nest.Agents.Agent.t(), String.t(), String.t() | nil) ::
          {:noreply, Nest.Agents.Agent.t()}
  def handle_chat(state, content, requested_mode) do
    mode = requested_mode || state.live.mode

    {effective_mode, _caps} =
      resolve_mode_and_caps(mode, state.vocation, state.workspace_path, state.tmp_path)

    state = %{state | live: %{state.live | mode: effective_mode, cancelled: false}}
    user = build_user_message(content, effective_mode)

    {:ok, state} = Turn.settle(state, {:chat_request, {:user_message, user}})
    {:noreply, state}
  end

  @doc """
  The pending user message as a `{:user, User.t()}` tuple, or `nil`.
  """
  @spec pending_user_message_struct(Nest.Agents.Agent.t()) :: {:user, User.t()} | nil
  def pending_user_message_struct(state) do
    case state.live.machine.pending_user_message do
      {:user_message, %User{} = user} -> {:user, user}
      {:user, %User{} = user} -> {:user, user}
      _ -> nil
    end
  end

  # Build the persisted user message. The mode is encoded both on
  # `metadata.mode` (UI badge) and as a `[mode: <name>]\n` prefix on the
  # text part (source of truth for the LLM). `index: nil` — the appender
  # stamps the actual index.
  defp build_user_message(content, mode) do
    %User{
      index: nil,
      timestamp: DateTime.utc_now(),
      parts: [%Part.Text{text: "[mode: #{mode}]\n#{content}"}],
      metadata: %{"mode" => mode},
      api_logs: []
    }
  end

  @doc """
  The user-turn preflight decision, used by callers that need the same
  fit/compaction decision.
  """
  @spec preflight_decision([{atom(), map()}], Nest.Agents.Agent.t()) :: atom()
  def preflight_decision(messages_for_llm, %{llm_metrics: %{context_limit: limit}})
      when is_integer(limit) and limit > 0 do
    PreFlight.check_messages(messages_for_llm, limit, Reserve.compaction_reserve(limit))
  end

  @doc """
  Resolve the effective mode and capability map for a chat message.

  If `mode` is in the vocation's `modes` map, use it as-is; otherwise fall
  back to the vocation's default mode (or "chat" if the vocation has no
  modes). This matches the LLM-visible `[mode: X]` prefix.
  """
  @spec resolve_mode_and_caps(String.t(), term(), String.t() | nil, String.t() | nil) ::
          {String.t(), map()}
  def resolve_mode_and_caps(mode, %Nest.Vocations.Vocation{} = vocation, workspace, tmp_path) do
    modes = Vocations.list_modes(vocation)

    {resolved, caps} =
      if mode in modes do
        {mode, elem(Vocations.get_caps(vocation, mode), 1)}
      else
        default = Vocations.default_mode(vocation)
        {default, elem(Vocations.get_caps(vocation, default), 1)}
      end

    {resolved, Nest.ProjectConfig.apply_or_default(caps, workspace, tmp_path)}
  end

  def resolve_mode_and_caps(_mode, _no_vocation_or_id, workspace, tmp_path) do
    {"chat", chat_caps(workspace, tmp_path)}
  end

  defp chat_caps(workspace, tmp_path) do
    Nest.ProjectConfig.apply_or_default(Nest.Sandbox.default_caps(), workspace, tmp_path)
  end
end
