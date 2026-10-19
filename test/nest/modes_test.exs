defmodule Nest.ModesTest do
  @moduledoc """
  The two universal modes: their names, the caps they resolve to, the monotone
  rule's arithmetic, and the catalog.

  Everything here is a constant, so this is the whole contract of the module the
  rest of the system builds on.
  """

  use ExUnit.Case, async: true

  alias Nest.Modes

  describe "the modes" do
    test "are plan and act, least permissive first" do
      assert Modes.names() == ["plan", "act"]
      assert Modes.plan() == "plan"
      assert Modes.act() == "act"
    end

    test "are validated by name, not by shape" do
      for name <- Modes.names(), do: assert(Modes.valid?(name))

      refute Modes.valid?("chat")
      refute Modes.valid?(nil)
      refute Modes.valid?(:plan)
    end
  end

  describe "caps/1" do
    test "plan writes the scratch, act adds the workspace" do
      assert Modes.caps("plan") ==
               %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}

      assert Modes.caps("act") ==
               %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}}
    end

    test "the caps are the shape the sandbox reads" do
      for name <- Modes.names() do
        assert :ok = Nest.Sandbox.validate_caps(Modes.caps(name))
      end
    end

    test "an unknown mode resolves to the default, never to nothing" do
      # A stale row, or a client that made a name up, must not become a mode with
      # no restrictions at all — nor one with no caps.
      assert Modes.caps("chat") == Modes.caps(Modes.default())
      assert Modes.caps(nil) == Modes.caps(Modes.default())
    end
  end

  describe "allows?/2 (the monotone rule's arithmetic)" do
    test "an agent may hold its own mode, or lower it" do
      assert Modes.allows?("act", "act")
      assert Modes.allows?("act", "plan")
    end

    test "an agent may not raise a mode" do
      refute Modes.allows?("plan", "act")
    end

    test "a name this build does not know is refused, from either side" do
      refute Modes.allows?("act", "chat")
      refute Modes.allows?("chat", "plan")
      refute Modes.allows?(nil, "plan")
    end
  end

  describe "catalog/2" do
    test "is empty for an agent with no tools" do
      # With no tools there is nothing for a mode to restrict, so the section
      # would describe a distinction the agent cannot act on. (The `compact`
      # contract is rendered by `SystemPrompt`, not here — a tool-less agent still
      # compacts.)
      assert Modes.catalog(false, true) == ""
    end

    test "names both modes and says the mode arrives with every message" do
      catalog = Modes.catalog(true, true)

      assert catalog =~ "[Available modes]"
      assert catalog =~ "**`plan`**"
      assert catalog =~ "**`act`**"
      assert catalog =~ "shown on every message you receive"
      assert catalog =~ "prefix on a message from the user"
      assert catalog =~ "header of a message from another agent"
      refute catalog =~ "compact"
    end

    test "says whether the space enforces the restriction" do
      enforced = Modes.catalog(true, true)
      unenforced = Modes.catalog(true, false)

      assert enforced =~ "is enforced by the sandbox"
      assert unenforced =~ "cannot enforce"
      assert unenforced =~ "on you"

      refute enforced =~ "cannot enforce"
      refute unenforced =~ "is enforced by the sandbox"
    end
  end
end
