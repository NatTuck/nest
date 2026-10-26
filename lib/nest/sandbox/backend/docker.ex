defmodule Nest.Sandbox.Backend.Docker do
  # The image's identity, declared before the `@moduledoc` because the moduledoc
  # interpolates two of them.
  @base_image "debian:trixie-slim"

  # `bubblewrap` is not optional: the container is only half the sandbox. The
  # mode's caps are enforced by a bwrap *inside* it (see the moduledoc), so an
  # image without it could run nothing at all.
  @base_packages ~w(bash coreutils file git curl ca-certificates procps ripgrep bubblewrap)

  # The label a container carries its layout in. Declared before the moduledoc
  # because the moduledoc names it.
  @layout_label "nest.layout"

  @moduledoc """
  The docker backend: bwrap runs *inside* a container the space shares.

  ## Two layers, one bind list

  The container's root filesystem is the derived image — the host's `/` is not
  visible in it at all — and every command runs inside a `bwrap` in that
  container:

      docker exec -i <container> /bin/bash -c 'mkdir -p … && exec bwrap …'

  The *same* bind list (`Nest.Sandbox.Binds.specs/2`) is applied over the
  container's root instead of over the host's, so the two backends cannot drift,
  and a read-only mode keeps its teeth here for the same reason it does there.
  The container binds the **superset** a space can need, because its mounts are
  fixed at creation and one container serves every mode its space can run; the
  sandbox inside it tightens per call, by re-applying each bind the call's caps
  ask for as a self-bind of the path the container already put there. And
  `caps.fs.read` is not what docker binds: **the image is the read set**, made
  read-only, so a host path that is read-only under bwrap is simply absent here.

  ## The container

  Named `nest-space-<space_id>-<installation>` (`Nest.Sandbox.Installation`), and
  **stable across BEAM restarts**: nothing per-BEAM is bound any more, because
  the scratch is the container's own `/tmp` and the one host directory a call
  needs (`Nest.Sandbox.Paths.docker_stage_dir/1`) is keyed on the space. That is
  what lets the container outlive a restart — the original design's intent, and
  what its pid-keyed layout made impossible.

  Because the name cannot move when the layout does, the layout travels as a
  `#{@layout_label}` **label** instead, covering the binds, the image and the
  network: every call inspects the container once (status and label in one call),
  and a container whose label does not match is removed and created again.
  Nothing is ever orphaned, so there is no sweep — a `.nest` package change, a
  workspace change, a hardware change or a **net edit** replaces the container in
  place on the next command. `notes/sandbox-backends.md` has the rest: the
  measured table of the container flags, what the one narrowable flag costs, why
  the staging directory is bound read-only, and why nothing on the host may touch
  the agent's scratch.
  """

  require Logger

  @name_prefix "nest-space-"
  @image_prefix "nest-sandbox:"
  @build_dir_prefix "nest-docker-build-"

  # The bwrap that runs inside the container. `--ro-bind / /` is the whole point
  # (the image becomes read-only); `--dev-bind /dev /dev` and `--proc /proc` are
  # required because that same bind made them read-only, so redirects to
  # `/dev/null` and `/proc/self` would otherwise break. There is deliberately no
  # `--unshare-all`, `--unshare-user` or `--unshare-net`.

  # The flags every container of this backend is created with.
  @container_flags [
    "--cap-add",
    "SYS_ADMIN",
    "--security-opt",
    "apparmor=unconfined",
    "--security-opt",
    "seccomp=unconfined"
  ]

  # The status and the layout label in one `docker inspect`: a container that is
  # there but was built for a different layout has to be replaced, not started.
  @inspect_format ~s({{.State.Status}}|{{index .Config.Labels "#{@layout_label}"}})

  # A container name segment: what a docker object name may contain after the
  # first character. `this_space?/2` uses it to decide whether a name the
  # daemon's substring filter matched is really this space's container.
  @segment_format ~r/\A[A-Za-z0-9_.-]+\z/

  # 6 bytes of hex for the layout label and 6 for the image tag: both are read by
  # a human, and a collision needs two different layouts of one space to agree on
  # 48 bits.
  @layout_bytes 6
  @image_hash_bytes 6

  @log_tag "[Nest.Sandbox.Backend.Docker]"
  @message_limit 500

  # The daemon's own failures, which mean the sandbox never ran the command.
  @docker_markers [
    "No such container",
    "is not running",
    "Cannot connect to the Docker daemon",
    "Error response from daemon"
  ]

  alias Nest.Hardware
  alias Nest.ProjectConfig
  alias Nest.Sandbox
  alias Nest.Sandbox.Backend.Docker.CommandLine
  alias Nest.Sandbox.{Binds, Failure, Installation, Mounts, Paths}

  # ---- the backend contract ----

  @doc """
  `docker exec -i <container> /bin/bash -c '<payload>'`, where the payload makes
  the agent's scratch directory and then `exec`s the inner bwrap.

  `-i` is required: without it the exec's stdin is closed and a `shell-cmd` with
  `:stdin` (a `file-write`, a `file-edit`) would silently write nothing. The
  command text itself is never an argv element — it is a staged file the payload
  hands to bash — so the escaping here only has to survive the paths this module
  builds.

  `cd` is `nil`: the container was started with `-w`.
  """
  @spec command(Mounts.t(), map() | nil, String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def command(mounts, caps, script) do
    caps = caps || Sandbox.default_caps()

    with :ok <- check_binds(mounts, caps),
         {:ok, name} <- ensure_container(mounts, caps) do
      {:ok, %{command: CommandLine.exec_line(name, mounts, caps, script, nil), cd: nil}}
    end
  end

  @doc """
  The same command, with the job's output also written to `log_path` **inside
  the container**.

  A background job's log is a file under the agent's scratch directory, which is
  the container's own `/tmp`: nothing on the host can write it, so the command
  has to. `set -o pipefail` keeps the exit code the command's rather than
  `tee`'s. The container is not touched here: `command/3` has already ensured it.
  """
  @spec job_spec(Mounts.t(), map() | nil, String.t(), String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def job_spec(mounts, caps, script, log_path) do
    caps = caps || Sandbox.default_caps()

    # A background job is built by `Nest.Sandbox.ShellJobs.Launcher` and never
    # goes through `command/3`, so without this it would be the one path that
    # skipped the refusals below — for a `mode = "tmp"` `.nest` mount *and* for a
    # `caps.fs.write` path the container cannot bind. Both would then reach the
    # inner bwrap and fail there as `Can't bind mount …: No such file or
    # directory`, which tells the agent nothing it can act on.
    with :ok <- check_binds(mounts, caps),
         {:ok, name} <- container_name(mounts) do
      {:ok, %{command: CommandLine.exec_line(name, mounts, caps, script, log_path), cd: nil}}
    end
  end

  @doc """
  The host staging directory: a stable directory per space and installation
  (`Nest.Sandbox.Paths.docker_stage_dir/1`), which the container is given at
  `#{Nest.Sandbox.Paths.docker_stage_dir_sandbox()}` read-only. A call that
  belongs to no space cannot run at all (`command/3` refuses it), so it gets the
  no-bind spelling rather than a directory named after a space it does not have.
  """
  @spec stage_dir(Mounts.t()) :: String.t()
  def stage_dir(%Mounts{space_id: id}) when is_integer(id), do: Paths.docker_stage_dir(id)
  def stage_dir(_mounts), do: Paths.stage_dir(nil)
  @doc "The staging directory's spelling inside the container."
  @spec stage_dir_sandbox(Mounts.t()) :: String.t()
  def stage_dir_sandbox(_mounts), do: Paths.docker_stage_dir_sandbox()

  @doc "The name this backend is logged under."
  @spec display_name(Mounts.t()) :: String.t()
  def display_name(_mounts), do: "docker exec"

  @doc """
  Classify stderr: the daemon's own failures are a broken sandbox
  (`:sandbox_setup_failed`, which the file tools render as "the sandbox failed to
  start; this is a Nest configuration problem"); everything else is the command's
  own, from the shared errno table.
  """
  @spec classify(Mounts.t(), String.t()) :: atom()
  def classify(_mounts, stderr) do
    if docker_failure?(stderr), do: :sandbox_setup_failed, else: Failure.classify_errno(stderr)
  end

  defp docker_failure?(stderr), do: Enum.any?(@docker_markers, &String.contains?(stderr, &1))

  # A `caps.fs.write` path outside the symbolic entries and the `.nest` mounts
  # names a *host* path the container does not have, so the sandbox inside cannot
  # bind it. Refuse by name rather than let it fail as `bwrap: Can't bind mount
  # …: No such file or directory`, an ordinary `:enoent`.
  defp check_binds(mounts, caps) do
    with :ok <- check_unbound_writes(mounts, caps) do
      check_project_mounts(mounts, caps)
    end
  end

  defp check_unbound_writes(mounts, caps) do
    case Binds.unbound_write_paths(caps, mounts) do
      [] ->
        :ok

      paths ->
        {:error,
         "The docker backend cannot bind #{Enum.join(paths, ", ")}: its binds are " <>
           "the container's, which does not have that path. Declare it as a " <>
           "[[mount]] in .nest instead."}
    end
  end

  # A `mode = "tmp"` mount is backed by a directory Nest makes, and its source is
  # derived from the scratch root — which on this backend names a path *inside the
  # container*, so the source that comes out is a host path. Refuse it by name and
  # say the way out, rather than let the daemon create a root-owned host directory
  # that the whole space shares. See `Binds.non_host_project_mounts/2`.
  defp check_project_mounts(mounts, caps) do
    case Binds.non_host_project_mounts(caps, mounts) do
      [] ->
        :ok

      dests ->
        {:error,
         "The docker backend cannot back #{Enum.join(dests, ", ")}: a " <>
           "`mode = \"tmp\"` .nest mount needs a directory Nest makes, and on a " <>
           "docker space that directory would be a host path shared by every agent " <>
           "in the space. Use `mode = \"rw\"` for that mount."}
    end
  end

  # ---- lifecycle ----

  @doc """
  Ensure this call's container exists, is running, and was built for this call's
  layout, and return its name.

  `opts`: `:runner` (`fn argv -> {output, exit_code} end`, defaulting to
  `system/1` — the injectable seam the lifecycle is tested through) and
  `:devices` (the host device paths, defaulting to
  `Nest.Hardware.hpu_device_paths/0`). Returns `{:error, reason}` — never a
  half-built sandbox — when the space is unknown, the image cannot be built, the
  container cannot be started, or a container built for another layout will not
  go away.
  """
  @spec ensure_container(Mounts.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def ensure_container(mounts, caps, opts \\ []) do
    runner = Keyword.get_lazy(opts, :runner, &default_runner/0)
    devices = Keyword.get_lazy(opts, :devices, &Hardware.hpu_device_paths/0)
    caps = caps || Sandbox.default_caps()

    with {:ok, name} <- container_name(mounts) do
      use_container(mounts, caps, devices, name, runner)
    end
  end

  # The container that is there, if any, decides: a matching layout is reused or
  # started, and anything else has to be replaced (see `replace/6`).
  defp use_container(mounts, caps, devices, name, runner) do
    layout = layout(mounts, caps, devices)

    case inspect_container(name, runner) do
      :missing -> create(mounts, caps, devices, name, layout, runner)
      {:ok, %{layout: ^layout, status: :running}} -> {:ok, name}
      {:ok, %{layout: ^layout}} -> start(name, runner)
      {:ok, _stale} -> replace(mounts, caps, devices, name, layout, runner)
    end
  end

  @doc """
  Remove every container this space's agents ran in, for an archive or a delete
  (or a network change). Archiving is reversible — the containers are recreated
  lazily after an unarchive — so this is cleanup rather than part of either
  operation's success: a daemon failure is logged and the caller carries on.
  """
  @spec remove_space(integer(), keyword()) :: :ok
  def remove_space(space_id, opts \\ []) do
    runner = Keyword.get_lazy(opts, :runner, &default_runner/0)

    case list_containers(space_id, runner) do
      {:ok, names} -> Enum.each(names, &remove_container(&1, runner))
      {:error, reason} -> Logger.warning("#{@log_tag} #{reason}")
    end

    remove_stage_dir(space_id)
    :ok
  end

  # The staging directory is the one thing this backend leaves on the host, and it
  # is per space, so an archive, a delete or a network change takes it along. It is
  # recreated lazily by `Nest.Tools.ShellCmd.Transcript.stage/2`.
  #
  # `File.rm_rf` on a path derived from an id is the shape `SMELLS.md` warns about,
  # so the guard is explicit: the directory has to be a `nest-docker-…` one, which
  # is the only thing this module ever creates there, and anything else is refused
  # and logged rather than removed.
  defp remove_stage_dir(space_id) do
    parent = space_id |> Paths.docker_stage_dir() |> Path.dirname()

    if String.starts_with?(Path.basename(parent), "nest-docker-") do
      case File.rm_rf(parent) do
        {:ok, _paths} ->
          :ok

        {:error, reason, path} ->
          Logger.warning("#{@log_tag} could not remove #{path}: #{inspect(reason)}")
      end
    else
      Logger.warning("#{@log_tag} refusing to remove #{parent}: not a docker staging directory")
      :error
    end
  end

  defp list_containers(space_id, runner) do
    args = [
      "ps",
      "-a",
      "--filter",
      "name=#{container_prefix(space_id)}",
      "--format",
      "{{.Names}}"
    ]

    case runner.(args) do
      {output, 0} ->
        # `--filter name=` is a substring match, so the filter narrows the list
        # and the pattern decides: only this space's own containers, whose names
        # are exactly `<prefix><installation>`.
        {:ok, output |> String.split("\n", trim: true) |> Enum.filter(&this_space?(&1, space_id))}

      {output, code} ->
        {:error,
         "could not list containers for space #{space_id} (exit #{code}): #{trim(output)}"}
    end
  end

  # Whether `name` is one of this space's containers. The prefix carries a
  # trailing `-`, so another space's container (`nest-space-78-…` against space
  # 7's `nest-space-7-`) is not a prefix match, and what follows the prefix has
  # to be a name segment rather than whatever the substring filter happened to
  # match.
  defp this_space?(name, space_id) do
    case String.replace_prefix(name, container_prefix(space_id), "") do
      ^name -> false
      "" -> false
      segment -> Regex.match?(@segment_format, segment)
    end
  end

  defp remove_container(name, runner) do
    case runner.(["rm", "-f", name]) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Logger.warning(
          "#{@log_tag} could not remove container #{name} (exit #{code}): #{trim(output)}"
        )

        {:error, failure("docker rm -f", name, output, code)}
    end
  end

  defp inspect_container(name, runner) do
    case runner.(["inspect", "--format", @inspect_format, name]) do
      {output, 0} -> parse_inspect(output)
      {_output, _code} -> :missing
    end
  end

  defp parse_inspect(output) do
    case output |> String.trim() |> String.split("|", parts: 2) do
      [status, layout] -> {:ok, %{status: status_of(status), layout: String.trim(layout)}}
      _other -> :missing
    end
  end

  # `exited`, `created` and `paused` all mean "there is a container and it is not
  # serving": `docker start` brings it back with the binds it was created with,
  # which is why only a container whose layout matches may be started.
  defp status_of("running"), do: :running
  defp status_of(_other), do: :stopped

  defp start(name, runner) do
    case runner.(["start", name]) do
      {_output, 0} -> {:ok, name}
      {output, code} -> {:error, failure("docker start", name, output, code)}
    end
  end

  # The container is there but was built for a different layout, and a
  # container's mounts, image and network are fixed at creation: it has to be
  # replaced. A removal that fails is an error rather than something to adopt —
  # adopting would run this call in the old environment.
  defp replace(mounts, caps, devices, name, layout, runner) do
    with :ok <- remove_container(name, runner) do
      create(mounts, caps, devices, name, layout, runner)
    end
  end

  defp create(mounts, caps, devices, name, layout, runner) do
    with {:ok, image} <- ensure_image(caps, runner) do
      run_container(name, mounts, caps, devices, image, layout, runner)
    end
  end

  defp run_container(name, mounts, caps, devices, image, layout, runner) do
    args = run_args(mounts, caps, image, devices, layout)

    case runner.(["run", "-d", "--name", name | args]) do
      {_output, 0} -> {:ok, name}
      {output, code} -> adopt_or_fail(name, output, code, runner)
    end
  end

  # Two agents can resolve to the same container and race to create it. A refused
  # `run` because the name is taken is "someone else got there first" — and they
  # built it for the same layout, since the name is a function of the space — so
  # re-inspect and use whatever is there.
  defp adopt_or_fail(name, output, code, runner) do
    case inspect_container(name, runner) do
      :missing -> {:error, failure("docker run", name, output, code)}
      {:ok, %{status: :running}} -> {:ok, name}
      {:ok, _stopped} -> start(name, runner)
    end
  end

  defp ensure_image(caps, runner) do
    tag = image_tag(caps)

    case runner.(["image", "inspect", tag]) do
      {_output, 0} -> {:ok, tag}
      {_output, _code} -> build_image(tag, caps, runner)
    end
  end

  defp build_image(tag, caps, runner) do
    context = build_context(caps)

    try do
      case runner.(["build", "-t", tag, context]) do
        {_output, 0} ->
          {:ok, tag}

        {output, code} ->
          # The same race as `run_container/7`: a concurrent build of this tag
          # means the image exists after all.
          case runner.(["image", "inspect", tag]) do
            {_output, 0} -> {:ok, tag}
            {_output, _code} -> {:error, failure("docker build", tag, output, code)}
          end
      end
    after
      remove_build_context(context)
    end
  end

  # The Dockerfile is written as the build context's own `Dockerfile`, so the
  # build needs no stdin (the runner takes argv only) and nothing else is sent to
  # the daemon. The directory is the context, so it is removed afterwards.
  defp build_context(caps) do
    dir =
      Path.join(System.tmp_dir!(), "#{@build_dir_prefix}#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Dockerfile"), dockerfile(caps))
    dir
  end

  defp remove_build_context(dir) do
    # Guarded by the identifying string, as SMELLS.md requires of any `rm_rf`.
    if String.contains?(dir, @build_dir_prefix), do: File.rm_rf(dir)
    :ok
  end

  # ---- what the container is ----

  @doc """
  The container's name: `nest-space-<space_id>-<installation>`.

  `{:error, reason}` when the mounts carry no space: a container shared by
  accident is worse than a clear refusal, and only a caller that built its value
  without one can hit this.

  Nothing per-BEAM is in it, which is what lets the container survive a restart
  and what makes two agents in one space share it; `Nest.Sandbox.Installation` is
  the last segment so two installations sharing a space id do not adopt each
  other's container. A name that cannot encode the layout means the layout has to
  be checked instead — see `layout/3`.
  """
  @spec container_name(Mounts.t()) :: {:ok, String.t()} | {:error, String.t()}
  def container_name(mounts) do
    case Mounts.space_id(mounts) do
      id when is_integer(id) -> {:ok, "#{container_prefix(id)}#{Installation.segment()}"}
      _other -> {:error, "A docker sandbox needs the space it belongs to"}
    end
  end

  @doc "The prefix every container of `space_id` starts with."
  @spec container_prefix(integer()) :: String.t()
  def container_prefix(space_id), do: "#{@name_prefix}#{space_id}-"

  @doc """
  Everything a container's layout depends on, as the label it carries: the binds,
  the network, the devices and the image. A container is created with all four
  fixed, so a change to any of them has to be a *different* container; the name
  cannot say so (it is stable across restarts by design), so this does, and
  `ensure_container/3` compares it on every call.

  Deliberately excludes anything per-call: two agents in one space with different
  modes resolve to the same container, which is the point of the container
  binding the superset.
  """
  @spec layout(Mounts.t(), map() | nil, [String.t()]) :: String.t()
  def layout(mounts, caps, devices) do
    caps = caps || Sandbox.default_caps()

    hash(
      {net?(caps), container_binds(mounts), devices, image_tag(caps)},
      @layout_bytes
    )
  end

  @doc """
  The binds the container makes, as `{source, dest, mode}` with `source` a host
  path: the superset a space can need, plus the workspace at the path the caller
  named when that is not the path the shared bind list uses. See
  `Nest.Sandbox.Binds.container_specs/1`.
  """
  @spec container_binds(Mounts.t()) :: [Binds.spec()]
  def container_binds(mounts) do
    Binds.container_specs(mounts) ++ CommandLine.workspace_spelling(mounts, :rw)
  end

  @doc """
  The tag of the image derived for `caps`' package set: keyed on the base
  reference and the sorted package list, so a `.nest` that changes its packages
  is a different tag and rebuilds on next use.
  """
  @spec image_tag(map() | nil) :: String.t()
  def image_tag(caps), do: @image_prefix <> hash({@base_image, packages(caps)}, @image_hash_bytes)

  @doc """
  The generated Dockerfile for `caps`' package set: one `RUN`, so the layer is a
  single apt transaction and the lists are not left behind.
  """
  @spec dockerfile(map() | nil) :: String.t()
  def dockerfile(caps) do
    """
    FROM #{@base_image}
    RUN apt-get update \\
     && apt-get install -y --no-install-recommends #{Enum.join(packages(caps), " ")} \\
     && rm -rf /var/lib/apt/lists/*
    """
  end

  @doc """
  The `docker run` arguments after `-d --name <name>`: the flags bwrap needs, the
  network, the layout label, the binds, the devices, the working directory, the
  image, and its keep-alive.
  """
  @spec run_args(Mounts.t(), map() | nil, String.t(), [String.t()]) :: [String.t()]
  def run_args(mounts, caps, image, devices) do
    run_args(mounts, caps, image, devices, layout(mounts, caps, devices))
  end

  @doc "`run_args/4` with the layout already computed, so a caller that has it does not hash the bind list again."
  @spec run_args(Mounts.t(), map() | nil, String.t(), [String.t()], String.t()) :: [String.t()]
  def run_args(mounts, caps, image, devices, layout) do
    @container_flags ++
      net_args(caps) ++
      ["--label", "#{@layout_label}=#{layout}"] ++
      bind_args(mounts) ++
      Enum.flat_map(devices, &["--device", &1]) ++
      workdir_args(mounts) ++
      [image, "sleep", "infinity"]
  end

  # The container's binds, plus the staging directory the BEAM stages command
  # transcripts in — read-only, because the agent can write `/tmp` and a writable
  # staging bind would be a host write path.
  defp bind_args(mounts) do
    (container_binds(mounts) ++ staging_bind(mounts))
    |> Enum.map(fn {source, dest, mode} -> ["-v", "#{source}:#{dest}:#{mode_name(mode)}"] end)
    |> List.flatten()
  end

  defp staging_bind(mounts) do
    [{stage_dir(mounts), Paths.docker_stage_dir_sandbox(), :ro}]
  end

  defp mode_name(:rw), do: "rw"
  defp mode_name(:ro), do: "ro"

  defp net_args(caps), do: if(net?(caps), do: [], else: ["--network", "none"])

  defp workdir_args(%Mounts{workspace: nil}), do: []
  defp workdir_args(%Mounts{workspace: workspace}), do: ["-w", workspace]

  @doc """
  The packages the derived image installs: the base set plus the project's.
  """
  @spec packages(map() | nil) :: [String.t()]
  def packages(caps),
    do: Enum.sort(Enum.uniq(@base_packages ++ ProjectConfig.sandbox_packages(caps)))

  defp net?(caps), do: get_in(caps, ["net"]) == true

  # ---- the daemon ----

  @doc """
  The default runner: `docker <argv>` on the host, with stderr folded into the
  output so a failure message is what the caller reports.

  The one line of this module the suite does not execute — `config/test.exs`
  installs an inert runner, because the suite must never talk to a daemon.
  """
  @spec system([String.t()]) :: {String.t(), non_neg_integer()}
  def system(argv), do: System.cmd("docker", argv, stderr_to_stdout: true)

  @doc """
  Run `argv` against the daemon with the configured runner, returning
  `{output, exit_code}`.

  `opts` takes the same `:runner` as `ensure_container/3` — the injectable seam
  the callers that have no lifecycle of their own are tested through.

  The lifecycle goes through the `:runner` option instead; this is for the one
  caller with no lifecycle of its own — a background job's log lives in the
  container, so reading or removing it is a `docker exec`
  (`Nest.Sandbox.ShellJobs.JobLog`). Going through the configured runner keeps
  that on the same seam, so the suite still never talks to a daemon.
  """
  @spec run([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(argv, opts \\ []) do
    runner = Keyword.get_lazy(opts, :runner, &default_runner/0)
    runner.(argv)
  end

  defp default_runner, do: Application.get_env(:nest, :docker_runner, &system/1)

  defp hash(term, bytes) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
    |> binary_part(0, bytes * 2)
  end

  # A failed build or run prints the daemon's own diagnosis, which can be long:
  # the agent gets the beginning of it, which is where the cause is.
  defp failure(op, subject, output, code) do
    "#{op} failed for #{subject} (exit #{code}): #{trim(output)}"
  end

  defp trim(output) do
    text = output |> to_string() |> String.trim()

    if String.length(text) > @message_limit do
      String.slice(text, 0, @message_limit) <> "…"
    else
      text
    end
  end
end
