defmodule Nest.Messages.Message do
  @moduledoc """
  Message schemas for chat with LLM agents.

  Role-specific structs with tagged tuple wrapper.
  Follows the canonical schema from notes/llm_schema.md.

  `{:compaction, Compaction.t()}` is a non-LLM-visible marker
  that lives in the agent's `history` list (not `messages`).
  It marks the boundary between archived and active history
  and tells the chat UI to render a divider with an "expand
  archived messages" affordance.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @type t ::
          {:system, System.t()}
          | {:user, User.t()}
          | {:assistant, Assistant.t()}
          | {:tool, Tool.t()}
          | {:compaction, Compaction.t()}

  @type role :: :system | :user | :assistant | :tool | :compaction

  @doc """
  Convert a tagged tuple message to JSON-compatible map.
  Delegates to the appropriate module's to_json function.
  """
  @spec to_json(t()) :: map()
  def to_json({:system, %System{} = msg}), do: System.to_json(msg)
  def to_json({:user, %User{} = msg}), do: User.to_json(msg)
  def to_json({:assistant, %Assistant{} = msg}), do: Assistant.to_json(msg)
  def to_json({:tool, %Tool{} = msg}), do: Tool.to_json(msg)
  def to_json({:compaction, %Compaction{} = msg}), do: Compaction.to_json(msg)

  @doc """
  Format api_logs for JSON output, ensuring consistent string keys.
  """
  @spec format_api_logs([map()] | nil) :: [map()]
  def format_api_logs(nil), do: []

  def format_api_logs(api_logs) do
    Enum.map(api_logs, fn log ->
      %{
        "id" => log[:id] || log["id"],
        "timestamp" => format_timestamp(log[:timestamp] || log["timestamp"]),
        "type" => to_string(log[:type] || log["type"]),
        "payload" => format_api_payload(log[:payload] || log["payload"])
      }
    end)
  end

  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: other

  defp format_api_payload(nil), do: nil

  defp format_api_payload(payload) when is_struct(payload),
    do: format_api_payload(Map.from_struct(payload))

  defp format_api_payload(payload) when is_map(payload) do
    payload
    |> Enum.map(fn {k, v} ->
      key = if is_atom(k), do: to_string(k), else: k
      value = format_api_payload_value(v)
      {key, value}
    end)
    |> Map.new()
  end

  defp format_api_payload(payload), do: payload

  defp format_api_payload_value(v) when is_struct(v), do: format_api_payload(Map.from_struct(v))
  defp format_api_payload_value(v) when is_map(v), do: format_api_payload(v)
  defp format_api_payload_value(v) when is_list(v), do: Enum.map(v, &format_api_payload_value/1)

  defp format_api_payload_value(v) when is_atom(v) and v not in [nil, true, false],
    do: to_string(v)

  defp format_api_payload_value(v), do: v
end
