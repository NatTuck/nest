defmodule NestWeb.AgentChannel.Replies do
  @moduledoc """
  How the agent channel answers a control-plane call: the `{:ok, ...}` /
  `{:error, ...}` reply every `chat:*` handler builds.

  Split out of `NestWeb.AgentChannel` to keep that module under the file cap.
  Every error goes through `NestWeb.ErrorPayload`, because a reason carrying a
  detail term (`{:config_file_not_regular, path, type}`) is not `to_string/1`-able, and
  raising inside a channel leaves the client with no reply at all.
  """

  alias NestWeb.ErrorPayload

  # The optional `/compact <focus>` argument: an omitted key, a non-string, or a
  # blank string all mean "no operator guidance".
  def optional_focus(%{"focus" => focus}) when is_binary(focus) and focus != "", do: focus
  def optional_focus(_payload), do: nil

  # A non-binary mode is "no mode requested" rather than a value on the wire (the
  # browser contract is string-or-null; `Inbox.put_entry/8` also guards).
  def requested_mode(payload) do
    case Map.get(payload, "mode") do
      mode when is_binary(mode) -> mode
      _ -> nil
    end
  end

  # The channel only maps the agent's reply: the agent is the disposition
  # authority (it queues the message while it is busy).
  def reply_chat(socket, :ok), do: {:reply, {:ok, %{}}, socket}

  # One spelling for every refusal, `chat_message_reason/1` included: `:not_found`
  # is `agent_not_found` and `:archived` is `agent_archived` whichever of
  # `get_info/2` or `chat/6` produced them, rather than depending on the caller.
  def reply_chat(socket, {:error, reason}),
    do: reply_err(chat_message_reason(reason), socket)

  # The control-plane calls (`compact`, `retry-compaction`, `stop`, …). A
  # non-idle agent is the one refusal with its own spelling.
  def reply_control(:ok, socket), do: {:reply, {:ok, %{}}, socket}
  def reply_control({:error, :not_found}, socket), do: reply_err("agent_not_found", socket)
  def reply_control({:error, {:not_idle, s}}, socket), do: reply_err("agent_status_#{s}", socket)
  def reply_control({:error, reason}, socket), do: reply_err(reason, socket)

  defp reply_err(reason, socket), do: {:reply, {:error, ErrorPayload.from_reason(reason)}, socket}

  # The two refusals `chat:message` spells differently from the atom's own name:
  # `:not_found` is `agent_not_found` on this channel, and an archived agent has
  # its own code because its row must not be resurrected to answer. Both are
  # reached through `chat:message`'s generic `{:error, reason}` arm — the handler
  # used to have an arm each, and folding them here is what let that `case` stay
  # inside credo's complexity bound.
  def chat_message_reason(:not_found), do: "agent_not_found"
  def chat_message_reason(:archived), do: "agent_archived"
  def chat_message_reason(reason), do: reason
end
