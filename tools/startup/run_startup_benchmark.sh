#!/usr/bin/env bash
#
# run_startup_benchmark.sh: the Linux startup benchmark, end to end.
#
# Runs test/benchmarks/startup_time_bench.dart over the empty, small and large
# synthetic libraries and reports how long each takes to reach a usable
# Library screen. Three runs, because a timing check nobody has tested is a
# timing check nobody should believe:
#
#   1. baseline: the app as it is. Everything is measured against this.
#   2. control:  the app as it is, again. Must come back NO REGRESSION.
#                This is the false-positive check: if two identical runs
#                disagree, this machine is too noisy today and any red result
#                below proves nothing.
#   3. canary:   the same run with catalog reads deliberately slowed. Must come
#                back REGRESSION. This is the false-negative check: a check
#                that only ever says "fine" is indistinguishable from one that
#                has quietly stopped measuring.
#
# The comparison is a ratio against the baseline, never a millisecond
# threshold: see tools/startup/README.md for why, and for what the numbers do
# and do not cover.
#
# Usage:
#   ./tools/startup/run_startup_benchmark.sh [options]
#
#   --iterations N     launches per workload (default 5, the first is warm-up)
#   --small-tracks N   size of the small library (default 1000)
#   --large-tracks N   size of the large library (default 20000)
#   --canary-ms N      delay the canary injects into catalog reads (default 250)
#   --out DIR          where the JSON and logs land (default build/startup)
#   --relative-allowance F      how much slower than the baseline is still
#                               noise, as a fraction (default 0.30)
#   --absolute-allowance-ms N   milliseconds a run may be slower before the
#                               ratio is consulted (default 25)
#   --simulated-allowance-ms N  extra awaited (simulated) time that is still
#                               noise (default 16)
#   --smoke            one small, fast run and a structure check, no verdict.
#                      What CI runs: it proves the harness still produces a
#                      valid sample set without timing a shared runner.
#
# Flutter resolution matches scripts/verify_linux.sh: the project-local SDK
# from setup_flutter.sh (.tool/flutter) if present, otherwise Flutter on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ITERATIONS=5
SMALL_TRACKS=1000
LARGE_TRACKS=20000
CANARY_MS=250
OUT_DIR="$REPO_ROOT/build/startup"
SMOKE=0

# The warm-up count every scenario runs with. Pinned rather than inherited,
# and the same number the iteration check below sizes the run against: a
# caller who exported LINTHRA_STARTUP_WARMUP would otherwise discard a
# different prefix than that check assumed, leaving too few judged launches
# and making all three measurements run before both comparisons come back
# indeterminate.
HARNESS_WARMUP=1

# Forwarded verbatim to every startup_report.py comparison. Empty by default,
# so the reporter's own defaults are the ones in force; the failure message a
# disagreeing control prints names these, so they have to actually exist here.
info() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Every numeric option reaches the harness as an environment variable, and the
# harness falls back to its default on anything it cannot parse. So
# `--large-tracks 20000.0` or `--small-tracks typo` would not fail: all three
# scenarios would quietly measure a different library from the one asked for
# and the run would pass, describing a workload that was never run. Checked
# here instead, before anything is measured. (`set -e` is off in this script,
# so a bad value would also survive a later arithmetic test.)
require_count() {
  local flag="$1" value="$2" digits
  case "$value" in
    ''|*[!0-9]*) die "$flag needs a whole number, got '$value'" ;;
  esac
  # Digits alone are not enough: `int.tryParse` returns null past Dart's 64-bit
  # range, which lands in the same silent default as `typo` does. Compared by
  # length after stripping leading zeros, because the shell's own arithmetic
  # overflows on exactly the values being rejected.
  digits="${value#"${value%%[!0]*}"}"
  if [ "${#digits}" -gt 18 ]; then
    die "$flag is too large to measure, got '$value'"
  fi
}

ALLOWANCES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --iterations)   require_count "$1" "${2-}"; ITERATIONS="$2"; shift 2 ;;
    --small-tracks) require_count "$1" "${2-}"; SMALL_TRACKS="$2"; shift 2 ;;
    --large-tracks) require_count "$1" "${2-}"; LARGE_TRACKS="$2"; shift 2 ;;
    --canary-ms)    require_count "$1" "${2-}"; CANARY_MS="$2"; shift 2 ;;
    --out)          OUT_DIR="$2"; shift 2 ;;
    --relative-allowance|--absolute-allowance-ms|--simulated-allowance-ms)
      ALLOWANCES+=("$1" "$2"); shift 2 ;;
    --smoke)        SMOKE=1; shift ;;
    -h|--help)      sed -n '2,48p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

LOCAL_FLUTTER="$REPO_ROOT/.tool/flutter/bin/flutter"
if [ -x "$LOCAL_FLUTTER" ]; then
  FLUTTER="$LOCAL_FLUTTER"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER="$(command -v flutter)"
else
  die "Flutter not found. Run ./scripts/setup_flutter.sh first."
fi

BENCH="test/benchmarks/startup_time_bench.dart"
REPORT="$SCRIPT_DIR/startup_report.py"

# The workloads a run has to contain. The point of the whole exercise is that
# all three library sizes still start, so a run that quietly measured two of
# them is not a pass however well-formed it is.
REQUIRED_WORKLOADS="empty,small,large"

# Resolved against the *caller's* directory, before the cd below changes what a
# relative path means. Without this, `--out out/` from outside the repository
# created the directory beside the caller and then wrote to `<repo>/out/`,
# which does not exist, and the first scenario failed for no visible reason.
mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)" || die "cannot resolve $OUT_DIR"

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

# A smoke run is small on purpose: it exists to prove the harness still runs and
# still produces a sample set the reporter can read, which is the only part of
# this that means the same thing on a machine nobody controls.
if [ "$SMOKE" -eq 1 ]; then
  ITERATIONS=2
  SMALL_TRACKS=200
  LARGE_TRACKS=2000
else
  # A comparison ignores the harness's warm-up launch and refuses to judge
  # fewer than the reporter's minimum, so too small an --iterations makes the
  # control come back "regressed" however identical the timings are, and the
  # run can never pass. Asked of the reporter rather than hardcoded, so the
  # number lives in one place.
  MINIMUM_SAMPLES="$(python3 "$REPORT" --minimum-samples)" \
    || die "cannot ask $REPORT for its minimum sample count"
  MINIMUM_ITERATIONS=$((MINIMUM_SAMPLES + HARNESS_WARMUP))
  if [ "$ITERATIONS" -lt "$MINIMUM_ITERATIONS" ]; then
    die "--iterations $ITERATIONS leaves $((ITERATIONS - HARNESS_WARMUP)) judged launch(es) after the warm-up, and a comparison needs $MINIMUM_SAMPLES. Use --iterations $MINIMUM_ITERATIONS or more."
  fi
fi

run_scenario() {
  local name="$1" slow_ms="$2"
  local out="$OUT_DIR/$name.json"
  info "measuring: $name (${SMALL_TRACKS} / ${LARGE_TRACKS} tracks, ${ITERATIONS} launches each)"
  # Delete first, so a run that exits 0 without writing (a harness that skipped
  # the write, a test that passed having measured nothing) cannot leave the
  # previous run's file in place for the reporter to read as this one's. Two
  # controls comparing a file against itself both pass, which is the worst
  # possible failure: it looks like success.
  rm -f "$out"
  # LINTHRA_STARTUP_WORKLOADS is set, not inherited. A caller who exported it
  # would otherwise narrow all three scenarios at once, and because the
  # comparison only requires the two sides to *match*, both controls would
  # pass over a run that never measured `small` or `large` while the script
  # claimed it had. Every scenario measures the full set; the reporter is told
  # the same list again below.
  LINTHRA_STARTUP_OUT="$out" \
  LINTHRA_STARTUP_LABEL="$name" \
  LINTHRA_STARTUP_ITERATIONS="$ITERATIONS" \
  LINTHRA_STARTUP_WARMUP="$HARNESS_WARMUP" \
  LINTHRA_STARTUP_WORKLOADS="$REQUIRED_WORKLOADS" \
  LINTHRA_STARTUP_SMALL_TRACKS="$SMALL_TRACKS" \
  LINTHRA_STARTUP_LARGE_TRACKS="$LARGE_TRACKS" \
  LINTHRA_STARTUP_SLOW_CATALOG_MS="$slow_ms" \
    "$FLUTTER" test "$BENCH" > "$OUT_DIR/$name.log" 2>&1 \
    || die "the $name run failed; see $OUT_DIR/$name.log"
  [ -s "$out" ] \
    || die "the $name run reported success but wrote no samples to $out"
  # And checked rather than assumed: the harness could have been changed to
  # ignore the variable.
  python3 "$REPORT" "$out" --validate --require-workloads "$REQUIRED_WORKLOADS" \
    > /dev/null || die "the $name run did not measure $REQUIRED_WORKLOADS"
}

if [ "$SMOKE" -eq 1 ]; then
  run_scenario smoke 0
  info "checking the sample set is complete and well-formed"
  python3 "$REPORT" "$OUT_DIR/smoke.json" --validate \
    --require-workloads "$REQUIRED_WORKLOADS" || exit 1
  printf '\nSmoke run ok: %s\n' "$OUT_DIR/smoke.json"
  exit 0
fi

run_scenario baseline 0
run_scenario control 0
run_scenario canary "$CANARY_MS"

info "baseline"
python3 "$REPORT" "$OUT_DIR/baseline.json" || exit 1

status=0

# Two-sided, unlike a real comparison. `--expect same` means "not slower",
# which is right for a change (a genuine speed-up should pass) and wrong for
# two runs of the same commit: a control that came back far *faster* has not
# shown the two agree, it has shown the baseline was measured while the
# machine was busy, and every number taken against that baseline is worth less
# than it looks.
info "control against baseline (expect EQUIVALENT, in both directions)"
python3 "$REPORT" "$OUT_DIR/control.json" \
  --baseline "$OUT_DIR/baseline.json" "${ALLOWANCES[@]}" --expect equivalent || {
  printf '\nTwo identical runs disagreed. This machine is too noisy right now\n'
  printf 'for the comparison to mean anything: close what is running, or raise\n'
  printf 'the allowance with --relative-allowance and re-measure.\n'
  status=1
}

# Every workload, not just one. The canary delays *every* catalog read, so a
# run where it still fires on `empty` and has stopped firing on `large` has
# shown that two thirds of the check no longer detects the delay, and the
# ordinary any-workload policy would print "both controls passed" over it.
info "canary against baseline (expect REGRESSION on every workload)"
python3 "$REPORT" "$OUT_DIR/canary.json" \
  --baseline "$OUT_DIR/baseline.json" "${ALLOWANCES[@]}" \
  --expect delayed-everywhere || {
  printf '\nA deliberate %s ms delay in every catalog read was NOT detected on\n' "$CANARY_MS"
  printf 'every workload. The check is not measuring what it thinks it is; do\n'
  printf 'not trust a clean result until this passes.\n'
  status=1
}

info "reports and raw samples in $OUT_DIR"
if [ "$status" -eq 0 ]; then
  printf '\nBoth controls passed. To check a change, record a baseline on the\n'
  printf 'commit before it and compare:\n\n'
  printf '  python3 %s <after>.json --baseline <before>.json --expect same\n' \
    "tools/startup/startup_report.py"
fi
exit "$status"
