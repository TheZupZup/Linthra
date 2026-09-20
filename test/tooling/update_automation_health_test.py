#!/usr/bin/env python3
"""Offline tests for scripts/check_update_automation_health.py.

The script exists because a failing scheduled workflow tells nobody. Its whole
value is the judgement it makes about a run history, so that judgement is
tested here against fixtures rather than against GitHub: no network, no `gh`,
no Actions API.

What is worth pinning down, and why:

  * a manual run must not mask a broken schedule — that is the exact way a
    maintainer "checking it still works" could hide a month of dead Mondays;
  * a cancelled run is not evidence, in either direction;
  * one bad week is tolerated and two are not, because the first is usually a
    runner blip and the second is a standing fault;
  * a workflow with no history yet is unknown, not broken;
  * unreadable input fails loudly instead of reporting a healthy repository.

Run it directly: `python3 test/tooling/update_automation_health_test.py`.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT = REPO_ROOT / "scripts" / "check_update_automation_health.py"

sys.path.insert(0, str(REPO_ROOT / "scripts"))

import check_update_automation_health as checker  # noqa: E402


def run(conclusion: str, *, event: str = "schedule", status: str = "completed") -> dict:
    """One run row, shaped like the Actions API's."""

    return {
        "event": event,
        "status": status,
        "conclusion": conclusion,
        "url": "https://github.com/TheZupZup/Linthra/actions/runs/1",
        "createdAt": "2026-09-14T10:07:39Z",
    }


def history(**overrides: list) -> dict:
    """A full history with every watched workflow green unless overridden."""

    base = {name: [run("success")] for name in checker.WATCHED_WORKFLOWS}
    base.update(overrides)
    return base


class ClassificationTest(unittest.TestCase):
    def test_all_green_is_healthy(self) -> None:
        result = checker.build_result(history(), 2)
        self.assertEqual(result["verdict"], "healthy")
        self.assertEqual(result["failing_workflows"], [])

    def test_two_consecutive_failures_are_reported(self) -> None:
        result = checker.build_result(
            history(**{"flutter-sdk-updates.yml": [run("failure"), run("failure")]}), 2
        )
        self.assertEqual(result["verdict"], "failing")
        self.assertEqual(result["failing_workflows"], ["flutter-sdk-updates.yml"])

    def test_one_failure_is_tolerated(self) -> None:
        # A single bad week is usually a runner or network blip; reporting it
        # would make the issue noise rather than signal.
        result = checker.build_result(
            history(**{"flutter-sdk-updates.yml": [run("failure"), run("success")]}), 2
        )
        self.assertEqual(result["verdict"], "healthy")

    def test_the_streak_is_counted_from_the_newest_run(self) -> None:
        # Fixed last week: newest is green, so the older failures are history.
        result = checker.build_result(
            history(
                **{
                    "flutter-sdk-updates.yml": [
                        run("success"),
                        run("failure"),
                        run("failure"),
                        run("failure"),
                    ]
                }
            ),
            2,
        )
        self.assertEqual(result["verdict"], "healthy")

    def test_a_manual_run_cannot_mask_a_broken_schedule(self) -> None:
        # The green run is a workflow_dispatch, so it is not evidence about the
        # weekly cadence that actually keeps the repository current.
        result = checker.build_result(
            history(
                **{
                    "flutter-sdk-updates.yml": [
                        run("success", event="workflow_dispatch"),
                        run("failure"),
                        run("failure"),
                    ]
                }
            ),
            2,
        )
        self.assertEqual(result["verdict"], "failing")

    def test_an_in_flight_run_is_ignored(self) -> None:
        result = checker.build_result(
            history(
                **{
                    "flutter-sdk-updates.yml": [
                        run("", status="in_progress"),
                        run("failure"),
                        run("failure"),
                    ]
                }
            ),
            2,
        )
        self.assertEqual(result["verdict"], "failing")

    def test_a_cancelled_run_bounds_the_streak_without_counting(self) -> None:
        # Neither a pass nor a failure: it stops the count where it is.
        result = checker.build_result(
            history(
                **{
                    "flutter-sdk-updates.yml": [
                        run("failure"),
                        run("cancelled"),
                        run("failure"),
                        run("failure"),
                    ]
                }
            ),
            2,
        )
        self.assertEqual(result["verdict"], "healthy")
        sdk = next(
            w for w in result["workflows"] if w["workflow"] == "flutter-sdk-updates.yml"
        )
        self.assertEqual(sdk["consecutive_failures"], 1)

    def test_timed_out_and_startup_failure_count_as_broken(self) -> None:
        for conclusion in ("timed_out", "startup_failure"):
            with self.subTest(conclusion=conclusion):
                result = checker.build_result(
                    history(
                        **{"flutter-sdk-updates.yml": [run(conclusion), run(conclusion)]}
                    ),
                    2,
                )
                self.assertEqual(result["verdict"], "failing")

    def test_a_workflow_with_no_scheduled_history_is_unknown(self) -> None:
        result = checker.build_result(history(**{"flutter-sdk-updates.yml": []}), 2)
        self.assertEqual(result["verdict"], "healthy")
        sdk = next(
            w for w in result["workflows"] if w["workflow"] == "flutter-sdk-updates.yml"
        )
        self.assertEqual(sdk["state"], "unknown")

    def test_every_watched_workflow_is_classified(self) -> None:
        result = checker.build_result(history(), 2)
        self.assertEqual(
            [w["workflow"] for w in result["workflows"]],
            list(checker.WATCHED_WORKFLOWS),
        )

    def test_all_three_updaters_can_fail_together(self) -> None:
        # The real outage: one missing publication secret took out all three.
        broken = {name: [run("failure"), run("failure")] for name in checker.WATCHED_WORKFLOWS}
        result = checker.build_result(broken, 2)
        self.assertEqual(result["failing_workflows"], list(checker.WATCHED_WORKFLOWS))

    def test_the_threshold_is_honoured(self) -> None:
        one_failure = history(**{"flutter-sdk-updates.yml": [run("failure")]})
        self.assertEqual(checker.build_result(one_failure, 1)["verdict"], "failing")
        self.assertEqual(checker.build_result(one_failure, 2)["verdict"], "healthy")


class InputTrustTest(unittest.TestCase):
    def test_a_missing_watched_workflow_is_an_error(self) -> None:
        partial = history()
        del partial["flutter-sdk-updates.yml"]
        with self.assertRaises(checker.CheckError):
            checker.build_result(partial, 2)

    def test_a_non_object_history_is_an_error(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.build_result([], 2)

    def test_a_non_list_run_set_is_an_error(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.build_result(history(**{"flutter-sdk-updates.yml": {}}), 2)

    def test_a_malformed_run_is_an_error(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.build_result(history(**{"flutter-sdk-updates.yml": ["nope"]}), 2)


class ReportTest(unittest.TestCase):
    def test_the_failing_report_names_the_workflow(self) -> None:
        result = checker.build_result(
            history(**{"flutter-sdk-updates.yml": [run("failure"), run("failure")]}), 2
        )
        report = checker.render_report(result)
        self.assertIn("flutter-sdk-updates.yml", report)
        self.assertIn("no update PR is opened", report)

    def test_the_healthy_report_says_so(self) -> None:
        report = checker.render_report(checker.build_result(history(), 2))
        self.assertIn("Every scheduled update workflow is running.", report)


class CliTest(unittest.TestCase):
    def _run_cli(self, payload: object, *extra: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            runs_file = Path(tmp) / "runs.json"
            if isinstance(payload, str):
                runs_file.write_text(payload, encoding="utf-8")
            else:
                runs_file.write_text(json.dumps(payload), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--runs-file", str(runs_file), *extra],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_a_healthy_history_exits_zero(self) -> None:
        proc = self._run_cli(history())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("verdict: healthy", proc.stdout)

    def test_a_failing_history_still_exits_zero(self) -> None:
        # The verdict is what the caller reads. A non-zero exit here would make
        # the reporting workflow itself go red, which is the silence this whole
        # script exists to break.
        proc = self._run_cli(
            history(**{"flutter-sdk-updates.yml": [run("failure"), run("failure")]})
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("verdict: failing", proc.stdout)

    def test_unparseable_input_exits_two(self) -> None:
        proc = self._run_cli("{not json")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("ERROR", proc.stderr)

    def test_a_missing_file_exits_two(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--runs-file", "/nonexistent/runs.json"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 2)

    def test_github_output_carries_the_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runs_file = Path(tmp) / "runs.json"
            out_file = Path(tmp) / "out.txt"
            runs_file.write_text(
                json.dumps(
                    history(
                        **{"flutter-sdk-updates.yml": [run("failure"), run("failure")]}
                    )
                ),
                encoding="utf-8",
            )
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--runs-file",
                    str(runs_file),
                    "--github-output",
                    str(out_file),
                    "--quiet",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            written = out_file.read_text(encoding="utf-8")
            self.assertIn("verdict=failing", written)
            self.assertIn("failing=flutter-sdk-updates.yml", written)

    def test_report_file_is_written(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runs_file = Path(tmp) / "runs.json"
            report_file = Path(tmp) / "report.md"
            runs_file.write_text(json.dumps(history()), encoding="utf-8")
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--runs-file",
                    str(runs_file),
                    "--report",
                    str(report_file),
                    "--quiet",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("| Workflow |", report_file.read_text(encoding="utf-8"))

    def test_a_zero_threshold_is_rejected(self) -> None:
        proc = self._run_cli(history(), "--min-consecutive-failures", "0")
        self.assertEqual(proc.returncode, 2)


class WorkflowWiringTest(unittest.TestCase):
    """The reporter must stay a reporter, and must watch the real updaters."""

    WORKFLOW = REPO_ROOT / ".github" / "workflows" / "update-automation-health.yml"

    def setUp(self) -> None:
        self.text = self.WORKFLOW.read_text(encoding="utf-8")

    def test_every_watched_workflow_exists(self) -> None:
        for name in checker.WATCHED_WORKFLOWS:
            self.assertTrue(
                (REPO_ROOT / ".github" / "workflows" / name).is_file(),
                f"{name} is watched but does not exist",
            )

    def test_it_never_merges_or_pushes(self) -> None:
        # This workflow reports. It has no business touching a branch or a PR,
        # and nothing in Linthra merges automatically (#362).
        for forbidden in (
            "gh pr merge",
            "--auto",
            "--admin",
            "--squash",
            "--rebase",
            "enable_pr_auto_merge",
            "git push",
            "git commit",
            "gh pr create",
        ):
            self.assertNotIn(
                forbidden,
                self.text,
                f"{self.WORKFLOW.name} contains {forbidden!r}; it only files an issue.",
            )

    def test_it_consumes_no_repository_secret(self) -> None:
        # An issue triggers no CI, so this needs none of the publication token's
        # reach — the built-in GITHUB_TOKEN is sufficient, and a workflow that
        # handles no secret cannot leak one.
        #
        # Asserted on `secrets.` rather than on the token's name: the issue body
        # deliberately *names* DEPENDENCY_UPDATE_TOKEN, because "the secret is
        # missing" is the first thing to check when all three updaters fail at
        # once. Naming it is the report doing its job; consuming it is not.
        self.assertNotIn("secrets.", self.text)
        self.assertIn("GH_TOKEN: ${{ github.token }}", self.text)

    def test_its_permissions_are_minimal(self) -> None:
        self.assertIn("permissions:\n  contents: read\n", self.text)
        self.assertIn("issues: write", self.text)
        self.assertIn("actions: read", self.text)
        self.assertNotIn("pull-requests: write", self.text)

    def test_it_is_scheduled_and_dispatchable(self) -> None:
        self.assertIn("schedule:", self.text)
        self.assertIn("cron:", self.text)
        self.assertIn("workflow_dispatch:", self.text)

    def test_it_cannot_trigger_itself(self) -> None:
        # No pull_request/push trigger, so filing an issue cannot start another
        # run of anything that files an issue.
        self.assertNotIn("pull_request:", self.text)
        self.assertNotIn("\n  push:", self.text)

    def test_it_runs_the_checker(self) -> None:
        self.assertIn("scripts/check_update_automation_health.py", self.text)


if __name__ == "__main__":
    # Fail loudly if the script moved rather than reporting a passing suite.
    if not SCRIPT.is_file():
        print(f"ERROR: {SCRIPT} is missing.", file=sys.stderr)
        raise SystemExit(2)
    os.chdir(REPO_ROOT)
    unittest.main(verbosity=2)
