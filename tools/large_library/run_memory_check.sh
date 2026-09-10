#!/usr/bin/env bash
#
# run_memory_check.sh: the large-library memory check, end to end.
#
# Runs test/benchmarks/large_library_memory_bench.dart three times over a large
# synthetic library and compares the growth rates:
#
#   1. baseline: the app as it is. Everything is measured against this.
#   2. control:  the app as it is, again. Must come back NO REGRESSION.
#                 This is the false-positive check: if two identical runs
#                 disagree, the noise band is too tight and any red result the
#                 check produces is worthless.
#   3. leak:     the same run with a deliberate retained-object regression.
#                 Must come back REGRESSION. This is the false-negative check:
#                 a check that only ever says "fine" is indistinguishable from
#                 one that has quietly stopped measuring anything.
#
# Both controls have to pass for a result to mean anything, which is why they
# are part of the check rather than something to run occasionally.
#
# The comparison is on growth *rate*, never on an RSS figure: see
# tools/large_library/README.md for why, and for what the noise is made of.
#
# Usage:
#   ./tools/large_library/run_memory_check.sh [--tracks N] [--cycles N] [--out DIR]
#
# Flutter resolution matches scripts/verify_linux.sh: the project-local SDK from
# setup_flutter.sh (.tool/flutter) if present, otherwise Flutter on PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TRACKS=12000
CYCLES=16
OUT_DIR="$REPO_ROOT/build/memory"

while [ $# -gt 0 ]; do
  case "$1" in
    --tracks) TRACKS="$2"; shift 2 ;;
    --cycles) CYCLES="$2"; shift 2 ;;
    --out)    OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
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

BENCH="test/benchmarks/large_library_memory_bench.dart"
REPORT="$SCRIPT_DIR/memory_report.py"
mkdir -p "$OUT_DIR"

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

run_scenario() {
  local name="$1" leak="$2"
  info "measuring: $name ($TRACKS tracks, $CYCLES cycles)"
  # The harness writes JSON and prints nothing else worth keeping; its own
  # output goes to a log so a failure can still be read afterwards.
  LINTHRA_MEMORY_TRACKS="$TRACKS" \
  LINTHRA_MEMORY_CYCLES="$CYCLES" \
  LINTHRA_MEMORY_LEAK="$leak" \
  LINTHRA_MEMORY_OUT="$OUT_DIR/$name.json" \
    "$FLUTTER" test "$BENCH" > "$OUT_DIR/$name.log" 2>&1 \
    || die "the $name run failed; see $OUT_DIR/$name.log"
}

run_scenario baseline 0
run_scenario control 0
run_scenario leak 1

status=0

info "control against baseline (expect NO REGRESSION)"
python3 "$REPORT" "$OUT_DIR/control.json" \
  --baseline "$OUT_DIR/baseline.json" --expect same || {
  printf '\nTwo identical runs disagreed. The noise band is too tight for this\n'
  printf 'machine, so a red result from the leak run below would prove nothing.\n'
  printf 'Widen it with --comparison-noise-mib-per-cycle and re-measure.\n'
  status=1
}

info "leak canary against baseline (expect REGRESSION)"
python3 "$REPORT" "$OUT_DIR/leak.json" \
  --baseline "$OUT_DIR/baseline.json" --expect regressed || {
  printf '\nThe deliberate leak was NOT detected. The check is not measuring\n'
  printf 'what it thinks it is; do not trust a clean result until this passes.\n'
  status=1
}

info "reports and raw samples in $OUT_DIR"
if [ "$status" -eq 0 ]; then
  printf '\nBoth controls passed. To check a change, record a baseline on the\n'
  printf 'commit before it and compare:\n\n'
  printf '  python3 %s <after>.json --baseline <before>.json --expect same\n' \
    "tools/large_library/memory_report.py"
fi
exit "$status"
