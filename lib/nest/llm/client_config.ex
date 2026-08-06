defmodule Nest.LLM.ClientConfig do
  @moduledoc """
  Carries the per-agent LLM client configuration.

  `client` is the module that implements the `Nest.LLM.Client`
  behavior. `base_url`, `api_key`, `model`, and `receive_timeout`
  are passed to the client at call time via the opts list.

  `probe_base_url` is the optional URL used by *model discovery*
  (`Nest.LLM.Discover`) — `GET <probe_base_url>/models` — when a
  provider exposes a different listing path from its chat path
  (e.g. an Olla-shaped discovery endpoint separate from the
  OpenAI-compatible chat endpoint). Defaults to `nil`; discovery
  then reuses `base_url`.
  """

  defstruct client: nil,
            base_url: nil,
            api_key: nil,
            model: nil,
            receive_timeout: nil,
            probe_base_url: nil

  @type t :: %__MODULE__{
          client: module() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          model: String.t() | nil,
          receive_timeout: non_neg_integer() | nil,
          probe_base_url: String.t() | nil
        }
end
