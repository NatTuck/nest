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
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.PreFlight
  alias Nest.Tokens.Reserve
  alias Nest.Vocations

  @doc """
  Handle an incoming chat turn. Returns the GenServer reply tuple.

  `human?` says whether `content` is the human's own words; only then is the
  built message tagged `origin: "human"` for the Ctrl/Cmd+Up recall list.
  """
  @spec handle_chat(Nest.Agents.Agent.t(), String.t(), String.t() | nil, boolean()) ::
          {:noreply, Nest.Agents.Agent.t()}
  def handle_chat(state, content, requested_mode, human? \\ false) do
    mode = requested_mode || state.live.mode

    {effective_mode, _caps} =
      resolve_mode_and_caps(mode, state.vocation, Mounts.from_agent(state))

    state = %{state | live: %{state.live | mode: effective_mode, cancelled: false}}
    user = build_user_message(content, effective_mode, human?)

    {:ok, state} = Turn.settle(state, {:chat_request, {:user_message, user}})
    {:noreply, state}
  end

  # Build the persisted user message. The mode is encoded both on
  # `metadata.mode` (UI badge) and as a `[mode: <name>]\n` prefix on the
  # text part (source of truth for the LLM). `index: nil` — the appender
  # stamps the actual index.
  #
  # `origin: "human"` is added only when `human?` — it marks the message as
  # the human's own words, which is what the Ctrl/Cmd+Up recall list keys off
  # (see `Nest.Messages.User.human_metadata/0`). A kickoff nobody typed
  # (`agents-spawn`'s `query`) is left untagged, so it never reaches that list.
  defp build_user_message(content, mode, human?) do
    %User{
      index: nil,
      timestamp: DateTime.utc_now(),
      parts: [%Part.Text{text: "[mode: #{mode}]\n#{content}"}],
      metadata: maybe_put_human(%{"mode" => mode}, human?),
      api_logs: []
    }
  end

  defp maybe_put_human(metadata, true), do: Map.merge(metadata, User.human_metadata())
  defp maybe_put_human(metadata, _human?), do: metadata

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
  @spec resolve_mode_and_caps(String.t(), term(), Mounts.t()) :: {String.t(), map()}
  def resolve_mode_and_caps(mode, %Nest.Vocations.Vocation{} = vocation, mounts) do
    modes = Vocations.list_modes(vocation)

    {resolved, caps} =
      if mode in modes do
        {mode, elem(Vocations.get_caps(vocation, mode), 1)}
      else
        default = Vocations.default_mode(vocation)
        {default, elem(Vocations.get_caps(vocation, default), 1)}
      end

    {resolved, Nest.ProjectConfig.apply_or_default(caps, mounts)}
  end

  def resolve_mode_and_caps(_mode, _no_vocation_or_id, mounts) do
    {"chat", Nest.ProjectConfig.apply_or_default(Nest.Sandbox.default_caps(), mounts)}
  end
end
