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
end
