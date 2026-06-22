defmodule Nest.VocationsTest do
  use Nest.DataCase, async: false

  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  import Nest.VocationsFixtures

  @valid_caps %{
    "net" => false,
    "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
  }

  @plan_caps %{
    "net" => false,
    "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
  }

  describe "vocations" do
    @invalid_attrs %{name: nil, description: nil, modes: nil, tools: nil, system_prompt: nil}

    test "list_vocations/0 returns all vocations" do
      vocation = vocation_fixture()
      assert Vocations.list_vocations() == [vocation]
    end

    test "get_vocation!/1 returns the vocation with given id" do
      vocation = vocation_fixture()
      assert Vocations.get_vocation!(vocation.id) == vocation
    end

    test "create_vocation/1 with valid data creates a vocation" do
      valid_attrs = %{
        name: "some name",
        description: "some description",
        modes: %{},
        tools: [],
        system_prompt: "some system_prompt"
      }

      assert {:ok, %Vocation{} = vocation} = Vocations.create_vocation(valid_attrs)
      assert vocation.name == "some name"
      assert vocation.description == "some description"
      assert vocation.modes == %{}
      assert vocation.tools == []
      assert vocation.system_prompt == "some system_prompt"
    end

    test "create_vocation/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Vocations.create_vocation(@invalid_attrs)
    end

    test "update_vocation/2 with valid data updates the vocation" do
      vocation = vocation_fixture()

      update_attrs = %{
        name: "some updated name",
        description: "some updated description",
        modes: %{},
        tools: [],
        system_prompt: "some updated system_prompt"
      }

      assert {:ok, %Vocation{} = vocation} = Vocations.update_vocation(vocation, update_attrs)
      assert vocation.name == "some updated name"
      assert vocation.description == "some updated description"
      assert vocation.modes == %{}
      assert vocation.tools == []
      assert vocation.system_prompt == "some updated system_prompt"
    end

    test "update_vocation/2 with invalid data returns error changeset" do
      vocation = vocation_fixture()
      assert {:error, %Ecto.Changeset{}} = Vocations.update_vocation(vocation, @invalid_attrs)
      assert vocation == Vocations.get_vocation!(vocation.id)
    end

    test "delete_vocation/1 deletes the vocation" do
      vocation = vocation_fixture()
      assert {:ok, %Vocation{}} = Vocations.delete_vocation(vocation)
      assert_raise Ecto.NoResultsError, fn -> Vocations.get_vocation!(vocation.id) end
    end

    test "change_vocation/1 returns a vocation changeset" do
      vocation = vocation_fixture()
      assert %Ecto.Changeset{} = Vocations.change_vocation(vocation)
    end
  end

  describe "modes changeset validation" do
    test "valid modes with caps pass validation" do
      attrs = %{
        name: "Programmer",
        description: "Builds software",
        system_prompt: "You are a programmer.",
        tools: ["read_file", "write_file"],
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
      # Heading is preceded by a blank line for readability
      assert catalog =~ "\n\n[Available modes]\n"
      # Each mode line: caps-derived sentences, then the description
      assert catalog =~
               ~s(- build: Read only "/". Read and write workspace and /tmp. Network disabled. You're clear to edit the project in the workspace.)

      assert catalog =~
               ~s(- plan: Read only "/". Read and write /tmp. Network disabled. Read-only planning only, can still run commands.)
    end

    test "plan mode without :workspace does NOT say workspace is writable" do
      # This is the key behavior change: plan mode's caps say
      # write: ["/tmp"], so the catalog must reflect that the
      # workspace is read-only.
      vocation = %Vocation{
        name: "Programmer",
        modes: %{
          "plan" => %{
            "description" => "Read-only planning only, can still run commands.",
            "caps" => @plan_caps
          }
        }
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ "Read and write /tmp"
      refute catalog =~ "Read and write workspace"
    end

    test "modes without descriptions still appear (just the caps-derived text)" do
      vocation = %Vocation{
        name: "Test",
        modes: %{"build" => %{"caps" => @valid_caps}}
      }

      catalog = Vocations.mode_catalog(vocation)

      assert catalog =~
               ~s(- build: Read only "/". Read and write workspace and /tmp. Network disabled.)
    end

    test "caps mention Network enabled when net is true" do
      caps_with_net = %{
        "net" => true,
        "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
      }

      vocation = %Vocation{
        modes: %{"online" => %{"caps" => caps_with_net}}
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ "Network enabled"
    end

    test "extra write paths appear after the symbolic :workspace and /tmp" do
      caps_with_extras = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace", "/some/extra"]}
      }

      vocation = %Vocation{
        modes: %{"build" => %{"caps" => caps_with_extras}}
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ ~s(Read and write workspace, /tmp, and "/some/extra")
    end

    test "multiple extra write paths are joined with commas and a final and" do
      caps_multi_write = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace", "/a", "/b", "/c"]}
      }

      vocation = %Vocation{
        modes: %{"multi" => %{"caps" => caps_multi_write}}
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ ~s(Read and write workspace, /tmp, "/a", "/b", and "/c")
    end

    test "real write paths are wrapped in double-quotes" do
      caps_real_path = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace", "/data"]}
      }

      vocation = %Vocation{
        modes: %{"build" => %{"caps" => caps_real_path}}
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ ~s("/data")
    end

    test "read-only read list produces a different read sentence" do
      caps_limited = %{
        "net" => false,
        "fs" => %{"read" => ["/data"], "write" => ["/tmp", ":workspace", "/data"]}
      }

      vocation = %Vocation{
        modes: %{"scoped" => %{"caps" => caps_limited}}
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ ~s(Read only "/data")
      assert catalog =~ ~s(Read and write workspace, /tmp, and "/data")
    end

    test "empty write list produces no Read and write sentence" do
      caps_no_writes = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      vocation = %Vocation{
        modes: %{"locked" => %{"caps" => caps_no_writes}}
      }

      catalog = Vocations.mode_catalog(vocation)
      refute catalog =~ "Read and write"
    end

    test "falls back to a generic label for malformed caps" do
      vocation = %Vocation{
        modes: %{"weird" => %{"caps" => "not a map"}}
      }

      catalog = Vocations.mode_catalog(vocation)
      assert catalog =~ "- weird: custom profile"
    end

    test "returns empty string for nil vocation" do
      assert Vocations.mode_catalog(nil) == ""
    end

    test "returns empty string for vocation with nil modes" do
      vocation = %Vocation{modes: nil}
      assert Vocations.mode_catalog(vocation) == ""
    end

    test "returns empty string for vocation with empty modes" do
      vocation = %Vocation{modes: %{}}
      assert Vocations.mode_catalog(vocation) == ""
    end
  end
end
