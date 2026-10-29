defmodule Nest.LLM.ClientConfig do
  @moduledoc """
  Carries the per-agent LLM client configuration.

  `client` is the module that implements the `Nest.LLM.Client`
  behavior. `base_url`, `api_key`, `model`, `first_byte_timeout` and
  `stream_idle_timeout` are passed to the client at call time via the
  opts list.

  The two timeouts (in milliseconds) are the two silences a streaming
  request can suffer, kept apart because they mean opposite things:
  `first_byte_timeout` is how long the provider may be silent before
  the first chunk (prefill of a long context after a cache miss, a cold
  model, provider-side queueing) and `stream_idle_timeout` is how long
  it may be silent between chunks once streaming. One number for both
  either kills a legitimate prefill or delays noticing a dead
  connection by the same amount.

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
            first_byte_timeout: nil,
            stream_idle_timeout: nil,
            probe_base_url: nil,
            thinking_effort: nil

  @type t :: %__MODULE__{
          client: module() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          model: String.t() | nil,
          first_byte_timeout: non_neg_integer() | nil,
          stream_idle_timeout: non_neg_integer() | nil,
          probe_base_url: String.t() | nil,
          # Normalized thinking level (:off | :low | :medium | :high |
          # :xhigh), resolved from the agent's model map + config.
          thinking_effort: atom() | nil
        }
end
