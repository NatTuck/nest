defmodule NestWeb.AgentChannelSyncBatchingTest do
  @moduledoc """
  `chat:sync` batching, end to end (issue #52).

  A cold-cache drain costs the client a frame parse, a merge, a sort and a
  full re-render **per batch**, so the batch count — not the server's shaping
  work — is what makes switching to an agent with a long conversation slow.
  These tests pin the reply budget and the drain's completeness, which is what
  the budget has to preserve.

  The shaper's own branches are pinned in `NestWeb.AgentChannelSyncTest`,
  including the one message larger than the whole limit: it must still be sent,
  or the client would ask again from the same `lastIndex` forever.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  alias Nest.Agents.Supervisor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

  # The suite's fence, deliberately above the 500 ms default because this file's
  # fixtures are large. Measured with `--cover --trace`, which is the
  # instrumentation a full precommit runs under: the single-reply case took
  # 23.7 ms, the drain's two round trips 114.7 + 215.7 ms, and a 500 ms fence
  # was observed to fail under load. The cost is the fixture's own JSON encode
  # plus `Supervisor.get_agent/2` startup (`seed_active/4` below), not the
  # reply, which carries at most one budget's worth (~1 MiB).
  @reply_timeout 1_000

  # A message of roughly `bytes` wire bytes.
  defp message(index, bytes) do
    parts = [%Part.Text{text: String.duplicate("m", bytes)}]

    if rem(index, 2) == 0 do
      {:user, %User{index: index, parts: parts, api_logs: []}}
    else
      {:assistant, %Assistant{index: index, parts: parts, api_logs: []}}
    end
  end

  defp seed_active(space_id, name, count, bytes) do
    {:ok, pid} = Supervisor.get_agent(space_id, name)
    messages = for i <- 0..(count - 1), do: message(i, bytes)

    :sys.replace_state(
      pid,
      fn state -> put_in(state.chat_state.messages, messages) end,
      1_000
    )
  end

  defp sync(socket, last_index) do
    ref = push(socket, "chat:sync", %{"lastIndex" => last_index})
    assert_reply ref, :ok, reply, @reply_timeout
    reply["messages"]
  end

  defp wire_bytes(messages), do: messages |> Jason.encode!() |> byte_size()

  # Drain the way the client's recursion does: sync from the highest index seen
  # until a reply comes back empty. Returns each reply's wire size, and
  # everything the drain delivered.
  defp drain(socket, last_index, sizes \\ [], acc \\ []) do
    case sync(socket, last_index) do
      [] ->
        {Enum.reverse(sizes), Enum.reverse(acc)}

      messages ->
        highest = messages |> Enum.map(& &1["index"]) |> Enum.max()
        drain(socket, highest, [wire_bytes(messages) | sizes], Enum.reverse(messages) ++ acc)
    end
  end

  test "a reply bigger than the old 64 kB cap arrives in one batch", %{
    socket: socket,
    space_id: space_id,
    agent_id: agent_id
  } do
    # 5 x ~30 kB is ~150 kB: comfortably over the old `@sync_size_limit` of
    # 65_536, and well under the current one. This is the regression test for
    # the batch count — with the old cap this took three round trips.
    seed_active(space_id, agent_id, 5, 30_000)

    messages = sync(socket, -1)

    assert length(messages) == 5
    assert wire_bytes(messages) > 65_536
  end

  test "a cold drain returns every active message, in order, exactly once, within budget", %{
    socket: socket,
    space_id: space_id,
    agent_id: agent_id
  } do
    # 40 x ~30 kB is ~1.2 MB: more than one budget's worth, so every reply must
    # be cut at the budget — and the cut must not drop or repeat a message.
    seed_active(space_id, agent_id, 40, 30_000)

    {sizes, messages} = drain(socket, -1)

    # The batch count is the regression (#52), so it is pinned, not bounded.
    assert length(sizes) == 2
    assert Enum.all?(sizes, &(&1 <= 1_048_576))
    assert Enum.map(messages, & &1["index"]) == Enum.to_list(0..39)
  end
end
