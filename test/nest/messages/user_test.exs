defmodule Nest.Messages.UserTest do
  @moduledoc """
  Tests for the two markers a `Nest.Messages.User` row carries in metadata: the
  `origin` of the row, and which of its parts are command output.

  The Ctrl/Cmd+Up recall list includes a user row only when it carries
  `origin: "human"` (fail-closed), so the marker must survive `to_json/1` and
  must be *absent* for every untagged row — otherwise a delivered or legacy
  message would be indistinguishable from a human prompt.

  `"commandOutputParts"` (issue #139) is the other one: the indexes into
  `"parts"` whose text is a backgrounded shell command's output, which the
  client renders verbatim instead of as markdown. It too is omitted when there
  is nothing to mark, so a row without command output keeps the payload shape
  it always had.
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

  describe "command_output_metadata/1 and the commandOutputParts key" do
    test "names the indexes of the row's output segments, and only those" do
      # A drained batch row is one text part per rendered body plus one per
      # backgrounded command's output (issue #139). The metadata says which
      # parts the client must render as command output, and it is a list of
      # positions — so a note in front of a notice moves the index, which is why
      # it is computed from the ordered segments rather than assumed.
      assert User.command_output_metadata([
               {:text, "peer note"},
               {:text, "Your backgrounded command (shell-cmd) finished. Its result:\n\n"},
               {:output, "# output\n"},
               {:text, "and another body"},
               {:output, "more"}
             ]) == %{"command_output_parts" => [2, 4]}

      assert User.command_output_metadata([{:text, "no output here"}]) == %{}
      assert User.command_output_metadata([]) == %{}
    end

    test "to_json/1 exposes commandOutputParts when the row carries it" do
      json = json_for(%{"mode" => "act", "command_output_parts" => [1]}, two_parts())

      assert json["commandOutputParts"] == [1]
      # The indexes name positions in `"parts"`, which is untouched: the row's
      # text is still the parts' join, exactly as the model reads it.
      assert json["parts"] == [
               %{"kind" => "text", "text" => "Your backgrounded command (shell-cmd) finished."},
               %{"kind" => "text", "text" => "# output\n"}
             ]

      assert Enum.map_join(json["parts"], "", & &1["text"]) ==
               "Your backgrounded command (shell-cmd) finished.# output\n"
    end

    test "to_json/1 omits commandOutputParts for a row that has none" do
      # Omitted entirely, so every existing payload's shape is unchanged: no
      # marker, an empty list, and nil metadata all read as "nothing to mark".
      cases = [
        {"metadata without the key", %{"mode" => "act"}},
        {"an empty index list", %{"mode" => "act", "command_output_parts" => []}},
        {"nil metadata", nil}
      ]

      for {label, metadata} <- cases do
        json = json_for(metadata, two_parts())

        refute Map.has_key?(json, "commandOutputParts"), label
        assert length(json["parts"]) == 2, label
      end
    end
  end

  defp json_for(metadata, parts) do
    User.to_json(%User{index: 1, parts: parts, metadata: metadata, api_logs: []})
  end

  # The row a backgrounded notice is delivered as: the prose, then the command's
  # own output.
  defp two_parts do
    [
      %Part.Text{text: "Your backgrounded command (shell-cmd) finished."},
      %Part.Text{text: "# output\n"}
    ]
  end
end
