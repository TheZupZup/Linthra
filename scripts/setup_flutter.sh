#!/usr/bin/env bash
#
# setup_flutter.sh — install the Flutter version this project is pinned to.
#
# Goal: a contributor or agent can run this once and get a Flutter toolchain
# that matches CI, without sudo and without committing the SDK. It is safe to
# run repeatedly: an existing matching install (on PATH or project-local) is
# reused instead of re-downloaded.
#
# The pinned version lives in .flutter-version (single source of truth). The
# SDK is installed into .tool/flutter, which is git-ignored.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$REPO_ROOT/.flutter-version"
TOOL_DIR="$REPO_ROOT/.tool"
FLUTTER_DIR="$TOOL_DIR/flutter"
LOCAL_FLUTTER_BIN="$FLUTTER_DIR/bin/flutter"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- helpers ---------------------------------------------------------------

read_required_version() {
  [ -f "$VERSION_FILE" ] || die "missing $VERSION_FILE (the pinned Flutter version)"
  local v
  v="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [ -n "$v" ] || die "$VERSION_FILE is empty"
  printf '%s' "$v"
}

# Version of a Flutter SDK directory, read from its fast offline `version`
# file when present, otherwise by invoking the binary.
flutter_version_of() {
  local bin="$1"
  local sdk_version_file
  sdk_version_file="$(dirname "$(dirname "$bin")")/version"
  if [ -f "$sdk_version_file" ]; then
    tr -d '[:space:]' < "$sdk_version_file"
    return 0
  fi
  "$bin" --version 2>/dev/null | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1
}

# Echo the download URL for the pinned version on this OS/arch.
flutter_download_url() {
  local version="$1" os arch platform ext
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)  platform="linux";  ext="tar.xz" ;;
    Darwin) platform="macos";  ext="zip" ;;
    *) die "unsupported OS '$os' — install Flutter $version manually (see docs/development.md)" ;;
  esac

  local arch_suffix=""
  if [ "$platform" = "macos" ] && [ "$arch" = "arm64" ]; then
    arch_suffix="_arm64"
  fi

  printf 'https://storage.googleapis.com/flutter_infra_release/releases/stable/%s/flutter_%s%s_%s-stable.%s' \
    "$platform" "$platform" "$arch_suffix" "$version" "$ext"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

download() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$out" "$url" || die "download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url" || die "download failed: $url"
  else
    die "need either 'curl' or 'wget' to download Flutter"
  fi
}

extract() {
  local archive="$1" dest="$2"
  case "$archive" in
    *.tar.xz) require_cmd tar; tar -xJf "$archive" -C "$dest" || die "extract failed: $archive" ;;
    *.zip)    require_cmd unzip; unzip -q "$archive" -d "$dest" || die "extract failed: $archive" ;;
    *) die "unknown archive type: $archive" ;;
  esac
}

install_flutter() {
  local version="$1" url tmp_dir archive
  url="$(flutter_download_url "$version")"

  info "Downloading Flutter $version"
  info "  from $url"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/flutter-setup.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp_dir'" RETURN

  archive="$tmp_dir/${url##*/}"
  download "$url" "$archive"

  info "Extracting into $FLUTTER_DIR"
  mkdir -p "$TOOL_DIR"
  rm -rf "$FLUTTER_DIR"
  # Archives unpack a top-level `flutter/` directory into TOOL_DIR.
  extract "$archive" "$TOOL_DIR"
  [ -x "$LOCAL_FLUTTER_BIN" ] || die "extracted SDK is missing $LOCAL_FLUTTER_BIN"
}

print_path_help() {
  cat <<EOF

Flutter $1 is ready in: $FLUTTER_DIR

To use it in this shell:

  export PATH="$FLUTTER_DIR/bin:\$PATH"

Then verify the project with:

  ./scripts/verify_android.sh

(The verification script auto-detects this project-local Flutter, so the
export above is only needed if you want to run flutter/dart directly.)
EOF
}

# --- main -------------------------------------------------------------------

main() {
  local required
  required="$(read_required_version)"
  info "Pinned Flutter version: $required"

  # 1. Reuse a project-local install if it already matches.
  if [ -x "$LOCAL_FLUTTER_BIN" ]; then
    local local_version
    local_version="$(flutter_version_of "$LOCAL_FLUTTER_BIN")"
    if [ "$local_version" = "$required" ]; then
      info "Project-local Flutter already matches ($local_version)."
      print_path_help "$required"
      return 0
    fi
    warn "Project-local Flutter is $local_version, expected $required — reinstalling."
  fi

  # 2. Reuse a matching Flutter already on PATH (don't disturb the contributor's
  #    own install if it is the right version).
  if command -v flutter >/dev/null 2>&1; then
    local path_bin path_version
    path_bin="$(command -v flutter)"
    path_version="$(flutter_version_of "$path_bin")"
    if [ "$path_version" = "$required" ]; then
      info "Flutter $path_version already on PATH ($path_bin) — using it, nothing to install."
      return 0
    fi
    warn "Flutter on PATH is $path_version, project needs $required."
    warn "Installing a project-local $required so dev/CI stay consistent."
  fi

  # 3. Install the pinned version locally.
  install_flutter "$required"

  local installed
  installed="$(flutter_version_of "$LOCAL_FLUTTER_BIN")"
  [ "$installed" = "$required" ] || warn "installed version reports '$installed' (expected '$required')"

  info "Done."
  print_path_help "$required"
}

main "$@"
