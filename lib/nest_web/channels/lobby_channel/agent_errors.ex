defmodule NestWeb.LobbyChannel.AgentErrors do
  @moduledoc false
  # Maps `Agents.change_model` / `Agents.edit_agent` /
  # `Spaces.create_space_with_root_agent` error reasons to
  # `{:error, %{"reason" => ...}}` reply payloads. Extracted from the
  # lobby channel so it stays under the credo line cap.

  require Logger

  alias Nest.Agents.PersistedAgent
  alias Nest.Spaces.Space
  alias NestWeb.ErrorPayload

  # The `Nest.Sandbox.workspace_error/1` refusals a create can carry.
  @workspace_reasons [:workspace_required, :workspace_missing, :workspace_under_tmp]

  # The refusals whose reply code is simply the reason's own name, so one arm
  # covers them (see `create_payload/1`).
  @simple_reasons @workspace_reasons ++ [:blueprint_missing, :missing_vocation]

  # A reason that carries its detail beside the tag: `{:scratch_path_taken, path}`,
  # `{:config_file_not_regular, path, type}`. One guard rather than a `{tag, _}`
  # pattern, which would send the wider ones to the `other` arm.
  defguardp is_tagged(reason)
            when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0))

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
        {:error, ErrorPayload.from_reason(other)}
    end
  end

  # The edit path's refusals whose reply code is the reason's own name. One
  # entry, and deliberately not the workspace trio `@simple_reasons` carries:
  # `edit_agent` takes no workspace, so it cannot produce one — a workspace is a
  # *space* property, edited through `edit_space` (`edit_space_payload/1`).
  @edit_simple [:agent_busy]

  @doc false
  def edit_payload(name, reason) do
    case reason do
      simple when simple in @edit_simple ->
        {:error, %{"reason" => to_string(simple)}}

      {:invalid_model, _} ->
        {:error, %{"reason" => "invalid_model"}}

      :context_overflow ->
        {:error, %{"reason" => "context_overflow"}}

      :not_found ->
        {:error, %{"reason" => "not_found"}}

      # A tagged reason carries a detail term, and `to_string/1` on a tuple
      # raises — which kills the channel process and leaves the client with no
      # reply at all. `create_payload/1` has the same arm; the log line and the
      # fallback code differ because this is an edit.
      # Any tuple whose head is a tag: the detail term may be one field
      # (`{:scratch_path_taken, path}`) or two (`{:config_file_not_regular, path,
      # type}`), and a narrow `{tag, _detail}` pattern would send the wider ones to
      # the `other` arm below, where `inspect` is all that is left.
      tagged when is_tagged(tagged) ->
        tagged_payload(tagged, {"Failed to edit agent #{inspect(name)}", "failed_to_edit"})

      other ->
        Logger.error("Failed to edit agent #{inspect(name)}: #{inspect(other)}")
        {:error, %{"reason" => "failed_to_edit"}}
    end
  end

  # The space edit's reply codes: the same refusals a create can carry (a
  # workspace the sandbox will not run, a tagged config-file reason), plus the
  # one field a client sends by *value* — the backend.
  @doc false
  def edit_space_payload(reason) do
    case reason do
      simple when simple in @simple_reasons ->
        {:error, %{"reason" => to_string(simple)}}

      # Another session is editing this space: its latch is up, so nothing may
      # start in it until that edit finishes or its claim expires.
      :space_changing ->
        {:error, %{"reason" => "space_changing"}}

      # Not a refusal — the edit needs the user's word first, because it stops
      # work. The plan rides the reply so the dialog can name what it costs.
      {:confirmation_required, plan} ->
        {:error, confirmation_payload(plan)}

      tagged when is_tagged(tagged) ->
        tagged_payload(tagged, {"Failed to edit space", "failed_to_edit"})

      %Ecto.Changeset{} = changeset ->
        space_changeset_payload(changeset, "Failed to edit space", "failed_to_edit")

      other ->
        Logger.error("Failed to edit space: #{inspect(other)}")
        {:error, %{"reason" => "failed_to_edit"}}
    end
  end

  # The wire form of `Nest.Spaces.edit_plan/0`: the agents the edit would stop,
  # each with its status and its running job count, and the space's total. String
  # keys because it is the wire.
  defp confirmation_payload(plan) do
    %{
      "reason" => "confirmation_required",
      "jobs" => plan.jobs,
      "agents" =>
        Enum.map(plan.agents, fn agent ->
          %{
            "name" => agent.name,
            "status" => Atom.to_string(agent.status),
            "jobs" => agent.jobs
          }
        end)
    }
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
      # One arm for the refusals whose reply code is the reason's own name: the
      # workspace ones, plus the two the blueprint resolution adds. Listing them
      # separately would be five copies of one rule.
      simple when simple in @simple_reasons ->
        {:error, %{"reason" => to_string(simple)}}

      # The tagged refusals, which all carry a detail term beside the code.
      tagged when is_tagged(tagged) ->
        tagged_payload(tagged, {"Failed to create space", "failed_to_create"})

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
      %Ecto.Changeset{data: %Space{}} = changeset ->
        space_changeset_payload(changeset, "Failed to create space", "failed_to_create")

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

  # A workspace whose `.nest` or `AGENTS.md` is not a regular file: Nest cannot
  # mask a symlink, and a mask that is merely omitted lets an agent replace the
  # file with one that grants host access. The client needs the path to tell the
  # user which file to replace.
  #
  # Each takes a `{log_prefix, fallback_code}` context; only the last arm uses it.
  defp tagged_payload({:config_file_not_regular, _path, _type} = tagged, _context) do
    {:error, ErrorPayload.from_reason(tagged)}
  end

  # The refusals whose reason carries a detail term. The two `"none"`-space
  # scratch ones come from the same place — such a space's agents live at
  # `/tmp/<name>` in the host's one `/tmp` — and each names what it refused: the
  # other space whose live agent holds the name, or the path that is already
  # something Nest does not own.
  defp tagged_payload({:scratch_name_in_use, other_space_name}, _context) do
    {:error, %{"reason" => "scratch_name_in_use", "space_name" => other_space_name}}
  end

  defp tagged_payload({:scratch_path_taken, path}, _context) do
    {:error, %{"reason" => "scratch_path_taken", "path" => path}}
  end

  # A blueprint whose root vocation no longer exists: stale blueprint data rather
  # than a user mistake, so name the code and log the detail.
  defp tagged_payload({:vocation_not_found, slug}, _context) do
    Logger.warning("Blueprint root vocation #{inspect(slug)} no longer exists")
    {:error, %{"reason" => "vocation_not_found"}}
  end

  # A tagged reason no arm above knows: log the detail and answer with the
  # caller's own code. "failed to create" and "failed to edit" are not
  # interchangeable — the client shows the user what it was trying to do.
  defp tagged_payload(other, {log, code}) do
    Logger.error("#{log}: #{inspect(other)}")
    {:error, %{"reason" => code}}
  end

  # A space changeset's one client-facing field, on both paths: the backend is
  # the only thing a client sends that the changeset validates by *value*, so
  # name it rather than answering "failed" about a choice the user just made.
  # The rest (a blank name, a taken slug, an unshowable error) stays generic and
  # logged, under the prefix of the action that was attempted.
  defp space_changeset_payload(%Ecto.Changeset{errors: errors}, log_prefix, fallback_code) do
    if Keyword.has_key?(errors, :sandbox_backend) do
      {:error, %{"reason" => "invalid_sandbox_backend"}}
    else
      Logger.error("#{log_prefix}: #{inspect(errors)}")
      {:error, %{"reason" => fallback_code}}
    end
  end
end
