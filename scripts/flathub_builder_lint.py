#!/usr/bin/env python3
"""Run Flathub's own submission linter against Linthra's packaging (#449).

`appstreamcli validate` and `desktop-file-validate`, which CI already runs, are
not this. They check that two files are well-formed. Flathub's linter checks
whether a *submission* would be accepted: whether the sources are reproducible,
whether the permissions are ones Flathub grants, whether the metainfo carries
what a software centre needs to show the app at all.

This script is the repeatable way to run it and the honest way to read the
result. In particular it refuses two comfortable outcomes:

  * A missing linter is not a pass. If `org.flatpak.Builder` is not installed
    the script exits 2 and says so, rather than reporting a clean run of
    nothing.
  * A finding is only tolerated when it has a written reason in the exceptions
    file, and an exception that the linter no longer reports is itself a
    failure, so the file cannot quietly accumulate reasons for problems that
    were fixed years ago.

Usage:
    python3 scripts/flathub_builder_lint.py --manifest flatpak/<app-id>.yml
    python3 scripts/flathub_builder_lint.py --repo flatpak/repo-ci
    python3 scripts/flathub_builder_lint.py --builddir flatpak/flatpak-builder-ci

Exit codes:
    0  every finding is a documented exception, and every documented exception
       was reported
    1  an undocumented finding, or a stale exception
    2  the linter could not be run at all

Not every mode returns JSON: `appstream` delegates to appstreamcli and prints
its verdict as text. There the exit code is the verdict, and the text is
printed either way.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_EXCEPTIONS = REPO_ROOT / "flatpak" / "flathub-lint-exceptions.json"

# The linter modes this script drives. Exception keys are qualified with one of
# these, so a reason states which run it belongs to.
MODES = ("manifest", "repo", "appstream")

#: The Flatpak that ships flatpak-builder-lint. Flathub's own documentation
#: runs the linter this way, so this is the tool a reviewer will use.
LINTER_APP = "org.flatpak.Builder"
LINTER_COMMAND = "flatpak-builder-lint"

#: Where the exported AppStream catalogue lands inside a flatpak-builder build
#: directory. Linting the source metainfo is not the same check: this is the
#: file a software centre actually reads, after appstreamcli compose has run.
APPSTREAM_IN_BUILDDIR = "files/share/app-info/xmls/{app_id}.xml.gz"

APP_ID = "io.github.thezupzup.linthra"


class LinterUnavailable(RuntimeError):
    """The linter could not be run, so nothing was checked."""


def linter_versions() -> dict[str, str]:
    """Version facts worth printing beside a result.

    The linter's rules change with the tool, so "clean" is only meaningful
    alongside the version that said so.
    """
    versions: dict[str, str] = {}
    for label, command in (
        ("flatpak", ["flatpak", "--version"]),
        ("org.flatpak.Builder", ["flatpak", "info", "--show-ref", LINTER_APP]),
        (
            "org.flatpak.Builder commit",
            ["flatpak", "info", "--show-commit", LINTER_APP],
        ),
        (
            LINTER_COMMAND,
            [
                "flatpak",
                "run",
                f"--command={LINTER_COMMAND}",
                LINTER_APP,
                "--version",
            ],
        ),
    ):
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, check=False
            )
        except OSError as error:  # flatpak itself is missing
            raise LinterUnavailable(
                "flatpak is not installed: {}".format(error)
            ) from error
        if result.returncode == 0:
            versions[label] = result.stdout.strip()
    return versions


def run_linter(mode: str, target: Path) -> dict:
    """Run one linter mode and return its parsed report.

    The linter exits non-zero when it finds something, which is not an error
    here: the findings are the output. Anything that stops it from producing a
    report at all is.
    """
    command = [
        "flatpak",
        "run",
        f"--command={LINTER_COMMAND}",
        LINTER_APP,
        mode,
        str(target),
    ]
    print("$ {}".format(" ".join(command)))
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError as error:
        raise LinterUnavailable("could not run the linter: {}".format(error)) from error

    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)

    output = result.stdout.strip()
    if not output:
        # flatpak-builder-lint 3.x prints nothing at all when a mode finds
        # nothing, and exits 0. That is a clean report, not a missing tool,
        # and it cannot be confused with one here, because main() has already
        # established that org.flatpak.Builder is installed before any mode
        # runs. A *non-zero* exit with no output is still unexplained, and is
        # still refused.
        if result.returncode == 0:
            return {}
        raise LinterUnavailable(
            "the linter produced no report for {} {} and exited {}. Nothing "
            "explains that, so it cannot be read as a clean run.".format(
                mode, target, result.returncode
            )
        )
    try:
        report = json.loads(output)
    except json.JSONDecodeError:
        # Not every mode speaks JSON. `appstream` hands the catalogue to
        # appstreamcli and prints its human-readable verdict
        # ("Validation was successful."), which the first version of this
        # script refused as unreadable output and turned into a hard failure.
        #
        # For those, the exit code is the verdict and the text is the detail:
        # both are surfaced, so a failure still has to be looked at and cannot
        # pass as clean.
        if result.returncode == 0:
            return {"message": output}
        # The linter itself failed rather than reporting a submission finding,
        # and every such failure in this mode collapses to one name. That name
        # must never be exceptable: a written reason attached to it would go on
        # matching after the original problem was fixed and a different one
        # appeared, which is exactly the guarantee the exceptions file makes.
        return {
            "errors": ["{}-lint-failed".format(mode)],
            "message": output,
        }
    if not isinstance(report, dict):
        raise LinterUnavailable(
            "the linter's report for {} {} was not an object.".format(mode, target)
        )
    # A non-zero exit has to be explained by something this script will treat as
    # a finding. A structured report that carries neither errors nor warnings
    # alongside a failure exit would otherwise read as clean and print PASS,
    # which is the one outcome a non-zero linter run must never produce. The
    # text and empty-output paths above already refuse this; so does JSON.
    if result.returncode != 0 and not (report.get("errors") or report.get("warnings")):
        report = dict(report)
        report["errors"] = ["{}-lint-failed".format(mode)]
    return report


def findings(report: dict) -> dict[str, list[str]]:
    """Errors and warnings from a report, both treated as findings.

    Flathub's reviewers read the warnings too, and #449 is explicitly about
    reaching a submission-quality result rather than an exit code.
    """
    return {
        "errors": sorted(str(item) for item in report.get("errors", []) or []),
        "warnings": sorted(str(item) for item in report.get("warnings", []) or []),
    }


def load_exceptions(path: Path) -> dict[str, str]:
    """The documented exceptions, as {"mode/finding": reason}.

    A missing file means no exceptions, which is the state #449 wants to end
    in.

    Keys are qualified by the linter mode they belong to, because CI does not
    run every mode in one invocation: the manifest is linted before the build
    and the repo and catalogue after it. An unqualified key could not be told
    apart from one whose mode simply did not run this time, so the staleness
    check would have to either miss real stale entries or reject live ones.
    """
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    raw = data.get("exceptions", {})
    if not isinstance(raw, dict):
        raise ValueError("{}: `exceptions` must be an object.".format(path))
    exceptions: dict[str, str] = {}
    for finding, reason in raw.items():
        key = str(finding)
        mode, sep, name = key.partition("/")
        if not sep or mode not in MODES or not name:
            raise ValueError(
                "{}: exception {!r} must be qualified with the linter mode it "
                "belongs to, as one of {}. CI lints the manifest and the built "
                "repo in separate runs, so an unqualified reason cannot be "
                "told from one whose mode did not run.".format(
                    path, key, "/, ".join(sorted(MODES)) + "/"
                )
            )
        if name.endswith("-lint-failed"):
            raise ValueError(
                "{}: {!r} cannot be excepted. That name means the linter itself "
                "failed, and it is the same name whatever the failure was, so a "
                "reason for it would outlive the problem it explains.".format(path, key)
            )
        text = reason if isinstance(reason, str) else reason.get("reason", "")
        if not text.strip():
            raise ValueError(
                "{}: exception {!r} has no written reason. An exception without "
                "one is a suppression.".format(path, key)
            )
        exceptions[key] = text.strip()
    return exceptions


def report_mode(mode: str, target: Path, exceptions: dict[str, str]) -> tuple[int, set]:
    """Print one mode's result. Returns (undocumented count, seen keys).

    Findings are looked up as "mode/finding", so a reason written for the repo
    run cannot silently accept a same-named finding from the manifest run.
    """
    report = run_linter(mode, target)
    found = findings(report)
    seen: set[str] = set()
    undocumented = 0

    print("\n--- {} {} ---".format(mode, target))
    for kind in ("errors", "warnings"):
        for finding in found[kind]:
            key = "{}/{}".format(mode, finding)
            seen.add(key)
            # load_exceptions refuses to record one of these, so this is belt
            # and braces: a linter failure is never accepted, whatever the file
            # says.
            if key in exceptions and not finding.endswith("-lint-failed"):
                print("  {} (accepted): {}".format(finding, kind[:-1]))
                print("      reason: {}".format(exceptions[key]))
            else:
                undocumented += 1
                print("  {} ({})".format(finding, kind[:-1]))
    if not found["errors"] and not found["warnings"]:
        print("  no findings")

    # Anything else the linter said, verbatim, so a message that is not an
    # error or a warning is not lost.
    for key, value in sorted(report.items()):
        if key in {"errors", "warnings"}:
            continue
        print("  {}: {}".format(key, value))
    return undocumented, seen


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="manifest to lint")
    parser.add_argument("--repo", type=Path, help="exported OSTree repo to lint")
    parser.add_argument(
        "--builddir",
        type=Path,
        help="flatpak-builder build directory, whose exported AppStream "
        "catalogue is linted",
    )
    parser.add_argument(
        "--exceptions",
        type=Path,
        default=DEFAULT_EXCEPTIONS,
        help="documented exceptions (default: {})".format(
            DEFAULT_EXCEPTIONS.relative_to(REPO_ROOT)
        ),
    )
    args = parser.parse_args(argv)

    targets: list[tuple[str, Path]] = []
    if args.manifest:
        targets.append(("manifest", args.manifest))
    if args.repo:
        targets.append(("repo", args.repo))
    if args.builddir:
        targets.append(
            (
                "appstream",
                args.builddir / APPSTREAM_IN_BUILDDIR.format(app_id=APP_ID),
            )
        )
    if not targets:
        parser.error("pass at least one of --manifest, --repo or --builddir")

    for mode, target in targets:
        if not target.exists():
            print("ERROR: {} does not exist ({})".format(target, mode), file=sys.stderr)
            return 2

    if shutil.which("flatpak") is None:
        print(
            "ERROR: flatpak is not installed, so nothing was linted. This is "
            "not a pass.",
            file=sys.stderr,
        )
        return 2

    try:
        exceptions = load_exceptions(args.exceptions)
    except (ValueError, json.JSONDecodeError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        return 1

    try:
        versions = linter_versions()
        print("Flathub builder lint")
        for label, value in versions.items():
            print("  {}: {}".format(label, value))
        if LINTER_APP not in versions:
            raise LinterUnavailable(
                "{} is not installed: `flatpak install -y flathub {}`.".format(
                    LINTER_APP, LINTER_APP
                )
            )

        undocumented = 0
        seen: set[str] = set()
        for mode, target in targets:
            mode_undocumented, mode_seen = report_mode(mode, target, exceptions)
            undocumented += mode_undocumented
            seen |= mode_seen
    except LinterUnavailable as error:
        print("\nERROR: {}".format(error), file=sys.stderr)
        print("Nothing was linted, so this is not a pass.", file=sys.stderr)
        return 2

    print()
    # Only the modes this run actually linted. CI lints the manifest before the
    # build and the repo and catalogue after it, in separate invocations, so
    # comparing every exception against one run's findings would report the
    # other run's live exceptions as stale and fail the build.
    ran = {mode for mode, _ in targets}
    scoped = {key for key in exceptions if key.split("/", 1)[0] in ran}
    stale = sorted(scoped - seen)
    if stale:
        print(
            "FAIL: {} documented exception(s) were not reported by the linter. "
            "Remove them rather than leaving a written reason for a problem "
            "that no longer exists:".format(len(stale))
        )
        for finding in stale:
            print("  {}".format(finding))
    if undocumented:
        print(
            "FAIL: {} finding(s) with no written reason. Fix them, or record "
            "the reason in {}.".format(undocumented, args.exceptions.name)
        )
    if stale or undocumented:
        return 1

    if scoped:
        print(
            "PASS: every finding has a documented reason ({} accepted).".format(
                len(scoped)
            )
        )
    else:
        print("PASS: the linter reported nothing.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
