#!/usr/bin/env python3
"""`scripts/verify_native.sh` is a faithful, read-only local twin of CI (#354).

    python3 test/tooling/verify_native_test.py

The script exists so a Rust, C++ or Python contributor has one command to run
before pushing. That is only worth anything if it runs what CI runs, so two
kinds of test here:

  * agreement rules, which read the workflows and the script and require them
    to still say the same thing. The ctest exclusion and the three Ruff paths
    are the ones most likely to drift, because they live in a workflow the
    script never reads;
  * the real script, run end to end against stub `cargo`, `cmake`, `ctest` and
    `ruff` binaries in a throwaway checkout. The stubs record their argv, so
    "it runs the same command CI runs" is checked rather than asserted, and
    they can be told to fail, which is how the exit code, the keep-going
    behaviour and the skip-vs-fail distinction get proven.

The end-to-end checkout lives under a directory with a space in its name, so
every run is also a test that the quoting holds.

Nothing here needs Rust, CMake or Ruff installed: the point of the stubs is
that this suite says the same thing on a machine that has none of them.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify_native.sh"
WORKFLOWS = ROOT / ".github" / "workflows"

# Real tools the script itself needs. Everything else on PATH is deliberately
# withheld, so "cargo is not installed" can be staged by simply not writing a
# cargo stub.
PASSTHROUGH_TOOLS = (
    "bash",
    "sh",
    "env",
    "dirname",
    "find",
    "sort",
    "grep",
    "sed",
    "head",
    "python3",
)

# A stub records `name<TAB>arg<TAB>arg...` and exits non-zero when the test
# named it in LINTHRA_STUB_FAIL. The key is the command plus its first
# argument, with `:--version` appended for a probe, so "clippy is not
# installed" (`cargo:clippy:--version`) and "clippy found problems"
# (`cargo:clippy`) are different things to ask for.
STUB = """#!/usr/bin/env bash
name="${0##*/}"
key="$name:${1:-}"
for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    key="$key:--version"
    break
  fi
done

printf '%s' "$name" >> "$LINTHRA_STUB_LOG"
for arg in "$@"; do
  printf '\\t%s' "$arg" >> "$LINTHRA_STUB_LOG"
done
printf '\\n' >> "$LINTHRA_STUB_LOG"

case " ${LINTHRA_STUB_FAIL:-} " in
  *" $key "*)
    printf '%s: stubbed failure\\n' "$key" >&2
    exit 1
    ;;
esac
exit 0
"""

# A tooling test that passes, one that fails, and one that cannot import what
# it needs. The third is the PyYAML shape: ci.yml pip-installs PyYAML right
# before the Flatpak smoke manifest tests, so on a machine without it that file
# is a missing tool rather than a broken change.
PASSING_TEST = "import sys\nsys.exit(0)\n"
FAILING_TEST = (
    "import sys\nsys.stderr.write('a real assertion failed\\n')\nsys.exit(1)\n"
)
# Fails to import an external dependency, in the shape a real one does, but
# without depending on whether this machine happens to have PyYAML installed.
MISSING_EXTERNAL_DEPENDENCY_TEST = (
    "raise ModuleNotFoundError(\"No module named 'yaml'\")\n"
)
# The same shape, for a module this repository is supposed to provide.
# test/tooling/large_library_memory_report_test.py really does import
# memory_report from tools/large_library/ at the top of the file, so renaming
# that module produces exactly this.
MISSING_REPOSITORY_MODULE_TEST = (
    "raise ModuleNotFoundError(\"No module named 'memory_report'\")\n"
)
# Runs, fails for real, and quotes a ModuleNotFoundError while doing it: a test
# asserting on how some tool reports a missing dependency looks exactly like
# this. The output must not be mistaken for the file failing to import.
FAILING_TEST_QUOTING_AN_IMPORT_ERROR = """import sys
import unittest


class T(unittest.TestCase):
    def test_a_genuine_regression(self):
        self.assertEqual("ModuleNotFoundError: No module named 'x'", "clean")


if __name__ == "__main__":
    unittest.main(verbosity=2, exit=False)
    sys.exit(1)
"""


def script_text() -> str:
    return SCRIPT.read_text(encoding="utf-8")


def workflow_text(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class TheScriptItself(unittest.TestCase):
    """Rules about the file, before anything is run."""

    def test_it_is_executable_and_bash(self) -> None:
        self.assertTrue(SCRIPT.exists(), msg="scripts/verify_native.sh is missing")
        self.assertTrue(
            os.access(SCRIPT, os.X_OK),
            msg="CONTRIBUTING.md tells people to run ./scripts/verify_native.sh",
        )
        self.assertTrue(script_text().startswith("#!/usr/bin/env bash\n"))

    def test_the_formatter_is_never_asked_to_rewrite_a_file(self) -> None:
        """A verify script that reformats the tree is a trap, not a check."""
        for match in re.finditer(r"^\s*(ruff format[^\n]*)$", script_text(), re.M):
            self.assertIn(
                "--check",
                match.group(1),
                msg="`ruff format` without --check edits the working tree",
            )
        for match in re.finditer(r"^\s*(cargo fmt[^\n]*)$", script_text(), re.M):
            line = match.group(1)
            if line.endswith("--version >/dev/null 2>&1; then"):
                continue
            self.assertIn(
                "--",
                line,
                msg="`cargo fmt` without `-- --check` rewrites the Rust sources",
            )

    def test_the_tooling_tests_are_found_by_glob_not_by_find(self) -> None:
        """ "No tests found" is a skip, so the listing must not be able to fail.

        A `find` inside a process substitution hands the reading loop a
        successful status whatever happened, so a listing that broke for any
        reason would arrive looking like an empty directory and drop the whole
        Python suite from the run without saying so.
        """
        text = script_text()
        self.assertIn("local tests=(test/tooling/*_test.py)", text)
        self.assertNotIn("find test/tooling", text)

    def test_every_section_names_the_workflow_it_stands_in_for(self) -> None:
        """A reader has to be able to get from the script back to CI."""
        for workflow in (
            "rust-core.yml",
            "cpp-audio-dsp.yml",
            "cpp-desktop-window.yml",
            "python-lint.yml",
        ):
            self.assertIn(workflow, script_text())


class AgreementWithCI(unittest.TestCase):
    """The parts most able to drift, because they live in two files."""

    def test_the_rust_commands_carry_the_flags_the_workflow_uses(self) -> None:
        rust = workflow_text("rust-core.yml")
        text = script_text()
        # --locked is the interesting one: without it a stale Cargo.lock is
        # quietly resolved locally and only fails on the CI runner.
        for flag in ("--locked", "--all-targets", "-D warnings", "benchmark_200k"):
            self.assertIn(flag, rust, msg="rust-core.yml no longer uses " + flag)
            self.assertIn(
                flag,
                text,
                msg="rust-core.yml uses {} and verify_native.sh does not".format(flag),
            )

    def test_the_rust_manifest_is_the_one_the_workflow_builds(self) -> None:
        manifests = set(
            re.findall(r"--manifest-path (\S+)", workflow_text("rust-core.yml"))
        )
        self.assertEqual(manifests, {"native/linthra_core/Cargo.toml"})
        self.assertIn('RUST_MANIFEST="native/linthra_core/Cargo.toml"', script_text())

    def test_the_debug_ctest_exclusion_matches_the_workflow(self) -> None:
        """CI skips the realtime budget in Debug; so must the local twin.

        An unoptimized build says nothing useful about the performance of the
        build users actually get, so a local run that kept the budget test in
        Debug would fail for a reason CI never would.
        """
        excluded = [
            name.strip("'\"")
            for name in re.findall(
                r"--exclude-regex (\S+)", workflow_text("cpp-audio-dsp.yml")
            )
        ]
        self.assertEqual(len(excluded), 1, msg="the workflow's exclusion changed shape")
        self.assertIn(
            "ctest_args=(--exclude-regex {})".format(excluded[0]),
            script_text(),
        )

    def test_both_cmake_projects_are_covered(self) -> None:
        sources = set()
        for name in ("cpp-audio-dsp.yml", "cpp-desktop-window.yml"):
            sources.update(re.findall(r"cmake -S native/(\w+)", workflow_text(name)))
        self.assertEqual(sources, {"linthra_audio", "linthra_desktop"})
        self.assertIn(
            "CPP_PROJECTS=({})".format(" ".join(sorted(sources))),
            script_text(),
        )

    def test_the_compiler_gate_is_no_narrower_than_CMake_s_detection(self) -> None:
        """Missing a compiler CMake would find drops coverage silently.

        The gate only chooses between running the C++ checks and skipping
        them, so it should err wide: a compiler that turns out not to work
        costs a configure error, which is reported as a failure, while one the
        gate fails to see costs the whole section with nothing said.
        """
        # CMakeDetermineCXXCompiler.cmake's candidates.
        for candidate in (
            "c++",
            "CC",
            "g++",
            "aCC",
            "cl",
            "bcc",
            "xlC",
            "icpx",
            "icx",
            "clang++",
        ):
            self.assertIn(
                candidate,
                script_text().split("CXX_CANDIDATES=(")[1].split(")")[0].split(),
            )
        # An IDE generator supplies its own toolchain rather than taking one
        # from PATH, so nothing has to be found for the build to work.
        self.assertIn('"Visual Studio"*', script_text())

    def test_the_ruff_paths_are_the_ones_the_workflow_passes(self) -> None:
        """ruff.toml sets the rules, not the scope: the paths are the scope."""
        lint = workflow_text("python-lint.yml")
        paths = set(re.findall(r"ruff (?:check|format --check) ([\w /]+)", lint))
        self.assertEqual(paths, {"scripts tool tools"})
        self.assertIn("ruff check scripts tool tools", script_text())
        self.assertIn("ruff format --check scripts tool tools", script_text())

    def test_the_skippable_modules_are_the_ones_CI_installs(self) -> None:
        """Only an external dependency may excuse a test from running.

        CI pip-installs what the tooling tests need beyond stdlib, so that set
        is the whole of what this machine can legitimately be missing.
        Anything else is owned by this repository, and its absence is a broken
        change rather than a missing tool.
        """
        installed: set[str] = set()
        for path in sorted((WORKFLOWS).glob("*.yml")):
            text = path.read_text(encoding="utf-8")
            for match in re.finditer(r"pip install [^\n]*", text):
                for package in re.findall(
                    r"[\"']?([A-Za-z][\w.-]+)[\"']?", match.group(0)
                ):
                    if package in ("pip", "install", "python3", "m", "quiet"):
                        continue
                    installed.add(package.split("==")[0].lower())
        self.assertIn("pyyaml", installed, msg="CI stopped installing PyYAML")

        declared = set(
            script_text().split("PYTHON_EXTERNAL_MODULES=(")[1].split(")")[0].split()
        )
        # PyYAML is the distribution; yaml is what a failed import names.
        self.assertEqual(
            declared,
            {"yaml"},
            msg=(
                "the skippable set drifted from what CI installs "
                "({}); widening it lets a broken repository module "
                "pass as a missing tool".format(sorted(installed))
            ),
        )

    def test_no_ruff_version_is_pinned_in_two_places(self) -> None:
        """The pin lives in python-lint.yml. A copy here would rot."""
        self.assertNotRegex(script_text(), r"ruff==\d")


class StubHarness(unittest.TestCase):
    """Runs the real script in a throwaway checkout, against stub binaries."""

    maxDiff = None

    def _run(
        self,
        *,
        tools: tuple[str, ...] = ("cargo", "cmake", "ctest", "c++", "ruff"),
        fail: tuple[str, ...] = (),
        tooling_tests: dict[str, str] | None = None,
        env: dict[str, str] | None = None,
    ) -> "_Run":
        """Run verify_native.sh with exactly `tools` available on PATH.

        `fail` names stub invocations that should exit non-zero, and
        `tooling_tests` is the contents of test/tooling/, defaulting to a
        single test that passes.
        """
        tmp = Path(tempfile.mkdtemp(prefix="linthra-verify-native-"))
        self.addCleanup(shutil.rmtree, tmp, True)

        # The space is deliberate and permanent: every run in this suite is
        # also a test that the script's quoting survives a checkout under
        # "~/My Projects/..." or an macOS-style path.
        repo = tmp / "a checkout with spaces"
        bin_dir = tmp / "stub bin"
        for path in (repo, bin_dir):
            path.mkdir(parents=True)

        (repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, repo / "scripts" / "verify_native.sh")
        # The two trees the script's own "is this a checkout" guard looks for,
        # plus the CMake sources it points cmake at.
        (repo / "native" / "linthra_core").mkdir(parents=True)
        (repo / "native" / "linthra_core" / "Cargo.toml").write_text(
            '[package]\nname = "linthra_core"\n', encoding="utf-8"
        )
        for project in ("linthra_audio", "linthra_desktop"):
            (repo / "native" / project).mkdir(parents=True)
            (repo / "native" / project / "CMakeLists.txt").write_text(
                "project({})\n".format(project), encoding="utf-8"
            )
        (repo / "test" / "tooling").mkdir(parents=True)
        if tooling_tests is None:
            tooling_tests = {"example_test.py": PASSING_TEST}
        for name, body in tooling_tests.items():
            (repo / "test" / "tooling" / name).write_text(body, encoding="utf-8")

        for name in PASSTHROUGH_TOOLS:
            real = shutil.which(name)
            if real is not None:
                (bin_dir / name).symlink_to(real)
        for name in tools:
            stub = bin_dir / name
            stub.write_text(STUB, encoding="utf-8")
            stub.chmod(0o755)

        log = tmp / "stub-calls.tsv"
        log.touch()
        before = _snapshot(repo)
        process = subprocess.run(
            ["bash", str(repo / "scripts" / "verify_native.sh")],
            cwd=str(tmp),
            env={
                "PATH": str(bin_dir),
                "HOME": str(tmp),
                "LINTHRA_STUB_LOG": str(log),
                "LINTHRA_STUB_FAIL": " ".join(fail),
                **(env or {}),
            },
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
        calls = [
            line.split("\t")
            for line in log.read_text(encoding="utf-8").splitlines()
            if line
        ]
        return _Run(
            process=process,
            output=process.stdout + process.stderr,
            calls=calls,
            repo=repo,
            before=before,
        )

    @staticmethod
    def _calls(run: "_Run", name: str, *, probes: bool = False) -> list[list[str]]:
        """The recorded argv for `name`, without the version probes."""
        return [
            call
            for call in run.calls
            if call[0] == name and (probes or "--version" not in call)
        ]


class RunAgainstStubs(StubHarness):
    """What a clean run does."""

    def test_a_clean_run_passes_and_says_what_it_ran(self) -> None:
        run = self._run()
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn("Verification passed", run.output)
        self.assertNotIn("SKIPPED", run.output)

    def test_the_three_sections_are_labelled_and_in_CI_order(self) -> None:
        run = self._run()
        headers = re.findall(r"^=== (.+?):", run.output, re.M)
        self.assertEqual(headers, ["Rust", "C++", "Python"], msg=run.output)

    def test_it_runs_the_rust_commands_the_workflow_runs(self) -> None:
        run = self._run()
        cargo = [" ".join(call) for call in self._calls(run, "cargo")]
        manifest = "--manifest-path native/linthra_core/Cargo.toml"
        self.assertEqual(
            cargo,
            [
                "cargo fmt {} -- --check".format(manifest),
                "cargo clippy --locked {} --all-targets -- -D warnings".format(
                    manifest
                ),
                "cargo test --locked {}".format(manifest),
                "cargo run --locked --release {} --bin benchmark_200k".format(manifest),
            ],
            msg=run.output,
        )

    def test_it_configures_builds_and_tests_both_projects_both_ways(self) -> None:
        run = self._run()
        configured = [
            (call[2].split("/")[-1], call[4], call[5])
            for call in self._calls(run, "cmake")
            if call[1] == "-S"
        ]
        self.assertEqual(
            configured,
            [
                (
                    "linthra_audio",
                    "build/linthra_audio/Release",
                    "-DCMAKE_BUILD_TYPE=Release",
                ),
                (
                    "linthra_audio",
                    "build/linthra_audio/Debug",
                    "-DCMAKE_BUILD_TYPE=Debug",
                ),
                (
                    "linthra_desktop",
                    "build/linthra_desktop/Release",
                    "-DCMAKE_BUILD_TYPE=Release",
                ),
                (
                    "linthra_desktop",
                    "build/linthra_desktop/Debug",
                    "-DCMAKE_BUILD_TYPE=Debug",
                ),
            ],
            msg=run.output,
        )
        built = [call[2] for call in self._calls(run, "cmake") if call[1] == "--build"]
        tested = [call[2] for call in self._calls(run, "ctest")]
        self.assertEqual(built, [c[1] for c in configured])
        self.assertEqual(tested, [c[1] for c in configured])

    def test_the_build_and_the_tests_name_the_configuration(self) -> None:
        """Under a multi-config generator, CMAKE_BUILD_TYPE alone is ignored.

        CI's runner uses a single-config generator, so the workflows get away
        with setting only CMAKE_BUILD_TYPE. A contributor with CMAKE_GENERATOR
        set to Ninja Multi-Config, Xcode or Visual Studio would otherwise build
        the generator's default config in both legs, and ctest without -C
        reports every test as "Not Run" and exits non-zero.
        """
        run = self._run()
        for call in self._calls(run, "cmake"):
            if call[1] != "--build":
                continue
            self.assertIn("--config", call, msg=" ".join(call))
            self.assertEqual(
                call[call.index("--config") + 1],
                call[2].split("/")[-1],
                msg="built a different configuration than the directory is for",
            )
        for call in self._calls(run, "ctest"):
            self.assertIn("-C", call, msg=" ".join(call))
            self.assertEqual(
                call[call.index("-C") + 1],
                call[2].split("/")[-1],
                msg="tested a different configuration than was built",
            )

    def test_only_the_audio_debug_leg_drops_the_realtime_budget(self) -> None:
        run = self._run()
        excluding = [
            call[2] for call in self._calls(run, "ctest") if "--exclude-regex" in call
        ]
        self.assertEqual(excluding, ["build/linthra_audio/Debug"], msg=run.output)

    def test_it_runs_the_two_ruff_commands_with_the_workflow_s_paths(self) -> None:
        run = self._run()
        ruff = [" ".join(call) for call in self._calls(run, "ruff")]
        self.assertEqual(
            ruff,
            [
                "ruff check scripts tool tools",
                "ruff format --check scripts tool tools",
            ],
            msg=run.output,
        )

    def test_nothing_in_the_checkout_is_touched_by_a_passing_run(self) -> None:
        """A verify script that edits the tree would be worse than none."""
        run = self._run()
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertEqual(
            _snapshot(run.repo),
            run.before,
            msg="the run added, removed or rewrote something in the checkout",
        )


class FailuresAreFailures(StubHarness):
    """An actual check failing has to reach the exit code."""

    def test_a_failing_clippy_fails_the_script_and_is_named(self) -> None:
        run = self._run(fail=("cargo:clippy",))
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        self.assertIn("Verification FAILED", run.output)
        self.assertIn("cargo clippy", run.output)

    def test_one_failure_does_not_stop_the_other_sections(self) -> None:
        """One pass should show a contributor every problem, not the first."""
        run = self._run(fail=("cargo:clippy", "ruff:check"))
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        # The C++ section sits between the two and has to have run anyway.
        self.assertTrue(
            [c for c in run.calls if c[0] == "ctest"],
            msg="a failing Rust check stopped the C++ checks:\n" + run.output,
        )
        failed = _summary_items(run.output, "Failed")
        self.assertEqual(len(failed), 2, msg=run.output)

    def test_a_failing_build_does_not_pretend_to_test_it(self) -> None:
        """ctest against a directory that never built is noise, not a result."""
        run = self._run(fail=("cmake:--build",))
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        self.assertEqual(
            [c for c in run.calls if c[0] == "ctest"],
            [],
            msg="ctest ran even though every build failed:\n" + run.output,
        )

    def test_a_real_failure_quoting_an_import_error_is_still_a_failure(self) -> None:
        """The skip is for a file that cannot start, not for any mention of it.

        Classifying on the error string alone would downgrade a genuine
        regression whose output happens to quote a ModuleNotFoundError, and the
        whole run would exit 0 with that regression hidden inside it.
        """
        run = self._run(
            tooling_tests={"quoting_test.py": FAILING_TEST_QUOTING_AN_IMPORT_ERROR}
        )
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        self.assertIn("FAIL  test/tooling/quoting_test.py", run.output)
        self.assertNotIn("skip  test/tooling/quoting_test.py", run.output)

    def test_a_missing_repository_module_is_a_failure_not_a_skip(self) -> None:
        """A module this repo owns going missing is a broken change.

        Several tooling tests import a repository module at the top of the
        file, so removing or renaming one fails the import in exactly the shape
        a missing dependency does. Calling that a skip would pass the very
        change CI is about to reject.
        """
        run = self._run(
            tooling_tests={
                "ok_test.py": PASSING_TEST,
                "repo_module_test.py": MISSING_REPOSITORY_MODULE_TEST,
            }
        )
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        self.assertIn("FAIL  test/tooling/repo_module_test.py", run.output)
        self.assertNotIn("skip  test/tooling/repo_module_test.py", run.output)

    def test_a_failing_tooling_test_fails_the_script_and_shows_its_output(self) -> None:
        run = self._run(
            tooling_tests={"ok_test.py": PASSING_TEST, "bad_test.py": FAILING_TEST}
        )
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        self.assertIn("a real assertion failed", run.output)
        self.assertIn("python3 test/tooling/bad_test.py", run.output)
        # The passing one is not drowned out by the failing one's output.
        self.assertIn("ok    test/tooling/ok_test.py", run.output)


class MissingToolsAreSkips(StubHarness):
    """A tool this machine lacks is not a verdict on the change."""

    def test_no_cargo_skips_rust_and_still_runs_the_rest(self) -> None:
        run = self._run(tools=("cmake", "ctest", "c++", "ruff"))
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn("SKIPPED: Rust checks, cargo not found", run.output)
        self.assertIn("rustup.rs", run.output)
        self.assertTrue([c for c in run.calls if c[0] == "ctest"], msg=run.output)
        self.assertTrue([c for c in run.calls if c[0] == "ruff"], msg=run.output)

    def test_a_missing_rustfmt_component_skips_only_that_check(self) -> None:
        """cargo can be installed while `cargo fmt` is an unknown command."""
        run = self._run(fail=("cargo:fmt:--version",))
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn("rustup component add rustfmt", run.output)
        ran = [call[1] for call in self._calls(run, "cargo")]
        self.assertEqual(ran, ["clippy", "test", "run"], msg=run.output)

    def test_no_cmake_skips_the_cpp_section_with_something_to_install(self) -> None:
        run = self._run(tools=("cargo", "ruff"))
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn("SKIPPED: C++ checks", run.output)
        self.assertIn("cmake", run.output)
        self.assertIn("C++17 compiler", run.output)

    def test_a_CXX_carrying_required_options_still_counts_as_a_compiler(self) -> None:
        """cmake-env-variables(7) permits options in CXX, so the gate must too.

        Looking the whole value up as one command name rejects a cross
        toolchain CMake would configure happily, and on a machine without
        c++/g++/clang++ that skipped every C++ check.
        """
        run = self._run(
            tools=("cargo", "cmake", "ctest", "ruff", "custom-compiler"),
            env={"CXX": "custom-compiler --sysroot=/sdk"},
        )
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertNotIn("SKIPPED: C++ checks", run.output)
        self.assertTrue([c for c in run.calls if c[0] == "ctest"], msg=run.output)

    def test_a_compiler_only_CMake_would_have_named_still_counts(self) -> None:
        """`cl`, `icpx` and friends are compilers too, not an absent toolchain."""
        for compiler in ("cl", "icpx", "CC"):
            with self.subTest(compiler=compiler):
                run = self._run(tools=("cargo", "cmake", "ctest", "ruff", compiler))
                self.assertEqual(run.process.returncode, 0, msg=run.output)
                self.assertNotIn("SKIPPED: C++ checks", run.output)

    def test_an_IDE_generator_supplies_its_own_toolchain(self) -> None:
        run = self._run(
            tools=("cargo", "cmake", "ctest", "ruff"),
            env={"CMAKE_GENERATOR": "Visual Studio 17 2022"},
        )
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertNotIn("SKIPPED: C++ checks", run.output)

    def test_windows_defaults_to_an_IDE_generator_with_no_compiler_on_PATH(
        self,
    ) -> None:
        """CMake's default generator on Windows supplies its own toolchain.

        cl is not on a Git Bash PATH and CMAKE_GENERATOR need not be set for
        CMake to find the Visual Studio toolchain, so nothing visible from the
        script can confirm a compiler there. Skipping the section on that
        basis would drop the C++ checks on a machine where they would run.
        """
        run = self._run(
            tools=("cargo", "cmake", "ctest", "ruff"),
            env={"OSTYPE": "msys"},
        )
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertNotIn("SKIPPED: C++ checks", run.output)
        self.assertTrue([c for c in run.calls if c[0] == "ctest"], msg=run.output)

    def test_a_unix_machine_with_no_compiler_still_skips(self) -> None:
        """The exemption above must not become a blanket pass."""
        run = self._run(
            tools=("cargo", "cmake", "ctest", "ruff"),
            env={"OSTYPE": "linux-gnu"},
        )
        self.assertIn("SKIPPED: C++ checks", run.output)
        self.assertIn("C++17 compiler", run.output)

    def test_no_ruff_still_runs_the_python_tooling_tests(self) -> None:
        run = self._run(tools=("cargo", "cmake", "ctest", "c++"))
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn("ruff not found", run.output)
        self.assertIn("pip install ruff", run.output)
        self.assertIn("ok    test/tooling/example_test.py", run.output)

    def test_a_missing_external_dependency_is_skipped_not_failed(self) -> None:
        """The PyYAML shape: ci.yml installs it, a contributor may not have it."""
        run = self._run(
            tooling_tests={
                "ok_test.py": PASSING_TEST,
                "needs_module_test.py": MISSING_EXTERNAL_DEPENDENCY_TEST,
            }
        )
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn(
            "skip  test/tooling/needs_module_test.py (needs the yaml Python module)",
            run.output,
        )

    def test_a_skipped_run_never_reports_itself_as_a_full_pass(self) -> None:
        run = self._run(tools=("cmake", "ctest", "c++", "ruff"))
        self.assertIn("CI still runs every one of them", run.output)
        self.assertTrue(_summary_items(run.output, "Skipped"), msg=run.output)

    def test_no_toolchain_at_all_is_an_error_rather_than_a_pass(self) -> None:
        """Nothing was verified, so "passed" would be the wrong word."""
        run = self._run(tools=(), tooling_tests={})
        self.assertEqual(run.process.returncode, 1, msg=run.output)
        self.assertIn("Nothing could be checked", run.output)
        self.assertIn("doctor.sh", run.output)
        self.assertNotIn("Verification passed", run.output)


class DoctorReportsTheSameToolchains(unittest.TestCase):
    """scripts/doctor.sh is where a skip message sends you."""

    def test_it_reports_every_toolchain_verify_native_can_skip_for(self) -> None:
        doctor = (ROOT / "scripts" / "doctor.sh").read_text(encoding="utf-8")
        for label in (
            "Rust (cargo):",
            "rustfmt:",
            "clippy:",
            "CMake:",
            "ctest:",
            "C++ compiler:",
            "Python 3:",
            "Ruff:",
        ):
            self.assertIn(label, doctor)

    def test_it_still_changes_nothing(self) -> None:
        doctor = (ROOT / "scripts" / "doctor.sh").read_text(encoding="utf-8")
        self.assertIn("Makes no changes.", doctor)
        commands = "\n".join(
            line for line in doctor.splitlines() if not line.lstrip().startswith("#")
        )
        # Shapes that cannot appear in the strings it prints. A bare "install"
        # can and does: the report already says "not installed".
        for destructive in ("rm -", "mkdir", "cargo build", "cargo test", "--build"):
            self.assertNotIn(destructive, commands, msg="doctor.sh is read-only")


class ContributingDocumentsIt(unittest.TestCase):
    """The issue asks for the command to be findable, not just present."""

    def test_contributing_names_the_script(self) -> None:
        text = (ROOT / "CONTRIBUTING.md").read_text(encoding="utf-8")
        self.assertIn("./scripts/verify_native.sh", text)
        # The three areas it is for, so the table above it stays honest.
        for language in ("Rust", "C++", "Python"):
            self.assertIn(language, text)


@dataclass(frozen=True)
class _Run:
    process: subprocess.CompletedProcess[str]
    output: str
    # One recorded stub invocation per entry: [name, *argv].
    calls: list[list[str]]
    repo: Path
    # The checkout's contents before the run, for the no-mutation check.
    before: dict[str, str]


def _snapshot(repo: Path) -> dict[str, str]:
    """Every file under `repo`, by relative path, with its contents."""
    return {
        str(path.relative_to(repo)): path.read_text(encoding="utf-8", errors="replace")
        for path in sorted(repo.rglob("*"))
        if path.is_file()
    }


def _summary_items(output: str, heading: str) -> list[str]:
    """The `  - ...` lines under one of the summary's headings."""
    items: list[str] = []
    collecting = False
    for line in output.splitlines():
        if line.startswith(heading):
            collecting = True
            continue
        if not collecting:
            continue
        if line.startswith("  - "):
            items.append(line[4:])
        elif items:
            # The heading wraps onto a second line, so only a non-item line
            # after the list has started means the list is over.
            break
    return items


if __name__ == "__main__":
    unittest.main(verbosity=2)
