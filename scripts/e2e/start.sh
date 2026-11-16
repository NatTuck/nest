#!/usr/bin/env bash
#
# One command that makes an end-to-end run possible from a cold checkout.
#
#   bash scripts/e2e/start.sh          # standalone: boots and stays in the foreground
#
# Playwright's `webServer` runs exactly this, so a developer and a runner take the
# same path: nothing below is test-only.
#
# A fresh clone has no dependencies. They are fetched first, and only when they
# are missing, so a warm checkout pays nothing for that step.
#
# What it does, in order:
#
#   1. create, migrate and seed the throwaway database (`MIX_ENV=e2e`, database
#      `nest_e2e`). All three are idempotent, which is what makes this safe to run
#      twice in a row — and a second run must work, because the database is *not*
#      reset between runs and the specs have to pass again on the data the first
#      run left behind.
#   2. build the browser bundle. The server serves `priv/static/assets`, so a JS
#      change that is not built is a browser running the previous bundle.
#   3. start the provider stub (`scripts/e2e/stub-llm.mjs`) in the background and
#      wait for it to answer.
#   4. start the server in the foreground, so killing this script (or Playwright's
#      teardown) stops the run. A trap takes the stub down with it.
#
# The seed is the standard one (`priv/repo/seeds.exs`): `nat` / `bacon4242` and
# every vocation and blueprint. Nothing else is seeded — the space, the agent and
# the message are created through the UI, which is the point of running a browser.

set -euo pipefail

# The project root, whatever directory this is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

export MIX_ENV=e2e
export E2E_PORT="${E2E_PORT:-4010}"
# The provider's port is also written into `scripts/e2e/config.toml`'s
# `base-url` — the server calls the stub, so the two must name the same port and
# changing one means changing both.
export STUB_LLM_PORT="${STUB_LLM_PORT:-4011}"

# A cold checkout has no dependencies at all. Both of these are the setup step
# `mix setup` already runs, and they are skipped when the directories are there,
# so a warm checkout pays nothing for them.
if [[ ! -d deps ]]; then
  mix deps.get
fi
if [[ ! -d assets/node_modules ]]; then
  (cd assets && pnpm install)
fi

# A cold checkout has no database at all. `create` on an existing one is not an
# error (it says so and exits 0), and `migrate` and the seeds are no-ops the
# second time.
#
# `E2E_PORT=0` for these three, on purpose: the endpoint is `server: true`, so
# **every** `mix` task that starts the app opens its port — including the seed,
# for as long as it runs. A port that is bound and then released is worse than
# no port at all: Playwright's readiness probe (`url` in `playwright.config.ts`)
# takes any answer as "the server is up", so a probe that lands in the seed's
# window starts the specs against a socket that has already closed. An ephemeral
# port gives those short-lived endpoints somewhere else to listen, and leaves
# `E2E_PORT` to the one process that is meant to have it.
E2E_PORT=0 mix ecto.create
E2E_PORT=0 mix ecto.migrate
E2E_PORT=0 mix run priv/repo/seeds.exs

mix assets.build

stub_pid=""
server_pid=""

cleanup() {
  # The stub first: it is the one that would otherwise outlive the run.
  if [[ -n "$stub_pid" ]] && kill -0 "$stub_pid" 2>/dev/null; then
    kill "$stub_pid" 2>/dev/null || true
    wait "$stub_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

node scripts/e2e/stub-llm.mjs &
stub_pid=$!

# Wait for the stub to *answer*, not for a clock: the first chat message goes
# through it, and a provider that is not up yet is a failed turn rather than a
# slow one. `--retry-delay 0` is curl's own backoff, so this is a wait on state.
if ! curl -sf --retry 60 --retry-delay 0 --retry-connrefused \
  "http://127.0.0.1:${STUB_LLM_PORT}/v1/models" >/dev/null; then
  echo "the stub provider never answered on :${STUB_LLM_PORT}" >&2
  exit 1
fi

# The server in the foreground. `--no-halt` is what `phx.server` already does; the
# point of running it as a child rather than `exec` is that the trap above must
# still run when this script is killed.
mix phx.server &
server_pid=$!
wait "$server_pid"
