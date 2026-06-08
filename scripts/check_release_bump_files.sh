#!/usr/bin/env bash
#
# check_release_bump_files.sh — assert a release-bump PR only touches the files
# a version bump is supposed to touch.
#
# The "Prepare release bump" workflow (and its local twin
# scripts/prepare_release_bump.py) edits exactly four files:
#
#   * pubspec.yaml                                            (version: line)
#   * lib/core/app_info.dart                                  (_devVersionName)
#   * fastlane/metadata/android/en-US/changelogs/<code>.txt   (Fastlane changelog)
#   * metadata/io.github.thezupzup.linthra.yml                (F-Droid Current*)
#
# A release-bump PR that also carries an unrelated source/UI change is almost
# always a mistake: those changes belong in their own PR so the release commit
# stays a clean, reviewable "version only" diff (and so it is obvious nothing
# in the build changed between the tagged commit and its parent). This guard
# fails such a PR with the offending paths named.
#
# It is intentionally scoped: CI only runs it for PRs whose branch starts with
# `release/` (the branch the prepare workflow pushes). It is read-only, makes
# no network calls, and needs no secrets.
#
# Usage:
#
#   # Explicit list (one path per line) on stdin:
#   git diff --name-only <base>..HEAD | scripts/check_release_bump_files.sh
#
#   # Or as arguments:
#   scripts/check_release_bump_files.sh pubspec.yaml lib/core/app_info.dart
#
# The allowed set also permits pubspec.lock (a dependency refresh may ride
# along) and docs/release-notes/** (longer GitHub-Release notes), since both
# are part of cutting a release. Anything else is reported and fails.

set -uo pipefail

# Collect candidate paths from arguments, else from stdin.
paths=()
if [ "$#" -gt 0 ]; then
  paths=("$@")
else
  while IFS= read -r line; do
    [ -n "$line" ] && paths+=("$line")
  done
fi

if [ "${#paths[@]}" -eq 0 ]; then
  echo "No changed files provided; nothing to check."
  exit 0
fi

# Returns 0 if the given path is allowed in a release-bump PR.
is_allowed() {
  case "$1" in
    pubspec.yaml|pubspec.lock|\
    lib/core/app_info.dart|\
    metadata/io.github.thezupzup.linthra.yml|\
    fastlane/metadata/android/*/changelogs/*.txt|\
    docs/release-notes/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

offenders=()
for p in "${paths[@]}"; do
  is_allowed "$p" || offenders+=("$p")
done

if [ "${#offenders[@]}" -eq 0 ]; then
  echo "OK: release-bump PR touches only allowed version files (${#paths[@]} file(s))."
  exit 0
fi

{
  echo "ERROR: this looks like a release-bump PR, but it changes files outside"
  echo "the allowed version-bump set:"
  echo
  for p in "${offenders[@]}"; do
    echo "  - $p"
  done
  echo
  echo "A release bump should be a clean, version-only diff. Allowed files:"
  echo "  - pubspec.yaml, pubspec.lock"
  echo "  - lib/core/app_info.dart"
  echo "  - metadata/io.github.thezupzup.linthra.yml"
  echo "  - fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt"
  echo "  - docs/release-notes/**"
  echo
  echo "Move the unrelated change to its own PR, or — if it genuinely belongs"
  echo "with the release — widen the allowlist in scripts/check_release_bump_files.sh."
} >&2
exit 1
