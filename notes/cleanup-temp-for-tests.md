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
   outer nest sandbox has `/proc` mounted read-only (visible at
   `/proc/self/mountinfo` line 1163), so the inner bwrap can't set
   up its user namespace before processing any args.

A third failure (test 38, in `agent_compaction_test.exs`) is a real
assertion failure unrelated to this work.

Both clusters trace back to one underlying design issue:
**the test sandboxes are not the same shape as the production
sandbox**. The production sandbox gives the tool a per-agent
writable `/tmp` (so shell commands have a scratch space and can't
trash the host's `/tmp`). The test sandboxes either give the tool
no writable `/tmp` at all (because `tmp_path` defaults to `nil`),
or they shadow the workspace with a misplaced tmp bind.

## Why the test sandboxes are wrong

`Nest.Tools.get_function/2` and `/3` carry a `tmp_path` argument
that defaults to `nil`. `Tools.get_function/2` is the two-arg
form, used by every test in `tools_test.exs`,
`tools_edit_test.exs`, and `tools_inspect_file_test.exs`. The
`tmp_path` ends up `nil`, the tool calls `ShellCmd.execute/5`
with `tmp_path = nil`, and `Nest.Sandbox.append_tmp_bind/1`
short-circuits on `nil`:

```elixir
defp append_tmp_bind(args, nil), do: args

defp append_tmp_bind(args, tmp_path) do
  args ++ ["--bind", tmp_path, "/tmp"]
end
```

So the test bwrap has no `--bind` or `--tmpfs` for `/tmp`. Inside
the inner sandbox, `/tmp` is just whatever the read-only bind of
the host root provides — i.e. the host's `/tmp`, read-only. The
"cannot write to /tmp when tmp_path is not provided" test
(`tools_test.exs:257`) actually asserts on this, treating the
absence as a feature.

The bwrap args list is also ordered wrong even when `tmp_path` is
non-nil. In `Sandbox.build/3` the order is:

```
base_args()         # --ro-bind / /, --dev /dev, --proc /proc
|> append_net_flag(caps)
|> append_workspace_bind(caps, workspace_path)
|> append_write_binds(caps, workspace_path)
|> append_tmp_bind(tmp_path)   # <-- this comes AFTER the workspace bind
|> append_chdir(workspace_path)
```

`append_tmp_bind/1` does `--bind <tmp_path> /tmp`. The destination
is the root of the `/tmp` subtree. A new mount at `/tmp` shadows
all descendant mounts reachable via path traversal, including the
workspace bind that was just placed at `<workspace_path>` if
`<workspace_path>` is under `/tmp` (e.g. `/tmp/agent_1`). The
workspace mount exists in the namespace but is unreachable from
inside the sandbox.

This is why the test code in `tools_test.exs` puts the workspace
at `/var/tmp/...` rather than `/tmp/...`: the author was avoiding
the shadow. But `/var/tmp` is read-only in the nest sandbox, so
the test setup can't create the directory at all. The "outside
`/tmp`" comment in those setup blocks is documenting a workaround
for a self-inflicted constraint in `append_tmp_bind/1`.

## Correct design

The sandbox should always have a fresh per-sandbox `/tmp`, with
the workspace bound on top of it:

```
--ro-bind / /            # host root, read-only
--dev /dev               # fresh devtmpfs over the ro-bind
--proc /proc             # fresh procfs over the ro-bind
--tmpfs /tmp             # fresh per-sandbox /tmp, over the ro-bind
--share-net | --unshare-net
--bind <workspace> <workspace>   # workspace on top of the ro-bind (and on top of /tmp if the workspace is under /tmp)
--bind <extra-write-path> <extra-write-path>   # per caps.fs.write
--chdir <workspace>
```

Key invariants:

- `/tmp` is per-sandbox. It dies when the bwrap exits. Nothing
  the tool writes to `/tmp` survives the bwrap.
- The workspace survives the bwrap, because it lives on the host
  (under the outer sandbox's `/tmp`, or under whatever the
  outer's writable tree is) and is bind-mounted in.
- If the workspace happens to be at a `/tmp` subpath on the
  host (typical in the nest sandbox, where the test setup
  creates `/tmp/workspace_X` on the outer tmpfs), the workspace
  is reachable inside the bwrap because the workspace bind is
  *after* `--tmpfs /tmp`. The new empty tmpfs covers the
  outer `/tmp`, and the workspace bind is a separate mount at
  `/tmp/workspace_X` sitting on top of the empty tmpfs.
- If `--tmpfs /tmp` were *after* the workspace bind (the
  reverse order), the new tmpfs would shadow the workspace mount
  and the workspace would be unreachable.

The relevant bwrap rule: **a new mount at an ancestor path
covers all descendant mounts that are reachable via path
traversal.** Order matters because earlier mounts at descendant
paths are not lifted out — they just become shadowed by the new
ancestor mount.

## Plan

### `lib/nest/sandbox.ex`

1. Add `--tmpfs /tmp` to `base_args/0`, after `--proc /proc`.
   Keep the existing comments that explain why `--dev` and
   `--proc` come after `--ro-bind`; add a comment that `--tmpfs
   /tmp` is in the same position for the same reason (the new
   tmpfs overlays the read-only host `/tmp` rather than being
   shadowed by it).
2. Delete `append_tmp_bind/1` entirely. Drop the `tmp_path`
   parameter from `build/3`. Remove the `append_tmp_bind(tmp_path)`
   line from the `build/3` pipeline.
3. Drop the `tmp_path` parameter from `build_default/2`.
4. Drop `"/tmp"` from the write list in `default_caps/0`. The
   `"/tmp"` entry was symbolic and rejected by
   `append_write_binds/3`; with `append_tmp_bind/1` gone it's
   just a no-op. Update the moduledoc to drop the "/tmp
   (symbolic) — the per-agent scratch directory" paragraph;
   replace with a sentence saying /tmp is a fresh per-sandbox
   tmpfs that dies with the sandbox.

### `lib/nest/tools/shell_cmd.ex`

5. Drop the `tmp_path` parameter from `execute/5` and
   `build_bwrap_args/3`. Update `build_sandboxed_command/4` to
   match.
6. Update the moduledoc to drop the "workspace + /tmp writable"
   bullet and the sentence about the symbolic `/tmp` placeholder.

### `lib/nest/tools.ex`

7. Drop the `tmp_path` parameter from `get_function/2` and
   `get_functions/3` (collapse the `/3` arity into the
   two-arg form).
8. Update the private tool-function builders
   (`read_file_function/2`, `write_file_function/2`,
   `edit_function/2`, `shell_cmd_function/2`) to drop the
   `tmp_path` argument.
9. Update the private tool implementations (`read_file/4`,
   `write_file/5`, `edit/4`, `read_file_via_shell/4`,
   `shell_cmd/4`, `shell_escape/1`, etc.) to drop the
   `tmp_path` argument and stop forwarding it to
   `ShellCmd.execute`.

### `lib/nest/tools/inspect_file.ex`

10. Drop `tmp_path` from `build/2`, `execute/4`, `run_file_type/4`,
    `text_output/6`, and `read_file_via_shell/4`. Update
    `InspectFile.build(workspace_path, tmp_path)` callers
    (in `Tools.inspect_file_function/2` and in any tests).

### `test/nest/sandbox_test.exs`

11. Update `build/3` and `build_default/2` test calls to drop
    the trailing `tmp_path` argument. Update the
    `"--tmp_path provided produces --bind tmp_path /tmp"` test
    to assert on `--tmpfs /tmp` instead.
12. Add a regression test in the `"arg ordering (regression)"`
    describe block:

    ```elixir
    test "--tmpfs /tmp appears AFTER --ro-bind / / and BEFORE the workspace bind" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/tmp/workspace_X")
      ro_bind_idx   = Enum.find_index(args, &(&1 == "--ro-bind"))
      tmpfs_idx     = Enum.find_index(args, &(&1 == "--tmpfs"))
      workspace_idx = Enum.find_index(args, &(&1 == "/tmp/workspace_X"))

      assert ro_bind_idx < tmpfs_idx,
             "expected --ro-bind before --tmpfs (so the new /tmp is fresh, " <>
             "not shadowed by the read-only host root)"

      assert tmpfs_idx < workspace_idx,
             "expected --tmpfs /tmp before the workspace bind (so the " <>
             "workspace is bound on top of the fresh /tmp, not shadowed by it)"
    end
    ```

### `test/nest/tools_test.exs`

13. In the four `setup` blocks at lines 68, 107, 173, 329, change
    the workspace path from `"/var/tmp/nest_tools_test_#{…}"`
    (and `"/var/tmp/nest_caps_test_#{…}"`) to
    `Path.join(System.tmp_dir!(), "nest_tools_test_#{…}")`.
    Delete the now-incorrect comments about "outside of /tmp to
    avoid conflicts with tmp bind mounts".
14. Delete the test at line 257, `"cannot write to /tmp when
    tmp_path is not provided"`. It asserts the OLD behavior
    (writes to `/tmp` fail when `tmp_path` is `nil`); with
    `--tmpfs /tmp`, writes to `/tmp` always succeed, so the
    test's assertion is wrong.
15. Simplify the test at line 212, `"can write to /tmp when
    tmp_path is provided"`. The `agent_tmp` setup is no longer
    needed — `/tmp` is always writable via `--tmpfs /tmp`.
    Drop the `Tools.get_function("shell_cmd", workspace, agent_tmp)`
    call to `Tools.get_function("shell_cmd", workspace)` and
    drop the assertion that the file is at `Path.join(agent_tmp, ...)`
    (it's now in the bwrap's tmpfs, which dies with the bwrap,
    so there's nothing to assert on the host filesystem).
16. Update the "caps threading through context" tests to drop
    the unused `"/tmp"` entry from the `caps` map (now a no-op
    since `append_write_binds/3` doesn't have a special case
    for it, and the symbol no longer appears in
    `default_caps/0`).

### `test/nest/tools_edit_test.exs` and `test/nest/tools_inspect_file_test.exs`

17. No change to setup paths (already using
    `System.tmp_dir!()`). Optional: drop the `"/tmp"` entries
    from the `caps` map in the `invoke/2` helpers (now a no-op).

## Out of scope

The 14 `bwrap: setting up uid map: Read-only file system`
failures in `tools_edit_test.exs` and `tools_inspect_file_test.exs`
are caused by the outer nest sandbox having `/proc` mounted
read-only. The inner bwrap can't write to `/proc/self/uid_map`
to set up its user namespace, so it dies before processing its
args. The changes above don't affect this — the user-namespace
setup is a kernel-level concern that happens before bwrap reads
its argument list.

Fixing that requires an environment change (the outer nest
sandbox needs `/proc` writable, or a different
unshare-namespace mechanism that doesn't require writing
`/proc/self/uid_map`). The remaining work for that cluster of
failures is outside this repo.

The single agent_compaction_test.exs failure (test 38) is a
real assertion failure unrelated to the sandbox work.

## Expected outcome

After the changes above, running `mix test` inside the nest
sandbox should drop from 38 failures to 14 (the
`/proc`-read-only cluster). Outside the nest sandbox, the 14
disappear too, and `mix test` should pass cleanly.

The 23 setup failures (`/var/tmp` not writable) are addressed
by #13. The `cannot write to /tmp` test failure is addressed
by #14. The other shell_cmd tests in `tools_test.exs` should
pass once the Sandbox and ShellCmd changes are in (the bwrap
is now correct).
