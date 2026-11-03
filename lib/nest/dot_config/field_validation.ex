defmodule Nest.DotConfig.FieldValidation do
  @moduledoc """
  The rules a provider or model config value must satisfy, in **one** place.

  Both sides of the config use these: `Nest.DotConfig` when it reads a value,
  and `NestWeb.LobbyChannel.Providers` when it accepts one from the GUI. That
  sharing is the point. The defect this module exists to prevent is the reader
  and the writer disagreeing about what is valid — which is how a config the
  app writes for itself becomes one the app refuses to read, and the read is on
  `Nest.Models.init/1`'s boot path, so the app then cannot start at all.

  They live apart from `Nest.DotConfig` for two reasons:

    * that module's file-length cap (issue #80), and
    * `Nest.DotConfig` is Mimic-wrapped, so a caller reaching a validator
      through it would pick up any test stub. The GUI path calls this module
      directly, exactly as `Nest.DotConfig.KeyValidation` is called.

  Each function returns the value on success and raises a message naming the
  field and the offending value. **Defaulting stays with the reader**, which is
  the only side that has a default to apply: `nil` means "not set here" to the
  writer, and "use the default" to the reader.
  """

  @doc """
  A positive integer, or a raise.

  Used for a provider's `timeout` (seconds) and `default-context-limit`. `nil`
  is the caller's business — the reader substitutes a default, the writer omits
  the key — so each caller handles it before calling here.
  """
  @spec positive_integer(term(), String.t() | nil, String.t(), String.t()) :: pos_integer()
  def positive_integer(value, provider_name, field, unit \\ "") do
    if is_integer(value) and value > 0 do
      value
    else
      raise "Provider #{provider_name}: invalid #{field} #{inspect(value)}: " <>
              "must be a positive integer#{unit}"
    end
  end

  @doc """
  A list of strings, or a raise.

  `tags = "abc"` reached `Enum.member?/2` in `get_providers_by_tag/2`, which
  raises on a binary — and `|| []` cannot rescue a value that is truthy but not
  a list.
  """
  @spec string_list(term(), String.t() | nil, String.t()) :: [String.t()]
  def string_list(value, provider_name, field \\ "tags") do
    if is_list(value) and Enum.all?(value, &is_binary/1) do
      value
    else
      raise "Provider #{provider_name}: invalid #{field} #{inspect(value)}: " <>
              "must be a list of strings"
    end
  end

  @doc """
  A boolean, or a raise. `nil` means "not set here" and takes `default`.

  Used for every provider flag — `auto-models`, `auto-probe`, `expose-models`,
  `probe-multimodal` — on both sides. The rule is one rule because the defect it
  prevents is the two sides disagreeing: `auto-models = "no"` was truthy, so a
  typo silently turned auto-discovery **on**, and the writer's `|| false` wrote
  the string through. `nil` is not the same as `false`: the reader substitutes
  the documented default, and the writer's payload omits an untouched checkbox.
  """
  @spec boolean(term(), String.t() | nil, String.t(), boolean()) :: boolean()
  def boolean(nil, _provider_name, _field, default), do: default

  def boolean(value, _provider_name, _field, _default) when is_boolean(value), do: value

  def boolean(value, provider_name, field, _default) do
    raise "Provider #{provider_name}: invalid #{field} #{inspect(value)}: must be a boolean"
  end

  # The protocols `protocol/2` accepts: the set the two consumers implement
  # (`Nest.EndpointProbe.protocol_atom/1`, `Nest.LLM.MultimodalProbe.wire_format/1`).
  @protocols ["openai", "anthropic"]

  @doc """
  The protocols `protocol/2` accepts.

  Public because the GUI's editor has to offer the same set
  (`assets/js/components/providerConstants.js`'s `PROTOCOLS`) and the browser
  cannot read this module, so the list is written down twice.
  `Nest.DotConfigJsDefaultsTest` reads that file and fails when the two drift, so
  a protocol added here without the editor (or the reverse) is a test failure
  rather than a config refused at load for a value the editor offers.
  """
  @spec protocols() :: [String.t()]
  def protocols, do: @protocols

  @doc """
  A provider's `protocol`, or a raise. `nil` means the documented default,
  `"openai"`.

  The two consumers both have a catch-all that means `"openai"`
  (`Nest.EndpointProbe.protocol_atom/1`, `Nest.LLM.MultimodalProbe.wire_format/1`),
  so a `protocol = "bogus"` was silently OpenAI-compatible on both sides and
  nothing ever said so. The set is `protocols/0`'s.
  """
  @spec protocol(term(), String.t() | nil) :: String.t()
  def protocol(nil, _provider_name), do: "openai"

  def protocol(value, _provider_name) when value in @protocols, do: value

  def protocol(value, provider_name) do
    raise "Provider #{provider_name}: invalid protocol #{inspect(value)}: " <>
            "must be one of #{Enum.map_join(@protocols, ", ", &inspect/1)}"
  end

  @doc """
  A provider's name, or a raise.

  The name is the provider's key in `local.toml` and how it is addressed
  everywhere, so an absent, blank or whitespace-only one is not a provider. A
  blank name used to be accepted, and `{"name": ""}` and `{"name": null}`
  collapsed onto the same key, `[providers.""]`, so two different payloads
  produced one unaddressable provider; `" "` then slipped past the blank rule
  and persisted as `[providers." "]`, which undercut the wording of the rule it
  had just passed.

  Both sides call it. The reader's key is always a string, so the non-binary
  shapes are the writer's, but a whitespace-only *key* in a hand-written file is
  the same unaddressable provider and is refused at load like any other bad
  value.
  """
  @spec provider_name(term()) :: String.t()
  def provider_name(name) when is_binary(name) do
    if String.trim(name) == "" do
      raise "invalid provider name #{inspect(name)}: must be a non-empty string"
    else
      name
    end
  end

  def provider_name(name) do
    raise "invalid provider name #{inspect(name)}: must be a non-empty string"
  end

  @doc """
  A non-empty string, or a raise.

  Used for a provider's `probe-base-url`. `nil` is the caller's business — the
  reader substitutes the default, the writer omits the key — so each caller
  handles it before calling here.
  """
  @spec non_empty_string(term(), String.t() | nil, String.t()) :: String.t()
  def non_empty_string(value, provider_name, field) do
    if is_binary(value) and value != "" do
      value
    else
      raise "Provider #{provider_name}: invalid #{field} #{inspect(value)}: " <>
              "must be a non-empty string"
    end
  end

  @doc """
  Any string, or a raise.

  Used for a provider's `api-key`, whose only *value* rule is that it is text —
  an empty string and the documented `api-key = "none"` opt-out are both
  legitimate. Whether a reference-shaped key resolves is a separate question,
  answered by `Nest.DotConfig.KeyValidation` on the read side.
  """
  @spec string(term(), String.t() | nil, String.t()) :: String.t()
  def string(value, provider_name, field) do
    if is_binary(value) do
      value
    else
      raise "Provider #{provider_name}: invalid #{field} #{inspect(value)}: must be a string"
    end
  end
end
