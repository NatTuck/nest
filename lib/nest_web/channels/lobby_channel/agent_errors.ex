defmodule NestWeb.LobbyChannel.AgentErrors do
  @moduledoc false
  # Maps `Agents.change_model` / `Agents.edit_agent` /
  # `Spaces.create_space_with_root_agent` error reasons to
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

      :workspace_missing ->
        {:error, %{"reason" => "workspace_missing"}}

      :workspace_under_tmp ->
        {:error, %{"reason" => "workspace_under_tmp"}}

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

  # `Spaces.create_space_with_root_agent/2` returns a *heterogeneous* reason
  # space: the workspace/vocation refusals a user can act on, plus changesets
  # and internal terms from the space insert and the agent spawn. Only the
  # first group gets a named code; the rest stay generic (and logged), because
  # an `Ecto.Changeset` is neither `to_string/1`-able nor fit to show a user.
  @doc false
  def create_payload(reason) do
    case reason do
      :workspace_required ->
        {:error, %{"reason" => "workspace_required"}}

      :workspace_missing ->
        {:error, %{"reason" => "workspace_missing"}}

      :workspace_under_tmp ->
        {:error, %{"reason" => "workspace_under_tmp"}}

      :blueprint_missing ->
        {:error, %{"reason" => "blueprint_missing"}}

      :missing_vocation ->
        {:error, %{"reason" => "missing_vocation"}}

      {:vocation_not_found, slug} ->
        # A blueprint whose root vocation no longer exists: stale blueprint
        # data rather than a user mistake, so name the code and log the detail.
        Logger.warning("Blueprint root vocation #{inspect(slug)} no longer exists")
        {:error, %{"reason" => "vocation_not_found"}}

      other ->
        Logger.error("Failed to create space: #{inspect(other)}")
        {:error, %{"reason" => "failed_to_create"}}
    end
  end
end
