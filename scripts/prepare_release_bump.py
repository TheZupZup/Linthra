#!/usr/bin/env python3
"""prepare_release_bump.py — prepare a Linthra release version bump.

Updates every file that must agree on the release version:

  * pubspec.yaml                                            (`version:` line)
  * lib/core/app_info.dart                                  (`_devVersionName`)
  * fastlane/metadata/android/en-US/changelogs/<code>.txt   (Fastlane changelog)
  * metadata/io.github.thezupzup.linthra.yml                (F-Droid CurrentVersion/Code)
  * linux/packaging/<app-id>.metainfo.xml                   (AppStream <release>)

Then prints the next safe command — the release preflight — so a contributor
running the script locally sees the same workflow the GitHub Action runs.

This script does NOT create a git tag, push anything, build the APK/AAB, or
publish a GitHub Release. Those steps still happen manually after the
generated PR is merged. See docs/distribution/release-process.md.

Usage:

    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37
    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37 \
        --changelog "Linthra 0.1.0-alpha.37 — fixed X."
    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37 --force-changelog
    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37 --keep-changelog
    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37 --release-date 2026-09-09

Drift between all of those (and the release tag) is checked by
scripts/check_release_metadata_sync.py, which CI runs on every push.

The version-to-versionCode encoding mirrors tool/version_from_tag.dart and
scripts/release_preflight.sh; see docs/distribution/release-process.md §1.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

# Encoding rules — must match tool/version_from_tag.dart and the bash twin
# scripts/release_preflight.sh. Drift is caught by
# test/tooling/prepare_release_bump_test.dart against the same corpus.
_MAJOR_WEIGHT = 10_000_000
_MINOR_WEIGHT = 100_000
_PATCH_WEIGHT = 1_000
_MAX_VERSION_CODE = 2_100_000_000
_MAX_MINOR = 99
_MAX_PATCH = 99
_MAX_PRE_NUMBER = 299
_STABLE_RANK = 999
_TIER_BASE = {"alpha": 0, "beta": 300, "rc": 600}
_TAG_PATTERN = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$")


class VersionError(Exception):
    """A user-visible failure: bad input or unsafe edit."""


def version_from_tag(tag):
    """Parse `tag` into its canonical (versionName, versionCode).

    Mirrors `versionFromTag` in tool/version_from_tag.dart. Accepts a leading
    `v`; the returned name strips it.
    """
    match = _TAG_PATTERN.match(tag.strip())
    if not match:
        raise VersionError(
            'Malformed release tag "{}". Expected vMAJOR.MINOR.PATCH with an '
            "optional -alpha.N / -beta.N / -rc.N pre-release suffix, e.g. "
            "v0.1.0-alpha.37, v0.1.0-rc.1, or v1.2.3.".format(tag)
        )

    major = int(match.group(1))
    minor = int(match.group(2))
    patch = int(match.group(3))
    tier = match.group(4)
    pre_number = match.group(5)

    if minor > _MAX_MINOR:
        raise VersionError(
            'Minor version {} in tag "{}" exceeds the supported range (0..{}).'.format(
                minor, tag, _MAX_MINOR
            )
        )
    if patch > _MAX_PATCH:
        raise VersionError(
            'Patch version {} in tag "{}" exceeds the supported range (0..{}).'.format(
                patch, tag, _MAX_PATCH
            )
        )

    if tier is None:
        rank = _STABLE_RANK
        name = "{}.{}.{}".format(major, minor, patch)
    else:
        pre_n = int(pre_number)
        if pre_n > _MAX_PRE_NUMBER:
            raise VersionError(
                'Pre-release number {} in tag "{}" exceeds the supported range '
                "(0..{}).".format(pre_n, tag, _MAX_PRE_NUMBER)
            )
        rank = _TIER_BASE[tier] + pre_n
        name = "{}.{}.{}-{}.{}".format(major, minor, patch, tier, pre_n)

    code = major * _MAJOR_WEIGHT + minor * _MINOR_WEIGHT + patch * _PATCH_WEIGHT + rank
    if code <= 0 or code > _MAX_VERSION_CODE:
        raise VersionError(
            'Derived versionCode {} for tag "{}" is outside the valid Android '
            "range (1..{}).".format(code, tag, _MAX_VERSION_CODE)
        )
    return name, code


def update_pubspec(path, version_name, version_code):
    """Set `version: <name>+<code>` in pubspec.yaml.

    Returns True if the file changed.
    """
    text = path.read_text()
    full = "{}+{}".format(version_name, version_code)
    # `[ \t]*$` (not `\s*$`) so we don't greedily swallow the trailing newline
    # and collapse blank lines around the `version:` entry.
    version_line = re.compile(r"^version:[ \t]*(\S+)[ \t]*$", re.MULTILINE)
    match = version_line.search(text)
    if not match:
        raise VersionError("pubspec.yaml at {} has no `version:` line.".format(path))
    if match.group(1) == full:
        return False
    new_text = version_line.sub("version: {}".format(full), text, count=1)
    path.write_text(new_text)
    return True


def update_app_info(path, version_name):
    """Set `_devVersionName = '<name>'` in app_info.dart.

    Returns True if the file changed. If the field is not present, raises so the
    workflow fails loudly instead of silently guessing.
    """
    if not path.exists():
        raise VersionError(
            "lib/core/app_info.dart not found at {}; refusing to guess.".format(path)
        )
    text = path.read_text()
    pattern = re.compile(r"(static\s+const\s+String\s+_devVersionName\s*=\s*)'[^']*'")
    matches = pattern.findall(text)
    if not matches:
        raise VersionError(
            "Could not find `_devVersionName = '...'` in {}. Refusing to "
            "guess — fix the file by hand and re-run.".format(path)
        )
    if len(matches) != 1:
        raise VersionError(
            "Expected exactly one `_devVersionName` declaration in {}; "
            "found {}. Refusing to update.".format(path, len(matches))
        )
    new_text = pattern.sub(r"\g<1>'" + version_name + "'", text, count=1)
    if new_text == text:
        return False
    path.write_text(new_text)
    return True


def default_changelog(version_name):
    """The safe placeholder Fastlane changelog used when the input is empty."""
    return (
        "Linthra {name} — maintenance update.\n"
        "\n"
        "No app feature, permission, or behavior change in this build. See the\n"
        "GitHub release notes for any build/packaging details.\n"
        "\n"
        "Still an alpha — expect rough edges. Not on F-Droid yet.\n"
    ).format(name=version_name)


def create_changelog(path, version_name, body, allow_overwrite, keep_existing):
    """Write the Fastlane changelog at `path`.

    Returns True if the file was created or changed. Raises if the file already
    exists with different content and `allow_overwrite` is False — the workflow
    must opt into clobbering an existing changelog.

    `keep_existing` leaves a changelog that is already there exactly as it is.
    That is what a re-run needs when the release notes were written by hand and
    something *else* (the AppStream entry, the F-Droid code) still has to be
    fixed: without it the only ways through are failing here or overwriting
    real notes with the generated default.
    """
    raw = body if body else default_changelog(version_name)
    content = raw.rstrip() + "\n"
    if path.exists():
        existing = path.read_text()
        if existing == content:
            return False
        if keep_existing:
            return False
        if not allow_overwrite:
            raise VersionError(
                "Changelog already exists at {} and would be modified. "
                "Pass --force-changelog to overwrite it.".format(path)
            )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return True


def fdroid_current_version_code(text, base_version_code):
    """Return the CurrentVersionCode F-Droid will use for this metadata.

    Linthra's F-Droid entry uses VercodeOperation to turn one canonical base
    code from pubspec.yaml into three per-ABI codes (`base*10 + rank`). F-Droid's
    update checker compares/records the highest transformed code, so writing the
    untransformed base here makes our draft metadata internally inconsistent and
    trips the release guardrail.

    Keep this parser deliberately narrow: the repo only supports the simple
    `%c*MULTIPLIER + OFFSET` form used by Linthra. If a future metadata change
    introduces another operation shape, fail instead of evaluating arbitrary
    metadata as code or silently guessing a CurrentVersionCode.
    """
    marker = re.search(r"^VercodeOperation:[ \t]*$", text, flags=re.MULTILINE)
    if marker is None:
        return base_version_code

    operations = []
    for line in text[marker.end() :].splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # The VercodeOperation value is a YAML list. Stop as soon as the next
        # metadata key begins, even if a fixture/editor happened to indent it.
        # A malformed *list item* is still an error below; only a non-list line
        # terminates this field.
        item = re.fullmatch(r"-\s*(.+)", stripped)
        if item is None:
            break

        expression = item.group(1).strip()
        if (
            len(expression) >= 2
            and expression[0] == expression[-1]
            and expression[0] in ("'", '"')
        ):
            expression = expression[1:-1]
        match = re.fullmatch(r"%c\s*\*\s*(\d+)\s*\+\s*(\d+)", expression)
        if match is None:
            raise VersionError(
                "Unsupported F-Droid VercodeOperation {!r}; expected "
                "`%c*MULTIPLIER + OFFSET`; refusing to guess "
                "CurrentVersionCode.".format(expression)
            )
        multiplier = int(match.group(1))
        offset = int(match.group(2))
        transformed = base_version_code * multiplier + offset
        if transformed <= 0 or transformed > _MAX_VERSION_CODE:
            raise VersionError(
                "F-Droid VercodeOperation {!r} transforms base versionCode {} "
                "to {}, outside the valid Android range (1..{}).".format(
                    expression,
                    base_version_code,
                    transformed,
                    _MAX_VERSION_CODE,
                )
            )
        operations.append(transformed)

    if not operations:
        raise VersionError(
            "F-Droid metadata declares VercodeOperation but contains no "
            "supported operations; refusing to guess CurrentVersionCode."
        )
    return max(operations)


def update_fdroid_metadata(path, version_name, version_code):
    """Update CurrentVersion/CurrentVersionCode in the F-Droid metadata YAML.

    When VercodeOperation is present, CurrentVersionCode must be the highest
    transformed per-ABI code, matching F-Droid's own update-check behavior.
    Without VercodeOperation the canonical base versionCode is used unchanged.

    Returns True if the file changed. If the file does not exist, returns False
    silently — the repo may not carry the draft F-Droid entry. The Builds block
    is intentionally left untouched.
    """
    if not path.exists():
        return False
    text = path.read_text()
    if not re.search(r"^CurrentVersion:.*$", text, flags=re.MULTILINE):
        raise VersionError(
            "F-Droid metadata at {} has no `CurrentVersion:` line; refusing "
            "to guess.".format(path)
        )
    if not re.search(r"^CurrentVersionCode:.*$", text, flags=re.MULTILINE):
        raise VersionError(
            "F-Droid metadata at {} has no `CurrentVersionCode:` line; "
            "refusing to guess.".format(path)
        )
    fdroid_version_code = fdroid_current_version_code(text, version_code)
    new_text = re.sub(
        r"^CurrentVersion:.*$",
        "CurrentVersion: {}".format(version_name),
        text,
        count=1,
        flags=re.MULTILINE,
    )
    new_text = re.sub(
        r"^CurrentVersionCode:.*$",
        "CurrentVersionCode: {}".format(fdroid_version_code),
        new_text,
        count=1,
        flags=re.MULTILINE,
    )
    if new_text == text:
        return False
    path.write_text(new_text)
    return True


# AppStream release entries (#452).
#
# Matched with regexes rather than round-tripped through ElementTree on
# purpose: linux/packaging/<app-id>.metainfo.xml is hand-maintained and carries
# a long explanatory comment block, and an XML round-trip would reflow the whole
# file into an unreviewable diff every release. These patterns read the one
# shape the file actually uses, and anything they cannot find is reported
# instead of guessed at.
_RELEASES_BLOCK = re.compile(
    r"(?P<indent>[ \t]*)<releases>[ \t]*\r?\n(?P<body>.*?)(?P<closing>[ \t]*</releases>)",
    re.DOTALL,
)
# A release entry is either self-closing or a pair wrapping child elements
# (AppStream allows a <description>, <url>, <issues> inside one). Matching
# the whole element means an entry with children is seen once, and can be
# rewritten without leaving its children orphaned.
_RELEASE_ENTRY = re.compile(
    r"<release\b[^>]*?/>|<release\b[^>]*?>.*?</release\s*>", re.DOTALL
)
_RELEASE_OPEN_TAG = re.compile(r"<release\b[^>]*?/?>")
_ATTRIBUTE = re.compile(r'([A-Za-z_:][-\w:.]*)\s*=\s*"([^"]*)"')


def is_prerelease(version_name):
    """Whether `version_name` carries an -alpha.N / -beta.N / -rc.N suffix."""
    match = _TAG_PATTERN.match(version_name.strip())
    if match is None:
        raise VersionError('Malformed version "{}".'.format(version_name))
    return match.group(4) is not None


def today_utc():
    """Today's date in UTC, so two machines bumping at once agree."""
    return dt.datetime.now(dt.timezone.utc).date().isoformat()


def parse_release_date(value):
    """Validate a YYYY-MM-DD release date and return it normalised."""
    try:
        return dt.date.fromisoformat(value.strip()).isoformat()
    except ValueError:
        raise VersionError(
            'Malformed release date "{}"; expected YYYY-MM-DD.'.format(value)
        ) from None


def appstream_releases(text):
    """Return the `<release .../>` entries of an AppStream document, in order.

    Each entry is `(element, attributes)`, the attributes being those of its
    opening tag. Returns None when the document has no
    `<releases>` block at all, so a caller can tell "no releases listed" from
    "this file is not shaped the way we think it is".
    """
    block = _RELEASES_BLOCK.search(text)
    if block is None:
        return None
    return [
        (element, dict(_ATTRIBUTE.findall(_RELEASE_OPEN_TAG.match(element).group(0))))
        for element in _RELEASE_ENTRY.findall(block.group("body"))
    ]


def _release_entry(version_name, release_date, self_closing=True):
    """The `<release>` tag for one release.

    Pre-releases are marked `type="development"` so a software centre does not
    offer an alpha as if it were the current stable build. `self_closing` is
    False when the tag opens an element that has children to keep.
    """
    attributes = 'version="{}" date="{}"'.format(version_name, release_date)
    if is_prerelease(version_name):
        attributes += ' type="development"'
    return "<release {}{}>".format(attributes, "/" if self_closing else "")


def update_appstream_release(path, version_name, release_date):
    """Add or refresh this release's entry in the AppStream metainfo file.

    Newest first, which is the order the file already uses and the order
    software centres read. An entry that already names `version_name` is
    rewritten in place rather than duplicated, so re-running the script is
    safe.

    `release_date` is the date to record, or None to stamp a *new* entry with
    today (UTC) and leave an entry that is already there on the date it has. A
    release that already shipped therefore keeps its published date through a
    re-run on another day; changing one is a deliberate --release-date.

    Returns True if the file changed. A missing file returns False silently, as
    with the F-Droid metadata: a checkout may not carry the Linux packaging.
    """
    if not path.exists():
        return False
    text = path.read_text()
    block = _RELEASES_BLOCK.search(text)
    if block is None:
        raise VersionError(
            "AppStream metainfo at {} has no <releases> block; refusing to "
            "guess where the release entry belongs.".format(path)
        )

    body = block.group("body")
    existing, existing_attributes = next(
        (
            (tag, attributes)
            for tag, attributes in appstream_releases(text)
            if attributes.get("version") == version_name
        ),
        (None, {}),
    )
    # The date already in the file wins over today: it is the date that release
    # was published, and only an explicit --release-date may rewrite it.
    date = release_date or existing_attributes.get("date") or today_utc()
    if existing is not None:
        # Rewrite the attributes, not the element: an entry that wraps a
        # <description> keeps it, and the file stays well-formed XML.
        open_tag = _RELEASE_OPEN_TAG.match(existing).group(0)
        entry = _release_entry(version_name, date, self_closing=open_tag.endswith("/>"))
        new_body = body.replace(existing, existing.replace(open_tag, entry, 1), 1)
    else:
        entry = _release_entry(version_name, date)
        indent = _entry_indent(body, block.group("indent"))
        new_body = "{}{}\n{}".format(indent, entry, body)

    if new_body == body:
        return False
    start, end = block.span("body")
    path.write_text(text[:start] + new_body + text[end:])
    return True


def _entry_indent(body, block_indent):
    """Indent a new `<release/>` line to match the entries already there."""
    match = re.search(r"^([ \t]*)<release\b", body, flags=re.MULTILINE)
    if match is not None:
        return match.group(1)
    return block_indent + "  "


def _rel(repo, path):
    try:
        return str(path.relative_to(repo))
    except ValueError:
        return str(path)


def prepare(
    repo,
    raw_version,
    changelog_body,
    allow_overwrite,
    keep_changelog,
    release_date,
):
    """Run the full bump against `repo`. Returns (versionName, code, changed)."""
    if raw_version.startswith("v"):
        raise VersionError(
            'version must not start with "v" (got "{}"); pass the '
            "versionName, e.g. 0.1.0-alpha.37.".format(raw_version)
        )
    if "+" in raw_version:
        raise VersionError(
            'version must not contain "+versionCode" (got "{}"); the '
            "versionCode is computed.".format(raw_version)
        )
    version_name, version_code = version_from_tag(raw_version)
    if version_name != raw_version:
        # Belt-and-braces against a future regex regression: the canonical
        # name must round-trip the input.
        raise VersionError(
            "computed versionName {} does not match input {}.".format(
                version_name, raw_version
            )
        )

    pubspec = repo / "pubspec.yaml"
    app_info = repo / "lib" / "core" / "app_info.dart"
    changelog = (
        repo
        / "fastlane"
        / "metadata"
        / "android"
        / "en-US"
        / "changelogs"
        / "{}.txt".format(version_code)
    )
    fdroid = repo / "metadata" / "io.github.thezupzup.linthra.yml"
    metainfo = repo / "linux" / "packaging" / "io.github.thezupzup.linthra.metainfo.xml"

    changed = []
    if update_pubspec(pubspec, version_name, version_code):
        changed.append(_rel(repo, pubspec))
    if update_app_info(app_info, version_name):
        changed.append(_rel(repo, app_info))
    if create_changelog(
        changelog, version_name, changelog_body, allow_overwrite, keep_changelog
    ):
        changed.append(_rel(repo, changelog))
    if update_fdroid_metadata(fdroid, version_name, version_code):
        changed.append(_rel(repo, fdroid))
    if update_appstream_release(metainfo, version_name, release_date):
        changed.append(_rel(repo, metainfo))
    return version_name, version_code, changed


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Prepare a Linthra release version bump (pubspec, app_info, "
            "Fastlane changelog, F-Droid metadata, AppStream release entry). "
            "Does not tag or build."
        )
    )
    parser.add_argument(
        "version",
        help="Version name, e.g. 0.1.0-alpha.37 (no leading v, no +code).",
    )
    parser.add_argument(
        "--changelog",
        default="",
        help="Changelog body. Empty -> a safe maintenance default.",
    )
    parser.add_argument(
        "--force-changelog",
        action="store_true",
        help="Overwrite the Fastlane changelog if it already exists.",
    )
    parser.add_argument(
        "--keep-changelog",
        action="store_true",
        help=(
            "Leave an existing Fastlane changelog alone instead of failing. "
            "Use to repair other metadata without touching written notes."
        ),
    )
    parser.add_argument(
        "--release-date",
        default="",
        help=(
            "Release date for the AppStream entry, YYYY-MM-DD. Empty -> today (UTC)."
        ),
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root (default: directory containing this script's parent).",
    )
    args = parser.parse_args(argv)

    repo = args.repo_root.resolve()
    try:
        if args.keep_changelog and args.force_changelog:
            raise VersionError(
                "--keep-changelog and --force-changelog contradict each other; "
                "pass one."
            )
        if args.keep_changelog and args.changelog:
            raise VersionError(
                "--keep-changelog leaves the existing changelog alone, so "
                "--changelog would be ignored; pass one."
            )
        release_date = (
            parse_release_date(args.release_date) if args.release_date else None
        )
        version_name, version_code, changed = prepare(
            repo,
            args.version,
            args.changelog,
            args.force_changelog,
            args.keep_changelog,
            release_date,
        )
    except VersionError as err:
        print("ERROR: {}".format(err), file=sys.stderr)
        return 1

    full = "{}+{}".format(version_name, version_code)
    print("versionName:          {}".format(version_name))
    print("versionCode:          {}".format(version_code))
    print("full pubspec version: {}".format(full))
    print("tag (after merge):    v{}".format(version_name))
    print()
    if changed:
        print("Files updated:")
        for path in changed:
            print("  - {}".format(path))
    else:
        print("No files changed (already at {}).".format(full))
    print()
    print("Next safe command:")
    print("  ./scripts/release_preflight.sh v{}".format(version_name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
