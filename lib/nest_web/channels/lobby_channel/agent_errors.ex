defmodule NestWeb.LobbyChannel.AgentErrors do
  @moduledoc false
  # Maps `Agents.change_model` / `Agents.edit_agent` /
  # `Spaces.create_space_with_root_agent` error reasons to
  # `{:error, %{"reason" => ...}}` reply payloads. Extracted from the
  # lobby channel so it stays under the credo line cap.

  require Logger

  alias Nest.Agents.PersistedAgent
  alias Nest.Spaces.Space

  # The `Nest.Sandbox.workspace_error/1` refusals a create can carry; each is
  # its own reply code (see `create_payload/1`).
  @workspace_reasons [:workspace_required, :workspace_missing, :workspace_under_tmp]

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
  # space: the workspace/vocation refusals a user can act on, a root-agent
  # name the client chose that is not filename-safe, plus changesets and
  # internal terms from the space insert and the agent spawn. Everything
  # except the first two groups stays generic (and logged), because an
  # `Ecto.Changeset` is neither `to_string/1`-able nor fit to show a user.
  @doc false
  def create_payload(reason) do
    case reason do
      # One arm for the workspace refusals: the reply code is the reason's own
      # name, so listing them separately would be three copies of one rule.
      workspace_reason when workspace_reason in @workspace_reasons ->
        {:error, %{"reason" => to_string(workspace_reason)}}

      :blueprint_missing ->
        {:error, %{"reason" => "blueprint_missing"}}

      :missing_vocation ->
        {:error, %{"reason" => "missing_vocation"}}

      # A `"none"`-backend space's agent name collides with a live agent's
      # scratch directory in another `"none"` space — they share the host's
      # `/tmp`. The other space is named so the message can say which one.
      {:scratch_name_in_use, space_name} ->
        {:error, %{"reason" => "scratch_name_in_use", "space_name" => space_name}}

      {:vocation_not_found, slug} ->
        # A blueprint whose root vocation no longer exists: stale blueprint
        # data rather than a user mistake, so name the code and log the detail.
        Logger.warning("Blueprint root vocation #{inspect(slug)} no longer exists")
        {:error, %{"reason" => "vocation_not_found"}}

      # The root agent's name (`create_space`'s `agent_name`) is not a
      # filename-safe component. Matching `data:` on the *agent* schema is what
      # keeps this precise: a space changeset (blank `:name`, taken `:slug`, a
      # `:slug` that could not be an agent name) also carries `:name`/`:slug`
      # errors and must stay generic, and `Space.changeset/2` refuses an unsafe
      # slug before it ever becomes a name. The New Space form sends neither
      # field (the root agent is named `<slug>-root`), so this is for custom
      # clients.
      %Ecto.Changeset{data: %PersistedAgent{}, errors: errors} ->
        agent_changeset_payload(errors)

      # A space changeset refused the row. The one field a client sends that
      # `Space.create_changeset/2` validates by *value* is the sandbox backend,
      # so name that rather than answering "failed to create" about a choice the
      # user just made; the rest (a blank name, a taken slug) stays generic,
      # like the other unshowable reasons here.
      %Ecto.Changeset{data: %Space{}, errors: errors} ->
        space_changeset_payload(errors)

      other ->
        Logger.error("Failed to create space: #{inspect(other)}")
        {:error, %{"reason" => "failed_to_create"}}
    end
  end

  # A root-agent name the client chose that is not filename-safe gets a code
  # the client can show; any other agent-changeset error stays generic (and
  # logged), like the rest of this module's unshowable reasons.
  defp agent_changeset_payload(errors) do
    if Keyword.has_key?(errors, :name) do
      {:error, %{"reason" => "invalid_agent_name"}}
    else
      Logger.error("Failed to create space: #{inspect(errors)}")
      {:error, %{"reason" => "failed_to_create"}}
    end
  end

  # Same shape for the space changeset's one client-facing field.
  defp space_changeset_payload(errors) do
    if Keyword.has_key?(errors, :sandbox_backend) do
      {:error, %{"reason" => "invalid_sandbox_backend"}}
    else
      Logger.error("Failed to create space: #{inspect(errors)}")
      {:error, %{"reason" => "failed_to_create"}}
    end
  end
end
