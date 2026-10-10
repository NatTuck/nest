#!/usr/bin/env bash
#
# scripts/precommit-test.sh - the budgeted test gate for `mix precommit`.
#
# Runs `mix test --cover` EXACTLY ONCE and splits that single run into four
# buckets, each with its own budget:
#
#     setup  everything before ExUnit starts: mix boot, `ecto.create`,
#            `ecto.migrate`, cover instrumentation, app boot
#     load   test-file compile/require (ExUnit's "compilation cycle" step)
#     run    the tests themselves
#     post   after ExUnit's summary: cover analyse/export/report, teardown
#
# Budgets on the fast reference host ("vampire"); every other host gets x3:
#
#     setup <= 4s    load <= 4s    run <= 3s    post <= 3s
#
# The four buckets exist so that a regression names the phase it moved. A
# normal overrun is always MEASURED AND REPORTED, never SIGTERM'd: the hard
# `timeout` below is a hang-guard only, set at 2x the sum of the four budgets,
# and its 124 is reserved for a genuine hang. (The old gate was a bare
# `timeout 5 mix test`, so a green run killed during teardown was indistinguish-
# able from a real failure and could not say which phase ran long.)
#
# Exit codes, all distinct:
#
#     0    ok
#     1    coverage shortfall (ExCoveralls / coveralls.json)
#     2    test failures (ExUnit's own code)
#     3    a timing bucket blew its budget, or the timing line was missing
#     124  the hang-guard fired
#
# If more than one applies the loudest wins: 124 > 3 > 2 > 1 > 0. Every
# problem found is printed, so nothing hides behind the exit code.
#
# Hooks for exercising this gate itself (NOT for use in precommit):
#
#     PRECOMMIT_TEST_HOST=vampire|other   override the hostname lookup
#     PRECOMMIT_TEST_ARGS="test/x_test.exs"   extra args for `mix test`
#     PRECOMMIT_SETUP_BUDGET_MS, PRECOMMIT_LOAD_BUDGET_MS,
#     PRECOMMIT_RUN_BUDGET_MS, PRECOMMIT_POST_BUDGET_MS   override a budget
#
set -u

cd "$(dirname "$0")/.." || exit 1

readonly BUDGET_FAILED=3
readonly HANG_GUARD_FACTOR=2
readonly VAMPIRE_SETUP_MS=4000
readonly VAMPIRE_LOAD_MS=4000
readonly VAMPIRE_RUN_MS=3000
readonly VAMPIRE_POST_MS=3000
readonly OFFHOST_MULTIPLIER=3
readonly TIMING_PREFIX="NEST_TEST_TIMING"
# AGENTS.md: all test-run output lives under notes/test-runs (gitignored).
readonly LOG_DIR="notes/test-runs"
readonly LOG_FILE="$LOG_DIR/precommit-test.log"

now_us() {
  printf '%s' "${EPOCHREALTIME/./}"
}

ms_to_seconds() {
  awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 1000 }'
}

budget_ms() {
  local name=$1
  local fallback=$2
  local value
  value=$(printenv "$name" || true)

  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

resolve_host() {
  if [ -n "${PRECOMMIT_TEST_HOST:-}" ]; then
    printf '%s' "$PRECOMMIT_TEST_HOST"
  else
    hostname
  fi
}

# Budgets as a "setup load run post" line of milliseconds.
resolve_budgets() {
  local multiplier=1

  if [ "$1" != "vampire" ]; then
    multiplier=$OFFHOST_MULTIPLIER
  fi

  printf '%s %s %s %s\n' \
    "$(budget_ms PRECOMMIT_SETUP_BUDGET_MS $((VAMPIRE_SETUP_MS * multiplier)))" \
    "$(budget_ms PRECOMMIT_LOAD_BUDGET_MS $((VAMPIRE_LOAD_MS * multiplier)))" \
    "$(budget_ms PRECOMMIT_RUN_BUDGET_MS $((VAMPIRE_RUN_MS * multiplier)))" \
    "$(budget_ms PRECOMMIT_POST_BUDGET_MS $((VAMPIRE_POST_MS * multiplier)))"
}

# One field out of the timing line, e.g. `field load_ms "$line"`.
field() {
  awk -v key="$1" '{
    for (i = 1; i <= NF; i++) {
      split($i, pair, "=")
      if (pair[1] == key) print pair[2]
    }
  }' <<<"$2"
}

run_suite() {
  local t0_us=$1
  local guard_ms=$2
  local out_file=$3

  # shellcheck disable=SC2086  # PRECOMMIT_TEST_ARGS is deliberately word-split
  NEST_TEST_T0_US="$t0_us" timeout "$(ms_to_seconds "$guard_ms")" \
    mix test --cover \
    --formatter ExUnit.CLIFormatter \
    --formatter Nest.TestTiming \
    ${PRECOMMIT_TEST_ARGS:-} 2>&1 | tee "$out_file"

  return "${PIPESTATUS[0]}"
}

# Sub-second values are shown in ms so that a small violation still shows both
# numbers (e.g. "run 412ms (budget 300ms)"), while real budgets read as
# "load 4.3s (budget 4.0s)".
format_ms() {
  local ms=$1

  if [ "$ms" -lt 1000 ]; then
    printf '%sms' "$ms"
  else
    printf '%ss' "$(ms_to_seconds "$ms")"
  fi
}

# Prints one violation line per over-budget bucket. Empty output means clean.
check_bucket() {
  local name=$1 actual=$2 budget=$3

  if [ "$actual" -gt "$budget" ]; then
    printf '%s %s (budget %s)\n' "$name" "$(format_ms "$actual")" "$(format_ms "$budget")"
  fi
}

read_timings() {
  local out_file=$1 line

  line=$(grep -m1 "^${TIMING_PREFIX} " "$out_file" || true)

  if [ -z "$line" ]; then
    echo "precommit-test: no '${TIMING_PREFIX}' line in the suite output - the timing formatter did not run or did not report. Refusing to pass. Output: $out_file" >&2
    return 1
  fi

  setup_ms=$(field setup_ms "$line")
  load_ms=$(field load_ms "$line")
  run_ms=$(field run_ms "$line")
  reported_ms=$(field reported_ms "$line")

  if [ -z "$setup_ms" ] || [ -z "$load_ms" ] || [ -z "$run_ms" ] || [ -z "$reported_ms" ]; then
    echo "precommit-test: unparseable timing line: $line" >&2
    return 1
  fi

  if [ "$setup_ms" -lt 0 ] || [ "$load_ms" -lt 0 ] || [ "$run_ms" -lt 0 ]; then
    echo "precommit-test: a phase could not be computed (timing line: $line). Refusing to pass." >&2
    return 1
  fi

  return 0
}

main() {
  local host budgets setup_budget load_budget run_budget post_budget
  host=$(resolve_host)
  budgets=$(resolve_budgets "$host")
  read -r setup_budget load_budget run_budget post_budget <<<"$budgets"

  local guard_ms=$(((setup_budget + load_budget + run_budget + post_budget) * HANG_GUARD_FACTOR))

  mkdir -p "$LOG_DIR"

  echo "precommit-test: host=${host} budgets: setup<=${setup_budget}ms load<=${load_budget}ms run<=${run_budget}ms post<=${post_budget}ms (hang-guard ${guard_ms}ms)"

  local t0_us child_rc wall_ms
  t0_us=$(now_us)
  run_suite "$t0_us" "$guard_ms" "$LOG_FILE"
  child_rc=$?
  wall_ms=$((($(now_us) - t0_us) / 1000))

  if [ "$child_rc" -eq 124 ]; then
    echo "precommit-test: HANG - the suite did not finish within the ${guard_ms}ms hang-guard. Output: $LOG_FILE" >&2
    return 124
  fi

  local setup_ms load_ms run_ms reported_ms
  if ! read_timings "$LOG_FILE"; then
    return "$BUDGET_FAILED"
  fi

  # `post` is whatever the suite spent outside the three phases ExUnit and the
  # formatter can see: cover analyse/export/report, teardown, process exit.
  local post_ms=$((wall_ms - setup_ms - load_ms - run_ms))

  local violations
  violations=$(
    check_bucket setup "$setup_ms" "$setup_budget"
    check_bucket load "$load_ms" "$load_budget"
    check_bucket run "$run_ms" "$run_budget"
    check_bucket post "$post_ms" "$post_budget"
  )

  echo "precommit-test: setup $(ms_to_seconds "$setup_ms")s · load $(ms_to_seconds "$load_ms")s · run $(ms_to_seconds "$run_ms")s · post $(ms_to_seconds "$post_ms")s · wall $(ms_to_seconds "$wall_ms")s (ExUnit reported $(ms_to_seconds "$reported_ms")s)"

  if [ -n "$violations" ]; then
    echo "precommit-test: BUDGET FAILED" >&2
    printf '%s\n' "$violations" >&2
    echo "precommit-test: output: $LOG_FILE" >&2
    return "$BUDGET_FAILED"
  fi

  if [ "$child_rc" -ne 0 ]; then
    report_child_failure "$child_rc"
  fi

  return "$child_rc"
}

# The child's exit code is ExUnit's and ExCoveralls' own. When a run fails BOTH
# its tests and its coverage threshold, the coverage code (1) wins and the test
# failures would be invisible from the exit code alone. Print what the output
# actually says, so neither cause is hidden behind the code.
report_child_failure() {
  local child_rc=$1
  local summary_line coverage_line

  summary_line=$(grep -m1 -E '^[0-9]+ (doctests?|tests?|properties), [0-9]+ (failures?|excluded)' "$LOG_FILE" || true)
  coverage_line=$(grep -m1 '^FAILED: Expected minimum coverage' "$LOG_FILE" || true)

  {
    echo "precommit-test: suite exited ${child_rc} (0 ok, 1 coverage shortfall, 2 test failures)"

    if [ -n "$summary_line" ]; then
      echo "precommit-test:   ExUnit: ${summary_line}"
    fi

    if [ -n "$coverage_line" ]; then
      echo "precommit-test:   coverage: ${coverage_line}"
    fi

    echo "precommit-test: full output: ${LOG_FILE}"
  } >&2
}

main
