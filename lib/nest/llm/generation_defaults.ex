defmodule Nest.LLM.GenerationDefaults do
  @moduledoc """
  Model-name-based generation defaults shared by every LLM client.

  Some models need explicit sampling parameters to behave well, but a
  provider may be reached over either the OpenAI-compatible or the
  Anthropic protocol. Keeping these rules here — rather than inside a
  single client — ensures a model gets the same defaults regardless of
  which protocol the provider was probed as.

  Every request-rendering path (the live call, the api_log, restored
  logs, and compaction) goes through the client's
  `format_request_payload/2`, so these defaults apply uniformly and
  stay visible in the UI.
  """

  # DeepSeek's `flash` models need an explicit `top_p` and `max_tokens`
  # to behave, so the clients fill them in when the model name matches
  # (case-insensitive) and the caller didn't set a value.
  @deepseek_flash_regex ~r/deepseek.*flash/i
  @deepseek_flash %{top_p: 0.95, max_tokens: 32_000}

  @doc """
  Default generation parameters for `model`, keyed by `:top_p` and
  `:max_tokens`. Returns `%{}` when the model has no known defaults.
  """
  @spec for_model(String.t() | nil) :: %{
          optional(:top_p) => float(),
          optional(:max_tokens) => pos_integer()
        }
  def for_model(model) when is_binary(model) do
    if Regex.match?(@deepseek_flash_regex, model), do: @deepseek_flash, else: %{}
  end

  def for_model(_model), do: %{}

  @doc """
  Default `:max_tokens` for `model`, or `nil` when there is none.
  """
  @spec default_max_tokens(String.t() | nil) :: pos_integer() | nil
  def default_max_tokens(model), do: for_model(model)[:max_tokens]

  @doc """
  Default `:top_p` for `model`, or `nil` when there is none.
  """
  @spec default_top_p(String.t() | nil) :: float() | nil
  def default_top_p(model), do: for_model(model)[:top_p]
end
