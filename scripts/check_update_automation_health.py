#!/usr/bin/env python3
"""check_update_automation_health.py — are Linthra's update workflows still working?

Linthra's dependency and toolchain updates are proposed by four mechanisms
(issue #362, see docs/dependency-updates.md). Three of them are scheduled
workflows in this repository:

    .github/workflows/dart-dependency-updates.yml
    .github/workflows/flutter-sdk-updates.yml
    .github/workflows/android-toolchain-updates.yml

Each runs weekly, detects what can move, and opens a draft PR. None of them
merges anything — a human decides what lands.

The gap this script closes
--------------------------

A scheduled workflow that fails notifies almost nobody. There is no PR, no
issue and no red mark on any branch: the run just goes red in the Actions tab,
where nothing forces a maintainer to look. So an updater can stop working and
the repository simply stops being told that updates exist, which reads exactly
like "there is nothing to update".

That is not hypothetical. It is how `.flutter-version` drifted while every
weekly run reported a newer stable release and then died before publishing —
the failure mode a contributor eventually reported from the other end, as a
Flutter version mismatch on their own machine.

This script turns that silence into a signal. It reads the recent run history
of those workflows and reports which of them are failing, so
.github/workflows/update-automation-health.yml can file one issue about it.

What it decides, and what it does not
-------------------------------------

It classifies, and stops there. It opens nothing, closes nothing, merges
nothing and changes no file in the repository — the same division of labour as
scripts/check_flutter_sdk_update.py, and for the same reason: the judgement can
then be tested offline against fixtures
(test/tooling/update_automation_health_test.py) instead of being buried in YAML.

It also does not fetch anything. The run history is handed to it as JSON, which
is what keeps it offline-testable; the workflow does the `gh api` call.

Which runs count
----------------

Only **completed scheduled** runs, newest first:

* `event` must be `schedule`. A `workflow_dispatch` run is someone testing the
  workflow by hand, which says nothing about whether the weekly cadence that
  actually keeps the repository current is still working. Counting a manual
  green run would let "I ran it once to check" mask a schedule that has been
  failing for a month.
* `status` must be `completed`. A run still in flight has no verdict yet.

Each conclusion then falls into one of three groups:

    healthy   success, skipped, neutral
    broken    failure, timed_out, startup_failure
    unknown   cancelled, action_required, stale, anything unrecognised

A streak is counted from the newest completed scheduled run backwards. `healthy`
ends it at zero, `broken` extends it, and `unknown` stops the count where it is
rather than guessing in either direction — a cancelled run is genuinely no
evidence, and treating it as either a pass or a failure would be inventing one.

The verdict
-----------

A workflow is reported as failing once its consecutive-failure streak reaches
`--min-consecutive-failures` (default 2). One week of grace is deliberate: a
single failed run is usually a runner or network blip and fixes itself on the
next schedule, while two in a row is a standing fault that will not. Two weeks
is also still far inside the window where a missed update matters — the drift
that prompted this ran for five.

A workflow with no completed scheduled runs at all is reported as `unknown`, not
as failing. That is what a newly added workflow looks like before its first
Monday, and filing an issue about it would be wrong.

Exit codes follow the other checkers here: 0 when the input was understood
(whatever the verdict), 2 when it was not. The verdict is what the caller reads,
not the exit code, so a genuinely broken input can never be mistaken for a
healthy repository.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

# The scheduled updaters this script watches, in the order they run on a Monday.
# Kept as a list rather than discovered from .github/workflows/ on purpose: the
# point is to notice when one of *these* stops working, and a glob would quietly
# start covering (or stop covering) workflows as the directory changes.
WATCHED_WORKFLOWS: tuple[str, ...] = (
    "dart-dependency-updates.yml",
    "flutter-sdk-updates.yml",
    "android-toolchain-updates.yml",
)

# Conclusions that end a failure streak: the workflow did its job, or correctly
# had nothing to do.
HEALTHY_CONCLUSIONS = frozenset({"success", "skipped", "neutral"})

# Conclusions that extend a failure streak: the run was meant to finish and did
# not.
BROKEN_CONCLUSIONS = frozenset({"failure", "timed_out", "startup_failure"})

DEFAULT_MIN_CONSECUTIVE_FAILURES = 2

# How many runs back the caller is expected to hand over. Only used to explain
# the default in --help; this script reads whatever it is given.
DEFAULT_RUN_WINDOW = 10


class CheckError(Exception):
    """Raised when the run history cannot be trusted to mean anything."""


def _as_list(value: Any, where: str) -> List[Any]:
    if not isinstance(value, list):
        raise CheckError(
            f"{where}: expected a list of runs, found {type(value).__name__}."
        )
    return value


def _as_str(run: Dict[str, Any], key: str, where: str) -> str:
    value = run.get(key, "")
    if value is None:
        return ""
    if not isinstance(value, str):
        raise CheckError(f"{where}: run field {key!r} is not a string.")
    return value


def scheduled_runs(runs: List[Any], where: str) -> List[Dict[str, Any]]:
    """Return the completed scheduled runs from `runs`, newest first.

    The input is assumed to be newest-first already, which is what the GitHub
    runs API and `gh run list` both return. Nothing here re-sorts it: the
    timestamps are strings whose format is the API's to change, and a sort that
    silently failed would reorder the streak rather than report a problem.
    """

    completed: List[Dict[str, Any]] = []
    for index, run in enumerate(_as_list(runs, where)):
        if not isinstance(run, dict):
            raise CheckError(f"{where}: run {index} is not an object.")
        if _as_str(run, "event", where) != "schedule":
            continue
        if _as_str(run, "status", where) != "completed":
            continue
        completed.append(run)
    return completed


def failure_streak(runs: List[Dict[str, Any]], where: str) -> int:
    """Count consecutive broken runs from the newest backwards.

    Stops at the first run that is not `broken`, so an `unknown` conclusion
    (a cancelled run, say) bounds the count rather than being read as evidence
    either way.
    """

    streak = 0
    for run in runs:
        conclusion = _as_str(run, "conclusion", where)
        if conclusion in BROKEN_CONCLUSIONS:
            streak += 1
            continue
        break
    return streak


def classify_workflow(name: str, runs: Any, min_failures: int) -> Dict[str, Any]:
    """Build the per-workflow verdict for one updater."""

    where = f"{name}"
    completed = scheduled_runs(runs, where)

    if not completed:
        return {
            "workflow": name,
            "state": "unknown",
            "consecutive_failures": 0,
            "last_conclusion": "",
            "last_run_url": "",
            "last_run_at": "",
            "detail": "no completed scheduled run in the window",
        }

    newest = completed[0]
    streak = failure_streak(completed, where)
    state = "failing" if streak >= min_failures else "healthy"

    return {
        "workflow": name,
        "state": state,
        "consecutive_failures": streak,
        "last_conclusion": _as_str(newest, "conclusion", where),
        "last_run_url": _as_str(newest, "url", where)
        or _as_str(newest, "html_url", where),
        "last_run_at": _as_str(newest, "createdAt", where)
        or _as_str(newest, "created_at", where),
        "detail": "",
    }


def build_result(history: Any, min_failures: int) -> Dict[str, Any]:
    """Classify every watched workflow and roll the verdicts up into one."""

    if not isinstance(history, dict):
        raise CheckError(
            f"The run history must be an object keyed by workflow file name, "
            f"found {type(history).__name__}."
        )

    missing = [name for name in WATCHED_WORKFLOWS if name not in history]
    if missing:
        raise CheckError(
            "The run history is missing these watched workflows: " + ", ".join(missing)
        )

    workflows = [
        classify_workflow(name, history[name], min_failures)
        for name in WATCHED_WORKFLOWS
    ]
    failing = [w["workflow"] for w in workflows if w["state"] == "failing"]

    return {
        "verdict": "failing" if failing else "healthy",
        "failing_workflows": failing,
        "min_consecutive_failures": min_failures,
        "workflows": workflows,
    }


def write_github_output(path: str, result: Dict[str, Any]) -> None:
    """Append the two values the workflow branches on."""

    with open(path, "a", encoding="utf-8") as output:
        output.write(f"verdict={result['verdict']}\n")
        output.write(f"failing={','.join(result['failing_workflows'])}\n")


def render_report(result: Dict[str, Any]) -> str:
    """Render the Markdown the issue body is built from."""

    lines: List[str] = []
    if result["verdict"] == "healthy":
        lines.append("Every scheduled update workflow is running.")
        lines.append("")
    else:
        lines.append(
            "One or more of Linthra's scheduled update workflows has failed "
            f"{result['min_consecutive_failures']} or more scheduled runs in a row. "
            "While a run fails before it publishes, no update PR is opened — so the "
            "repository looks up to date when it is not."
        )
        lines.append("")

    lines.append("| Workflow | State | Consecutive failures | Last scheduled run |")
    lines.append("| --- | --- | --- | --- |")
    for workflow in result["workflows"]:
        conclusion = workflow["last_conclusion"] or workflow["detail"] or "unknown"
        url = workflow["last_run_url"]
        last = f"[{conclusion}]({url})" if url else conclusion
        lines.append(
            f"| `{workflow['workflow']}` | {workflow['state']} "
            f"| {workflow['consecutive_failures']} | {last} |"
        )
    lines.append("")
    return "\n".join(lines)


def report(result: Dict[str, Any]) -> None:
    print(f"verdict: {result['verdict']}")
    for workflow in result["workflows"]:
        detail = f" ({workflow['detail']})" if workflow["detail"] else ""
        print(
            f"  {workflow['workflow']}: {workflow['state']}, "
            f"{workflow['consecutive_failures']} consecutive failure(s), "
            f"last {workflow['last_conclusion'] or 'n/a'}{detail}"
        )


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Report scheduled update workflows that have stopped working.",
    )
    parser.add_argument(
        "--runs-file",
        required=True,
        help=(
            "JSON object keyed by workflow file name, each holding that "
            f"workflow's recent runs (newest first, typically {DEFAULT_RUN_WINDOW})."
        ),
    )
    parser.add_argument(
        "--min-consecutive-failures",
        type=int,
        default=DEFAULT_MIN_CONSECUTIVE_FAILURES,
        help=(
            "How many scheduled runs in a row must fail before a workflow is "
            "reported (default: %(default)s)."
        ),
    )
    parser.add_argument(
        "--report",
        help="Write the Markdown report to this file.",
    )
    parser.add_argument(
        "--github-output",
        help="Append key=value lines for GitHub Actions to this file.",
    )
    parser.add_argument("--json", action="store_true", help="Print the result as JSON.")
    parser.add_argument(
        "--quiet", action="store_true", help="Suppress the human-readable report."
    )
    args = parser.parse_args(argv)

    if args.min_consecutive_failures < 1:
        parser.error("--min-consecutive-failures must be at least 1")

    try:
        raw = Path(args.runs_file).read_text(encoding="utf-8")
    except OSError as error:
        print(f"ERROR: cannot read {args.runs_file}: {error}", file=sys.stderr)
        return 2

    try:
        history = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"ERROR: {args.runs_file} is not valid JSON: {error}", file=sys.stderr)
        return 2

    try:
        result = build_result(history, args.min_consecutive_failures)
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if args.report:
        Path(args.report).write_text(render_report(result), encoding="utf-8")
    if args.github_output:
        write_github_output(args.github_output, result)

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif not args.quiet:
        report(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
