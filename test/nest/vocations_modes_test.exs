defmodule Nest.VocationsModesTest do
  @moduledoc """
  Tests for the `Vocations` modes / caps surface — split from
  `VocationsTest` so the parent file stays under the credo
  500-line cap. Same data setup (shared `@valid_caps` and
  `@plan_caps` module attributes) — duplicated here so the
  split file can run independently.

  Covers:

    * `modes` field validation in the changeset
    * `get_caps/2` lookup (with the default-caps fallback)
    * `list_modes/1` (sorted, with chat fallback)
    * `default_mode/1` (first sorted, with chat fallback)
    * `mode_catalog/1` (the LLM-facing mode description string)
  """

  use Nest.DataCase, async: true

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
        name: "Programmer",
        description: "Builds software",
        system_prompt: "You are a programmer.",
        tools: ["file-read", "file-write"],
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
        name: "Chatty",
        description: "Just chat",
        system_prompt: "You chat.",
        modes: nil
      }

      assert {:ok, %Vocation{}} = Vocations.create_vocation(attrs)
    end

    test "empty modes pass validation" do
      attrs = %{
        name: "Chatty",
        description: "Just chat",
        system_prompt: "You chat.",
        modes: %{}
      }

      assert {:ok, %Vocation{}} = Vocations.create_vocation(attrs)
    end

    test "mode missing caps returns changeset error" do
      attrs = %{
        name: "Bad",
        description: "Bad",
        system_prompt: "Bad",
        modes: %{"build" => %{"description" => "no caps here"}}
      }

      assert {:error, changeset} = Vocations.create_vocation(attrs)
      assert errors_on(changeset).modes |> List.first() =~ ~s/build: mode must be a map/
    end

    test "mode with invalid caps returns changeset error" do
      attrs = %{
        name: "Bad",
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
        name: "Bad",
        description: "Bad",
        system_prompt: "Bad",
        modes: %{"build" => "not a map"}
      }

      assert {:error, changeset} = Vocations.create_vocation(attrs)
      assert errors_on(changeset).modes |> List.first() =~ "build: mode must be a map"
    end
  end

  describe "get_caps/2" do
    test "returns caps for an existing mode" do
      vocation = %Vocation{
        modes: %{"build" => %{"caps" => @valid_caps}, "plan" => %{"caps" => @valid_caps}}
      }

      assert {:ok, caps} = Vocations.get_caps(vocation, "build")
      assert caps == @valid_caps
    end

    test "returns :unknown_mode for a missing mode" do
      vocation = %Vocation{modes: %{"build" => %{"caps" => @valid_caps}}}
      assert {:error, :unknown_mode} = Vocations.get_caps(vocation, "nonexistent")
    end

    test "returns default caps for \"chat\" on a vocation with no modes" do
      vocation = %Vocation{modes: nil}
      assert {:ok, caps} = Vocations.get_caps(vocation, "chat")
      assert caps == Nest.Sandbox.default_caps()
    end

    test "returns default caps for \"chat\" on a nil vocation" do
      assert {:ok, caps} = Vocations.get_caps(nil, "chat")
      assert caps == Nest.Sandbox.default_caps()
    end

    test "returns :unknown_mode for non-chat on a vocation with no modes" do
      assert {:error, :unknown_mode} = Vocations.get_caps(nil, "build")
      assert {:error, :unknown_mode} = Vocations.get_caps(%Vocation{modes: nil}, "build")
    end

    test "returns :unknown_mode when the mode has no caps key" do
      vocation = %Vocation{modes: %{"build" => %{"description" => "no caps"}}}
      assert {:error, :unknown_mode} = Vocations.get_caps(vocation, "build")
    end
  end

  describe "list_modes/1" do
    test "returns sorted mode names" do
      vocation = %Vocation{
        modes: %{
          "plan" => %{"caps" => @valid_caps},
          "build" => %{"caps" => @valid_caps},
          "audit" => %{"caps" => @valid_caps}
        }
      }

      assert Vocations.list_modes(vocation) == ["audit", "build", "plan"]
    end

    test "returns [\"chat\"] for a vocation with nil modes" do
      assert Vocations.list_modes(nil) == ["chat"]
      assert Vocations.list_modes(%Vocation{modes: nil}) == ["chat"]
    end

    test "returns [\"chat\"] for a vocation with empty modes" do
      assert Vocations.list_modes(%Vocation{modes: %{}}) == ["chat"]
    end
  end

  describe "default_mode/1" do
    test "returns the first sorted mode" do
      vocation = %Vocation{
        modes: %{
          "plan" => %{"caps" => @valid_caps},
          "audit" => %{"caps" => @valid_caps}
        }
      }

      assert Vocations.default_mode(vocation) == "audit"
    end

    test "returns \"chat\" for a vocation with no modes" do
      assert Vocations.default_mode(nil) == "chat"
      assert Vocations.default_mode(%Vocation{modes: nil}) == ["chat"] |> hd()
    end
  end

  describe "mode_catalog/1" do
    test "builds a sorted catalog with caps-derived paths followed by the description" do
      vocation = %Vocation{
        name: "Programmer",
        modes: %{
          "build" => %{
            "description" => "You're clear to edit the project in the workspace.",
            "caps" => @valid_caps
          },
          "plan" => %{
            "description" => "Read-only planning only, can still run commands.",
            "caps" => @plan_caps
          }
        }
      }

      catalog = Vocations.mode_catalog(vocation)

      assert catalog =~ "\n\n[Available modes]\n"

      assert catalog =~
               ~s(- build: Read only "/". Read and write workspace and /tmp. Network disabled. You're clear to edit the project in the workspace.)

      assert catalog =~
               ~s(- plan: Read only "/". Read and write /tmp. Network disabled. Read-only planning only, can still run commands.)
    end

    test "plan mode without :workspace does NOT say workspace is writable" do
      vocation = %Vocation{
        name: "Programmer",
        modes: %{
          "plan" => %{
            "description" => "Read-only planning.",
            "caps" => @plan_caps
          }
        }
      }

      catalog = Vocations.mode_catalog(vocation)

      refute catalog =~ "Read and write workspace"
      assert catalog =~ "plan: Read only \"/\". Read and write /tmp."
    end
  end
end
