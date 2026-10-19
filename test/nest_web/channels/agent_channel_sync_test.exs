defmodule NestWeb.AgentChannelSyncTest do
  @moduledoc """
  Unit tests for the `chat:sync` reply shaper.

  Two things are under test: the bounded prefix itself, and the cost property
  that is the reason the module takes a single pass — a reply may format only
  the messages it carries (issue #52). The second one is what the injectable
  formatter exists to observe.
  """
  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias NestWeb.AgentChannel.Sync

  defp message(index) do
    parts = [%Part.Text{text: "m#{index}"}]

    if rem(index, 2) == 0 do
      {:user, %User{index: index, parts: parts, api_logs: []}}
    else
      {:assistant, %Assistant{index: index, parts: parts, api_logs: []}}
    end
  end

  defp messages(count), do: for(i <- 0..(count - 1), do: message(i))

  # A formatter that records every message it is asked to format, so the
  # cost property is observable: the reply may format its kept messages plus
  # one rejected candidate, and nothing else. It runs in the calling process
  # (the shaper is a pure function), so the record is the process dictionary
  # rather than a mailbox.
  defp recording_formatter do
    fn {_role, %{index: index}} ->
      Process.put(:formatted, [index | Process.get(:formatted, [])])
      %{"index" => index}
    end
  end

  defp formatted do
    :formatted |> Process.get([]) |> Enum.reverse()
  end

  # The wire size of one formatted message, computed the same way the reply
  # computes it: by encoding it.
  defp one_message_bytes do
    %{"index" => 0} |> Jason.encode!() |> byte_size()
  end

  test "returns nothing for an empty list" do
    assert Sync.take([], 1_000) == {[], 0}
  end

  test "keeps the prefix that fits the limit" do
    limit = one_message_bytes() * 3

    {kept, bytes} = Sync.take(messages(10), limit, recording_formatter())

    assert Enum.map(kept, & &1["index"]) == [0, 1, 2]
    assert bytes == limit
  end

  test "formats only the kept messages plus one rejected candidate" do
    # The property the single pass exists for. The old implementation mapped
    # `format_message/1` over every message above lastIndex on every batch, so
    # a cold drain re-formatted the whole remaining window ~240 times.
    Sync.take(messages(10), one_message_bytes() * 3, recording_formatter())

    assert formatted() == [0, 1, 2, 3]
  end

  test "keeps at least one message when a single message exceeds the limit" do
    # One oversized message must not wedge the drain: the client would ask
    # again from the same lastIndex forever.
    {kept, bytes} = Sync.take(messages(3), 0, recording_formatter())

    assert Enum.map(kept, & &1["index"]) == [0]
    assert bytes == one_message_bytes()
  end

  test "reports the combined wire size of what it keeps" do
    {kept, bytes} = Sync.take(messages(4), 1_000_000)

    assert bytes == kept |> Enum.map(&(Jason.encode!(&1) |> byte_size())) |> Enum.sum()
  end
end
