#!/usr/bin/env bash
# scripts/precommit-test.sh
#
# Run the Elixir test suite for `mix precommit` under a host-dependent
# timeout. "vampire" is our fast reference host (5s); every other host
# (e.g. the Gaudi box) gets 15s of headroom.
#
# The test DB is prepared *outside* the timed window: `mix test` normally
# does it itself, but the gate is for the suite, and the prep — two
# Postgres round-trips plus their Mix-task overhead — does not belong
# inside it.
#
# Usage: bash scripts/precommit-test.sh

set -u

# `mix test` implies MIX_ENV=test, but a standalone `mix ecto.create` /
# `ecto.migrate` would default to :dev. Pin it so this script works on its
# own, not only under `mix precommit`'s `preferred_envs`.
export MIX_ENV=test

# Prepare the DB loudly. `ecto.create` exits 0 when the database already
# exists (it prints a notice and moves on), so a plain `|| exit 1` only
# fires on a genuine failure — which must not be mistaken for a test
# failure, nor silently skipped.
mix ecto.create --quiet || {
  echo "precommit-test: could not create the test database" >&2
  exit 1
}

mix ecto.migrate --quiet || {
  echo "precommit-test: could not migrate the test database" >&2
  exit 1
}

# This isn't negotiable. Tests on vampire must hit this goal, or
# whatever we're doing isn't done.
# If you're failing this, that's unacceptable and your code is
# shit and needs to be fixed.
if [ "$(hostname)" = "vampire" ]; then
  timeout 5 env NEST_TEST_NO_DB_PREP=1 mix test
else
  timeout 15 env NEST_TEST_NO_DB_PREP=1 mix test
fi
