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
  * unreadable input fails loudly instead of reporting a healthy repository;
  * the report says where a failing updater stopped, because the updaters fail
    for different reasons and #671 sent readers to the token when the Dart
    updater had actually stopped at its allowlist guard.

Run it directly: `python3 test/tooling/update_automation_health_test.py`.
"""

from __future__ import annotations

import json
import os
import re
import shutil
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

    def test_the_failing_report_names_where_each_run_stopped(self) -> None:
        # The #671 shape: two updaters red for two unrelated reasons.
        dart = run("failure")
        dart["failedSteps"] = [
            "Resolve and prepare update PR / Resolve updates with the pinned SDK"
        ]
        android = run("failure")
        android["failedSteps"] = [
            "Draft PR for agp / Require workflow-triggering publication token",
            "Draft PR for kotlin / Require workflow-triggering publication token",
        ]
        result = checker.build_result(
            history(
                **{
                    "dart-dependency-updates.yml": [dart, run("failure")],
                    "android-toolchain-updates.yml": [android, run("failure")],
                }
            ),
            2,
        )
        report = checker.render_report(result)
        self.assertIn("### Where the last scheduled run stopped", report)
        self.assertIn(
            "- `dart-dependency-updates.yml`: "
            "`Resolve and prepare update PR / Resolve updates with the pinned SDK`",
            report,
        )
        self.assertIn(
            "`Draft PR for kotlin / Require workflow-triggering publication token`",
            report,
        )
        self.assertNotIn("- `flutter-sdk-updates.yml`", report)

    def test_failed_steps_never_change_the_verdict(self) -> None:
        # Rendered only. A single failure with steps is still one week of grace,
        # and a failing streak without them is still failing.
        located = run("failure")
        located["failedSteps"] = ["job / step"]
        tolerated = checker.build_result(
            history(**{"flutter-sdk-updates.yml": [located, run("success")]}), 2
        )
        self.assertEqual(tolerated["verdict"], "healthy")
        self.assertNotIn("Where the last", checker.render_report(tolerated))

        unlocated = checker.build_result(
            history(**{"flutter-sdk-updates.yml": [run("failure"), run("failure")]}), 2
        )
        self.assertEqual(unlocated["verdict"], "failing")
        self.assertNotIn("Where the last", checker.render_report(unlocated))

    def test_malformed_failed_steps_are_an_error(self) -> None:
        bad = run("failure")
        bad["failedSteps"] = "Require workflow-triggering publication token"
        with self.assertRaises(checker.CheckError):
            checker.build_result(history(**{"flutter-sdk-updates.yml": [bad]}), 2)


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

    def test_it_looks_up_where_the_newest_failure_stopped(self) -> None:
        self.assertIn("failedSteps", self.text)
        self.assertIn("/actions/runs/$run_id/jobs", self.text)
        # Best effort: a failed lookup warns rather than failing the report.
        self.assertIn("::warning::Could not read the failed steps", self.text)

    def _jobs_filter(self) -> str:
        """The jq filter the workflow applies to a run's jobs, as written."""

        match = re.search(
            r'/actions/runs/\$run_id/jobs\?per_page=100" \\\n\s*--jq \'(.*?)\' \\\n',
            self.text,
            re.DOTALL,
        )
        self.assertIsNotNone(match, "could not find the jobs lookup filter")
        return match.group(1)

    def _failed_steps(self, jobs: list) -> list:
        proc = subprocess.run(
            ["jq", "-c", self._jobs_filter()],
            input=json.dumps({"jobs": jobs}),
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(proc.stdout)

    @unittest.skipUnless(shutil.which("jq"), "jq is not installed")
    def test_the_jobs_filter_locates_failures_and_timeouts(self) -> None:
        jobs = [
            {"name": "Check", "conclusion": "success", "steps": []},
            {
                "name": "Draft PR for agp",
                "conclusion": "failure",
                "steps": [
                    {"name": "Require token", "conclusion": "failure"},
                    {"name": "Checkout main", "conclusion": "skipped"},
                ],
            },
            # A timeout marks the job timed_out and its interrupted step
            # cancelled, so filtering on "failure" alone reports nothing.
            {
                "name": "Resolve",
                "conclusion": "timed_out",
                "steps": [
                    {"name": "Set up Flutter", "conclusion": "success"},
                    {"name": "Run tests", "conclusion": "cancelled"},
                ],
            },
            # No failed step recorded: the job is still named.
            {"name": "Draft PR for kotlin", "conclusion": "failure", "steps": None},
        ]
        self.assertEqual(
            self._failed_steps(jobs),
            [
                "Draft PR for agp / Require token",
                "Resolve / Run tests",
                "Draft PR for kotlin",
            ],
        )

    @unittest.skipUnless(shutil.which("jq"), "jq is not installed")
    def test_the_jobs_filter_ignores_healthy_jobs(self) -> None:
        jobs = [
            {"name": "Check", "conclusion": "success", "steps": []},
            {"name": "Major upgrade issue", "conclusion": "skipped", "steps": []},
        ]
        self.assertEqual(self._failed_steps(jobs), [])

    def test_the_guidance_names_steps_that_exist(self) -> None:
        # The issue body tells the reader which step means what. If an updater
        # renames one of those steps, the guidance silently stops matching the
        # run it points at, so hold the names to the real workflows.
        workflows = REPO_ROOT / ".github" / "workflows"
        cited = {
            "Require workflow-triggering publication token": (
                "dart-dependency-updates.yml",
                "flutter-sdk-updates.yml",
                "android-toolchain-updates.yml",
            ),
            "Resolve updates with the pinned SDK": ("dart-dependency-updates.yml",),
        }
        for step, owners in cited.items():
            self.assertIn(step, self.text)
            for owner in owners:
                self.assertIn(
                    f"name: {step}",
                    (workflows / owner).read_text(encoding="utf-8"),
                    f"{owner} has no step named {step!r}, which the report cites",
                )
        # And the guard's own wording, which the guidance quotes.
        guard = (REPO_ROOT / "scripts" / "check_dependency_update_files.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("files outside the allowed set", guard)
        self.assertIn("files outside the allowed set", self.text)


if __name__ == "__main__":
    # Fail loudly if the script moved rather than reporting a passing suite.
    if not SCRIPT.is_file():
        print(f"ERROR: {SCRIPT} is missing.", file=sys.stderr)
        raise SystemExit(2)
    os.chdir(REPO_ROOT)
    unittest.main(verbosity=2)
