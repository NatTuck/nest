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
| Filesystem view | the host, read-only, plus the binds below | the derived image's rootfs, plus the binds below | the host, read-write |
| `caps.fs.read` | `--ro-bind` per root | **ignored** (the image *is* the read set) | ignored |
| `caps.fs.write` | `--bind` per path | `-v <p>:<p>:rw` | ignored |
| Workspace | bound at its own path, rw iff `":workspace"` | same, `-v …:rw\|ro` | the real directory |
| Scratch (`/tmp`) | the space scratch dir, bound at `/tmp` | same, `-v <space_dir>:/tmp:rw\|ro` | the host's real `/tmp` |
| `caps.net` | `--share-net` / `--unshare-net` | no flag / `--network none` | ignored |
| `.nest` mounts | `--bind` / `--ro-bind` | `-v` | not bound (the host path is already visible) |
| `.nest` read-only mask | a `/dev/null` `--ro-bind` | a `/dev/null` `-v …:ro` | **not enforced** |
| `caps.shell.background` | enforced by `ShellJobs` | enforced by `ShellJobs` | enforced by `ShellJobs` |
| HPU devices | host `/dev` `--dev-bind` + writable Habana log dir | `--device` per path | already visible |
| Process/net namespace | unshared | the container's | the host's |

**`none` enforces nothing.** It is the escape hatch for a space that must reach
the real machine, and its caps are unenforceable by construction — including the
`.nest` read-only mask, so an agent in a `none` space can edit its own `.nest`.
That is stated in `Nest.Sandbox.Backend.None`'s moduledoc, in `Nest.Spaces.Space`'s
and in the New Space form's help text, rather than papered over.

**`docker` is stricter than `bwrap`, not looser**, because its root filesystem is
the image: the host's `/` is not visible at all, so a path that is read-only
under bwrap is *absent* here. A project that needs a host path read-only declares
it as a `.nest` mount.

Agent-visible paths are identical on every backend: `/tmp/<agent-name>/…` for
scratch and the workspace's own path for the workspace.

### The staging directory needs the scratch bind

A command's transcript is staged on the host and handed to the shell as a *file*,
so the file has to be reachable *inside* the environment. Under bwrap that works
with or without a scratch bind, because bwrap binds the host `/` read-only and
`<host tmp>/.nest-cmds` is visible through it. **Under docker it does not**: the
container's root filesystem is the image, so without the `<space_dir>:/tmp` bind
the handed path is the container's own empty `/tmp` — bash exits 127, the failure
classifies as `:enoent` (an ordinary "not found", deliberately not logged), and a
caller like the system prompt's `AGENTS.md` section swallows it. A docker space
with a workspace would silently lose that section.

So every call that runs the sandbox names the agent's real scratch directory —
`Nest.Agents.Agent.TmpSpace.prompt_mounts/4` is the one place the prompt's mounts
are built — and `Docker.command/3` refuses outright with no scratch bind, so the
next caller that forgets is loud rather than silent.

### A `"none"` scratch is removed only if Nest marked it

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
the marker — a bwrap or docker scratch sits under `nest-<BEAM pid>/space-<id>/`.

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

## One container per `(space, caps signature)`

Caps are per **agent** (they come from the vocation's mode), and one container's
binds and network namespace cannot vary per `docker exec`. Binding the union of
every mode's caps would silently hand a read-only mode a writable workspace,
which is exactly the silent capability weakening this codebase forbids.

So each distinct caps signature gets its own container:

* named `nest-space-<space_id>-<BEAM pid>-<8 hex>`, where the hash covers `net`,
  the bind list with its rw/ro flags, the workspace path, and the HPU device
  paths — i.e. exactly what the container's layout depends on;
* created lazily on first use, `docker start`ed when it exists but is stopped, and
  shared by every agent that resolves to the same signature. In practice a space
  has one or two.

The name carries the **BEAM's OS pid** as well as the space id, because the layout
includes the scratch bind — the space scratch dir is `/tmp/nest-<BEAM pid>/space-<id>`.
A restart is therefore a different layout, and it gets a different container, on
purpose: a container's mounts are fixed when it is created, so `docker start`ing
the old one would leave its `/tmp` pointing at the *previous* BEAM's scratch
directory, which this BEAM never writes to — every staged script would be
unreadable inside the container. (That is also why `Nest.Sandbox.Mounts` carries
the space id: the name has to be built from the space, not from the scratch path.)

The superseded container does not leak. The next create for that space sweeps
every container of the space whose BEAM is gone — liveness is `/proc/<pid>`, which
is Linux-specific and fine, since `bwrap` is already a boot requirement — and logs
each removal at `info`. A *live* BEAM's container is kept, because two BEAMs can
share a space id (a dev BEAM and a prod BEAM on one daemon, same serial), and so
is any name that is not this space's exact format.

So **"one container for the life of the space" holds within a BEAM, not across
restarts.** Making it hold across restarts would mean a scratch root that does not
embed the BEAM's pid — a change to `Nest.Agents.Agent.TmpSpace.space_dir/2`, which
is a deliberate design and out of scope here.

The *image* is per space rather than per signature — it comes from the space's
`.nest`, which every agent in the space shares.

Archiving or deleting a space removes every container named
`nest-space-<space_id>-*` — every BEAM's, not just the running one
(`Nest.Spaces` → `Nest.Sandbox.Backend.remove_space/3`). Archive is reversible:
the containers are recreated lazily after an unarchive. A daemon failure during
that cleanup is logged and does not break the archive or the delete.

## The derived image

```
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash coreutils file git curl ca-certificates procps ripgrep [<.nest packages>] \
 && rm -rf /var/lib/apt/lists/*
```

* `debian:trixie-slim` is Debian 13. It is deliberately minimal — no `git`,
  `curl`, `file` or `rg` — so the base set adds what a shell needs to be useful.
* The tag is `nest-sandbox:<12 hex>` keyed on the base reference and the sorted
  package list, so a changed set is a different tag. The build is skipped when the
  tag already exists, and the tag is part of the container's signature — a
  container reused across a package change would otherwise keep running the old
  image, because the image is only ensured on the create path. The superseded
  container then lingers until its BEAM is gone, which is the deliberate cost of a
  pid-based sweep: a layout-based one would have two agents in different modes
  deleting each other's container on every create.
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

A failed build or a failed container start reaches the agent as
`Execution failed: …`; it is never a half-built sandbox.

## Testing

* A docker space with a *workspace* cannot be created in the suite at all: the
  system prompt reads `AGENTS.md` through the backend, and that exec is a real
  `docker exec` (the `docker_runner` stub covers the setup calls, not the command
  the agent runs — see `config/test.exs`). The call sites that build the prompt's
  mounts are therefore covered through `TmpSpace.prompt_mounts/4` and through a
  docker space *without* a workspace.
* Everything that decides *what* to run is pure and asserted exactly:
  `Docker.container_name/3`, `image_tag/1`, `dockerfile/1`, `bind_specs/2`,
  `run_args/4`. `bind_specs/2` mirrors `Nest.Sandbox.build/2`'s derivation, and a
  test compares the two for a table of caps, so they cannot drift — the readable
  roots bwrap binds and docker ignores are the one intended difference.
* The lifecycle takes an injectable `runner` (`fn argv -> {output, exit_code}
  end`), so create / reuse / start-if-stopped / remove are tested against a fake,
  including that a second call **reuses** rather than recreates.
* `config/test.exs` installs an inert runner for the test environment, so the
  suite never talks to a daemon even by accident, and never leaves a container.
  `Docker.system/1` — the `System.cmd("docker", argv)` default — is the one line
  the suite does not execute.

## Manual smoke check

The suite mocks the daemon, so the real command line only runs by hand. **Run
this from the host, not from inside a Nest agent**: the daemon resolves bind
sources against the real host filesystem, and a sandboxed `/tmp` is not the
host's `/tmp`.

```sh
ws=/path/to/workspace
space_dir=/tmp/nest-<pid>/space-<id>        # the space scratch dir

# 1. a container with the shape the backend builds
docker run -d --name nest-space-probe --network none \
  -v "$ws":"$ws":ro -v "$space_dir":/tmp:rw -w "$ws" debian:trixie-slim sleep infinity

# 2. the command line the backend builds: stdin must reach the script
printf 'stdin works\n' | docker exec -i nest-space-probe /bin/bash /tmp/.cmds/<script>.sh

# 3. it survives a stop/start (this is what a BEAM restart relies on)
docker stop nest-space-probe && docker start nest-space-probe

# 4. a read-only bind really is read-only
docker exec -i nest-space-probe /bin/bash -c "echo x > $ws/evil.txt"   # Read-only file system

# 5. the image really has the tools the base set promises
docker run --rm debian:trixie-slim sh -c 'command -v git curl file rg'  # all missing on the base
docker run --rm "$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^nest-sandbox:' | head -1)" \
  sh -c 'command -v git curl file rg'                                   # all present in the derived image

docker rm -f nest-space-probe
```

Then confirm nothing was left behind:

```sh
docker ps -a --format '{{.Names}}' | grep '^nest-space-' || echo "no nest containers"
```

## Known limitations

* **A docker space's container does not survive a BEAM restart.** Each restart
  gets a fresh container (see above), and the superseded one is swept on the next
  create for that space. To clear them all by hand (`xargs -r`, so an empty list
  is a no-op rather than a usage error):

  ```sh
  docker ps -aq --filter 'name=^nest-space-' | xargs -r docker rm -f
  ```

* **`bwrap` is still required at boot.** `Nest.Application.check_system_dependencies!/0`
  runs `bwrap --version` and refuses to start without it, so a deployment that
  only ever uses `docker` or `none` still needs bubblewrap installed. Flagged, not
  changed here.
* **Docker ignores `caps.fs.read`** (see above) and does not bind the Habana log
  directory that the bwrap backend binds on an HPU host; it passes the accelerator
  device nodes through with `--device` instead.
* **`docker` needs a daemon.** A space created with it is unusable without one;
  every command reports `Execution failed: …` with the daemon's own message.
