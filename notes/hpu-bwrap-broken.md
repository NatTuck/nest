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
route to `ShellCmd.execute_bypass/5`. That runs the command under a
minimal bwrap mount (`Nest.Sandbox.build_bypass/2`): the host root is
bound read-write and the host's `/dev` re-bound, so nothing is unshared,
no fresh devtmpfs is mounted, and HPU devices, network, and IPC are the
container's. Only the per-agent scratch dir is overlaid at `/tmp`, so
build mode sees the same private temp dir plan mode's sandbox provides.

This avoids the HPU-vs-namespace problem (the full sandbox's
`--unshare-all` + fresh `--dev`) while keeping `/tmp` consistent across
modes. Every other command keeps the full bwrap sandbox.
