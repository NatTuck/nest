#!/usr/bin/env bash
# scripts/start-instance.sh
#
# Run a numbered Nest dev instance:
#
#     ./scripts/start-instance.sh 7
#
# - database: nest7, created, migrated and seeded on first run. Every step
#   is idempotent (`ecto.create` exits 0 on an existing database, migrations
#   are versioned, the seeds upsert), so re-running the setup is harmless.
# - port: 4047 (= 4000 + n).
# - watchers: off (`NEST_NO_WATCHERS=1`). The watchers build into this
#   checkout's priv/static, and this instance usually runs alongside the
#   checkout's own server, whose watchers are already building there — two
#   vite build --watch processes racing on one output is waste. An instance
#   that is the only server in its checkout starts with NEST_NO_WATCHERS=0.
#
# `NEST_DEV_DB` and `NEST_PORT` are the overrides `Nest.Config.Checkout`
# documents; this script simply sets them from n.
#
# Isolation comes for free: this instance's docker containers are
# nest-space-<space_id>-nest7 (`Nest.Sandbox.Installation` derives the
# installation segment from the database name) and its bwrap scratch lives
# under /tmp/nest/<beam-ospid>.
#
# Usage: ./scripts/start-instance.sh <n>

set -euo pipefail

n="${1:-}"
case "$n" in
  ''|*[!0-9]*)
    echo "usage: $0 <n>   (runs nest<n> on port 4000+n)" >&2
    exit 2
    ;;
esac

cd "$(dirname "$0")/.."

export NEST_DEV_DB="nest${n}"
export NEST_PORT=$((4040 + n))
export NEST_NO_WATCHERS="${NEST_NO_WATCHERS:-1}"

mix ecto.setup

echo "starting nest${n} on http://localhost:${NEST_PORT} (db ${NEST_DEV_DB}, NEST_NO_WATCHERS=${NEST_NO_WATCHERS})"
exec mix phx.server
