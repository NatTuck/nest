defmodule Nest.Agents.Agent.ChatTurn.BudgetReminderTest do
  @moduledoc """
  Tests for the tool-call budget reminder notice text.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.BudgetReminder

  describe "notice_text/1 returning nil" do
    test "above the warning band (more than 2 rounds remaining)" do
      assert BudgetReminder.notice_text(5) == nil
    end

    test "at the cap (0 remaining or fewer)" do
      assert BudgetReminder.notice_text(0) == nil
      assert BudgetReminder.notice_text(-1) == nil
    end

    test "with non-integer remaining (defensive)" do
      assert BudgetReminder.notice_text(nil) == nil
      assert BudgetReminder.notice_text("2") == nil
    end
  end

  describe "notice_text/1 with 2 remaining" do
    test "returns the 2-remaining notice text" do
      assert BudgetReminder.notice_text(2) ==
               "2 tool call rounds remaining. Plan your remaining tool use carefully."
    end
  end

  describe "notice_text/1 with 1 remaining" do
    test "returns the last-round notice text" do
      assert BudgetReminder.notice_text(1) ==
               "Last tool call round. Provide your final response after this tool."
    end
  end

  describe "spec/1" do
    test "returns nil above the warning band" do
      assert BudgetReminder.spec(5) == nil
    end

    test "returns nil at the cap" do
      assert BudgetReminder.spec(0) == nil
      assert BudgetReminder.spec(-1) == nil
    end

    test "returns nil with non-integer remaining" do
      assert BudgetReminder.spec(nil) == nil
      assert BudgetReminder.spec("2") == nil
    end

    test "returns a :budget spec with 'Tool limit?' attention and 2-remaining notice" do
      spec = BudgetReminder.spec(2)
      assert spec.kind == :budget
      assert spec.attention == "Tool limit?"
      assert spec.notice =~ "2 tool call rounds remaining"
      assert spec.notice =~ "Plan your remaining tool use carefully"
    end

    test "returns a :budget spec with 'Tool limit?' attention and last-round notice" do
      spec = BudgetReminder.spec(1)
      assert spec.kind == :budget
      assert spec.attention == "Tool limit?"
      assert spec.notice =~ "Last tool call round"
      assert spec.notice =~ "final response"
    end
  end

  describe "spec_from_pending/1" do
    test "wraps the pre-computed notice in a :budget spec with 'Tool limit?' attention" do
      spec = BudgetReminder.spec_from_pending("2 tool call rounds remaining. Foo.")
      assert spec.kind == :budget
      assert spec.attention == "Tool limit?"
      assert spec.notice == "2 tool call rounds remaining. Foo."
    end
  end
end
