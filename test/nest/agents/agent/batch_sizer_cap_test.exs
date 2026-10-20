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
      `read_file` → structured error, others → path-and-head substitute.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Agents.Agent.CapCalculator
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
    # * cap = min(LLM override, floor(usable * 0.80)), where
    #   usable = context_limit - size(messages) - reserve.
    # * `context_limit: 100_000` leaves 80_000 usable, so the default cap is
    #   64_000 — far above these outputs, so the `max_result_tokens: 100`
    #   override is the only thing that bites.
    # * `context_limit: 20_000` leaves 11_808 usable (the 8_192-token reserve
    #   dominates), so the default cap is 9_446 — which the `max_result_tokens:
    #   100_000` override is clamped to.

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
      # Substituted, not kept whole: had the override been honoured the
      # ~12_000-token output would have gone inline under a 100_000 cap.
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
      # Nothing was offloaded: no substitute was built at all.
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

          assert error =~ "tokens which exceeds your requested limit of 100"
        end)

      # The `is_error=true` cap-overflow path is a deliberate
      # diagnostic — assert on it so the test's intent is
      # self-documenting and the log doesn't escape to the test
      # output. The tool name is asserted too: `capture_log` is
      # process-global, so the generic line alone could be another
      # test's.
      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "tool=file-read"
    end

    test "raises when context_limit is nil (limit is never optional)" do
      # `preflight/2` is where the raise happens, so the batch needs no tool
      # and no output: it never reaches execution.
      calls = [call("c1", "shell-cmd", %{"command" => "ls"})]

      assert_raise FunctionClauseError, fn ->
        BatchSizer.run(calls, ctx([], context_limit: nil))
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

      # One name per `write_prefix/1` shape other than `shell-wait`'s: the
      # shell tools' shared "exec" prefix, and the sanitized tool name.
      for name <- ["shell-list", "file-inspect"] do
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

    test "a spent window substitutes rather than raising", %{tmp_dir: dir} do
      # `cook/2` is reachable without the preflight that would have refused this
      # batch — it runs once over a merged regular + sub-agent batch — and a
      # spent window leaves `usable` at 0, which `effective_max_result_tokens/2`
      # will not take. The result must be substituted, not raised on: before
      # `cap_for/2` existed this crashed the turn with a FunctionClauseError.
      big = TextFixtures.big_text(40_000)
      entries = [{call("c1", "agents-query", %{"name" => "peer"}), :ok, big}]

      # 100 tokens cannot hold the 8_192-token reserve, so the window is spent.
      c = ctx([], context_limit: 100, tmp_path: dir)

      assert [%ToolResult{is_error: false, content: content}] = BatchSizer.cook(entries, c)

      # Substituted, not kept full: with no budget left `Overflow.substitute/5`
      # returns its pointer form. The claim is that it did not raise and did not
      # keep the 40 000-byte body.
      assert content =~ "content elided"
      assert byte_size(content) < 1_000
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

    test "two over-cap reads still refuse, and compaction cannot clear it", %{tmp_dir: dir} do
      # The known gap this branch does NOT close, pinned so it is a recorded
      # limitation rather than a surprise. Two clamped `file-read`s cost
      # `2 * cap = 1.6 * usable`, and `size + reserve = limit - usable` by
      # definition, so the total is `limit + 0.6 * usable` — above the limit for
      # every `usable > 0`. Measured here: 2 * 671_088 + 209_715 = 1_551_891
      # against a 1_048_576 limit.
      #
      # The refusal is a property of the files, not of the transcript, so the
      # compaction it routes into re-refuses the same carried calls — the loop
      # the clamp was written for. Closing it needs the routing to refuse to
      # the model instead of compacting (P2), and the loop breaker un-disarmed
      # (P3); neither belongs here.
      File.write!(Path.join(dir, "big.txt"), TextFixtures.big_text(3_000_000))

      limit = 1_048_576
      c = ctx([], context_limit: limit, workspace_path: dir)

      # The same file twice: the refusal depends on the file, not the
      # conversation, which is exactly why compaction cannot clear it.
      calls = [
        call("c1", "file-read", %{"path" => "big.txt"}),
        call("c2", "file-read", %{"path" => "big.txt"})
      ]

      cap = floor(CapCalculator.usable_remaining(c) * 0.8)

      assert ProjectedSize.project_batch(calls, c) == 2 * cap
      assert {:refuse, _} = BatchSizer.preflight(calls, c)
    end
  end

  describe "the request byte ceiling" do
    # Media is priced at a flat token ceiling, so a batch of images can be
    # trivial on tokens and enormous on the wire. These two are the same batch
    # shape at two file sizes: the token budget admits both, and only the byte
    # ceiling separates them.
    setup do
      tmp_dir =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "batchsizer-bytes-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> rm_tmp!(tmp_dir, "batchsizer-bytes-") end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "refuses a batch of images that would put the request over it", %{tmp_dir: dir} do
      # 13 MB of image is ~17.3 MB once base64-encoded — over the 16 MB ceiling —
      # while its token price is a flat 4,096.
      File.write!(Path.join(dir, "big.png"), :binary.copy(<<0>>, 13_000_000))

      c = ctx([], context_limit: 100_000, workspace_path: dir)
      calls = [call("c1", "file-read", %{"path" => "big.png"})]

      # The premise: the token budget would have admitted this batch on its own,
      # which is exactly how agent 916 reached a 51 MB request at 25% of its
      # window.
      assert ProjectedSize.project_batch(calls, c) + Reserve.compaction_reserve(100_000) <=
               100_000

      assert {:refuse, reason} = BatchSizer.preflight(calls, c)
      assert reason =~ "MB"
      # The refusal names the remedy, and compaction is one: it replaces the
      # conversation with a summary and drops the images, so this is not the
      # shape that loops.
      assert reason =~ "context-compact"
    end

    test "admits the same batch when the images fit under it", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "small.png"), :binary.copy(<<0>>, 1_000_000))

      c = ctx([], context_limit: 100_000, workspace_path: dir)
      calls = [call("c1", "file-read", %{"path" => "small.png"})]

      assert {:fits, _} = BatchSizer.preflight(calls, c)
    end

    test "does not refuse a batch that adds no media, even over the ceiling", %{tmp_dir: dir} do
      # The ceiling is self-imposed and sits well under the provider's 48 MiB, so
      # refusing ordinary work at 16 MB would be a false refusal: text is bounded
      # by the token window and no window holds 16 MB of text, so a media-free
      # batch cannot push the request past what the provider accepts. Without
      # this, a media-heavy conversation could not run `shell-cmd ls`.
      over_ceiling =
        {:user,
         %{
           parts: [
             %Nest.Messages.Part.Media{
               tool_call_id: "c0",
               modality: :image,
               media_type: "image/png",
               data: String.duplicate("A", 16_100_000),
               bytes: 16_100_000,
               path: "old.png"
             }
           ]
         }}

      c =
        ctx([], context_limit: 1_048_576, messages: [over_ceiling], workspace_path: dir)

      assert {:fits, _} = BatchSizer.preflight([call("c1", "shell-cmd", %{"command" => "ls"})], c)
    end
  end
end
