defmodule Nest.Agents.Agent.BatchSizerPreflightStatTest do
  @moduledoc """
  The preflight's `file-read` stat batching (issue #48).

  `ProjectedSize.project_batch/2` hands the sandbox every distinct resolved
  `file-read` path in one go, so the preflight spends bwrap spawns per *batch*
  (and per distinct path), not per tool call. Every assertion here counts
  spawns with Mimic rather than timing anything.
  """

  use ExUnit.Case, async: true

  import Mimic

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Agents.Agent.BatchSizer.ProjectedSizeOracle
  alias Nest.Messages.ToolCall
  alias Nest.Sandbox

  setup :verify_on_exit!

  # -- helpers --

  defp call(id, name, arguments) do
    %ToolCall{id: id, name: name, arguments: arguments}
  end

  defp ctx(tools, opts \\ []) do
    %{
      tools: tools,
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
      context_limit: Keyword.get(opts, :context_limit, 100_000),
      messages: Keyword.get(opts, :messages, []),
      tmp_path: Keyword.get(opts, :tmp_path, nil),
      agent_pid: self(),
      agent_name: "test"
    }
  end

  # `ctx/2` carries no `workspace_path`, so a *relative* `file-read` path cannot
  # resolve (and therefore never stats). Absolute paths resolve without one.
  defp ctx_with_ws(ws, tools) do
    ctx(tools) |> Map.put(:workspace_path, ws)
  end

  # Stub the sandbox's two stat entry points so a test can assert *which*
  # distinct paths the preflight batched and how many spawns it took:
  # `stat_many/4` (one bwrap spawn for a whole chunk of paths) and `stat/4`
  # (one per path — the per-path fallback). Both modules are copied in
  # `test/test_helper.exs`, never per-test.
  defp stub_stats(size) do
    Mimic.stub(Sandbox, :stat_many, fn paths, _caps, _ws, _tmp ->
      Map.new(paths, &{&1, {:ok, size}})
    end)

    Mimic.stub(Sandbox, :stat, fn _path, _caps, _ws, _tmp ->
      {:ok, %File.Stat{size: size}}
    end)
  end

  # A real workspace under `_build/tmp` (not `/tmp`: the sandbox scratch dir is
  # bound at /tmp, so a /tmp-rooted workspace is rejected).
  defp tmp_ws!(label) do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "#{label}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "preflight stat batching (issue #48)" do
    alias Nest.Tokens.{Budget, Estimator, Reserve}

    # Every assertion here is the number of bwrap spawns (Mimic), never a
    # timing. `estimate_bytes(100) == 40`.
    @per_call Estimator.estimate_bytes(100)

    test "batches every call that targets the same path into one stat" do
      stub_stats(100)

      Mimic.expect(Sandbox, :stat_many, 1, fn paths, _c, _w, _t ->
        assert paths == ["/ws/a.txt"]
        Map.new(paths, &{&1, {:ok, 100}})
      end)

      Mimic.reject(Sandbox, :stat, 4)

      calls = [
        call("c1", "file-read", %{"path" => "a.txt"}),
        call("c2", "file-read", %{"path" => "a.txt"}),
        call("c3", "file-read", %{"path" => "a.txt"})
      ]

      # One spawn for the batch, three projections: the dedupe is the stat,
      # not the size.
      assert BatchSizer.projected_content_size(calls, ctx_with_ws("/ws", [])) ==
               Budget.size([]) + ceil(3 * @per_call)
    end

    test "passes each distinct path once, in a single stat invocation" do
      stub_stats(100)

      Mimic.expect(Sandbox, :stat_many, 1, fn paths, _c, _w, _t ->
        assert Enum.sort(paths) == ["/ws/a.txt", "/ws/b.txt"]
        Map.new(paths, &{&1, {:ok, 100}})
      end)

      Mimic.reject(Sandbox, :stat, 4)

      calls = [
        call("c1", "file-read", %{"path" => "a.txt"}),
        call("c2", "file-read", %{"path" => "b.txt"}),
        call("c3", "file-read", %{"path" => "a.txt"})
      ]

      assert BatchSizer.projected_content_size(calls, ctx_with_ws("/ws", [])) ==
               Budget.size([]) + ceil(3 * @per_call)
    end

    test "batches only the file-read calls" do
      stub_stats(100)

      Mimic.expect(Sandbox, :stat_many, 1, fn paths, _c, _w, _t ->
        assert paths == ["/ws/a.txt"]
        Map.new(paths, &{&1, {:ok, 100}})
      end)

      Mimic.reject(Sandbox, :stat, 4)

      calls = [
        call("c1", "file-read", %{"path" => "a.txt"}),
        call("c2", "shell-cmd", %{"command" => "ls"}),
        call("c3", "file-write", %{"path" => "b.txt", "content" => "x"}),
        call("c4", "agents-list", %{})
      ]

      assert BatchSizer.projected_content_size(calls, ctx_with_ws("/ws", [])) >
               Budget.size([]) + ceil(@per_call)
    end

    test "hands the sandbox no path for a malformed or unresolvable file-read" do
      # An empty list is all the preflight may ask for, and the per-path
      # fallback (`stat/4`) must never run.
      Mimic.expect(Sandbox, :stat_many, 1, fn [], _c, _w, _t -> %{} end)
      Mimic.reject(Sandbox, :stat, 4)

      calls = [
        call("c1", "file-read", %{}),
        call("c2", "file-read", %{"path" => 42}),
        call("c3", "file-read", %{"path" => ""}),
        # A relative path with no workspace: `Sandbox.resolve/2` errors, so the
        # projection must fall back without statting.
        call("c4", "file-read", %{"path" => "a.txt"})
      ]

      c = ctx([])
      fallback = ProjectedSize.summary_baseline_size() * 1.2

      assert Enum.map(calls, &ProjectedSize.project(&1, c)) == List.duplicate(fallback, 4)

      assert BatchSizer.projected_content_size(calls, c) ==
               Budget.size([]) + ceil(4 * fallback)
    end

    test "different spellings of one file are batched separately (documented limit)" do
      stub_stats(100)

      Mimic.expect(Sandbox, :stat_many, 1, fn paths, _c, _w, _t ->
        assert Enum.sort(paths) == ["/ws/./a.txt", "/ws/a.txt"]
        Map.new(paths, &{&1, {:ok, 100}})
      end)

      Mimic.reject(Sandbox, :stat, 4)

      calls = [
        call("c1", "file-read", %{"path" => "a.txt"}),
        call("c2", "file-read", %{"path" => "./a.txt"})
      ]

      # `Sandbox.resolve/2` is lexical (`Path.join/2`), so `a.txt` and `./a.txt`
      # resolve to different strings and both ride the batch. Normalizing `.`
      # and `..` lexically would be wrong when a component is a symlink, so the
      # memo keys on the resolved string verbatim: at most one extra operand,
      # never a wrong size.
      assert BatchSizer.projected_content_size(calls, ctx_with_ws("/ws", [])) ==
               Budget.size([]) + ceil(2 * @per_call)
    end

    test "a direct project/2 call still stats, with no memo in ctx" do
      stub_stats(100)

      Mimic.expect(Sandbox, :stat, 1, fn path, _c, _w, _t ->
        assert path == "/ws/a.txt"
        {:ok, %File.Stat{size: 100}}
      end)

      c = ctx_with_ws("/ws", [])

      assert ProjectedSize.project(call("c1", "file-read", %{"path" => "a.txt"}), c) == @per_call
    end

    test "a memo that misses the path still stats, and a failed stat falls back" do
      Mimic.expect(Sandbox, :stat, 1, fn _path, _c, _w, _t -> {:error, :enoent} end)

      # A memo that does not mention this path: the projection must stat rather
      # than invent a size, and a failed stat is the summary fallback.
      c = Map.put(ctx_with_ws("/ws", []), :file_read_sizes, %{})

      assert ProjectedSize.project(call("c1", "file-read", %{"path" => "a.txt"}), c) ==
               ProjectedSize.summary_baseline_size() * 1.2
    end

    test "matches main's projection module, path for path (independent oracle)" do
      ws = tmp_ws!("batchsizer-statbatch-oracle")
      File.write!(Path.join(ws, "a.txt"), String.duplicate("x", 4_000))
      File.write!(Path.join(ws, "b.txt"), String.duplicate("y", 1_000))

      calls = [
        call("c1", "file-read", %{"path" => "a.txt"}),
        call("c2", "file-read", %{"path" => "a.txt"}),
        call("c3", "file-read", %{"path" => "b.txt"}),
        call("c4", "file-read", %{"path" => "missing.txt"}),
        call("c5", "file-read", %{"path" => ""}),
        call("c6", "shell-cmd", %{"command" => "ls"}),
        call("c7", "file-write", %{"path" => "a.txt", "content" => "x"})
      ]

      c = ctx_with_ws(ws, [])

      # `ProjectedSizeOracle` is `main`'s `ProjectedSize`: live stats, one per
      # call, no memo, no batching. It shares no code with the code under test,
      # so this compares against the actual pre-change behaviour rather than
      # against the new module's own `project/2`.
      oracle = Enum.map(calls, &ProjectedSizeOracle.project(&1, c))

      assert Enum.map(calls, &ProjectedSize.project(&1, c)) == oracle

      content = Budget.size([]) + ceil(Enum.sum(oracle))
      assert BatchSizer.projected_content_size(calls, c) == content

      # Refusal decisions agree at a limit derived from the oracle's own total:
      # `content` refuses (the reserve is always positive) and a huge limit fits.
      assert {:refuse, _} = BatchSizer.preflight(calls, %{c | context_limit: content})
      assert :fits = BatchSizer.preflight(calls, %{c | context_limit: 10_000_000})
    end

    test "matches main's projection for every tool clause" do
      c = ctx_with_ws("/ws", [])

      names =
        ~w(file-read shell-cmd file-write file-edit file-inspect context-check
           shell-wait shell-list shell-kill agents-spawn agents-query agents-batch
           agents-list models-list agents-archive agents-send agents-wait)

      for name <- names do
        tc = call("c-#{name}", name, %{"path" => "a.txt", "command" => "ls"})

        assert ProjectedSize.project(tc, c) == ProjectedSizeOracle.project(tc, c),
               "projection differs for #{name}"
      end

      # The catch-all for a hallucinated name, plus the public helpers the real
      # module also exposes.
      unknown = call("c-unknown", "no-such-tool", %{})

      assert ProjectedSize.project(unknown, c) == ProjectedSizeOracle.project(unknown, c)
      assert ProjectedSize.projected?("file-read") == ProjectedSizeOracle.projected?("file-read")
      assert ProjectedSize.projected?("nope") == ProjectedSizeOracle.projected?("nope")

      assert ProjectedSize.read_file_projection(:not_a_tool_call, c) ==
               ProjectedSizeOracle.read_file_projection(:not_a_tool_call, c)
    end

    test "projection is byte-identical to the naive per-call sum" do
      ws = tmp_ws!("batchsizer-statbatch-parity")
      File.write!(Path.join(ws, "a.txt"), String.duplicate("x", 4_000))

      calls = [
        call("c1", "file-read", %{"path" => "a.txt"}),
        call("c2", "file-read", %{"path" => "a.txt"}),
        call("c3", "file-read", %{"path" => "b.txt"}),
        call("c4", "shell-cmd", %{"command" => "ls"})
      ]

      c = ctx_with_ws(ws, [])

      # The pre-change projection: sum `ProjectedSize.project/2` per call. A
      # real bwrap stat for `a.txt` (the memo) and a fallback for `b.txt`.
      naive = Budget.size([]) + ceil(Enum.sum(Enum.map(calls, &ProjectedSize.project(&1, c))))

      assert BatchSizer.projected_content_size(calls, c) == naive
    end

    test "duplicate calls each still contribute to the refusal decision" do
      ws = tmp_ws!("batchsizer-statbatch-refuse")
      # 400_000 bytes -> `estimate_bytes/1` == 120_010 tokens per call.
      File.write!(Path.join(ws, "big.txt"), String.duplicate("x", 400_000))

      one = [call("c1", "file-read", %{"path" => "big.txt"})]

      three = [
        call("c1", "file-read", %{"path" => "big.txt"}),
        call("c2", "file-read", %{"path" => "big.txt"}),
        call("c3", "file-read", %{"path" => "big.txt"})
      ]

      c = ctx_with_ws(ws, [])

      one_content = BatchSizer.projected_content_size(one, c)
      three_content = BatchSizer.projected_content_size(three, c)

      # Three reads of one file project three results even though they share a
      # single stat; a dedupe that collapsed the projection would let an
      # oversized batch through.
      assert three_content == 3 * one_content

      # `reserve(200_000) == 40_000`, so one read fits and three do not.
      limit = 200_000
      reserve = Reserve.compaction_reserve(limit)

      assert one_content + reserve <= limit
      assert three_content + reserve > limit
      assert :fits = BatchSizer.preflight(one, %{c | context_limit: limit})
      assert {:refuse, _} = BatchSizer.preflight(three, %{c | context_limit: limit})
    end
  end
end
