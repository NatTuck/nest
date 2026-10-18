defmodule Nest.Agents.Agent.SpawnErrors do
  @moduledoc """
  How a failed spawn is worded for the model.

  Every refusal a spawn can produce becomes a sentence the agent that asked can
  act on — which slug to pass, which name is legal, why a mode is refused —
  rather than an `inspect` of a tuple dumped into its context. The clauses live
  here rather than in `Nest.Agents.Agent.ToolLoop` so that module stays a
  dispatcher, and so the wording has one home.

  The sibling renderer for `agents-batch` is
  `Nest.Agents.Agent.BatchPlan.spawn_error_message/1`: a batch's failure is the
  whole call's, and says so ("Could not spawn batch children: ...").
  """

  @doc """
  The model-facing text for a spawn failure.
  """
  @spec message(term()) :: String.t()
  def message({:vocation_not_spawnable, allowed}) do
    labels = Enum.map_join(allowed, ", ", fn {name, slug} -> "#{name} (#{slug})" end)

    "Could not spawn agent: that vocation is not spawnable in this space. " <>
      "Allowed vocations: #{labels}. Retry passing one as `vocation`."
  end

  def message({:vocation_not_found, slug}) do
    "Could not spawn agent: no vocation with slug #{inspect(slug)} exists. " <>
      "Retry with a valid `vocation` slug."
  end

  # The space's blueprint names no default, so an omitted `vocation` has no
  # answer — see `Nest.Agents.Supervisor.resolve_spawn_vocation/2`. The allowed
  # list is included because it is the one thing that makes the retry easy: the
  # model has to pass a slug, and a restricted space will refuse most guesses.
  def message({:vocation_required, allowed}) do
    allowed_hint =
      case allowed do
        [] ->
          # An *empty* list here means the space has no whitelist, i.e. it is
          # unrestricted — not that nothing is allowed. Saying "you must name one
          # and any will do" is a complete instruction; listing nothing is not.
          "this space has no whitelist, so any vocation is allowed"

        labels ->
          "allowed: " <>
            Enum.map_join(labels, ", ", fn {name, slug} -> "#{name} (#{slug})" end)
      end

    "Could not spawn agent: `vocation` is required — this space has no default " <>
      "spawn vocation, so it cannot be omitted; #{allowed_hint}. Retry passing " <>
      "one as `vocation`."
  end

  # An unsafe `name` is the likeliest way an LLM trips validation
  # (`"code reviewer"`, `"Reviewer 2"`): `Agents.create_agent/3` returns the
  # changeset from `PersistedAgent.changeset/2`, whose name rule is
  # `Nest.Name`'s `[a-z0-9_-]+`. Render that rule plainly — the catch-all below would
  # dump a whole `#Ecto.Changeset<…>` struct into the model's context, which
  # is both noisy and useless to it. (A duplicate name never arrives here:
  # `Persistence.do_insert/1` translates the unique violation to
  # `{:error, :duplicate_name}`.)
  def message(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :name) do
      "Could not spawn agent: the name must be non-empty and contain only " <>
        "lowercase letters, digits, `_` and `-` (no capitals, spaces or slashes). " <>
        "Retry with a different `name`."
    else
      "Could not spawn agent: the request was rejected (#{inspect(errors)})."
    end
  end

  # The spawner named a mode the monotone rule refuses (`ModeAuthority`): a
  # `plan` parent may not spawn an `act` child, nor spawn one and then raise it.
  # The reason is already a sentence for the agent that asked, so it is passed
  # through rather than wrapped in `inspect`.
  def message({:mode_refused, reason}),
    do: "Could not spawn agent: #{reason}"

  # A workspace the config-file gate refuses: `Nest.ConfigFile.error_message/1`
  # already words it for a human, and `inspect` would hand the model a tuple.
  def message({:config_file_not_regular, _path, _type} = reason),
    do: "Could not spawn agent: #{Nest.ConfigFile.error_message(reason)}"

  def message(reason), do: "Could not spawn agent: #{inspect(reason)}"
end
