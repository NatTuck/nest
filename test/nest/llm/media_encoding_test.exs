defmodule Nest.LLM.MediaEncodingTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.MockClient
  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

  defp media_part(tool_call_id) do
    {:ok, part} =
      Part.new_media(%{
        tool_call_id: tool_call_id,
        modality: :image,
        media_type: "image/png",
        data: @png,
        bytes: byte_size(Base.decode64!(@png)),
        path: "shot.png"
      })

    part
  end

  defp result_part(tool_call_id, content) do
    %Part.ToolResult{
      tool_call_id: tool_call_id,
      name: "file-read",
      content: content,
      arguments: %{"path" => "shot.png"},
      is_error: false
    }
  end

  # A media part this build cannot send, built directly rather than through
  # `new_media/1` (which refuses an unknown modality by design). This is the
  # *restored* shape: a row a build with a wider vocabulary wrote.
  defp unknown_media(tool_call_id) do
    %Part.Media{
      tool_call_id: tool_call_id,
      modality: "video",
      media_type: "video/mp4",
      data: @png,
      bytes: byte_size(Base.decode64!(@png)),
      path: "clip.mp4"
    }
  end

  defp anchor, do: "Read 68 bytes image/png from shot.png; attached below."

  defp tool_msg(parts), do: {:tool, %Tool{index: 2, parts: parts, api_logs: []}}

  defp user_msg(parts), do: {:user, %User{index: 1, parts: parts}}

  describe "the OpenAI wire" do
    test "hoists media into a trailing user message and keeps the tool message text-only" do
      req = %RunRequest{
        model: "gpt-4o",
        messages: [tool_msg([result_part("call_1", anchor()), media_part("call_1")])]
      }

      assert [tool_wire, media_wire] =
               OpenAIClient.format_request_payload(req, [])["messages"]

      assert tool_wire["role"] == "tool"
      assert tool_wire["tool_call_id"] == "call_1"
      # The API rejects any content part other than `text` on `role: "tool"`,
      # so the tool message's content has to stay a plain string.
      assert tool_wire["content"] == anchor()

      assert media_wire["role"] == "user"
      assert [%{"type" => "image_url"} = image] = media_wire["content"]
      assert image["image_url"]["url"] == "data:image/png;base64," <> @png
      refute Map.has_key?(image["image_url"], "detail")
    end

    test "gives a user message with media the content-array form, text first" do
      req = %RunRequest{
        model: "gpt-4o",
        messages: [user_msg([%Part.Text{text: "what is this?"}, media_part("u1")])]
      }

      assert [%{"role" => "user", "content" => content}] =
               OpenAIClient.format_request_payload(req, [])["messages"]

      assert [%{"type" => "text", "text" => "what is this?"}, %{"type" => "image_url"}] = content
    end
  end

  describe "the Anthropic wire" do
    test "folds media into the tool_result block of the result it answers" do
      req = %RunRequest{
        model: "claude-x",
        messages: [tool_msg([result_part("call_1", anchor()), media_part("call_1")])]
      }

      assert [%{"role" => "user", "content" => [block]}] =
               AnthropicClient.format_request_payload(req, [])["messages"]

      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "call_1"
      assert block["is_error"] == false

      assert [text_block, image_block] = block["content"]
      assert text_block == %{"type" => "text", "text" => anchor()}

      assert image_block == %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => @png}
             }
    end

    test "folds media into its own result only, preserving result order" do
      req = %RunRequest{
        model: "claude-x",
        messages: [
          tool_msg([
            result_part("call_1", "first"),
            result_part("call_2", "second"),
            media_part("call_2")
          ])
        ]
      }

      assert [%{"content" => [first, second]}] =
               AnthropicClient.format_request_payload(req, [])["messages"]

      assert first["tool_use_id"] == "call_1"
      assert first["content"] == "first"

      assert second["tool_use_id"] == "call_2"
      assert [%{"type" => "text", "text" => "second"}, %{"type" => "image"}] = second["content"]
    end

    test "keeps a media part that answers no result rather than dropping it" do
      # Unreachable from the batch path, which always emits the pair. If it
      # ever happens the media must still reach the model, because silently
      # dropping it is exactly the failure the project forbids.
      req = %RunRequest{
        model: "claude-x",
        messages: [tool_msg([result_part("call_1", "plain"), media_part("orphan")])]
      }

      assert [%{"role" => "user", "content" => [block, orphan]}] =
               AnthropicClient.format_request_payload(req, [])["messages"]

      assert block["type"] == "tool_result"
      assert orphan["type"] == "image"
    end
  end

  describe "the mock client" do
    test "models the same media fold the Anthropic client does" do
      # The mock is the cross-provider replay harness. If it dropped media the
      # harness would be lying about what a real client sends.
      req = %RunRequest{
        model: "mock-model",
        messages: [tool_msg([result_part("call_1", anchor()), media_part("call_1")])]
      }

      assert [%{"role" => "user", "content" => [block]}] =
               MockClient.format_request_payload(req, [])["messages"]

      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "call_1"
      assert [%{"type" => "text", "text" => text}, %{"type" => "image"}] = block["content"]
      assert text == anchor()
    end

    test "keeps a media-free tool message's content a plain string" do
      req = %RunRequest{
        model: "mock-model",
        messages: [tool_msg([result_part("call_1", "plain")])]
      }

      assert [%{"role" => "user", "content" => [%{"content" => "plain"}]}] =
               MockClient.format_request_payload(req, [])["messages"]
    end
  end

  describe "a media part this build cannot send" do
    test "becomes an explicit note on every wire, never a crash and never a drop" do
      # A restored row from a build with a wider vocabulary. It is still shown
      # in the panel, so it cannot simply vanish from the request — but it also
      # cannot be encoded, and raising would brick the turn.
      req = %RunRequest{
        model: "some-model",
        messages: [tool_msg([result_part("call_1", "anchor"), unknown_media("call_1")])]
      }

      # OpenAI hoists it into the trailing user message as a text note.
      assert [_tool_wire, %{"role" => "user", "content" => [note]}] =
               OpenAIClient.format_request_payload(req, [])["messages"]

      assert note["type"] == "text"
      assert note["text"] =~ "omitted from this request"
      assert note["text"] =~ "video"
      refute note["text"] =~ @png

      # Anthropic folds it into the same result block an image would use.
      assert [%{"role" => "user", "content" => [block]}] =
               AnthropicClient.format_request_payload(req, [])["messages"]

      assert [%{"type" => "text"}, %{"type" => "text", "text" => text}] = block["content"]
      assert text =~ "omitted from this request"
      refute text =~ @png

      # The mock agrees, or the replay harness would be lying.
      assert [%{"role" => "user", "content" => [mock_block]}] =
               MockClient.format_request_payload(req, [])["messages"]

      assert [_, %{"type" => "text", "text" => mock_text}] = mock_block["content"]
      assert mock_text == text
    end
  end
end
