defmodule Nest.Agents.Agent.ModeAuthorityTest do
  @moduledoc """
  The monotone rule: who may move whom between modes, and what a refusal says.

  The rule is the whole point of `ModeAuthority` — one place, so the spawn, a
  message's `set_mode` and the human's own path cannot disagree about it.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ModeAuthority
  alias Nest.Agents.ChildRegistry

  # `ChildRegistry` is the live parent/child tree, started by the application,
  # and it is shared by every test in this suite — so each test works in a space
  # of its own rather than registering into a space another test is using.
  defp space, do: System.unique_integer([:positive])

  # An agent actor in `mode`, acting on `target` (`:child` for a spawn, else the
  # target's name).
  defp agent(mode, target, name \\ "boss", space_id \\ space()) do
    %{kind: :agent, space_id: space_id, name: name, mode: mode, target: target}
  end

  describe "the human" do
    test "may set any agent's mode to anything" do
      assert :ok = ModeAuthority.authorize(%{kind: :human}, "act")
      assert :ok = ModeAuthority.authorize(%{kind: :human}, "plan")
    end

    test "is still held to the modes that exist" do
      assert {:error, reason} = ModeAuthority.authorize(%{kind: :human}, "chat")
      assert reason =~ "not a mode"
      assert reason =~ "plan"
      assert reason =~ "act"
    end
  end

  describe "an agent and its own mode" do
    test "may never set its own mode, not even to lower it" do
      # Self-escalation is the thing the rule exists to prevent, and an agent
      # that could set its own mode could set it back — including by sending
      # itself a message carrying `set_mode`.
      for {from, to} <- [{"act", "act"}, {"act", "plan"}, {"plan", "plan"}] do
        assert {:error, reason} = ModeAuthority.authorize(agent(from, "boss"), to)
        assert reason =~ "self-escalation"
      end
    end
  end

  describe "an agent and a descendant" do
    test "may hold its own mode or lower it" do
      space = space()
      ChildRegistry.register(space, "boss", "worker")

      assert :ok = ModeAuthority.authorize(agent("act", "worker", "boss", space), "act")
      assert :ok = ModeAuthority.authorize(agent("act", "worker", "boss", space), "plan")
      assert :ok = ModeAuthority.authorize(agent("plan", "worker", "boss", space), "plan")
    end

    test "may not raise it, and the refusal says why" do
      space = space()
      ChildRegistry.register(space, "boss", "worker")

      assert {:error, reason} =
               ModeAuthority.authorize(agent("plan", "worker", "boss", space), "act")

      assert reason =~ "`plan`"
      assert reason =~ "`act`"
      assert reason =~ "never raised"
      assert reason =~ "user"
    end

    test "reaches a grandchild too" do
      space = space()
      ChildRegistry.register(space, "boss", "worker")
      ChildRegistry.register(space, "worker", "grandchild")

      assert :ok = ModeAuthority.authorize(agent("act", "grandchild", "boss", space), "plan")
      refute :ok == ModeAuthority.authorize(agent("plan", "grandchild", "boss", space), "act")
    end

    test "may not touch an agent it did not spawn" do
      space = space()
      ChildRegistry.register(space, "other", "stranger")

      assert {:error, reason} =
               ModeAuthority.authorize(agent("act", "stranger", "boss", space), "plan")

      assert reason =~ "stranger"
      assert reason =~ "descendant"
      assert reason =~ "user"
    end

    test "may not touch an agent that is nobody's descendant" do
      space = space()

      assert {:error, reason} =
               ModeAuthority.authorize(agent("act", "nobody", "boss", space), "plan")

      assert reason =~ "not one"
    end
  end

  describe "an agent and a spawn" do
    test "may spawn a child at its own mode or lower" do
      assert :ok = ModeAuthority.authorize(agent("act", :child), "act")
      assert :ok = ModeAuthority.authorize(agent("act", :child), "plan")
      assert :ok = ModeAuthority.authorize(agent("plan", :child), "plan")
    end

    test "may not spawn a child above it" do
      # The rule covers the spawn as much as a later change: a `plan` parent may
      # not create an `act` child, nor create one and then raise it.
      assert {:error, reason} = ModeAuthority.authorize(agent("plan", :child), "act")
      assert reason =~ "a child you spawn"
      assert reason =~ "never raised"
    end
  end

  describe "a mode that does not exist" do
    test "is refused from either side" do
      space = space()
      assert {:error, _} = ModeAuthority.authorize(agent("act", "worker", "boss", space), "chat")
      assert {:error, _} = ModeAuthority.authorize(agent("chat", :child), "plan")
    end

    test "and an actor with no mode can set nothing" do
      refute :ok == ModeAuthority.authorize(agent(nil, :child), "plan")
    end
  end
end
