defmodule Nest.Sandbox.Backend.Docker.CommandLineTest do
  @moduledoc """
  The literal `docker exec …` line a docker-space call becomes, asserted as text.

  `CommandLine.exec_line/5` is a pure function returning a string, and it is what
  `Docker.command/3` and `Docker.job_spec/4` both hand off to — so it needs no
  daemon, no runner seam and nothing injectable: a test calls it and reads the
  string. What the backend asks a daemon to *do* is
  `Nest.Sandbox.Backend.DockerLifecycleTest`, and what it decides before it builds
  this line is `Nest.Sandbox.Backend.DockerTest`. This file is the one place the
  string itself is pinned, because everything else asserts on what a correct
  string achieves rather than on the string — which is how a bind-mode leak like
  #129's reached a reviewer instead of a test.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.FSPath
  alias Nest.Modes
  alias Nest.Sandbox.Backend.Docker.CommandLine
  alias Nest.Sandbox.Mounts
  alias Nest.Tools.ShellEscape

  # The shape `Docker.container_name/1` returns; `exec_line/5` only interpolates
  # it, so nothing here depends on how it is composed.
  @container "nest-space-7-abc123"
  @script "/tmp/.cmds/nest-cmd-1.sh"

  describe "exec_line/5" do
    test "is `docker exec -i <container> /bin/bash -c`, with the payload as one argument" do
      command = CommandLine.exec_line(@container, mounts("/ws"), caps(), @script, nil)

      prefix = "docker exec -i #{@container} /bin/bash -c "
      assert String.starts_with?(command, prefix)

      # `-i` keeps stdin open, which is what makes a `shell-cmd` with `:stdin` (a
      # `file-write`, a `file-edit`) write anything at all; and the payload is one
      # argument rather than a script path, because the command text is a staged
      # file the payload hands to bash.
      assert shell_arguments(String.replace_prefix(command, prefix, "")) ==
               {1, [payload(command)]}
    end

    test "is the scratch prefix and then the inner sandbox, and nothing else" do
      inner = payload(CommandLine.exec_line(@container, mounts("/ws"), caps(), @script, nil))

      assert inner ==
               "mkdir -p '/tmp/agent-a' && " <>
                 "exec bwrap --die-with-parent --new-session --ro-bind / / " <>
                 "--dev-bind /dev /dev --proc /proc --bind '/ws' '/ws' --bind '/tmp' '/tmp' " <>
                 "--chdir '/ws' /bin/bash '#{@script}'"

      # A foreground call has no pipeline: `docker exec`'s status is bwrap's.
      refute inner =~ "pipefail"
      refute inner =~ "tee"
    end

    test "a background call adds pipefail and a tee, and keeps the command's exit code" do
      log = "/tmp/agent-a/shell-jobs/job-1.log"
      foreground = payload(CommandLine.exec_line(@container, mounts("/ws"), caps(), @script, nil))
      background = payload(CommandLine.exec_line(@container, mounts("/ws"), caps(), @script, log))

      # `pipefail` comes before the pipeline, or the job's status would be `tee`'s
      # and a job that failed would report exit 0, and the `tee` comes after the
      # command. The log's directory is not the scratch's, so the prefix names
      # both of them.
      assert String.starts_with?(background, "set -o pipefail; ")
      assert background =~ "mkdir -p '/tmp/agent-a' '/tmp/agent-a/shell-jobs' && exec bwrap"
      assert background =~ " 2>&1 | tee '#{log}'"

      # … and when they are the same directory it names it once, so the whole line
      # is the foreground one with exactly two additions: `pipefail` in front and
      # a `tee` at the end. A log in the scratch itself is the ordinary case
      # (`ShellJobs` writes `<scratch>/…`).
      same_dir =
        payload(
          CommandLine.exec_line(
            @container,
            mounts("/ws"),
            caps(),
            @script,
            "/tmp/agent-a/job.log"
          )
        )

      assert same_dir ==
               "set -o pipefail; " <> foreground <> " 2>&1 | tee '/tmp/agent-a/job.log'"

      refute same_dir =~ "'/tmp/agent-a' '/tmp/agent-a'"
    end

    test "makes no directory when the call binds no scratch and writes no log" do
      # `Mounts` allows either directory to be nil, and a call that binds no
      # scratch has nothing to create: the prefix is what makes the *container's*
      # `/tmp/<agent>`, and there is none.
      no_scratch = Mounts.new("/ws", nil, "docker", space_id())
      inner = payload(CommandLine.exec_line(@container, no_scratch, caps(), @script, nil))

      assert inner ==
               "exec bwrap --die-with-parent --new-session --ro-bind / / " <>
                 "--dev-bind /dev /dev --proc /proc --bind '/ws' '/ws' " <>
                 "--chdir '/ws' /bin/bash '#{@script}'"

      refute inner =~ "mkdir"
    end

    test "escapes a path with a space and one with a quote for both shell layers" do
      ws = Path.join(workspace("nest_docker_cl_escape"), "it's a ws")
      File.mkdir_p!(ws)
      script = "/tmp/.cmds/it's.sh"
      log = "/tmp/agent-a/it's a dir/job.log"

      command = CommandLine.exec_line(@container, mounts(ws), caps(), script, log)
      inner = payload(command)

      # The container's bash: each path is exactly one argument of the `mkdir`,
      # the bwrap or the `tee` that takes it, which is the property that matters —
      # not that a backslash appears somewhere.
      for path <- [ws, script, log, Path.dirname(log)] do
        assert shell_arguments(ShellEscape.escape(path)) == {1, [path]}
      end

      assert inner =~ "--chdir " <> ShellEscape.escape(ws)
      assert inner =~ "/bin/bash " <> ShellEscape.escape(script)
      assert inner =~ "| tee " <> ShellEscape.escape(log)
      assert inner =~ "mkdir -p '/tmp/agent-a' " <> ShellEscape.escape(Path.dirname(log))

      # And the BEAM's layer: the whole payload is one argument of `docker exec`,
      # so the escaping of the escaping is what makes the container's bash see the
      # paths above rather than the host's shell splitting them first.
      prefix = "docker exec -i #{@container} /bin/bash -c "
      assert shell_arguments(String.replace_prefix(command, prefix, "")) == {1, [inner]}
    end

    test "masks an absent .nest and AGENTS.md from /dev/null, because the container binds neither" do
      ws = workspace("nest_docker_cl_masks")
      nest = Path.join(ws, ".nest")
      agents_md = Path.join(ws, "AGENTS.md")

      caps =
        caps_with(%{
          "protected" => [
            %{"path" => nest, "source" => "/dev/null"},
            %{"path" => agents_md, "source" => "/dev/null"}
          ]
        })

      inner = payload(CommandLine.exec_line(@container, mounts(ws), caps, @script, nil))

      for path <- [nest, agents_md] do
        assert inner =~ "--ro-bind /dev/null #{ShellEscape.escape(path)}"

        # A mask, not a self-bind: the container binds neither file
        # (`Binds.container_specs/1` drops both), so there is nothing at the dest
        # for the sandbox inside to set the mode of. Binding `/dev/null` is what
        # makes reading the file fail with `EACCES` rather than return empty bytes.
        refute inner =~ "--ro-bind #{ShellEscape.escape(path)} #{ShellEscape.escape(path)}"
      end
    end

    test "renders the same call's binds with the mode's own write permission" do
      real = workspace("nest_docker_cl_mode")
      spelling = real <> "-alias"
      File.ln_s!(real, spelling)
      on_exit(fn -> File.rm(spelling) end)

      act =
        payload(
          CommandLine.exec_line(
            @container,
            mounts(spelling),
            Modes.caps(Modes.act()),
            @script,
            nil
          )
        )

      plan =
        payload(
          CommandLine.exec_line(
            @container,
            mounts(spelling),
            Modes.caps(Modes.plan()),
            @script,
            nil
          )
        )

      # Both the canonical bind and the spelling self-bind follow the call's mode.
      # The spelling bind is the second, writable view of the workspace, so its
      # mode is exactly what a bind leak gets wrong: assert it and the leak in
      # #129 is caught here rather than by a reviewer.
      for path <- [FSPath.canonical(real), spelling] do
        assert act =~ "--bind #{ShellEscape.escape(path)} #{ShellEscape.escape(path)}"
        assert plan =~ "--ro-bind #{ShellEscape.escape(path)} #{ShellEscape.escape(path)}"
        refute plan =~ "--bind #{ShellEscape.escape(path)}"
      end

      # `plan` may write the space's scratch, so `/tmp` is writable in both.
      assert act =~ "--bind '/tmp' '/tmp'"
      assert plan =~ "--bind '/tmp' '/tmp'"
    end
  end

  describe "workspace_spelling/2" do
    test "is empty for no workspace and for a canonical one, and one bind for a spelling" do
      assert CommandLine.workspace_spelling(mounts(), :rw) == []
      assert CommandLine.workspace_spelling(mounts("/ws"), :rw) == []

      real = workspace("nest_docker_cl_spelling")
      assert CommandLine.workspace_spelling(mounts(FSPath.canonical(real)), :ro) == []

      spelling = real <> "-alias"
      File.ln_s!(real, spelling)
      on_exit(fn -> File.rm(spelling) end)

      # The container sees only the image and the explicit binds, so nothing
      # resolves the caller's spelling of a symlinked workspace for it. The
      # sandbox inside materializes that spelling, with the call's own mode, or
      # every path the model was given names a path the container does not have.
      for mode <- [:rw, :ro] do
        assert CommandLine.workspace_spelling(mounts(spelling), mode) ==
                 [{spelling, spelling, mode}]
      end
    end
  end

  # ---- the shell's own answer ----

  # What a shell makes of `word`: how many arguments it is, and which.
  #
  # Both escaping jobs in this module are "the shell sees one argument" — the
  # payload is one argument of `docker exec`, and each path inside it is one
  # argument of the bwrap in the container — so `set --` is the assertion, rather
  # than a substring match on a quote character. A word that split would report a
  # count above 1; a word that a shell refused would fail here rather than pass.
  defp shell_arguments(word) do
    script = "set -- " <> word <> "; printf '%s\\n' \"$#\"; printf '%s\\n' \"$@\""

    case System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(output, "\n", trim: true) do
          [count | arguments] -> {String.to_integer(count), arguments}
        end

      {output, code} ->
        flunk("the shell refused #{inspect(word)} (exit #{code}): #{output}")
    end
  end
end
