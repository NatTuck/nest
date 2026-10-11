defmodule Nest.Agents.Agent.NoticePairInjector do
  @moduledoc """
  Wire-safe synthetic notice pair construction.

  The Agent's messages list must alternate `user → assistant →
  user → assistant` to satisfy every LLM provider's wire
  format. The user-message path (`Machine.Transitions`) and the
  LLM-response path (`Machine.Response`) both need to wedge a
  synthetic pair into the stream — a synthetic
  `assistant(attention)` and/or `user(notice)` so the LLM sees a
  structured signal before it commits to its next response.

  `build_pair/3` is pure: it returns the wire-safe messages to
  insert (or `:deferred` when a trailing unpaired `tool_use` makes
  injection unsafe), and the caller emits them as `{:append_many, _}`
  actions for the turn executor. The two injection shapes:

      :agent_user    → [assistant(attention), user(notice)]
      :user_agent    → [assistant(notice+ack)]  (trailing user/tool)
                     | [user(notice), assistant(ack)]  (trailing assistant)

  `:agent_user` is used at LLM-response construction time (the
  response's trailing role is `:user` or `:tool` from the tool
  result that triggered the call). After this injection the trailing
  role is `:user`, and nothing in the chat turn would drive a next
  iteration — so the caller MUST iterate after a successful
  `:agent_user` injection.

  `:deferred` is returned when a trailing assistant carries an
  unpaired `Part.ToolUse{}` — putting a notice pair between the
  `tool_use` and its upcoming `tool_result` breaks Anthropic's
  tool-use/tool-result pairing invariant. The caller retries on the
  next safe boundary (the next LLM-response construction site).

  `notice_record/3` is the same `:user_agent` shape for a notice that
  has **no** next safe boundary — the Stop cancellation record (issue
  #36, step 4) — so it resolves the `:deferred` tail instead of
  deferring.
  """

  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part

  @type spec :: %{
          required(:kind) => atom(),
          optional(:attention) => String.t(),
          required(:notice) => String.t(),
          optional(:threshold) => atom(),
          optional(:ack) => String.t()
        }

  @doc """
  Purely build the wire-safe notice pair for `messages` in the given
  direction. Returns `{:ok, messages}` or `:deferred` when a trailing
  unpaired `tool_use` makes injection unsafe.
  """
  @spec build_pair([term()], spec(), :agent_user | :user_agent) ::
          {:ok, [term()]} | :deferred
  def build_pair(messages, spec, :agent_user) do
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
         ContextReminder.build_user_notice(
           spec.notice,
           nil,
           ContextReminder.context_metadata(spec)
         )
       ]}
    end
  end

  def build_pair(messages, spec, :user_agent) do
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

        {:ok,
         [
           build_single_assistant(
             notice_text <> " " <> ack_text,
             ContextReminder.context_metadata(spec)
           )
         ]}

      # Trailing source `:assistant` (no trailing tool_use). The
      # full `[user(notice), assistant(ack)]` pair lands before
      # the new user message so the wire sequence is
      # `assistant → user(notice) → assistant(ack) → user(real)` —
      # strict alternation preserved.
      true ->
        ack_text = Map.get(spec, :ack, ack_for_kind(spec.kind))

        {:ok,
         [
           ContextReminder.build_user_notice(
             spec.notice,
             nil,
             ContextReminder.context_metadata(spec)
           ),
           build_single_assistant(ack_text)
         ]}
    end
  end

  @doc """
  The messages that land `notice` and `ack` now, whatever the transcript tail is.

  This is `build_pair/3`'s `:user_agent` shape for a notice with no next safe
  boundary — the Stop cancellation record (issue #36, step 4), whose promise to
  the model has to be answered in the same breath. Where `build_pair/3` answers
  `:deferred` (a tail carrying an unpaired `tool_use`), this collapses to the
  single assistant message: the appender's terminal bridge then answers the
  unpaired ids with the canonical interrupted result *before* it lands, and
  fabricates no acknowledgement of its own (its incoming message is an
  assistant). So the record closes with exactly one.

  Pure, and total on an empty message list (the shape a hand-built fixture has).
  """
  @spec notice_record([term()], String.t(), String.t()) :: [term()]
  def notice_record(messages, notice, ack) do
    spec = %{kind: :stop_cancellation, notice: notice, ack: ack}

    case build_pair(messages, spec, :user_agent) do
      {:ok, pair} -> pair
      :deferred -> [build_single_assistant(notice <> " " <> ack)]
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

  defp trailing_has_tool_use?(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        Enum.any?(parts || [], &match?(%Part.ToolUse{}, &1))

      _ ->
        false
    end
  end

  defp build_attention_assistant(text, metadata \\ nil) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: text}],
       metadata: metadata,
       api_logs: []
     }}
  end

  defp build_single_assistant(text, metadata \\ nil) do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: text}],
       metadata: metadata,
       api_logs: []
     }}
  end

  # Default ack text by spec kind. Mirrors the ack texts the
  # original call sites used (context_reminder.ex and
  # budget_reminder.ex) so the unified injector produces the
  # same wire output as the old per-site builders.
  defp ack_for_kind(:context), do: "Okay, noted."
  defp ack_for_kind(:budget), do: "Okay, noted."
  defp ack_for_kind(_), do: "Okay, noted."
end
