defmodule Nest.Agents.Agent.FilePolicyTest do
  @moduledoc """
  Tests for the `write_file` "must read first" / "contents
  changed" policy: the `:check_read_policy` clause of
  `IntrospectionHandler.handle/3`, exercised directly against
  a constructed agent state (cache lookup, on-disk stat
  comparison, path resolution).

  Not covered here or anywhere else: the translation from the
  policy atom to the user-facing tool-result string
  (`BatchSizer.FilePolicy.error_message/1`), the `BatchSizer`
  call site that produces it, and the `LLMStreamHandler`
  recording path that populates the cache (these tests seed
  the cache with `AgentTestHelpers.record_read_file/2`
  instead).
  """

  use Nest.DataCase, async: true

  import Mimic

  import Nest.Test.TmpCleanup

  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    # `Agents.delete_agent/1` does a DB write that requires
    # the test pid's sandbox checkout. In `on_exit` that
    # checkout is gone, so the DB call would deadlock on
    # `DBConnection.OwnershipError`. The DataCase's
    # automatic sandbox rollback covers the agent rows
    # (`Agents.create_agent/2`'s pre_spawn insert is
    # rolled back); the agent GenServers are orphaned for
    # the remainder of the session, but `System.unique_integer/1`
    # names mean other tests' agents don't collide.
    on_exit(fn ->
      Process.delete(:nest_test_agent_pid)
    end)

    :ok
  end

  describe ":check_read_policy" do
    test "returns :ok for a missing-path (defensive passthrough)" do
      # The `BatchSizer.FilePolicy.check/2` call site only
      # fires for `write_file` tool calls, and only those
      # carry a `path` argument. A non-binary `raw_path`
      # short-circuits to `:ok` so a malformed or missing
      # argument doesn't refuse the call at this layer
      # (the `LLMTools.validate_args/2` rejection is the
      # authoritative gate for missing required fields).
      {pid, _name} = start_agent_with_workspace()

      assert GenServer.call(pid, {:check_read_policy, %{path: nil}}) == :ok
    end

    test "returns {:error, :never_read} when the cache is empty (file present)" do
      # The policy only returns `:never_read` when the file is
      # PRESENT on disk — i.e. there's something to overwrite
      # and the agent hasn't read it. (The "create new file"
      # case is covered by `returns :ok for a never-existed
      # path` below — when there's no file, the user
      # explicitly says "if there's no file, allow, no
      # further checks".)
      {pid, _name} = start_agent_with_workspace()
      write_test_file(pid, "foo.txt", "exists\n")

      assert GenServer.call(pid, {:check_read_policy, %{path: "foo.txt"}}) ==
               {:error, :never_read}
    end

    test "returns :ok after a fresh read_file (cache seeded with on-disk mtime/size)" do
      # The streaming `read_file` tool result populates the
      # cache from `File.stat(path)`. We exercise the same
      # code path by writing a real file, then calling
      # `record_read_file/3` (the test helper that mirrors
      # what `LLMStreamHandler` does). A workspace-relative
      # path is also the resolution case: the cache key is the
      # resolved full path, and the lookup resolves the same
      # way.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "foo.txt", "hello\n")

      AgentTestHelpers.record_read_file(pid, full_path)

      assert GenServer.call(pid, {:check_read_policy, %{path: "foo.txt"}}) == :ok
    end

    test "returns {:error, :contents_changed} after an external edit" do
      # Seed the cache with the file's current stat. Externally
      # edit the file (size changes — the policy check trips
      # on either mtime OR size). We deliberately use a size
      # delta rather than a mtime delta so the test doesn't
      # need a sleep for filesystem mtime granularity.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "foo.txt", "old\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      File.write!(full_path, "much longer new contents than the original file had\n")

      assert GenServer.call(pid, {:check_read_policy, %{path: "foo.txt"}}) ==
               {:error, :contents_changed}
    end

    test "returns :ok for an absolute path that matches the recorded cache" do
      # An absolute path is used as-is (not joined onto the
      # workspace root), so the cache key and the lookup key
      # are the same absolute string.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "abs_foo.txt", "data\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      assert GenServer.call(pid, {:check_read_policy, %{path: full_path}}) == :ok
    end

    test "returns :ok for a never-existed path (creating a new file)" do
      # The user's main case: the LLM is about to create a
      # new file. There's no prior read, no cache entry, and
      # the file doesn't exist on disk. The on-disk `File.stat/1`
      # returns `:enoent` and the policy returns `:ok` —
      # "if there's no file, allow, no further checks."
      {pid, _name} = start_agent_with_workspace()
      workspace = workspace_root(pid)

      refute File.exists?(Path.join(workspace, "fresh.txt"))

      assert GenServer.call(pid, {:check_read_policy, %{path: "fresh.txt"}}) ==
               :ok
    end

    test "returns :ok when a previously-read file has been externally deleted" do
      # The agent ran `read_file` (cache populated), then the
      # user (or another process) deletes the file. The
      # recorded cache entry is now stale (the file the
      # agent read is gone), but the user said "if there's no
      # file, allow, no further checks". The on-disk
      # `File.stat/1` returns `:enoent` and the policy returns
      # `:ok` — the agent can recreate the file from its
      # cached content. This is the ordering the cache-hit
      # case pins: the stat is consulted first, so a stale
      # entry cannot produce `:contents_changed` here.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "ephemeral.txt", "data\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      File.rm!(full_path)

      assert GenServer.call(pid, {:check_read_policy, %{path: "ephemeral.txt"}}) ==
               :ok
    end
  end

  describe "ChatState.read_files" do
    test "is fresh (empty) at agent init" do
      {pid, _name} = start_agent_with_workspace()

      assert read_files(pid) == %{}
    end
  end

  # ---- helpers ----

  defp start_agent_with_workspace do
    # Project-relative workspace outside /tmp: the sandbox scratch dir is
    # bound at /tmp, so a workspace under it would be shadowed.
    workspace_root =
      Path.join([File.cwd!(), "_build", "tmp", "file_policy_workspace_#{unique_int()}"])

    File.mkdir_p!(workspace_root)

    # Arm cleanup before the risky `start_agent` below: if it raises, the
    # workspace must still be removed.
    on_exit(fn ->
      rm_tmp!(workspace_root, "file_policy_workspace")
    end)

    vid = AgentTestHelpers.vocation_id_for_test()

    # Use a real workspace path on the agent. The MockClient
    # doesn't reach out to any LLM — we just script tool
    # results to drive the policy.
    {pid, name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        workspace_path: workspace_root,
        vocation_id: vid
      })

    {pid, name}
  end

  defp unique_int, do: System.unique_integer([:positive])

  defp workspace_root(pid) do
    Nest.Agents.Agent.get_public_info(pid, 1_000).workspace_path
  end

  defp read_files(pid) do
    GenServer.call(pid, :get_read_files)
  end

  # Materialize a workspace-relative file with the given
  # content. Returns the absolute path so the test can stat
  # it directly when it wants to assert mtime/size without
  # going through the agent.
  defp write_test_file(pid, rel_path, content) do
    full_path = Path.join(workspace_root(pid), rel_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    full_path
  end
end
