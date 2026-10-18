defmodule Nest.Sandbox.Backend.DockerProtectedTest do
  @moduledoc """
  The two protected config files (`.nest` and `AGENTS.md`) and the docker
  backend: what the container binds, what the sandbox inside masks, and what the
  container's *layout* is allowed to depend on.

  Split from `Nest.Sandbox.Backend.DockerTest` to keep that file under the credo
  cap.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.Backend.DockerTestHelpers

  alias Nest.Sandbox.Backend.Docker
  alias Nest.Tools.ShellEscape

  # ---- the protected config files ----

  describe "the protected config files" do
    test "neither is part of the container's layout" do
      # The container does not bind them — the bwrap inside masks them per call —
      # so whether they exist must not move the layout. It has to not be: the
      # `/dev/null` mask materialises both files on the first command, and people
      # add an `AGENTS.md` while agents are running, and a layout change replaces
      # the container, which takes the space's `/tmp` (offloads, job logs,
      # running jobs) with it.
      ws = workspace("nest_docker_layout")
      layout = Docker.layout(mounts(ws), caps(), [])

      File.write!(Path.join(ws, ".nest"), "")
      File.write!(Path.join(ws, "AGENTS.md"), "policy\n")

      assert Docker.layout(mounts(ws), caps(), []) == layout
    end

    test "masks both at the workspace's own spelling, not only at the canonical path" do
      # A symlinked workspace is bound at its canonical path *and* at the path the
      # caller named, because the container sees only the image and the explicit
      # binds — nothing resolves a symlink for it. Two binds of one directory are
      # two writable views of it, so a mask at the canonical path alone leaves
      # `<spelling>/.nest` an ordinary writable file, at the very path `--chdir`,
      # the prompt and every tool path use. Measured at the kernel level with the
      # same two-bind shape: without the spelling mask the write succeeds and the
      # host's canonical `.nest` becomes the written bytes; with it the write is
      # `EACCES` and the host file is untouched.
      real = workspace("nest_docker_spelling")
      spelling = real <> "-alias"
      File.ln_s!(real, spelling)
      on_exit(fn -> File.rm(spelling) end)

      nest = Path.join(real, ".nest")
      agents_md = Path.join(real, "AGENTS.md")
      File.write!(agents_md, "policy\n")

      caps =
        caps_with(%{
          "protected" => [
            %{"path" => nest, "source" => "/dev/null"},
            %{"path" => agents_md, "source" => agents_md}
          ]
        })

      assert {:ok, %{command: command}} = Docker.command(mounts(spelling), caps, "echo hi")
      command = payload(command)

      # The canonical masks are still there …
      assert command =~ "--ro-bind /dev/null #{ShellEscape.escape(nest)}"

      # … and so are the spelling ones, after the rw self-bind that would
      # otherwise be the last word on that path.
      assert command =~
               "--ro-bind #{ShellEscape.escape("/dev/null")} " <>
                 ShellEscape.escape(Path.join(spelling, ".nest"))

      assert command =~
               "--ro-bind #{ShellEscape.escape(agents_md)} " <>
                 ShellEscape.escape(Path.join(spelling, "AGENTS.md"))

      assert String.split(command, "--bind #{ShellEscape.escape(spelling)}") |> length() == 2
    end

    test "the container binds neither, and the sandbox inside masks both" do
      ws = workspace("nest_docker_binds")
      nest = Path.join(ws, ".nest")
      agents_md = Path.join(ws, "AGENTS.md")
      File.write!(agents_md, "policy\n")

      dests = for {_source, dest, _mode} <- Docker.container_binds(mounts(ws)), do: dest
      refute nest in dests
      refute agents_md in dests

      # What `ProjectConfig.effective_caps/2` puts on a *call's* caps: the absent
      # file masked with `/dev/null`, the present one over itself. Per call they
      # are masked exactly as the bwrap backend masks them — an absent file bound
      # from `/dev/null`, which is why reading a masked file fails with `EACCES`
      # rather than returning empty bytes, and a present one self-bound to set its
      # mode (its content is already there through the workspace bind).
      caps =
        caps_with(%{
          "protected" => [
            %{"path" => nest, "source" => "/dev/null"},
            %{"path" => agents_md, "source" => agents_md}
          ]
        })

      assert {:ok, %{command: command}} = Docker.command(mounts(ws), caps, "echo hi")
      command = payload(command)

      assert command =~ "--ro-bind /dev/null #{ShellEscape.escape(nest)}"

      assert command =~
               "--ro-bind #{ShellEscape.escape(agents_md)} #{ShellEscape.escape(agents_md)}"
    end
  end
end
