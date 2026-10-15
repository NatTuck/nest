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
