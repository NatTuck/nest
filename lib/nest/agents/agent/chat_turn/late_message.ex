defmodule Nest.Agents.Agent.ChatTurn.LateMessage do
  @moduledoc """
  Build a late-conversation reminder payload.

  Late reminders are the `{:system, _}` tuples the ChatTurn
  appends mid-turn (context-usage threshold, tool-call budget,
  the compactor's `[mode: compact]` suffix). By default they go
  out as `{:system, %System{…}}` so the wire shape matches the
  initial system prompt.

  When the provider's `rewrite-late-system-messages` config flag
  is on, they go out as `{:user, %User{parts: [%Part.Text{text:
  "[System notice: …]"}]}}` instead. The DB stores the rewritten
  shape and the chat UI / audit log reflect what was actually
  sent. This is for providers whose chat template enforces
  "system must be at the beginning" (Qwen3.5 on vLLM, etc.):
  mid-conversation `role: "system"` messages are rejected with a
  400 Bad Request, but `role: "user"` text is fine.

  Callers: `BudgetReminder.build/2`, `ContextReminder.build_message/4`,
  `Nest.Agents.Agent.Compaction.Trigger.start/2`.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User

  @prefix "[System notice: "
  @suffix "]"

  @doc """
  Wrap `text` as a wire-ready reminder tuple.

  Returns `{:user, %User{parts: [%Part.Text{text: "[System
  notice: " <> text <> "]"}]}}` when `client_config.rewrite_late_system_messages`
  is `true`, else `{:system, %System{parts: [%Part.Text{text: text}]}}`.

  `client_config` may be `nil` — that path returns the default
  System shape. Useful for tests and for callers that don't yet
  have a fully-built `ClientConfig`.
  """
  @spec build(ClientConfig.t() | nil, String.t()) ::
          {:system, System.t()} | {:user, User.t()}
  def build(%ClientConfig{rewrite_late_system_messages: true}, text)
      when is_binary(text) do
    {:user,
     %User{
       parts: [%Part.Text{text: @prefix <> text <> @suffix}],
       timestamp: DateTime.utc_now()
     }}
  end

  def build(_client_config, text) when is_binary(text) do
    {:system,
     %System{
       parts: [%Part.Text{text: text}],
       timestamp: DateTime.utc_now()
     }}
  end

  @doc """
  Re-wrap an already-built `{:system, _}` reminder tuple per the
  provider config.

  Returns the tuple unchanged when rewrite is off; otherwise
  extracts the text and re-wraps it as a `[System notice: …]`
  User message. Used by `Compaction.Trigger.start/2`, where
  `TokensCompactor.compute_summary_budget/4` renders the suffix
  as a System tuple (config-agnostic) and only the append
  boundary needs the shape swap.
  """
  @spec rewrap(ClientConfig.t() | nil, {:system, System.t()}) ::
          {:system, System.t()} | {:user, User.t()}
  def rewrap(
        %ClientConfig{rewrite_late_system_messages: true} = client_config,
        {:system, %System{parts: parts}}
      ) do
    text = Enum.map_join(parts || [], "", &part_text/1)
    build(client_config, text)
  end

  def rewrap(_client_config, {:system, _} = rendered), do: rendered

  defp part_text(%Part.Text{text: text}), do: text
  defp part_text(_), do: ""
end
