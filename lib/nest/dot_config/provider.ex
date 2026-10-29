defmodule Nest.DotConfig.Provider do
  @moduledoc """
  Provider configuration struct.

  `first_byte_timeout_seconds` and `stream_idle_timeout_seconds` are the two
  per-provider silence bounds, in seconds. They used to be one number
  (`timeout_seconds`), which conflated two different silences:

    * `first_byte_timeout_seconds` bounds the silence *before the first
      streamed chunk* — prefill of a long context after a cache miss, a cold
      model, provider-side queueing. Defaults to
      `Nest.DotConfig.@default_first_byte_timeout_seconds` (900s = 15
      minutes) when not set in the config file.
    * `stream_idle_timeout_seconds` bounds the silence *between chunks once
      streaming*. Defaults to
      `Nest.DotConfig.@default_stream_idle_timeout_seconds` (120s = 2
      minutes) when not set.

  The old `timeout` key is a back-compat alias for `first_byte_timeout`: an
  existing `timeout = 600` keeps meaning "the prefill may take 10 minutes",
  and does *not* become the idle bound (which would make every dead-connection
  failure take 10 minutes to notice). `first_byte_timeout` wins when both keys
  are present.

  `default_context_limit` is the optional provider-wide fallback for
  `context-window` size, used when neither the per-model
  `[[providers.<name>.models]]` block nor the auto-discovery cache
  carries a value. Parsed from the optional `default-context-limit`
  TOML key on `[providers.<name>]`. `nil` when absent.

  `probe_base_url` is the optional URL used for *model discovery*
  only (`GET <base>/models`). Defaults to `nil`, in which case
  `base_url` is used for both chat and discovery. Set this on
  providers whose chat base and discovery base diverge — e.g. an
  Olla-style discovery listing at one path and OpenAI-compatible
  chat at another. Parsed from the optional `probe-base-url`
  TOML key. See `Nest.LLM.Discover` and `Nest.ChatModel`.

  `auto_probe` is the optional flag that enables endpoint probing
  (`Nest.EndpointProbe` + `Nest.EndpointCache`) for this provider.
  Defaults to `true`. When enabled, the chat protocol, chat base
  URL, and discovery `/models` path are auto-detected at startup
  and re-detected when a cached endpoint starts returning `404`.
  Set `auto-probe = false` on a provider you'd rather configure
  fully by hand. Parsed from the optional `auto-probe` TOML key.

  `expose_models` is the optional flag that makes this provider's
  models visible in the `models-list` tool output. Defaults to
  `false`. Set `expose-models = true` on providers whose models
  should be discoverable by agents via the `models-list` tool.

  `probe_multimodal` is the optional opt-in that lets discovery
  probe a model's image-input support (`Nest.LLM.MultimodalProbe`)
  when the provider's `/models` body leaves it unknown. Defaults to
  `false`. It never overrides a definite answer from the metadata:
  a provider that publishes a modality list, or an Anthropic-style
  capability flag, is believed as-is. Parsed from the optional
  `probe-multimodal` TOML key.
  """
  defstruct [
    :name,
    :base_url,
    :api_key,
    :protocol,
    :auto_models,
    :tags,
    :models,
    :first_byte_timeout_seconds,
    :stream_idle_timeout_seconds,
    :default_context_limit,
    :default_thinking_effort,
    :probe_base_url,
    :expose_models,
    probe_multimodal: false,
    auto_probe: true
  ]
end

defmodule Nest.DotConfig.Model do
  @moduledoc "Model configuration struct"
  defstruct [
    :name,
    :provider_name,
    :context_limit,
    :multi_modal,
    :thinking_effort
  ]
end
