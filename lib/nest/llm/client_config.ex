defmodule Nest.LLM.ClientConfig do
  @moduledoc """
  Carries the per-agent LLM client configuration.

  `client` is the module that implements the `Nest.LLM.Client`
  behavior. `base_url`, `api_key`, `model`, and `receive_timeout`
  are passed to the client at call time via the opts list.
  """

  defstruct client: nil,
            base_url: nil,
            api_key: nil,
            model: nil,
            receive_timeout: nil

  @type t :: %__MODULE__{
          client: module() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          model: String.t() | nil,
          receive_timeout: non_neg_integer() | nil
        }
end
