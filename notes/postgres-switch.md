# Switch from SQLite to PostgreSQL

Default DB switched from SQLite to PostgreSQL. The original
plan was to flip DB-using tests from `async: false` to
`async: true` since Postgres's sandbox supports concurrent
transactions (SQLite's doesn't — see
`test-refactor.md:200-216` for the SQLite-era history).

## Final async state

**Not as many async tests as hoped.** The Ecto SQL Sandbox's
`{:shared, pid}` ownership mode is REPO-WIDE — only one process
can hold it at a time (deps/db_connection/lib/db_connection/ownership/manager.ex:148-159).
The agent's `init/1` queries the DB via
`fetch_vocation_config/3` when a `vocation_id` is passed, so it
needs `shared: true` checkout (the test process can't `Sandbox.allow`
the agent pid before `start_supervised!` returns — `init/1` runs
synchronously inside that call). With many async tests all
trying to acquire shared mode concurrently, only the first
succeeds; the rest get `:already_shared`.

So agent tests that pass `vocation_id` stay `async: false`.
Tests that don't pass `vocation_id` (no DB work in `init/1`)
and tests that talk to the DB directly in the test process
are now `async: true`. Net win: more concurrent tests than
before, but not all.

## Files changed

### Deps / config
- `mix.exs`: `ecto_sqlite3` → `postgrex ~> 0.19`. `mix.lock`
  drops `ecto_sqlite3`, `exqlite`, `elixir_make` on
  `mix deps.unlock --unused`.
- `lib/nest/repo.ex`: `Ecto.Adapters.SQLite3` →
  `Ecto.Adapters.Postgres`.
- `config/dev.exs`: file-path DB → `username: $USER`,
  `socket_dir: "/var/run/postgresql"` (peer auth via unix
  socket — TCP requires a password the role doesn't have),
  `database: "nest_dev"`.
- `config/test.exs`: same shape, `database: "nest_test"`,
  `pool_size: 20`, `ownership_timeout: 30_000`.
- `config/runtime.exs`: prod now reads `DATABASE_URL`
  (standard 12-factor). `DATABASE_PATH` is gone.

### Migration
- `priv/repo/migrations/20260528172450_create_vocations.exs`:
  edited in place. `tools` is now `{:array, :string}` (Postgres
  `text[]`) to match the schema at
  `lib/nest/vocations/vocation.ex:21`. `modes` stays `:map`
  (Postgres `jsonb`).

### Test async conversions
| File | Before | After |
|------|--------|-------|
| `test/nest/vocations_test.exs` | `false` | `true` |
| `test/nest/chat_model_test.exs` | `false` | `true` |
| `test/nest/agents/agent_tools_test.exs` | `false` | `true` |
| `test/nest/agents/agent_observability_test.exs` | `false` | `true` |
| `test/nest/agents/agent_agents_md_test.exs` | `false` | `false` |
| `test/nest/agents/agent_chat_test.exs` | `false` | `false` |
| `test/nest/agents/agent_compaction_test.exs` | `false` | `false` |
| `test/nest/agents/agent_system_prompt_composition_test.exs` | `false` | `false` |

The four `async: false` modules use `vocation_id` in
`start_agent/1` and need `shared: true` checkout for the
agent's `init/1`. They stay sync.

Stays `async: false` (unrelated to DB):
- `test/nest/agents/agent_tmp_path_test.exs` — `/tmp/nest-VMPID/`
  is shared per BEAM VM; concurrent cleanup races.
- `test/nest/agents_test.exs` — supervisor / registry lifecycle.
- `test/nest/agents/agent_context_limit_test.exs` — Mimic stubs
  `Req.get/2` from a `Task.Supervisor` child; per-process Mimic
  scope + async-mode rejection of `set_mimic_global` makes this
  fundamentally async-unsafe.

### `:db_shared` tag
Kept and documented in `test/support/data_case.ex`. The opt-in
mechanism stays as a safety hatch for tests that need shared
mode but only run one at a time (e.g. a future test that wants
shared mode without async).

### Test sandbox setup
`test/support/data_case.ex` moduledoc updated to drop the
"not recommended for other databases" caveat. The setup logic
is unchanged: `shared = tags[:db_shared] || not tags[:async]`.

### Cleanup
- `db/` directory and `db/.gitkeep` removed.
- `.gitignore` keeps the `*.db` and `*.db-*` lines as a
  defensive measure.

## Auth model

Local dev / test connect via peer auth through
`/var/run/postgresql/.s.PGSQL.5432` as the current OS user
(`System.fetch_env!("USER")`). The role must have `CREATEDB`
privilege (verified locally). No password needed for local
unix-socket connections.

Prod uses `DATABASE_URL` so any cloud-managed Postgres works
without code changes.

## Future work

To fully enable async tests for agent tests that pass
`vocation_id`, the agent's `init/1` needs to stop doing
DB work synchronously. Options:

1. **Defer to `handle_continue/2`** — fetch vocation in
   `handle_continue`, broadcast a `vocation_ready` event when
   done. Tests would need to wait for that event.
2. **Pre-fetch in test helper** — `start_agent/1` fetches the
   vocation in the test process and passes the full struct in
   attrs (not the id). Then the agent's `init/1` has no DB
   work.
3. **`Sandbox.allow/3` with `caller:`** — pass `:caller` option
   in DB calls so the agent can find the test's connection via
   the callers chain. Requires agent code changes to pass
   `:caller` through.

Option 2 is the smallest change with the least new race
conditions.

## Verification

- `mix precommit` exits 0.
- Elixir suite: 669 tests, 0 failures, ~2.2s wall-clock.
- Verified across 6 seeds (1, 7, 42, 100, 999, 2024) — 0
  failures per seed. Some pre-existing async flakes
  (`notes/flaky-tests.md`) may still show up under specific
  orderings; the failure rate is comparable to the
  pre-Postgres baseline.
- Coverage: 91.6% on the test helpers file, 87.5% on
  `data_case.ex`.
- JS suite: 581 tests, 0 failures, 5.5s wall-clock.
- `mix compile --warnings-as-errors` clean.
- `mix credo`: 0 issues.