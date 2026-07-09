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

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.LLM.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
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
      tmp_path: Keyword.get(opts, :tmp_path, nil),
      agent_pid: self(),
      agent_name: "test"
    }
  end

  describe "max_result_tokens cap" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "batchsizer-cap-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
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
      big_output = String.duplicate("z", 40_000)

      tools = [
        make_tool("shell_cmd", fn _, _ -> {:ok, big_output} end)
      ]

      c = ctx(tools, context_limit: 20_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [call("c1", "shell_cmd", %{"command" => "cat foo"})],
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
      output = String.duplicate("q", 1_000)

      tools = [
        make_tool("shell_cmd", fn _, _ -> {:ok, output} end)
      ]

      c = ctx(tools, context_limit: 100_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [
                   call("c1", "shell_cmd", %{
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
      big_output = String.duplicate("r", 40_000)

      tools = [
        make_tool("shell_cmd", fn _, _ -> {:ok, big_output} end)
      ]

      c = ctx(tools, context_limit: 20_000, tmp_path: dir)

      assert [result] =
               BatchSizer.run(
                 [
                   call("c1", "shell_cmd", %{
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
      tools = [small_tool("shell_cmd")]
      c = ctx(tools, context_limit: 100_000, tmp_path: dir)

      assert [%ToolResult{content: content, is_error: false}] =
               BatchSizer.run(
                 [call("c1", "shell_cmd", %{"command" => "ls"})],
                 c
               )

      assert content == "small output for shell_cmd"
      refute content =~ "saved to"
      assert Enum.all?(File.ls!(dir), &(not String.starts_with?(&1, "exec-")))
    end

    test "read_file exceeding cap returns error with token-count hint", %{tmp_dir: dir} do
      # ~5_000 bytes ≈ 1_250 tokens → exceeds the 100-token override.
      big_content = String.duplicate("v", 5_000)
      file = Path.join(dir, "big.txt")
      File.write!(file, big_content)

      tools = [Tools.get_function("read_file", dir)]
      c = ctx(tools, context_limit: 100_000)

      assert [%ToolResult{is_error: true, content: error}] =
               BatchSizer.run(
                 [
                   call("c1", "read_file", %{
                     "path" => "big.txt",
                     "max_result_tokens" => 100
                   })
                 ],
                 c
               )

      assert error =~ "File is"
      assert error =~ "tokens which exceeds your requested limit of 100"
    end

    test "no cap when context_limit is nil (degraded-but-hopeful path)" do
      big_output = String.duplicate("w", 40_000)

      tools = [
        make_tool("shell_cmd", fn _, _ -> {:ok, big_output} end)
      ]

      c = ctx(tools, context_limit: nil)

      assert [%ToolResult{content: content, is_error: false}] =
               BatchSizer.run(
                 [call("c1", "shell_cmd", %{"command" => "ls"})],
                 c
               )

      assert content == big_output
      refute content =~ "saved to"
    end
  end
end
