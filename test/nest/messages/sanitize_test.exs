defmodule Nest.Messages.SanitizeTest do
  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Sanitize
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @replacement "\uFFFD"

  describe "text/1" do
    test "passes valid text through unchanged" do
      assert Sanitize.text("hello wörld\n") == "hello wörld\n"
    end

    test "replaces NUL with U+FFFD" do
      assert Sanitize.text("a" <> <<0>> <> "b") == "a" <> @replacement <> "b"
    end

    test "replaces invalid bytes without dropping the rest of the binary" do
      assert Sanitize.text(<<0xFF>> <> "ok") == @replacement <> "ok"

      assert Sanitize.text("a" <> <<0xFF, 0xFE>> <> "b") ==
               "a" <> @replacement <> @replacement <> "b"
    end

    test "turns an incomplete trailing sequence into a single replacement" do
      assert Sanitize.text(<<0xE2, 0x82>>) == @replacement
    end

    test "passes nil and non-binaries through" do
      assert Sanitize.text(nil) == nil
      assert Sanitize.text(42) == 42
    end
  end

  describe "text?/1" do
    test "accepts valid UTF-8 without NUL" do
      assert Sanitize.text?("hello wörld\n")
      assert Sanitize.text?("")
    end

    test "rejects NUL even though it is valid UTF-8" do
      assert String.valid?("a" <> <<0>> <> "b")
      refute Sanitize.text?("a" <> <<0>> <> "b")
    end

    test "rejects invalid UTF-8" do
      refute Sanitize.text?(<<0xFF>>)
    end

    test "rejects non-binaries" do
      refute Sanitize.text?(nil)
      refute Sanitize.text?(42)
    end
  end

  describe "message/1" do
    test "sanitizes tool-result content and nested arguments" do
      message =
        {:tool,
         %Tool{
           index: 1,
           parts: [
             %Part.ToolResult{
               tool_call_id: "c1",
               name: "shell-cmd",
               content: "before" <> <<0>> <> "after",
               arguments: %{"path" => "a" <> <<0>> <> "b"},
               is_error: false
             }
           ]
         }}

      assert {:tool, %Tool{parts: [%Part.ToolResult{} = result]}} = Sanitize.message(message)
      assert result.content == "before" <> @replacement <> "after"
      assert result.arguments == %{"path" => "a" <> @replacement <> "b"}
    end

    test "sanitizes text parts and metadata" do
      message =
        {:user,
         %User{
           index: 2,
           parts: [%Part.Text{text: "hi" <> <<0>>}],
           metadata: %{"mode" => "build", "note" => <<0xFF>>}
         }}

      assert {:user, %User{} = user} = Sanitize.message(message)
      assert [%Part.Text{text: "hi" <> @replacement}] = user.parts
      assert user.metadata["mode"] == "build"
      assert user.metadata["note"] == @replacement
    end

    test "leaves non-text parts and fields intact" do
      message =
        {:assistant,
         %Assistant{
           index: 3,
           parts: [%Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{"x" => 1}}],
           api_logs: [%{id: "1.0", type: :request, payload: %{"ok" => true}}]
         }}

      assert Sanitize.message(message) == message
    end

    test "is idempotent" do
      message = {:user, %User{index: 1, parts: [%Part.Text{text: <<0>> <> <<0xFF>>}]}}
      once = Sanitize.message(message)
      assert Sanitize.message(once) == once
    end
  end
end
