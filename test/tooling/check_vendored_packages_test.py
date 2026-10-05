#!/usr/bin/env python3
"""`scripts/check_vendored_packages.sh` leaves the vendored tree as it found it.

    python3 test/tooling/check_vendored_packages_test.py

Flutter rewrites a package's analysis_options.yaml on every `pub get`: its
analysis options migration adds `build/**` and the platform folders to the
analyzer's excludes. The script runs `pub get` and `flutter analyze` inside
each vendored package after checking that the package is exactly upstream +
upstream.patch, so a local run used to pass while leaving the vendored
analysis_options.yaml rewritten, and the commit that swept that edit in failed
CI's provenance check (#760).

Each case runs the real script in a throwaway repository: one vendored package
that passes the provenance check, and a stub `flutter` that rewrites
analysis_options.yaml on `pub get` the way the migration does.
"""

from __future__ import annotations

import hashlib
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_vendored_packages.sh"

OPTIONS = "include: package:flutter_lints/flutter.yaml\n"
UPSTREAM_README = "vendored\n"
PATCHED_README = "vendored, with one fix\n"

# A patch that turns the upstream README into the vendored one, so reversing
# it reproduces upstream, as the provenance check requires.
PATCH = textwrap.dedent(
    """\
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -vendored
    +vendored, with one fix
    """
)

# What the stub does: rewrite analysis_options.yaml on `pub get`, then succeed
# or fail each command as the test asks.
STUB_FLUTTER = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    case "$1" in
      pub)
        printf 'analyzer:\\n  exclude:\\n    - build/**\\n' > analysis_options.yaml.new
        cat analysis_options.yaml >> analysis_options.yaml.new
        mv analysis_options.yaml.new analysis_options.yaml
        exit "${STUB_PUB_EXIT:-0}" ;;
      analyze)
        exit "${STUB_ANALYZE_EXIT:-0}" ;;
    esac
    exit 0
    """
)


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


class AnalysisOptionsRestoredTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="linthra-vendored-")
        self.repo = Path(self._tmp.name)

        (self.repo / "scripts").mkdir()
        self.script = self.repo / "scripts" / "check_vendored_packages.sh"
        self.script.write_text(SCRIPT.read_text())

        flutter = self.repo / ".tool" / "flutter" / "bin" / "flutter"
        flutter.parent.mkdir(parents=True)
        flutter.write_text(STUB_FLUTTER)
        flutter.chmod(0o755)

        self.package = self.repo / "third_party" / "pkg"
        self.package.mkdir(parents=True)
        pubspec = "name: pkg\n"
        (self.package / "pubspec.yaml").write_text(pubspec)
        (self.package / "pubspec.lock").write_text("packages: {}\n")
        (self.package / "analysis_options.yaml").write_text(OPTIONS)
        (self.package / "README.md").write_text(PATCHED_README)
        (self.package / "PATCHES.md").write_text("A test package.\n")
        (self.package / "upstream.patch").write_text(PATCH)
        (self.package / "upstream.sha256").write_text(
            f"{sha256(pubspec)}  pubspec.yaml\n"
            f"{sha256(OPTIONS)}  analysis_options.yaml\n"
            f"{sha256(UPSTREAM_README)}  README.md\n"
        )
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_script(self, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(self.script)],
            cwd=self.repo,
            env={"PATH": "/usr/bin:/bin", **env},
            capture_output=True,
            text=True,
        )

    def options(self) -> str:
        return (self.package / "analysis_options.yaml").read_text()

    def test_a_passing_run_leaves_the_file_as_it_was(self) -> None:
        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("vendored package checks passed", result.stdout)
        self.assertEqual(self.options(), OPTIONS)

    def test_a_second_run_still_passes_the_provenance_check(self) -> None:
        self.assertEqual(self.run_script().returncode, 0)

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("did not reproduce upstream", result.stderr)

    def test_failing_analysis_still_puts_it_back(self) -> None:
        result = self.run_script(STUB_ANALYZE_EXIT="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("flutter analyze reported issues", result.stderr)
        self.assertEqual(self.options(), OPTIONS)

    def test_failing_pub_get_still_puts_it_back(self) -> None:
        result = self.run_script(STUB_PUB_EXIT="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("pub get --enforce-lockfile failed", result.stderr)
        self.assertEqual(self.options(), OPTIONS)


if __name__ == "__main__":
    unittest.main()
