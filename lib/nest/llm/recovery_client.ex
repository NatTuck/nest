defmodule Nest.LLM.RecoveryClient do
  @moduledoc """
  Inert LLM client used when an agent's persisted `model` no longer
  resolves to a runtime provider — e.g. the model was removed from
  `~/.config/nest/config.toml` while the agent row stayed in the DB.

  The agent's `Agent.init/1` constructs a `%ClientConfig{client: RecoveryClient}`
  in this situation so the GenServer can still start (with
  `live.status == :model_missing`). The runtime channel and
  GenServer blocks inbound `chat:message` traffic while in this
  state, so `run/2` is never invoked in normal operation.

  ## Why not just `:stop` the GenServer?

  Earlier behavior crashed the agent on `Config.create_client_config`
  errors. Concretely that meant a user who removed a provider from
  their config saw the row silently disappear from the lobby list
  (`Agents.list_agents_info/0` filters out unloadable agents), with
  no path to load or repair it from the UI. The recovery flow:
  surfaces the broken row in the lobby's `broken_agents` payload
  and in `ChatPage.jsx`'s "model unavailable" banner; lets the user
  call `Agents.change_model/2` to transition back to `:idle` with
  a fresh `ClientConfig`.

  ## Wire-format obligations

  `format_request_payload/2` exists because some code paths build a
  wire-format payload asynchronously (api_log rebuilds on restore,
  preflight). The payload mirrors an OpenAI-shape request so
  downstream code that pattern-matches on JSON structure keeps
  working — but it is never sent over the network.
  """

  @behaviour Nest.LLM.Client

  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse

  @impl Nest.LLM.Client
  def run(%RunRequest{}, _opts) do
    # This branch is only reachable if an internal code path
    # bypasses the `:model_missing` channel/GenServer guard (e.g.
    # a regression that lets the agent spawn a chat turn without
    # flipping status to `:idle`). Surface a plain text reply that
    # downstream consumers can fold into the assistant accumulator.
    text =
      "Model is no longer available. Pick a replacement from the " <>
        "model selector above to continue."

    response = %RunResponse{text: text, stop_reason: "stop"}

    stream =
      Stream.map(
        [{:text, text}, {:finish_reason, "stop"}, {:done, %{response: response}}],
        & &1
      )

    {:ok, stream}
  end

  @impl Nest.LLM.Client
  def format_request_payload(%RunRequest{} = req, _opts) do
    %{
      "model" => req.model,
      "messages" => [],
      "stream" => req.stream,
      "_recovery" => true
    }
  end
end
