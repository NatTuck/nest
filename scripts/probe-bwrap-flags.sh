#!/usr/bin/env bash
# scripts/probe-bwrap-flags.sh
#
# Diagnose which bwrap flag combinations work in nested / /proc-restricted
# environments. Iterates the variants flagged in the plan and prints a
# summary table at the end.
#
# Usage:
#   bash scripts/probe-bwrap-flags.sh [OUTPUT_FILE]
#
# When OUTPUT_FILE is given, output is teed there in addition to stdout.
# Use that for capturing evidence into notes/test-runs/.

set -u

OUT="${1:-/dev/null}"
WORK=$(mktemp -d -t bwrap-probe-host-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Tee all output to the requested file.
exec > >(tee "$OUT") 2>&1

echo "## host uname"
uname -a
echo "## kernel user-ns setting"
cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null \
  || echo "(/proc/sys/kernel/unprivileged_userns_clone not present)"
echo "## bwrap version"
bwrap --version
echo
echo "## current sandbox flags (lib/nest/sandbox.ex:178-198, verbatim)"
echo "    --unshare-all --die-with-parent --new-session \\"
echo "    --proc /proc --ro-bind / / --dev /dev"
echo

# One bwrap invocation per variant. --tmpfs /tmp gives the probe a writable
# scratch dir without us needing to bind any host paths into the sandbox.
# The probe body creates its own workspace dir under /tmp and exercises
# /proc reads, /proc writes, /proc/self visibility.
probe() {
  local label="$1"; shift
  printf '\n========== variant: %s ==========\n' "$label"
  printf '## args: bwrap %s\n' "$*"

  local stdout_file="$WORK/stdout"
  local stderr_file="$WORK/stderr"
  : > "$stdout_file"
  : > "$stderr_file"

  bwrap "$@" \
        --tmpfs /tmp \
        /bin/sh -c '
set +e
WORK=/tmp/probe-work
mkdir -p "$WORK"
cd "$WORK"
echo "===hello==="
echo "pwd=$(pwd)"
echo "lsd_proc=$(ls -d /proc/self 2>&1)"
echo "status_head=$(cat /proc/self/status 2>&1 | head -1)"
echo "pid=$$"
ls -la /proc/self/exe /proc/self/cwd 2>&1 || true
: > /tmp/oom_before /tmp/oom_after /tmp/oom_err /tmp/proc_test_err
cat /proc/self/oom_score_adj >/tmp/oom_before 2>/tmp/oom_before_err
echo 100 > /proc/self/oom_score_adj 2>/tmp/oom_err
cat /proc/self/oom_score_adj >/tmp/oom_after 2>/tmp/oom_after_err
touch /proc/test 2>/tmp/proc_test_err
echo "oom_before_err=$(cat /tmp/oom_before_err 2>/dev/null | tr "\n" " ")"
echo "oom_err=$(cat /tmp/oom_err 2>/dev/null | tr "\n" " ")"
echo "oom_after_err=$(cat /tmp/oom_after_err 2>/dev/null | tr "\n" " ")"
echo "oom_before=$(cat /tmp/oom_before 2>/dev/null)"
echo "oom_after=$(cat /tmp/oom_after 2>/dev/null)"
echo "proc_test_err=$(cat /tmp/proc_test_err 2>/dev/null | tr "\n" " ")"
echo "===ok==="
exit 0
' \
        > "$stdout_file" 2> "$stderr_file"
  local rc=$?

  echo "rc=$rc"
  if [ -s "$stdout_file" ]; then
    echo "stdout:"
    sed 's/^/    /' "$stdout_file"
  fi
  if [ -s "$stderr_file" ]; then
    echo "stderr:"
    sed 's/^/    /' "$stderr_file"
  fi

  local hello=no ok=no proc_visible=no proc_writable=no
  grep -q '===hello===' "$stdout_file" && hello=yes
  grep -q '===ok==='    "$stdout_file" && ok=yes
  grep -q '/proc/self'  "$stdout_file" && proc_visible=yes
  # oom_after differs from oom_before iff the write succeeded.
  grep -q 'oom_after=100' "$stdout_file" && proc_writable=yes
  # Also catch the explicit Read-only file system error.
  grep -q 'Read-only file system' "$stderr_file" && \
    printf '>>> read-only /proc detected for variant %s\n' "$label" > "$WORK/ro_marker"

  printf '>>> summary: hello=%s ok=%s proc_visible=%s proc_writable=%s\n' \
    "$hello" "$ok" "$proc_visible" "$proc_writable"
  RESULTS+="$label	rc=$rc	hello=$hello	ok=$ok	proc=$proc_visible	writable=$proc_writable"$'\n'
}

RESULTS=""

# 0. current / verbatim
probe "0-current (verbatim)" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --proc /proc \
  --ro-bind / / \
  --dev /dev

# 1. drop --proc /proc
probe "1-drop --proc /proc" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --dev /dev

# 2. replace --proc /proc with --bind /proc /proc
probe "2-bind /proc /proc" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --bind /proc /proc \
  --ro-bind / / \
  --dev /dev

# 3. read-only bind of host /proc
probe "3-ro-bind /proc /proc" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind /proc /proc \
  --ro-bind / / \
  --dev /dev

# 4. drop --unshare-all (keep --proc)
probe "4-drop --unshare-all" \
  --die-with-parent \
  --new-session \
  --proc /proc \
  --ro-bind / / \
  --dev /dev

# 5. unshare-pid-IPC only, drop --proc (omitted: --unshare-IPC is unsupported in
#    bwrap 0.9.0; 'bwrap: Unknown option --unshare-IPC' would just be noise)

# 6. drop --new-session
probe "6-drop --new-session" \
  --unshare-all \
  --die-with-parent \
  --proc /proc \
  --ro-bind / / \
  --dev /dev

# 7. drop --die-with-parent
probe "7-drop --die-with-parent" \
  --unshare-all \
  --new-session \
  --proc /proc \
  --ro-bind / / \
  --dev /dev

# 8. bare minimum: fresh-proc only, no namespace isolation
probe "8-minimal fresh-proc" \
  --proc /proc \
  --ro-bind / / \
  --dev /dev

# 9. combine: --bind /proc + drop --unshare-all (likely best for nested)
probe "9-bind /proc, no --unshare-all" \
  --die-with-parent \
  --new-session \
  --bind /proc /proc \
  --ro-bind / / \
  --dev /dev

# 10. PROPOSED FIX: --proc /proc AFTER --ro-bind / /, BEFORE --dev /dev.
# Hypothesis: the current order has --proc before --ro-bind /, which causes
# the fresh proc to inherit the parent's read-only flag. Reordering should
# make /proc/self/<pid> files writable again.
probe "10-FIX-proc after ro-bind" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  --ro-bind / / \
  --proc /proc \
  --dev /dev

echo
echo "==============================================="
echo "FINAL SUMMARY"
echo "==============================================="
printf '%s\n' "label	rc	hello	ok	proc"
printf '%s\n' "$RESULTS"
