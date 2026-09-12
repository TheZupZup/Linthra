#!/usr/bin/env bash
#
# verify_native.sh - run Linthra's Rust, C++ and Python checks locally, the way
# CI runs them.
#
# The native/tooling twin of scripts/verify_android.sh (Flutter and Android) and
# scripts/verify_linux.sh (the Linux desktop build). Someone who comes to
# Linthra for the Rust core, the C++ DSP or the Python tooling gets one command
# to run before pushing, instead of reassembling it from three workflows.
#
# What it runs, and where CI runs the same thing:
#
#   Rust    .github/workflows/rust-core.yml, over native/linthra_core:
#           cargo fmt --check, clippy with -D warnings, cargo test, and the
#           200k-track benchmark binary.
#   C++     .github/workflows/cpp-audio-dsp.yml (native/linthra_audio) and
#           .github/workflows/cpp-desktop-window.yml (native/linthra_desktop):
#           cmake configure, cmake --build, ctest, in Release and Debug.
#   Python  .github/workflows/python-lint.yml, plus the tooling unit tests that
#           ci.yml and four other workflows run one file at a time:
#           ruff check, ruff format --check, python3 test/tooling/*_test.py.
#
# A missing toolchain is not a failing check. A section whose tools are not
# installed is skipped with a message saying what to install, the same shape as
# verify_android.sh skipping the APK build when there is no Android SDK, and the
# summary lists everything skipped so a pass is never read as full coverage. A
# check that actually fails makes this script exit non-zero. If nothing could be
# checked at all, that is an error rather than a pass: nothing was verified.
#
# Nothing here writes to tracked files. Cargo builds into
# native/linthra_core/target/ and CMake into build/, both git-ignored, and Ruff
# runs with --check so it reports formatting instead of rewriting it.
#
# scripts/doctor.sh reports the same toolchains without running anything, which
# is the quicker way to find out what a skip message is asking you to install.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Paths stay relative to REPO_ROOT, which main() enters: that keeps every
# command line identical to the workflow's, and keeps a checkout living under a
# directory with spaces in its name out of the arguments entirely.
RUST_MANIFEST="native/linthra_core/Cargo.toml"

# The two CMake projects, in the order their workflows appear. They build
# identically; only the Debug ctest exclusion below tells them apart.
CPP_PROJECTS=(linthra_audio linthra_desktop)

info()    { printf '\n==> %s\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*" >&2; }
section() { printf '\n=== %s ===\n' "$*"; }

FAILED=()
SKIPPED=()
RAN=0

# Run a labelled check; record (but do not abort on) failure, so one pass shows
# a contributor every problem rather than only the first. Returns the check's
# own exit status, which the C++ section uses to stop building after a failed
# configure.
run_step() {
  local label="$1"; shift
  info "$label"
  RAN=$((RAN + 1))
  if "$@"; then
    return 0
  fi
  warn "FAILED: $label"
  FAILED+=("$label")
  return 1
}

# Record something this machine cannot check. Never a failure: it only means the
# tool is not installed here, and CI will still run it. Arguments after the
# reason are printed as install hints.
skip() {
  local label="$1"
  local reason="$2"
  shift 2
  SKIPPED+=("$label ($reason)")
  warn "SKIPPED: $label, $reason"
  local hint
  for hint in "$@"; do
    warn "  $hint"
  done
}

rust_section() {
  section "Rust: native/linthra_core"

  if ! command -v cargo >/dev/null 2>&1; then
    skip "Rust checks" "cargo not found" \
      "Install a stable Rust toolchain from https://rustup.rs (CI uses stable)."
    return
  fi
  cargo --version 2>/dev/null | head -1 || true

  # rustfmt and clippy are rustup components rather than part of cargo itself: a
  # toolchain installed without them has cargo on PATH and still cannot run
  # either. CI asks for both by name (dtolnay/rust-toolchain with components),
  # so ask here too, instead of letting cargo fail with "no such subcommand",
  # which reads like a broken checkout.
  if cargo fmt --version >/dev/null 2>&1; then
    run_step "cargo fmt --check" \
      cargo fmt --manifest-path "$RUST_MANIFEST" -- --check
  else
    skip "cargo fmt --check" "the rustfmt component is not installed" \
      "rustup component add rustfmt"
  fi

  if cargo clippy --version >/dev/null 2>&1; then
    run_step "cargo clippy (warnings are errors)" \
      cargo clippy --locked --manifest-path "$RUST_MANIFEST" \
      --all-targets -- -D warnings
  else
    skip "cargo clippy" "the clippy component is not installed" \
      "rustup component add clippy"
  fi

  run_step "cargo test" cargo test --locked --manifest-path "$RUST_MANIFEST"

  # CI's fourth Rust step, and a real check rather than a report: the binary
  # asserts an average-search budget over a synthetic 200k-track library
  # (native/linthra_core/src/bin/benchmark_200k.rs), so a search regression
  # fails it. It is a release build, but a small and quick one, and leaving it
  # out of the local twin would only move the surprise to CI.
  run_step "cargo run --release --bin benchmark_200k" \
    cargo run --locked --release --manifest-path "$RUST_MANIFEST" \
    --bin benchmark_200k
}

# CMake finds the compiler on its own (CXX first, then c++/g++/clang++ on PATH).
# This asks the same question up front so a machine without one reads as
# "install a compiler" rather than as a CMake configure error.
#
# CXX may carry required options, not just a program name: cmake-env-variables(7)
# documents `CXX="custom-compiler --sysroot=/sdk"`, and looking the whole string
# up as one command would reject a cross toolchain CMake is perfectly happy
# with. Only the first word names a program. A compiler path that itself
# contains spaces is indistinguishable from a path plus options here, which is
# a limitation CMake shares.
#
# The candidate list is CMake's own, from CMakeDetermineCXXCompiler.cmake. A
# shorter list would be the wrong kind of wrong: this gate only decides whether
# to run the C++ checks or skip them, so missing a compiler CMake would have
# found drops real coverage silently, while guessing one that turns out not to
# work costs nothing but a configure error, which is reported as a failure.
CXX_CANDIDATES=(c++ CC g++ aCC cl bcc xlC icpx icx clang++)

cxx_compiler_available() {
  if [ -n "${CXX:-}" ] && command -v "${CXX%% *}" >/dev/null 2>&1; then
    return 0
  fi
  # An IDE generator brings its own toolchain instead of taking one from PATH,
  # so nothing needs to be found here for the build to work.
  case "${CMAKE_GENERATOR:-}" in
    "Visual Studio"*|Xcode|"Green Hills MULTI") return 0 ;;
  esac
  # The same applies when CMAKE_GENERATOR is unset on Windows, where CMake's
  # default is a Visual Studio generator: cl is not on a Git Bash PATH, and
  # cmake-generators(7) notes that "since the IDEs configure their own
  # environment one may launch CMake from any environment". Nothing visible
  # from here can confirm that toolchain, so do not skip the section over it.
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) return 0 ;;
  esac
  local candidate
  for candidate in "${CXX_CANDIDATES[@]}"; do
    command -v "$candidate" >/dev/null 2>&1 && return 0
  done
  return 1
}

cpp_section() {
  section "C++: native/linthra_audio and native/linthra_desktop"

  local missing=()
  local tool
  for tool in cmake ctest; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  cxx_compiler_available || missing+=("a C++17 compiler (g++ or clang++)")

  if [ "${#missing[@]}" -gt 0 ]; then
    # Joined by hand rather than with printf: an entry can contain spaces, so the
    # join has to go through IFS rather than through word splitting.
    local list
    list="$(IFS=','; printf '%s' "${missing[*]}")"
    skip "C++ checks" "missing ${list//,/, }" \
      "Both projects are plain CMake, with no other dependencies: install" \
      "CMake (which provides ctest) and a C++17 compiler from your" \
      "distribution's packages."
    return
  fi
  cmake --version 2>/dev/null | head -1 || true

  local project build_type build_dir
  local ctest_args
  for project in "${CPP_PROJECTS[@]}"; do
    for build_type in Release Debug; do
      # CI gets a fresh runner per matrix leg and can reuse one directory name.
      # One local pass builds both, so each type gets its own directory under
      # the same build/<project> path the workflows use, rather than
      # reconfiguring in place and rebuilding everything on every switch.
      build_dir="build/$project/$build_type"

      run_step "$project $build_type: cmake configure" \
        cmake -S "native/$project" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE="$build_type" || continue
      # --config goes beyond the workflow's command line on purpose. CI's
      # runner uses a single-config generator, where CMAKE_BUILD_TYPE above
      # decides everything; a contributor with CMAKE_GENERATOR set to a
      # multi-config generator (Ninja Multi-Config, Xcode, Visual Studio) has
      # CMAKE_BUILD_TYPE ignored and would build the generator's default
      # config in both legs. It is a no-op for single-config generators.
      run_step "$project $build_type: cmake build" \
        cmake --build "$build_dir" --parallel --config "$build_type" || continue

      ctest_args=()
      if [ "$project" = "linthra_audio" ] && [ "$build_type" = "Debug" ]; then
        # The same exclusion cpp-audio-dsp.yml applies to its Debug leg: an
        # unoptimized build says nothing useful about the realtime budget of
        # the build users actually get.
        ctest_args=(--exclude-regex linthra_audio_realtime_budget)
      fi
      # -C for the same reason, and it matters more here: under a
      # multi-config generator ctest without it reports every test as "Not
      # Run" and exits non-zero, which would read as a broken checkout.
      run_step "$project $build_type: ctest" \
        ctest --test-dir "$build_dir" --output-on-failure -C "$build_type" \
        "${ctest_args[@]+"${ctest_args[@]}"}"
    done
  done
}

# The external Python packages CI installs before it runs these tests, and so
# the only modules whose absence is this machine's problem rather than the
# change's. ci.yml and pr-security-review-tests.yml both pip-install PyYAML;
# everything else the tests import is either stdlib or owned by this
# repository, and a repository module that has gone missing is a broken change,
# not a missing tool. Kept honest by
# test/tooling/verify_native_test.py, which reads the pip installs out of the
# workflows and requires this list to match.
PYTHON_EXTERNAL_MODULES=(yaml)

# Whether a missing module names an external dependency rather than something
# this repository is supposed to provide.
is_external_python_module() {
  local wanted="$1" known
  for known in "${PYTHON_EXTERNAL_MODULES[@]}"; do
    [ "$wanted" = "$known" ] && return 0
  done
  return 1
}

# One tooling test, run the way CI runs it. Output is captured and only printed
# when the test fails, the same bargain `ctest --output-on-failure` makes: a
# clean run stays readable, a broken one shows everything.
#
# A test that cannot even import what it needs is reported as a skip rather than
# a failure. PyYAML is the live example: ci.yml pip-installs it right before the
# Flatpak smoke manifest tests, so on a machine without it that one file is a
# missing tool, not a broken change, and failing the whole run for it would tell
# a contributor nothing about what they are about to push.
run_python_test() {
  local path="$1"
  local output status module
  output="$(python3 "$path" 2>&1)"
  status=$?

  if [ "$status" -eq 0 ]; then
    RAN=$((RAN + 1))
    printf '  ok    %s\n' "$path"
    return 0
  fi

  # A skip has to clear two bars, because getting either wrong means a real
  # regression leaves the run looking clean.
  #
  # First, the file must have failed *before any test ran*: unittest prints a
  # "Ran N tests" line as soon as it has run something, so the absence of that
  # line is what separates "this machine cannot run the file at all" from "the
  # file ran and something failed". Without it, a genuine failure whose output
  # merely quotes a ModuleNotFoundError would be downgraded to a skip.
  #
  # Second, the missing module must be one CI installs rather than one this
  # repository owns. Several of these tests import a repository module at the
  # top of the file (test/tooling/large_library_memory_report_test.py takes
  # memory_report from tools/large_library/, for instance). If a change removes
  # or renames one, the import fails in exactly the shape a missing dependency
  # does, and calling that a skip would pass the very change CI is about to
  # reject.
  if ! printf '%s\n' "$output" | grep -q '^Ran [0-9]'; then
    module="$(printf '%s\n' "$output" |
      sed -n "s/.*ModuleNotFoundError: No module named '\([^']*\)'.*/\1/p" |
      head -1)"
    if [ -n "$module" ] && is_external_python_module "$module"; then
      printf '  skip  %s (needs the %s Python module)\n' "$path" "$module"
      SKIPPED+=("python3 $path (needs the $module Python module)")
      return 0
    fi
  fi

  RAN=$((RAN + 1))
  printf '  FAIL  %s\n' "$path"
  printf '%s\n' "$output"
  FAILED+=("python3 $path")
  return 1
}

# The Python unit tests under test/tooling/. CI runs them one `python3
# test/tooling/<name>.py` step at a time, spread over ci.yml,
# linux-desktop-build.yml, flatpak-build.yml, pr-security-review-tests.yml and
# large-library-sql.yml. Repeating that list here would mean maintaining it in a
# sixth place, so this runs whatever the directory holds: a test added to it is
# picked up without anyone remembering to touch this script.
python_tooling_tests() {
  # A glob rather than `find`: one fewer external tool in the way, and no way
  # for a failure inside a process substitution to arrive here looking like an
  # empty directory. That distinction matters, because "no tests found" is
  # reported as a skip, so a silently broken listing would quietly drop the
  # whole Python suite from the run.
  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local tests=(test/tooling/*_test.py)
  [ "$had_nullglob" -eq 1 ] || shopt -u nullglob

  local path

  if [ "${#tests[@]}" -eq 0 ]; then
    skip "Python tooling tests" "no test/tooling/*_test.py files found"
    return
  fi

  info "Python tooling tests (${#tests[@]} files under test/tooling/)"
  for path in "${tests[@]}"; do
    run_python_test "$path"
  done
}

python_section() {
  section "Python: scripts/, tool/, tools/ and test/tooling/"

  if ! command -v python3 >/dev/null 2>&1; then
    skip "Python checks" "python3 not found" \
      "Install Python 3 from your distribution's packages."
    return
  fi
  python3 --version 2>/dev/null | head -1 || true

  # The two commands python-lint.yml runs, with the three paths it passes.
  # ruff.toml only adds excludes, it does not set the scope, so a bare
  # `ruff check .` is a different check (ruff.toml explains this at length).
  # --check on the formatter is the point rather than a detail: this script
  # reports formatting, it never rewrites a file.
  if command -v ruff >/dev/null 2>&1; then
    ruff --version 2>/dev/null | head -1 || true
    run_step "ruff check scripts tool tools" ruff check scripts tool tools
    run_step "ruff format --check scripts tool tools" \
      ruff format --check scripts tool tools
  else
    skip "ruff check and ruff format --check" "ruff not found" \
      "python3 -m pip install ruff" \
      "CI pins an exact version; .github/workflows/python-lint.yml has it," \
      "and matching it locally avoids disagreeing about formatting."
  fi

  python_tooling_tests
}

main() {
  cd "$REPO_ROOT" || {
    printf 'ERROR: cannot enter %s\n' "$REPO_ROOT" >&2
    exit 1
  }

  # A checkout is the only place these checks mean anything, and every command
  # below is relative to it. If REPO_ROOT came out wrong, say so here rather
  # than running cargo and cmake against whatever directory we landed in.
  if [ ! -f "$RUST_MANIFEST" ] || [ ! -d "test/tooling" ]; then
    printf 'ERROR: %s does not look like a Linthra checkout.\n' "$REPO_ROOT" >&2
    exit 1
  fi

  rust_section
  cpp_section
  python_section

  section "Summary"

  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    printf '\nSkipped %d check(s) for want of the tools they need.\n' \
      "${#SKIPPED[@]}"
    printf 'CI still runs every one of them:\n'
    printf '  - %s\n' "${SKIPPED[@]}"
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '\nFailed %d check(s):\n' "${#FAILED[@]}"
    printf '  - %s\n' "${FAILED[@]}"
    printf '\nVerification FAILED.\n'
    exit 1
  fi

  # Everything skipped is not a pass. Same call verify_android.sh makes when
  # there is no Flutter at all: the script could not answer the question it
  # exists to answer, and saying "passed" would be worse than saying nothing.
  if [ "$RAN" -eq 0 ]; then
    printf '\nNothing could be checked: no Rust, C++ or Python toolchain was\n'
    printf 'found. Run ./scripts/doctor.sh to see what is detected, and\n'
    printf 'install at least one of them.\n'
    exit 1
  fi

  printf '\nVerification passed (%d check(s) ran).\n' "$RAN"
}

main "$@"
