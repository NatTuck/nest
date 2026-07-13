defmodule Nest.Agents.Agent.ChatTurn.BudgetReminderTest do
  @moduledoc """
  Tests for the tool-call budget reminder.

  The wire-shape decision (System vs User-bracket) is delegated
  to `Nest.Agents.Agent.ChatTurn.LateMessage.build/2`. These
  tests assert that the budget reminder carries the right
  threshold text AND routes through the right shape per the
  provider's `rewrite_late_system_messages` flag.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.BudgetReminder
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User

  defp rewrite_on, do: %ClientConfig{rewrite_late_system_messages: true}
  defp rewrite_off, do: %ClientConfig{rewrite_late_system_messages: false}

  describe "build/2 returning nil" do
    test "above the warning band (more than 2 rounds remaining)" do
      assert BudgetReminder.build(5, rewrite_off()) == nil
    end

    test "at the cap (0 remaining or fewer)" do
      assert BudgetReminder.build(0, rewrite_off()) == nil
      assert BudgetReminder.build(-1, rewrite_off()) == nil
    end

    test "with non-integer remaining (defensive)" do
      assert BudgetReminder.build(nil, rewrite_off()) == nil
      assert BudgetReminder.build("2", rewrite_off()) == nil
    end
  end

  describe "build/2 with rewrite off (default path)" do
    test "remaining=2 returns a {:system, %System{}} tuple" do
      full = "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

      assert {:system, %System{parts: [%Part.Text{text: ^full}]}} =
               BudgetReminder.build(2, rewrite_off())
    end

    test "remaining=1 returns the last-round message as a {:system, %System{}} tuple" do
      full =
        "This is your last tool call round. After this, no more tools will be available — provide your final response."

      assert {:system, %System{parts: [%Part.Text{text: ^full}]}} =
               BudgetReminder.build(1, rewrite_off())
    end
  end

  describe "build/2 with rewrite on" do
    test "remaining=2 returns a {:user, %User{}} bracket-wrapped tuple" do
      inner = "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."
      bracketed = "[System notice: " <> inner <> "]"

      assert {:user, %User{parts: [%Part.Text{text: ^bracketed}]}} =
               BudgetReminder.build(2, rewrite_on())
    end

    test "remaining=1 returns a {:user, %User{}} bracket-wrapped tuple" do
      inner =
        "This is your last tool call round. After this, no more tools will be available — provide your final response."

      bracketed = "[System notice: " <> inner <> "]"

      assert {:user, %User{parts: [%Part.Text{text: ^bracketed}]}} =
               BudgetReminder.build(1, rewrite_on())
    end
  end

  describe "build/1 backward-compat form" do
    test "always returns the System shape regardless of any flag" do
      full = "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

      assert {:system, %System{parts: [%Part.Text{text: ^full}]}} =
               BudgetReminder.build(2)
    end

    test "returns nil above the warning band" do
      assert BudgetReminder.build(3) == nil
    end
  end
end
