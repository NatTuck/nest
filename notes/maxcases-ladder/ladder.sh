#!/usr/bin/env bash
# ladder.sh LABEL WORKTREE OUT_TSV [CASE_COUNTS...]
#
# Run this project's full test suite at a ladder of `--max-cases` values ON THE
# HOST WHOSE NUMBERS WE WANT, and write one TSV row per point. Copy it to each
# measured host and run it there, so wall/user time is measured locally rather
# than over ssh.
#
# Timing uses bash's `time` keyword (a shell builtin), NOT /usr/bin/time: that
# binary is absent on some of the hosts, and a missing TIMEBIN silently turns
# the whole run into `: command not found`.
#
# Command output is never piped into head/tail/grep: every run's full output
# goes to a log file and is parsed from that file.
#
# Env: LOCK=/path/to/lock  -> hold that flock for the whole ladder, so no other
# agent's suite run can interleave with a measurement.

set -uo pipefail

LABEL=${1:?usage: ladder.sh LABEL WORKTREE OUT_TSV [CASE_COUNTS...]}
WT=${2:?}
OUT=${3:?}
shift 3
COUNTS=("$@")
if [ ${#COUNTS[@]} -eq 0 ]; then COUNTS=(2 4 6 8 12 16 24 32); fi

SEED=12345
TIMEFORMAT=$'%R\t%U\t%S'
LOGDIR=$(dirname "$OUT")/logs
mkdir -p "$LOGDIR"

if [ -n "${LOCK:-}" ]; then
  exec 9>"$LOCK"
  flock -w 3600 9 || { echo "could not take $LOCK" >&2; exit 1; }
fi

if command -v mix >/dev/null 2>&1; then
  MIX=(mix)
  MIXSRC=path
elif [ -x "$HOME/.local/bin/mise" ]; then
  MIX=("$HOME/.local/bin/mise" exec -- mix)
  MIXSRC=mise
else
  echo "no mix and no mise on $(hostname)" >&2
  exit 1
fi

cd "$WT" || exit 1
SHA=$(git rev-parse --short HEAD)
printf 'label\tcases\tsha\tload1\tfailures\tdetector\ttimeouts\terrorlogs\tother\twall_s\tuser_s\tsys_s\texit\tmixsrc\n' > "$OUT"

# Warm up the test-env build first, so the first ladder point does not pay for
# a cold compile. Recorded separately; it is not a data point.
{ time "${MIX[@]}" compile > "$LOGDIR/$LABEL-warmup.log" 2>&1 ; } 2> "$LOGDIR/$LABEL-warmup.time" || true

for n in "${COUNTS[@]}"; do
  load1=$(cut -d' ' -f1 /proc/loadavg)
  log="$LOGDIR/$LABEL-cases$n.log"
  tfile="$LOGDIR/$LABEL-cases$n.time"
  { time "${MIX[@]}" test --seed "$SEED" --max-cases "$n" > "$log" 2>&1 ; } 2> "$tfile"
  rc=$?

  total=$(sed -n 's/^\([0-9][0-9]*\) tests, \([0-9][0-9]*\) failures*$/\2/p' "$log" | tail -n 1)
  [ -n "$total" ] || total=-1
  detector=$(grep -c 'expected zero remaining agents' "$log")
  timeouts=$(grep -c 'ExUnit.TimeoutError' "$log")
  errorlogs=$(grep -c '\[error\]' "$log")
  other=$(( total - detector - timeouts )); [ "$other" -lt 0 ] && other=0
  wall=-1; user=-1; sys=-1
  if [ -s "$tfile" ]; then read -r wall user sys < <(tr '\t' ' ' < "$tfile"); fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "$n" "$SHA" "$load1" "$total" "$detector" "$timeouts" "$errorlogs" \
    "$other" "$wall" "$user" "$sys" "$rc" "$MIXSRC" >> "$OUT"
  printf '  %s cases=%s failures=%s (detector=%s timeout=%s errlog=%s other=%s) wall=%ss load=%s rc=%s mixsrc=%s\n' \
    "$LABEL" "$n" "$total" "$detector" "$timeouts" "$errorlogs" "$other" "$wall" "$load1" "$rc" "$MIXSRC" >&2
done
