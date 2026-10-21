defmodule Nest.Agents.Agent.Turn.ModeTest do
  @moduledoc """
  The mode a drain *keeps* is written to the row, and one it declines is not.

  `Turn.keep_mode/2` is called from every path that can apply a mode — `run/6`'s
  own commit, `Turn.drain_inbox/1`, and `ChatPipeline.handle_chat/4` — and
  `Turn.restore_undelivered_mode/3` runs first, so an undone change never reaches
  the row. `agents.mode` is the truth a restart and a `PreSpawn` inheritance read,
  so it has to hold exactly what the agent is working under.

  Split out of `Turn.ExecutorTest` (credo's source-file cap).
  """

  use Nest.DataCase, async: true

  import Nest.TestSupport.ExecutorTestHelpers

  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Tokens.ConversationSize

  test "a mode a drain declined is not written to the row" do
    messages = [system_msg(), user_msg(), assistant_msg(), user_msg()]
    base = state()

    content = "[From agent peer | mode: plan]\npeer note"
    projected = messages ++ [Dispatch.build_user_message(content, "act")]
    limit = ConversationSize.size(projected) + 8_191

    state = %{
      base
      | chat_state: %{base.chat_state | messages: messages},
        llm_metrics: %{base.llm_metrics | context_limit: limit}
    }

    assert Dispatch.preflight_decision(projected, limit) == :needs_compaction,
           "the fixture must force the :needs_compaction branch"

    # The row starts in a known mode, so "the declined drain left it alone" is an
    # assertion about this drain rather than about the column's default.
    :ok = Persistence.update_agent_mode(base.space_id, base.name, "act")

    peer = %{entry(:agent, "peer", "peer note") | mode: "plan"}
    state = inbox_state([peer], "act", state)

    # `:queued` *is* "nothing it peeked was consumed" (`drain_inbox/1` computes
    # it from the queue), so the entry is still queued; the machine shape that
    # decline leaves is `ExecutorTest`'s `:queued` test, on this same fixture.
    # This file is about the mode.
    {state, :queued} = Turn.drain_inbox(state)

    # The peek applied `plan` and the declined drain put it back, so the mode the
    # entry asked for must not be written down: the row still holds what the
    # agent is working under.
    assert state.live.mode == "act"
    assert {:ok, %{mode: "act"}} = Persistence.fetch_agent(state.space_id, state.name)
  end

  defp inbox_state(entries, mode, base) do
    %{base | live: %{base.live | inbox: entries, mode: mode}}
  end

  defp entry(kind, from, content, mode \\ nil) do
    %{
      id: Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: mode,
      source: false,
      fulfilled_ids: []
    }
  end

  defp system_msg do
    {:system, %System{index: 0, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user_msg do
    {:user,
     %User{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: "hi"}],
       api_logs: []
     }}
  end

  defp assistant_msg do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: "ok"}],
       api_logs: []
     }}
  end
end
