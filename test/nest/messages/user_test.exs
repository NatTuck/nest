defmodule Nest.Messages.UserTest do
  @moduledoc """
  Tests for the `origin` marker on `Nest.Messages.User`.

  The Ctrl/Cmd+Up recall list includes a user row only when it carries
  `origin: "human"` (fail-closed), so the marker must survive `to_json/1` and
  must be *absent* for every untagged row — otherwise a delivered or legacy
  message would be indistinguishable from a human prompt.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Part
  alias Nest.Messages.User

  test "human_metadata/0 is the marker the client filter matches" do
    assert User.human_metadata() == %{"origin" => "human"}
  end

  test "to_json/1 exposes origin when the message carries it" do
    json =
      User.to_json(%User{
        index: 1,
        parts: [%Part.Text{text: "[mode: build]\nhi"}],
        metadata: Map.merge(%{"mode" => "build"}, User.human_metadata()),
        api_logs: []
      })

    assert json["origin"] == "human"
    assert json["mode"] == "build"
    assert json["role"] == "user"
  end

  test "to_json/1 omits origin for an untagged row" do
    json =
      User.to_json(%User{
        index: 1,
        parts: [%Part.Text{text: "[mode: build]\nhi"}],
        metadata: %{"mode" => "build"},
        api_logs: []
      })

    refute Map.has_key?(json, "origin")
    assert json["mode"] == "build"
  end

  test "to_json/1 omits origin when metadata is nil" do
    json =
      User.to_json(%User{
        index: 1,
        parts: [%Part.Text{text: "[mode: build]\nhi"}],
        metadata: nil,
        api_logs: []
      })

    refute Map.has_key?(json, "origin")
    assert json["mode"] == nil
  end
end
