defmodule Nest.Agents.Agent.Repair do
  @moduledoc """
  The single repair-decision table for the Agent's message sequence.

  Every caller that must heal, drop, or fail on a sequence mismatch
  routes through `decide/3`. The decision is keyed by context:

    * `:live` — an append during a live turn. The turn owns the
      sequence, so a mismatch is generally not repaired: a tool result
      that does not answer the live tail is `:stale` (drop it), and a
      genuinely broken sequence (a non-result while a `tool_use` is
      unanswered, or two consecutive wire roles) is `{:invalid, reason}`
      (fail the turn cleanly). Repair must never race a live turn.

      There is exactly one exception: an incoming `user` message onto a
      wire-`user` tail is bridged (`MessageList.pairing_bridge/2`). A
      user message is only accepted at idle — the channel and
      `Callbacks.chat_or_drop/3` reject it mid-turn — so this append is
      necessarily the turn-opening append and cannot race a live turn.
      The `pending != []` clause still wins, so no synthetic
      `tool_result` is ever fabricated on the live path, and
      assistant-after-assistant still fails loudly.
    * `:worker_death` — a tool worker died without a result; answer the
      unanswered tail `tool_use`(s) with the canonical error result.
    * `:terminal` — the turn is ending; heal the tail with the pairing
      bridge before the incoming message lands.
    * `:load` — classify a restored active slice; a lone trailing orphan
      is an interrupted turn (heal it), anything else blocks for the
      offline tool.
    * `:offline` — `mix nest.repair_messages` is the repair authority.
      It reuses the same synthetic builders (`load_heal/1`,
      `MessageList.repair_ack/0`, `MessageList.continuation_prompt/0`).

  This module only *decides*: the synthetic shapes stay in
  `Nest.Messages.MessageList` so the offline planner, the load heal, the
  terminal bridge, and the worker-death recovery produce identical
  repair messages.
  """

  alias Nest.LLM.Preflight
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  @contexts [:live, :worker_death, :terminal, :load, :offline]

  @type live_decision :: :ok | :stale | {:invalid, String.t()} | {:repair, [term()]}

  @type decision ::
          live_decision()
          | :none
          | {:interrupted, [Part.ToolUse.t()]}
          | {:violations, [Preflight.violation()]}
          | :offline_authority

  @doc "The declared repair contexts."
  @spec contexts() :: [atom()]
  def contexts, do: @contexts

  @doc """
  The single repair-decision entry point.

  `messages` is the sequence *before* the incoming message (live,
  worker_death, terminal) or the restored active slice (load). For
  `:live` and `:terminal`, `incoming` is the message being appended; for
  the others it is ignored.
  """
  @spec decide(atom(), [term()], term()) :: decision()
  def decide(:live, messages, incoming), do: classify_live(messages, incoming)
  def decide(:worker_death, messages, _incoming), do: worker_death(messages)
  def decide(:terminal, messages, incoming), do: {:repair, terminal_bridge(messages, incoming)}
  def decide(:load, messages, _opts), do: classify_load(messages)
  def decide(:offline, _messages, _opts), do: :offline_authority

  @doc """
  Classify a live append, repairing the one shape that is safe to bridge.

  Returns `:ok` when the message fits the turn's wire sequence, `:stale`
  for a tool result that does not answer the live tail (a late/duplicate
  result), or `{:invalid, reason}` for a genuinely broken sequence.

  The single exception is an incoming `user` message onto a wire-`user`
  tail: that is only reachable as the turn-opening append (a user message
  is rejected mid-turn), so it is bridged rather than failed. The
  unanswered-`tool_use` clause is checked first, so no synthetic
  `tool_result` is ever produced here. `incoming` is the message about to
  be appended.
  """
  @spec classify_live([term()], term()) :: live_decision()
  def classify_live(messages, incoming) do
    pending = MessageList.unpaired_tail_tool_uses(messages)

    cond do
      tool_result?(incoming) ->
        if answers_any?(pending, incoming), do: :ok, else: :stale

      pending != [] ->
        {:invalid, unanswered_tool_use_reason(incoming, pending)}

      same_wire_role?(messages, incoming) and match?({:user, _}, incoming) ->
        {:repair, MessageList.pairing_bridge(messages, incoming)}

      same_wire_role?(messages, incoming) ->
        {:invalid, consecutive_role_reason(incoming)}

      true ->
        :ok
    end
  end

  @doc """
  Classify a restored active slice.

  Returns `:ok`, `{:interrupted, tool_uses}` for a lone trailing orphan
  (a turn that died mid-tool), or `{:violations, violations}` for
  anything else (which blocks the agent for the offline tool).
  """
  @spec classify_load([term()]) ::
          :ok | {:interrupted, [Part.ToolUse.t()]} | {:violations, [Preflight.violation()]}
  def classify_load(active) do
    case Preflight.validate(active) do
      :ok ->
        :ok

      {:error, [%{rule: :no_trailing_orphan, expected_ids: expected_ids} = violation]} ->
        trailing_orphan(active, expected_ids, violation)

      {:error, violations} ->
        {:violations, violations}
    end
  end

  @doc """
  The load-time heal messages for an interrupted trailing tool call: the
  canonical error result plus the assistant acknowledgement, so the tail
  lands on an `assistant` and the next user turn appends cleanly.
  """
  @spec load_heal([Part.ToolUse.t()]) :: [term()]
  def load_heal(tool_uses) do
    case MessageList.interrupted_tool_result(tool_uses) do
      nil -> []
      tool -> [tool, MessageList.repair_ack()]
    end
  end

  defp worker_death(messages) do
    case messages
         |> MessageList.unpaired_tail_tool_uses()
         |> MessageList.interrupted_tool_result() do
      nil -> :none
      tool -> {:repair, [tool]}
    end
  end

  defp terminal_bridge(messages, incoming) do
    MessageList.pairing_bridge(messages, incoming)
  end

  defp trailing_orphan(active, expected_ids, violation) do
    tool_uses =
      active
      |> MessageList.unpaired_tail_tool_uses()
      |> Enum.filter(&(&1.id in expected_ids))

    case tool_uses do
      [] -> {:violations, [violation]}
      uses -> {:interrupted, uses}
    end
  end

  defp tool_result?({:tool, _}), do: true
  defp tool_result?(_), do: false

  defp answers_any?([], _incoming), do: false

  defp answers_any?(pending, incoming) do
    pending_ids = MapSet.new(pending, & &1.id)
    not MapSet.disjoint?(pending_ids, answered_tool_ids(incoming))
  end

  defp answered_tool_ids({:tool, %Tool{parts: parts}}) when is_list(parts) do
    for %Part.ToolResult{tool_call_id: id} <- parts, into: MapSet.new(), do: id
  end

  defp answered_tool_ids(_incoming), do: MapSet.new()

  defp same_wire_role?(messages, incoming) do
    last = MessageList.last_wire_role(messages)
    not is_nil(last) and last == wire_role(incoming)
  end

  defp wire_role({:user, _}), do: :user
  defp wire_role({:assistant, _}), do: :assistant
  defp wire_role(_), do: nil

  defp unanswered_tool_use_reason(incoming, pending) do
    "repair does not run on the live path: refusing to append a " <>
      "#{inspect(wire_role(incoming))} message while #{length(pending)} " <>
      "live tool_use id(s) are unanswered"
  end

  defp consecutive_role_reason(incoming) do
    "repair does not run on the live path: refusing to append a second " <>
      "consecutive #{wire_role(incoming)} message"
  end
end
