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
   security review rather than a commit: the whole host, the whole session
   bus, `--allow=devel`, and the rest. They are rejected here as well as by the
   allow-list, so widening the sandbox means editing two independent checks.

3. **The installed package matches** (with `--installed`). A manifest says what
   was asked for; `flatpak info --show-permissions` says what the built package
   actually carries. Only the second one is what a user gets.

   That output is metadata sections, not finish-args, so it has to be turned
   back into them, and this parser fails closed while doing it: a section, key
   or bus policy value it does not recognise stops the check rather than being
   skipped. A skipped grant is present in the artifact and absent from the
   report, which is a pass that means nothing.

Usage:
    python3 scripts/check_flatpak_permissions.py
    python3 scripts/check_flatpak_permissions.py --installed

The first runs on every PR. The second needs a built package, so it runs in
the Flatpak workflow through scripts/flatpak_filesystem_smoke.sh.
"""

from __future__ import annotations

import argparse
import re
import shlex
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

#: The heading above the refusals table in the rationale document. Every
#: pattern in REFUSED has to have a spelling under it, and every spelling under
#: it has to be refused.
REFUSALS_HEADING = "Permissions that are refused"

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
    r"--see-name=.*",
    r"--system-see-name=.*",
    # Any bus-name wildcard except the one that has been reviewed. Flatpak's
    # trailing `.*` owns every name below the prefix, so `--own-name=org.mpris.*`
    # is broader than the `org.mpris.MediaPlayer2.*` this list used to name
    # explicitly, and slipped straight past it. Naming bad spellings one at a
    # time loses that race, so the rule is inverted: a wildcard is refused
    # unless it is exactly Linthra's own instance name.
    r"--own-name=(?!org\.mpris\.MediaPlayer2\.linthra\.\*$).*\*.*",
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
    "unset-environment": "--unset-env={}",
}

#: A bus policy is one of four values, and three of them are grants. `see` was
#: missing here and, because an unknown value used to be skipped, a package
#: that could see a name on the bus read back as a package that could not.
BUS_FLAGS = {
    "Session Bus Policy": {
        "own": "--own-name={}",
        "talk": "--talk-name={}",
        "see": "--see-name={}",
    },
    "System Bus Policy": {
        "own": "--system-own-name={}",
        "talk": "--system-talk-name={}",
        "see": "--system-see-name={}",
    },
}

#: The fourth value. `none` is an explicit denial, so it is the one bus policy
#: that legitimately produces no permission.
BUS_POLICY_NONE = "none"

#: Metadata groups that describe the package rather than what it may reach:
#: an app id, a runtime, a command. `flatpak info --show-permissions` builds
#: its output from the context alone and should print none of them, but a
#: metadata file read from anywhere else carries them.
IDENTITY_SECTIONS = frozenset({"Application", "Runtime", "Instance", "Build"})


def documented_permissions(path: Path) -> dict[str, str]:
    """The permission table from the rationale document, as {arg: rationale}.

    A row counts only when its first cell is a backticked finish-arg and every
    other cell has something in it, since a row with an empty "why" column is not a
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


def documented_refusals(path: Path) -> list[str]:
    """The spellings named in the rationale document's refusals table.

    The refusal list in this file is what makes a refusal binding; this table
    is what makes it *readable*, and the page promises the reason for each one
    is written there. That promise was being kept by hand, and by the time it
    was checked six refusals had no row: `--socket=x11`, `--device=input`, all
    three system-bus spellings, and `--own-name=org.freedesktop.*`. A rule a
    reviewer cannot look up is not much of a rule.

    So the two are compared, both ways, exactly as the granted table already
    is. Only the table under the refusals heading is read: the granted table
    mentions refused spellings in passing (`--socket=x11` appears in the
    fallback-x11 row) and a mention is not a rationale.
    """
    spellings: list[str] = []
    section = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        if section != REFUSALS_HEADING or not line.startswith("|"):
            continue
        first = line.strip().strip("|").split("|")[0]
        spellings.extend(re.findall(r"`([^`]+)`", first))
    return spellings


def manifest_permissions(path: Path) -> set[str]:
    """The finish-args of one manifest.

    Deliberately a small line reader rather than a YAML parse: the generated
    manifest carries the comments that explain each grant, and this has to work
    on both files with the same code.

    Each entry then goes through shlex, exactly as `check_linux_runner.py`
    reads the same block. Stripping quotes by hand instead meant the two
    checkers disagreed about the same file: a trailing comment on an entry,

        - "--socket=wayland"  # the application window

    read as the permission `--socket=wayland"  # the application window`,
    which matches no refusal pattern and no documented row. It would have
    failed as undocumented, but for the wrong reason and with an unreadable
    message, and the refusal list would have stopped applying to any entry
    written that way.
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
        # A YAML sequence entry is a dash followed by whitespace, or a bare
        # dash. Matching a bare `startswith("-")` would read the mis-indented
        # line `--socket=wayland` as the entry `-socket=wayland`: a permission
        # nobody wrote, silently one dash short of the real one.
        if re.match(r"-(\s|$)", stripped) is None:
            raise ValueError(
                "{}: unrecognised line in finish-args: {!r}".format(path.name, stripped)
            )
        try:
            values = shlex.split(stripped[1:], comments=True, posix=True)
        except ValueError as error:
            raise ValueError(
                "{}: unreadable finish-args entry {!r}: {}".format(
                    path.name, stripped, error
                )
            ) from error
        if len(values) != 1:
            raise ValueError(
                "{}: finish-args entry {!r} does not resolve to exactly one "
                "permission.".format(path.name, stripped)
            )
        permissions.add(values[0])
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
    """Turn Flatpak metadata into the finish-args it represents.

    Raises ValueError for anything it cannot read, which is the whole design
    of this function. `flatpak info --show-permissions` prints metadata
    sections rather than finish-args, and the first version of this parser
    skipped whatever it did not recognise. That is the worst possible failure
    mode for a security check: the grant is in the artifact, absent from the
    report, and the check says OK. Two of those were found in review, an
    `[Environment]` section and a `see` bus policy, and they were found by
    reading the code rather than by anything failing.

    So an unreadable line is a failure. A newer flatpak that prints a section
    this does not know about stops the check with the section named in the
    error, rather than quietly answering a narrower question than the one it
    was asked.
    """
    permissions: set[str] = set()
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            if section not in IDENTITY_SECTIONS and section not in (
                "Context",
                "Environment",
                *BUS_FLAGS,
            ):
                raise ValueError(
                    "unrecognised metadata section [{}]. A grant this checker "
                    "cannot read is not a grant it may ignore: teach it the "
                    "section, or remove it from the package.".format(section)
                )
            continue
        if section in IDENTITY_SECTIONS:
            continue
        if not section:
            raise ValueError("metadata line outside any section: {!r}".format(line))
        if "=" not in line:
            raise ValueError("unreadable line in [{}]: {!r}".format(section, line))
        key, value = (part.strip() for part in line.split("=", 1))
        if section == "Context":
            template = CONTEXT_KEYS.get(key)
            if template is None:
                raise ValueError(
                    "unrecognised [Context] key {!r}. Every key here is a "
                    "permission of some kind, so an unknown one has to fail "
                    "rather than be dropped.".format(key)
                )
            for item in value.split(";"):
                if item:
                    permissions.add(template.format(item))
        elif section == "Environment":
            # `--env=NAME=VALUE` becomes an [Environment] entry in the installed
            # metadata, and REFUSED bans it. Skipping this section meant the ban
            # held for the manifest, where finish-args are read literally, but
            # not for the installed package, which is the artifact a user
            # actually gets. The whole point of --installed is that a manifest
            # says what was asked for and only the package says what was
            # granted.
            permissions.add("--env={}={}".format(key, value))
        else:
            if value == BUS_POLICY_NONE:
                continue
            template = BUS_FLAGS[section].get(value)
            if template is None:
                raise ValueError(
                    "unrecognised [{}] value {!r} for {}. The known values are "
                    "own, talk, see and none.".format(section, value, key)
                )
            permissions.add(template.format(key))
    return collapse_fallback_x11(permissions)


def collapse_fallback_x11(permissions: set[str]) -> set[str]:
    """Read `x11` + `fallback-x11` back as the one grant that produced them.

    `--socket=fallback-x11` sets the plain X11 bit as well as its own. From
    flatpak's option handler, common/flatpak-context.c:

        if (socket == FLATPAK_CONTEXT_SOCKET_FALLBACK_X11)
          socket |= FLATPAK_CONTEXT_SOCKET_X11;

    `flatpak run` clears the X11 bit again when a Wayland display is present,
    which is what makes the grant a fallback. So the installed metadata of an
    app that asked only for `--socket=fallback-x11` reads
    `sockets=...;x11;...;fallback-x11;`, and taking that literally reports a
    `--socket=x11` nobody declared.

    Not hypothetical: it is what the first CI run of `--installed` against a
    real package reported, and the package was correct.

    Both bits together are the only shape `--socket=fallback-x11` can produce,
    so they collapse back to it. **`x11` on its own is untouched and stays
    refused**, which is the case this refusal exists for.

    The limit is worth stating rather than hiding. A package declaring *both*
    `--socket=x11` and `--socket=fallback-x11` is indistinguishable here from
    one declaring only the fallback, because the metadata is the same two bits
    either way. That single case is covered instead by the two manifest checks,
    which read finish-args literally and both refuse `--socket=x11` before
    anything is built.
    """
    if {"--socket=x11", "--socket=fallback-x11"} <= permissions:
        return permissions - {"--socket=x11"}
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

    refusals = documented_refusals(RATIONALE)
    if not refusals:
        print(
            "ERROR: {} lists no refused permissions under '{}'. The refusal "
            "list is only binding if a reviewer can read why.".format(
                RATIONALE, REFUSALS_HEADING
            ),
            file=sys.stderr,
        )
        return 1
    for pattern in REFUSED:
        if not any(re.fullmatch(pattern, spelling) for spelling in refusals):
            problems.append(
                "the refusal {} has no spelling in {}. A refusal nobody wrote "
                "down is a rule nobody can look up.".format(pattern, RATIONALE.name)
            )
    for spelling in refusals:
        if not refused({spelling}):
            problems.append(
                "{} is listed as refused in {}, but nothing refuses it. Remove "
                "the row or add the pattern.".format(spelling, RATIONALE.name)
            )

    for manifest in MANIFESTS:
        if not manifest.exists():
            problems.append("{} is missing.".format(manifest))
            continue
        try:
            declared = manifest_permissions(manifest)
        except ValueError as error:
            problems.append(str(error))
            continue
        problems.extend(
            check(
                documented,
                declared,
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
        except (OSError, RuntimeError, ValueError) as error:
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
