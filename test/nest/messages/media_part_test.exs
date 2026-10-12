defmodule Nest.Messages.MediaPartTest do
  use ExUnit.Case, async: true

  import Nest.WireFormatAssertions

  alias Nest.Messages.Part
  alias Nest.Tokens.Estimator

  # A real 1x1 PNG. The byte count is derived rather than hardcoded so the
  # fixture cannot drift from `new_media/1`'s invariant that `data` decodes to
  # exactly `bytes`.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

  defp png_attrs(overrides) do
    Map.merge(
      %{
        tool_call_id: "call_1",
        modality: :image,
        media_type: "image/png",
        data: @png,
        bytes: byte_size(Base.decode64!(@png)),
        path: "shot.png"
      },
      overrides
    )
  end

  defp png!(overrides \\ %{}) do
    {:ok, part} = Part.new_media(png_attrs(overrides))
    part
  end

  describe "media parts" do
    test "are their own kind, and are the only part `media?/1` accepts" do
      assert Part.kind(png!()) == :media
      assert Part.media?(png!())

      others = [
        %Part.Text{text: "hi"},
        %Part.Thinking{thinking: "hmm"},
        %Part.ToolUse{id: "i", name: "n", arguments: %{}},
        %Part.ToolResult{tool_call_id: "i", name: "n", content: "c"},
        %Part.Refusal{refusal: "no"}
      ]

      refute Enum.any?(others, &Part.media?/1)

      assert Enum.map(others, &Part.kind/1) ==
               [:text, :thinking, :tool_use, :tool_result, :refusal]
    end

    test "round-trip through the persisted shape, with `path` the only optional key" do
      with_path = png!()
      assert Part.from_json(Part.to_json(with_path)) == with_path

      without_path = png!(%{path: nil})
      json = Part.to_json(without_path)

      refute Map.has_key?(json, "path")
      assert Part.from_json(json) == without_path
    end

    test "use the camelCase wire shape, and carry no `state`" do
      json = Part.to_json(png!())

      assert json["kind"] == "media"
      assert json["toolCallId"] == "call_1"
      assert json["modality"] == "image"
      assert json["mediaType"] == "image/png"
      assert json["bytes"] == byte_size(Base.decode64!(@png))
      assert json["data"] == @png
      assert json["path"] == "shot.png"

      refute Map.has_key?(json, "tool_call_id")
      # `state` is a ToolResult concept — a media part has no verdict to report.
      refute Map.has_key?(json, "state")

      assert_wire_encodable!(json, "media part")
    end

    test "restore an unknown modality as nil rather than raising" do
      # A row written by a build with a wider vocabulary. `from_json/1` already
      # returns nil for a kind it does not know, and the restore path is
      # written to tolerate that, so an unknown modality must behave the same.
      json = png!() |> Part.to_json() |> Map.put("modality", "video")

      assert Part.from_json(json) == nil
    end
  end

  describe "new_media/1 validation" do
    test "rejects a modality outside the vocabulary, naming what it got and what is allowed" do
      assert {:error, msg} = Part.new_media(png_attrs(%{modality: :video}))
      assert msg =~ ":video"
      assert msg =~ ":image"

      # A string where an atom belongs is a real risk from a config path, so it
      # must be rejected rather than coerced.
      assert {:error, msg} = Part.new_media(png_attrs(%{modality: "image"}))
      assert msg =~ ~s("image")
    end

    test "rejects a media type whose prefix disagrees with the modality" do
      assert {:error, msg} = Part.new_media(png_attrs(%{media_type: "audio/mpeg"}))
      assert msg =~ "audio/mpeg"
      assert msg =~ "does not match modality image"

      assert {:error, msg} = Part.new_media(png_attrs(%{media_type: 42}))
      assert msg =~ "must be a string"
    end

    test "rejects a byte count that disagrees with the data, or is not a positive integer" do
      assert {:error, msg} = Part.new_media(png_attrs(%{bytes: 1}))
      assert msg =~ "not the declared 1"

      for bad <- [0, -1, "12", nil] do
        assert {:error, msg} = Part.new_media(png_attrs(%{bytes: bad}))
        assert msg =~ "positive integer"
      end
    end

    test "rejects data that is not base64, or is not a string at all" do
      assert {:error, msg} = Part.new_media(png_attrs(%{data: @png <> "!"}))
      assert msg =~ "not valid base64"

      assert {:error, msg} = Part.new_media(png_attrs(%{data: nil}))
      assert msg =~ "must be a string"
    end

    test "rejects a missing or empty tool call id" do
      for bad <- [nil, ""] do
        assert {:error, msg} = Part.new_media(png_attrs(%{tool_call_id: bad}))
        assert msg =~ "tool call id"
      end
    end

    test "rejects a non-map argument rather than raising" do
      assert {:error, msg} = Part.new_media(nil)
      assert msg =~ "must be a map"
    end
  end

  describe "the modality vocabulary" do
    test "is exactly the set the estimator can price" do
      # A modality that could be built but not priced would raise `Map.fetch!/2`
      # inside the sizing path, so the two lists are pinned together here.
      assert Enum.sort(Part.modalities()) ==
               Estimator.media_token_ceilings() |> Map.keys() |> Enum.sort()
    end

    test "prices media at its ceiling, not the unrecognised-part fallback" do
      # The catch-all in `estimate_part/1` prices anything it does not
      # recognise at the per-message overhead, which would price a 1 MB image at
      # 10 tokens and mean the cap never fires. Media needs its own clause.
      assert Estimator.estimate_part(png!()) == 4_096
      assert Estimator.estimate_media_ceiling(:image) == 4_096
      assert Estimator.estimate_media(png!()) == 4_096
    end
  end
end
