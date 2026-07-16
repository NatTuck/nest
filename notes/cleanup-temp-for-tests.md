# Sandbox tmp bind and test tmp paths

## Problem

`mix test` reports 38 failures in two clusters:

1. **23 setup failures in `test/nest/tools_test.exs`** —
   `File.mkdir_p!("/var/tmp/nest_tools_test_…")` returns `read-only file system`
   in the nest sandbox because `/var` is part of the outer sandbox's
   `--ro-bind / /`.
2. **14 tool-call failures in `test/nest/tools_edit_test.exs` and
   `test/nest/tools_inspect_file_test.exs`** — bwrap dies with
   `bwrap: setting up uid map: Read-only file system` because the
   outer nest sandbox has `/proc` mounted read-only, so the inner
   bwrap can't set up its user namespace before processing any args.

A third failure (described in earlier drafts as "test 38 in
`agent_compaction_test.exs`") is most likely a cascade of the
setup failures above — the file has only 7 tests, all passing
locally. Re-verify inside the nest sandbox after the fix.

## Why the test sandboxes are not actually wrong

Earlier drafts of this note proposed a sweeping rewrite: replace the
per-agent `--bind <tmp_path> /tmp` with `--tmpfs /tmp`, and delete
`tmp_path` plumbing from `Sandbox.build/3`, `ShellCmd.execute/5`,
`Tools.get_function/3`, `InspectFile.build/2`, and the Agent's
`:tmp_path` field. **That proposal was wrong.** The per-agent
`tmp_path` exists because the agent's `/tmp` must persist across
many bwrap invocations (one per tool call). `--tmpfs /tmp` creates
a fresh tmpfs per bwrap, so files written by one tool call would
disappear before the next. The current design — each Agent gets
`/tmp/nest-#{System.pid()}/agent-#{agent_id}` on the host, the
sandbox binds it at `/tmp` — is the correct one and stays.

The "cannot write to /tmp when tmp_path is not provided" test in
`tools_test.exs:257` is a load-bearing assertion of the desired
invariant: a mode whose caps do not include `/tmp` cannot write to
it inside the sandbox. It is **kept as-is**, not rewritten.

## What is actually wrong

Only the test setup paths. Four `describe` blocks in
`test/nest/tools_test.exs` construct their workspace directories at
`/var/tmp/nest_tools_test_#{id}` (or `/var/tmp/nest_caps_test_#{id}`).
`/var` is part of the outer nest sandbox's `--ro-bind / /`, so
`File.mkdir_p!` fails. There is also a misleading comment in those
setup blocks claiming the path is "outside of /tmp to avoid
conflicts with tmp bind mounts" — the comment is wrong; the path was
chosen because the author thought `/tmp` was unusable for some
reason. There is no such conflict.

## Fix

Replace each `/var/tmp/nest_tools_test_…` with a project-relative
path under `_build/tmp/`. `_build/` is gitignored (see
`.gitignore`), is cleaned by `mix clean`, and is writable regardless
of outer sandbox permissions because the project directory is
always writable when running `mix test` from it.

### `test/nest/tools_test.exs`

Four setup blocks (lines 65-75, 103-113, ~170-179, 326-332) change
from:

```elixir
# Use a directory outside of /tmp for workspaces to avoid conflicts with tmp bind mounts
test_workspace = "/var/tmp/nest_tools_test_#{System.unique_integer([:positive])}"
File.mkdir_p!(test_workspace)
```

to:

```elixir
# Project-relative tmp dir under _build/ — gitignored, cleaned by
# `mix clean`, always writable regardless of outer sandbox permissions.
test_workspace =
  Path.join(
    [File.cwd!(), "_build", "tmp", "nest_tools_test_#{System.unique_integer([:positive])}"]
  )

File.mkdir_p!(test_workspace)
```

The caps block (line 326) keeps its `"nest_caps_test_…"` prefix to
stay distinct from the others.

## Out of scope

- The 14 `bwrap: setting up uid map: Read-only file system` failures
  in `tools_edit_test.exs` and `tools_inspect_file_test.exs` are
  caused by the outer nest sandbox having `/proc` mounted
  read-only. The inner bwrap can't write to `/proc/self/uid_map`
  to set up its user namespace, so it dies before processing its
  arg list. The user-namespace setup is a kernel-level concern that
  happens before bwrap reads its arguments. Fixing it requires an
  environment change outside this repo (the outer nest sandbox
  needs `/proc` writable, or a different unshare-namespace
  mechanism that doesn't require writing `/proc/self/uid_map`).
- Any change to `lib/`. The production sandbox design is correct
  as-is; only the test setup paths are wrong.
- Deleting or rewriting the `cannot write to /tmp` test. It
  asserts the desired invariant and is the canonical example of
  why `--tmpfs /tmp` would be wrong.

## Expected outcome

After the change above, running `mix test` inside the nest sandbox
should drop from 38 failures to 14 (the `/proc`-read-only cluster).
The 23 setup failures are addressed by the fix above. The 14 bwrap
failures disappear if/when the outer nest sandbox mounts `/proc`
writable; that is outside this repo.