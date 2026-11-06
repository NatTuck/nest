defmodule Nest.Agents.Agent.BatchSizerCapTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.BatchSizer`'s `max_result_tokens` cap.

  Split out from `batch_sizer_test.exs` to keep that file under the
  500-line Credo cap. The cap is a gate (does the result fit inline,
  or do we route it through a different path?), never a shrinker
  (we never truncate a result to fit).

  Per `notes/no-truncation-or-overflow.md`:
    * `budget = context_limit - estimate_messages(messages) - reserve`
    * `requested = max_result_tokens || the tool's default`
    * `limit = min(requested, budget)` — there is no share of the window
    * When exceeded: every tool but `file-read` is filed and replaced by a
      pointer + preview; `file-read` gets a structured error.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.BatchSizer.ProjectedSize
  alias Nest.Agents.Agent.ResultPolicy

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
    # * limit = min(requested, budget), where
    #   budget = context_limit - size(messages) - reserve.
    # * `context_limit: 100_000` leaves 80_000 of budget, so the 8_000-token
    #   default is far above these outputs and the `max_result_tokens: 100`
    #   override is the only thing that bites.
    # * `context_limit: 20_000` leaves 11_808 (the 8_192-token reserve
    #   dominates), so an override above 11_808 is capped by the budget — never
    #   by the default.

    test "an override below the default files a result that would have fit",
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
      assert result.content =~ "Output of shell-cmd"
      assert result.content =~ "saved to"

      [exec_file] = Enum.filter(File.ls!(dir), &String.starts_with?(&1, "exec-"))
      assert File.read!(Path.join(dir, exec_file)) == output
    end

    test "an override above the default is honoured up to the budget", %{tmp_dir: dir} do
      # 40_000 chars ≈ 10_000 tokens. The model asked for 100_000; the budget
      # is 11_808, so the limit is the budget and the output fits inline. The
      # default of 8_000 would have filed it — the ask is what raises it.
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
      # Kept whole: the ask raised the limit above the 8_000 default, and the
      # output fits the budget the window actually leaves.
      refute result.content =~ "saved to"
    end

    test "an error result over the limit is filed like any other", %{tmp_dir: dir} do
      # The incident, in one call: a `grep` that exits non-zero still returns its
      # whole output as the result's content. Before the `:error` arm went
      # through the same admission, that content was sized and kept inline
      # whatever its size — 1.8 MB of it produced a 1.42M-token request against
      # a 1.05M window.
      big = TextFixtures.big_text(40_000)
      tools = [make_tool("shell-cmd", fn _, _ -> {:error, big} end)]
      c = ctx(tools, context_limit: 20_000, tmp_path: dir)

      log =
        capture_log(fn ->
          assert [%ToolResult{is_error: true, content: content}] =
                   BatchSizer.run(
                     [call("c1", "shell-cmd", %{"command" => "grep -R x ."})],
                     c
                   )

          # Filed, not kept: the kind is still an error, and the content is the
          # pointer, well under the 8_000 default it exceeded.
          assert content =~ "saved to"
          assert Estimator.estimate(content) < 8_000

          [exec_file] = Enum.filter(File.ls!(dir), &String.starts_with?(&1, "exec-"))
          assert File.read!(Path.join(dir, exec_file)) == big
        end)

      assert log =~ "BatchSizer produced is_error=true tool result"
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

      assert content =~ "Output of shell-wait"
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
      #
      # The bound is `1_000` and not "much smaller than the body", because the
      # pointer has a known shape: one sentence plus the scratch path. Measured
      # on this host it is 908 bytes, so the headroom is the path — the only
      # part whose length varies (the temp dir). It was loosened to 2_000 once;
      # 2_000 is not the real bound, it is the real bound plus a slack nobody
      # had measured, and the body is 40 000 bytes either way.
      assert content =~ "saved to"
      assert byte_size(content) < 1_000
    end
  end

  describe "the admission's failure paths" do
    # `cook/2` admits every result through `ResultPolicy`, and a result over its
    # limit is filed. These are the two ways that can go wrong: the scratch write
    # fails, and the lossy view of a binary is empty.
    setup do
      dir =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "batchsizer-admit-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "batchsizer-admit-") end)
      {:ok, tmp_dir: dir}
    end

    test "a text result that cannot be filed is an error naming the size" do
      # No scratch dir, so `Overflow.substitute/5` cannot write: the result
      # becomes an error rather than an inline copy over the budget.
      c = ctx([], context_limit: 100)
      big = TextFixtures.big_text(40_000)

      # The turn logs the error result it produced; that is the line captured
      # here, asserted rather than silenced.
      log =
        capture_log(fn ->
          assert [%ToolResult{is_error: true, content: content}] =
                   BatchSizer.cook([{call("c1", "agents-query", %{}), :ok, big}], c)

          assert content == ResultPolicy.offload_failure(Estimator.estimate(big))
          assert content =~ "could not be written"
        end)

      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "agents-query"
    end

    test "a non-text result that cannot be filed is an error too" do
      # The same failure on the binary path, which writes with `Overflow.write/5`
      # rather than `substitute/5` — one place each, both saying so.
      c = ctx([], context_limit: 100)

      log =
        capture_log(fn ->
          assert [%ToolResult{is_error: true, content: content}] =
                   BatchSizer.cook([{call("c1", "shell-cmd", %{}), :ok, <<0, 1, 2, 0, 255>>}], c)

          assert content =~ "could not be written"
        end)

      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "shell-cmd"
    end

    test "a small binary's lossy view rides along with its pointer", %{tmp_dir: tmp_dir} do
      # Every byte is NUL, and NUL is replaced rather than dropped — so the view
      # is never empty, and a small binary always shows one after the pointer.
      c = ctx([], context_limit: 100_000, tmp_path: tmp_dir)

      assert [%ToolResult{is_error: false, content: content}] =
               BatchSizer.cook([{call("c1", "shell-cmd", %{}), :ok, <<0, 0, 0, 0>>}], c)

      assert content =~ "saved to"
      assert content =~ "\n\n"
      assert content =~ "\uFFFD"
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
      # `context_limit: 10_000` the budget is 1_808 (the 8_192-token reserve
      # dominates), so the limit is the budget — below the ceiling — and the
      # projection is the limit.
      c = ctx([], context_limit: 10_000, workspace_path: dir)

      assert ProjectedSize.project(call("c1", "file-read", %{"path" => "shot.png"}), c) == 1_808
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
      # of conversation leave 745_361 of budget. `file-read`'s requested size is
      # 32_000, so that is the limit and the projection is clamped to it.
      assert ProjectedSize.project(hd(calls), c) == 32_000
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

    test "two over-cap reads now fit, so the refusal loop cannot start", %{tmp_dir: dir} do
      # This used to be a recorded limitation: two clamped `file-read`s cost
      # `2 * cap` and the cap was 80% of the budget, so two of them always
      # exceeded the window — and because the refusal is a property of the
      # files rather than the transcript, compaction re-refused the same
      # carried calls. With `file-read`'s limit at a flat 32_000, two of them
      # cost 64_000 against a 745_361 budget, so the batch fits.
      File.write!(Path.join(dir, "big.txt"), TextFixtures.big_text(3_000_000))

      limit = 1_048_576
      c = ctx([], context_limit: limit, workspace_path: dir)

      calls = [
        call("c1", "file-read", %{"path" => "big.txt"}),
        call("c2", "file-read", %{"path" => "big.txt"})
      ]

      assert ProjectedSize.project_batch(calls, c) == 2 * 32_000
      assert {:fits, _} = BatchSizer.preflight(calls, c)
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
