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
      # the prompt and every tool path use. Measured by hand at the kernel level
      # with the same two-bind shape (`notes/sandbox-backends.md` records it):
      # without the spelling mask the write succeeds and the host's canonical
      # `.nest` becomes the written bytes; with it the write is `EACCES` and the
      # host file is untouched. This test asserts the rendered command line.
      #
      # The canonical masks are `CommandLineTest`'s ("masks an absent .nest and
      # AGENTS.md from /dev/null"), and the `/dev/null` mask's shape is
      # `DockerTest`'s ("the shared bind list"); the spelling-dest'd copy is the
      # one nothing else renders, so it is the only thing asserted here.
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

      # … and the spelling ones, after the rw self-bind that would otherwise be
      # the last word on that path: both files, each re-dest'd at the spelling —
      # the absent one from `/dev/null`, the present one from itself.
      assert command =~
               "--ro-bind #{ShellEscape.escape("/dev/null")} " <>
                 ShellEscape.escape(Path.join(spelling, ".nest"))

      assert command =~
               "--ro-bind #{ShellEscape.escape(agents_md)} " <>
                 ShellEscape.escape(Path.join(spelling, "AGENTS.md"))
    end

    test "a present file is neither bound at the container nor masked from /dev/null" do
      # The absent-file halves are already pinned: that the container binds
      # neither is `DockerTest`'s "binds the workspace read-write, and neither
      # config file", and the `/dev/null` mask the sandbox inside makes for an
      # absent one is `CommandLineTest`'s "masks an absent .nest and AGENTS.md
      # from /dev/null". What only a *present* file shows is the other branch: the
      # container still binds it not at all — a container-level copy would shadow
      # the file a human edits later — and the sandbox inside **self**-binds it
      # rather than masking it, because the content is already there through the
      # workspace bind and the bind's job is to set the file's mode.
      ws = workspace("nest_docker_binds")
      agents_md = Path.join(ws, "AGENTS.md")
      File.write!(agents_md, "policy\n")

      dests = for {_source, dest, _mode} <- Docker.container_binds(mounts(ws)), do: dest
      refute agents_md in dests

      caps = caps_with(%{"protected" => [%{"path" => agents_md, "source" => agents_md}]})

      assert {:ok, %{command: command}} = Docker.command(mounts(ws), caps, "echo hi")
      command = payload(command)

      assert command =~
               "--ro-bind #{ShellEscape.escape(agents_md)} #{ShellEscape.escape(agents_md)}"
    end
  end
end
