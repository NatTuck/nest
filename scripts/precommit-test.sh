#!/usr/bin/env bash
# scripts/precommit-test.sh
#
# Run the Elixir test suite for `mix precommit` under a host-dependent
# timeout. "vampire" is our fast reference host (5s); every other host
# (e.g. the Gaudi box) gets 15s of headroom.
#
# Usage: bash scripts/precommit-test.sh

set -u

# This isn't negotiable. Tests on vampire must hit this goal, or
# whatever we're doing isn't done.
# If you're failing this, that's unacceptable and your code is
# shit and needs to be fixed.
if [ "$(hostname)" = "vampire" ]; then
  timeout 5 mix test
else
  timeout 15 mix test
fi
