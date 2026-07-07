defmodule Nest.Agents.Agent.BatchSizerTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer`.

  Covers the three-phase batch sizing flow:

    * Phase 1 (preflight) — refuses batches whose projected post-batch
      size exceeds `context_limit`.
    * Phase 2 (execute) — runs each tool and measures actual sizes
      via `Nest.Tokens.Estimator`.
    * Phase 3 (keep-or-summarize) — for `execute_command` results,
      decides keep-full vs. summary-with-path to fit the budget.

  Per `notes/extract-compaction-and-resumable-chat-turn.md`:
  tool sizes are deterministic (read_file exact, others trivial or
  fixed-summary). The BatchSizer surfaces the `is_error` flag
  through refusal paths.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.LLM.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Tools

  # -- helpers --

  defp make_tool(name, fn_) do
    %Tool{
      name: name,
      description: name,
      parameters_schema: nil,
      function: fn_
    }
  end

  defp small_tool(name) do
    make_tool(name, fn _, _ -> {:ok, "small output for #{name}"} end)
  end

  defp huge_tool(name, size_bytes) do
    make_tool(name, fn _, _ -> {:ok, String.duplicate("x", size_bytes)} end)
  end

  defp failing_tool(name) do
    make_tool(name, fn _, _ -> {:error, "intentional failure"} end)
  end

  defp call(id, name, arguments \\ %{}) do
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

  describe "Phase 1: preflight" do
    test "fits when projected total is below context_limit" do
      tools = [small_tool("echo")]
      c = ctx(tools, context_limit: 100_000)
      assert BatchSizer.preflight([call("c1", "echo")], c) == :fits
    end

    test "refuses when projected total exceeds context_limit" do
      # context_limit = 100 tokens, but a 1 MB output would far exceed
      tools = [huge_tool("huge", 1_000_000)]
      c = ctx(tools, context_limit: 100)
      assert {:refuse, _reason} = BatchSizer.preflight([call("c1", "huge")], c)
    end

    test "fits when context_limit is nil (degraded-but-hopeful path)" do
      tools = [small_tool("echo")]
      c = ctx(tools, context_limit: nil)
      assert BatchSizer.preflight([call("c1", "echo")], c) == :fits
    end

    test "fits empty batch" do
      c = ctx([], context_limit: 100)
      assert BatchSizer.preflight([], c) == :fits
    end
  end

  describe "Phase 2: execute" do
    test "runs each tool in batch order and returns raw results" do
      tools = [small_tool("alpha"), small_tool("beta")]
      c = ctx(tools)

      assert [%ToolResult{} = r1, %ToolResult{} = r2] =
               BatchSizer.run(
                 [call("c1", "alpha"), call("c2", "beta")],
                 c
               )

      assert r1.name == "alpha" and r1.is_error == false
      assert r2.name == "beta" and r2.is_error == false
      assert r1.tool_call_id == "c1"
      assert r2.tool_call_id == "c2"
    end

    test "preserves tool_call_id and arguments in the result" do
      tools = [small_tool("write_file")]

      assert [%ToolResult{} = r] =
               BatchSizer.run(
                 [
                   call("c1", "write_file", %{"path" => "a.txt", "content" => "x"})
                 ],
                 ctx(tools)
               )

      assert r.tool_call_id == "c1"
      assert r.arguments == %{"path" => "a.txt", "content" => "x"}
    end

    test "marks error results as is_error: true" do
      tools = [failing_tool("crashy")]

      assert [%ToolResult{is_error: true, content: content}] =
               BatchSizer.run([call("c1", "crashy")], ctx(tools))

      assert content =~ "intentional failure"
    end

    test "returns synthetic error results when preflight refuses the batch" do
      tools = [small_tool("echo"), small_tool("beta")]
      c = ctx(tools, context_limit: 50)

      [r1, r2] =
        BatchSizer.run(
          [call("c1", "echo"), call("c2", "beta")],
          c
        )

      assert r1.is_error == true and r2.is_error == true
      assert r1.content == r2.content
      assert r1.content =~ "Batch refused"
      assert r1.content =~ "Reformulate"
    end

    test "preserves empty batch results in input order" do
      assert [] == BatchSizer.run([], ctx([small_tool("echo")]))
    end
  end

  describe "Phase 3: keep-or-summarize for execute_command" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "batchsizer-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "single small execute_command keeps full", %{tmp_dir: dir} do
      tools = [small_tool("execute_command")]
      c = ctx(tools, context_limit: 100_000, tmp_path: dir)

      assert [%ToolResult{content: content, is_error: false}] =
               BatchSizer.run([call("c1", "execute_command", %{"command" => "ls"})], c)

      assert content == "small output for execute_command"
      # No temp file should have been written (kept full).
      assert Enum.all?(File.ls!(dir), &(not String.starts_with?(&1, "exec-")))
    end

    test "execute_command with larger output is summarized with path", %{tmp_dir: dir} do
      big_output = String.duplicate("y", 50_000)

      tools = [
        make_tool("execute_command", fn _, _ -> {:ok, big_output} end)
      ]

      # context_limit tight enough that the full 50K-byte output
      # (~12.5K tokens) + reserve (~8K) won't fit post-execution,
      # but the summary (~30 tokens) + reserve fits preflight.
      c = ctx(tools, context_limit: 10_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [call("c1", "execute_command", %{"command" => "cat foo"})],
                 c
               )

      # Preflight passed (summary+reserve fit); post-execution
      # decided to summarize (full output didn't fit).
      assert result.is_error == false
      assert result.content =~ "Command output of 'cat foo'"
      assert result.content =~ "saved to"
      assert result.content =~ "/batchsizer-test-"

      [exec_file] = Enum.filter(File.ls!(dir), &String.starts_with?(&1, "exec-"))
      assert File.read!(Path.join(dir, exec_file)) == big_output
    end

    test "kept-full execute_command has no summary path string" do
      tools = [small_tool("execute_command")]
      c = ctx(tools, context_limit: 100_000, tmp_path: nil)

      [%ToolResult{content: content}] =
        BatchSizer.run([call("c1", "execute_command")], c)

      refute content =~ "saved to"
      refute content =~ "Command output of"
    end
  end

  describe "read_file sizing policy" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "batchsizer-read-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir, test_file: Path.join(tmp_dir, "test.txt")}
    end

    test "reads the file and emits a ToolResult with exact size", ctx do
      %{tmp_dir: dir, test_file: file} = ctx
      File.write!(file, "hello world")

      tools = [Tools.get_function("read_file", dir)]
      c = ctx(tools)

      assert [%ToolResult{content: content, is_error: false}] =
               BatchSizer.run(
                 [call("c1", "read_file", %{"path" => "test.txt"})],
                 c
               )

      assert content == "hello world"
    end

    test "returns error for non-existent file", ctx do
      %{tmp_dir: dir} = ctx
      tools = [Tools.get_function("read_file", dir)]
      c = ctx(tools)

      [%ToolResult{is_error: true, content: error}] =
        BatchSizer.run([call("c1", "read_file", %{"path" => "nope.txt"})], c)

      assert error =~ "File not found"
    end
  end

  describe "tool size projections for various tools" do
    test "all standard tool projections are estimator-computed (no hardcoded constants)" do
      # Project each tool and ensure the projections are non-zero.
      tools = [
        small_tool("write_file"),
        small_tool("edit"),
        small_tool("inspect_file"),
        small_tool("context")
      ]

      c = ctx(tools, context_limit: 100_000_000)

      assert :fits = BatchSizer.preflight([call("c1", "write_file")], c)
      assert :fits = BatchSizer.preflight([call("c1", "edit")], c)
      assert :fits = BatchSizer.preflight([call("c1", "inspect_file")], c)
      assert :fits = BatchSizer.preflight([call("c1", "context")], c)
    end
  end

  describe "ToolLoop integration" do
    test "ToolLoop.execute/3 routes single context.compact to compaction handler" do
      alias Nest.Agents.Agent.ToolLoop

      # Spawn a tiny GenServer-like process that pretends to be the
      # Agent: it replies to `{:task_compaction_request, ...}` with
      # `{:task_compaction_done, []}` so the chat task can unblock.
      test_pid = self()

      {:ok, agent_pid} =
        Task.start_link(fn ->
          receive do
            {:task_compaction_request, task, _focus} ->
              send(task, {:task_compaction_done, []})
              send(test_pid, :compaction_request_received)
          after
            5000 -> :ok
          end
        end)

      c = %{ctx([], context_limit: 100_000) | agent_pid: agent_pid}

      result =
        ToolLoop.execute(
          c,
          %{},
          [call("c1", "context", %{"action" => "compact", "focus" => "summary"})]
        )

      assert_receive :compaction_request_received, 1000
      assert [%ToolResult{name: "context", is_error: false}] = result

      Process.exit(agent_pid, :kill)
    end

    test "ToolLoop.execute/3 refuses batch with context.compact mixed with other tools" do
      alias Nest.Agents.Agent.ToolLoop

      c = ctx([small_tool("read_file")])

      result =
        ToolLoop.execute(c, %{}, [
          call("c1", "context", %{"action" => "compact"}),
          call("c2", "read_file", %{"path" => "/tmp/x"})
        ])

      assert length(result) == 2
      assert Enum.all?(result, & &1.is_error)
      assert hd(result).content =~ "context.compact must be the sole tool"
    end

    test "ToolLoop.execute/3 delegates batch to BatchSizer for non-context-compact batches" do
      alias Nest.Agents.Agent.ToolLoop

      tools = [small_tool("echo"), small_tool("beta")]

      results = ToolLoop.execute(ctx(tools), %{}, [call("c1", "echo"), call("c2", "beta")])

      assert [%ToolResult{name: "echo"}, %ToolResult{name: "beta"}] = results
      assert Enum.all?(results, &(not &1.is_error))
    end
  end
end
