defmodule Nest.Tokens.RequestSizeTest do
  use ExUnit.Case, async: true

  alias Nest.Messages.Part
  alias Nest.Tokens.RequestSize

  # Plain maps rather than `%User{}` / `%Tool{}`: `bytes/1` reads `:parts` and
  # nothing else, and building the real structs would test them instead.
  defp message(parts), do: {:user, %{parts: parts}}

  defp text(bytes), do: message([%Part.Text{text: String.duplicate("a", bytes)}])

  defp media(data_bytes) do
    message([
      %Part.Media{
        tool_call_id: "c1",
        modality: :image,
        media_type: "image/png",
        data: String.duplicate("A", data_bytes),
        bytes: data_bytes,
        path: "shot.png"
      }
    ])
  end

  describe "bytes/1" do
    test "counts text parts" do
      assert RequestSize.bytes([text(100), text(50)]) == 150
    end

    test "counts a media part's payload, which is the term that matters" do
      # A media part's token price is a flat ceiling, so its bytes are invisible
      # to every other budget in the system. This is the only place they are
      # counted.
      #
      # Compared rather than asserted outright: the part also carries its call
      # id, media type and path, and counting those is the upper bound this
      # function is meant to be. The payload is the term that has to move.
      small = RequestSize.bytes([media(1_000)])
      large = RequestSize.bytes([media(9_000_000)])

      assert large - small == 9_000_000 - 1_000
    end

    test "counts nested map values, so a tool call's arguments are not missed" do
      tool_use = %Part.ToolUse{id: "c1", name: "shell-cmd", arguments: %{"command" => "ls"}}

      assert RequestSize.bytes([message([tool_use])]) ==
               byte_size("c1") + byte_size("shell-cmd") + 2
    end

    test "is zero for an empty list" do
      assert RequestSize.bytes([]) == 0
    end
  end

  describe "media_wire_bytes/1" do
    test "is the base64 expansion, rounded up to a four-character group" do
      # Base64 encodes three bytes as four characters, and pads a short final
      # group rather than dropping it.
      assert RequestSize.media_wire_bytes(0) == 0
      assert RequestSize.media_wire_bytes(1) == 4
      assert RequestSize.media_wire_bytes(3) == 4
      assert RequestSize.media_wire_bytes(4) == 8
    end
  end

  describe "within?/2" do
    test "the ceiling is 16 MB, well under the provider's 48 MiB body limit" do
      assert RequestSize.max_bytes() == 16_000_000
    end

    test "counts the existing messages and the new media together" do
      # The ceiling boundary, both sides: a gate that only ever refused would
      # pass an "over the limit is refused" test on its own.
      #
      # Projected, not measured: a conversation just under the line must not
      # admit one more image that takes it over.
      just_under = RequestSize.max_bytes() - 1_000

      assert RequestSize.within?([text(just_under)], 1_000)
      refute RequestSize.within?([text(just_under)], 1_001)
    end

    test "the largest image file-read can attach still fits on its own" do
      # `file-read` refuses a read larger than its own 10 MB cap before this gate
      # is ever reached, so 13.3 MB is the most one image can add. If that
      # stopped fitting — the cap raised, or the ceiling lowered — a single image
      # would trip the ceiling on any conversation and the refusal would blame
      # images already in context.
      #
      # The 10 MB is `FileTools`'s `@max_read_file_bytes`, spelled here because
      # the two constants live in different modules and this is the only thing
      # tying them together. Raise that attribute and this test must move with
      # it; that is the point.
      assert RequestSize.within?([], RequestSize.media_wire_bytes(10_000_000))
    end
  end
end
