defmodule Nest.DotConfig.ModelValidation do
  @moduledoc """
  Read-time validation for a `[[providers.<name>.models]]` entry's values.

  These live apart from `Nest.DotConfig` to keep that module under its
  file-length cap — the same reason `Nest.DotConfig.KeyValidation` and
  `Nest.ParseCache` do (see issue #80) — and they are here rather than at the
  call sites because the whole point is that a bad value is a **startup** error.
  That is the convention the parent module's `parse_timeout` and
  `parse_default_context_limit` already follow: a config mistake should surface
  when the config is read, not on the first LLM call, and not as a crash inside
  the `models-list` tool.

  `validate_name/2` and `validate_multi_modal/3` are also called by
  `NestWeb.LobbyChannel.Providers` on the **write** side, so a value the GUI
  accepts is a value the reader accepts. See `Nest.DotConfig.FieldValidation`
  for why that sharing matters.
  """

  alias Nest.DotConfig.FieldValidation

  @doc """
  The model's name, or a raise.

  The name is the model's id: it is what `models-list` renders and what a model
  is addressed by. Both of the bad shapes used to be accepted, and each failed
  somewhere else: a table-valued name reached the `models-list` formatter, which
  joins the provider and the name into one string and raised `String.Chars`
  inside a tool call, and an absent name rendered as a bare `/`.

  A blank name is the GUI's own default (`emptyModel()` returns `name: ""`), so
  this is called on the write side too — refusing it there is what stops the app
  writing a config it will refuse to read.
  """
  @spec validate_name(term(), String.t() | nil) :: String.t()
  def validate_name(nil, provider_name) do
    raise "Provider #{provider_name}: a [[models]] entry has no name; " <>
            "every model needs the name it is addressed by"
  end

  def validate_name(name, _provider_name) when is_binary(name) and name != "", do: name

  def validate_name(name, provider_name) do
    raise "Provider #{provider_name}: invalid model name #{inspect(name)}: " <>
            "must be a non-empty string"
  end

  @doc """
  The model's optional `multi-modal` claim, or a raise.

  `nil` means "no claim made", which is not a negative — see
  `Nest.Models.MultiModal` for the three-valued vocabulary. A table whose
  `input` is a list of names is kept; everything else raises, so an explicit
  `multi-modal = false` is a startup error rather than being silently discarded
  into "no claim".

  A table with no `input` key is kept as-is: it is not a claim this system can
  read, and `models-list` reports that honestly as `input: invalid`.

  The model's name is only used to name it in the message, and the write side
  has not resolved it yet when it validates the claim — so it is optional.
  """
  @spec validate_multi_modal(term(), String.t() | nil, String.t() | nil) :: map() | nil
  def validate_multi_modal(nil, _provider_name, _model_name), do: nil

  def validate_multi_modal(%{} = claim, provider_name, model_name) do
    case Map.get(claim, "input") do
      nil ->
        claim

      input ->
        if is_list(input) and Enum.all?(input, &is_binary/1) do
          claim
        else
          raise invalid_modalities_message(input, provider_name, model_name)
        end
    end
  end

  def validate_multi_modal(value, provider_name, model_name) do
    raise "Provider #{provider_name}#{subject(model_name)}: invalid multi-modal " <>
            "#{inspect(value)}: must be a table"
  end

  @doc """
  The provider's `default-context-limit`, or a raise. `nil` means unset.

  Also called on the write side: the GUI's context-limit input is a bare
  `type="number"` with no `min`, so typing `0` — or `0.5`, which has no `step`
  to stop it — produces a value the reader rejects.
  """
  @spec validate_default_context_limit(term(), String.t() | nil) :: pos_integer() | nil
  def validate_default_context_limit(nil, _provider_name), do: nil

  def validate_default_context_limit(limit, provider_name) do
    FieldValidation.positive_integer(limit, provider_name, "default-context-limit")
  end

  @doc """
  The provider's `timeout` in seconds, or a raise. `nil` means unset.

  Also called on the write side. The GUI does not expose a timeout field today,
  so this is the one rule with no live GUI path to it; it is here so the two
  sides stay defined in one place rather than drifting apart the moment a field
  is added.
  """
  @spec validate_timeout(term(), String.t() | nil) :: pos_integer() | nil
  def validate_timeout(nil, _provider_name), do: nil

  def validate_timeout(seconds, provider_name) do
    FieldValidation.positive_integer(seconds, provider_name, "timeout", " (seconds)")
  end

  @doc """
  The provider's `tags`, or a raise. `nil` means unset (the reader then uses
  `[]`).

  Also called on the write side: the GUI preserves tags it was given, so a
  malformed list can arrive from a client that built one itself.
  """
  @spec validate_tags(term(), String.t() | nil) :: [String.t()] | nil
  def validate_tags(nil, _provider_name), do: nil

  def validate_tags(tags, provider_name) do
    FieldValidation.string_list(tags, provider_name, "tags")
  end

  defp subject(nil), do: ""
  defp subject(name), do: ", model #{name}"

  defp invalid_modalities_message(input, provider_name, model_name) do
    "Provider #{provider_name}#{subject(model_name)}: invalid multi-modal input " <>
      "#{inspect(input)}: must be a list of strings"
  end
end
