defmodule Nest.Agents.Agent.NoticePairInjector do
  @moduledoc """
  Wire-safe synthetic notice pair injection.

  The Agent's messages list must alternate `user → assistant →
  user → assistant` to satisfy every LLM provider's wire
  format. Two callers (the LLM-response path, the
  user-message path) need to wedge a synthetic pair into the
  stream — a single synthetic `assistant(attention)` and
  `user(notice)` so the LLM sees a structured signal before
  it commits to its next response.

  Both callers face the same problem: where exactly do I
  drop the pair without breaking alternation? That depends
  on the *current* trailing role, which neither caller wants
  to compute by hand. This module centralizes the decision.

  The two injection shapes (each satisfies alternation from a
  different starting role):

      :agent_user_pair    → [assistant(attention), user(notice)]
      :user_agent_pair    → [user(notice), assistant(ack)]
      :single_assistant   → [assistant(notice+ack)]

  `:agent_user_pair` is used at LLM-response construction time
  (the response's trailing role is `:user` or `:tool` from the
  tool result that triggered the call). After this injection
  the trailing role is `:user`, and nothing in the chat turn
  would drive a next iteration — so the caller MUST send
  `:iterate` after a successful `:agent_user_pair`
  injection.

  `:user_agent_pair` and `:single_assistant` are used at
  user-message construction time (the new user message
  follows the injection and itself drives the next chat turn
  via `ChatPipeline.handle_chat/3`). No iterate is needed
  after these shapes.

  `:deferred` is returned when a trailing assistant carries
  an unpaired `Part.ToolUse{}` — putting a notice pair
  between the `tool_use` and its upcoming `tool_result`
  breaks Anthropic's tool-use/tool-result pairing invariant.
  The caller is expected to retry on the next safe boundary
  (typically the next LLM-response construction site).

  ## Atomicity

  The pair is appended via `{:append_messages, _}`, a single
  GenServer.call. A partial failure (agent dead, mailbox
  timeout) leaves the messages list either fully updated or
  fully untouched — never half-updated with an assistant
  message followed by no user message. This closes the
  regression where the second of two sequential appends
  timed out and the LLM was given a wire-format-broken
  messages list.
  """

  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part

  @type shape :: :agent_user_pair | :user_agent_pair | :single_assistant | :deferred
  @type spec :: %{
          required(:kind) => atom(),
          required(:attention) => String.t(),
          required(:notice) => String.t()
        }

  @doc """
  Inject a synthetic notice pair into the Agent's messages
  list. Returns `{:ok, shape, stamped_messages}` on success,
  `:deferred` if a trailing tool_use makes injection unsafe,
  or `:agent_dead` if the Agent GenServer is unreachable.

  Direction is `:agent_user` for the LLM-response path (use
  after an LLM call that crossed a threshold; the next LLM
  call needs to be triggered by `:iterate`) or `:user_agent`
  for the user-message path (use before a new user message;
  no iterate needed because the user message drives the
  next chat turn on its own).

  Returns `{:ok, :user_agent_pair, _}` or `{:ok,
  :agent_user_pair, _}` based on direction — never `:single_assistant`
  from this entry point (the single-message variant is only
  produced by `inject_pair_in_process/4` for `:user_agent`
  + trailing `:user` role).
  """
  @spec inject_pair(GenServer.server(), spec(), :agent_user | :user_agent) ::
          {:ok, shape(), [term()]} | shape() | :agent_dead
  def inject_pair(agent_pid, spec, direction) do
    with {:ok, messages} <- fetch_messages(agent_pid),
         {:ok, pair_messages} <- build_pair(messages, spec, direction) do
      append_pair(agent_pid, pair_messages, direction)
    end
  end

  # In-process variant for callers that already run inside the
  # Agent process (the user-message pipeline). Same wire-safety
  # rules as `inject_pair/3`, but skips the GenServer.call —
  # the pair is appended via `__append_messages__/2` directly.
  #
  # `messages` is the Agent's current messages list (caller
  # passes `state.chat_state.messages` directly to avoid the
  # self-call). Returns `{:ok, shape, stamped_messages,
  # new_state}` on success, or `:deferred` on a trailing
  # tool_use.
  @spec inject_pair_in_process([term()], map(), spec(), :agent_user | :user_agent) ::
          {:ok, shape(), [term()], map()} | shape()
  def inject_pair_in_process(messages, state, spec, direction) do
    with {:ok, pair_messages} <- build_pair(messages, spec, direction) do
      {stamped, new_state} = Nest.Agents.Agent.__append_messages__(state, pair_messages)

      shape =
        case {length(stamped), direction} do
          {1, _} -> :single_assistant
          {_, :agent_user} -> :agent_user_pair
          {_, :user_agent} -> :user_agent_pair
        end

      {:ok, shape, stamped, new_state}
    end
  end

  defp build_pair(messages, spec, :agent_user) do
    last_role = MessageList.last_wire_role(messages)

    if last_role == :assistant and trailing_has_tool_use?(messages) do
      # Trailing assistant carries an unpaired tool_use (in-flight
      # tool call). Defer so the synthetic pair doesn't land between
      # the tool_use and its upcoming tool_result.
      :deferred
    else
      # Trailing role is assistant without trailing tool_use, or
      # trailing role is `:user` / `:tool`. Either way we can
      # insert the `[assistant(attention), user(notice)]` pair —
      # wire alternation is preserved.
      {:ok,
       [
         build_attention_assistant(spec.attention),
         ContextReminder.build_user_notice(spec.notice, nil)
       ]}
    end
  end

  defp build_pair(messages, spec, :user_agent) do
    last_source_role = last_source_role(messages)

    cond do
      # Trailing assistant carrying an unpaired tool_use (the LLM
      # is mid-tool-call). Defer so the synthetic pair doesn't
      # land between the tool_use and its upcoming tool_result.
      last_source_role == :assistant and trailing_has_tool_use?(messages) ->
        :deferred

      # Trailing source `:user` OR `:tool` — both wire-equivalent to
      # `:user` (Anthropic sends tool results as user-role messages
      # per `MessageList.last_wire_role/1`). The new user message
      # follows naturally. A single `[assistant(notice+ack)]` is
      # enough to signal the LLM; the new user message completes
      # the alternation `user → assistant → user`.
      last_source_role in [:user, :tool] ->
        notice_text = spec.notice
        ack_text = Map.get(spec, :ack, ack_for_kind(spec.kind))
        {:ok, [build_single_assistant(notice_text <> " " <> ack_text)]}

      # Trailing source `:assistant` (no trailing tool_use). The
      # full `[user(notice), assistant(ack)]` pair lands before
      # the new user message so the wire sequence is
      # `assistant → user(notice) → assistant(ack) → user(real)` —
      # strict alternation preserved.
      true ->
        ack_text = Map.get(spec, :ack, ack_for_kind(spec.kind))

        {:ok,
         [
           ContextReminder.build_user_notice(spec.notice, nil),
           build_single_assistant(ack_text)
         ]}
    end
  end

  defp last_source_role(messages) do
    case List.last(messages) do
      {:user, _} -> :user
      {:tool, _} -> :tool
      {:assistant, _} -> :assistant
      _ -> nil
    end
  end

  defp append_pair(agent_pid, pair_messages, direction) do
    case GenServer.call(agent_pid, {:append_messages, pair_messages}, 5_000) do
      [_ | _] = stamped ->
        shape =
          case {length(stamped), direction} do
            {1, _} -> :single_assistant
            {_, :agent_user} -> :agent_user_pair
            {_, :user_agent} -> :user_agent_pair
          end

        {:ok, shape, stamped}

      _ ->
        :agent_dead
    end
  catch
    :exit, _ -> :agent_dead
  end

  defp fetch_messages(agent_pid) do
    case GenServer.call(agent_pid, :get_messages, 1_000) do
      messages when is_list(messages) -> {:ok, messages}
      _ -> :agent_dead
    end
  catch
    :exit, _ -> :agent_dead
  end

  defp trailing_has_tool_use?(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        Enum.any?(parts || [], &match?(%Part.ToolUse{}, &1))

      _ ->
        false
    end
  end

  defp build_attention_assistant(text) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: text}],
       api_logs: []
     }}
  end

  defp build_single_assistant(text) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: text}],
       api_logs: []
     }}
  end

  # Default ack text by spec kind. Mirrors the ack texts the
  # two original call sites used (context_reminder.ex and
  # budget_reminder.ex) so the unified injector produces the
  # same wire output as the old per-site builders.
  defp ack_for_kind(:context), do: "Okay, noted."
  defp ack_for_kind(:budget), do: "Okay, noted."
  defp ack_for_kind(_), do: "Okay, noted."
end
