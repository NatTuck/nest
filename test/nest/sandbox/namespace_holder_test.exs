defmodule Nest.Sandbox.NamespaceHolderTest do
  @moduledoc """
  The per-space persistent namespace (#224): the holder manager, the join-mode
  argument builder, and the properties a joined command must keep — non-root,
  shared pid namespace, nat-owned files, per-mode mounts, network isolation —
  plus the fresh-namespace fallback when a space has no holder.
  """

  use ExUnit.Case, async: true

  import Eventually
  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup

  alias Nest.Sandbox
  alias Nest.Sandbox.{Backend, Mounts, NamespaceHolder}
  alias Nest.Tools.ShellCmd

  setup do
    space_id = System.unique_integer([:positive])
    ws = Path.join([File.cwd!(), "_build", "tmp", "nest_ns_ws_#{space_id}"])
    root = Path.join(System.tmp_dir!(), "nest_ns_#{space_id}")
    scratch = Path.join([root, "space", "agent"])
    File.mkdir_p!(ws)
    File.mkdir_p!(scratch)

    on_exit(fn ->
      NamespaceHolder.stop_space(space_id)
      rm_tmp!(ws, "nest_ns_ws_")
      rm_tmp!(root, "nest_ns_")
    end)

    %{space_id: space_id, ws: ws, scratch: scratch}
  end

  defp mounts(ctx, net \\ false),
    do: Mounts.new(ctx.ws, ctx.scratch, "bwrap", ctx.space_id, net)

  defp run(command, mounts, caps), do: ShellCmd.execute_raw(command, mounts, caps)

  defp runtime_uid do
    {uid, 0} = System.cmd("id", ["-u"])
    uid |> String.trim() |> String.to_integer()
  end

  describe "build_join/2" do
    test "shares the holder's namespaces: no --unshare-all, net inherited when enabled" do
      caps = Map.put(Nest.Modes.caps("act"), "net", true)
      {:ok, args} = Sandbox.build_join(caps, Mounts.new(nil, nil, "bwrap", 1, true))

      refute "--unshare-all" in args
      assert "--die-with-parent" in args
      assert "--new-session" in args
      # join + net=true inherits the holder's net: neither net flag appears.
      refute "--share-net" in args
      refute "--unshare-net" in args
    end

    test "still unshares a fresh network namespace when net is disabled" do
      caps = Nest.Modes.caps("plan")
      {:ok, args} = Sandbox.build_join(caps, Mounts.new(nil, nil, "bwrap", 1, false))

      refute "--unshare-all" in args
      assert "--unshare-net" in args
      # The mode's binds are unchanged: plan keeps the workspace read-only.
      refute "--bind" in args
    end
  end

  describe "the holder manager" do
    test "ensure starts a holder, reuses it, and stop_space tears it down", ctx do
      assert {:ok, first} = NamespaceHolder.ensure(ctx.space_id)
      assert {:ok, again} = NamespaceHolder.ensure(ctx.space_id)
      assert again.generation == first.generation
      assert again.holder_pid == first.holder_pid
      assert File.exists?("/proc/#{first.holder_pid}")

      assert :ok = NamespaceHolder.stop_space(ctx.space_id)

      assert eventually(fn -> not File.exists?("/proc/#{first.holder_pid}") end, timeout: 1_000)
    end

    test "a holder that dies is restarted with a new generation", ctx do
      assert {:ok, first} = NamespaceHolder.ensure(ctx.space_id)

      # SIGKILL the verified holder child — PID 1 of its own isolated pid
      # namespace, so this is contained and cannot reach a host process. The
      # manager logs the loss and restarts; capture that expected warning.
      log =
        capture_log(fn ->
          System.cmd("kill", ["-9", first.holder_pid])

          assert eventually(
                   fn ->
                     case NamespaceHolder.ensure(ctx.space_id) do
                       {:ok, fresh} -> fresh.generation != first.generation
                       :error -> false
                     end
                   end,
                   timeout: 1_500
                 )
        end)

      assert log =~ "restarting"
    end

    test "ensure/1 with no space is :error (the fresh-namespace fallback)" do
      assert NamespaceHolder.ensure(nil) == :error
    end
  end

  describe "a joined command" do
    test "runs as the invoking user, owns its files, and shares the space pid namespace", ctx do
      m = mounts(ctx)
      caps = Nest.Modes.caps("act")
      uid = runtime_uid()

      assert {:ok, 0, id_out, _} = run("id -u", m, caps)
      assert String.trim(id_out) == Integer.to_string(uid)
      refute uid == 0

      assert {:ok, 0, _, _} = run("touch #{ctx.ws}/owned", m, caps)
      assert File.stat!(Path.join(ctx.ws, "owned")).uid == uid

      # Orphan a distinctly-named marker in the shared namespace; a second
      # command sees it (the holder's own loop is `sleep 1`, not `sleep 30`).
      assert {:ok, 0, _, _} = run("sleep 30 & echo started", m, caps)

      assert eventually(
               fn ->
                 {:ok, 0, ps, _} = run("ps -eo args", m, caps)
                 String.contains?(ps, "sleep 30")
               end,
               timeout: 1_000
             )
    end

    test "plan mode keeps the workspace read-only while joined", ctx do
      m = mounts(ctx)
      caps = Nest.Modes.caps("plan")

      assert {:ok, code, _, err} = run("touch #{ctx.ws}/nope", m, caps)
      assert code != 0
      assert err =~ "Read-only"
      refute File.exists?(Path.join(ctx.ws, "nope"))
    end

    test "net disabled sees only loopback while joined", ctx do
      m = mounts(ctx, false)
      caps = Nest.Modes.caps("act")

      assert {:ok, 0, out, _} = run("cat /proc/net/dev", m, caps)
      assert out =~ "lo:"
      refute out =~ "eth0"
    end
  end

  describe "the command line" do
    test "a space with a holder joins it; a call with no space stays fresh", ctx do
      {:ok, joined} = Backend.Bwrap.command(mounts(ctx), Nest.Modes.caps("act"), "/tmp/x.sh")
      assert joined.command =~ "/bin/bash -c 'exec {u}"
      assert joined.command =~ "--userns"
      refute joined.command =~ "--unshare-all"

      fresh_mounts = Mounts.new(nil, nil, "bwrap", nil, false)
      {:ok, fresh} = Backend.Bwrap.command(fresh_mounts, Nest.Modes.caps("act"), "/tmp/x.sh")
      assert fresh.command =~ "--unshare-all"
      refute fresh.command =~ "--userns"
    end
  end
end
