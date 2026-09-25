#!/usr/bin/env bash
#
# check_vendored_packages.sh — audit every package under third_party/.
#
# Two independent checks per package, both of which CI runs on each PR (see
# .github/workflows/ci.yml, job "flutter"):
#
#   1. Provenance (offline, no downloads). The vendored tree must be exactly
#      "upstream + the recorded patch": reverse-applying upstream.patch onto a
#      copy of the tree has to reproduce files whose SHA-256 digests match
#      upstream.sha256. Any local edit that is not described by the patch — or
#      a patch that has drifted from the tree — fails here. The digests were
#      recorded from the pub.dev archive named in the package's PATCHES.md, so
#      nothing has to be fetched to re-check the claim.
#
#      Vendored trees that are not Dart packages (native sources such as
#      third_party/libflac and third_party/media3_decoder_flac, which have no
#      pubspec.yaml) get the same check. For them upstream.patch is optional
#      (no patch means the files must be byte-for-byte upstream), and the files
#      Linthra adds are listed in a local.files manifest instead of being
#      implied.
#
#   2. Static analysis. The root analysis_options.yaml excludes third_party/**
#      (upstream code is not held to Linthra's stricter lint set, and forcing it
#      to be would mean patching upstream for style), so `flutter analyze` at
#      the repository root never looks at a vendored package. This analyzes it
#      from its own directory instead, against its own analysis_options.yaml,
#      with the repository's pinned Flutter toolchain — so a vendored package
#      that would not compile, or a patch that introduces an analyzer error,
#      still fails CI.
#
# Usage: scripts/check_vendored_packages.sh [--no-analyze]
#   --no-analyze  run only the offline provenance check (no pub get, no network)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_ROOT="$REPO_ROOT/third_party"

ANALYZE=1
if [ "${1:-}" = "--no-analyze" ]; then
  ANALYZE=0
elif [ "$#" -gt 0 ]; then
  printf 'usage: %s [--no-analyze]\n' "$(basename "$0")" >&2
  exit 2
fi

info() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# The Flutter the repository is pinned to, if it has been installed locally.
# CI puts the pinned SDK on PATH itself.
FLUTTER="flutter"
if [ -x "$REPO_ROOT/.tool/flutter/bin/flutter" ]; then
  FLUTTER="$REPO_ROOT/.tool/flutter/bin/flutter"
fi

# Reverse-apply the recorded patch onto a copy of the vendored tree and compare
# the result with the recorded upstream digests.
#
# $3 is "pub" for a Dart package (upstream.patch required, the fixed set of
# Linthra additions below) or "native" for a non-package tree (upstream.patch
# optional, Linthra additions listed in local.files).
check_provenance() {
  local package_dir="$1" name="$2" kind="${3:-pub}"
  local manifest="$package_dir/upstream.sha256"
  local patch_file="$package_dir/upstream.patch"

  [ -f "$manifest" ] || fail "$name: missing upstream.sha256 (see PATCHES.md)"
  if [ "$kind" = "pub" ]; then
    [ -f "$patch_file" ] || fail "$name: missing upstream.patch (see PATCHES.md)"
  else
    [ -f "$package_dir/local.files" ] || fail "$name: missing local.files (see PATCHES.md)"
  fi
  [ -f "$package_dir/PATCHES.md" ] || fail "$name: missing PATCHES.md"

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $work now, not at trap time
  trap "rm -rf '$work'" RETURN

  # Copy only the files the manifest claims came from upstream. A vendored file
  # that is missing is caught here; one that was added without being recorded is
  # caught by the unlisted-file check below.
  local digest path
  while read -r digest path; do
    [ -n "$path" ] || continue
    [ -f "$package_dir/$path" ] || fail "$name: $path is listed in upstream.sha256 but not vendored"
    mkdir -p "$work/$(dirname "$path")"
    cp "$package_dir/$path" "$work/$path"
  done < "$manifest"

  cp "$manifest" "$work/upstream.sha256"
  if [ -f "$patch_file" ]; then
    cp "$patch_file" "$work/upstream.patch"
    ( cd "$work" && git apply --reverse -p1 upstream.patch ) \
      || fail "$name: upstream.patch no longer describes the vendored tree"
  fi

  ( cd "$work" && sha256sum --check --quiet upstream.sha256 ) \
    || fail "$name: reverse-applying upstream.patch did not reproduce upstream (an undocumented local edit?)"

  # Everything else in the package must be a file Linthra deliberately adds.
  local allowed_extra="PATCHES.md upstream.patch upstream.sha256 pubspec.lock"
  local relative
  while IFS= read -r relative; do
    grep -qx "[0-9a-f]\{64\}  $relative" "$manifest" && continue
    if [ "$kind" = "pub" ]; then
      case " $allowed_extra " in
        *" $relative "*) continue ;;
      esac
    else
      grep -qxF "$relative" "$package_dir/local.files" && continue
    fi
    fail "$name: $relative is neither recorded in upstream.sha256 nor a known Linthra addition"
  done < <(cd "$package_dir" && git ls-files --cached --others --exclude-standard)

  if [ -f "$patch_file" ]; then
    info "$name: vendored tree is upstream + upstream.patch"
  else
    info "$name: vendored tree is unmodified upstream"
  fi
}

# Analyze the package on its own terms, with the pinned toolchain.
check_analysis() {
  local package_dir="$1" name="$2"

  [ -f "$package_dir/analysis_options.yaml" ] \
    || fail "$name: no analysis_options.yaml — the root one excludes third_party/**, so the package would not be analyzed at all"

  info "$name: resolving dependencies"
  ( cd "$package_dir" && "$FLUTTER" pub get --enforce-lockfile >/dev/null ) \
    || fail "$name: flutter pub get --enforce-lockfile failed"

  info "$name: analyzing"
  ( cd "$package_dir" && "$FLUTTER" analyze ) \
    || fail "$name: flutter analyze reported issues"
}

main() {
  [ -d "$VENDOR_ROOT" ] || { info 'no third_party/ directory; nothing to check'; exit 0; }

  local found=0 package_dir name
  for package_dir in "$VENDOR_ROOT"/*/; do
    package_dir="${package_dir%/}"
    name="$(basename "$package_dir")"
    if [ -f "$package_dir/pubspec.yaml" ]; then
      found=1
      check_provenance "$package_dir" "$name" pub
      if [ "$ANALYZE" -eq 1 ]; then
        check_analysis "$package_dir" "$name"
      fi
    elif [ -f "$package_dir/upstream.sha256" ]; then
      found=1
      check_provenance "$package_dir" "$name" native
    else
      fail "$name: vendored directory has neither pubspec.yaml nor upstream.sha256 (see PATCHES.md of an existing package)"
    fi
  done

  [ "$found" -eq 1 ] || { info 'no vendored packages found'; exit 0; }
  info 'vendored package checks passed'
}

main "$@"
