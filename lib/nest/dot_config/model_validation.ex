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

  Also called on the write side: the GUI's context-limit input is a
  `type="number"`, and `Number()` keeps a typed `0` — `e.target.value` is the
  string `"0"`, which is truthy, so the `? … : null` guard does not catch it. Its
  `min="1"` is a courtesy rather than a guard (no enclosing `<form>`, no
  `checkValidity()` call), so this is what actually refuses the value.
  """
  @spec validate_default_context_limit(term(), String.t() | nil) :: pos_integer() | nil
  def validate_default_context_limit(nil, _provider_name), do: nil

  def validate_default_context_limit(limit, provider_name) do
    FieldValidation.positive_integer(limit, provider_name, "default-context-limit")
  end

  @doc """
  A model's `context-limit`, or a raise. `nil` means unset.

  `nil` is not the same as `0`. An absent key leaves the limit to be resolved
  later (the discovery cache, then the provider default, then `@default_limit`),
  but a **present** value is used as-is: `Init.context_limit_layer/3` keeps any
  integer, and `Reserve.compaction_reserve/1` guards `is_integer(limit) and
  limit > 0`. So `context-limit = 0` does not mean "no limit" — it means every
  agent start raises `FunctionClauseError` in the reserve arithmetic, from
  `Init.build_vocation_pipeline/1` and `PreSpawn.build_initial_system_message/1`
  alike. That is why this is validated rather than passed through.

  Both sides call it. The writer has to, because `ProviderModelRow`'s
  `type="number"` sends `Number("0")` for a typed `0` — the string `"0"` is
  truthy, so the `e.target.value ? … : null` guard does not catch it — and the
  value would otherwise be written to `local.toml` before any read refused it.
  """
  @spec validate_context_limit(term(), String.t() | nil, String.t() | nil) :: pos_integer() | nil
  def validate_context_limit(nil, _provider_name, _model_name), do: nil

  def validate_context_limit(limit, provider_name, model_name) do
    FieldValidation.positive_integer(
      limit,
      provider_name,
      "context-limit#{subject(model_name)}"
    )
  end

  @doc """
  The provider's `base-url`, or a raise. `nil` means unset.

  Also called on the write side. This is the same shape of hole as
  `probe-base-url` below, and the last one found: neither side validated it, so
  the two *agreed* and no reader/writer drift existed — but the value is
  dereferenced on every chat, and a non-binary raises `FunctionClauseError` in
  `String.trim_trailing/2` (`OpenAIClient.normalize_endpoint/2`,
  `AnthropicClient`, `MultimodalProbe`) and in `EndpointProbe.probe/1`, plus an
  `ArgumentError` on `<>` in `ChatModel.discovery_url/1`. A channel client could
  send `7` and have it persisted.

  Non-empty rather than "any binary", so this field and its sibling
  `probe-base-url` agree: `""` is not a URL, and this module's convention is that
  a bad value is a **startup** error rather than something that surfaces on the
  first request. `ProviderEditor` sends `null` for a cleared field, so clearing
  it means "unset" rather than "refused".
  """
  @spec validate_base_url(term(), String.t() | nil) :: String.t() | nil
  def validate_base_url(nil, _provider_name), do: nil

  def validate_base_url(url, provider_name) do
    FieldValidation.non_empty_string(url, provider_name, "base-url")
  end

  @doc """
  The provider's `probe-base-url`, or a raise. `nil` means unset.

  Also called on the write side, and it is the field that made the "the class is
  closed" claim false: the reader raised on it while the write side passed it
  through, so a `probe-base-url = ""` from a channel client was persisted and
  then raised on the re-read — inside `Models.rescan/0`, which has no rescue, so
  the `Models` process died, the operator got no reply at all, and the next boot
  could not start. The browser coerces `""` to `null`, but the rule must not rest
  on one client's coercion.
  """
  @spec validate_probe_base_url(term(), String.t() | nil) :: String.t() | nil
  def validate_probe_base_url(nil, _provider_name), do: nil

  def validate_probe_base_url(url, provider_name) do
    FieldValidation.non_empty_string(url, provider_name, "probe-base-url")
  end

  @doc """
  The provider's `api-key`, or a raise. `nil` means unset.

  The rule is only that the value is text: an empty string and the documented
  `api-key = "none"` opt-out are both legitimate, and whether a reference-shaped
  key *resolves* is a separate question answered by
  `Nest.DotConfig.KeyValidation` on the read side.

  A non-binary is refused because a non-binary that reaches the resolver raises:
  `resolve_api_key/1` calls `String.starts_with?/2` on it, so a hand-written
  `api-key = 7` used to boot and then raise `FunctionClauseError` at chat time.
  Both sides now call this, so that is a startup error instead.
  """
  @spec validate_api_key(term(), String.t() | nil) :: String.t() | nil
  def validate_api_key(nil, _provider_name), do: nil

  def validate_api_key(key, provider_name) do
    FieldValidation.string(key, provider_name, "api-key")
  end

  @doc """
  A provider silence bound in seconds, or a raise. `nil` means unset.

  Called on both sides: the reader (`Nest.DotConfig.parse_first_byte_timeout/2`,
  `parse_stream_idle_timeout/2`) and the writer
  (`NestWeb.LobbyChannel.Providers`), which validates the GUI payload before
  `Writer.save_providers/1` so a refused save writes nothing. `field` names the
  key in the error message, because the provider now has two of these bounds and
  "invalid timeout" would not say which.
  """
  @spec validate_timeout(term(), String.t() | nil, String.t()) :: pos_integer() | nil
  def validate_timeout(seconds, provider_name, field \\ "timeout")

  def validate_timeout(nil, _provider_name, _field), do: nil

  def validate_timeout(seconds, provider_name, field) do
    FieldValidation.positive_integer(seconds, provider_name, field, " (seconds)")
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
