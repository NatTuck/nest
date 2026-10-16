defmodule Nest.Sandbox.Backend.Docker do
  # The image's identity, declared before the `@moduledoc` because the moduledoc
  # interpolates two of them.
  @base_image "debian:trixie-slim"
  @base_packages ~w(bash coreutils file git curl ca-certificates procps ripgrep)

  @moduledoc """
  The docker backend: commands run inside a container the space shares.

  ## What the container exposes

  Its root filesystem is the derived image, so the host's `/` is not visible at
  all. The container sees the workspace, the space scratch dir at `/tmp`, the
  explicit `.nest` mounts, and nothing else — which means `caps.fs.read` is
  **deliberately ignored**: the image *is* the read set. That makes this backend
  *stricter* than bwrap, not looser, and it is why a project that needs a host
  path read-only has to declare it as a `.nest` mount. `/dev` is the image's own
  (the equivalent of bwrap's fresh devtmpfs); only HPU device paths are passed
  through, with `--device`.

  `caps.net` and the write flags *are* honoured: `--network none` when the mode
  denies the network, and `rw`/`ro` per bind from `caps.fs.write`.

  ## One container per `(space, caps signature)`

  Caps are per *agent* — they come from the vocation's mode — and one container's
  binds and network namespace cannot vary per `docker exec`. Binding the union of
  every mode's caps would silently hand a read-only mode a writable workspace,
  which is exactly the silent capability weakening this codebase forbids. So each
  distinct caps signature gets its own container, named
  `nest-space-<space_id>-<BEAM pid>-<hash>`:

  * the hash covers exactly what the container's layout depends on — `net`, the
    bind list with its rw/ro flags, the workspace path, and the HPU device paths;
  * agents that resolve to the same signature share a container, and in practice
    a space has one or two.

  The *image* is per space rather than per signature (it comes from the space's
  `.nest`), so the two names are keyed differently on purpose.

  The container is created lazily on first use, `docker start`ed when it exists
  but is stopped, and removed when the space is archived or deleted
  (`Nest.Spaces` → `Nest.Sandbox.Backend.remove_space/3`).

  ## A container does *not* outlive its BEAM

  The layout includes the scratch bind, whose source is the space scratch dir —
  `/tmp/nest-<BEAM pid>/space-<id>`. A restart is therefore a different layout, and
  it gets a different container, on purpose: a container's mounts are fixed when
  it is created, so reusing one would leave its `/tmp` pointing at the *previous*
  BEAM's scratch directory, a directory this BEAM never writes to, which would
  make every staged script unreadable inside the container.

  The superseded container does not leak: the next create for that space sweeps
  every container of the space whose BEAM is gone (`sweep_dead_beams/2`), which is
  what the pid segment in the name is for. A *live* BEAM's container is left
  alone — two BEAMs can share a space id — and so is any name that is not this
  space's exact format.

  So "one container for the life of the space" holds within a BEAM, not across
  restarts. Making it hold across restarts would mean a scratch root that does not
  embed the BEAM's pid, i.e. a change to `Nest.Agents.Agent.TmpSpace.space_dir/2`,
  which is a deliberate design and out of scope here.

  ## The derived image

  `#{@base_image}` plus the packages a usable shell needs and the slim base lacks
  (`#{Enum.join(@base_packages, " ")}`), plus whatever the project's `.nest`
  `[sandbox] packages` adds. The tag is keyed on the base reference and the
  package set, so a changed set is a different tag and rebuilds automatically,
  and a failed build surfaces as a clear error rather than a half-built sandbox.

  The project toolchain (Elixir, Node, Rust) is deliberately **not** in the base:
  a project that needs it declares it in `.nest`.

  ## Testing

  Everything that decides *what* to run is pure and asserted exactly
  (`container_name/4`, `image_tag/1`, `dockerfile/1`, `bind_specs/2`,
  `run_args/4`). The lifecycle takes an injectable `:runner` (`fn argv ->
  {output, exit_code} end`) so create / reuse / start-if-stopped / remove are all
  tested against a fake; `system/1`, the `System.cmd` default, is the only line
  the suite does not execute (see `config/test.exs`).
  """

  require Logger

  @name_prefix "nest-space-"
  @image_prefix "nest-sandbox:"
  @build_dir_prefix "nest-docker-build-"

  # 4 bytes of hex for the layout hash and 6 for the image: both are read by a
  # human in `docker ps` output, and neither has a collision worth worrying about
  # (a collision needs two different layouts of one space to agree on 32 bits).
  @name_hash_bytes 4
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

  alias Nest.FSPath
  alias Nest.Hardware
  alias Nest.ProjectConfig
  alias Nest.Sandbox
  alias Nest.Sandbox.{Failure, Mounts, Paths}
  alias Nest.Tools.ShellEscape

  # ---- the backend contract ----

  @doc """
  `docker exec -i <container> /bin/bash '<script>'`.

  `-i` is required: without it the exec's stdin is closed and a `shell-cmd`
  with `:stdin` (a `file-write`, an `file-edit`) would silently write nothing.

  `cd` is `nil`: the container was started with `-w`, so docker sets the working
  directory itself.
  """
  @spec command(Mounts.t(), map() | nil, String.t()) ::
          {:ok, Nest.Sandbox.Backend.spec()} | {:error, String.t()}
  def command(mounts, caps, script) do
    # The staged script has to be reachable *inside* the container, and the only
    # bind that can make it so is the scratch bind at `/tmp`. Without it the
    # staging directory is the host's own `<tmp>/.nest-cmds`, which bwrap reaches
    # through its read-only root bind and this backend cannot reach at all: the
    # container's `/tmp` is its own, so bash would exit 127 and the failure would
    # be classified `:enoent` — an ordinary "not found" that is not logged and
    # that a caller like the system prompt would swallow. Refuse loudly instead.
    if Mounts.scratch(mounts) do
      with {:ok, name} <- ensure_container(mounts, caps) do
        {:ok,
         %{
           command: "docker exec -i #{name} /bin/bash #{ShellEscape.escape(script)}",
           cd: nil
         }}
      end
    else
      {:error, "A docker sandbox needs the agent's scratch bind to stage its script"}
    end
  end

  @doc """
  The host staging directory: the space scratch dir's own `.cmds`, reached
  inside the container through the `<space_dir>:/tmp` bind as `/tmp/.cmds`.

  `Mounts.scratch` is `<space_dir>/<agent>`, so `Paths.scratch_root/1` derives
  `<space_dir>` and does not refuse it.
  """
  @spec stage_dir(Mounts.t()) :: String.t()
  def stage_dir(mounts), do: Paths.stage_dir(Mounts.scratch(mounts))

  @doc "The staging directory's spelling inside the container."
  @spec stage_dir_sandbox(Mounts.t()) :: String.t()
  def stage_dir_sandbox(mounts), do: Paths.stage_dir_sandbox(Mounts.scratch(mounts))

  @doc "The name this backend is logged under."
  @spec display_name(Mounts.t()) :: String.t()
  def display_name(_mounts), do: "docker exec"

  @doc """
  Classify stderr: the daemon's own failures are a broken sandbox
  (`:sandbox_setup_failed`, which the file tools already render as "the sandbox
  failed to start; this is a Nest configuration problem"), and everything else is
  the command's own, classified from the shared errno table.
  """
  @spec classify(Mounts.t(), String.t()) :: atom()
  def classify(_mounts, stderr) do
    if docker_failure?(stderr), do: :sandbox_setup_failed, else: Failure.classify_errno(stderr)
  end

  defp docker_failure?(stderr), do: Enum.any?(@docker_markers, &String.contains?(stderr, &1))

  # ---- lifecycle ----

  @doc """
  Ensure this call's container exists and is running, and return its name.

  `opts`:

    * `:runner` — `fn argv -> {output, exit_code} end`, defaulting to
      `system/1`. The injectable seam the lifecycle is tested through.
    * `:devices` — the host device paths to pass through, defaulting to
      `Nest.Hardware.hpu_device_paths/0`. Threaded explicitly for the same
      reason `Nest.Sandbox.build/4` threads it: so a test can exercise both
      branches without mutating global config.

  Returns `{:error, reason}` — never a half-built sandbox — when the space is
  unknown, the image cannot be built, or the container cannot be started.
  """
  @spec ensure_container(Mounts.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def ensure_container(mounts, caps, opts \\ []) do
    runner = Keyword.get_lazy(opts, :runner, &default_runner/0)
    devices = Keyword.get_lazy(opts, :devices, &Hardware.hpu_device_paths/0)

    with {:ok, name} <- container_name(mounts, caps, devices) do
      case status(name, runner) do
        :running -> {:ok, name}
        :stopped -> start(name, runner)
        :missing -> create(mounts, caps, devices, name, runner)
      end
    end
  end

  @doc """
  Remove every container this space's agents ran in.

  Called by `Nest.Spaces` when a space is archived or deleted. Archiving is
  reversible — the containers are simply recreated lazily after an unarchive — so
  this is cleanup rather than part of either operation's success: a daemon
  failure is logged and the caller carries on.
  """
  @spec remove_space(integer(), keyword()) :: :ok
  def remove_space(space_id, opts \\ []) do
    runner = Keyword.get_lazy(opts, :runner, &default_runner/0)

    case list_containers(space_id, runner) do
      {:ok, names} -> Enum.each(names, &remove_container(&1, runner))
      {:error, reason} -> Logger.warning("#{@log_tag} #{reason}")
    end

    :ok
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
        # are exactly `<prefix><pid>-<8 hex>`.
        {:ok, output |> String.split("\n", trim: true) |> Enum.filter(&this_space?(&1, space_id))}

      {output, code} ->
        {:error,
         "could not list containers for space #{space_id} (exit #{code}): #{trim(output)}"}
    end
  end

  defp this_space?(name, space_id), do: beam_pid_of(name, space_id) != :error

  # The BEAM pid segment of a container name that is exactly this space's format,
  # or `:error` for anything else — another space's container, an older naming
  # scheme, or a name someone made up. Only a name this matches is ever removed.
  defp beam_pid_of(name, space_id) do
    case Regex.run(container_pattern(space_id), name, capture: :all_but_first) do
      [os_pid] -> {:ok, os_pid}
      _other -> :error
    end
  end

  defp container_pattern(space_id) do
    ~r/\A#{Regex.escape(container_prefix(space_id))}(\d+)-[0-9a-f]{#{@name_hash_bytes * 2}}\z/
  end

  defp remove_container(name, runner) do
    case runner.(["rm", "-f", name]) do
      {_output, 0} ->
        :ok

      {output, code} ->
        Logger.warning(
          "#{@log_tag} could not remove container #{name} (exit #{code}): #{trim(output)}"
        )
    end
  end

  defp status(name, runner) do
    case runner.(["inspect", "--format", "{{.State.Status}}", name]) do
      {output, 0} -> status_of(String.trim(output))
      {_output, _code} -> :missing
    end
  end

  # `exited`, `created` and `paused` all mean "there is a container and it is not
  # serving": `docker start` brings it back *with the binds it was created with*,
  # which is why only the BEAM whose scratch root those binds name can use it —
  # see `sweep_dead_beams/2`.
  defp status_of("running"), do: :running
  defp status_of(_other), do: :stopped

  defp start(name, runner) do
    case runner.(["start", name]) do
      {_output, 0} -> {:ok, name}
      {output, code} -> {:error, failure("docker start", name, output, code)}
    end
  end

  defp create(mounts, caps, devices, name, runner) do
    # Reclaim this space's containers whose BEAM is gone, before making another
    # one. See `sweep_dead_beams/2` for why they are there at all.
    sweep_dead_beams(Mounts.space_id(mounts), runner)

    with {:ok, image} <- ensure_image(caps, runner) do
      run_container(name, mounts, caps, devices, image, runner)
    end
  end

  # Remove this space's containers left by a BEAM that is no longer running.
  #
  # The scratch root is part of the layout, and its path embeds the BEAM's OS pid
  # (`Nest.Agents.Agent.TmpSpace`), so a restart is a *different* layout and gets
  # a fresh container: a container's mounts are fixed when it is created, and
  # reusing one would leave its `/tmp` pointing at the previous BEAM's scratch
  # directory, which this BEAM never writes to. The superseded container would
  # otherwise sit there — running `sleep infinity`, holding nothing useful —
  # until the space is archived or deleted, which on a dev loop means one per
  # restart. This is the only place that reclaims them.
  #
  # Liveness is `/proc/<pid>`, which is Linux-specific — fine, because
  # `Nest.Application.check_system_dependencies!/0` already requires bwrap, i.e.
  # Linux. A *live* pid is deliberately kept: two BEAMs can share a space id (a
  # dev BEAM and a prod BEAM on one daemon, same serial), and neither may remove
  # the other's container. Only a name in this space's own format is ever a
  # candidate, so another space's containers and anything unrecognised are left
  # alone.
  defp sweep_dead_beams(space_id, runner) do
    case list_containers(space_id, runner) do
      {:ok, names} ->
        Enum.each(names, &sweep_one(&1, space_id, runner))

      {:error, reason} ->
        # Opportunistic cleanup: the `docker run` this precedes reports the same
        # daemon failure properly, so this is a debugging line rather than a
        # second report of it.
        Logger.debug("#{@log_tag} #{reason}")
    end

    :ok
  end

  defp sweep_one(name, space_id, runner) do
    with {:ok, os_pid} <- beam_pid_of(name, space_id),
         true <- os_pid != beam_pid() and not File.exists?("/proc/#{os_pid}") do
      Logger.info("#{@log_tag} removing #{name}: BEAM #{os_pid} is gone")
      remove_container(name, runner)
    else
      # This BEAM's own container, a live BEAM's, or a name that is not this
      # space's format: not ours to remove.
      _kept -> :ok
    end
  end

  defp run_container(name, mounts, caps, devices, image, runner) do
    case runner.(["run", "-d", "--name", name | run_args(mounts, caps, image, devices)]) do
      {_output, 0} -> {:ok, name}
      {output, code} -> adopt_or_fail(name, output, code, runner)
    end
  end

  # Two agents can resolve to the same container and race to create it. A refused
  # `run` because the name is taken is "someone else got there first", not a
  # failure: re-inspect and use whatever is there.
  defp adopt_or_fail(name, output, code, runner) do
    case status(name, runner) do
      :missing -> {:error, failure("docker run", name, output, code)}
      :running -> {:ok, name}
      :stopped -> start(name, runner)
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
          # The same race as `create/6`: a concurrent build of this tag means the
          # image exists after all.
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
  The container's name: `nest-space-<space_id>-<BEAM pid>-<hash of the layout>`.

  `{:error, reason}` when the mounts carry no space: a container shared by
  accident is worse than a clear refusal, and only a caller that built its value
  without one can hit this.

  The BEAM's OS pid is a segment because the layout contains the scratch root,
  whose path embeds it — a restart is a different layout, and its container has
  to be a different container (see `sweep_dead_beams/2`). It is also what lets
  the sweep tell a dead BEAM's container from a live one's.

  `os_pid` is threaded for the tests, which have one BEAM and could otherwise not
  exercise two.
  """
  @spec container_name(Mounts.t(), map() | nil, [String.t()], String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def container_name(mounts, caps, devices, os_pid \\ nil) do
    case Mounts.space_id(mounts) do
      id when is_integer(id) ->
        # The image is part of the signature because it *is* the container's root
        # filesystem: a `.nest` that changes its `[sandbox] packages` changes the
        # image, and a container reused across that change would run the old one
        # (`ensure_image/2` runs only on the create path).
        signature = {
          net?(caps),
          bind_specs(mounts, caps),
          Mounts.workspace(mounts),
          devices,
          image_tag(caps)
        }

        {:ok, name(id, os_pid || beam_pid(), hash(signature, @name_hash_bytes))}

      _other ->
        {:error, "A docker sandbox needs the space it belongs to"}
    end
  end

  @doc "The prefix every container of `space_id` starts with."
  @spec container_prefix(integer()) :: String.t()
  def container_prefix(space_id), do: "#{@name_prefix}#{space_id}-"

  defp name(space_id, os_pid, hash), do: "#{container_prefix(space_id)}#{os_pid}-#{hash}"

  # The BEAM's OS pid, spelled explicitly so an alias for `Nest.Messages.System`
  # (as several agent modules have) could never change what this means.
  defp beam_pid, do: Elixir.System.pid()

  @doc """
  The tag of the image derived for `caps`' package set.

  Keyed on the base reference and the (sorted) package list, so a `.nest` that
  changes its packages is a different tag and rebuilds on next use.
  """
  @spec image_tag(map() | nil) :: String.t()
  def image_tag(caps), do: @image_prefix <> hash({@base_image, packages(caps)}, @image_hash_bytes)

  @doc """
  The generated Dockerfile for `caps`' package set.

  One `RUN`, so the layer is a single apt transaction and the lists are not left
  behind; `--no-install-recommends` keeps the image close to what was asked for.
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
  The `docker run` arguments after `-d --name <name>`: the network flag, the
  binds, the devices, the working directory, the image, and its keep-alive.
  """
  @spec run_args(Mounts.t(), map() | nil, String.t(), [String.t()]) :: [String.t()]
  def run_args(mounts, caps, image, devices) do
    net_args(caps) ++
      bind_args(mounts, caps) ++
      Enum.flat_map(devices, &["--device", &1]) ++
      workdir_args(mounts) ++
      [image, "sleep", "infinity"]
  end

  @doc """
  The binds this call makes, as `{source, dest, mode}` with `mode` `"rw"`/`"ro"`,
  in the order they must be applied.

  This mirrors `Nest.Sandbox.build/2`'s derivation of the same set — the workspace
  bind, the extra `caps.fs.write` paths, the scratch bind at `/tmp`, the `.nest`
  project mounts, and the read-only `.nest` mask — because both backends must
  bind the *same* things; only the spelling differs (`--bind`/`--ro-bind` there,
  `-v` here). The difference is the readable roots: bwrap binds the host's `/`
  read-only and docker has no such bind, which is what
  `Nest.Sandbox.Backend.DockerTest` pins as the one intended divergence.
  """
  @spec bind_specs(Mounts.t(), map() | nil) :: [{String.t(), String.t(), String.t()}]
  def bind_specs(mounts, caps) do
    caps = normalize_caps(caps)
    workspace = Mounts.workspace(mounts)
    writes = write_list(caps)

    workspace_bind(workspace, writes) ++
      extra_write_binds(caps, workspace) ++
      scratch_bind(mounts, writes) ++
      project_binds(caps) ++
      protected_binds(caps)
  end

  defp workspace_bind(workspace, writes) when is_binary(workspace) do
    [{workspace, workspace, write_mode(":workspace" in writes)}]
  end

  defp workspace_bind(_workspace, _writes), do: []

  defp scratch_bind(%Mounts{scratch: nil}, _writes), do: []

  defp scratch_bind(%Mounts{scratch: scratch}, writes) do
    [{Paths.scratch_root(scratch), Paths.sandbox_root(), write_mode("/tmp" in writes)}]
  end

  defp extra_write_binds(caps, workspace) do
    bound = already_bound(caps, workspace)

    caps
    |> write_list()
    |> Enum.reject(&(&1 in bound))
    |> Enum.map(&FSPath.canonical/1)
    |> Enum.uniq()
    |> Enum.map(&{&1, &1, "rw"})
  end

  # The paths a dedicated step already binds.
  defp already_bound(caps, workspace) do
    [":workspace", "/tmp"] ++
      if(is_binary(workspace), do: [workspace, FSPath.canonical(workspace)], else: []) ++
      Enum.map(project_list(caps), & &1["dest"]) ++
      Enum.map(protected_list(caps), & &1["path"])
  end

  defp project_binds(caps) do
    caps
    |> project_list()
    |> Enum.filter(&is_binary(&1["source"]))
    |> Enum.map(fn %{"dest" => dest, "source" => source} -> {source, dest, "rw"} end)
  end

  defp protected_binds(caps) do
    caps
    |> protected_list()
    |> Enum.flat_map(fn %{"path" => path, "source" => source} -> [{source, path, "ro"}] end)
  end

  defp write_mode(true), do: "rw"
  defp write_mode(false), do: "ro"

  defp bind_args(mounts, caps) do
    mounts
    |> bind_specs(caps)
    |> Enum.flat_map(fn {source, dest, mode} -> ["-v", "#{source}:#{dest}:#{mode}"] end)
  end

  defp net_args(caps), do: if(net?(caps), do: [], else: ["--network", "none"])

  defp workdir_args(mounts) do
    case Mounts.workspace(mounts) do
      nil -> []
      workspace -> ["-w", workspace]
    end
  end

  @doc """
  The packages the derived image installs: the base set plus the project's.
  """
  @spec packages(map() | nil) :: [String.t()]
  def packages(caps),
    do: Enum.sort(Enum.uniq(@base_packages ++ ProjectConfig.sandbox_packages(caps)))

  # `caps: nil` means the legacy default profile, exactly as
  # `ShellCmd.execute/4` documents.
  defp normalize_caps(nil), do: Sandbox.default_caps()
  defp normalize_caps(caps), do: caps

  defp net?(caps), do: get_in(caps, ["net"]) == true

  defp write_list(caps), do: get_in(caps, ["fs", "write"]) || []
  defp project_list(caps), do: get_in(caps, ["fs", "project"]) || []
  defp protected_list(caps), do: get_in(caps, ["fs", "protected"]) || []

  # ---- the daemon ----

  @doc """
  The default runner: `docker <argv>` on the host, with stderr folded into the
  output so a failure message is what the caller reports.

  The only line of this module the suite does not execute — `config/test.exs`
  installs an inert runner for the test environment, because the suite must never
  talk to a daemon (see the moduledoc).
  """
  @spec system([String.t()]) :: {String.t(), non_neg_integer()}
  def system(argv), do: System.cmd("docker", argv, stderr_to_stdout: true)

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
