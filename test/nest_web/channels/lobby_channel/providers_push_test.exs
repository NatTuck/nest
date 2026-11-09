defmodule NestWeb.LobbyChannel.ProvidersPushTest do
  @moduledoc """
  The `providers_updated` push helper the lobby's provider tests assert through.

  `Providers.save/2` broadcasts on the process-global `"lobby"` topic, so a test
  joined to it receives every other joined test's save as well. `assert_push`
  takes the first frame with that event — which may not be this save's — so those
  tests wait for the frame that names their own providers instead
  (`NestWeb.LobbyChannelTestHelpers.assert_providers_updated/2`). This pins the
  helper's two branches: the frame it skips, and the failure when nothing names
  what was asked for.
  """

  use ExUnit.Case, async: true

  import NestWeb.LobbyChannelTestHelpers

  test "ignores another save's frame, and fails rather than accept a wrong one" do
    # The topic is process-global, so another test's save can be the first
    # `providers_updated` frame in this mailbox. The helper must skip it.
    push = fn names ->
      %Phoenix.Socket.Message{
        topic: "lobby",
        event: "providers_updated",
        payload: %{providers: Enum.map(names, &%{"name" => &1})},
        ref: nil,
        join_ref: nil
      }
    end

    send(self(), push.(["someone-else"]))
    send(self(), push.(["mine"]))

    assert %{providers: [%{"name" => "mine"}]} = assert_providers_updated(["mine"])

    # And a frame that names something else is never accepted as ours.
    send(self(), push.(["someone-else"]))
    assert_raise ExUnit.AssertionError, fn -> assert_providers_updated(["absent"], 0) end
  end
end
