# HPU-over-bwrap — removed (Sep 2026)

HPU (Habana Gaudi) device passthrough through bwrap did not work
reliably: the `synProfilerStart` profiler (client ↔ host-daemon) failed
under even a carefully minimized namespace split, and the device-bind /
log-dir machinery added significant complexity to the bwrap arg builder
for an unsupported path. The default sandbox is therefore back to full
isolation (`--unshare-all` plus a fresh `--dev` devtmpfs).

## What was removed

- `Nest.Sandbox.append_device_binds/2` — explicit `--dev-bind` for
  detected HPU device paths (`/dev/accel`, `/dev/hl*`, `/dev/infiniband`).
- `Nest.Sandbox.append_habana_log_tmpfs/3` — `--tmpfs` of the Habana
  log dir.
- `Nest.Hardware.habana_log_dir/0,1` — resolution of the `HABANA_LOGS`
  env var (default `/var/log/habana_logs`).
- The device-passthrough tests in `sandbox_test.exs`.
- `test/nest/hpu_sandbox_test.exs` (the `:hpu`-tagged integration test).

## What replaced it

`Nest.Sandbox.Bypass` — when HPU devices are detected *and* the process
is inside a container (`/.dockerenv`, `/run/.containerenv`, or a
containerd/podman cgroup/mountinfo marker), and the mode has a writable
workspace (build/act, not plan), `Sandbox.run/5` and `Sandbox.write/5`
route to `ShellCmd.execute_direct/5`, which runs the command without
bwrap and with no sandbox enforcement at all. The command still runs
from the workspace.

This avoids the HPU-vs-namespace problem entirely: if you're in a
container with HPUs, the sandbox is the container itself, not a nested
bwrap. Every other command keeps the full bwrap sandbox.
