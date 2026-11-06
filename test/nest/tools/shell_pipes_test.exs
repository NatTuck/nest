defmodule Nest.Tools.ShellPipesTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellPipes`, which removes a `shell-cmd` command's
  trailing output-truncating stage instead of refusing the command.

  Two levels. `truncation/1` is pure — no bwrap, no I/O — so the rule is pinned
  cheaply: which stage is removed, what the command becomes, and the many shapes
  that are left alone (`grep`, `awk`, a `sed` substitution, a file operand, a
  stage that is not the last one, anything quoted or heredoc'd). The tool-level
  tests then run the real thing: the command without its stage, the complete
  output in a scratch file, and the warning that names it.
  """

  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools
  alias Nest.Tools.ShellPipes

  describe "truncation/1 removes a trailing truncating stage" do
    test "head, tail, and a sed line range, naming the stage and the command left behind" do
      for {command, prefix, stage} <- [
            {"ls | head", "ls ", "head"},
            {"ls|head", "ls", "head"},
            {"ls | head -n 5", "ls ", "head"},
            {"ls | head -20", "ls ", "head"},
            {"ls | head -c 100", "ls ", "head"},
            {"ls | tail -n 5", "ls ", "tail"},
            {"ls | /usr/bin/head", "ls ", "head"},
            {"ls | sed -n '1,50p'", "ls ", "sed"},
            {"ls | sed -n '50,100p'", "ls ", "sed"},
            {"ls | sed -n '5p'", "ls ", "sed"},
            {"ls | sed -n '$p'", "ls ", "sed"},
            {"ls | sed '1,50d'", "ls ", "sed"},
            {"ls | sed -n '1,50d'", "ls ", "sed"}
          ] do
        assert {:ok, {^prefix, ^stage}} = ShellPipes.truncation(command),
               "expected #{inspect(command)} to lose its last stage"
      end
    end

    test "keeps everything before the last stage, and takes the operator with it" do
      # The stage is the *last* one, so the earlier stages stay: the command that
      # runs is the model's own, minus the pipe that discarded its output.
      assert {:ok, {"ls | grep x ", "head"}} = ShellPipes.truncation("ls | grep x | head")
      assert {:ok, {"cd /x\nls ", "head"}} = ShellPipes.truncation("cd /x\nls | head")
      # A trailing newline (or a comment, which the tokenizer drops) is not a
      # following command, so it does not disqualify the stage.
      assert {:ok, {"ls ", "head"}} = ShellPipes.truncation("ls | head\n")
      assert {:ok, {"ls ", "head"}} = ShellPipes.truncation("ls | head # first two")
    end
  end

  describe "truncation/1 leaves everything else alone" do
    test "a filter, a file operand, or a stage that is not the last one" do
      for command <- [
            "ls | head | wc -l",
            "ls | head && echo done",
            "ls | head; echo done",
            "ls | head;",
            "ls | head > out.txt",
            "ls | head 2>/dev/null",
            "ls | grep x",
            "ls | awk '{print $1}'",
            "ls | sed 's/a/b/'",
            "ls | sed '1,50p'",
            "ls | sed -i '1,50d'",
            "ls | sed -f script.sed",
            "ls | sed -n '1,50p' file",
            "ls | head -5 file",
            "sed -n '1,5p' file",
            "head -5 file",
            "head -1 file"
          ] do
        assert {:ok, nil} = ShellPipes.truncation(command),
               "expected #{inspect(command)} to be left alone"
      end
    end

    test "a quoted pipe, a heredoc, or a stage inside a substitution" do
      for command <- [
            ~s{echo "a | head"},
            "echo 'a | head'",
            "cat <<EOF | head",
            "cat <<'EOF'\nls | head\nEOF",
            "(ls | head)",
            "ls | (head)",
            "$(ls | head)",
            "`ls | head`",
            "ls | xargs head",
            "ls | { head; }"
          ] do
        assert {:ok, nil} = ShellPipes.truncation(command),
               "expected #{inspect(command)} to be left alone"
      end
    end

    test "rejects a non-binary command with the same shape as the timeout error" do
      # The tool's schema only checks that the `command` key is present, so a
      # non-string value reaches here; it must not crash `ShellCmd`.
      for bad <- [nil, ["echo X | head"]] do
        assert {:error, message} = ShellPipes.truncation(bad)

        assert message ==
                 "Invalid `command` argument: expected a string, got: #{inspect(bad)}."
      end
    end
  end

  describe "the shell-cmd tool" do
    setup do
      unique = System.unique_integer([:positive])

      # A workspace outside /tmp, because the scratch dir is bound there.
      workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_pipe_ws_#{unique}"])
      File.mkdir_p!(workspace)

      for n <- 1..5 do
        File.write!(Path.join(workspace, "file-#{n}.txt"), "contents #{n}\n")
      end

      root = Path.join(System.tmp_dir!(), "nest_pipe_scratch_#{unique}")
      agent = "pipe-agent-#{unique}"
      scratch = Path.join([root, "space-1", agent])
      File.mkdir_p!(scratch)

      on_exit(fn ->
        if String.contains?(workspace, "nest_pipe_ws"), do: File.rm_rf!(workspace)
        rm_tmp!(root, "nest_pipe_scratch")
      end)

      %{mounts: Mounts.new(workspace, scratch), agent: agent, scratch: scratch}
    end

    @tag :bwrap
    test "a truncated command runs without its stage, and its complete output is filed", %{
      mounts: mounts,
      agent: agent,
      scratch: scratch
    } do
      for {command, stage} <- [
            {"ls | head -2", "head"},
            {"ls | tail -n 2", "tail"},
            {"ls | sed -n '1,2p'", "sed"}
          ] do
        assert {:ok, warning} = run_tool(command, mounts)

        # The stage really ran: the answer is the warning, and the file it names
        # holds all five entries rather than the two the pipe would have kept.
        path = filed_path(warning, agent)
        filed = File.read!(Path.join(scratch, Path.basename(path)))
        assert length(lines(filed)) == 5

        # The warning is the shipped text, exactly — it names the removed stage
        # and the file, and it is the deterrent (`ShellPipes.warning/2`).
        assert warning == warning_text(stage, path)
      end
    end

    @tag :bwrap
    test "a background call runs its command as written, files nothing, and is not warned about",
         %{mounts: mounts, scratch: scratch} do
      # A background job answers with a job id rather than a filed result, so
      # there is nothing to file and nothing to warn about: the pipe is left in
      # place and the job's own output is what comes back. The job reports its
      # exit to this process (the caller is its waiter), so this needs no grace
      # window to be deterministic.
      #
      # A key of its own, so the job does not land under the tools' shared
      # `{:unknown, :unknown}` fallback and disturb another test's listing. The
      # space id is above any serial a test database hands out, so a space-wide
      # listing cannot see it either.
      space_id = 1_000_000 + System.unique_integer([:positive])
      key = {space_id, "pipe-bg-#{System.unique_integer([:positive])}"}
      {space_id, name} = key

      assert {:ok, output} =
               run_tool(
                 "ls | head -2",
                 mounts,
                 %{"background" => true},
                 %{space_id: space_id, agent_name: name}
               )

      # The stage ran: two lines, not the five the file would hold.
      assert lines(output) == ["file-1.txt", "file-2.txt"]
      refute output =~ "judge agent"

      # Nothing was filed, and the job recorded the command exactly as asked —
      # a warning here would have claimed a stage was removed when it ran.
      refute Enum.any?(File.ls!(scratch), &String.starts_with?(&1, "exec-"))

      assert [%{command: "ls | head -2"}] = ShellJobs.list(key)
    end

    @tag :bwrap
    test "an untouched command runs as written, writes no file, and is not warned about", %{
      mounts: mounts,
      scratch: scratch
    } do
      for {command, expected} <- [
            {~s{echo "a | head"}, "a | head"},
            {"ls | head | wc -l", "5"},
            {"ls | grep file-1", "file-1.txt"},
            {"ls | awk '{print $1}'", "file-1.txt"},
            {"ls | sed 's/file-/item-/'", "item-1.txt"},
            {"head -2 file-3.txt", "contents 3"},
            {"sed -n '1,2p' file-4.txt", "contents 4"}
          ] do
        assert {:ok, output} = run_tool(command, mounts),
               "expected #{inspect(command)} to run as written"

        assert output =~ expected
        refute output =~ "judge agent"
        assert File.ls!(scratch) == [], "#{inspect(command)} must not file anything"
      end
    end
  end

  defp run_tool(command, mounts, extra \\ %{}, context \\ %{}) do
    Tools.get_function("shell-cmd", mounts).function.(
      Map.put(extra, "command", command),
      context
    )
  end

  # The path the warning names, as the agent sees it (`/tmp/<agent>/exec-*.txt`).
  defp filed_path(warning, agent) do
    [path] = Regex.run(~r{/tmp/#{agent}/exec-[^ ]+\.txt}, warning)
    path
  end

  defp lines(text), do: String.split(text, "\n", trim: true)

  # The warning as shipped, spelled out rather than read back from
  # `ShellPipes.warning/2`: an exact assertion is what makes a softened wording
  # fail here.
  defp warning_text(stage, path) do
    "Your command was piped into `#{stage}` and that stage was removed. " <>
      "The complete output is in #{path} — read it. " <>
      "Do not throw away output. " <>
      "If you need to choose the size, use the tool's `max_result_tokens` " <>
      "argument — that is the supported way to decide how much comes back, and " <>
      "when the result is large enough to overflow, the complete output is " <>
      "still saved to a file for you to read. " <>
      "Do not use any substitutions: no `| head`, no `| tail`, no `| sed`, no " <>
      "filtering of any kind. " <>
      "If this behaviour is repeated, every command you run will be evaluated " <>
      "for cheating by a judge agent."
  end
end
