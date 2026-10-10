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

---

# 8. Follow-up plan: the PR #47 review

Everything above is history — the rulings, the plan and the anchors as they were
before implementation. This section is what we are doing *now*, after an
independent review of PR #47 (branch `always-bwrap` @ `0b83110`). Where the two
disagree, this section wins.

## 8.0 The ruling: no agent may ever have a workspace at or under `/tmp`

This is the headline, and it is absolute.

**Every** path that can give an agent a workspace at or under `/tmp` must fail
with a clean, user-visible error. Not "fail when a scratch bind happens to be
present", not "fail deep inside `Sandbox.build/5` with a message the model has to
parse out of a stat failure" — fail at the point the workspace is chosen, and
fail again at the last gate, because there must be no route around it:

* the create-a-space-with-root-agent path,
* the create-an-agent path (including sub-agent spawning),
* the standalone `set_workspace` path,
* the combined edit-agent path,
* and `Nest.Sandbox.build/5` itself as the final gate for anything that reaches
  the sandbox some other way.

We accept **any** blast radius. Concretely, that means:

* We do **not** special-case tests. A test that passes a `/tmp`-rooted path as a
  *workspace* moves its fixture to `_build/tmp/...` (the pattern `tools_test.exs`
  and `agent/tmp_space_test.exs` already use).
* We do **not** delete, skip, weaken or `async: false` a test to get this to
  land. Every assertion that existed keeps existing; only the fixture path
  changes.
* We do **not** leave a "for now" hole (a `nil`-scratch escape hatch, a
  `default_caps` exemption, a test-only bypass). The one temporary measure we
  do take — erroring on `fs.write` `/tmp` without a scratch dir (§8.3) — errors
  rather than silently doing nothing, and it does not create a route to a
  `/tmp` workspace.
* We do **not** split this into a second PR. All of the fallout below lands in
  this branch, in this change.
* `AGENTS.md`'s existing sentence — "A workspace can never live under `/tmp`" —
  becomes true as written. It stops being an overstatement and becomes the
  policy statement for the code we are about to write.

The technical reason is unchanged and already documented: the space scratch dir
is bound at `/tmp`, so a workspace under `/tmp` is shadowed and every
read/stat/glob silently resolves against the wrong tree. The old code only
rejected that when a scratch bind was present, which meant the failure depended
on whether the agent had a scratch dir — i.e. on unrelated state. It is now
unconditional, so the rule has one shape and one error.

## 8.1 Decision map

The review's 18 findings, and what happens to each.

| # | Finding | Decision |
|---|---|---|
| 1 | bwrap's own failures classify as `:enoent` and are never logged | New reason `:sandbox_setup_failed`; matched *before* the errno strings; logged from `read`/`stat`/`glob`; reported to the caller |
| 2 | `file-read` on a directory logs a warning and loses `:eisdir` | `"Is a directory" -> :eisdir`; not logged; tools say "Not a file" |
| 3 | A missing workspace is silently dropped by `bind_workspace/1` | Delete `bind_workspace/1`; the existence check moves into `validate_workspace/2`; `ShellCmd` returns an error instead of raising |
| 4 | The host script path is logged | **No change.** A server log line cannot reach the agent |
| 5 | The `/tmp` rule is only enforced deep in `Sandbox.build/5` | Shared `Sandbox.workspace_error/1`, called from every `:workspace_required` site, plus a JS message |
| 6 | `execute_raw`'s dead `tmp_path \\ nil, caps \\ nil` defaults | Dropped (arities 4 and 5 only) |
| 7 | Stale docs (`FSPath`, `ShellEscape`, `Sandbox`) | Fixed |
| 8 | Staging pollutes the globbed tree; the `.nest-cmd-` skip hides real files | Stage in `Paths.stage_dir/1` (`<space_dir>/.cmds/`); the glob skips the staging *dir*, not a basename prefix |
| 9 | Timeout/cancel annotations are dropped by `execute_raw` | Markers move into **stderr**; classified and logged |
| 10 | `classify_read_failure/1` matches English stderr | `LC_ALL=C` on `cat`, `stat`, and the glob script |
| 11 | The AST guard doesn't scan `shell_jobs.ex` | Added, with an explicit commented allowlist |
| 12 | `@doc false` on cross-module API | Promote the contract comments to `@doc`; keep rationale as `#` |
| 13 | BatchSizer stats one bwrap per `file-read` in a batch | A GitHub issue, **only** about the caching question, with an explicit "we are not reducing bwrap usage" note. No code change here |
| 14 | Test nits (weak `{:error, _}`, unguarded `rm_rf!`) | Fixed |
| 15 | `AGENTS.md` overstates the `/tmp` rule | **The code changes to match the policy** (§8.0) |
| 16 | The note still ends with "Decisions needed" | **No change.** It is history |
| 17 | Char devices are `:device`, block devices `:other` | Both `0x2000` and `0x6000` → `:device` |
| 18 | `fs.write` `/tmp` silently does nothing without a scratch dir | An error (§8.3) |

## 8.2 Executors, classification, staging (`lib/nest/sandbox.ex`, `lib/nest/tools/shell_cmd.ex`)

**`classify_read_failure/1` (`sandbox.ex:470`)** becomes, in order:

```elixir
String.contains?(stderr, "bwrap:")                  -> :sandbox_setup_failed
String.contains?(stderr, "Can't ")                  -> :sandbox_setup_failed
String.contains?(stderr, "Command timed out")       -> :read_timeout
String.contains?(stderr, "Command cancelled")       -> :read_cancelled
String.contains?(stderr, "Permission denied")       -> :read_permission_denied
String.contains?(stderr, "No such file or directory") -> :enoent
String.contains?(stderr, "Not a directory")         -> :enoent
String.contains?(stderr, "Is a directory")          -> :eisdir
true                                                -> :read_failed
```

The `bwrap:` check **must** come first. bwrap's own diagnostics use the same
strings as the errno cases — measured on this host:

```
$ bwrap --unshare-all --die-with-parent --new-session --ro-bind / / \
    --bind /nonexistent-dir /nonexistent-dir --proc /proc /bin/true
bwrap: Can't find source path /nonexistent-dir: No such file or directory
```

so a mode with a stale `fs.write`/`fs.project` source currently makes every
`read`/`stat`/`glob` return `{:error, :enoent}`, which the file tools render as
`"File not found: <path>"`, with nothing in the log — the exact diagnostic
`log_bwrap_failure/5`'s comment (`shell_cmd.ex:239-249`) says we must never
lose. The other bwrap shape (`bwrap: Can't mkdir parents for …: Read-only file
system`) is the one `sandbox_host_path_test.exs` already exercises; it classified
as `:read_failed` by luck, not by design.

**Logging.** Replace `log_read_failure/3` (`sandbox.ex:482-486`) with a single
`log_sandbox_failure/4` called from `read/4` (`:246`), `stat/5` (`:277`) **and**
`run_glob/5` (`:363` — stat and glob are silent today). Log `:read_failed`,
`:sandbox_setup_failed` and `:read_timeout`; stay quiet for `:enoent`,
`:read_permission_denied`, `:eisdir`, `:read_cancelled` — those are ordinary tool
outcomes, and logging them turns a common user mistake into log noise.

**Reporting to the caller.** The caller gets a fixed sentence naming the class of
problem, *not* bwrap's stderr: bwrap errors can name the host scratch path, and
the rule at the top of this note says that spelling never reaches the LLM. Full
stderr goes to the server log. Arms to add in
`lib/nest/tools/file_tools.ex` (`read_after_stat/5` `:155`, `read_file_content/5`
`:182`) and `lib/nest/tools/inspect_file.ex` (`safe_byte_size/4` `:93`,
`read_file_via_shell/4` `:267`):

* `:sandbox_setup_failed` → "The sandbox failed to start; this is a Nest
  configuration problem, not a missing file."
* `:eisdir` → "Not a file: <path>"
* `:read_timeout` / `:read_cancelled` → one short arm each.

`lib/nest/agents/agent/introspection_handler.ex:366` must treat
`:sandbox_setup_failed` like `:enoent` (`:ok`), so a broken sandbox produces the
real error from the write attempt rather than a bogus `:never_read`.

**Missing workspace is an error (item 3).** Delete `bind_workspace/1`
(`sandbox.ex:494-496`) and pass `workspace` straight through from
`read/4`/`stat/5`/`glob/5`/`run/5`/`write/5`. `validate_workspace/2`
(`sandbox.ex:504-515`) grows the existence check, and `ShellCmd.resolve_workspace/1`
(`shell_cmd.ex:309-321`) **returns** `{:error, "Workspace directory does not
exist: …"}` instead of raising, threaded through `build_command/4`'s existing
error path. This restores the moduledoc's "A non-existent workspace is rejected
before bwrap runs" — which `bind_workspace/1` had quietly made false — and it
means a stale workspace gives the agent a clean message instead of crashing the
tool worker.

**`LC_ALL=C` (item 10).** Prefix the `cat --` and `stat -L -c` commands, and
`export LC_ALL=C` as the first line of `glob_script/2` (before the `for`, whose
word list is expanded when the loop runs). Without it a non-C locale silently
degrades every classification to `:read_failed`.

**Timeouts and cancellation (item 9).** `handle_timeout/3` (`shell_cmd.ex:459`)
and `handle_stop_chat/2` (`:425`) currently hand-append the marker to the
*combined* output, which `execute_raw/4,5` discards — so a glob that hits
`@glob_timeout_ms` reports `:read_failed` with empty stderr and no log at all.
Put the marker in stderr with `append_stderr/2` and let `combine_output/1`
(`:465`) render it, so both `execute/5` and `execute_raw/4,5` see it. Accepted
consequence: `execute/5`'s text for those two paths becomes
`…\n[stderr]\n\n[Command timed out after Nms]`.

**Defaults (item 6).** `execute_raw(command, workspace_path, tmp_path, caps, opts \\ [])`
— no default on `tmp_path` or `caps`. `caps: nil` means `default_caps/0` (full
host read *plus* workspace and `/tmp` write), so a caller that forgets it must
not compile.

**`@doc false` audit (item 12).** Two in the touched files:
`execute_raw/4,5` (`shell_cmd.ex:87`) and `exit_code/1` (`:441`). Both carry real
cross-module contracts (the raw-streams contract; the `:DOWN`-reason decoding
`Nest.Sandbox.ShellJobs` shares) and become real `@doc`s. Everything that is
*rationale* rather than contract — e.g. "`--dev /dev` must come after
`--ro-bind / /`" — stays a `#` comment, because promoting rationale to docs
invites edits that break the invariant.

**Block/char devices (item 17).** `type_from_mode/1` (`sandbox.ex:455`): `0x2000`
and `0x6000` both → `:device`, matching `File.stat/1`.

## 8.3 Staging outside the globbed tree (item 8)

Today `stage_script/2` (`shell_cmd.ex:268-278`) writes into the agent's own
scratch dir, so a glob over that dir sees Nest's own transcript — hence the
basename-prefix skip at `sandbox.ex:384`, which silently hides any real file an
agent names `.nest-cmd-*`. Both halves get fixed:

* `Nest.Sandbox.Paths` gains `stage_dir/1` (host) and `stage_dir_sandbox/1`
  (sandbox spelling), so the derivation stays in the one module that owns the
  mapping:
  * scratch bind present → `<space_dir>/.cmds/`, visible inside at `/tmp/.cmds`;
  * no scratch bind → `<System.tmp_dir!()>/.nest-cmds/`, visible inside at the
    same path through the root `--ro-bind / /`.
* `stage_script/2` `mkdir_p`s that dir and stages
  `nest-cmd-<n>.sh` there. The `.` prefix existed only to hide the file from
  globs; that is now the directory's job, so the name loses it.
* `glob_script/2` replaces `case ${p##*/} in .nest-cmd-*)` with a path-scoped
  skip on the escaped staging dir: `case "$p" in <escaped dir>/*) continue;; esac`.
  A real file called `.nest-cmd-notes.sh` stops disappearing from glob results,
  and a glob over `/tmp/**/*` still cannot pick up Nest's own scripts.
* The staging dir is inside the bound space dir, so it is visible to siblings —
  which is fine, since siblings already share the whole space scratch dir. It
  must never be advertised in a tool description or a tool result.

## 8.4 Workspace policy (items 3, 5, 15, 18)

**One predicate, every entry point.** `Nest.Sandbox.workspace_error/1` returns
`:ok | {:error, :workspace_missing | :workspace_under_tmp}`. It is used by
`validate_workspace/2` (the last gate) and by the early checks at the sites that
already return `:workspace_required`:

* `lib/nest/agents/supervisor.ex:309` (create; also covers sub-agent spawning)
* `lib/nest/spaces.ex:363` (create-space-with-root-agent)
* `lib/nest/agents/agent/model_handler.ex:57-93` (combined edit)
* `lib/nest/agents/agent/workspace_handler.ex` (`{:set_workspace, path}`)
* `lib/nest/agents/agent/introspection_handler.ex` (the `{:set_workspace, _}`
  re-check)

…plus `AgentErrors.edit_payload/2`
(`lib/nest_web/channels/lobby_channel/agent_errors.ex:29`) and a
`workspace_under_tmp` case in `assets/js/utils/chatErrors.js`'s
`describeEditError` (mirroring `workspace_required`), with the matching JS
mapping test.

**Unconditional `/tmp` rejection.** `validate_workspace/2` loses the
`nil tmp_path` escape hatch at `sandbox.ex:505`. `Paths.sandbox_root/0` stays the
single source of the literal. `AGENTS.md`'s sentence needs no change — the code
now matches it; the surrounding wording gets tightened to say the rule is
unconditional, and to name the reason (the scratch bind shadows the workspace).

**`fs.write` `/tmp` without a scratch dir (item 18).** `Sandbox.build/5` returns
`{:error, "caps.fs.write lists /tmp but this agent has no scratch dir …"}`. This
is a "make the silent no-op loud" measure, not a route to a `/tmp` workspace.

`default_caps/0` (`sandbox.ex:116`) lists `"/tmp"`, and it is the fallback for
`caps: nil`, so the new check would make the legacy path error. `"/tmp"` is
inert there anyway — `append_tmp_bind/2` (`:632`) binds the scratch dir read-write
unconditionally, ignoring `fs.write` — so `"/tmp"` comes out of `default_caps/0`,
its docstring loses "and /tmp writable", and `sandbox_test.exs:16` follows.
*(Assumed; the alternative is to exempt `default_caps` from the check. Flagging
because it changes a documented constant.)*

**Not fixed here.** Because `append_tmp_bind/2` ignores caps, an agent with a
scratch dir gets a writable `/tmp` even in a read-only mode. Making that bind
conditional would take the scratch dir away from every mode that does not list
`/tmp` — including chat mode — so it is a separate product decision, not a
review fix. It gets its own TODO entry, not a second PR.

## 8.5 Test fallout — all of it, in this PR

Item 15 makes the rejection unconditional, so every fixture that passes a
`/tmp`-rooted path as a **workspace** (not as `tmp_path`) has to move to
`_build/tmp/...`. Known list; a grep sweep for
`ShellCmd.execute(_, <ws>, …)`, `Sandbox.{build,run,read,stat,glob,write}(…, <ws>, …)`,
`Tools.get_function(name, <ws>, …)` and `workspace_path:` completes it:

* `test/nest/tools/shell_cmd_test.exs` — `"/tmp"` as the workspace at `:37`,
  `:55`, `:112`, `:117`, `:120`, `:160`, `:167`; the `:bwrap` symlink fixture
  (`:68-92`); the large-stdin fixture (`:177-179`); the staged-script test
  (`:122-158`) for the new staging dir. `:93-100` flips from `assert_raise` to
  asserting the returned error, keeping the "never auto-created" assertion.
* `test/nest/sandbox_test.exs` — the top-level `setup`'s `dir` (it feeds the
  glob describe's `root`, which is passed as the workspace at `:431`, `:451`,
  `:462`); `:16` (`default_caps` map); `:246` inverts from "allows a workspace
  under /tmp when no scratch bind is present" to asserting rejection. New test
  for `/tmp`-in-`fs.write` without a scratch dir.
* `test/nest/sandbox_project_test.exs` — `setup`'s `dir`.
* `test/nest/agents/agent/batch_plan_test.exs` — `setup`'s `dir` (used as
  `workspace_path`).
* `test/nest/tools_edit_test.exs`, `test/nest/tools_inspect_file_test.exs` —
  `setup`'s `dir` (passed to `Tools.get_function/3` as the workspace) **and**
  drop `"/tmp"` from the permissive `write` caps (item 18; `"/"` already covers
  them).
* `test/nest/tools_test.exs` — no change: it only *builds* tools with `"/tmp"`,
  and its `test_workspace` is already `_build/tmp`.

New/updated tests for the rest:

* a directory read is `:eisdir` and does **not** log;
* a bwrap setup failure reports `:sandbox_setup_failed` and **does** log (the
  existing "config 2" test in `sandbox_host_path_test.exs` asserts the log for
  `read`; it extends to `stat`/`glob`);
* a timeout/cancel annotation reaches the caller (this is what locks in item 9;
  there is no test for `ShellCmd`'s own timeout path today);
* the staging dir is where it says it is, and the file is gone afterwards;
* an early rejection for each entry point (create-space, create-agent,
  `set_workspace`, edit-agent), plus the JS message mapping.

Item 14, in the same pass: the workspace-under-`/tmp` test in
`sandbox_host_path_test.exs` asserts the rejection *message* instead of
`{:error, _}` (so an unrelated failure cannot pass it), and the two unguarded
`File.rm_rf!`s on lines this PR touched get the `String.contains?` guard
SMELLS.md requires — `test/nest/agents/agent/batch_sizer_test.exs:214` and
`test/nest/agents/agent_file_policy_test.exs:329`.

## 8.6 AST guard (item 11)

`test/nest/sandbox_host_path_test.exs`'s `@sandbox_sources` gains
`"lib/nest/sandbox/shell_jobs.ex"`, which does `File.read/1` on the job log at
`:559`. That read is benign — the log is Nest's own artifact, written by Nest,
and the mount exposes the same bytes — so the guard gets an explicit, commented
allowlist instead of an exclusion. Offenders drop their line number and become
`{module, fun}`, asserted as an exact sorted list (currently
`[{:file, :read}]` for `shell_jobs.ex`), so a *second* host read in that file
still fails the guard while ordinary refactors do not.

## 8.7 Docs (item 7)

* `lib/nest/fspath.ex`'s moduledoc still describes "the sandbox rule helpers" and
  "the read-only host fast-path in `Nest.Sandbox`" — both deleted. Rewrite around
  what is left: canonicalization for bind sources, and containment.
* `lib/nest/tools/shell_escape.ex`'s moduledoc says it serves "the `file-read`,
  `file-write`, and `file-edit` tools"; it now also serves `Sandbox.read/4`,
  `Sandbox.stat/5` and the glob script.
* `Nest.Sandbox`'s moduledoc: the "Missing paths" paragraph must match §8.2
  (a missing workspace errors), and the caps section must say `/tmp` in
  `fs.write` needs a scratch dir (§8.4). The "Executors" section must mention the
  new classification.
* The `fs.write` `/tmp` bullet wherever modes are documented, and
  `default_caps/0`'s docstring.

## 8.8 The one issue we file (item 13)

A GitHub issue, **only** about the BatchSizer question, with the bwrap-usage
non-goal stated in the body: `ProjectedSize.read_file_projection/2`
(`lib/nest/agents/agent/batch_sizer/projected_size.ex:141`) calls `Sandbox.stat/4`
once per `file-read` in a batch, so K=50 adds ~50 bwrap spawns (~8 ms each,
~0.4 s). The question is whether one preflight pass can share a stat (or bound
how many it takes). Explicitly **not** in scope: going back to a host-side read
or stat for anything, for any reason.

## 8.9 Verification

* One full `mix precommit`, read end to end, output under `notes/test-runs/`.
  The suite currently runs 2066 tests in 3.9 s / 3.5 s; the new bwrap calls per
  read/stat must not push it past the host budget in
  `scripts/precommit-test.sh`.
* Post-change greps that must come back empty:
  `rg 'File\.(stat|ls|regular\?)' lib/nest/sandbox.ex`,
  `rg 'to_host|to_sandbox|read_source' lib/`,
  `rg '"/tmp"' test/` (no `/tmp` workspace left).
* Coverage stays ≥85% and rises; the new classifier arms and `Paths.stage_dir/1`
  are the lines to cover, and the timeout/cancel test plus the
  `/tmp`-write-without-scratch test are the cheap wins.

## 8.10 Open, still

1. **`default_caps/0`** (§8.4) — assumed: drop `"/tmp"` from it, update its
   docstring and `sandbox_test.exs:16`. The alternative is exempting
   `default_caps` from the new `/tmp`-write check. Say which.
2. **The unconditional `append_tmp_bind/2`** (§8.4, "Not fixed here") — assumed:
   a TODO entry, no code change in this PR.
