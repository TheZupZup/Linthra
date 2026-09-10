#!/usr/bin/env python3
"""Unit tests for scripts/flathub_builder_lint.py (#449).

    python3 test/tooling/flathub_builder_lint_test.py

The script's value is entirely in what it refuses to call a pass, so that is
what these tests are about: a missing linter, a finding nobody wrote a reason
for, an exception with an empty reason, and an exception the linter no longer
reports. The linter itself is stubbed: it lives in a Flatpak, and the point
here is the judgement around it, not its rules.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


lint = _load("flathub_builder_lint", "flathub_builder_lint.py")


@contextlib.contextmanager
def stub_linter(reports):
    """Replace the linter with canned reports, keyed by mode."""
    original = lint.run_linter
    lint.run_linter = lambda mode, target: reports[mode]
    try:
        yield
    finally:
        lint.run_linter = original


@contextlib.contextmanager
def exceptions_file(payload):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "flathub-lint-exceptions.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        yield path


def run_mode(mode, report, exceptions):
    with stub_linter({mode: report}):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            undocumented, seen = lint.report_mode(mode, Path("x"), exceptions)
    return undocumented, seen, buffer.getvalue()


class FindingsTest(unittest.TestCase):
    def test_reads_errors_and_warnings(self) -> None:
        found = lint.findings(
            {"errors": ["b", "a"], "warnings": ["c"], "message": "hi"}
        )
        self.assertEqual(found["errors"], ["a", "b"])
        self.assertEqual(found["warnings"], ["c"])

    def test_tolerates_a_report_with_neither(self) -> None:
        self.assertEqual(lint.findings({}), {"errors": [], "warnings": []})

    def test_tolerates_explicit_nulls(self) -> None:
        self.assertEqual(
            lint.findings({"errors": None, "warnings": None}),
            {"errors": [], "warnings": []},
        )


class ExceptionsFileTest(unittest.TestCase):
    def test_missing_file_means_no_exceptions(self) -> None:
        self.assertEqual(lint.load_exceptions(Path("/nope/absent.json")), {})

    def test_reads_written_reasons(self) -> None:
        with exceptions_file({"exceptions": {"repo/a-finding": "because"}}) as path:
            self.assertEqual(lint.load_exceptions(path), {"repo/a-finding": "because"})

    def test_accepts_an_object_with_a_reason_field(self) -> None:
        with exceptions_file(
            {"exceptions": {"repo/a-finding": {"reason": "because", "issue": 449}}}
        ) as path:
            self.assertEqual(lint.load_exceptions(path), {"repo/a-finding": "because"})

    # An exception without a reason is exactly the suppression #449 forbids.
    def test_rejects_an_exception_with_no_reason(self) -> None:
        with exceptions_file({"exceptions": {"repo/a-finding": "   "}}) as path:
            with self.assertRaises(ValueError):
                lint.load_exceptions(path)

    # CI lints the manifest and the built repo in separate invocations, so an
    # unqualified key cannot be told from one whose mode did not run.
    def test_rejects_an_unqualified_key(self) -> None:
        with exceptions_file({"exceptions": {"a-finding": "because"}}) as path:
            with self.assertRaises(ValueError):
                lint.load_exceptions(path)

    def test_rejects_an_unknown_mode(self) -> None:
        with exceptions_file({"exceptions": {"nonsense/a-finding": "because"}}) as path:
            with self.assertRaises(ValueError):
                lint.load_exceptions(path)

    # "<mode>-lint-failed" is the same name whatever went wrong, so a reason
    # for it would go on matching a different failure later.
    def test_refuses_to_except_a_linter_failure(self) -> None:
        for key in ("appstream/appstream-lint-failed", "repo/repo-lint-failed"):
            with exceptions_file({"exceptions": {key: "known bad"}}) as path:
                with self.assertRaises(ValueError):
                    lint.load_exceptions(path)

    def test_rejects_a_malformed_exceptions_block(self) -> None:
        with exceptions_file({"exceptions": ["a-finding"]}) as path:
            with self.assertRaises(ValueError):
                lint.load_exceptions(path)

    def test_the_committed_file_has_no_exceptions_yet(self) -> None:
        # #456 requires this to be empty at submission, so a PR that adds one
        # should have to change this test and explain itself.
        self.assertEqual(lint.load_exceptions(lint.DEFAULT_EXCEPTIONS), {})


class ReportModeTest(unittest.TestCase):
    def test_a_clean_report_has_nothing_undocumented(self) -> None:
        undocumented, seen, output = run_mode(
            "manifest", {"errors": [], "warnings": []}, {}
        )
        self.assertEqual(undocumented, 0)
        self.assertEqual(seen, set())
        self.assertIn("no findings", output)

    def test_warnings_count_as_findings(self) -> None:
        undocumented, seen, _ = run_mode(
            "manifest", {"warnings": ["appstream-missing-screenshots"]}, {}
        )
        self.assertEqual(undocumented, 1)
        self.assertEqual(seen, {"manifest/appstream-missing-screenshots"})

    def test_a_documented_finding_is_accepted_and_quotes_its_reason(self) -> None:
        undocumented, seen, output = run_mode(
            "manifest",
            {"errors": ["some-finding"]},
            {"manifest/some-finding": "the linter is wrong about X"},
        )
        self.assertEqual(undocumented, 0)
        self.assertEqual(seen, {"manifest/some-finding"})
        self.assertIn("the linter is wrong about X", output)

    # A reason written for one mode must not accept a same-named finding from
    # another, which is the whole point of qualifying the key.
    def test_a_reason_for_another_mode_does_not_accept_it(self) -> None:
        undocumented, seen, _ = run_mode(
            "manifest",
            {"errors": ["some-finding"]},
            {"repo/some-finding": "documented for the repo run only"},
        )
        self.assertEqual(undocumented, 1)
        self.assertEqual(seen, {"manifest/some-finding"})

    # Belt and braces: load_exceptions refuses to record one of these, so this
    # covers a hand-built dict reaching report_mode anyway.
    def test_a_linter_failure_is_never_accepted(self) -> None:
        undocumented, _, _ = run_mode(
            "appstream",
            {"errors": ["appstream-lint-failed"]},
            {"appstream/appstream-lint-failed": "a reason that should not count"},
        )
        self.assertEqual(undocumented, 1)

    # A message the linter emits outside errors/warnings still has to reach the
    # log, or a reviewer reads a summary that quietly dropped it.
    def test_other_report_keys_are_printed(self) -> None:
        _, _, output = run_mode(
            "repo", {"errors": [], "warnings": [], "message": "checked 1 ref"}, {}
        )
        self.assertIn("checked 1 ref", output)


class RunLinterTest(unittest.TestCase):
    """How the linter's own output is read.

    flatpak-builder-lint 3.x prints nothing when a mode finds nothing. The
    first version of this script read that as "the tool is missing" and turned
    a clean manifest into a hard failure, which is why the distinction below is
    a test rather than a comment.
    """

    @contextlib.contextmanager
    def _subprocess(self, stdout, returncode, stderr=""):
        original = lint.subprocess.run

        class Result:
            pass

        result = Result()
        result.stdout, result.stderr, result.returncode = stdout, stderr, returncode
        lint.subprocess.run = lambda *a, **k: result
        try:
            yield
        finally:
            lint.subprocess.run = original

    def test_no_output_and_exit_zero_is_a_clean_report(self) -> None:
        with self._subprocess("", 0):
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                self.assertEqual(lint.run_linter("manifest", Path("x")), {})

    # Silence with a failure exit explains nothing, so it cannot be read as
    # either a pass or a finding.
    def test_no_output_and_a_failure_exit_is_refused(self) -> None:
        with self._subprocess("", 2):
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                with self.assertRaises(lint.LinterUnavailable):
                    lint.run_linter("manifest", Path("x"))

    def test_findings_are_parsed(self) -> None:
        with self._subprocess('{"errors": ["a"]}', 1):
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                self.assertEqual(
                    lint.run_linter("manifest", Path("x")), {"errors": ["a"]}
                )

    # The `appstream` mode delegates to appstreamcli and prints its verdict as
    # text. Refusing that as unreadable output turned a successful validation
    # into a hard failure.
    def test_text_output_and_exit_zero_is_clean_and_still_printed(self) -> None:
        with self._subprocess("Validation was successful.", 0):
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                report = lint.run_linter("appstream", Path("x"))
        self.assertEqual(lint.findings(report), {"errors": [], "warnings": []})
        self.assertIn("Validation was successful.", report["message"])

    # A structured report with neither errors nor warnings alongside a failure
    # exit would otherwise read as clean and print PASS, which is the one thing
    # a non-zero linter run must never produce.
    def test_json_output_and_an_unexplained_failure_exit_is_a_finding(
        self,
    ) -> None:
        with self._subprocess('{"message": "internal failure"}', 1):
            report = lint.run_linter("repo", Path("x"))
        self.assertEqual(report["errors"], ["repo-lint-failed"])
        self.assertEqual(report["message"], "internal failure")

    # ...but a report that does explain itself keeps its own findings.
    def test_json_findings_explain_a_failure_exit_on_their_own(self) -> None:
        with self._subprocess('{"errors": ["a-real-finding"]}', 1):
            report = lint.run_linter("repo", Path("x"))
        self.assertEqual(report["errors"], ["a-real-finding"])

    def test_text_output_and_a_failure_exit_is_a_finding(self) -> None:
        with self._subprocess("E: something is wrong", 1):
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                report = lint.run_linter("appstream", Path("x"))
        self.assertEqual(lint.findings(report)["errors"], ["appstream-lint-failed"])
        self.assertIn("something is wrong", report["message"])


class MainTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = ROOT / "flatpak" / "io.github.thezupzup.linthra.yml"

    def _main(self, argv):
        buffer = io.StringIO()
        errors = io.StringIO()
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(errors):
            code = lint.main(argv)
        return code, buffer.getvalue() + errors.getvalue()

    def test_a_missing_target_is_not_a_pass(self) -> None:
        code, output = self._main(["--manifest", "/nope/absent.yml"])
        self.assertEqual(code, 2)
        self.assertIn("does not exist", output)

    # The failure mode this script exists to prevent: a CI runner without the
    # linter reporting a clean run of nothing.
    def test_a_missing_linter_is_not_a_pass(self) -> None:
        original = lint.shutil.which
        lint.shutil.which = lambda _: None
        try:
            code, output = self._main(["--manifest", str(self.manifest)])
        finally:
            lint.shutil.which = original
        self.assertEqual(code, 2)
        self.assertIn("not a pass", output)

    def test_an_undocumented_finding_fails(self) -> None:
        with stub_linter({"manifest": {"errors": ["a-finding"], "warnings": []}}):
            original_which, original_versions = lint.shutil.which, lint.linter_versions
            lint.shutil.which = lambda _: "/usr/bin/flatpak"
            lint.linter_versions = lambda: {lint.LINTER_APP: "test"}
            try:
                code, output = self._main(["--manifest", str(self.manifest)])
            finally:
                lint.shutil.which = original_which
                lint.linter_versions = original_versions
        self.assertEqual(code, 1)
        self.assertIn("no written reason", output)

    # A reason that outlives the problem it explains is how an exceptions file
    # rots into a suppression list.
    def test_a_stale_exception_fails(self) -> None:
        with exceptions_file(
            {"exceptions": {"manifest/fixed-long-ago": "it used to do this"}}
        ) as path:
            with stub_linter({"manifest": {"errors": [], "warnings": []}}):
                original_which = lint.shutil.which
                original_versions = lint.linter_versions
                lint.shutil.which = lambda _: "/usr/bin/flatpak"
                lint.linter_versions = lambda: {lint.LINTER_APP: "test"}
                try:
                    code, output = self._main(
                        [
                            "--manifest",
                            str(self.manifest),
                            "--exceptions",
                            str(path),
                        ]
                    )
                finally:
                    lint.shutil.which = original_which
                    lint.linter_versions = original_versions
        self.assertEqual(code, 1)
        self.assertIn("were not reported", output)

    # The failure Codex caught on #614. CI lints the manifest before the build
    # and the repo and catalogue after it, in two invocations, each loading the
    # whole file. Comparing every exception against one run's findings reported
    # the other run's live exceptions as stale, which made the mechanism
    # unusable the moment anyone recorded a real one.
    def test_an_exception_for_a_mode_that_did_not_run_is_not_stale(self) -> None:
        with exceptions_file(
            {"exceptions": {"repo/some-repo-finding": "documented, and still true"}}
        ) as path:
            with stub_linter({"manifest": {"errors": [], "warnings": []}}):
                original_which = lint.shutil.which
                original_versions = lint.linter_versions
                lint.shutil.which = lambda _: "/usr/bin/flatpak"
                lint.linter_versions = lambda: {lint.LINTER_APP: "test"}
                try:
                    code, output = self._main(
                        [
                            "--manifest",
                            str(self.manifest),
                            "--exceptions",
                            str(path),
                        ]
                    )
                finally:
                    lint.shutil.which = original_which
                    lint.linter_versions = original_versions
        self.assertEqual(code, 0, output)
        self.assertNotIn("were not reported", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
