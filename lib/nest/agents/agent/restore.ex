defmodule Nest.Agents.Agent.Restore do
  @moduledoc """
  Request-log rebuild helper. Lives outside `Nest.Agents.Agent`
  to keep that GenServer module under the 500-line credo limit.

  ## What it does

  Request logs are synthetic: `:user` and `:tool` messages never
  carry them (in memory, in the DB, or on the wire). When the
  user expands the API logs widget on such a message,
  `rebuild_request_api_logs/4` replays the request-payload build
  through the agent's configured client
  (`client.format_request_payload/2`) to reconstruct what the API
  request would have looked like at that point.

  ## Compaction markers

  The preloaded sequence returned by `Persistence.load_messages/1`
  carries `{:compaction, _}` markers inline — the partition into
  `history` vs `messages` happens at agent-init, not at load.
  The rebuild path filters `{:compaction, _}` tuples out of
  the slice before passing to `client.format_request_payload/2`
  because `OpenAIClient.message_to_wire/1` has no clause for
  `:compaction` (the live path avoids this because it draws
  requests from `state.chat_state.messages`, which excludes
  compaction markers). See `rebuild_request_api_logs/4`.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Message

  @doc """
  Rebuild the request api_log for the user/tool message at the
  given index. Walks the slice `Enum.take(messages, idx + 1)`
  from the preloaded sequence to construct the request
  payload, then defers to the agent's configured client.

  The returned log entry has the wire shape
  `%{id, timestamp, type: :request, payload}`.

  ## RunRequest defaults

  `tool_choice: :auto` matches the agent's standard chat
  config (vocation changes mid-conversation aren't supported
  elsewhere). `thinking_effort` comes from the agent's
  `client_config` so the rebuilt wire format matches the live
  request (the wire format excludes historical thinking blocks
  when thinking is off). `stream: true, metadata: %{}` mirror
  the live request defaults. The `opts` arg to
  `format_request_payload/2` is left empty: the wire format
  doesn't carry `base_url`/`api_key`, which are http concerns.
  """
  @spec rebuild_request_api_logs(
          Nest.Agents.Agent.t(),
          [Message.t()],
          non_neg_integer(),
          ClientConfig.t()
        ) :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          type: :request,
          payload: map()
        }
  def rebuild_request_api_logs(state, messages, message_index, %ClientConfig{} = client_config) do
    # Filter `{:compaction, _}` markers out of the slice before
    # the wire-format call. Compaction markers are runtime
    # bookkeeping (they live in `state.chat_state.history`,
    # never in `state.chat_state.messages`) and never reach
    # the LLM in the live path. The preloaded sequence we get
    # here is the full DB sequence (compaction markers inline),
    # so a user/tool index whose slice crosses a marker would
    # otherwise crash `OpenAIClient.message_to_wire/1` — that
    # was the `entire-ox` production regression on BEAM restart.
    slice =
      messages
      |> Enum.take(message_index + 1)
      |> Enum.reject(&match?({:compaction, _}, &1))

    request = %RunRequest{
      messages: slice,
      tools: state.tools,
      tool_choice: :auto,
      model: client_config.model,
      thinking_effort: client_config.thinking_effort,
      stream: true,
      metadata: %{}
    }

    # Wire format only — `opts` is for http concerns (base_url,
    # api_key) and intentionally omitted. The wire format the
    # live LLM client would receive is the same regardless of
    # the http call.
    payload = client_config.client.format_request_payload(request, [])

    %{
      id: format_sequence_id(message_index, 0),
      timestamp: DateTime.utc_now(),
      type: :request,
      payload: payload
    }
  end

  # Request api_logs for user/tool messages are never attached or stored —
  # they're synthetic and rebuilt on demand via `get_api_logs` when the user
  # expands the API logs widget. The response logs on assistant and system
  # messages are persisted and loaded from the DB directly.

  # Format a sequence id the same way
  # `Broadcasts.next_api_log_id/2` does: zero-padded
  # `<message_index>.<sequence>` (3 digits each). The JS uses
  # `key={log.timestamp}` rather than `log.id`, so id drift is
  # harmless for React reconciliation; preserving the format
  # keeps the wire shape uniform across live and rebuilt logs.
  @spec format_sequence_id(non_neg_integer(), non_neg_integer()) :: String.t()
  defp format_sequence_id(message_index, sequence) do
    :io_lib.format("~3..0B.~3..0B", [message_index, sequence])
    |> IO.iodata_to_binary()
  end
end
