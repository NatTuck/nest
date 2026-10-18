defmodule Nest.Agents.Agent.BatchSizerCapTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer`'s `max_result_tokens` cap.

  Split out from `batch_sizer_test.exs` to keep that file under the
  500-line Credo cap. The cap is a gate (does the result fit inline,
  or do we route it through a different path?), never a shrinker
  (we never truncate a result to fit).

  Per `notes/no-truncation-or-overflow.md`:
    * `usable = context_limit - estimate_messages(messages) - reserve`
    * `default_cap = floor(usable * 0.80)`
    * `effective_cap = min(LLM_override, default_cap)` (LLM may only lower)
    * When exceeded: `shell_cmd` → path-and-head summary,
      `read_file` → structured error, others → log + keep full.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.LLM.Tool
  alias Nest.Messages.Assistant
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Sandbox.Mounts
  alias Nest.TextFixtures
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve
  alias Nest.Tools

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

  defp call(id, name, arguments) do
    %ToolCall{id: id, name: name, arguments: arguments}
  end

  defp ctx(tools, opts) do
    %{
      tools: tools,
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
      context_limit: Keyword.get(opts, :context_limit, 100_000),
      messages: Keyword.get(opts, :messages, []),
      mounts:
        Mounts.new(Keyword.get(opts, :workspace_path, nil), Keyword.get(opts, :tmp_path, nil)),
      agent_pid: self(),
      agent_name: "test"
    }
  end

  describe "max_result_tokens cap" do
    setup do
      tmp_dir =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "batchsizer-cap-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> rm_tmp!(tmp_dir, "batchsizer-cap-") end)
      {:ok, tmp_dir: tmp_dir}
    end

    # Defaults summary for these tests:
    #
    # * usable = 10_000 (context_limit - messages - reserve)
    # * default_cap = floor(usable * 0.80) = 8_000
    # * With override `max_result_tokens: 100`, cap = min(100, 8000) = 100.
    # * With override `max_result_tokens: 100_000`, cap = min(100_000, 8000) = 8000.

    test "shell_cmd output exceeding 80% cap routes to summary path", %{tmp_dir: dir} do
      # 40_000 chars ≈ 10_000 tokens → exceeds default_cap of 8_000.
      big_output = TextFixtures.big_text(40_000)

      tools = [
        make_tool("shell-cmd", fn _, _ -> {:ok, big_output} end)
      ]

      c = ctx(tools, context_limit: 20_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [call("c1", "shell-cmd", %{"command" => "cat foo"})],
                 c
               )

      assert result.is_error == false
      assert result.content =~ "Command output of 'cat foo'"
      assert result.content =~ "saved to"

      [exec_file] = Enum.filter(File.ls!(dir), &String.starts_with?(&1, "exec-"))
      assert File.read!(Path.join(dir, exec_file)) == big_output
    end

    test "LLM override below 80% forces summary even when output fits inline",
         %{tmp_dir: dir} do
      # Output of ~1_000 chars ≈ 250 tokens → fits default_cap easily,
      # but the override forces a tight cap that the output exceeds.
      output = TextFixtures.big_text(1_000)

      tools = [
        make_tool("shell-cmd", fn _, _ -> {:ok, output} end)
      ]

      c = ctx(tools, context_limit: 100_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [
                   call("c1", "shell-cmd", %{
                     "command" => "ls",
                     "max_result_tokens" => 100
                   })
                 ],
                 c
               )

      assert result.is_error == false
      assert result.content =~ "Command output of 'ls'"
      assert result.content =~ "saved to"

      [exec_file] = Enum.filter(File.ls!(dir), &String.starts_with?(&1, "exec-"))
      assert File.read!(Path.join(dir, exec_file)) == output
    end

    test "LLM override above 80% is clamped to 80%", %{tmp_dir: dir} do
      # 40_000 chars ≈ 10_000 tokens → exceeds default_cap of 8_000
      # even though the LLM asked for 100_000 (clamped to 8_000).
      big_output = TextFixtures.big_text(40_000)

      tools = [
        make_tool("shell-cmd", fn _, _ -> {:ok, big_output} end)
      ]

      c = ctx(tools, context_limit: 20_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [
                   call("c1", "shell-cmd", %{
                     "command" => "cat big",
                     "max_result_tokens" => 100_000
                   })
                 ],
                 c
               )

      assert result.is_error == false
      assert result.content =~ "Command output of 'cat big'"
      assert result.content =~ "saved to"
    end

    test "output below cap stays inline (no summary)", %{tmp_dir: dir} do
      tools = [small_tool("shell-cmd")]
      c = ctx(tools, context_limit: 100_000, tmp_path: dir)

      assert [%ToolResult{content: content, is_error: false}] =
               BatchSizer.run(
                 [call("c1", "shell-cmd", %{"command" => "ls"})],
                 c
               )

      assert content == "small output for shell-cmd"
      refute content =~ "saved to"
      assert Enum.all?(File.ls!(dir), &(not String.starts_with?(&1, "exec-")))
    end

    test "read_file exceeding cap returns error with token-count hint", %{tmp_dir: dir} do
      # ~5_000 bytes ≈ 1_250 tokens → exceeds the 100-token override.
      big_content = TextFixtures.big_text(5_000)
      file = Path.join(dir, "big.txt")
      File.write!(file, big_content)

      tools = [Tools.get_function("file-read", Mounts.new(dir, nil))]
      c = ctx(tools, context_limit: 100_000)

      log =
        capture_log(fn ->
          assert [%ToolResult{is_error: true, content: error}] =
                   BatchSizer.run(
                     [
                       call("c1", "file-read", %{
                         "path" => "big.txt",
                         "max_result_tokens" => 100
                       })
                     ],
                     c
                   )

          assert error =~ "File is"
          assert error =~ "tokens which exceeds your requested limit of 100"
        end)

      # The `is_error=true` cap-overflow path is a deliberate
      # diagnostic — assert on it so the test's intent is
      # self-documenting and the log doesn't escape to the test
      # output.
      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "tool=file-read"
    end

    test "raises when context_limit is nil (limit is never optional)" do
      big_output = TextFixtures.big_text(40_000)

      tools = [
        make_tool("shell-cmd", fn _, _ -> {:ok, big_output} end)
      ]

      c = ctx(tools, context_limit: nil)

      assert_raise FunctionClauseError, fn ->
        BatchSizer.run([call("c1", "shell-cmd", %{"command" => "ls"})], c)
      end
    end
  end

  describe "over-budget substitute for every tool (never keep full)" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "batchsizer-sub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> rm_tmp!(tmp_dir, "batchsizer-sub-") end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "non-shell tools over the cap are substituted, not kept full", %{tmp_dir: dir} do
      big_output = TextFixtures.big_text(40_000)

      for name <- ["shell-wait", "shell-list", "file-inspect", "some-tool"] do
        tools = [make_tool(name, fn _, _ -> {:ok, big_output} end)]
        c = ctx(tools, context_limit: 20_000, tmp_path: dir)

        assert [%ToolResult{is_error: false, content: content}] =
                 BatchSizer.run([call("c1", name, %{"id" => "job-1"})], c)

        assert content =~ "saved to", "#{name} was not substituted"
        assert Estimator.estimate(content) < 20_000, "#{name} result exceeded the budget"
      end
    end

    test "shell-wait substitute names the job", %{tmp_dir: dir} do
      big_output = TextFixtures.big_text(40_000)
      tools = [make_tool("shell-wait", fn _, _ -> {:ok, big_output} end)]
      c = ctx(tools, context_limit: 20_000, tmp_path: dir)

      assert [%ToolResult{content: content}] =
               BatchSizer.run([call("c1", "shell-wait", %{"id" => "job-7"})], c)

      assert content =~ "Output of shell-wait job-7"
      assert content =~ "saved to"
    end

    test "a small bounded tool stays inline", %{tmp_dir: dir} do
      tools = [make_tool("shell-kill", fn _, _ -> {:ok, "Killed background job job-1."} end)]
      c = ctx(tools, context_limit: 100_000, tmp_path: dir)

      assert [%ToolResult{content: "Killed background job job-1.", is_error: false}] =
               BatchSizer.run([call("c1", "shell-kill", %{"id" => "job-1"})], c)
    end

    test "cook bounds a mixed regular + sub-agent batch as a whole", %{tmp_dir: dir} do
      big = TextFixtures.big_text(30_000)

      entries = [
        {call("c1", "shell-cmd", %{"command" => "cat big"}), :ok, big},
        {call("c2", "agents-query", %{"name" => "peer"}), :ok, big}
      ]

      c = ctx([], context_limit: 20_000, tmp_path: dir)
      results = BatchSizer.cook(entries, c)

      total =
        Enum.reduce(results, 0, fn r, acc -> acc + Estimator.estimate(r.content) + 10 end)

      assert total < 20_000
      assert Enum.any?(results, &(&1.content =~ "saved to"))
      assert Enum.map(results, & &1.name) == ["shell-cmd", "agents-query"]
    end
  end

  describe "the file-read projection is bounded by the inline cap" do
    # The projection must never exceed the cap, because the tool never returns
    # more than the cap inline: over it, `handle_over_cap/5` replaces a
    # `file-read` result with a short error (text and media alike). A
    # projection above the cap prices a result the tool cannot produce, and
    # because that refusal does not depend on the conversation, compaction
    # cannot clear it — the same call is carried across the commit and
    # refused again.
    setup do
      tmp_dir =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "batchsizer-clamp-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> rm_tmp!(tmp_dir, "batchsizer-clamp-") end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "clamps a projection above the cap down to the cap", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "big.txt"), TextFixtures.big_text(400_000))

      # 400_000 bytes prices at `estimate_bytes/1` == 120_010 tokens. At
      # `context_limit: 100_000` the content budget is 80_000, so the cap is
      # floor(0.80 * 80_000) == 64_000.
      unclamped = Estimator.estimate_bytes(400_000)
      c = ctx([], context_limit: 100_000, workspace_path: dir)
      tc = call("c1", "file-read", %{"path" => "big.txt"})

      assert unclamped == 120_010
      assert ProjectedSize.project(tc, c) == 64_000
    end

    test "leaves a projection under the cap alone", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "small.txt"), TextFixtures.big_text(4_000))

      # 1_210 tokens is well under the 64_000 cap, so the clamp must not touch
      # it: the projection is the estimator's number, unchanged.
      c = ctx([], context_limit: 100_000, workspace_path: dir)

      assert ProjectedSize.project(call("c1", "file-read", %{"path" => "small.txt"}), c) ==
               Estimator.estimate_bytes(4_000)
    end

    test "clamps a media projection to the cap too", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "shot.png"), TextFixtures.big_text(10))

      # The image ceiling is 4_096 tokens whatever the file size. At
      # `context_limit: 10_000` the content budget is 1_808 (the 8_192-token
      # reserve dominates), so the cap is floor(0.80 * 1_808) == 1_446 — below
      # the ceiling, so the projection is the cap.
      c = ctx([], context_limit: 10_000, workspace_path: dir)

      assert ProjectedSize.project(call("c1", "file-read", %{"path" => "shot.png"}), c) == 1_446
    end

    test "the refused 3.3 MB PDF read fits once the projection is clamped", %{tmp_dir: dir} do
      # The incident, with its real numbers: a 3.3 MB PDF (`.pdf` is not a media
      # extension, so it prices as text) in a conversation whose provider-reported
      # floor was 93_500 tokens, against a 1_048_576-token window.
      size = 3_341_374
      File.write!(Path.join(dir, "slides.pdf"), TextFixtures.big_text(size))

      limit = 1_048_576
      messages = [{:assistant, %Assistant{usage: %{input_tokens: 93_000, output_tokens: 500}}}]
      c = ctx([], context_limit: limit, messages: messages, workspace_path: dir)
      calls = [call("c1", "file-read", %{"path" => "slides.pdf"})]

      # The premise: priced at the whole file the batch could never fit, and no
      # compaction could change that, because the number is a property of the
      # file rather than of the transcript.
      unclamped = Budget.size(messages) + Estimator.estimate_bytes(size)
      assert unclamped + Reserve.compaction_reserve(limit) > limit

      # The reserve is 209_715 and the content budget 838_861, so 93_500 tokens
      # of conversation leave 745_361 usable and a cap of 596_288.
      assert ProjectedSize.project(hd(calls), c) == 596_288
      assert {:fits, _} = BatchSizer.preflight(calls, c)
    end

    test "leaves the projection alone when the window has no usable room", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "big.txt"), TextFixtures.big_text(400_000))

      # 100 tokens cannot hold the 8_192-token reserve, so `usable_remaining/1`
      # is 0 and there is no cap to clamp to. Leaving the projection unclamped
      # is safe rather than sloppy: the reserve alone already meets the limit,
      # so the batch is refused whatever this returns — the clamp could only
      # make that refusal more certain, never turn it into a fit.
      c = ctx([], context_limit: 100, workspace_path: dir)
      calls = [call("c1", "file-read", %{"path" => "big.txt"})]

      assert ProjectedSize.project(hd(calls), c) == Estimator.estimate_bytes(400_000)
      assert {:refuse, _} = BatchSizer.preflight(calls, c)
    end
  end
end
