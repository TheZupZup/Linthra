#!/usr/bin/env python3
"""prepare_release_bump.py — prepare a Linthra release version bump.

Updates every file that must agree on the release version:

  * pubspec.yaml                                            (`version:` line)
  * lib/core/app_info.dart                                  (`_devVersionName`)
  * fastlane/metadata/android/en-US/changelogs/<code>.txt   (Fastlane changelog)
  * metadata/io.github.thezupzup.linthra.yml                (F-Droid CurrentVersion/Code)

Then prints the next safe command — the release preflight — so a contributor
running the script locally sees the same workflow the GitHub Action runs.

This script does NOT create a git tag, push anything, build the APK/AAB, or
publish a GitHub Release. Those steps still happen manually after the
generated PR is merged. See docs/release-process.md.

Usage:

    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37
    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37 \\
        --changelog "Linthra 0.1.0-alpha.37 — fixed X."
    python3 scripts/prepare_release_bump.py 0.1.0-alpha.37 --force-changelog

The version-to-versionCode encoding mirrors tool/version_from_tag.dart and
scripts/release_preflight.sh; see docs/release-process.md §1.
"""

from __future__ import annotations

import argparse
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
            'Minor version {} in tag "{}" exceeds the supported range '
            "(0..{}).".format(minor, tag, _MAX_MINOR)
        )
    if patch > _MAX_PATCH:
        raise VersionError(
            'Patch version {} in tag "{}" exceeds the supported range '
            "(0..{}).".format(patch, tag, _MAX_PATCH)
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

    code = (
        major * _MAJOR_WEIGHT
        + minor * _MINOR_WEIGHT
        + patch * _PATCH_WEIGHT
        + rank
    )
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
        raise VersionError(
            "pubspec.yaml at {} has no `version:` line.".format(path)
        )
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
            "lib/core/app_info.dart not found at {}; refusing to guess.".format(
                path
            )
        )
    text = path.read_text()
    pattern = re.compile(
        r"(static\s+const\s+String\s+_devVersionName\s*=\s*)'[^']*'"
    )
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


def create_changelog(path, version_name, body, allow_overwrite):
    """Write the Fastlane changelog at `path`.

    Returns True if the file was created or changed. Raises if the file already
    exists with different content and `allow_overwrite` is False — the workflow
    must opt into clobbering an existing changelog.
    """
    raw = body if body else default_changelog(version_name)
    content = raw.rstrip() + "\n"
    if path.exists():
        existing = path.read_text()
        if existing == content:
            return False
        if not allow_overwrite:
            raise VersionError(
                "Changelog already exists at {} and would be modified. "
                "Pass --force-changelog to overwrite it.".format(path)
            )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return True


def update_fdroid_metadata(path, version_name, version_code):
    """Update CurrentVersion/CurrentVersionCode in the F-Droid metadata YAML.

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
    new_text = re.sub(
        r"^CurrentVersion:.*$",
        "CurrentVersion: {}".format(version_name),
        text,
        count=1,
        flags=re.MULTILINE,
    )
    new_text = re.sub(
        r"^CurrentVersionCode:.*$",
        "CurrentVersionCode: {}".format(version_code),
        new_text,
        count=1,
        flags=re.MULTILINE,
    )
    if new_text == text:
        return False
    path.write_text(new_text)
    return True


def _rel(repo, path):
    try:
        return str(path.relative_to(repo))
    except ValueError:
        return str(path)


def prepare(repo, raw_version, changelog_body, allow_overwrite):
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

    changed = []
    if update_pubspec(pubspec, version_name, version_code):
        changed.append(_rel(repo, pubspec))
    if update_app_info(app_info, version_name):
        changed.append(_rel(repo, app_info))
    if create_changelog(changelog, version_name, changelog_body, allow_overwrite):
        changed.append(_rel(repo, changelog))
    if update_fdroid_metadata(fdroid, version_name, version_code):
        changed.append(_rel(repo, fdroid))
    return version_name, version_code, changed


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Prepare a Linthra release version bump (pubspec, app_info, "
            "Fastlane changelog, F-Droid metadata). Does not tag or build."
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
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root (default: directory containing this script's parent).",
    )
    args = parser.parse_args(argv)

    repo = args.repo_root.resolve()
    try:
        version_name, version_code, changed = prepare(
            repo,
            args.version,
            args.changelog,
            args.force_changelog,
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
