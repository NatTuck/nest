defmodule Nest.VocationsModesTest do
  @moduledoc """
  Tests for the `Vocations` modes / caps surface — split from
  `VocationsTest` so the parent file stays under the credo
  500-line cap.

  The modes themselves are universal code constants (`Nest.Modes`), so what is
  left to test here is the *schema*: the `modes` column's validation (it is dead
  data from this stage on, and stage 4 drops it), and the three functions that
  used to read it and now answer from the constants.
  """

  use Nest.DataCase, async: true

  alias Nest.Modes
  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  @valid_caps %{
    "net" => false,
    "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
  }

  @plan_caps %{
    "net" => false,
    "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
  }

  describe "modes changeset validation" do
    test "valid modes with caps pass validation" do
      attrs = %{
        name: "Programmer #{System.unique_integer([:positive])}",
        description: "Builds software",
        system_prompt: "You are a programmer.",
        tools: ["file"],
        modes: %{
          "build" => %{"caps" => @valid_caps, "description" => "Full build mode"},
          "plan" => %{"caps" => @valid_caps}
        }
      }

      assert {:ok, %Vocation{} = v} = Vocations.create_vocation(attrs)
      assert v.modes["build"]["caps"] == @valid_caps
    end

    test "nil modes pass validation (legacy vocations)" do
      attrs = %{
        name: "Chatty #{System.unique_integer([:positive])}",
        description: "Just chat",
        system_prompt: "You chat.",
        modes: nil
      }

      assert {:ok, %Vocation{}} = Vocations.create_vocation(attrs)
    end

    test "empty modes pass validation" do
      attrs = %{
        name: "Chatty #{System.unique_integer([:positive])}",
        description: "Just chat",
        system_prompt: "You chat.",
        modes: %{}
      }

      assert {:ok, %Vocation{}} = Vocations.create_vocation(attrs)
    end

    test "mode missing caps returns changeset error" do
      attrs = %{
        name: "Bad #{System.unique_integer([:positive])}",
        description: "Bad",
        system_prompt: "Bad",
        modes: %{"build" => %{"description" => "no caps here"}}
      }

      assert {:error, changeset} = Vocations.create_vocation(attrs)
      assert errors_on(changeset).modes |> List.first() =~ ~s/build: mode must be a map/
    end

    test "mode with invalid caps returns changeset error" do
      attrs = %{
        name: "Bad #{System.unique_integer([:positive])}",
        description: "Bad",
        system_prompt: "Bad",
        modes: %{
          "build" => %{
            "caps" => %{"net" => true, "fs" => %{"read" => [], "write" => []}}
          }
        }
      }

      assert {:error, changeset} = Vocations.create_vocation(attrs)
      assert errors_on(changeset).modes |> List.first() =~ "build: caps.fs.read must include"
    end

    test "mode that is not a map returns changeset error" do
      attrs = %{
        name: "Bad #{System.unique_integer([:positive])}",
        description: "Bad",
        system_prompt: "Bad",
        modes: %{"build" => "not a map"}
      }

      assert {:error, changeset} = Vocations.create_vocation(attrs)
      assert errors_on(changeset).modes |> List.first() =~ "build: mode must be a map"
    end
  end

  describe "get_caps/2" do
    test "returns the universal caps for a mode, whatever the vocation says" do
      # Two vocations whose stored `modes` disagree with each other and with the
      # constants: the answer is the constant either way, because the column is
      # dead data from here on.
      one = %Vocation{modes: %{"plan" => %{"caps" => @valid_caps}}}
      two = %Vocation{modes: %{"act" => %{"caps" => @plan_caps}}}
      none = %Vocation{modes: nil}

      for vocation <- [one, two, none, nil] do
        assert {:ok, caps} = Vocations.get_caps(vocation, "plan")
        assert caps == Modes.caps("plan")

        assert {:ok, caps} = Vocations.get_caps(vocation, "act")
        assert caps == Modes.caps("act")
      end
    end

    test "returns :unknown_mode for a name this build does not implement" do
      for name <- ["chat", "build", "nonexistent", ""] do
        assert {:error, :unknown_mode} = Vocations.get_caps(nil, name)
        assert {:error, :unknown_mode} = Vocations.get_caps(%Vocation{modes: nil}, name)
      end
    end
  end

  describe "list_modes/1" do
    test "is every mode, for every vocation" do
      # The vocation is ignored: the modes are universal. `compact` is
      # deliberately not in the list — it is a protocol marker that rides the
      # `[mode: …]` prefix, not a mode an agent can be in.
      for vocation <- [
            nil,
            %Vocation{modes: nil},
            %Vocation{modes: %{}},
            %Vocation{modes: %{"plan" => %{"caps" => @valid_caps}}},
            %Vocation{modes: %{"build" => %{"caps" => @valid_caps}, "audit" => %{}}}
          ] do
        assert Vocations.list_modes(vocation) == ["plan", "act"]
      end
    end

    test "agrees with the constants it now answers from" do
      assert Vocations.list_modes(nil) == Modes.names()
      refute "compact" in Vocations.list_modes(nil)
    end
  end

  describe "requires_workspace?/1" do
    test "is true for every vocation, because every space has a workspace" do
      # It used to be derived from the mode caps (a vocation needed a workspace
      # iff some mode wrote `:workspace`). Now `act` is the only thing that
      # writes it and every agent can be in `act`, so the answer is a constant.
      for vocation <- [
            nil,
            %Vocation{modes: nil},
            %Vocation{modes: %{}},
            %Vocation{modes: %{"plan" => %{"caps" => @plan_caps}}},
            %Vocation{modes: %{"build" => %{"caps" => @valid_caps}}}
          ] do
        assert Vocations.requires_workspace?(vocation) == true
      end
    end
  end
end
