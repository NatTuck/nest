defmodule Nest.DotConfig.KeyValidation do
  @moduledoc """
  Resolves provider `api-key` references at config-load time.

  A provider's `api-key` may be a `${ENV_VAR}` or `file:...` reference whose
  value only exists at runtime. Every consumer resolves it lazily and must
  never raise over it, so the one place that can name *which* provider is
  broken is here, at load time. Only a reference-shaped key is resolved: a
  literal key (including the documented `api-key = "none"` opt-out), an empty
  key, and an absent key are all legitimate and pass through untouched.

  The resolver is **injected** rather than reached through
  `Nest.DotConfig.resolve_api_key/1`. `Nest.DotConfig` is Mimic-wrapped: a
  remote `Nest.DotConfig.resolve_api_key/1` goes through the proxy and would
  pick up any stub, so the caller passes a local capture
  (`&resolve_api_key/1`), which stays bound to the original module and calls
  the real resolver.
  """

  alias Nest.DotConfig.Provider

  @doc """
  Validates every provider's `api-key` in a `Nest.DotConfig.load/0` result.

  `resolve` is the one-argument key resolver invoked for a reference-shaped
  key. The load result is returned unchanged on success (and an error is
  passed through untouched); an unresolvable reference raises, naming the
  provider.
  """
  @spec validate({:ok, map()} | {:error, term()}, (term() -> term())) ::
          {:ok, map()} | {:error, term()}
  def validate({:ok, config}, resolve) do
    Enum.each(Map.values(config.providers), &validate_provider_key(&1, resolve))
    {:ok, config}
  end

  def validate({:error, reason}, _resolve), do: {:error, reason}

  defp validate_provider_key(%Provider{name: name, api_key: key}, resolve)
       when is_binary(key) do
    if reference_key?(key), do: resolve_reference_key!(name, key, resolve), else: :ok
  end

  defp validate_provider_key(%Provider{}, _resolve), do: :ok

  defp reference_key?(key),
    do: String.starts_with?(key, "${") or String.starts_with?(key, "file:")

  defp resolve_reference_key!(provider_name, key, resolve) do
    resolve.(key)
    :ok
  rescue
    error in RuntimeError ->
      reraise "Provider #{provider_name}: cannot resolve api-key #{inspect(key)}: " <>
                Exception.message(error),
              __STACKTRACE__
  end
end
