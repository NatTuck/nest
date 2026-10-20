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

    test "preserve a row whose modality a newer build wrote" do
      # A row written by a build with a wider vocabulary. Dropping it would make
      # a message silently lose an attachment on restore, which is exactly what
      # the transparency rule forbids — so the name is carried through and the
      # part survives the round-trip.
      json = png!() |> Part.to_json() |> Map.put("modality", "video")
      restored = Part.from_json(json)

      assert %Part.Media{modality: "video", media_type: "image/png"} = restored

      # ...and writing it back produces the row it came from, unchanged. The
      # equality also pins that the payload survived, so `data` and `bytes`
      # need no assertions of their own.
      assert Part.to_json(restored) == json
    end

    test "reject a row that is not a media part at all" do
      # The line between "data from a newer build" and "malformed" is whether
      # the row still describes bytes we can show.
      assert Part.from_json(%{"kind" => "media", "modality" => "video"}) == nil
      assert Part.from_json(%{"kind" => "media", "modality" => 7, "data" => @png}) == nil

      # `mediaType` and `bytes` are deliberately not required: the panel has an
      # explicit indicator for each of them being absent, so rejecting such a
      # row here would make those indicators unreachable.
      assert %Part.Media{media_type: nil, bytes: nil} =
               Part.from_json(%{"kind" => "media", "modality" => "image", "data" => @png})
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

      for bad <- [0, "12", nil] do
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

    test "prices a restored unknown modality conservatively" do
      # An unknown modality is not a key of the ceiling map — nothing can
      # produce it — so it takes a documented conservative constant. Pricing it
      # at the catch-all's per-message overhead would let an attachment of
      # unknown size slip past the budget entirely.
      unknown = %Part.Media{
        tool_call_id: "c1",
        modality: "video",
        media_type: "video/mp4",
        data: @png,
        bytes: byte_size(Base.decode64!(@png))
      }

      assert Estimator.estimate_media(unknown) == 65_536
      assert Estimator.estimate_part(unknown) == 65_536
    end
  end
end
