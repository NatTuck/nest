defmodule NestWeb.LobbyChannel.AgentErrors do
  @moduledoc false
  # Maps `Agents.change_model` / `Agents.edit_agent` error reasons to
  # `{:error, %{"reason" => ...}}` reply payloads. Extracted from the
  # lobby channel so it stays under the credo line cap.

  require Logger

  @doc false
  def change_model_payload(name, reason) do
    case reason do
      :agent_busy ->
        {:error, %{"reason" => "agent_busy"}}

      {:invalid_model, _} ->
        {:error, %{"reason" => "invalid_model"}}

      :not_found ->
        {:error, %{"reason" => "not_found"}}

      other ->
        Logger.error("Failed to change model on agent #{inspect(name)}: #{inspect(other)}")
        {:error, %{"reason" => to_string(other)}}
    end
  end

  @doc false
  def edit_payload(name, reason) do
    case reason do
      :agent_busy ->
        {:error, %{"reason" => "agent_busy"}}

      :workspace_required ->
        {:error, %{"reason" => "workspace_required"}}

      :context_overflow ->
        {:error, %{"reason" => "context_overflow"}}

      {:invalid_model, _} ->
        {:error, %{"reason" => "invalid_model"}}

      :not_found ->
        {:error, %{"reason" => "not_found"}}

      other ->
        Logger.error("Failed to edit agent #{inspect(name)}: #{inspect(other)}")
        {:error, %{"reason" => to_string(other)}}
    end
  end
end
