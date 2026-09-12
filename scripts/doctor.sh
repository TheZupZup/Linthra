#!/usr/bin/env bash
#
# doctor.sh — quick read-only report of the dev toolchain state.
# Tells you what's pinned, which Flutter would be used, whether an Android SDK
# is present, and which of the Rust, C++ and Python toolchains
# scripts/verify_native.sh needs are installed. Makes no changes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$REPO_ROOT/.flutter-version"
JDK_VERSION_FILE="$REPO_ROOT/.java-version"
LOCAL_FLUTTER_BIN="$REPO_ROOT/.tool/flutter/bin/flutter"

line() { printf '%-22s %s\n' "$1" "$2"; }

required="(none)"
[ -f "$VERSION_FILE" ] && required="$(tr -d '[:space:]' < "$VERSION_FILE")"
line "Pinned Flutter:" "$required"

required_jdk="(none)"
[ -f "$JDK_VERSION_FILE" ] && required_jdk="$(tr -d '[:space:]' < "$JDK_VERSION_FILE")"
line "Pinned JDK:" "$required_jdk"

if [ -x "$LOCAL_FLUTTER_BIN" ]; then
  line "Project-local Flutter:" "$LOCAL_FLUTTER_BIN"
  line "  version:" "$("$LOCAL_FLUTTER_BIN" --version 2>/dev/null | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1)"
else
  line "Project-local Flutter:" "not installed (run ./scripts/setup_flutter.sh)"
fi

if command -v flutter >/dev/null 2>&1; then
  line "Flutter on PATH:" "$(command -v flutter)"
  line "  version:" "$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9][0-9.]*\).*/\1/p' | head -1)"
else
  line "Flutter on PATH:" "none"
fi

# The JDK only matters for Android builds; analyze/format/test never need it.
if command -v java >/dev/null 2>&1; then
  line "Java on PATH:" "$(command -v java)"
  line "  version:" "$(java -version 2>&1 | sed -n 's/^[A-Za-z ]*version "\([0-9][0-9._]*\).*/\1/p' | head -1)"
else
  line "Java on PATH:" "none (only needed for Android builds)"
fi

if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}" ]; then
  line "Android SDK:" "ANDROID_HOME=$ANDROID_HOME"
elif [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "${ANDROID_SDK_ROOT}" ]; then
  line "Android SDK:" "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
elif command -v adb >/dev/null 2>&1 || command -v sdkmanager >/dev/null 2>&1; then
  line "Android SDK:" "tools on PATH (adb/sdkmanager)"
else
  line "Android SDK:" "not detected (APK build will be skipped)"
fi

# The Rust, C++ and Python toolchains scripts/verify_native.sh runs on. That
# script asks these same questions before it runs or skips a section, so this is
# the quick way to find out what one of its skip messages wants installed.
printf '\n'

if command -v cargo >/dev/null 2>&1; then
  line "Rust (cargo):" "$(cargo --version 2>/dev/null | head -1)"
  # rustfmt and clippy are rustup components rather than part of cargo: cargo
  # can be on PATH while `cargo fmt` and `cargo clippy` are unknown
  # subcommands, and CI asks for both by name.
  if cargo fmt --version >/dev/null 2>&1; then
    line "  rustfmt:" "$(cargo fmt --version 2>/dev/null | head -1)"
  else
    line "  rustfmt:" "missing (rustup component add rustfmt)"
  fi
  if cargo clippy --version >/dev/null 2>&1; then
    line "  clippy:" "$(cargo clippy --version 2>/dev/null | head -1)"
  else
    line "  clippy:" "missing (rustup component add clippy)"
  fi
else
  line "Rust (cargo):" "none (see https://rustup.rs)"
fi

if command -v cmake >/dev/null 2>&1; then
  line "CMake:" "$(cmake --version 2>/dev/null | head -1)"
else
  line "CMake:" "none (needed for the C++ in native/)"
fi

if command -v ctest >/dev/null 2>&1; then
  line "  ctest:" "$(command -v ctest)"
else
  line "  ctest:" "none (it ships with CMake)"
fi

# Same order CMake itself resolves a compiler in: $CXX, then what is on PATH.
# CXX may carry required options as well as a program name (cmake-env-variables(7)
# documents `CXX="custom-compiler --sysroot=/sdk"`), so only its first word is a
# command to look for. Kept in step with cxx_compiler_available() in
# scripts/verify_native.sh, which gates the C++ checks on the same question.
CXX_FOUND="${CXX:-}"
CXX_FOUND="${CXX_FOUND%% *}"
if [ -z "$CXX_FOUND" ]; then
  # CMake's own candidate list, from CMakeDetermineCXXCompiler.cmake, so this
  # report does not call a compiler missing that CMake would have found.
  for candidate in c++ CC g++ aCC cl bcc xlC icpx icx clang++; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CXX_FOUND="$candidate"
      break
    fi
  done
fi
if [ -n "$CXX_FOUND" ] && command -v "$CXX_FOUND" >/dev/null 2>&1; then
  line "C++ compiler:" "$(command -v "$CXX_FOUND")"
else
  line "C++ compiler:" "none (install g++ or clang++)"
fi

if command -v python3 >/dev/null 2>&1; then
  line "Python 3:" "$(python3 --version 2>&1 | head -1)"
else
  line "Python 3:" "none (needed by the tooling checks and tests)"
fi

if command -v ruff >/dev/null 2>&1; then
  line "  Ruff:" "$(ruff --version 2>/dev/null | head -1)"
else
  line "  Ruff:" "none (python3 -m pip install ruff)"
fi
