defmodule Nest.Scripts.CompactionProbeSupport do
  @moduledoc """
  Shared helpers for the compaction scripts:

    * `scripts/compact_agent_history.exs` — DB-level recovery for
      an agent whose in-process state is stuck mid-compaction.
    * `scripts/compaction_probe.exs` — diagnostic probe that
      replays the compactor's summarization call against the
      real LLM without committing anything to the database.

  Both scripts need to:

    1. Resolve a provider block from `~/.config/nest/config.toml`
       and build a `Nest.LLM.ClientConfig`.
    2. Build a `Nest.LLM.RunRequest` whose `messages` ends with a
       `[mode: compact] Summarize in your <N> remaining tokens.`
       suffix (the agent recognizes the prefix; the
       summarization contract itself lives in the `[Available modes]`
       list under the `compact` entry — see
       `Nest.Vocations.compact_description/0`).
    3. Run the request through `ClientConfig.client.run/2` and
       consume the resulting stream quietly (no PubSub, no
       broadcasts).

  Keeping these in one module ensures the probe exercises the
  exact same code path the live compactor uses. If the probe
  reports the LLM returning an empty summary, the production
  compactor will see the same empty string.
  """

  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer
  alias Nest.Messages.Part

  require Logger

  @doc """
  The per-call compactor suffix text: a one-liner that tells
  the agent to summarize in `<remaining_tokens>` tokens, with an
  optional `optional_guidance` clause (e.g. from the `:compact`
  tool's `focus` arg or a future `/compact <args>` slash
  command) appended when present.

  Format:
      [mode: compact] Summarize the conversation in your <N>
      remaining tokens. <optional_guidance?>
  """
  @spec compaction_suffix(non_neg_integer(), String.t() | nil) :: String.t()
  def compaction_suffix(remaining_tokens, optional_guidance) do
    base =
      "[mode: compact] Summarize the conversation in your " <>
        "#{remaining_tokens} remaining tokens."

    case optional_guidance do
      nil -> base
      "" -> base
      guidance -> base <> " " <> guidance
    end
  end

  @doc """
  Build the `{:user, _}` tuple the compactor appends to its
  request's messages. Wraps `compaction_suffix/2`.
  """
  @spec suffix_system_message(non_neg_integer(), String.t() | nil) ::
          {:user, Nest.Messages.User.t()}
  def suffix_system_message(remaining_tokens, optional_guidance) do
    {:user,
     %Nest.Messages.User{
       parts: [%Part.Text{text: compaction_suffix(remaining_tokens, optional_guidance)}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end

  @doc """
  Resolve a provider config from `DotConfig.load/0` and build
  a `ClientConfig` for the given model. Returns
  `{:ok, %ClientConfig{}, context_limit}` or `{:error, reason}`.

  The `context_limit` returned here is a 200k floor, matching
  the compactor's reference value for the 25% recent-slice
  threshold. The probe doesn't actually use it (it calls the
  LLM directly, not the compactor), but the recovery script
  does, so we return it for symmetry.
  """
  @spec build_client_config(map()) :: {:ok, ClientConfig.t(), pos_integer()} | {:error, term()}
  def build_client_config(model_map) do
    normalized = normalize_model(model_map)
    %{"name" => model_name} = normalized
    provider_name = Map.get(normalized, "provider") || "minimax"

    with {:ok, dotconfig} <- DotConfig.load(),
         %DotConfig.Provider{} = provider <- DotConfig.get_provider(dotconfig, provider_name),
         {:ok, %ClientConfig{} = cc} <- ChatModel.build_client_config(provider, model_name) do
      Logger.info("Built client config: model=#{cc.model} base_url=#{cc.base_url}")

      # 200k floor: gives the compactor headroom on a 200k-context
      # model; smaller models still work because the actual
      # recent-slice size is what triggers the tail summary.
      context_limit = 200_000

      {:ok, cc, context_limit}
    else
      nil -> {:error, {:provider_not_in_dotconfig, provider_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Persisted models are stored as `%{name: "..."}` (atom keys)
  # but the dotconfig helpers take string keys. Normalize both
  # directions so callers can pass either.
  defp normalize_model(model) when is_map(model) do
    Map.new(model, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {Atom.to_string(k), v}
    end)
  end

  @doc """
  Build the LLM callback the compactor expects:
  `[Message.t()] -> {:ok, String.t()} | {:error, term()}`.

  The callback appends the precomputed `[mode: compact]`
  suffix system message (built by
  `Nest.Tokens.Compactor.compute_summary_budget/4`) to the
  agent's messages list (preserving the agent's own system
  prompt at position 0), runs a streaming `RunRequest`, and
  consumes the stream quietly (no PubSub). Returns
  `{:ok, text}` (possibly empty) or `{:error, reason}`.

  `compaction_pid` is a sink for delta notifications so the
  caller (typically a `Task`) can observe streaming progress
  without subscribing to PubSub. The probe passes `self()`;
  the production compactor passes the Task's pid.

  The `rendered_suffix` argument is the
  `{:user, %User{}}` tuple returned by
  `compute_summary_budget/4` — already sized so its token
  cost matches the budget the compactor's N was computed
  against.
  """
  @spec build_summarization_llm_call(
          ClientConfig.t(),
          pid(),
          {:user, Nest.Messages.User.t()}
        ) :: (... -> {:ok, String.t()} | {:error, term()})
  def build_summarization_llm_call(
        %ClientConfig{} = client_config,
        compaction_pid,
        rendered_suffix
      ) do
    fn messages, _remaining_tokens, _optional_guidance ->
      # The suffix is closed over (already sized and rendered);
      # the compactor's 3-arity contract accepts the trailing
      # args for symmetry but they don't change the wire payload.
      request = %RunRequest{
        messages: messages ++ [rendered_suffix],
        tools: nil,
        tool_choice: :none,
        model: client_config.model,
        stream: true,
        metadata: %{}
      }

      opts = [
        base_url: client_config.base_url,
        api_key: client_config.api_key,
        receive_timeout: client_config.receive_timeout
      ]

      case client_config.client.run(request, opts) do
        {:ok, stream} -> consume_quietly(stream, compaction_pid)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Consume a streaming response without broadcasting. Returns
  # `{:ok, text}` (possibly empty) or `{:error, reason}`. The
  # compactor's `require_summary/1` converts an empty string
  # to `{:error, :llm_returned_empty}`, which is exactly the
  # error we want the probe to surface.
  @spec consume_quietly(Enumerable.t(), pid()) :: {:ok, String.t()} | {:error, term()}
  def consume_quietly(stream, _compaction_pid) do
    consumer = %StreamConsumer{
      on_text: fn _text, sent -> sent end,
      on_thinking: fn _text, sent -> sent end,
      on_signature: fn _sig -> :ok end
    }

    {_acc, response, error, _sent} = StreamConsumer.reduce(stream, consumer)

    cond do
      not is_nil(error) -> {:error, error}
      match?(%RunResponse{}, response) -> {:ok, response.text || ""}
      true -> {:error, :no_response}
    end
  end
end
