defmodule Nest.LLM.AnthropicClientTest do
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.Tool, as: LLMTool
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool, as: ToolMessage
  alias Nest.Messages.User

  setup :verify_on_exit!

  defp user_msg(text), do: {:user, %User{index: 1, parts: [%Part.Text{text: text}]}}
  defp sys_msg(index, text), do: {:system, %System{index: index, parts: [%Part.Text{text: text}]}}

  describe "format_request_payload/2" do
    test "emits model, max_tokens, messages, and stream: true" do
      req = %RunRequest{
        model: "claude-3-opus-20240229",
        messages: [user_msg("hi")]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["model"] == "claude-3-opus-20240229"
      assert payload["stream"] == true
      assert payload["max_tokens"] == 32_000

      assert payload["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
             ]

      refute Map.has_key?(payload, "system")
      refute Map.has_key?(payload, "tools")
    end

    test "lifts only a non-empty leading {:system, _} into the top-level system field" do
      user = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]

      # Each case is the full `messages` list, the expected top-level
      # `system` value (`:absent` when the field must not be emitted at
      # all), and the expected wire `messages` array.
      for {messages, expected_system, expected_messages} <- [
            # A leading system message is lifted out of the array.
            {[sys_msg(0, "be brief"), user_msg("hi")], "be brief", user},
            # A late system reminder stays in the messages array, as a
            # role: system message.
            {[sys_msg(0, "be brief"), user_msg("hi"), sys_msg(2, "2 rounds left")], "be brief",
             user ++ [%{"role" => "system", "content" => "2 rounds left"}]},
            # No leading system message at all: no top-level field.
            {[user_msg("hi")], :absent, user},
            # Empty system content is treated as "no initial system" —
            # the top-level `system` field is omitted, and the empty
            # `{:system, _}` tuple flows into the messages array.
            {[sys_msg(0, ""), user_msg("hi")], :absent,
             [%{"role" => "system", "content" => ""} | user]}
          ] do
        payload = AnthropicClient.format_request_payload(%RunRequest{messages: messages}, [])

        assert Map.get(payload, "system", :absent) == expected_system
        assert payload["messages"] == expected_messages
      end
    end

    test "coalesces adjacent user text parts into one block, and only adjacent ones" do
      # Issue #139: a drained batch's row is one text part per body and a
      # backgrounded notice splits its prose from the command's output, so a
      # user row can now hold several `Part.Text`s. The split is for the
      # browser; the model must see exactly the request it saw before, which is
      # one block per body — so consecutive text parts are joined, and a
      # non-text part between two of them still separates them.
      image =
        %Part.Media{
          tool_call_id: "call_1",
          modality: :image,
          media_type: "image/png",
          data: "aGk=",
          bytes: 2
        }

      req = %RunRequest{
        messages: [
          {:user,
           %User{
             index: 1,
             parts: [
               %Part.Text{text: "prose\n\n"},
               %Part.Text{text: "command output"},
               image,
               %Part.Text{text: "after the image"}
             ]
           }}
        ]
      }

      assert %{"messages" => [%{"role" => "user", "content" => blocks}]} =
               AnthropicClient.format_request_payload(req, [])

      assert [
               %{"type" => "text", "text" => "prose\n\ncommand output"},
               %{"type" => "image"},
               %{"type" => "text", "text" => "after the image"}
             ] = blocks
    end

    test "emits tools in the Anthropic shape" do
      tool = %LLMTool{
        name: "shell-cmd",
        description: "run a command",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{"command" => %{"type" => "string"}},
          "required" => ["command"]
        }
      }

      payload = AnthropicClient.format_request_payload(%RunRequest{tools: [tool]}, [])

      assert payload["tools"] == [
               %{
                 "name" => "shell-cmd",
                 "description" => "run a command",
                 "input_schema" => %{
                   "type" => "object",
                   "properties" => %{"command" => %{"type" => "string"}},
                   "required" => ["command"]
                 }
               }
             ]
    end

    test "rebuilds a stored assistant, replaying signed thinking only while thinking is on" do
      # This is the second turn of a multi-turn conversation: an Assistant
      # struct persisted from the previous turn (with thinking + signature +
      # tool call) is re-serialized for the next request. The signature must
      # travel on the thinking block, the tool_use block must keep its id and
      # input, and the order must match Anthropic's content-block order
      # convention.
      signed = %Part.Thinking{thinking: "let me think", signature: "sig_abc"}

      text_block = %{"type" => "text", "text" => "visible text"}

      thinking_block = %{
        "type" => "thinking",
        "thinking" => "let me think",
        "signature" => "sig_abc"
      }

      tool_use_block = %{
        "type" => "tool_use",
        "id" => "toolu_1",
        "name" => "shell-cmd",
        "input" => %{"command" => "ls"}
      }

      # Every case is the same assistant frame — text, then an optional
      # thinking part, then a tool_use — so only the stored block's signature
      # and the request's effort level vary. Those decide both the content (a
      # signed block is replayed only while thinking is on) and the top-level
      # `thinking` param.
      for {effort, thinking_part, expected_thinking, expected_content} <- [
            # No thinking part at all: nothing to emit.
            {nil, nil, :absent, [text_block, tool_use_block]},
            # Thinking on with a signed block: it is replayed, signature and
            # all, between the text and the tool_use.
            {:medium, signed, %{"type" => "enabled", "budget_tokens" => 8_000},
             [text_block, thinking_block, tool_use_block]},
            # Thinking on, but the stored block has no signature: unsigned
            # reasoning cannot be replayed, so it is dropped from the content
            # while the request still enables thinking.
            {:high, %Part.Thinking{thinking: "just thinking", signature: nil},
             %{"type" => "enabled", "budget_tokens" => 16_000}, [text_block, tool_use_block]},
            # Thinking off: even a signed historical block is dropped.
            {:off, signed, :absent, [text_block, tool_use_block]},
            {nil, signed, :absent, [text_block, tool_use_block]}
          ] do
        parts =
          [%Part.Text{text: "visible text"}] ++
            List.wrap(thinking_part) ++
            [%Part.ToolUse{id: "toolu_1", name: "shell-cmd", arguments: %{"command" => "ls"}}]

        payload =
          AnthropicClient.format_request_payload(
            %RunRequest{
              thinking_effort: effort,
              messages: [{:assistant, %Assistant{index: 2, parts: parts}}]
            },
            []
          )

        assert Map.get(payload, "thinking", :absent) == expected_thinking
        assert payload["messages"] == [%{"role" => "assistant", "content" => expected_content}]
      end
    end

    test "inserts a placeholder block for an empty assistant message" do
      payload =
        AnthropicClient.format_request_payload(
          %RunRequest{messages: [{:assistant, %Assistant{index: 4, parts: []}}]},
          []
        )

      assert payload["messages"] == [
               %{"role" => "assistant", "content" => [%{"type" => "text", "text" => " "}]}
             ]
    end

    test "translates tool results to a user-role message with tool_result content blocks" do
      req = %RunRequest{
        messages: [
          {:tool,
           %ToolMessage{
             index: 3,
             parts: [
               %Part.ToolResult{
                 tool_call_id: "toolu_1",
                 name: "shell-cmd",
                 content: "out1",
                 is_error: false
               },
               %Part.ToolResult{
                 tool_call_id: "toolu_2",
                 name: "file-read",
                 content: "boom",
                 is_error: true
               }
             ]
           }}
        ]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_1",
                     "content" => "out1",
                     "is_error" => false
                   },
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_2",
                     "content" => "boom",
                     "is_error" => true
                   }
                 ]
               }
             ]
    end

    test "translates tool_choice to the Anthropic shape and falls back to :auto for :required" do
      for {choice, expected} <- [
            {:auto, %{"type" => "auto"}},
            {:none, %{"type" => "none"}},
            {:required, %{"type" => "auto"}},
            {{:tool, "shell-cmd"}, %{"type" => "tool", "name" => "shell-cmd"}}
          ] do
        payload = AnthropicClient.format_request_payload(%RunRequest{tool_choice: choice}, [])
        assert payload["tool_choice"] == expected
      end
    end

    test "derives the thinking budget from the effort level and the output allowance" do
      # The budget heuristic per level, against the default 32k allowance.
      # `:xhigh` asks for 32k, but the budget never exceeds half the allowance.
      # `high` is 16k, but half of an explicit 12k max_tokens is 6k. Half of
      # 1.5k falls below Anthropic's 1k minimum, so thinking is omitted — while
      # the requested max_tokens still flows through. `:off` and `nil` disable
      # thinking by omitting the param entirely.
      for {effort, max_tokens, expected_max_tokens, expected_thinking} <- [
            {:high, nil, 32_000, %{"type" => "enabled", "budget_tokens" => 16_000}},
            {:xhigh, nil, 32_000, %{"type" => "enabled", "budget_tokens" => 16_000}},
            {:high, 12_000, 12_000, %{"type" => "enabled", "budget_tokens" => 6_000}},
            {:medium, 1_500, 1_500, :absent},
            {:off, nil, 32_000, :absent},
            {nil, nil, 32_000, :absent}
          ] do
        payload =
          AnthropicClient.format_request_payload(
            %RunRequest{thinking_effort: effort, max_tokens: max_tokens},
            []
          )

        assert payload["max_tokens"] == expected_max_tokens
        assert Map.get(payload, "thinking", :absent) == expected_thinking
      end
    end

    test "applies DeepSeek Flash model defaults over the Anthropic protocol" do
      payload =
        AnthropicClient.format_request_payload(
          %RunRequest{model: "deepseek-v4-flash", messages: [user_msg("hi")]},
          []
        )

      assert payload["max_tokens"] == 32_000
      assert payload["top_p"] == 0.95
    end

    test "passes temperature, top_p, and max_tokens through when set" do
      payload =
        AnthropicClient.format_request_payload(
          %RunRequest{temperature: 0.3, top_p: 0.9, max_tokens: 1024},
          []
        )

      assert payload["temperature"] == 0.3
      assert payload["top_p"] == 0.9
      assert payload["max_tokens"] == 1024
    end
  end

  describe "normalize_endpoint/2" do
    test "appends the endpoint to a base URL that may already carry it" do
      for base_url <- [
            # A clean base URL.
            "https://api.anthropic.com/v1",
            # A trailing slash is stripped before appending.
            "https://api.anthropic.com/v1/",
            # The endpoint is already present: it is stripped, not duplicated.
            "https://api.anthropic.com/v1/messages",
            # Same, with a trailing slash on the duplicated endpoint.
            "https://api.anthropic.com/v1/messages/"
          ] do
        assert AnthropicClient.normalize_endpoint(base_url, "/v1/messages") ==
                 "https://api.anthropic.com/v1/messages"
      end
    end
  end
end
