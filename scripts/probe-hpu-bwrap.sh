#!/usr/bin/env bash
# scripts/probe-hpu-bwrap.sh
#
# Verify the bwrap flag set needed to expose Habana Gaudi (HPU) devices
# to a sandboxed process, and capture the evidence for notes/test-runs/.
#
# Usage:
#   bash scripts/probe-hpu-bwrap.sh [OUTPUT_FILE]
#
# Each variant runs `hl-smi` under bwrap and prints its rc plus the first
# lines of output. Expected: the variants that bind /dev/accel AND make
# the Habana log dir writable pass; the others fail.

set -u

OUT="${1:-/dev/null}"
exec > >(tee "$OUT") 2>&1

echo "## bwrap version"
bwrap --version
echo "## host HPU nodes"
ls -la /dev/accel 2>&1
ls -la /dev/infiniband 2>&1
echo "## HABANA_LOGS=${HABANA_LOGS:-(unset)}"
echo

run() {
  local label="$1"; shift
  printf '\n========== variant: %s ==========\n' "$label"
  printf '## args: bwrap %s --tmpfs /tmp --chdir /tmp\n' "$*"

  local out
  out=$(bwrap "$@" --tmpfs /tmp --chdir /tmp /bin/sh -c 'hl-smi 2>&1' 2>&1)
  local rc=$?

  echo "rc=$rc"
  printf '%s\n' "$out" | head -8 | sed 's/^/    /'
}

# Baseline: current sandbox flags only (expected to fail).
run "0-current (no devices)" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --unshare-net

# Device passthrough only, still no writable log dir (expected to fail).
run "1-accel only" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --unshare-net \
  --dev-bind /dev/accel /dev/accel

# Device passthrough + writable Habana log dir (expected to pass).
run "2-accel + log tmpfs" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --unshare-net \
  --dev-bind /dev/accel /dev/accel \
  --tmpfs /var/log/habana_logs

# Full passthrough: accel + infiniband + log tmpfs (expected to pass;
# infiniband is required for actual compute, not for hl-smi alone).
run "3-accel + infiniband + log tmpfs" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --unshare-net \
  --dev-bind /dev/accel /dev/accel \
  --dev-bind /dev/infiniband /dev/infiniband \
  --tmpfs /var/log/habana_logs
