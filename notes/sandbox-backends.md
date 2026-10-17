# Sandbox backends

A space is created with a **sandbox backend**, chosen once and immutable
afterwards: `spaces.sandbox_backend` is one of `bwrap` (the default), `docker`
or `none`. `Nest.Sandbox.Backend` owns the list and dispatches on it; every
agent in a space runs its commands through the space's backend.

`Nest.Tools.ShellCmd` is the single seam: a `shell-cmd`, a `read`, a `stat`, a
`glob`, a write and a background job all build their command line by asking the
backend, and the backend is named on the `Nest.Sandbox.Mounts` value that
already travels with every call. Adding a backend means adding a module under
`Nest.Sandbox.Backend` and one clause to `resolve/1` — nothing else changes.

## What each backend enforces

| | `bwrap` (default) | `docker` | `none` |
|---|---|---|---|
| Filesystem view | the host, read-only, plus the binds below | the derived image's rootfs, made read-only, plus the binds below | the host, read-write |
| `caps.fs.read` | `--ro-bind` per root | **the image is the read set** (nothing to bind) | ignored |
| `caps.fs.write` | `--bind` per path | `-v <p>:<p>:rw` for the paths the container binds; a path it cannot bind is refused by name | ignored |
| Workspace | bound at its canonical path, rw iff `":workspace"` | same, `-v …:rw\|ro` at both the canonical path and the path the caller named | the real directory |
| Scratch (`/tmp`) | the space scratch dir, bound at `/tmp` | the container's own `/tmp`, made writable by a self-bind | the host's real `/tmp` |
| `caps.net` (the space's `network_access`) | `--share-net` / `--unshare-net` | no flag / `--network none` | ignored |
| `.nest` mounts | `--bind` / `--ro-bind` | `-v` | not bound (the host path is already visible) |
| `.nest` read-only mask | a `/dev/null` `--ro-bind` | the same bind, in both layers | **not enforced** |
| `caps.shell.background` | enforced by `ShellJobs` | enforced by `ShellJobs` | enforced by `ShellJobs` |
| HPU devices | host `/dev` `--dev-bind` + writable Habana log dir | `--device` per path | already visible |
| Process/net namespace | unshared | the container's | the host's |

`caps["net"]` is the **space's** `network_access`, not a mode's: it is resolved
once at agent start, carried on the `Mounts` value, and injected by
`Nest.Sandbox.with_network_access/2`. The mode's own `net` key is a placeholder —
`Nest.Modes.caps/1` sets it to `false` and nothing reads it.

**`none` enforces nothing.** It is the escape hatch for a space that must reach
the real machine, and its caps are unenforceable by construction — including the
`.nest` read-only mask, so an agent in a `none` space can edit its own `.nest`.
That is stated in `Nest.Sandbox.Backend.None`'s moduledoc, in `Nest.Spaces.Space`'s
and in the New Space form's help text, rather than papered over.

Agent-visible paths are identical on every backend: `/tmp/<agent-name>/…` for
scratch and the workspace's own path for the workspace.

## One bind list, two renderings

`Nest.Sandbox.Binds` is the one derivation of the binds a call makes — the
workspace, the extra `caps.fs.write` paths, the scratch root at `/tmp`, the
`.nest` project mounts and the `.nest` mask — as `{source, dest, mode}` triples.
Both binding backends render that list, so they cannot drift:

* `Nest.Sandbox.Backend.Bwrap` renders each triple as `--bind`/`--ro-bind` over
  the host, after its own readable roots (`caps.fs.read`).
* The docker backend renders it twice — as `-v source:dest:mode` for the
  container, and as a self-bind of `dest` for the bwrap *inside* the container.
  See below for why the container's view is what the inner one rebinds.

## bwrap runs inside the docker container

A docker command is:

```
docker exec -i <container> /bin/bash -c 'mkdir -p … && exec bwrap …'
```

The container's root filesystem is the derived image, so the host's `/` is not
visible in it at all — and inside it, `bwrap` applies the *same* bind list over
that root instead of over the host. That is what makes `caps` mean exactly what
they mean under bwrap, and it is *stricter* than bwrap in the one way that
matters: a host path that is read-only under bwrap is simply absent here, so a
project that needs a host path readable declares it as a `.nest` mount.

The container binds the **superset** a space can need, because a container's
mounts are fixed when it is created and one container serves every mode its
space can run. Its binds are the ones `act` gets — which is exactly the set
`.nest` project mounts are granted to (`Nest.ProjectConfig.effective_caps/2`
gives them only to caps that write `":workspace"`) — plus the workspace and the
staging directory. The sandbox
inside tightens per call: `--ro-bind / /` makes the whole image read-only, and
each bind the call's caps ask for is re-applied as a *self-bind* of the path the
container already put there, which is what sets that path's mode. So `plan`
cannot write the workspace, a project mount, or `/tmp`, and it cannot write
`/usr` either. Two consequences worth stating:

* `plan` *sees* the project mounts, read-only. Under bwrap it sees the
  host paths themselves, read-only, through bwrap's own root bind — so the
  capability is the same on both, and only what a `mode = "tmp"` mount resolves
  to differs.
* A `caps.fs.write` path outside the symbolic entries and the `.nest` mounts
  names a host path the container does not have. `Docker.command/3` refuses that
  by name rather than letting the inner bwrap fail with `Can't bind mount …: No
  such file or directory`, which would classify as an ordinary `:enoent` and read
  to the agent as a missing file.

### What the daemon has to be told, and what it costs

Running bwrap in a container needs three things beyond docker's defaults, and
each omission fails with its own message (measured on this host, Docker 29.8.0,
`debian:trixie-slim`, bubblewrap 0.12.0):

| container flags | result |
|---|---|
| docker defaults | `No permissions to create a new namespace` |
| `--cap-add SYS_ADMIN` | `Failed to make / slave: Permission denied` (docker-default AppArmor denies `mount`) |
| `+ --security-opt apparmor=unconfined` | `pivot_root: Operation not permitted` (docker's seccomp denies it) |
| `+ --security-opt seccomp=unconfined` | **works** |
| `--privileged` | works, but the container sees the host's device nodes — worse than `none`, rejected |

Two further requirements come out of the same measurements:

* **No user namespace inside.** bwrap only creates one with `--unshare-user` or
  if it is not root, and a user namespace is what made earlier attempts fail at
  `pivot_root`. The exec runs as root and never passes `--unshare-user`.
* **No `--unshare-net` inside.** bwrap configures loopback before remounting `/`
  and fails `loopback: Failed RTM_NEWADDR: No child processes` (ECHILD) — which is
  why the network is the container's, and fixed at creation.

**What `seccomp=unconfined` costs, measured:** the device cgroup is intact (15
device nodes, no `/dev/nvme*`), `/proc/sys/kernel/core_pattern`,
`/proc/sysrq-trigger` and `/sys/fs/cgroup` are all read-only, and `CapEff` is
docker's default capability set plus `SYS_ADMIN`.

**The profile is narrowable, and we do not ship the narrowing.** The daemon's
default with the single `pivot_root` denial removed works — the daemon's builtin
profile is `defaultAction: SCMP_ACT_ERRNO` plus 401 allow-listed names in 13
conditional groups, and `pivot_root` is the one syscall bwrap needs that it does
not list. But shipping that means vendoring a snapshot of the installed daemon's
*version-specific* policy: nothing in the suite can validate it (the suite never
talks to a daemon), and a stale snapshot fails silently and confusingly — a
syscall a newer toolchain needs, missing from a frozen allow list, surfaces as an
`EPERM` or `EINVAL` deep inside an ordinary command. The extra flags already
disable AppArmor and grant `SYS_ADMIN`, so a frozen copy of docker's seccomp
policy would present the *appearance* of docker's defaults while two of the three
layers are open. `seccomp=unconfined` is at least honest, and its cost is
measured rather than assumed.

### The staging directory

A command's transcript is staged by the BEAM and read inside the container, so
the staging directory is the one thing that lives on the host: a stable
directory per space and installation (`Nest.Sandbox.Paths.docker_stage_dir/1`),
bound **read-only** at `/tmp/.cmds`.

Read-only matters. The agent can write `/tmp`, so a writable staging bind would
be a host write path — and one that could rewrite a sibling agent's pending
script between the BEAM writing it and the container running it.

This is also why the staging directory no longer needs the scratch bind: the
transcript reaches the container through its own bind, so a docker command runs
with or without a scratch. (It used to be the other way round: the staging
directory was `<space_dir>/.cmds`, reachable only through the `<space_dir>:/tmp`
bind, so a docker space with a workspace silently lost its `AGENTS.md` section —
the read failed as an `:enoent` the prompt swallowed. `Docker.command/3` refused
that case loudly until this rework made it impossible.)

### The scratch is the container's own `/tmp`

`Mounts.scratch` for a docker space names a path *inside* the container, and
nothing on the host may create or write it (`Nest.Sandbox.Mounts.host_scratch?/1`):

* `Nest.Agents.Agent.TmpSpace.create/3` only names it; neither removal has
  anything to remove, because the scratch goes when the container does.
* `Mounts.ensure_scratch!/1` is a no-op.
* The command that runs makes it — `mkdir -p /tmp/<agent>` in the exec.
* `Nest.Sandbox.scratch_write/3` (the offload path,
  `Nest.Agents.Agent.BatchSizer.Overflow`) writes through the sandbox gatekeeper
  instead of straight to a file, because only the container can write there.
* A background job's log is written **by the command itself**, inside the
  container: `set -o pipefail; … 2>&1 | tee /tmp/<agent>/shell-jobs/<id>.log`.
  `pipefail` is what keeps the exit code the command's rather than `tee`'s, since
  `docker exec` reports the pipeline's status. `Nest.Sandbox.ShellJobs.JobLog`
  reads and removes it through the container; the manager's `append` is a no-op
  there, because the bytes it receives on the exec's stream are that same output.

### A network edit replaces the container

`--network none` is fixed when a container is created, so
`Nest.Spaces.set_network_access/2` releases the space's containers as part of the
change and the next command builds one with the new value. Everything that lived
only in the container goes with it: the agents' `/tmp` (offloads, job logs) and
any running background job. The UI says so before the toggle is flipped. For a
`none` space nothing is released — its caps were never enforceable, and the
toggle has always been advisory there.

## One container per space

The container is named `nest-space-<space_id>-<installation>`, where the
installation segment comes from `Nest.Sandbox.Installation` — the configured
database name, sanitised. One docker daemon can serve two installations that
share a space id (a dev checkout and a production one), and without that segment
the second to run would adopt the first's container, its binds and its `/tmp`.

The name is **stable across BEAM restarts**, and that is the point: nothing
per-BEAM is bound any more, because the scratch is the container's own `/tmp` and
the one host directory a call needs (the staging directory) is keyed on the space
rather than on the BEAM's pid. The earlier design could not do this — its layout
included the scratch root, which embeds the BEAM's pid, so a restart got a fresh
container and the create path had to sweep the ones whose BEAM was gone. That
sweep, and the pid parsing with it, is gone.

Because the name cannot move when the layout does, the layout travels as a
`nest.layout` **label** instead, covering the container's binds, the image, the
devices and the network. Every call inspects the container once — status and
label in the same call — and:

* a missing container is created (image ensured first, lazily);
* a container whose label matches is reused, or `docker start`ed if it is
  stopped;
* a container whose label does not match is removed and created again, because a
  container's mounts, image and network are fixed at creation. A removal that
  fails is an error rather than something to adopt: adopting would run the call
  in the environment the label just said was wrong.

Nothing is ever orphaned, so no sweep is needed: a `.nest` package change, a
workspace change, a hardware change or a network change replaces the container in
place on the next command.

Two agents resolving to the same container race to create it, and a refused `run`
because the name is taken is "someone else got there first": the name is a
function of the space, so whoever won built it for the same layout, and the loser
adopts it.

Archiving or deleting a space removes every container named
`nest-space-<space_id>-*` — every installation's, not just the running one
(`Nest.Spaces` → `Nest.Sandbox.Backend.remove_space/3`). Archive is reversible:
the containers are recreated lazily after an unarchive. A daemon failure during
that cleanup is logged and does not break the archive, the delete or the network
change.

## A `"none"` scratch is removed only if Nest marked it

A `"none"` agent's scratch is the host's own `/tmp/<name>`, and the name is
client- and model-controlled: `@name_format` admits `nest-4` (another BEAM's
whole scratch root), `X11-unix` and `snap-private-tmp`, all of which are real
entries in a real `/tmp`. So `TmpSpace.create/3` writes a `.nest-scratch` marker
into a `"none"` agent's scratch, and **every** removal requires it — the
`terminate/2` cleanup and the stale-directory clear at creation.

A directory without the marker is left alone because nothing will touch it: the
name boundary refuses it (`{:scratch_path_taken, path}` — the New Space form says
there is already something at that agent's scratch path on the host that this
space does not own, and to pick another name), `create/3` refuses to adopt it
rather than stamping a marker into it, and both removals require the marker. That
last part is what makes the guarantee hold: `create/3` *claiming* a foreign
directory would mark it, and the next `cleanup/3` would then delete it — the
pass-one version of this guard had exactly that hole.

Two honest residuals: a `"none"` scratch created before this change has no marker,
so it is neither removed nor reusable (clear it by hand); and an agent that
deletes its own marker leaves a directory in the same state. Only `"none"` needs
the marker — a bwrap scratch sits under `nest-<BEAM pid>/space-<id>/`, and a
docker scratch is not on the host at all.

A scratch directory has exactly two creators, and both mark what they make:
`TmpSpace.create/3` (the start path) and `Mounts.ensure_scratch!/1`, which
`Nest.Tools.ShellCmd` calls before every staged command — and which the prompt's
`AGENTS.md` read reaches first. That second one used to be a bare `mkdir_p!`, so a
`"none"` scratch it made carried no marker, and a start that never happened left a
directory no later agent could remove. An *existing* directory is never touched,
so something that is not Nest's is never marked by accident.
`TmpSpace.prompt_mounts/4` only *names* the directory; it does not make it, so a
scratch path that cannot be made fails where the agent starts rather than as a
raise out of a caller that is merely composing a prompt.

A `"none"` scratch is also left alone while a *live* agent in another space holds
the same name. Two `"none"` spaces share one `/tmp`, the creation boundary only
refuses a *live* holder, and the on-demand restart path is not gated at all — so
space A's stopped `x`, space B's new `x`, and A's rehydrated `x` can all be live
on `/tmp/x`. `TmpSpace.cleanup/3` therefore asks the registry (only the registry:
it runs from `terminate/2`) whether another space has a live agent of that name,
and refuses if so. Over-refusing leaves a stale directory, which is harmless.

## The `.nest` mask

The mask is a real bind of `/dev/null` (or of the `.nest` file itself, when it
exists) at the `.nest` path, read-only, in both layers. Reading it therefore
fails with `EACCES` rather than returning empty bytes: bwrap's read-only binds
are mounted with `nodev`, so a char device bound through one cannot be opened.
That is true on bwrap and on docker alike — it is one rendering of one bind list
— and it is what makes the mask a mask rather than an empty file.

## The derived image

```
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash coreutils file git curl ca-certificates procps ripgrep bubblewrap [<.nest packages>] \
 && rm -rf /var/lib/apt/lists/*
```

* `debian:trixie-slim` is Debian 13. It is deliberately minimal — no `git`,
  `curl`, `file` or `rg` — so the base set adds what a shell needs to be useful.
* **`bubblewrap` is not optional.** The container is half the sandbox: the mode's
  caps are enforced by the bwrap inside it, so an image without one could run
  nothing at all.
* The tag is `nest-sandbox:<12 hex>` keyed on the base reference and the sorted
  package list, so a changed set is a different tag. The build is skipped when the
  tag already exists, and the tag is part of the container's *layout*, so a
  `.nest` that changes its packages is a label mismatch and replaces the
  container on the next command.
* The project toolchain (Elixir, Node, Rust) is **not** in the base. A project
  that needs it declares it:

```toml
# .nest
[sandbox]
packages = ["nodejs", "elixir"]
```

Names must look like Debian package names (`^[a-z0-9][a-z0-9+.-]*$`); a malformed
value is refused exactly like every other `.nest` failure — logged, ignored, and
rendered as a visible error block in the system prompt — never silently dropped.
The list applies in every mode (it is tooling inside the container, not a
filesystem grant) and is rendered in the system prompt's project-config section
so an agent knows the toolchain is there.

A failed build, a refused container start or a daemon that is not there reaches
the agent as `Execution failed: …`; it is never a half-built sandbox.

## Testing

* A docker space with a *workspace* cannot be created in the suite at all: the
  system prompt reads `AGENTS.md` through the backend, and that exec is a real
  `docker exec` (the `docker_runner` stub covers the setup calls, not the command
  the agent runs — see `config/test.exs`). The call sites that build the prompt's
  mounts are therefore covered through `TmpSpace.prompt_mounts/4` and through a
  docker space *without* a workspace.
* Everything that decides *what* to run is pure and asserted exactly:
  `Docker.container_name/1`, `layout/3`, `image_tag/1`, `dockerfile/1`,
  `container_binds/1`, `run_args/4`, and the command line (including the payload
  the container's bash runs, which the test helpers unescape one layer so an
  assertion can be written against what the container sees).
* The bind list is shared (`Nest.Sandbox.Binds`), so there is one derivation and
  two renderings rather than two derivations with a drift guard. Two tests pin
  the renderings: bwrap's args equal the specs after its readable roots, and the
  docker command line self-binds every spec's `dest`.
* The lifecycle takes an injectable `:runner` (`fn argv -> {output, exit_code}
  end`), so create / reuse / start-if-stopped / replace-on-drift / remove are
  tested against a fake, including that a second call **reuses** rather than
  recreates, and that a container built for another layout is replaced.
* `config/test.exs` installs an inert runner for the test environment, so the
  suite never talks to a daemon even by accident, and never leaves a container.
  `Docker.system/1` — the `System.cmd("docker", argv)` default — is the one line
  the suite does not execute.
* **Two docker paths are exercised only by hand**, because the suite cannot run
  a container: `Nest.Sandbox.scratch_write/3`'s docker branch (it goes through
  `ShellCmd`, which spawns the real CLI) and the whole per-call command line
  end to end. Both are covered by the manual check below.

## Manual smoke check

The suite mocks the daemon, so the real command line only runs by hand. **Run
this from the host, not from inside a Nest agent**: the daemon resolves bind
sources against the real host filesystem, and a sandboxed `/tmp` is not the
host's `/tmp`. The staging directory is the one place that matters most — it is
the one host path a docker command needs — so point `TMPDIR` at somewhere the
daemon can see if you are running this from a sandbox.

```sh
ws=/path/to/workspace
tag=nest-sandbox:<the tag the backend computed>

# 1. the image the backend would build, with the Dockerfile it generates
printf 'FROM debian:trixie-slim\nRUN apt-get update && apt-get install -y --no-install-recommends %s && rm -rf /var/lib/apt/lists/*\n' \
  'bash coreutils file git curl ca-certificates procps ripgrep bubblewrap' > Dockerfile
docker build -t "$tag" .

# 2. a container with the flags and binds the backend builds
docker run -d --name nest-space-probe \
  --cap-add SYS_ADMIN --security-opt apparmor=unconfined --security-opt seccomp=unconfined \
  --network none --label nest.layout=probe \
  -v "$ws":"$ws":rw -v /dev/null:"$ws/.nest":ro -v /tmp/nest-docker-probe/.cmds:/tmp/.cmds:ro \
  -w "$ws" "$tag" sleep infinity

# 3. the command line the backend builds, by hand
mkdir -p /tmp/nest-docker-probe/.cmds && echo 'cat in.txt' > /tmp/nest-docker-probe/.cmds/x.sh
printf 'stdin works\n' | docker exec -i nest-space-probe /bin/bash -c \
  "mkdir -p /tmp/agent-a && exec bwrap --die-with-parent --new-session \
     --ro-bind / / --dev-bind /dev /dev --proc /proc \
     --bind '$ws' '$ws' --bind /tmp /tmp --chdir '$ws' /bin/bash /tmp/.cmds/x.sh"

# 4. a read-only call really is read-only, and the image really is too
docker exec -i nest-space-probe /bin/bash -c \
  "exec bwrap --ro-bind / / --dev-bind /dev /dev --proc /proc --ro-bind '$ws' '$ws' --chdir '$ws' \
     /bin/bash -c 'echo x > out.txt; touch /usr/local/evil'"   # both Read-only file system

# 5. it survives a stop/start — this is what a BEAM restart relies on
docker stop nest-space-probe && docker start nest-space-probe

docker rm -f nest-space-probe
```

Then confirm nothing was left behind:

```sh
docker ps -a --format '{{.Names}}' | grep '^nest-space-' || echo "no nest containers"
```

## Known limitations

* **`bwrap` is still required at boot.** `Nest.Application.check_system_dependencies!/0`
  runs `bwrap --version` and refuses to start without it, so a deployment that
  only ever uses `docker` or `none` still needs bubblewrap installed. Flagged, not
  changed here.
* **Docker ignores `caps.fs.read`** (see above) and does not bind the Habana log
  directory that the bwrap backend binds on an HPU host; it passes the accelerator
  device nodes through with `--device` instead.
* **`docker` needs a daemon.** A space created with it is unusable without one;
  every command reports `Execution failed: …` with the daemon's own message.
* **A `caps.fs.write` path outside the symbolic entries and the `.nest` mounts is
  refused on a docker space**, by name, with a pointer at `.nest` mounts. The
  container's binds are fixed when it is created and one container serves every
  mode of a space, so a per-mode host path cannot be one of them.
* **A timed-out or cancelled docker command is not killed inside the container.**
  `ShellCmd` kills the process it started, which is the `docker` CLI; the command
  in the container keeps running (the inner `--die-with-parent` only covers the
  container's own bash). This is a property of running anything through
  `docker exec`, it predates this rework, and it is flagged rather than fixed.
