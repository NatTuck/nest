# Issue #21 — the `async: false` audit

An audit of every `async: false` Elixir test module in the suite, asking one
question per file: **is the shared state that forces the module out of the
concurrent phase intrinsic to what the test is about, or is it incidental?**

Ten modules were `async: false` when the audit ran. It found that in **seven**
of them the forcing global was incidental — and, in most cases, that the
module's own written justification for being sync was factually wrong.

- Branch: `issue-21-async-kills`, based on `origin/main` = `3f4c0ec`.
- Worktree: `tmp/wtasynckill`.
- 7 modules converted to `async: true`; 1 left sync as **JUSTIFIED**; 2 left
  sync as **MANUAL-REVIEW** (they need a human call on churn, not a rework).

| # | module | class | outcome |
|---|---|---|---|
| 0 | `test/mix/tasks/nest/repair_messages_test.exs` | KILL | ✅ async — `Mix.shell` injected |
| 1 | `test/nest/models_test.exs` | **JUSTIFIED** | stays `async: false` (see below) |
| 2 | `test/nest/timeline_test.exs` | **MANUAL-REVIEW** | stays `async: false`; split proposed |
| 3 | `test/nest/hostname_test.exs` | KILL | ✅ async — override injected |
| 4 | `test/nest/agents_auto_name_test.exs` | KILL | ✅ async — nothing was ever forcing it |
| 5 | `test/nest_web/surgical_reloader_test.exs` | KILL | ✅ async — made deterministic |
| 6 | `test/nest_web/channels/lobby_channel_rescan_models_test.exs` | KILL | ✅ async — private-mode Mimic |
| 7 | `test/nest/agents/agent_context_limit_test.exs` | KILL | ✅ async — cache tier injected |
| 8 | `test/nest_web/channels/lobby_channel/providers_test.exs` | KILL | ✅ async — path injected |
| 9 | `test/nest/agents/agent/timeline_emitters_test.exs` | **MANUAL-REVIEW** | stays `async: false`; split proposed |

Result: **3 of 10 modules remain `async: false`**, down from 10.

---

## The recurring finding

Every single kill had the same shape. The shared state was **never an intrinsic
resource** — never a real OS resource, never a database, never a file lock. It
was one of exactly three things:

1. **Mimic global mode** (`setup :set_mimic_global`) — which pins the module for
   a purely mechanical reason: `Mimic.set_mimic_global/1` *raises* when the case
   is async, so the setup line itself, not any real global, is what pins the
   file. (`lobby_channel_rescan_models_test`, `agent_context_limit_test`.)
2. **An `Application.put_env` write** to a test-only seam.
   (`hostname_test`, `lobby_channel_providers_test`.)
3. **A VM-global write to `Mix.State`** via `Mix.shell/1`.
   (`repair_messages_test`.)

The repo already had the escape hatch for each of these, and in several places
was already using it:

- `Mimic.allow/3` where the calling pid **is** known (used at
  `test/support/agent_test_helpers.ex` and `agent_turn_test_helpers.ex`).
- Injection — a documented, defaulted extra arity — where the pid provably
  **is not** knowable (`agent_context_limit_test`, where `init/1` runs in a
  supervisor-spawned child with `$callers == nil`).

The audit's secondary finding is worth recording on its own: **several modules'
stated reasons for being sync were false.**

- `agents_auto_name_test` named `Supervisor.generate_unique_name/0`,
  `Registry.list()` and `Persistence.list_agent_names()` — none of which exist.
  The real functions are `generate_unique_name_for_space/1`,
  `Registry.list_for_space/1` and `Persistence.list_agent_names_for_space/1`,
  and they are per-space, not per-BEAM.
- `surgical_reloader_test`'s watcher-sharing story cannot happen: no `:name` is
  passed to `FileSystem.start_link/1`, so every test gets its own anonymous
  watcher.
- `repair_messages_test`'s "these tests cannot run with each other" is vacuous —
  ExUnit serialises tests *within* a module regardless of `async`.

---

## The 7 kills

### 0. `test/mix/tasks/nest/repair_messages_test.exs`

**Forced by:** `Mix.shell/1`, a VM-global write to the named public ETS table
`Mix.State`. The test swapped in `Mix.Shell.Process` so it could assert on the
task's output; that swap is visible to every other test in the VM.

**Fix:** `Mix.Tasks.Nest.RepairMessages` gained `run/2`, taking the shell as an
argument (`run/1` stays the `@impl Mix.Task` callback and forwards
`Mix.shell()`). `execute/2` became `execute/3` and calls `shell.info/1` instead
of `Mix.shell().info/1`. The test passes `Mix.Shell.Process` explicitly at all
five call sites; the global swap is gone. CLI behaviour is unchanged.

### 3. `test/nest/hostname_test.exs`

**Forced by:** an app-env write to `:nest, :hostname`, read back by
`Nest.Hostname.get/0` and, during rendering, by
`lib/nest_web/components/layouts/root.html.heex`.

**Fix:** `Nest.Hostname` gained a documented `get/1` that takes the override
directly; `get/0` is now a one-line wrapper and remains the only reader of the
global. The tests call `get(nil)` / `get("")` for the fallback and `get("vampire")`
for the override — no `put_env`/`delete_env` anywhere. `get/0`'s call sites are
untouched.

### 4. `test/nest/agents_auto_name_test.exs`

**Forced by:** nothing. This is the clearest case in the audit: the file was
sync purely on the strength of a justification describing functions that do not
exist and a scope the code does not have.

**Fix:** `async: true` and a moduledoc rewritten against the real API. The file
contains **no** `stub`/`expect`/`allow` call at all — only a vestigial
`import Mimic` (`:24`) and `setup :verify_on_exit!` (`:30`), which are no-ops
when nothing is stubbed and therefore force nothing. It was never the forcing
factor.

### 5. `test/nest_web/surgical_reloader_test.exs`

**Forced by:** nothing intrinsic. See *Divergences* below — the audit's proposed
one-line flip was **not** sufficient, and the module needed a real fix.

**Fix:** `async: true` plus a deterministic guard. The test now sets
`compiling: true` on the reloader's state (`:sys.replace_state/2`) *before*
sending the file event, so the 100 ms debounce timer firing is harmless:
`handle_info(:do_compile, ...)` only compiles — and only clears
`pending_changes` — when `compiling` is false. The compile path, which would run
a real global `Mix.Task.run("compile.elixir", ...)`, is now unreachable. The
assertions are unchanged; the now-unused `capture_log` wrapper was removed.

### 6. `test/nest_web/channels/lobby_channel_rescan_models_test.exs`

**Forced by:** `setup :set_mimic_global`, needed to stub `Nest.Models` from the
channel process.

**Fix:** the stub is now scoped with `Mimic.allow(Nest.Models, self(),
socket.channel_pid)` before each push — private mode, no global. The two PubSub
broadcast helpers were replaced by functions that `send` the identical tuples
straight to `socket.channel_pid`, so the test asserts on consumption without
publishing to the global `"models"` topic. A stale `lobby_channel.ex:89`
reference was corrected to `:107`.

### 7. `test/nest/agents/agent_context_limit_test.exs`

**Forced by:** Mimic's VM-wide mode row, because the stubbed call happens inside
the agent's `init/1` — a supervisor-spawned child with `$callers == nil`, so
`Mimic.allow/3` is not an option (it needs the pid, and init runs before
`start_supervised!` returns).

**Fix:** the cache tier is parameterised. `Init.initial_context_limit/2` takes a
`cache_lookup` fun defaulting to `&Nest.Models.context_limit/2`, and
`build_vocation_pipeline/1` reads an optional `:context_limit_lookup` attr. The
other four call sites (`agent.ex`, `model_handler.ex`, `agent_compaction.ex`)
keep the default and are untouched. The test injects the lookup through
`start_probe_agent/1`'s attrs; the closure runs in the child's init and messages
the test pid, so all five assertion sets hold verbatim. The Olla test's
`create_client_config` stub also went, replaced by a model name that resolves in
`test/data/config.toml`. See *Divergences* for the judgement call.

### 8. `test/nest_web/channels/lobby_channel/providers_test.exs`

**Forced by:** `Application.put_env(:nest, :local_config_file, ...)` — a
test-only seam that happens to be process-global, and a **demonstrated
cross-module flake source**: while this file's temp `local.toml` exists, the
`merge_configs/2` rule makes its providers table authoritative for the whole
map, so `dot_config_test.exs` and `lobby_channel_test.exs` (both already
`async: true`) see only `{exposed}`/`{acme}` instead of the real catalog.

**Fix:** one production line — `lib/nest/dot_config.ex:167` now calls
`load(__MODULE__.local_file())` instead of a bare local call, so the internal
call goes through Mimic's proxy rather than the renamed original (Mimic renames
a copied module by rewriting only its `:module` attribute, so the expanded
`__MODULE__` atom survives while a local call does not). The test stubs
`Nest.DotConfig.local_file/0` to return its own temp path and passes that path
around; the app-env write is gone. `Mimic.allow/3` for `Nest.DotConfig` and
`Nest.Models` is installed in the `handle_in` describe's setup, so no test can
reach a real `rescan/0` (which would run a live HTTP scan and broadcast on the
global `"models"` topic).

---

## The 1 justified: `test/nest/models_test.exs`

**Stays `async: false`, and should.** This is the one file where the shared
state *is* the subject. `Nest.Models` is a process-global singleton GenServer
started once in the application supervision tree; the file asserts on the merged
catalog the singleton builds from `test/data/config.toml` plus a real scan, on
real `{:models_updated, _}` / `{:models_scan_complete, _}` broadcasts, and on
per-scan request counts. Two of its forces are irreducibly cross-process: the
HTTP under test is performed by the singleton's detached `Task.Supervisor`
child, and `DotConfig.load/0` is invoked from inside the singleton's
`handle_call` — neither is the test pid, so a private Mimic stub cannot
intercept either. It also mutates `state.static_config` (restored in `on_exit`),
which is only possible because the singleton is shared.

The only async route is architectural: give `start_link` a name parameter, plus
the task supervisor name and the PubSub topic, and thread a server argument
through the twelve `Models.*` call sites in seven lib modules — i.e. change the
production API purely for test isolation, which would *reduce* what is tested
(it would stop testing the real app-wide catalog). Per the mandate, that is not
a KILL.

---

## The 2 needing a human decision

Both of these are **over-broadly sync**, not wholly so. The fix in each case is
a **file split**, which the audit declines to make unilaterally because it is
churn a human should sign off on. In both, every assertion survives the split.

### 2. `test/nest/timeline_test.exs`

Genuinely sync: `describe "enablement"` tests the *resolution order of two
process-global config sources*, so it must mutate `System.put_env` + app env;
`describe "recording"` needs `record/4` to find its directory, and in production
`record/4` is called from arbitrary agent processes that hold no directory; and
the `run/1` test needs `Mix.shell/1` plus `base_dir/0`.

Not genuinely sync: the redaction, digest, `Timeline.load/1` and `parse_args/1`
tests touch no global at all — they are sync only because the module-level
`setup` mutates `:nest, :timeline_dir` for every test in the file.

**Proposed split:** move `describe "redaction"`, `describe "the digest"`, the two
`Timeline.load/1` tests and the pure `parse_args/1` test (~200 lines,
mechanical) into a new `test/nest/timeline_digest_test.exs` with `async: true`
and a locally-built unique temp dir. Optionally also the `latest_run/0` test,
via a 3-line `Timeline.latest_run/1` parameterisation. The residual ~7 tests
cannot go async at any price. Two hazards confirm the split is the ceiling, not
a shortcut: an async version of this file would race
`timeline_emitters_test.exs`, which sets the same two keys; and the invalid-dir
test disables under a *fixed* `:persistent_term` key that outlives the test.

### 9. `test/nest/agents/agent/timeline_emitters_test.exs`

Same mechanism: the directory and the enable flag are per-OS-process globals
read at call time by processes the test does not own.

**Proposed split:** 6 of its 8 tests can go async (~45 lines moved, no assertion
lost) by moving the dir/enable setup to a module-scoped `setup_all` directory
with a `setup_all` `on_exit` — the per-test `rm_rf` of a run directory siblings
are appending to is the one thing that must go. The 2 remaining tests are the
ones whose *subject* is the global's hostile value (`:timeline_enabled` false →
"the emitters build nothing and write nothing"; `:timeline_dir` = `:not_a_dir`),
and they must stay sync because their whole point is that they globally stop or
poison recording — they would silently blank every concurrent sibling's records.
Residual risk to verify when implementing: `events/0` asserts `problems == []`
on a file siblings now append to concurrently; each event is a single
`File.write!(path, [json, "\n"], [:append])` so lines do not interleave, but if
that flakes it should be narrowed (filtered), not reverted to sync.

The alternative — parameterising the writer (`Timeline.record/5`, or a
`timeline_dir` field on `Agent.t()`) — touches `lib/nest/timeline.ex`,
`lib/nest/agents/agent/timeline.ex` (3 `record/4` sites + 6 `enabled?/0`
checks), all 6 emitter call-site files, the agent state and `Agents.create_agent`
opts, and contradicts the module's documented design. Not recommended.

---

## Divergences from the audit

1. **`surgical_reloader_test` — the audit was wrong, and the implementer
   overrode it.** The audit proposed a one-line `async: true` flip, on the
   strength of a measured ~1000× margin (94.9 µs vs the 100 ms debounce). But
   that is a *probabilistic* argument, which AGENTS.md explicitly disallows for a
   test that can sometimes fail: if the debounce timer fires before the test
   reads state, `handle_compilation_success` clears `pending_changes` and the
   assertion fails. The deterministic fix (`compiling: true` set before the file
   event) was applied instead. The audit was right that the `Mix.Task.run`
   compile path is a real global; under `mix test` it is a `:noop`, so the
   consequence would have been a flake rather than a stray compile.

2. **`hostname_test` — the audit missed a consequence of its own rework.**
   Making that module async falsified a comment in
   `test/nest_web/controllers/page_controller_test.exs:21-25`, which claimed the
   only writer of `:nest, :hostname` was a deliberately-sync `Nest.HostnameTest`
   running in the serial phase. Both clauses became false. The comment was
   rewritten to the (true) statement that nothing in the suite mutates that
   config any more. Fixing it was in scope: the false comment was created by
   this change.

3. **`agent_context_limit_test` — a judgement call on a test-only seam.** The
   rework adds an optional `:context_limit_lookup` attr to the agent's attrs.
   The audit flagged that if the project rejects test-only injection seams in
   `lib/`, this degrades to MANUAL-REVIEW, because the only test-side
   alternative (asserting `Init.initial_context_limit/1` in the test process)
   would drop the `Agent.init/1` → `llm_metrics` wiring the file claims to pin,
   which the mandate forbids. The judgement made here: accept it. The injected
   value is a plain 2-arity lookup with exactly one production call site. The
   nearest existing precedent, `Nest.Hardware.hpu_device_paths/2`, **exists but
   the analogy is loose**: it injects *data* and has no production caller of its
   extra arity, whereas this injects *a function* and its default arity has four
   production callers. The exact analogue is `Nest.Hostname.get/1`, added in
   this same branch for the same reason. **If reviewers disagree, this file
   reverts to `async: false` and nothing else changes.**

4. **`lobby_channel_providers_test` — the audit's production change was taken
   as specified, and extended.** The required change is a genuine
   behaviour-preserving one (a self-remote call instead of a local call, to
   defeat Mimic's module rename), verified against
   `deps/mimic/lib/mimic/module.ex`. Review additionally required **deleting the
   now-dead `:nest, :local_config_file` app-env seam** in `local_file/0`: after
   the stub replaced it, nothing anywhere read or wrote that key, so the
   `case`'s `path -> path` clause was unreachable and had silently become an
   uncovered line. Removing it recovers the line and removes dead code, which
   AGENTS.md explicitly endorses. `local_file/0` stays **public** (the
   `__MODULE__.` remote call depends on it). **If the team refuses the
   self-remote call, this file degrades to MANUAL-REVIEW** — the app env cannot
   be scoped from the channel process by any test-side means.

---

## A flake found during review — and fixed, not tolerated

The first full `mix test --cover` run after the conversions failed once:

```
1) test handle_in(save_providers) persists the providers to local.toml and broadcasts providers_updated
   test/nest_web/channels/lobby_channel/providers_test.exs:139
   Assertion failed, no matching message after 100ms
   The process mailbox is empty.
   code: assert_receive %Phoenix.Socket.Reply{ref: ^ref, status: :ok, payload: %{}}
   stacktrace:
     test/nest_web/channels/lobby_channel/providers_test.exs:153: (test)
```

**Cause.** `assert_reply ref, :ok` at `:153` expands to that `assert_receive`
with ExUnit's **implicit 100 ms** default. That test is the only one in the file
whose `handle_in` does real work before replying — `Writer.save_providers/1`
writes `local.toml`, `DotConfig.load/0` parses TOML, and the handler broadcasts
before replying — and the file is now `async: true`, so it competes with 23
other tests. `mix test --cover` instruments every module, which slows that path
further. It had passed six or more earlier runs, including two `--cover` runs at
load ~5; the failing run was at load 8.4 → 10.5. Since `mix test --cover` **is**
the coverage gate, this could not be left as "a load flake".

**Fix (deterministic, no timeout bump).** The test now synchronises on the
channel process with `:sys.get_state(socket.channel_pid, 500)` — the idiom this
same file already uses in `refute_no_reply/2` — and asserts with an explicit `0`
timeout. A second barrier covers the `providers_updated` push, which reaches the
test one channel turn later: `Nest.PubSub` is started with no `:dispatcher`, so
`Phoenix.PubSub.broadcast/4` delivers to local subscribers with `send/2` from
the broadcasting process — the channel enqueues the `%Broadcast{}` in its own
mailbox while `handle_in/3` runs, so a second `:sys.get_state` (ordered after
it) guarantees the push has been forwarded. Both assertions are therefore true
with no timing window. Assertion semantics are unchanged: same ref, same `:ok`,
same `%{}`, same event, same provider and file assertions. (The barrier itself
is bounded at 500 ms — see *Host-load contention* below for what happens to it
when the host is at load 16.)

**Checked and left alone:** the file's other `assert_reply`/`refute_push` calls
sit on handlers that return before any I/O (`forbidden`, two `invalid_payload`s,
`does not broadcast on failure`), and the `init` / `broken_agents_updated` pushes
are already in the mailbox when `subscribe_and_join/3` returns. The other six
converted files have no implicit-timeout channel assertion on a slow handler.

## Timeout caps

A new hard constraint — "any timeout in the tests, implicit or explicit, gets
lowered to 2000 ms and no higher" — was applied to every test file this branch
touches. Every bare `:sys.get_state/1` and `:sys.replace_state/2` was given an
explicit timeout: **`500` for reads** (consistent with SMELLS.md's 500 ms rule)
and **`500` for the `:sys.replace_state` writes** as well. Nothing in these files
now exceeds 2000 ms, and no timeout was *raised* to make anything pass. OTP's
default for both `:sys.get_state/1` and `:sys.replace_state/2` is 5000 ms, so
every one of these is a tightening.

Two timeouts in these files were deliberately **left alone** because they are
pre-existing values this branch did not introduce:
`lobby_channel_rescan_models_test.exs:102`'s `assert_push "broken_agents_updated", …, 1_000`
(verified against `eba4dc1`) and the implicit `assert_reply`/`assert_push`
defaults in handlers that return before doing any I/O.

---

## Verification

All logs are under `notes/test-runs/` (gitignored); every one was read whole.

- **Five full suite runs, all green, before the review round:** seeds 137 / 4242
  / 90210 → **2369 tests, 0 failures** (6.8 s / 7.2 s / 7.2 s), no logger output;
  plus `full-after-fixes.log` and `flake-full.log`, both **2369 / 0**. All 7
  converted modules land in the async phase (the sync phase is 0.1 s).
- **Coverage gate** (`mix test --cover`) — **[TOTAL] 87.4%**, above the floor.
  Both lines the review flagged as lost are recovered:

  | file | before | after |
  |---|---|---|
  | `lib/mix/tasks/nest.repair_messages.ex` | 92.0%, 25 relevant, **2** missed | 95.8%, 24 relevant, **1** missed |
  | `lib/nest/dot_config.ex` | 80.2%, 142 relevant, 28 missed | 80.7%, 140 relevant, 27 missed |

  The one remaining miss in `repair_messages.ex` is the pre-existing `validate/2`
  "use either `--space` … or `--all`, not both" branch, unrelated to this change.
- `mix compile --warnings-as-errors` — clean, dev and test env.
- `mix credo --strict` — 5161 mods/funs, found no issues.
- `mix format --check-formatted` — clean.
- `cd assets && node lint-file-size.mjs` — OK, no source file exceeds the caps.
- No assertion was removed, renamed, split, disabled, downgraded or replaced in
  any of the 7 converted files — 8 test files in total, since
  `page_controller_test.exs` is the eighth (comment-only). Every pre-change
  `assert*`/`refute*` line is still present and still tests the same thing; the
  only net addition is one extra `Nest.Hostname.get/1` override assertion (the
  fallback assertions were kept). A reviewer re-derived this mechanically, by
  extracting every `assert*`/`refute*` line from `HEAD:<path>` and from the
  working tree and diffing the sets, as well as by reading.

### Host-load contention — reported, not papered over

Four of the runs were made against a host that other agents were also running
suites on. Two came back **red, purely on load-induced timeouts**:

| run | load avg | result |
|---|---|---|
| `final-full.log` | 5.88 → 6.74 | 2369 / 0 |
| `final-cover.log` | 8.41 → 10.49 | 2369 / **1** — `providers_test.exs:153`, the implicit 100 ms default |
| `final2-full.log` | 7.79 → 10.36 | 2369 / **2** — both in files this branch never touches |
| `final3-cover.log` | 12.08 → 15.79 | 2369 / **1** — the 500 ms barrier itself |

The two failures at load 10.36 are `agent_compaction_preflight_test.exs:56` and
`empty_response_reprompt_test.exs:46` — neither file is in this branch's diff,
both are pre-existing `async: true` modules, and both are bare 500 ms
`assert_receive` waits on a completed agent turn. Run in isolation they pass
(**6 tests, 0 failures**), as does `providers_test.exs` alone (**8 tests, 0
failures**). Everything passed in every run at load ≤ 9.9.

So the suite is not green at host load ≥ 10, and that is already true of files
this branch does not touch. One honest caveat: converting 7 more modules to
async raises sustained concurrency toward ExUnit's 24-case cap, which is
plausibly what tips other files' tight waits over at high load. That is a
property of the whole async suite — issue #21's territory, and `cap-enforcer`'s
sweep — not something this branch should fix by raising timeouts, which
AGENTS.md forbids and the new rule caps at 2000 ms anyway.

The `providers_test` barrier was therefore left at **500 ms** (the project's read
cap) rather than raised to 2000: it is strictly more robust than the 100 ms
default it replaced, and a green suite at load 16 would not have been achieved
by raising it in any case.

### Latent shared state the conversions exposed, checked and found clean

- `Nest.DotConfig`'s named public ETS cache (`:nest_dotconfig_cache`) is now
  written by the *channel* process, but keys are `{path, mtime}` with a per-test
  unique path, so it cannot collide with the shared `test/data/config.toml`
  entry.
- Mimic's `allow` rows live in the shared ETS table that `Mimic.Coordinator`
  owns, keyed `{allowed_pid, module}`. They are cleared by
  `Mimic.Server.clear_data_from_pid/2`, reached either from `Mimic.Server`'s
  `:DOWN` handler (`deps/mimic/lib/mimic/server.ex:188`) or from `Server.exit/1`
  on the `on_exit` path (`:182`). `Mimic.Coordinator` itself has **no** delete
  path. When `verify_on_exit!` is in play the `:DOWN` handler deliberately skips
  that pid (`:189-192`), leaving reaping to the `on_exit` path.
- `:nest, :hostname` is now read-only suite-wide.
- The `"models"` topic has no producer in the async phase (`models_test.exs` is
  sync, `Nest.Models`'s startup scan is skipped in test, and `providers_test`
  stubs `rescan`).
- **One latent global write this conversion *does* introduce**, recorded rather
  than hidden: `Mix.Shell.Process.info/1` → `print_app/0` →
  `Mix.Shell.printable_app_name/0` writes `Mix.ProjectStack`'s `io_done` key,
  and `repair_messages_test` now calls that from the async phase. It is inert
  today only because `Mix.Tasks.Test` has already set `io_done: true` and
  nothing in the suite pushes a project onto the stack.
- The `lobby`-topic broadcast at `lobby_channel/providers.ex:49` now reaches
  every concurrently-joined lobby socket. Verified inert: the only
  `providers_updated` assertion anywhere is in the same module, and every other
  `refute_push`/`refute_receive` in the lobby tests names a different event.
- `agents` uniqueness is `[:space_id, :name]`, not global, so
  `agents_auto_name_test`'s fixed name cannot collide across concurrent tests.

### Known observations, not blockers

- The suite runs in ~7 s here, above the 5 s target in AGENTS.md. This is
  **not** attributable to these changes — the sync phase is 0.1 s, so the
  conversion moved work *into* the concurrent phase — but the target is
  currently missed and that is worth a look separately.
- `Mix.Tasks.Nest.RepairMessages.run/1`'s coverage was **recovered, not waived.**
  The two-clause form (a `run/1` delegate plus `run/2`) left `run/1`'s body line
  uncovered, because no test calls it — calling it would re-introduce the
  `Mix.shell/1` global write this change exists to remove. The fix is a single
  clause, `def run(args, shell \\ Mix.shell())`: with a default argument there is
  no separate `run/1` body line, and the generated delegate shares the `def`'s
  line, which the five `run/2` call sites cover. **A suspected `@impl Mix.Task`
  ambiguity with a default argument was checked and does not exist** —
  `mix compile --warnings-as-errors` is clean, the `Mix.Task` `run/1` callback is
  still generated and satisfied, and the abstract code confirms both `run/1` and
  `run/2` are attributed to the same line.
