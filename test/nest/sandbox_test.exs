defmodule Nest.SandboxTest do
  use ExUnit.Case, async: true

  alias Nest.Sandbox

  describe "default_caps/0" do
    test "returns the all-writable 'build' profile" do
      assert Sandbox.default_caps() == %{
               "net" => false,
               "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
             }
    end
  end

  describe "build_default/2" do
    test "produces args for the build profile (workspace + /tmp writable)" do
      {:ok, args} = Sandbox.build_default("/workspace", "/tmp/agent-1")
      assert "--unshare-net" in args
      assert "--ro-bind" in args
      assert "--bind" in args
      assert "--dev" in args

      # Workspace is bound RW because the default caps include :workspace.
      workspace_idx = Enum.find_index(args, &(&1 == "/workspace"))
      assert workspace_idx != nil
      assert Enum.at(args, workspace_idx - 1) == "--bind"
      assert Enum.at(args, workspace_idx + 1) == "/workspace"
    end

    test "includes --bind tmp_path /tmp when tmp_path is provided" do
      {:ok, args} = Sandbox.build_default("/workspace", "/tmp/foo")
      assert "--bind" in args
      assert "/tmp/foo" in args
    end

    test "does not include --bind tmp_path /tmp when tmp_path is nil" do
      {:ok, args} = Sandbox.build_default("/workspace", nil)
      # /tmp appears nowhere in args when there's no tmp_path to bind
      refute "/tmp" in args
    end
  end

  describe "build/3 with net caps" do
    test "net=true includes --share-net and omits --unshare-net" do
      caps = build_caps(net: true, write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      assert "--share-net" in args
      refute "--unshare-net" in args
    end

    test "net=false includes --unshare-net" do
      caps = build_caps(net: false, write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      assert "--unshare-net" in args
    end
  end

  describe "build/3 with fs.read caps" do
    test "read=['/'] includes --ro-bind / /" do
      caps = build_caps(read: ["/"], write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      assert "--ro-bind" in args
      assert "/" in args
    end

    test "read=[] returns an error (bwrap needs /bin/sh)" do
      caps = build_caps(read: [], write: [":workspace"])
      assert {:error, msg} = Sandbox.build(caps, "/workspace", nil)
      assert msg =~ "caps.fs.read must include"
    end
  end

  describe "build/3 with fs.write caps" do
    test "write=[] (no extras) does NOT bind the workspace" do
      # Plan mode: workspace stays read-only via the / ro-bind.
      caps = build_caps(write: [])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)

      # No --bind at all (workspace not bound, no /tmp bind, no extras).
      refute "--bind" in args
    end

    test "write=[\":workspace\"] binds the workspace read-write" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/Users/me/proj", nil)

      # The workspace is bound at its actual path.
      workspace_idx = Enum.find_index(args, &(&1 == "/Users/me/proj"))
      assert workspace_idx != nil
      assert Enum.at(args, workspace_idx - 1) == "--bind"
      assert Enum.at(args, workspace_idx + 1) == "/Users/me/proj"
    end

    test ~s(write=[":workspace", "/tmp"] binds workspace + tmp via tmp_path) do
      caps = build_caps(write: ["/tmp", ":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")

      # Two --bind directives: workspace and tmp
      assert Enum.count(args, &(&1 == "--bind")) == 2
      caps = build_caps(write: ["/tmp", ":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")

      # Two --bind directives: workspace and tmp
      assert Enum.count(args, &(&1 == "--bind")) == 2
      # The /tmp in args is the tmp_path bind (NOT a caps-derived bind)
      tmp_indices = args |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))
      assert length(tmp_indices) == 1
      {_, idx} = hd(tmp_indices)
      assert Enum.at(args, idx - 1) == "/tmp/agent-1"
    end

    test "write=[\"/some/extra\"] binds the extra path, NOT the workspace" do
      caps = build_caps(write: ["/some/extra"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)

      # /some/extra is bound
      assert Enum.count(args, &(&1 == "--bind")) == 1
      # Workspace path does NOT appear as a --bind target. (It does
      # appear once more as the --chdir argument, which is fine.)
      bind_count =
        args
        |> Enum.with_index()
        |> Enum.count(fn
          {"/workspace", i} -> Enum.at(args, i - 1) == "--bind"
          _ -> false
        end)

      assert bind_count == 0
    end

    test "write=[\"/tmp\"] does not produce a redundant /tmp --bind" do
      # The /tmp symbolic entry is resolved by append_tmp_bind/2; the
      # write list entry should be rejected to avoid a double bind.
      caps = build_caps(write: ["/tmp"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")

      # Only the tmp_path bind; no extra --bind /tmp /tmp
      assert Enum.count(args, &(&1 == "--bind")) == 1
    end

    test "write includes the literal workspace_path: no double bind" do
      caps = build_caps(write: ["/workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      # The literal /workspace matches the rejection list (it equals
      # workspace_path), so no --bind is produced.
      refute "--bind" in args
    end
  end

  describe "build/3 tmp_path" do
    test "tmp_path=nil produces no /tmp bind" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      refute "/tmp" in args
    end

    test "tmp_path provided produces --bind tmp_path /tmp" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")
      tmp_indices = args |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))

      assert length(tmp_indices) == 1
      {_, idx} = hd(tmp_indices)
      assert Enum.at(args, idx - 2) == "--bind"
      assert Enum.at(args, idx - 1) == "/tmp/agent-1"
    end
  end

  describe "arg ordering (regression)" do
    test "--dev /dev appears AFTER --ro-bind / /" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      ro_bind_idx = Enum.find_index(args, &(&1 == "--ro-bind"))
      dev_idx = Enum.find_index(args, &(&1 == "--dev"))

      assert ro_bind_idx < dev_idx,
             "expected --ro-bind before --dev (bwrap arg order regression)"
    end
  end

  describe "validate_caps/1" do
    test "valid caps return :ok" do
      assert :ok = Sandbox.validate_caps(build_caps())
    end

    test "valid caps with :workspace and /tmp in write list" do
      assert :ok =
               Sandbox.validate_caps(build_caps(write: ["/tmp", ":workspace"]))
    end

    test "missing net" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "fs" => %{"read" => ["/"], "write" => []}
               })

      assert msg =~ "caps.net is required"
    end

    test "missing fs" do
      assert {:error, msg} = Sandbox.validate_caps(%{"net" => true})
      assert msg =~ "caps.fs is required"
    end

    test "fs.read not a list" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => "/", "write" => []}
               })

      assert msg =~ "caps.fs.read must be a list"
    end

    test "fs.write not a list" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => ["/"], "write" => nil}
               })

      assert msg =~ "caps.fs.write must be a list"
    end

    test "fs not a map" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{"net" => true, "fs" => []})

      assert msg =~ "caps.fs must be a map"
    end

    test "read entries not all strings" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => ["/", 42], "write" => []}
               })

      assert msg =~ "caps.fs.read entries must be strings"
    end

    test "write entries not all strings" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => ["/"], "write" => ["/foo", :bar]}
               })

      assert msg =~ "caps.fs.write entries must be strings"
    end

    test "non-map caps" do
      assert {:error, msg} = Sandbox.validate_caps("not a map")
      assert msg =~ "invalid caps"
    end
  end

  # Helpers

  defp build_caps(opts \\ []) do
    %{
      "net" => Keyword.get(opts, :net, false),
      "fs" => %{
        "read" => Keyword.get(opts, :read, ["/"]),
        "write" => Keyword.get(opts, :write, [])
      }
    }
  end
end
