defmodule Nest.DotConfig.Model do
  @moduledoc """
  Model configuration struct.

  One entry of a provider's `models` list (`[[providers.<name>.models]]`), or of
  the flat `config.models` map `Nest.DotConfig.load/0` returns.

  `context_limit` is the model's context window when the config names it;
  `nil` means "not known here", which leaves the provider's
  `default_context_limit` and then the discovery cache to answer. `multi_modal`
  is a three-state claim (`true`/`false`/`nil` for "not stated"), and
  `thinking_effort` is one of `Nest.DotConfig`'s thinking levels, or `nil` for
  the global default.
  """

  defstruct [
    :name,
    :provider_name,
    :context_limit,
    :multi_modal,
    :thinking_effort
  ]
end
