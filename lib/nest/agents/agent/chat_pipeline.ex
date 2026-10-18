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
  alias Nest.Modes
  alias Nest.Sandbox.Mounts
  alias Nest.Tokens.PreFlight
  alias Nest.Tokens.Reserve

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

    # The mode is applied *before* the settle, because the user message is built
    # with it (the `[mode: X]` prefix and the UI badge) and the turn runs under
    # it. That is also why the write has to happen here: the settle's own `run/6`
    # reads `pre_mode` from the already-applied state, so it cannot see the
    # change. A mode this message kept is the agent's mode from here on — the row
    # is what a restart and a later spawn read — so it is written down, and
    # nothing is announced: the message's own prefix is what states it.
    pre_mode = state.live.mode
    state = %{state | live: %{state.live | mode: effective_mode, cancelled: false}}
    user = build_user_message(content, effective_mode, human?)

    {:ok, state} = Turn.settle(state, {:chat_request, {:user_message, user}})
    {:noreply, Turn.keep_mode(state, pre_mode)}
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

  The modes are universal (`Nest.Modes`), so a name this build implements is used
  as-is and anything else — the old `"chat"`, a stale row, a client that made one
  up — falls back to `Nest.Modes.default/0`. This matches the LLM-visible
  `[mode: X]` prefix, and it is the one funnel every caller shares: the idle-turn
  request, the mode a delivered batch carries, and the bookkeeping reads that
  need the caps the tools run under.

  The vocation argument is kept because every caller already has one to hand and
  the modes no longer depend on it: they are universal constants (`Nest.Modes`),
  and the column that used to hold them is gone.
  """
  @spec resolve_mode_and_caps(String.t() | nil, term(), Mounts.t()) :: {String.t(), map()}
  def resolve_mode_and_caps(mode, _vocation_or_nil, mounts) do
    resolved = if Modes.valid?(mode), do: mode, else: Modes.default()

    {resolved, Nest.ProjectConfig.resolve_caps(Modes.caps(resolved), mounts)}
  end
end
