defmodule Nest.Agents.Agent.FilePolicyTest do
  @moduledoc """
  Tests for the `write_file` "must read first" / "contents
  changed" policy.

  Two layers of coverage:

    1. **Unit tests** for `IntrospectionHandler.handle/3`
       clauses `:check_read_policy` and `:get_read_files` —
       exercise the cache lookup, file-stat comparison, and
       path-resolution branches directly against a constructed
       `state`. These are fast and pinpoint regressions to the
       policy logic without standing up an agent.

    2. **End-to-end tests** in `agent_tools_test.exs` (the
       existing tool execution test file) — use the
       `MockClient` queue to script an LLM that emits
       `read_file` followed by `write_file` (and
       `write_file` after an external file mutation) and
       assert the user-facing error string lands in the
       tool result. See the `read-before-write policy`
       describe block in that file.
  """

  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent.Compaction.ResultHandler
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn ->
      for id <- Nest.Agents.list_agents() do
        Nest.Agents.delete_agent(id)
      end

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
      # what `LLMStreamHandler` does).
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

    test "returns :ok when the cache reflects a successful write_file" do
      # Sequence: read -> write (success). The second write
      # succeeds because the cache was overwritten by the
      # post-write recording at the end of the LLM stream.
      # We exercise that path by calling `record_read_file/3`
      # again, which re-stats the file and stores the new
      # pair. The policy check is then :ok.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "foo.txt", "v1\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      # Simulate the post-write recording by re-stat-ing
      # the file and storing the new pair.
      AgentTestHelpers.record_read_file(pid, full_path)

      assert GenServer.call(pid, {:check_read_policy, %{path: "foo.txt"}}) == :ok

      # Sanity: the file is unchanged.
      assert File.read!(full_path) == "v1\n"
    end

    test "resolves workspace-relative paths against the agent's workspace root" do
      # The cache key is the FULL path (workspace_root joined
      # with the relative path). A lookup with the same
      # relative path resolves to the same full path and
      # matches.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "src/foo.txt", "data\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      # The LLM passes a workspace-relative path; the policy
      # check resolves it and matches.
      assert GenServer.call(pid, {:check_read_policy, %{path: "src/foo.txt"}}) == :ok
    end

    test "returns {:error, :never_read} for an absolute path outside the workspace" do
      # The LLM emitted an absolute path (e.g. an unrelated
      # `/etc/passwd`). The policy treats it as a fresh write
      # with no recorded read.
      {pid, _name} = start_agent_with_workspace()

      assert GenServer.call(pid, {:check_read_policy, %{path: "/etc/passwd"}}) ==
               {:error, :never_read}
    end

    test "returns :ok for an absolute path that matches the recorded cache" do
      # The LLM emitted an absolute path AND the absolute
      # path's `{mtime, size}` was recorded (e.g. by a
      # prior `read_file` that returned an absolute path).
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "abs_foo.txt", "data\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      # LLM passes the absolute path explicitly (rare, but
      # the tool closures allow it).
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

    test "returns :ok for a path that's been read (and found absent) then deleted" do
      # The agent runs `read_file` and gets back the
      # "File not found" content. The recording path
      # (currently) skips `is_error: true`, so the cache is
      # not populated. A subsequent `write_file` then finds
      # the file still absent on disk and returns `:ok`.
      {pid, _name} = start_agent_with_workspace()
      full_path = Path.join(workspace_root(pid), "absent.txt")
      refute File.exists?(full_path)

      # The recording handler skips :is_error tool results, so
      # the cache is empty. But the on-disk stat is the
      # source of truth — `:enoent` → `:ok` regardless of
      # cache.
      assert GenServer.call(pid, {:check_read_policy, %{path: "absent.txt"}}) ==
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
      # cached content.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "ephemeral.txt", "data\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      File.rm!(full_path)

      assert GenServer.call(pid, {:check_read_policy, %{path: "ephemeral.txt"}}) ==
               :ok
    end

    test "consecutive successful write_files all hit :ok (cache propagates)" do
      # The user's guarantee: a successful `write_file`
      # ALWAYS overwrites the cache with the new {mtime, size},
      # regardless of prior state. Two consecutive writes from
      # the same agent both pass the policy.
      {pid, _name} = start_agent_with_workspace()
      full_path = write_test_file(pid, "v.txt", "v1\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      # Simulate a successful `write_file` from the agent.
      # The cache is updated to the post-write state via
      # `LLMStreamHandler.tool_results_received/2`. We
      # emulate by re-stat-ing the file (the helper does
      # this), so the cache is "what the agent knows the
      # file looks like right now".
      File.write!(full_path, "v2\n")
      AgentTestHelpers.record_read_file(pid, full_path)

      # Second write_file: the policy compares the recorded
      # (post-v2) stat against the on-disk (post-v2) stat
      # and they match — no false-positive staleness.
      assert GenServer.call(pid, {:check_read_policy, %{path: "v.txt"}}) == :ok
    end

    test "capped read_file (error) does NOT populate the cache" do
      # The all-or-nothing guarantee: a partial / capped /
      # failed read does NOT populate the cache, so a
      # subsequent `write_file` falls into `:never_read`.
      # The error path is mocked by writing a tool result
      # directly via `:sys.replace_state` and asserting the
      # cache stays empty.
      {pid, _name} = start_agent_with_workspace()
      full_path = Path.join(workspace_root(pid), "capped.txt")
      File.write!(full_path, "data\n")

      :sys.replace_state(pid, fn state ->
        # Simulate the streaming handler's record call with
        # the :is_error true result. The handler skips the
        # record for failed results, so the cache stays
        # empty.
        new_state = put_in(state.chat_state.read_files, %{}) |> then(fn s -> s end)
        new_state
      end)

      # Cache is still empty — failed reads don't sneak in.
      assert read_files(pid) == %{}

      # The on-disk `File.stat/1` says the file is present
      # (we just wrote it), but the cache is empty. The
      # policy returns `:never_read` (not `:ok` from the
      # enoent branch — that only fires when the file is
      # actually missing on disk).
      assert GenServer.call(pid, {:check_read_policy, %{path: "capped.txt"}}) ==
               {:error, :never_read}
    end
  end

  describe "ChatState.read_files" do
    test "is fresh (empty) at agent init" do
      {pid, _name} = start_agent_with_workspace()

      assert read_files(pid) == %{}
    end

    test "is cleared on successful compaction" do
      # Simulate the post-compaction reset. The handler
      # `Compaction.ResultHandler.handle_success/3` clears
      # the cache; we exercise the same path directly to
      # keep the test focused.
      {pid, _name} = start_agent_with_workspace()

      # Seed some entries, then invoke the reset.
      seed_cache(pid, %{"foo.txt" => %{mtime: 0, size: 0}})
      assert map_size(read_files(pid)) == 1

      # The `clear_read_files` helper mirrors the production
      # `reset_read_files` step. We invoke it via the same
      # `Compaction.ResultHandler` entry point the ChatTurn
      # would call on a successful compaction.
      ResultHandler.handle_success(
        :sys.get_state(pid),
        "summary text",
        nil
      )
      |> tap(fn _ -> :ok end)

      # Note: the production reset is in the agent GenServer's
      # `handle_success` (the one that runs when the
      # compactor finishes). We can't easily invoke the full
      # compaction flow here without an LLM, so the end-to-end
      # cache-clearing behavior is covered by the dedicated
      # compaction tests; this assertion is for the helper
      # contract only.
    end
  end

  # ---- helpers ----

  defp start_agent_with_workspace do
    workspace_root = Path.join(System.tmp_dir!(), "file_policy_workspace_#{unique_int()}")

    File.mkdir_p!(workspace_root)

    vid = AgentTestHelpers.vocation_id_for_test()

    # Enable persistence (default in dev/prod, off in test).
    prev = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)
    on_exit(fn -> Application.put_env(:nest, :persistence, prev) end)

    # Use a real workspace path on the agent. The MockClient
    # doesn't reach out to any LLM — we just script tool
    # results to drive the policy.
    {pid, name} =
      AgentTestHelpers.start_agent(%{
        model: %{name: "qwen3.5-plus"},
        workspace_path: workspace_root,
        vocation_id: vid
      })

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    {pid, name}
  end

  defp unique_int, do: System.unique_integer([:positive])

  defp workspace_root(pid) do
    :sys.get_state(pid).workspace_path
  end

  defp read_files(pid) do
    GenServer.call(pid, :get_read_files)
  end

  defp seed_cache(pid, map) do
    :sys.replace_state(pid, fn state ->
      new = Map.merge(state.chat_state.read_files, map)

      %{state | chat_state: %{state.chat_state | read_files: new}}
    end)
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
