defmodule Nest.Agents.Agent.ChatTurn.LateMessageTest do
  @moduledoc """
  Tests for the late-message shape router.

  Covers both `build/2` (called with text from the reminder
  authors) and `rewrap/2` (called when the compactor's
  suffix arrives as an already-built System tuple from
  `TokensCompactor.compute_summary_budget/4`). The split lets
  the `Tokens.Compactor` module stay config-agnostic while the
  per-message shape decision still lives at the chat-turn
  boundary.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.LateMessage
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User

  defp rewrite_on, do: %ClientConfig{rewrite_late_system_messages: true}
  defp rewrite_off, do: %ClientConfig{rewrite_late_system_messages: false}

  describe "build/2" do
    test "returns {:system, %System{}} when rewrite is off" do
      text = "Context usage is now at 50%."

      assert {:system, %System{parts: [%Part.Text{text: ^text}], timestamp: %DateTime{}}} =
               LateMessage.build(rewrite_off(), text)
    end

    test "returns {:system, %System{}} when client_config is nil (default path)" do
      text = "Be brief."

      assert {:system, %System{parts: [%Part.Text{text: ^text}]}} =
               LateMessage.build(nil, text)
    end

    test "returns {:user, %User{}} when rewrite is on" do
      text = "Context usage is now at 50%."
      bracketed = "[System notice: " <> text <> "]"

      assert {:user,
              %User{
                parts: [%Part.Text{text: ^bracketed}],
                timestamp: %DateTime{}
              }} = LateMessage.build(rewrite_on(), text)
    end

    test "the rewired user message is wrapped with [System notice: …]" do
      text = "Compacting…"
      bracketed = "[System notice: " <> text <> "]"

      {:user, %User{parts: [%Part.Text{text: result}]}} = LateMessage.build(rewrite_on(), text)

      assert result == bracketed
      assert String.starts_with?(result, "[System notice: ")
      assert String.ends_with?(result, "]")
    end

    test "preserves the full reminder text inside the bracket" do
      full =
        "Context usage is now at 50% (~80,000 of ~128,000 token budget). Consider compacting."

      bracketed = "[System notice: " <> full <> "]"

      {:user, %User{parts: [%Part.Text{text: result}]}} = LateMessage.build(rewrite_on(), full)

      assert result == bracketed
    end

    test "preserves newlines and unicode inside the bracket" do
      weird = ~s(Line 1\nLine 2 — emoji ⚡ — "quotes" )
      bracketed = "[System notice: " <> weird <> "]"

      {:user, %User{parts: [%Part.Text{text: result}]}} = LateMessage.build(rewrite_on(), weird)

      assert result == bracketed
    end
  end

  describe "rewrap/2" do
    test "returns the System tuple verbatim when rewrite is off (no-op)" do
      original =
        {:system, %System{index: 0, parts: [%Part.Text{text: "[mode: compact] Summarize."}]}}

      assert LateMessage.rewrap(rewrite_off(), original) === original
    end

    test "extracts text and rewrites as User when rewrite is on" do
      suffix_text = "[mode: compact] Summarize the conversation in your 1500 remaining tokens."
      bracketed = "[System notice: " <> suffix_text <> "]"

      system_tuple = {:system, %System{index: 0, parts: [%Part.Text{text: suffix_text}]}}

      assert {:user,
              %User{
                parts: [%Part.Text{text: ^bracketed}]
              }} = LateMessage.rewrap(rewrite_on(), system_tuple)
    end

    test "joins multi-part text into a single bracketed user message" do
      system_tuple =
        {:system,
         %System{
           index: 0,
           parts: [
             %Part.Text{text: "first"},
             %Part.Text{text: " second"}
           ]
         }}

      bracketed = "[System notice: first second]"

      assert {:user, %User{parts: [%Part.Text{text: ^bracketed}]}} =
               LateMessage.rewrap(rewrite_on(), system_tuple)
    end

    test "ignores non-Text parts when joining for the bracket" do
      system_tuple =
        {:system,
         %System{
           index: 0,
           parts: [
             %Part.Text{text: "header "},
             %Part.ToolUse{id: "x", name: "y", arguments: %{}}
           ]
         }}

      bracketed = "[System notice: header ]"

      assert {:user, %User{parts: [%Part.Text{text: ^bracketed}]}} =
               LateMessage.rewrap(rewrite_on(), system_tuple)
    end

    test "rewrap with nil client_config returns the System tuple unchanged" do
      original = {:system, %System{parts: [%Part.Text{text: "any text"}]}}

      assert LateMessage.rewrap(nil, original) === original
    end
  end
end
