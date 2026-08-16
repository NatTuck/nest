defmodule Nest.LLM.CrossProviderReplayTest do
  @moduledoc """
  Regression suite for the wire-format invariants that survive a
  mid-conversation provider switch (`Agents.change_model/2`).

  The canonical message model (`%Part.Text{}, %Part.Thinking{},
  %Part.ToolUse{}, %Part.ToolResult{}, %Part.Refusal{}`) is
  wire-agnostic — wire translation lives entirely in
  `OpenAIClient.message_to_wire/1` and
  `AnthropicClient.message_to_wire/1`. **No DB migration is
  required** when switching providers, but the wire format
  must still satisfy:

    1. Strict user/assistant alternation (system/tool counts
       as a user-role message on the wire).
    2. Every `tool_use_id` (Anthropic) / `tool_call_id`
       (OpenAI) referenced by a `tool_result` must come from a
       prior `tool_use` in the conversation.
    3. OpenAI-compatible providers preserve `tool_call_id`
       verbatim (the same opaque string format works for
       both protocols); no encoding step.
    4. OpenAI drops `Thinking` parts on the wire
       (`text_from_parts/1` filters to `%Part.Text{}` only);
       Anthropic renders them with their `signature`. Prior
       thinking content is therefore invisible to an OpenAI
       target — acceptable but documented.

  These tests build a mixed-history `RunRequest`, render it
  through each client, and walk the resulting JSON to confirm
  the invariants above.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.MockClient
  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.Preflight
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool, as: ToolMessage
  alias Nest.Messages.User

  defp sys(index, text) do
    {:system, %System{index: index, parts: [%Part.Text{text: text}]}}
  end

  defp user(index, text) do
    {:user, %User{index: index, parts: [%Part.Text{text: text}]}}
  end

  defp assistant_text(index, text) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: text}]}}
  end

  defp assistant_with_thinking(index, text, signature) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [
         %Part.Text{text: text},
         %Part.Thinking{thinking: "deep thoughts", signature: signature}
       ]
     }}
  end

  defp assistant_with_tool_call(index, id, name, args) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [
         %Part.ToolUse{id: id, name: name, arguments: args}
       ]
     }}
  end

  defp tool_result(index, id, content) do
    {:tool,
     %ToolMessage{
       index: index,
       parts: [%Part.ToolResult{tool_call_id: id, content: content}]
     }}
  end

  describe "OpenAIClient after Anthropic-flavored history" do
    test "tool_use/tool_result ids round-trip and history alternates" do
      req = %RunRequest{
        model: "qwen3.5-plus",
        messages: [
          sys(0, "be brief"),
          user(1, "hi"),
          assistant_with_tool_call(2, "toolu_abc123", "shell-cmd", %{"cmd" => "ls"}),
          tool_result(3, "toolu_abc123", "file1\nfile2"),
          assistant_with_thinking(4, "done", "sig_xyz"),
          user(5, "goodbye"),
          assistant_text(6, "bye")
        ],
        stream: true
      }

      payload = OpenAIClient.format_request_payload(req, [])

      # Tool_use id round-trips verbatim — OpenAI's `id` field is
      # a free-form string; we don't reformat Anthropic's
      # `toolu_*` prefix into anything.
      tool_msg = Enum.at(payload["messages"], 2)
      assert tool_msg["role"] == "assistant"
      [tool_call] = tool_msg["tool_calls"]
      assert tool_call["id"] == "toolu_abc123"
      assert tool_call["function"]["name"] == "shell-cmd"

      tool_result_msg = Enum.at(payload["messages"], 3)
      assert tool_result_msg["role"] == "tool"
      assert tool_result_msg["tool_call_id"] == "toolu_abc123"

      # Thinking content is silently dropped on the OpenAI
      # wire. The text content survives verbatim. This is
      # the only semantic loss in the cross-provider replay
      # path — see AGENTS.md "Cross-provider message history
      # compatibility".
      assistant_at_4 = Enum.at(payload["messages"], 4)
      assert assistant_at_4["role"] == "assistant"
      assert assistant_at_4["content"] == "done"
      refute Map.has_key?(assistant_at_4, "tool_calls")

      # Final alternation still: assistant → user → assistant,
      # no orphan tool_calls at the tail.
      assert Enum.at(payload["messages"], 5)["role"] == "user"
      assert Enum.at(payload["messages"], 6)["role"] == "assistant"

      # The MockClient's preflight pairs every tool_use id
      # with the matching tool_result — applying it here
      # ensures we caught any orphaned id.
      assert :ok = Preflight.validate_tool_call_pairing(req.messages)
    end
  end

  describe "AnthropicClient after OpenAI-flavored history" do
    test "tool_use / tool_result use the same id strings and history alternates" do
      req = %RunRequest{
        model: "claude-3-opus-20240229",
        messages: [
          sys(0, "be brief"),
          user(1, "hi"),
          assistant_with_tool_call(2, "call_abc123", "shell-cmd", %{"cmd" => "ls"}),
          tool_result(3, "call_abc123", "file1\nfile2"),
          assistant_with_thinking(4, "done", "sig_xyz"),
          user(5, "goodbye"),
          assistant_text(6, "bye")
        ],
        stream: true
      }

      payload = AnthropicClient.format_request_payload(req, [])

      # Leading system message lifted to top-level "system" field.
      assert payload["system"] == "be brief"

      tool_msg = Enum.at(payload["messages"], 1)

      [tool_block] = tool_msg["content"]
      assert tool_block["type"] == "tool_use"
      assert tool_block["id"] == "call_abc123"

      tool_result_msg = Enum.at(payload["messages"], 2)
      assert tool_result_msg["role"] == "user"
      [tool_result_block] = tool_result_msg["content"]
      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "call_abc123"

      # Thinking signature is preserved on the wire (Anthropic's
      # native rendering — the new model can rebuild its own
      # reasoning context from `signature`).
      assistant_at_4 = Enum.at(payload["messages"], 3)
      assert assistant_at_4["role"] == "assistant"

      has_thinking_block =
        Enum.any?(assistant_at_4["content"], fn block ->
          block["type"] == "thinking"
        end)

      assert has_thinking_block

      # Final alternation: assistant → user → assistant.
      assert Enum.at(payload["messages"], 4)["role"] == "user"
      assert Enum.at(payload["messages"], 5)["role"] == "assistant"
      assert :ok = Preflight.validate_tool_call_pairing(req.messages)
    end
  end

  describe "MockClient preflight across a switch" do
    test "anthropic-parody 400 fires when ids mismatch" do
      # After a switch, an OpenAI-issued `tool_call_id` might
      # not match the tool_use that produced it. Preflight
      # catches this for the test client; the real Anthropic
      # client would surface it as `(2013) tool call result
      # does not follow tool call`.
      broken_req = %RunRequest{
        messages: [
          sys(0, "x"),
          user(1, "hi"),
          assistant_with_tool_call(2, "call_AAA", "shell-cmd", %{}),
          tool_result(3, "call_BBB", "wrong id")
        ]
      }

      case Preflight.validate_tool_call_pairing(broken_req.messages) do
        {:error, {:preflight_unpaired_tool_call, _details}} ->
          # Expected — the pair check fires before any provider
          # call would. Surface via MockClient and the test
          # sees the canonical Anthropic-shaped 400.
          assert {:ok, %{} = stream} = MockClient.run(broken_req, [])

          assert Enum.any?(stream, &match?({:error, _}, &1))

        _ ->
          flunk("expected preflight to fail with unpaired id")
      end
    end
  end

  describe "repeated switches don't break alternation" do
    test "OpenAI render of a long history preserves every id and alternation" do
      req = %RunRequest{
        messages: [
          sys(0, "you are a helpful assistant"),
          user(1, "first message"),
          assistant_with_tool_call(2, "id_1", "shell-cmd", %{"command" => "ls"}),
          tool_result(3, "id_1", "f1\nf2"),
          assistant_text(4, "here are the files"),
          user(5, "ok thanks"),
          assistant_with_tool_call(6, "id_2", "file-read", %{"path" => "/etc/hostname"}),
          tool_result(7, "id_2", "my-host\n"),
          assistant_text(8, "done")
        ],
        stream: true
      }

      payload = OpenAIClient.format_request_payload(req, [])

      # Wire-format role order: system, user, assistant+tool,
      # tool, assistant, user, assistant+tool, tool, assistant.
      assert Enum.at(payload["messages"], 0)["role"] == "system"
      assert Enum.at(payload["messages"], 1)["role"] == "user"
      assert Enum.at(payload["messages"], 2)["role"] == "assistant"
      assert Enum.at(payload["messages"], 3)["role"] == "tool"
      assert Enum.at(payload["messages"], 4)["role"] == "assistant"
      assert Enum.at(payload["messages"], 5)["role"] == "user"
      assert Enum.at(payload["messages"], 6)["role"] == "assistant"
      assert Enum.at(payload["messages"], 7)["role"] == "tool"
      assert Enum.at(payload["messages"], 8)["role"] == "assistant"

      # Both tool_calls ids preserved verbatim.
      assert Enum.at(payload["messages"], 2)["tool_calls"] |> List.first() |> Map.get("id") ==
               "id_1"

      assert Enum.at(payload["messages"], 6)["tool_calls"] |> List.first() |> Map.get("id") ==
               "id_2"

      # Preflight agrees there are no orphan tool results.
      assert :ok = Preflight.validate_tool_call_pairing(req.messages)
    end
  end
end
