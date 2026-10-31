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

  ## The slice is the caller's

  This module does **not** cut a message list. The caller passes the
  slice of `state.chat_state.messages` through the target message
  (`Enum.take_while/2` on `index`), and that is the whole input: the
  active list is everything since the last compaction, it holds no
  `{:compaction, _}` markers (the marker lands on the archived side of
  the boundary), and the archive is never part of a request. A caller
  that reaches an archived index has no request to show and answers
  `{:error, :archived}` rather than rebuilding from rows no request
  ever carried — see `Nest.Agents.Agent.IntrospectionHandler`.
  """

  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Runner
  alias Nest.Messages.Message

  @doc """
  Rebuild the request api_log for the user/tool message at
  `message_index`, from the caller's `slice` of the active message list.

  The returned log entry has the wire shape
  `%{id, timestamp, type: :request, payload}`. Two fields are the
  message's, not the fetch's:

    * `timestamp` is the target message's own timestamp (the slice's last
      element, by the caller's cut) — the widget shows when the request
      happened, not when it was re-read;
    * `max_tokens` is the cap the request *would* have used
      (`Dispatch.ordinary_max_tokens/2`), not the encoder's fallback.

  ## RunRequest defaults

  The request is built through `Nest.LLM.Runner.build_request/1`, the
  same funnel the live path uses, so the rebuilt wire format matches
  what was actually sent — including the derived `tool_choice`
  (`:auto` when the agent has tools, `:none` when it has none).
  `thinking_effort` comes from the agent's `client_config` so the
  rebuilt wire format matches the live request (the wire format
  excludes historical thinking blocks when thinking is off).
  `stream: true, metadata: %{}` mirror the live request defaults. The
  `opts` arg to `format_request_payload/2` is left empty: the wire
  format doesn't carry `base_url`/`api_key`, which are http concerns.
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
  def rebuild_request_api_logs(state, slice, message_index, %ClientConfig{} = client_config) do
    # The cap the live request would have used. `machine.work.ctx` — where the
    # turn keeps the model/limit pair — is reset at the end of every turn, so it
    # is rebuilt from the same two values in state.
    max_tokens =
      Dispatch.ordinary_max_tokens(client_config.model, state.llm_metrics.context_limit)

    request =
      Runner.build_request(%{
        messages: slice,
        tools: state.tools,
        tool_choice: :auto,
        client_config: client_config,
        max_tokens: max_tokens
      })

    # Wire format only — `opts` is for http concerns (base_url,
    # api_key) and intentionally omitted. The wire format the
    # live LLM client would receive is the same regardless of
    # the http call.
    payload = client_config.client.format_request_payload(request, [])

    %{
      id: format_sequence_id(message_index, 0),
      timestamp: request_timestamp(slice),
      type: :request,
      payload: payload
    }
  end

  # The log is stamped with the *message's* time: it is a reconstruction of the
  # request that carried that message, and the widget renders it as when that
  # request happened. The target message is the slice's last element by the
  # caller's cut (`index <= message_index`).
  #
  # Every appended row is stamped (`Turn.Messages`, `Turn.Dispatch`,
  # `Turn.Commit`), so an unstamped target is a caller bug rather than a case to
  # render: a fetch-time (or epoch) timestamp would be a lie the user cannot see
  # through, and this function has no way to tell "not yet stamped" from "never".
  defp request_timestamp(slice) do
    case List.last(slice) do
      {_role, %{timestamp: %DateTime{} = at}} ->
        at

      other ->
        raise ArgumentError,
              "rebuild_request_api_logs/4 needs the target message in the slice, " <>
                "stamped; got #{inspect(other)}"
    end
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
