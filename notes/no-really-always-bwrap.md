# No, really: always bwrap

The sandbox's filesystem view is bwrap's view. Nothing emulates it on the host.

This note is the policy plus the plan for applying it to PR #46 ("sandbox has one
tmp", branch `fix-tmp-join` @ `de284c2`). It was written from an independent
review plus two read-only planning passes; every anchor is checkable.

## 0. Rulings that constrain this work

1. **The sandbox's filesystem view is bwrap's view.** Any host-side emulation of
   it is wrong unless the replication is *perfect* — so `read`, `stat` and `glob`
   all execute inside bwrap, and the host fast paths go away. (Confirmed against
   the evidence: two of the review's three "configurations" are genuine
   host-vs-bwrap disagreements for `stat` — a `mode="tmp"` mount with an absent
   out-of-workspace destination, where the host reports a healthy file of size 5
   in a sandbox bwrap cannot even start, and a workspace under `/tmp`, where the
   scratch bind shadows it. The third, the masked `.nest`, is *not* a stat
   disagreement — host `File.stat` and bwrap `stat -L` agree it is a char device;
   it is a **classification** bug, see §3.)
2. **Reads never go through the host. Permanently.** No fast path may be
   reintroduced; the rule gets stated and guarded (§3).
3. **The path mapping lives in exactly one place.** This change mostly *deletes*
   the problem: with no host-side emulation, the only mapping left is the bind
   source and the reported sandbox spelling (§1).
4. **Clean up the no-op tests** (§4). **The `AGENTS.md` hunk stays in this
   commit** — no split; new policy text goes in alongside it.

## 1. What remains of the path mapping

After the fast paths go, these are dead and should be **deleted**:
`Paths.to_host/3` and `Paths.to_sandbox/2` (their only callers were
`stat/4` (`sandbox.ex:330`), `collect_matches/5` (`:420`,`:424`) and
`classify_read_failure/4` (`:351`)); `Sandbox.read_permitted?/3` (`:342-344`);
`read_allowed?/2` (`:244-253`) and `write_allowed?/3` (`:261-266`) — both have no
production caller once the mounts are the only gate (`write_allowed?/3` has none
*today*; the repo's own comment in `test/nest/agents/agent/tmp_space_test.exs:158`
says so); and `ProjectConfig.read_source/2` (`project_config.ex:328`) with its
private helpers (`mount_for/2`, `protected_for/2`, `shadow_mount/2`,
`shadow_for/2`, `protected_paths/1`), whose only caller is `sandbox.ex:333`.
Keep `readable_roots/1` (used for the `--ro-bind`s) and `project_mounts/1`.

**What survives, in one place:**

- `Nest.Sandbox.Paths.scratch_root/1` — the bind source for
  `append_tmp_bind/2` (`sandbox.ex:580`).
- `Paths.@sandbox_root "/tmp"` + `sandbox_root/0` — the one home for the literal,
  used by `append_tmp_bind/2` and by the inverse mapping.
- `Paths.sandbox_tmp_path/1` — the inverse mapping, defined once;
  `Sandbox.sandbox_tmp_path/1` becomes a `defdelegate` (four callers:
  `Tools.scratch_note/1`, `ShellCmd.stage_script/2`, `ShellJobs.launch/3`,
  `BatchSizer.Overflow.write/4`).
- `TmpSpace.space_dir/1` stays as the host *origin*; `Paths`'s moduledoc states
  the relationship once (`TmpSpace` produces `tmp_path`; `Paths` derives the mount
  and the spelling). Do not make `Paths` depend on `TmpSpace`.
- `ShellJobs.@sandbox_tmp` → `Nest.Sandbox.Paths.sandbox_root()`.

## 2. `glob` and `stat` inside bwrap

**Delete the host walker's use**: `Sandbox.glob/5` no longer translates, walks,
filters and maps back (`sandbox.ex:416-427`); it runs one bash command inside
bwrap through `ShellCmd.execute_raw/5`. `Nest.Sandbox.Glob` becomes unused except
for `split/1` (pattern validation) — decide whether to keep it as a validator or
delete it with its tests (see §5 for the semantics the shell must reproduce).

**Glob script (bash, one bwrap call):**

```bash
shopt -s nullglob globstar dotglob
n=0
for p in <ESCAPED_PATTERN>; do
  [ -f "$p" ] || continue
  n=$((n + 1))
  [ "$n" -gt <LIMIT> ] && { printf 'nest-glob-too-broad\n' >&2; exit 3; }
  printf '%s\0' "$p"
done
```

`ShellCmd` runs `/bin/bash` (GNU bash 5.2.21 — `shell_cmd.ex:314-317`), so
`shopt`/`globstar`/`dotglob` are available. `ESCAPED_PATTERN` is the resolved
absolute pattern with every shell metacharacter backslash-escaped **except `*`
and `?`**, which preserves today's literal treatment of `[`, `]`, `{`, `}`,
`\` and `~`. Parse NUL-separated stdout, then **re-apply `Enum.sort/1` in Elixir**
(bash sorts by locale, which differs from today's binary sort). No
`FSPath.canonical/1` anywhere — bash resolves symlinks and the `/tmp` bind the
same way a shell inside the sandbox does, which is the entire point.

**Semantics that must not silently change** (today's engine, for the record):
`*` and `?` only; `**` special **only as a whole segment** and matching
*directories*; `[`/`]`/`{`/`}`/`\` are literal; dotfiles matched; results are
regular files only (symlinks to regular files count); sorted + deduped; a limit
of 1 000 pre-filter matches → `{:error, :glob_too_broad}`; a literal path matches
itself; a missing or non-directory base yields `[]` (never an error).

Two **deliberate divergences** to decide (§7):

- **Terminal `**`.** Today `dir/**` matches only directories, so the regular-file
  filter yields `[]`; with bash it lists every file recursively. (Mid-pattern
  `**`, i.e. the documented `tests/**/*_test.exs` form, is unaffected.)
- **Eager expansion.** bash materialises the whole match list before the loop, so
  the limit no longer bounds the *work*: `glob("/**")` would expand the tree.
  Mitigations: a `:timeout` on the call, `ulimit -v` in the script, or refusing
  terminal-`**` patterns.

**`stat` inside bwrap:** `stat -L -c '%s|%Y|%f' -- <escaped path>`, parsed into a
partial `%File.Stat{}`. Only **`size`** and **`mtime`** are actually read by
consumers (`inspect_file.ex:95`, `file_tools.ex:158`, `projected_size.ex:149`,
`introspection_handler.ex:370`, `file_access.ex:130`; `type`/`mode`/`inode`/…
are unused) — set `mtime` as the posix integer when `time: :posix` is requested
and as a `{{y,m,d},{h,mi,s}}` otherwise, decode `type` from the mode bits, and
document that the rest are `nil`. Return contract unchanged
(`{:ok, %File.Stat{}}` / `{:error, reason}`).

## 3. Classification, the policy, and the guards

**Classification must stop looking at the host.** `classify_read_failure/4`
(`sandbox.ex:350-357`) uses `Paths.to_host/3` + `read_permitted?/3` +
`File.exists?/1`; that is why the masked `.nest` read is reported as `:enoent`
even though `cat` said `Permission denied`. Replace it with stderr inspection
(shared by `read` and `stat`):

```elixir
String.contains?(stderr, "Permission denied")        -> :read_permission_denied
String.contains?(stderr, "No such file or directory") -> :enoent
String.contains?(stderr, "Not a directory")           -> :enoent
true                                                  -> :read_failed
```

Use `execute_raw/5` (which returns stderr separately). Expected, more truthful
behaviour changes: masked `.nest` `:enoent` → `:read_permission_denied`;
workspace-under-`/tmp` `:read_failed` → `:enoent`; a bwrap setup failure
(config 2) `:enoent` → `:read_failed` (optionally match `"bwrap:"` for a
dedicated atom). Add the warning the review asked for in `read/4`'s non-zero arm
(mirroring `log_bwrap_failure/5`, `shell_cmd.ex:239-249`) so a failed read is
never silent; ExUnit already captures Logger per test.

**State the policy in four places** (each guards a different reader):
`AGENTS.md` (new `### Sandbox reads always go through bwrap` subsection under
`## Important: Core Process Rules`, alongside the hunk that stays);
`Nest.Sandbox`'s moduledoc ("the sandbox's filesystem view is bwrap's view; there
is no host-side emulation of `read`, `stat` or `glob`"); the `file-read` /
`file-inspect` tool descriptions; and `ShellCmd.execute_raw/5`'s comment.

**Enforce it with an AST guard, not a string match.** Today's guard
(`sandbox_host_path_test.exs:85-90`) is `refute source =~ "File.read("`, which a
review defeated by reintroducing the fast path as `:file.read_file`. Replace it
with the repo's `guard_test.exs:277-320` pattern (`Code.string_to_quoted!` +
`Macro.prewalk`), scanning `lib/nest/sandbox.ex`, `lib/nest/sandbox/glob.ex`,
`lib/nest/sandbox/paths.ex`, `lib/nest/tools/shell_cmd.ex` and rejecting
`File.read/1,2`, `File.read!/1,2`, `File.stat/1,2,3`, `File.lstat/…`,
`File.ls/1`, `File.regular?/1`, `File.stream!/2,3`, `File.open/2,3`,
`File.open!/2,3`, `:file.read_file/1,2`, `:file.open/2,3`, `:file.read/2,3`,
`:file.pread/3`, `IO.read/2`, `IO.binread/2` — while allowing `File.dir?/1`
(the workspace setup guard at `sandbox.ex:303`), `File.exists?`/`File.rm`/
`File.mkdir_p!`/`File.write!` used for staging, and the `Paths` string helpers.
Mutation-verify the guard's helper against every rejected and allowed shape.
Write its honest limits in a comment (`apply/3`, an aliased `File`, `System.cmd`,
`Port.open`, a helper outside the scan set). Keep the behavioural mount test
(`sandbox_project_test.exs:77-90`): it can only pass through the mounts.

## 4. The no-op tests

Flat `/tmp/nest-tmp-…` fixtures make `Sandbox.sandbox_tmp_path(dir) == dir`, so
the pointer assertions pass for either spelling: `batch_sizer_test.exs`
`:496`, `:515`, `:538`, `:562`, `:568`, **and `:254`** (the review missed that
one), plus `batch_sizer_overflow_test.exs` `:60`, `:76`. Fix: build the real
shape (`root/space-1/agent-N`), assert `=~ Sandbox.sandbox_tmp_path(dir)` and
`refute =~ dir`, read files back via `Path.join(dir, Path.basename(path))`, and
`on_exit` the root. **Prove it:** revert `Overflow.write/4` (`overflow.ex:49`) to
return the host path — under the flat fixture the suite still passes (the no-op);
under the fixed fixture every corrected assertion fails. `batch_sizer_cap_test.exs`
asserts only `content =~ "saved to"` — same shape, no blind spot; optional.

## 5. Tests that must change

| test | verdict |
|---|---|
| `sandbox_test.exs` `describe "glob/4"` (9 tests) | **keep** — they pass with the bash implementation (`nullglob`+`dotglob`+`globstar`+escaping+Elixir sort+limit) |
| `sandbox_test.exs:462-469` "filtered to files readable under the caps" | **rewrite** — its caps omit `"/"`, so `Sandbox.build/5` errors and `ShellCmd.build_bwrap_args/3` raises; replace with a mount-based filter test (masked `.nest`, or a shadowed path) |
| `sandbox_host_path_test.exs:48-84` (bind source, glob/stat/read, "never returns the host spelling", overflow pointer) | **keep** |
| `sandbox_host_path_test.exs:85-90` source guard | **replace** with the AST guard (§3) |
| `sandbox_project_test.exs:77-90` (mount-only read) | **keep** |
| `sandbox_project_test.exs:68-74` (`write_allowed?`) | **delete** with the helper |
| `batch_plan_test.exs:71-99`, `batch_sizer_test.exs:272-315` | **keep** |
| **`agent_file_policy_test.exs` (the `check_read_policy` describe)** | **breaks — must fix**: its workspace is under `/tmp`, so after this change the shadowed workspace makes `stat` return `:enoent` and the assertions flip. Move the workspace out of `/tmp` (as `tools_test.exs:229` and `tools_scratch_path_test.exs:23` already do) and keep every assertion |

**New tests** (the "configurations" plus the review's case):
1. the canonical regression: `ln -s /tmp /tmp/<agent>/t` then
   `glob("/tmp/<agent>/t/*")` lists the **space scratch dir**, never the host
   `/tmp`;
2. config 3: workspace under `/tmp` + a real `tmp_path` → `stat` and `read` agree
   (both error);
3. config 2: `tmp` mount with an absent out-of-workspace destination →
   `stat`/`glob`/`read` all error;
4. config 1: masked `.nest` → `stat` reports a char device, `read` returns
   `:read_permission_denied`.

No test may be weakened. Post-change greps that must come back empty:
`rg 'File\.(stat|ls|regular\?)' lib/nest/sandbox.ex`,
`rg 'to_host|to_sandbox|read_source' lib/`.

## 6. Cost

One bwrap call is ~7.5–8.4 ms (bwrap startup dominates: `true` 7.3, `cat` 8.3,
`stat` 8.35, a one-pattern glob 7.57). So: `file-inspect` +8 ms,
`file-read` +8 ms, `file-write`'s policy check +8 ms, `file_access.record_stat`
+8 ms, `agents-batch`'s glob one call per invocation (not per file). **The one
place it multiplies:** `BatchSizer`'s preflight stats per `file-read` in a batch
(`batch_sizer.ex:172-174` reduces over tool calls), so K=50 adds ~0.4 s. Flag it,
and consider caching the stat inside one preflight pass.

## 7. Decisions needed before implementation

1. **Terminal `**`** — accept bash's recursive-files behaviour (a visible change,
   arguably a fix), or reject/limit terminal-`**` patterns to keep today's
   semantics?
2. **Eager expansion** — accept, add a `:timeout` on the glob call, add
   `ulimit -v`, or refuse terminal `**` (which also settles #1)?
3. **`dotglob`** — keep (preserves today's dotfile matching) or drop (adopt POSIX
   semantics deliberately)?
4. **Delete or keep** the now-dead predicates (`read_allowed?/2`,
   `write_allowed?/3`, `writable_roots/2`) and `ProjectConfig.read_source/2` +
   helpers? Deleting is cleaner; keeping them risks someone wiring them back into
   an executor.
5. **`Nest.Sandbox.Glob`** — keep `split/1` as a validator, or delete the module
   with its tests (the glob semantics move into the bash script and the
   `sandbox_test.exs` glob suite)?
6. **Workspace-under-`/tmp` shadowing** — leave as documented bwrap behaviour
   (all three operations now agree it fails), or fix the mount order (bind `/tmp`
   before the workspace) as a separate change?
7. **The `mix precommit` cap** — does it still apply to this branch, or may I
   spend one full `mix precommit` before merge?
