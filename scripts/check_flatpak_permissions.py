#!/usr/bin/env python3
"""Hold Linthra's Flatpak permissions to their written rationale (#455).

`scripts/check_linux_runner.py` already keeps an exact allow-list, so a new
finish-arg fails until somebody edits that list. This is the other half: a
permission also has to be *explained*, in a table a reviewer can read, and an
explanation cannot outlive the permission it explains.

Three things are checked.

1. **Every permission has a rationale, and every rationale has a permission.**
   The table in docs/flatpak-permissions.md is compared against the finish-args
   of both manifests. Either direction failing is a failure: an unexplained
   grant, or a page describing a sandbox that no longer exists.

2. **Nothing on the refused list is present.** Those are grants that need a
   security review rather than a commit — the whole host, the whole session
   bus, `--allow=devel`, and the rest. They are rejected here as well as by the
   allow-list, so widening the sandbox means editing two independent checks.

3. **The installed package matches** (with `--installed`). A manifest says what
   was asked for; `flatpak info --show-permissions` says what the built package
   actually carries. Only the second one is what a user gets.

Usage:
    python3 scripts/check_flatpak_permissions.py
    python3 scripts/check_flatpak_permissions.py --installed
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RATIONALE = REPO_ROOT / "docs" / "flatpak-permissions.md"
MANIFESTS = (
    REPO_ROOT / "flatpak" / "flatpak-flutter.yml",
    REPO_ROOT / "flatpak" / "io.github.thezupzup.linthra.yml",
)
APP_ID = "io.github.thezupzup.linthra"

#: Grants that are never acceptable without a security review, as regular
#: expressions matched against a whole finish-arg. The reason each is refused
#: is in the rationale document; this list is what makes the refusal binding.
REFUSED = (
    r"--filesystem=.*",
    r"--persist=.*",
    r"--socket=session-bus",
    r"--socket=system-bus",
    r"--socket=ssh-auth",
    r"--socket=gpg-agent",
    r"--socket=cups",
    r"--socket=x11",  # fallback-x11 is the narrow form and is spelled out
    r"--talk-name=.*",
    r"--system-talk-name=.*",
    r"--system-own-name=.*",
    r"--own-name=org\.mpris\.MediaPlayer2\.\*",
    r"--own-name=org\.freedesktop\..*",
    r"--device=all",
    r"--device=shm",
    r"--device=input",
    r"--allow=.*",
    r"--env=.*",
)

#: How `flatpak info --show-permissions` spells each finish-arg. The metadata
#: format groups by key; the manifest lists one flag per grant.
CONTEXT_KEYS = {
    "shared": "--share={}",
    "sockets": "--socket={}",
    "devices": "--device={}",
    "filesystems": "--filesystem={}",
    "persistent": "--persist={}",
    "features": "--allow={}",
}

BUS_FLAGS = {
    "Session Bus Policy": {"own": "--own-name={}", "talk": "--talk-name={}"},
    "System Bus Policy": {
        "own": "--system-own-name={}",
        "talk": "--system-talk-name={}",
    },
}


def documented_permissions(path: Path) -> dict[str, str]:
    """The permission table from the rationale document, as {arg: rationale}.

    A row counts only when its first cell is a backticked finish-arg and every
    other cell has something in it — a row with an empty "why" column is not a
    rationale, it is a placeholder.
    """
    rows: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 4:
            continue
        match = re.fullmatch(r"`(--[^`]+)`", cells[0])
        if match is None:
            continue
        permission = match.group(1)
        if any(not cell for cell in cells[1:4]):
            raise ValueError(
                "{}: the row for {} has an empty column. A permission needs a "
                "feature, a place it is used, and why nothing narrower "
                "works.".format(path.name, permission)
            )
        rows[permission] = cells[3]
    return rows


def manifest_permissions(path: Path) -> set[str]:
    """The finish-args of one manifest.

    Deliberately a small line reader rather than a YAML parse: the generated
    manifest carries the comments that explain each grant, and this has to work
    on both files with the same code.
    """
    permissions: set[str] = set()
    in_block = False
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if re.fullmatch(r"finish-args\s*:\s*(?:#.*)?", stripped):
            in_block = True
            continue
        if not in_block:
            continue
        if stripped.startswith("#") or not stripped:
            continue
        if not line.startswith((" ", "\t")):
            break  # the next top-level key ends the block
        if not stripped.startswith("- "):
            break
        permissions.add(stripped[2:].strip().strip("'\""))
    return permissions


def installed_permissions(app_id: str) -> set[str]:
    """The finish-args the installed package actually carries.

    Parsed from `flatpak info --show-permissions`, which prints the package's
    metadata rather than the manifest it was built from.
    """
    result = subprocess.run(
        ["flatpak", "info", "--show-permissions", app_id],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "could not read the installed permissions for {}: {}".format(
                app_id,
                result.stderr.strip() or "flatpak exited {}".format(result.returncode),
            )
        )
    return parse_metadata(result.stdout)


def parse_metadata(text: str) -> set[str]:
    """Turn Flatpak metadata into the finish-args it represents."""
    permissions: set[str] = set()
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if section == "Context":
            template = CONTEXT_KEYS.get(key)
            if template is None:
                continue
            for item in value.split(";"):
                if item:
                    permissions.add(template.format(item))
        elif section in BUS_FLAGS:
            template = BUS_FLAGS[section].get(value)
            if template is not None:
                permissions.add(template.format(key))
    return permissions


def refused(permissions: set[str]) -> list[str]:
    return sorted(
        permission
        for permission in permissions
        if any(re.fullmatch(pattern, permission) for pattern in REFUSED)
    )


def check(documented: dict[str, str], actual: set[str], source: str) -> list[str]:
    """Problems with one permission set, as messages."""
    problems: list[str] = []
    for permission in refused(actual):
        problems.append(
            "{}: {} is refused. Widening the sandbox this way needs a security "
            "review and its own issue, not a commit.".format(source, permission)
        )
    for permission in sorted(actual - set(documented)):
        problems.append(
            "{}: {} has no row in {}. Every permission needs a written "
            "rationale.".format(source, permission, RATIONALE.name)
        )
    for permission in sorted(set(documented) - actual):
        problems.append(
            "{}: {} is documented in {} but not granted. Remove the row rather "
            "than leaving a rationale for a permission that no longer "
            "exists.".format(source, permission, RATIONALE.name)
        )
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--installed",
        action="store_true",
        help="also check the installed package's effective permissions",
    )
    parser.add_argument("--app-id", default=APP_ID)
    args = parser.parse_args(argv)

    try:
        documented = documented_permissions(RATIONALE)
    except (OSError, ValueError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        return 1
    if not documented:
        print(
            "ERROR: {} lists no permissions. It is the source of truth for "
            "this check, so an empty table is a broken check, not a clean "
            "one.".format(RATIONALE),
            file=sys.stderr,
        )
        return 1

    problems: list[str] = []
    for manifest in MANIFESTS:
        if not manifest.exists():
            problems.append("{} is missing.".format(manifest))
            continue
        problems.extend(
            check(
                documented,
                manifest_permissions(manifest),
                manifest.relative_to(REPO_ROOT).as_posix(),
            )
        )

    if args.installed:
        try:
            problems.extend(
                check(
                    documented,
                    installed_permissions(args.app_id),
                    "installed {}".format(args.app_id),
                )
            )
        except (OSError, RuntimeError) as error:
            print("ERROR: {}".format(error), file=sys.stderr)
            print(
                "Nothing was checked about the installed package, so this is "
                "not a pass.",
                file=sys.stderr,
            )
            return 2

    if problems:
        for problem in problems:
            print("FAIL: {}".format(problem), file=sys.stderr)
        return 1

    print(
        "OK: {} permission(s), each with a written rationale in {}.".format(
            len(documented), RATIONALE.relative_to(REPO_ROOT).as_posix()
        )
    )
    for permission in sorted(documented):
        print("  {}".format(permission))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
