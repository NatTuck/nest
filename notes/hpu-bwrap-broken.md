# HPU-over-bwrap — removed (Sep 2026)

HPU (Habana Gaudi) device passthrough through bwrap did not work
reliably. The `synProfilerStart` profiler (client ↔ host-daemon) failed
under even a carefully minimized namespace split, and the
`append_device_binds` / `append_hpu_mounts` machinery added significant
complexity to the bwrap arg builder for an unsupported path.

## What was removed

- `Nest.Sandbox.append_device_binds/2` — explicit `--dev-bind` for
  detected HPU device paths (`/dev/accel`, `/dev/hl*`, `/dev/infiniband`).
- `Nest.Sandbox.append_hpu_mounts/3` — `--tmpfs` of Habana log dir and
  `--bind` of `~/.habana` read-write.
- `Nest.Hardware.habana_log_dir/0` — resolution of `HABANA_LOGS` env var
  (default `/var/log/habana_logs`).
- `Nest.Hardware.habana_home_dir/0` — resolution of `~/.habana`.
- `Nest.Hardware.ensure_habana_home!/1` — creation of `~/.habana`.
- The namespace-modification comments in `Sandbox.base_args/1` that
  explained why PID/IPC/UTS/cgroup were left SHARED.
- The device-passthrough tests in `sandbox_test.exs`.
- `test/nest/hpu_sandbox_test.exs` (the `:hpu`-tagged integration test).

## What replaced it

`Nest.Sandbox.Bypass` — when HPU devices are detected *and* the process
is inside a Docker container (`/.dockerenv`), and the mode has a writable
workspace (build/act, not plan), `ShellCmd.execute_direct/5` runs the
command without bwrap entirely.

This avoids the HPU-vs-namespace problem entirely: if you're in Docker
with HPUs, the sandbox is the Docker container itself, not a nested
bwrap.
