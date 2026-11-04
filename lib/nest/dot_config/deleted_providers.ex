defmodule Nest.DotConfig.DeletedProviders do
  @moduledoc """
  The optional top-level `deleted-providers` key: parsing it, and the two ways a
  file can contradict it.

  The key names the providers the user deleted in the app. `Nest.DotConfig.load/0`
  drops those names from the merged provider set whichever file defines them,
  which is what lets the merge be per name: the overlay cannot delete a provider
  by omitting it, because `config.toml` would supply it again on the next load.
  `Nest.DotConfig.Writer` maintains the list.

  It lives here rather than in `Nest.DotConfig` for the reason `FieldValidation`
  and `KeyValidation` do — that module is at its file-length cap (issue #80) —
  and that is also why every message carries the file's path: with two files on
  disk, "Provider alpha: is both defined and listed in deleted-providers" does
  not say which one to open.

  The key belongs in `local.toml`. In `config.toml` it is refused rather than
  ignored: a list there could hide nothing (the base file is the only source the
  overlay can hide a provider from), so it would be a silent no-op — and a no-op
  that reads as a working deletion is worse than a refusal.
  """

  alias Nest.DotConfig.FieldValidation

  @key "deleted-providers"

  @doc "The key as the files spell it."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  Parses the optional value: absent means none, a list of provider names is
  kept, and anything else raises with the file it came from.

  `local.toml` is user-editable, so `deleted-providers = "pegasus"` has to be a
  refusal naming the key — not a crash on `Enum`, and above all not a silent
  `[]`, which would bring a deleted provider back on the next load.
  """
  @spec parse(term(), String.t()) :: [String.t()]
  def parse(nil, _path), do: []

  def parse(names, path) when is_list(names), do: Enum.map(names, &parse_name(&1, path))

  def parse(other, path) do
    raise "Invalid #{@key} #{inspect(other)}: must be a list of provider names, in #{path}"
  end

  @doc """
  Refuses a file that both defines and deletes the same provider.

  That is the writer's own invariant, so a file carrying both was edited by hand
  and one of the two lines is a mistake. Naming the provider and the file beats
  picking a winner, which would leave the file saying two things and meaning
  one.
  """
  @spec refuse_contradictions!(map(), [String.t()], String.t()) :: :ok
  def refuse_contradictions!(providers, deleted, path) do
    case Enum.find(deleted, &Map.has_key?(providers, &1)) do
      nil ->
        :ok

      name ->
        raise "Provider #{name}: is both defined and listed in #{@key}, in #{path}; " <>
                "a provider can be defined or deleted, not both"
    end
  end

  @doc """
  Refuses the key in `config.toml`, where it could hide nothing — see the
  moduledoc.
  """
  @spec refuse_in_config!(map(), String.t()) :: :ok
  def refuse_in_config!(config, path) do
    case config.deleted_providers do
      [] ->
        :ok

      names ->
        raise "#{@key} belongs in local.toml, not in #{path}: it lists " <>
                "#{Enum.join(names, ", ")}, and a record in that file could only hide a " <>
                "provider that #{path} itself defines."
    end
  end

  # The shared rule quotes the offending name; the path is appended here because
  # this key can be written in either file, so the name alone does not say which
  # one to open.
  defp parse_name(name, path) when is_binary(name) do
    FieldValidation.provider_name(name)
  rescue
    error ->
      reraise RuntimeError.exception("#{Exception.message(error)}, in #{path}"), __STACKTRACE__
  end

  defp parse_name(other, path) do
    raise "Invalid #{@key} entry #{inspect(other)}: must be a provider name, in #{path}"
  end
end
