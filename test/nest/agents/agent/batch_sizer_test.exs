defmodule Nest.Agents.Agent.BatchSizerTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer`'s three phases: preflight, execute, and
  keep-or-summarize. Per `notes/extract-compaction-and-resumable-chat-turn.md`,
  tool sizes are deterministic (`file-read` exact, others trivial or
  fixed-summary), and `is_error` is what carries a failed call to the model.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.SpaceGate
  alias Nest.LLM.Tool
  alias Nest.Messages.{Part, ToolCall, ToolResult}
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.TextFixtures

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

  defp call(id, name, arguments \\ %{}) do
    %ToolCall{id: id, name: name, arguments: arguments}
  end

  defp ctx(tools, opts \\ []) do
    %{
      tools: tools,
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
      context_limit: Keyword.get(opts, :context_limit, 100_000),
      messages: Keyword.get(opts, :messages, []),
      mounts:
        Mounts.new(Keyword.get(opts, :workspace_path, nil), Keyword.get(opts, :tmp_path, nil)),
      agent_pid: self(),
      agent_name: "test",
      space_id: Keyword.get(opts, :space_id, nil)
    }
  end

  describe "Phase 1: preflight" do
    test "fits empty batch" do
      c = ctx([], context_limit: 100)
      assert {:fits, _} = BatchSizer.preflight([], c)
    end
  end

  describe "projected_content_size/2" do
    alias Nest.Tokens.Reserve

    test "preflight compares projected_content_size/2 plus the reserve against the limit" do
      calls = [call("c1", "shell-cmd")]

      # Content is tiny, but the 8_192 reserve floor does not fit in a
      # 100-token window: content alone would fit, content + reserve does
      # not, and `preflight/2` is what adds the reserve.
      c = ctx([], context_limit: 100)
      content = BatchSizer.projected_content_size(calls, c)

      assert content < 100
      assert content + Reserve.compaction_reserve(100) > 100
      assert {:refuse, _} = BatchSizer.preflight(calls, c)

      assert {:fits, _} = BatchSizer.preflight(calls, ctx([], context_limit: 100_000))
    end
  end

  describe "Phase 2: execute" do
    test "a batch waits for the space's latch, then runs under it" do
      # The space is being edited: no tool starts until the environment is written.
      id = System.unique_integer([:positive])
      c = ctx([small_tool("echo")], space_id: id)

      :ok = SpaceGate.hold(id)
      batch = Task.async(fn -> BatchSizer.execute([call("c1", "echo")], c) end)
      assert Task.yield(batch, 30) == nil

      :ok = SpaceGate.release(id)

      assert [{_tc, :ok, content}] = Task.await(batch, 500)
      assert content =~ "small output"
    end

    test "preserves tool_call_id and arguments in the result" do
      tools = [small_tool("file-write")]

      assert [%ToolResult{} = r] =
               BatchSizer.run(
                 [
                   call("c1", "file-write", %{"path" => "a.txt", "content" => "x"})
                 ],
                 ctx(tools)
               )

      assert r.tool_call_id == "c1"
      assert r.arguments == %{"path" => "a.txt", "content" => "x"}
    end

    test "a cancelled call is an error result that keeps its own kind" do
      # A call the space edit cancelled (`ShellCmd.execute/4`'s `{:cancelled,
      # reason}`) is `is_error: true` for the model, and no `[error]` line for
      # the operator, because a routine edit is not a defect. Its own kind is
      # what keeps both diagnostics off — they key on `:error`. Deliberately
      # outside any capture: if either fired, the suite would print.
      cancelled = make_tool("cancelled-tool", fn _, _ -> {:cancelled, "changed"} end)

      assert [%ToolResult{is_error: true, content: "changed"}] =
               BatchSizer.run([call("c2", "cancelled-tool")], ctx([cancelled]))

      assert [{_tc, :cancelled, "changed"}] =
               BatchSizer.execute([call("c3", "cancelled-tool")], ctx([cancelled]))
    end

    test "returns synthetic error results when preflight refuses the batch" do
      tools = [small_tool("echo"), small_tool("beta")]
      c = ctx(tools, context_limit: 50)

      log =
        capture_log(fn ->
          [r1, r2] =
            BatchSizer.run(
              [call("c1", "echo"), call("c2", "beta")],
              c
            )

          assert r1.is_error == true and r2.is_error == true
          assert r1.content == r2.content
          assert r1.content =~ "Batch refused"
          assert r1.content =~ "Reformulate"
        end)

      assert log =~ "BatchSizer refused batch (preflight)"
    end

    test "preserves empty batch results in input order" do
      assert [] == BatchSizer.run([], ctx([small_tool("echo")]))
    end
  end

  describe "Phase 3: keep-or-summarize for shell_cmd" do
    setup do
      unique = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "batchsizer-test-#{unique}")
      dir = Path.join([root, "space-1", "agent-#{unique}"])

      File.mkdir_p!(dir)
      on_exit(fn -> if String.contains?(root, "batchsizer-test"), do: File.rm_rf!(root) end)
      {:ok, tmp_dir: dir}
    end

    test "shell_cmd with larger output is summarized with path", %{tmp_dir: dir} do
      big_output = TextFixtures.big_text(50_000)

      tools = [
        make_tool("shell-cmd", fn _, _ -> {:ok, big_output} end)
      ]

      # context_limit tight enough that the full 50K-byte output
      # (~12.5K tokens) + reserve (~8K) won't fit post-execution,
      # but the summary (~30 tokens) + reserve fits preflight.
      c = ctx(tools, context_limit: 10_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [call("c1", "shell-cmd", %{"command" => "cat foo"})],
                 c
               )

      # Preflight passed (summary+reserve fit); post-execution
      # decided to summarize (full output didn't fit).
      assert result.is_error == false
      assert result.content =~ "Command output of 'cat foo'"
      assert result.content =~ "saved to"
      assert result.content =~ Sandbox.sandbox_tmp_path(dir)
      refute result.content =~ dir

      [exec_file] = Enum.filter(File.ls!(dir), &String.starts_with?(&1, "exec-"))
      assert File.read!(Path.join(dir, exec_file)) == big_output
    end
  end

  describe "ToolLoop integration" do
    # Note: `context-compact` used to be handled inside ToolLoop
    # (singleton → task-worker block on compaction; mixed → refuse).
    # `Machine.Response` owns that handling now; see the
    # context-compact coverage in `agent_compaction_test.exs`.
    # `ToolLoop.execute/3` is now an
    # unconditional passthrough to `BatchSizer.run/2` for non-empty
    # batches and `[]` for empty ones. The non-empty passthrough is
    # covered where a tool result comes back through it:
    # `tool_loop_error_flag_test.exs` asserts `BatchSizer`'s own
    # `is_error` diagnostic for a batch run through `ToolLoop`.

    test "ToolLoop.execute/3 returns [] for empty batch" do
      alias Nest.Agents.Agent.ToolLoop

      assert [] = ToolLoop.execute(ctx([small_tool("echo")]), %{}, [])
    end
  end

  describe "Bug 1 regression: shell_cmd batch fits preflight with long history" do
    test "three shell_cmd calls with a ~10k-token message history fits a 20k context" do
      # This is the `entire-ox` failure shape: three shell_cmd
      # calls batched against a long message history with a small
      # context. Pre-fix (catch-all projecting ~2468 tokens of
      # ghost budget per call), the batch was refused:
      #   3 × 2468 + 8192 reserve + ~10354 messages
      #   ≈ 25,950 tokens > 20,000 limit → :refuse
      #
      # Post-fix: the live `shell_cmd` clause projects
      # `summary_baseline_size() * @safety_padding` ≈ ~36 tokens
      # per call. The batch fits comfortably.
      messages = long_history(10_354)
      c = ctx([small_tool("shell-cmd")], context_limit: 20_000, messages: messages)

      assert {:fits, _} =
               BatchSizer.preflight(
                 [
                   call("c1", "shell-cmd"),
                   call("c2", "shell-cmd"),
                   call("c3", "shell-cmd")
                 ],
                 c
               )
    end
  end

  describe "catch-all: hallucinated tools project error-size, not worst-case" do
    test "the catch-all projection is small, not worst-case (Bug 1 enabler)" do
      # The catch-all used to project ~2468 tokens of ghost budget
      # for unknown tools. With the fix, it projects the size of a
      # representative error string (~30 tokens). This test pins
      # that the new projection is dramatically smaller than the
      # old one — the difference lets hallucinated tool batches
      # fit preflight in long-running sessions where they would
      # previously have been refused.
      #
      # We can't call `projected_size/2` directly (private). The
      # observable proxy: preflight fits a 100k-context batch
      # with 100 hallucinated tool calls.
      # - Pre-fix:  100 × 2468 + 20000 reserve > 100k → :refuse
      # - Post-fix: 100 × ~30 + 20000 reserve < 100k → :fits
      tools = []
      c = ctx(tools, context_limit: 100_000, messages: [])

      hallucinated_batch = Enum.map(1..100, &call("c#{&1}", "hallucinated_#{&1}"))

      assert {:fits, _} = BatchSizer.preflight(hallucinated_batch, c)
    end
  end

  describe "binary shell-cmd output never goes inline raw" do
    defp binary_tool(content) do
      make_tool("shell-cmd", fn _, _ -> {:ok, content} end)
    end

    defp tmp_dir_for_test do
      unique = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "nest-tmp-batchsizer-#{unique}")
      dir = Path.join([root, "space-1", "agent-#{unique}"])

      File.mkdir_p!(dir)

      on_exit(fn ->
        if String.contains?(root, "nest-tmp-batchsizer"), do: File.rm_rf(root)
      end)

      dir
    end

    # Pull the scratch-file path out of a `saved to <path>.` pointer.
    defp saved_path(content) do
      [_, path] = Regex.run(~r/saved to (\/[^\s]+\.txt)/, content)
      path
    end

    # The pointer is the sandbox spelling (`/tmp/<agent>/...`); the bytes live
    # at the same basename under the host scratch dir.
    defp read_saved(dir, content) do
      File.read!(Path.join(dir, Path.basename(saved_path(content))))
    end

    test "a large binary returns a pointer only, with the raw bytes saved", %{} do
      raw = :binary.copy(<<0xFF>>, 300)
      dir = tmp_dir_for_test()
      tools = [binary_tool(raw)]
      c = ctx(tools, tmp_path: dir)

      assert [%ToolResult{name: "shell-cmd", is_error: false, content: content}] =
               BatchSizer.run([call("c1", "shell-cmd")], c)

      assert String.valid?(content)
      assert content =~ "(non-text binary output, 300 bytes)"
      assert content =~ "saved to "
      # No lossy view for large binaries — pointer only.
      refute content =~ <<0xEF, 0xBF, 0xBD>>
      refute content =~ <<0xFF>>

      assert read_saved(dir, content) == raw
    end

    test "valid UTF-8 containing NUL is treated as non-text output", %{} do
      # NUL is valid UTF-8, so `String.valid?/1` alone would keep this
      # inline; Postgres jsonb cannot store it. It must take the binary
      # path and never reach the message/persistence layer raw.
      raw = "hl-smi:\n" <> <<"GPU ", 0, 0, "0">> <> "\n"
      dir = tmp_dir_for_test()
      tools = [binary_tool(raw)]
      c = ctx(tools, tmp_path: dir)

      assert [%ToolResult{name: "shell-cmd", is_error: false, content: content}] =
               BatchSizer.run([call("c1", "shell-cmd")], c)

      assert String.valid?(content)
      refute String.contains?(content, <<0>>)
      assert content =~ "(non-text binary output, #{byte_size(raw)} bytes)"
      assert content =~ "saved to "
      # The inline lossy view replaces the NULs with U+FFFD.
      assert content =~ <<0xEF, 0xBF, 0xBD>>

      # The scratch file preserves the ORIGINAL raw bytes (including NUL).
      assert read_saved(dir, content) == raw
    end

    test "an exhausted batch budget keeps the pointer and drops the inline view", %{} do
      # A small binary normally inlines `pointer <> "\n\n" <> body`. When
      # the running batch budget is already spent, the result is trimmed to
      # the caller-supplied marker instead: the `pointer` (which names the
      # scratch file and byte count) plus a note that the inline lossy view
      # was dropped. `execute/2` runs the tool; `cook/2` applies the budget
      # pass against an exhausted limit (preflight would refuse a limit this
      # small, so `run/2` cannot reach this branch).
      raw = <<"OK", 0x1F, 0x8B, 0x08, 0x00, 0xFF>>
      dir = tmp_dir_for_test()
      tools = [binary_tool(raw)]
      calls = [call("c1", "shell-cmd", %{"command" => "cat data.bin"})]

      entries = BatchSizer.execute(calls, ctx(tools, tmp_path: dir))

      assert [%ToolResult{name: "shell-cmd", is_error: false, content: content}] =
               BatchSizer.cook(entries, ctx(tools, context_limit: 100, tmp_path: dir))

      assert String.valid?(content)
      assert content =~ "(non-text binary output, 7 bytes)"
      assert content =~ "saved to "
      assert content =~ Sandbox.sandbox_tmp_path(dir)
      refute content =~ dir
      assert content =~ "inline view elided"
      # The inline lossy view is exactly what got dropped.
      refute content =~ Overflow.to_valid_utf8(raw)

      # The scratch file still holds the original raw bytes.
      assert read_saved(dir, content) == raw
    end
  end

  describe "tool context carries agent identity" do
    test "forwards space_id/agent_name/agent_pid, the caller's model, and the call id" do
      parent = self()

      tool =
        make_tool("identity-probe", fn _args, context ->
          {:ok,
           inspect(%{
             key: Nest.Tools.agent_key(context),
             pid: context[:agent_pid] == parent,
             model: context[:client_config] && context[:client_config].model,
             call_id: context[:tool_call_id]
           })}
        end)

      c = %{
        tools: [tool],
        caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
        context_limit: 100_000,
        messages: [],
        tmp_path: nil,
        agent_pid: parent,
        agent_name: "clever-raven",
        space_id: 42,
        client_config: %Nest.LLM.ClientConfig{model: "vision-model"}
      }

      assert [%ToolResult{content: content}] =
               BatchSizer.run([call("c1", "identity-probe")], c)

      # `client_config` is what `file-read`'s media gate reads to decide whether
      # the model can accept an attachment, and the call id is what ties an
      # attached media part to the result it answers.
      assert content ==
               inspect(%{
                 key: {42, "clever-raven"},
                 pid: true,
                 model: "vision-model",
                 call_id: "c1"
               })
    end
  end

  # -- helpers --

  # Build a list of ~`target_tokens` tokens' worth of messages
  # by repeating a filler string inside a single system message.
  # Estimator sees ~4 chars/token, so 10k tokens ≈ 40_000 chars.
  # Used by the Bug 1 regression test to set up a long-history
  # scenario without enumerating thousands of distinct messages.
  defp long_history(target_tokens) do
    char_count = target_tokens * 4 + 100
    filler = String.duplicate("prior conversation history. ", div(char_count, 28))
    body = String.slice(filler, 0, char_count)

    [
      {:system,
       %Nest.Messages.System{
         index: 0,
         parts: [%Part.Text{text: body}]
       }}
    ]
  end
end
