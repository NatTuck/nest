defmodule Nest.LLM.PreflightTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  defp assistant_text(text),
    do: {:assistant, %Assistant{parts: [%Part.Text{text: text}]}}

  defp assistant_tool_use(id),
    do:
      {:assistant, %Assistant{parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}]}}

  defp assistant_tool_uses(ids),
    do:
      {:assistant,
       %Assistant{
         parts:
           Enum.map(ids, fn id -> %Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}} end)
       }}

  defp user_text(text), do: {:user, %User{parts: [%Part.Text{text: text}]}}

  defp system_text(text), do: {:system, %System{parts: [%Part.Text{text: text}]}}

  defp tool_result(id, content \\ "ok"),
    do:
      {:tool,
       %Tool{
         parts: [
           %Part.ToolResult{
             tool_call_id: id,
             name: "shell-cmd",
             content: content,
             is_error: false
           }
         ]
       }}

  defp tool_results(ids) do
    parts =
      Enum.map(ids, fn id ->
        %Part.ToolResult{tool_call_id: id, name: "shell-cmd", content: "ok"}
      end)

    {:tool, %Tool{parts: parts}}
  end

  defp error_details({:preflight_unpaired_tool_call, details}), do: details
  defp error_details(other), do: flunk("expected preflight error, got #{inspect(other)}")

  describe "validate_tool_call_pairing/1" do
    test "ok: empty list" do
      assert Preflight.validate_tool_call_pairing([]) == :ok
    end

    test "ok: text-only conversation" do
      messages = [
        system_text("be brief"),
        user_text("hi"),
        assistant_text("hello")
      ]

      assert Preflight.validate_tool_call_pairing(messages) == :ok
    end

    test "ok: assistant [a] followed by tool [a]" do
      messages = [assistant_tool_use("a"), tool_result("a")]
      assert Preflight.validate_tool_call_pairing(messages) == :ok
    end

    test "ok: assistant [a, b] followed by tool [a, b]" do
      messages = [assistant_tool_uses(["a", "b"]), tool_results(["a", "b"])]
      assert Preflight.validate_tool_call_pairing(messages) == :ok
    end

    test "ok: order within a single tool message is irrelevant" do
      messages = [assistant_tool_uses(["a", "b"]), tool_results(["b", "a"])]
      assert Preflight.validate_tool_call_pairing(messages) == :ok
    end

    test "ok: paired turn followed by an unpaired text-only assistant turn" do
      messages = [
        assistant_tool_use("a"),
        tool_result("a"),
        assistant_text("done")
      ]

      assert Preflight.validate_tool_call_pairing(messages) == :ok
    end

    test "ok: multiple paired turns back to back" do
      messages = [
        assistant_tool_use("a"),
        tool_result("a"),
        assistant_tool_use("b"),
        tool_result("b")
      ]

      assert Preflight.validate_tool_call_pairing(messages) == :ok
    end

    test "error: assistant [a, b] followed by tool [a] — missing b" do
      messages = [assistant_tool_uses(["a", "b"]), tool_result("a")]

      assert {:error, error} = Preflight.validate_tool_call_pairing(messages)
      details = error_details(error)

      assert [%{kind: :missing_tool_responses}] = details
      assert [%{position: 1, missing_ids: ["b"], expected_ids: ["a", "b"]}] = details
    end

    test "error: text-only assistant followed by tool [a] — orphan tool result" do
      messages = [assistant_text("done"), tool_result("a")]

      assert {:error, error} = Preflight.validate_tool_call_pairing(messages)
      details = error_details(error)

      assert [%{kind: :orphan_tool_result, position: 1, orphan_ids: ["a"]}] = details
    end

    test "error: mismatched ids surface both missing and orphan kinds" do
      messages = [assistant_tool_use("a"), tool_result("b")]

      assert {:error, error} = Preflight.validate_tool_call_pairing(messages)
      details = error_details(error)

      kinds = Enum.map(details, & &1.kind) |> Enum.sort()
      assert kinds == [:missing_tool_responses, :orphan_tool_result]

      missing = Enum.find(details, &(&1.kind == :missing_tool_responses))
      extra = Enum.find(details, &(&1.kind == :orphan_tool_result))

      assert missing.missing_ids == ["a"]
      assert missing.expected_ids == ["a"]
      assert extra.orphan_ids == ["b"]
    end

    test "error: assistant [a] followed by another assistant (unclosed+alternation)" do
      messages = [assistant_tool_use("a"), assistant_text("hi")]

      assert {:error, error} = Preflight.validate_tool_call_pairing(messages)
      details = error_details(error)

      kinds = Enum.map(details, & &1.kind)
      assert :unclosed_tool_responses in kinds
      assert :alternation_violation in kinds
    end

    test "error: strict system — system reminder between tool_use and tool response" do
      messages = [assistant_tool_use("a"), system_text("reminder"), tool_result("a")]

      assert {:error, error} = Preflight.validate_tool_call_pairing(messages)
      details = error_details(error)

      assert details == [
               %{
                 kind: :orphan_tool_result,
                 position: 2,
                 orphan_ids: ["a"],
                 missing_ids: [],
                 expected_ids: []
               },
               %{
                 kind: :unclosed_tool_responses,
                 position: 1,
                 expected_ids: ["a"],
                 orphan_ids: [],
                 missing_ids: []
               }
             ]
    end
  end

  describe "rules/0" do
    test "lists every named rule" do
      assert Preflight.rules() == [
               :known_roles,
               :tool_pairing,
               :no_orphan_tool_results,
               :alternation,
               :no_trailing_orphan
             ]
    end
  end

  describe "validate/1" do
    test "ok: a valid paired sequence" do
      messages = [
        system_text("s"),
        user_text("hi"),
        assistant_tool_use("a"),
        tool_result("a"),
        assistant_text("done")
      ]

      assert Preflight.validate(messages) == :ok
    end

    test "known_roles: rejects an unknown role" do
      assert {:error, violations} = Preflight.validate([{:bogus, %User{}}])

      assert Enum.any?(violations, fn v ->
               v.rule == :known_roles and v.role == :bogus and v.position == 0
             end)
    end

    test "tool_pairing: a tool_use must be answered immediately" do
      assert {:error, violations} =
               Preflight.validate([assistant_tool_use("a"), user_text("hi")])

      assert [%{rule: :tool_pairing, expected_ids: ["a"], position: 1}] = violations
    end

    test "no_orphan_tool_results: a tool result needs a preceding tool_use" do
      assert {:error, violations} = Preflight.validate([assistant_text("done"), tool_result("a")])

      assert [%{rule: :no_orphan_tool_results, orphan_ids: ["a"], position: 1}] = violations
    end

    test "alternation: no two consecutive user roles" do
      assert {:error, violations} = Preflight.validate([user_text("a"), user_text("b")])

      assert [%{rule: :alternation, position: 1}] = violations
    end

    test "no_trailing_orphan: the list must not end with an unpaired tool_use" do
      assert {:error, violations} = Preflight.validate([assistant_tool_use("a")])

      assert [%{rule: :no_trailing_orphan, expected_ids: ["a"], position: 1}] = violations
    end

    test "unions violations across rules (does not stop at the first)" do
      # A mismatched id pair reports a missing result (tool_pairing)
      # and an orphan result (no_orphan_tool_results) together.
      assert {:error, violations} =
               Preflight.validate([assistant_tool_use("a"), tool_result("b")])

      rules = violations |> Enum.map(& &1.rule) |> Enum.uniq()
      assert :tool_pairing in rules
      assert :no_orphan_tool_results in rules
    end

    test "format_violations/1 names the rule and ids" do
      {:error, violations} = Preflight.validate([assistant_tool_use("a"), user_text("hi")])
      text = Preflight.format_violations(violations)

      assert text =~ "wire preflight"
      assert text =~ "tool_pairing"
      assert text =~ "a"
    end
  end
end
