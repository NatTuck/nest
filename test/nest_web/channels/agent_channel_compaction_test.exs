defmodule NestWeb.AgentChannelCompactionTest do
  @moduledoc """
  Regression test for Bug 5: the `AgentChannel` must handle
  the `chat:compaction` PubSub broadcast and forward it as
  a `chat:compaction` push to the socket.

  Pre-fix, `handle_info/2` had no clause for the
  `{:chat_compaction, _}` message, so every connected
  channel crashed with `FunctionClauseError` on every
  compaction, even when the DB write succeeded. The
  PubSub broadcast is sent by
  `Nest.Agents.Agent.Broadcasts.compaction/3` after
  `CompactionLifecycle.persist_and_broadcast/5` confirms
  the DB write; the JS side (`assets/js/channels.js:146`)
  subscribes to the `chat:compaction` event and uses it to
  render the compaction divider.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  setup :verify_on_exit!

  test "channel pushes chat:compaction to the socket on a chat_compaction broadcast", %{
    agent_id: agent_id,
    space_id: space_id
  } do
    # Drive the broadcast directly: the channel is
    # subscribed to `"agent:#{space_id}:#{agent_id}"` via the
    # `join/3` handler. Pre-fix, the channel process would crash
    # with `FunctionClauseError` on this broadcast (no
    # `handle_info({:chat_compaction, _}, _)` clause).
    # Top-level keys are atoms (mirroring
    # `Broadcasts.compaction/3`'s payload shape); inner
    # fields are strings (from `Message.to_json/1`).
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{space_id}:#{agent_id}",
      {:chat_compaction,
       %{
         marker: %{"index" => 5, "role" => "compaction", "archivedCount" => 3},
         history: [
           %{"index" => 0, "role" => "user", "content" => "old"}
         ]
       }}
    )

    assert_push "chat:compaction", payload, 200

    assert payload.marker["index"] == 5
    assert payload.marker["role"] == "compaction"
    assert payload.marker["archivedCount"] == 3
    assert length(payload.history) == 1
    assert hd(payload.history)["role"] == "user"
  end
end
