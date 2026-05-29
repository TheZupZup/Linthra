#!/usr/bin/env bash
#
# release_preflight.sh — verify a release tag matches pubspec.yaml *before*
# pushing it. Pure bash; does not need Flutter or Dart.
#
# Usage:
#
#   ./scripts/release_preflight.sh v0.1.0-alpha.36
#
# Options:
#
#   --pubspec PATH     Read pubspec.yaml from PATH (default: ./pubspec.yaml).
#   --app-info PATH    Read _devVersionName from PATH
#                      (default: ./lib/core/app_info.dart).
#   --no-app-info      Skip the AppInfo check.
#   -h, --help         Show this help.
#
# What it does:
#
#   1. Encodes the tag to versionName / versionCode using the same rules as
#      tool/version_from_tag.dart (the canonical Dart encoder, exercised by
#      test/tooling/version_from_tag_test.dart). The two encodings are kept in
#      lockstep by test/tooling/release_preflight_test.dart.
#         versionCode = MAJOR*10_000_000 + MINOR*100_000 + PATCH*1_000 + rank
#         rank: alpha.N=N, beta.N=300+N, rc.N=600+N, stable=999
#   2. Reads `version: <name>+<code>` from pubspec.yaml.
#   3. (Default) Reads `_devVersionName = '<name>'` from lib/core/app_info.dart.
#   4. Compares them. On any mismatch (or malformed tag) it emits a multi-line
#      ERROR that names the pushed tag, the expected pubspec version, the
#      actual pubspec version, and the exact fix — then exits non-zero.
#   5. On success it prints LINTHRA_VERSION_NAME / LINTHRA_VERSION_CODE for
#      CI capture, an `OK:` confirmation, and the next safe commands.
#
# This is the local twin of the GitHub Actions "Verify the tag matches
# pubspec.yaml" step in .github/workflows/android-release-build.yml: that step
# runs THIS script, so CI and a contributor's pre-tag check fail with the same
# wording. See docs/release-process.md §3 step 9.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PUBSPEC="$REPO_ROOT/pubspec.yaml"
APP_INFO="$REPO_ROOT/lib/core/app_info.dart"
CHECK_APP_INFO=true
TAG=""

usage() {
  cat <<'EOF'
Usage: scripts/release_preflight.sh <tag> [--pubspec PATH] [--app-info PATH] [--no-app-info]

  <tag>          Release tag, e.g. v0.1.0-alpha.36 (with or without leading v).
  --pubspec      Read pubspec.yaml from PATH (default: ./pubspec.yaml).
  --app-info     Read _devVersionName from PATH (default: ./lib/core/app_info.dart).
  --no-app-info  Skip the AppInfo check.
  -h, --help     Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pubspec)
      [ "$#" -ge 2 ] || { echo "ERROR: --pubspec needs a path." >&2; exit 64; }
      PUBSPEC="$2"; shift 2 ;;
    --app-info)
      [ "$#" -ge 2 ] || { echo "ERROR: --app-info needs a path." >&2; exit 64; }
      APP_INFO="$2"; shift 2 ;;
    --no-app-info) CHECK_APP_INFO=false; shift ;;
    --)
      shift
      if [ "$#" -gt 0 ] && [ -z "$TAG" ]; then TAG="$1"; shift; fi
      ;;
    -*)
      printf 'ERROR: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 64
      ;;
    *)
      if [ -z "$TAG" ]; then
        TAG="$1"
      else
        printf 'ERROR: unexpected argument: %s\n\n' "$1" >&2
        usage >&2
        exit 64
      fi
      shift
      ;;
  esac
done

if [ -z "$TAG" ]; then
  printf 'ERROR: missing tag argument.\n\n' >&2
  usage >&2
  exit 64
fi

# Trim surrounding whitespace.
TAG="${TAG#"${TAG%%[![:space:]]*}"}"
TAG="${TAG%"${TAG##*[![:space:]]}"}"

# Display form: always carry the leading v so error messages match what a user
# would type. Parsing strips it.
display_tag="$TAG"
[[ "$display_tag" != v* ]] && display_tag="v$display_tag"
parse="${TAG#v}"

# Mirror tool/version_from_tag.dart's _tagPattern:
#   ^v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$
re='^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$'
if [[ ! "$parse" =~ $re ]]; then
  cat >&2 <<EOF
ERROR: Malformed release tag "$display_tag".
Expected vMAJOR.MINOR.PATCH with an optional -alpha.N / -beta.N / -rc.N suffix,
e.g. v0.1.0-alpha.36, v0.1.0-rc.1, or v1.2.3.
EOF
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
tier="${BASH_REMATCH[5]}"
pre_n="${BASH_REMATCH[6]}"

# Bounds mirror tool/version_from_tag.dart: minor/patch ≤ 99, pre-release N ≤ 299.
if [ "$minor" -gt 99 ]; then
  echo "ERROR: Minor version $minor in tag \"$display_tag\" exceeds the supported range (0..99)." >&2
  exit 1
fi
if [ "$patch" -gt 99 ]; then
  echo "ERROR: Patch version $patch in tag \"$display_tag\" exceeds the supported range (0..99)." >&2
  exit 1
fi

if [ -z "$tier" ]; then
  rank=999
  expected_name="${major}.${minor}.${patch}"
else
  if [ "$pre_n" -gt 299 ]; then
    echo "ERROR: Pre-release number $pre_n in tag \"$display_tag\" exceeds the supported range (0..299)." >&2
    exit 1
  fi
  case "$tier" in
    alpha) base=0 ;;
    beta)  base=300 ;;
    rc)    base=600 ;;
  esac
  rank=$((base + pre_n))
  expected_name="${major}.${minor}.${patch}-${tier}.${pre_n}"
fi

expected_code=$((major * 10000000 + minor * 100000 + patch * 1000 + rank))
if [ "$expected_code" -le 0 ] || [ "$expected_code" -gt 2100000000 ]; then
  echo "ERROR: Derived versionCode $expected_code for tag \"$display_tag\" is outside the valid Android range (1..2100000000)." >&2
  exit 1
fi
expected_full="${expected_name}+${expected_code}"

# Read pubspec.yaml's `version: <name>+<code>`.
if [ ! -f "$PUBSPEC" ]; then
  echo "ERROR: pubspec.yaml not found at $PUBSPEC" >&2
  exit 1
fi
pubspec_full="$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -n1 | tr -d '[:space:]')"
if [ -z "$pubspec_full" ]; then
  echo "ERROR: pubspec.yaml at $PUBSPEC has no \`version:\` line." >&2
  exit 1
fi
pubspec_name="${pubspec_full%%+*}"
if [[ "$pubspec_full" == *+* ]]; then
  pubspec_code="${pubspec_full#*+}"
else
  pubspec_code=""
fi

if [ "$pubspec_name" != "$expected_name" ] || [ "$pubspec_code" != "$expected_code" ]; then
  cat >&2 <<EOF
ERROR: Release tag $display_tag expects pubspec.yaml version $expected_full.
Actual pubspec.yaml version is $pubspec_full.

Do not move this tag.
Bump pubspec.yaml in a PR, merge it, then create the next release tag from main.
EOF
  exit 1
fi

# AppInfo check (default on; CI passes --no-app-info because flutter test
# covers the drift already via test/core/app_info_version_test.dart).
if [ "$CHECK_APP_INFO" = "true" ]; then
  if [ ! -f "$APP_INFO" ]; then
    printf 'WARNING: app_info not found at %s; skipping AppInfo check.\n' "$APP_INFO" >&2
  else
    app_info_name="$(sed -n "s/.*_devVersionName *= *'\\([^']*\\)'.*/\\1/p" "$APP_INFO" | head -n1)"
    if [ -z "$app_info_name" ]; then
      printf 'WARNING: could not find _devVersionName in %s; skipping AppInfo check.\n' "$APP_INFO" >&2
    elif [ "$app_info_name" != "$expected_name" ]; then
      cat >&2 <<EOF
ERROR: Release tag $display_tag expects AppInfo._devVersionName = $expected_name.
Actual AppInfo._devVersionName is $app_info_name (in $APP_INFO).

Bump pubspec.yaml AND AppInfo._devVersionName in the same PR, then create the release tag from main.
EOF
      exit 1
    fi
  fi
fi

# Success: KEY=VALUE first so CI can capture them, then the friendly message
# and the next safe commands a contributor should run.
printf 'LINTHRA_VERSION_NAME=%s\n' "$expected_name"
printf 'LINTHRA_VERSION_CODE=%s\n' "$expected_code"
printf 'OK: %s matches pubspec.yaml version %s.\n' "$display_tag" "$expected_full"

cat <<EOF

Next safe commands (run from a clean checkout of main):
  git checkout main
  git pull origin main
  git tag -a $display_tag -m "Linthra $expected_name"
  git push origin $display_tag

Then watch GitHub Actions: the release workflow will build and attach artifacts.
EOF
