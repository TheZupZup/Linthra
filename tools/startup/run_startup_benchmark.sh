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

while [ $# -gt 0 ]; do
  case "$1" in
    --iterations)   ITERATIONS="$2"; shift 2 ;;
    --small-tracks) SMALL_TRACKS="$2"; shift 2 ;;
    --large-tracks) LARGE_TRACKS="$2"; shift 2 ;;
    --canary-ms)    CANARY_MS="$2"; shift 2 ;;
    --out)          OUT_DIR="$2"; shift 2 ;;
    --smoke)        SMOKE=1; shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

info() { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
mkdir -p "$OUT_DIR"

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

# A smoke run is small on purpose: it exists to prove the harness still runs and
# still produces a sample set the reporter can read, which is the only part of
# this that means the same thing on a machine nobody controls.
if [ "$SMOKE" -eq 1 ]; then
  ITERATIONS=2
  SMALL_TRACKS=200
  LARGE_TRACKS=2000
fi

run_scenario() {
  local name="$1" slow_ms="$2"
  info "measuring: $name (${SMALL_TRACKS} / ${LARGE_TRACKS} tracks, ${ITERATIONS} launches each)"
  LINTHRA_STARTUP_OUT="$OUT_DIR/$name.json" \
  LINTHRA_STARTUP_LABEL="$name" \
  LINTHRA_STARTUP_ITERATIONS="$ITERATIONS" \
  LINTHRA_STARTUP_SMALL_TRACKS="$SMALL_TRACKS" \
  LINTHRA_STARTUP_LARGE_TRACKS="$LARGE_TRACKS" \
  LINTHRA_STARTUP_SLOW_CATALOG_MS="$slow_ms" \
    "$FLUTTER" test "$BENCH" > "$OUT_DIR/$name.log" 2>&1 \
    || die "the $name run failed; see $OUT_DIR/$name.log"
}

if [ "$SMOKE" -eq 1 ]; then
  run_scenario smoke 0
  info "checking the sample set is complete and well-formed"
  python3 "$REPORT" "$OUT_DIR/smoke.json" --validate || exit 1
  printf '\nSmoke run ok: %s\n' "$OUT_DIR/smoke.json"
  exit 0
fi

run_scenario baseline 0
run_scenario control 0
run_scenario canary "$CANARY_MS"

info "baseline"
python3 "$REPORT" "$OUT_DIR/baseline.json" || exit 1

status=0

info "control against baseline (expect NO REGRESSION)"
python3 "$REPORT" "$OUT_DIR/control.json" \
  --baseline "$OUT_DIR/baseline.json" --expect same || {
  printf '\nTwo identical runs disagreed. This machine is too noisy right now\n'
  printf 'for the comparison to mean anything: close what is running, or raise\n'
  printf 'the allowance with --relative-allowance and re-measure.\n'
  status=1
}

info "canary against baseline (expect REGRESSION)"
python3 "$REPORT" "$OUT_DIR/canary.json" \
  --baseline "$OUT_DIR/baseline.json" --expect regressed || {
  printf '\nA deliberate %s ms delay in every catalog read was NOT detected.\n' "$CANARY_MS"
  printf 'The check is not measuring what it thinks it is; do not trust a\n'
  printf 'clean result until this passes.\n'
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
