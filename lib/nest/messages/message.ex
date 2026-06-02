defmodule Nest.Messages.Message do
  @moduledoc """
  Message schemas for chat with LLM agents.

  Role-specific structs with tagged tuple wrapper.
  Follows the canonical schema from notes/llm_schema.md.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @type t ::
          {:system, System.t()}
          | {:user, User.t()}
          | {:assistant, Assistant.t()}
          | {:tool, Tool.t()}

  @type role :: :system | :user | :assistant | :tool

  @doc """
  Convert a tagged tuple message to JSON-compatible map.
  Delegates to the appropriate module's to_json function.
  """
  @spec to_json(t()) :: map()
  def to_json({:system, %System{} = msg}), do: System.to_json(msg)
  def to_json({:user, %User{} = msg}), do: User.to_json(msg)
  def to_json({:assistant, %Assistant{} = msg}), do: Assistant.to_json(msg)
  def to_json({:tool, %Tool{} = msg}), do: Tool.to_json(msg)

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

  # Special handling for LangChain.Message.ContentPart struct
  defp format_api_payload_value(%{__struct__: struct_name} = v) do
    # Handle ContentPart structs - extract content from text parts
    if String.ends_with?(to_string(struct_name), ".ContentPart") or
         struct_name == LangChain.Message.ContentPart do
      map = Map.from_struct(v)
      formatted = format_api_payload(map)
      # If it's a text content part, extract just the content string
      if formatted["type"] == "text" and is_binary(formatted["content"]),
        do: formatted["content"],
        else: formatted
    else
      format_api_payload(Map.from_struct(v))
    end
  end

  defp format_api_payload_value(v) when is_struct(v), do: format_api_payload(Map.from_struct(v))
  defp format_api_payload_value(v) when is_map(v), do: format_api_payload(v)
  # Special handling for lists - check if it's a list of ContentParts and extract content
  defp format_api_payload_value(v) when is_list(v) do
    formatted_list = Enum.map(v, &format_api_payload_value/1)
    # If all items are strings (extracted from ContentParts), join them
    # Otherwise, return the formatted list
    if Enum.all?(formatted_list, &is_binary/1) do
      Enum.join(formatted_list, "")
    else
      formatted_list
    end
  end

  defp format_api_payload_value(v) when is_atom(v) and v not in [nil, true, false],
    do: to_string(v)

  defp format_api_payload_value(v), do: v
end
