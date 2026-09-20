#!/usr/bin/env python3
"""Make a tracking dependency impossible to add quietly (#504).

Linthra's privacy policy says the app carries no advertising trackers and
reports nothing home. `PRIVACY.md` is a promise; this is the part of it a
stranger can re-run.

The check reads the dependency files Linthra actually ships from, turns each
into a list of *identifiers*, and compares those against a reviewed policy in
`scripts/tracker_policy.json`. A match fails the run and prints which file the
dependency came in through, which policy line matched it and why that line is
there.

    python3 scripts/check_tracker_dependencies.py
    python3 scripts/check_tracker_dependencies.py --json

What is read (all of it committed, so the check needs no network and no
toolchain):

  * `pubspec.lock` — the resolved Dart/Flutter graph, the closest thing to a
    bill of materials the app has.
  * `flatpak/generated/sources/pubspec.json` — the pub archives the Flatpak
    build actually downloads. Derived from the lockfile, but it is what the
    Linux package is built from, so it is read on its own terms.
  * `linux/flutter/generated_plugins.cmake` — the plugins that get linked into
    the Linux binary.
  * `android/**/*.gradle` and `*.gradle.kts` — Maven coordinates and Gradle
    plugin ids. Linthra declares no Maven dependencies of its own today; the
    point is the line that adds the first one.
  * `native/**/Cargo.lock` — the Rust core's resolved crates.

**Matching is exact, never substring.** A Dart entry has to equal a package
name; a Maven entry has to equal a whole `group:artifact` coordinate, or — with
`"match": "group"` — the coordinate's group exactly. That is the difference
between a check people keep and a check people switch off: `grep -i amplitude`
over a *music player's* dependency graph is a machine for generating false
alarms, and `com.google.firebaseui` is not Firebase.

**Scope note on pubspec.lock.** A lockfile records that a package is
`transitive`, not *whose* transitive dependency it is, so a package pulled in
only by a dev dependency cannot be told from one that ships. The check treats
the whole locked graph as in scope and fails closed, and prints the dependency
kind next to each finding so a reviewer can see the difference the file cannot.

**What a failure means.** It means a human has to decide, not that somebody did
something wrong. If the decision is that Linthra should ship the dependency
anyway, that goes in the `exceptions` list in the policy file, with a reason and
a link to where it was decided — and an exception that stops matching anything
fails the run too, so a reason cannot outlive the dependency it explains.

**What this does not prove.** It proves a narrow, dependency-level property: no
*named* tracking SDK is in the graph. It cannot see a tracker nobody has named
yet, and it says nothing about code Linthra writes itself — the app could send
anything anywhere with `package:http` alone. The rest of #504 (fixed network
destinations, the manifest surface, the release APK report, the runtime network
smoke test) is what covers those. docs/tracker-dependency-audit.md spells the
boundary out.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_POLICY = REPO_ROOT / "scripts" / "tracker_policy.json"
DOC = "docs/tracker-dependency-audit.md"

#: The ecosystems an identifier can belong to. An entry's ecosystem decides how
#: it is matched, so an unknown one is a policy error rather than a no-op.
ECOSYSTEMS = ("cargo", "dart", "gradle-plugin", "maven")

#: Match kinds. "group" is Maven-only: a Maven identifier is `group:artifact`,
#: and a group rule compares the group half for equality. There is deliberately
#: no prefix or regex kind — see the module docstring.
MATCHES = ("exact", "group")

_DENYLIST_KEYS = frozenset(
    {"ecosystem", "match", "identifier", "category", "vendor", "rationale"}
)
_EXCEPTION_KEYS = frozenset(
    {"ecosystem", "identifier", "sources", "reason", "reviewed_in"}
)


class PolicyError(ValueError):
    """The policy file is not something this check is willing to act on."""


class SourceError(ValueError):
    """A dependency file is missing, or is not in the shape it should be."""


@dataclass(frozen=True)
class PolicyEntry:
    ecosystem: str
    match: str
    identifier: str
    category: str
    vendor: str
    rationale: str
    index: int

    def describe(self) -> str:
        kind = "group" if self.match == "group" else "exact"
        return f'{self.ecosystem} {kind} policy entry "{self.identifier}"'

    def matches(self, ecosystem: str, identifier: str) -> bool:
        if ecosystem != self.ecosystem:
            return False
        if self.match == "exact":
            return identifier == self.identifier
        # Maven group rule: compare the group half, whole and exact, so
        # `com.google.firebase` does not swallow `com.google.firebaseui`.
        group, separator, _ = identifier.partition(":")
        return bool(separator) and group == self.identifier


@dataclass(frozen=True)
class ReviewedException:
    ecosystem: str
    identifier: str
    sources: tuple[str, ...]
    reason: str
    reviewed_in: str
    index: int

    def covers(self, ecosystem: str, identifier: str, source: str) -> bool:
        return (
            ecosystem == self.ecosystem
            and identifier == self.identifier
            and source in self.sources
        )


@dataclass(frozen=True)
class Policy:
    path: Path
    version: int
    categories: dict[str, str]
    entries: tuple[PolicyEntry, ...]
    exceptions: tuple[ReviewedException, ...]

    def entry_for(self, ecosystem: str, identifier: str) -> PolicyEntry | None:
        """The first entry that matches, in policy-file order.

        Order is the file's order, which the loader has already required to be
        sorted, so the same graph always produces the same report.
        """
        for entry in self.entries:
            if entry.matches(ecosystem, identifier):
                return entry
        return None


@dataclass(frozen=True)
class Observation:
    """One identifier, as one file spells it."""

    ecosystem: str
    identifier: str
    source: str
    detail: str = ""

    @property
    def where(self) -> str:
        return f"{self.source} ({self.detail})" if self.detail else self.source


@dataclass(frozen=True)
class Inspected:
    """One file that was read, and what came out of it."""

    source: str
    counts: tuple[tuple[str, int], ...]

    def describe(self) -> str:
        if not self.counts:
            return "nothing to match"
        return ", ".join(f"{count} {kind}" for kind, count in self.counts)


@dataclass(frozen=True)
class Finding:
    entry: PolicyEntry
    observations: tuple[Observation, ...]

    @property
    def identifier(self) -> str:
        return self.observations[0].identifier


@dataclass
class Report:
    policy: Policy
    inspected: list[Inspected] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    stale_exceptions: list[ReviewedException] = field(default_factory=list)
    applied_exceptions: list[ReviewedException] = field(default_factory=list)
    identifier_count: int = 0

    @property
    def ok(self) -> bool:
        return not self.findings and not self.stale_exceptions


# --------------------------------------------------------------------------
# Policy
# --------------------------------------------------------------------------


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise PolicyError(message)


def _text(value: object, what: str) -> str:
    _require(isinstance(value, str), f"{what} must be a string")
    assert isinstance(value, str)
    _require(value.strip() != "", f"{what} must not be empty")
    return value


def load_policy(path: Path) -> Policy:
    """Read and validate the policy file.

    Strict on purpose. This file is the whole claim the check makes, so an
    unknown key, a blank rationale or an out-of-order list is a failure rather
    than something to skip: a policy nobody can read is not a reviewed policy,
    and a silently ignored entry is a rule that quietly stopped applying.
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise PolicyError(f"policy file not found: {path}") from error
    except json.JSONDecodeError as error:
        raise PolicyError(f"{path}: not valid JSON: {error}") from error

    _require(isinstance(raw, dict), f"{path}: top level must be an object")
    _require(
        raw.get("version") == 1,
        f"{path}: unsupported policy version {raw.get('version')!r} "
        "(this checker understands version 1)",
    )

    categories_raw = raw.get("categories")
    _require(
        isinstance(categories_raw, dict) and categories_raw != {},
        f'{path}: "categories" must be a non-empty object',
    )
    categories = {
        _text(key, f"{path}: category name"): _text(
            value, f'{path}: category "{key}" title'
        )
        for key, value in categories_raw.items()
    }

    denylist_raw = raw.get("denylist")
    _require(isinstance(denylist_raw, list), f'{path}: "denylist" must be a list')
    entries: list[PolicyEntry] = []
    for index, item in enumerate(denylist_raw):
        where = f"{path}: denylist[{index}]"
        _require(isinstance(item, dict), f"{where} must be an object")
        unknown = sorted(set(item) - _DENYLIST_KEYS)
        _require(not unknown, f"{where}: unknown key(s) {', '.join(unknown)}")
        missing = sorted(_DENYLIST_KEYS - set(item))
        _require(not missing, f"{where}: missing key(s) {', '.join(missing)}")

        ecosystem = _text(item["ecosystem"], f"{where}: ecosystem")
        _require(
            ecosystem in ECOSYSTEMS,
            f"{where}: unknown ecosystem {ecosystem!r} "
            f"(known: {', '.join(ECOSYSTEMS)})",
        )
        match = _text(item["match"], f"{where}: match")
        _require(
            match in MATCHES,
            f"{where}: unknown match kind {match!r} (known: {', '.join(MATCHES)})",
        )
        identifier = _text(item["identifier"], f"{where}: identifier")
        _require(
            match != "group" or ecosystem == "maven",
            f'{where}: "group" matching is only defined for maven identifiers',
        )
        _require(
            match != "group" or ":" not in identifier,
            f"{where}: a group rule takes a bare group id, not a coordinate",
        )
        _require(
            not (
                ecosystem == "maven" and match == "exact" and identifier.count(":") != 1
            ),
            f"{where}: an exact maven rule takes a `group:artifact` coordinate",
        )
        category = _text(item["category"], f"{where}: category")
        _require(
            category in categories,
            f'{where}: category {category!r} is not declared in "categories"',
        )
        entries.append(
            PolicyEntry(
                ecosystem=ecosystem,
                match=match,
                identifier=identifier,
                category=category,
                vendor=_text(item["vendor"], f"{where}: vendor"),
                rationale=_text(item["rationale"], f"{where}: rationale"),
                index=index,
            )
        )

    _require(bool(entries), f"{path}: the denylist is empty")
    keys = [(entry.ecosystem, entry.identifier) for entry in entries]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    _require(
        not duplicates,
        f"{path}: duplicate denylist entries: "
        + ", ".join(f"{eco} {ident}" for eco, ident in duplicates),
    )
    _require(
        keys == sorted(keys),
        f"{path}: the denylist must be sorted by (ecosystem, identifier) so "
        "review diffs stay readable",
    )

    exceptions_raw = raw.get("exceptions")
    _require(isinstance(exceptions_raw, list), f'{path}: "exceptions" must be a list')
    exceptions: list[ReviewedException] = []
    for index, item in enumerate(exceptions_raw):
        where = f"{path}: exceptions[{index}]"
        _require(isinstance(item, dict), f"{where} must be an object")
        unknown = sorted(set(item) - _EXCEPTION_KEYS)
        _require(not unknown, f"{where}: unknown key(s) {', '.join(unknown)}")
        missing = sorted(_EXCEPTION_KEYS - set(item))
        _require(not missing, f"{where}: missing key(s) {', '.join(missing)}")
        ecosystem = _text(item["ecosystem"], f"{where}: ecosystem")
        _require(
            ecosystem in ECOSYSTEMS,
            f"{where}: unknown ecosystem {ecosystem!r}",
        )
        sources = item["sources"]
        _require(
            isinstance(sources, list) and sources != [],
            f'{where}: "sources" must be a non-empty list of paths the check prints',
        )
        exceptions.append(
            ReviewedException(
                ecosystem=ecosystem,
                identifier=_text(item["identifier"], f"{where}: identifier"),
                sources=tuple(
                    _text(source, f"{where}: sources[{position}]")
                    for position, source in enumerate(sources)
                ),
                reason=_text(item["reason"], f"{where}: reason"),
                reviewed_in=_text(item["reviewed_in"], f"{where}: reviewed_in"),
                index=index,
            )
        )

    return Policy(
        path=path,
        version=1,
        categories=categories,
        entries=tuple(entries),
        exceptions=tuple(exceptions),
    )


# --------------------------------------------------------------------------
# Parsers — one per file format, each returning identifiers, each fail-closed
# --------------------------------------------------------------------------

_LOCK_PACKAGE = re.compile(r"^  ([A-Za-z0-9_]+):\s*$")
_LOCK_FIELD = re.compile(r"^    ([A-Za-z0-9_]+):\s*(.*?)\s*$")
_PUB_ARCHIVE_DEST = re.compile(
    r"^\.pub-cache/hosted/pub\.dev/(?P<name>[a-z0-9_]+)-(?P<version>\d[^/]*)$"
)
_MAVEN_COORDINATE = re.compile(
    r"^(?P<group>[A-Za-z0-9_.\-]+):(?P<artifact>[A-Za-z0-9_.\-]+)(?::[^:\s]*)?$"
)
_GRADLE_PLUGIN_ID = re.compile(r"\bid\b\s*\(?\s*(['\"])(?P<id>[^'\"]+)\1")
_GRADLE_APPLY_PLUGIN = re.compile(r"\bapply\s+plugin\s*:\s*(['\"])(?P<id>[^'\"]+)\1")
_CMAKE_PLUGIN_LIST = re.compile(
    r"list\(APPEND\s+FLUTTER_(?:FFI_)?PLUGIN_LIST\s*(?P<body>[^)]*)\)"
)


def parse_pubspec_lock(text: str, source: str = "pubspec.lock") -> list[Observation]:
    """Package name and dependency kind for every entry under `packages:`.

    Hand-rolled rather than YAML-parsed so the check needs no PyYAML, and
    narrow rather than clever: only the two-space keys directly under
    `packages:` are packages, which keeps the `sdks:` block at the bottom of the
    file (`dart:`, `flutter:`) out of the results.
    """
    packages: dict[str, dict[str, str]] = {}
    current: str | None = None
    in_packages = False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            in_packages = line.rstrip() == "packages:"
            current = None
            continue
        if not in_packages:
            continue
        package = _LOCK_PACKAGE.match(line)
        if package:
            current = package.group(1)
            packages.setdefault(current, {})
            continue
        field_match = _LOCK_FIELD.match(line)
        if field_match and current is not None:
            packages[current][field_match.group(1)] = field_match.group(2).strip('"')

    if not packages:
        raise SourceError(f"{source}: no packages found under `packages:`")

    observations = []
    for name in sorted(packages):
        kind = packages[name].get("dependency")
        if not kind:
            # Fail closed: a package whose kind cannot be read is a package
            # whose provenance cannot be reported, not one to wave through.
            raise SourceError(f"{source}: package {name!r} has no `dependency:` kind")
        observations.append(
            Observation("dart", name, source, detail=kind.replace('"', ""))
        )
    return observations


def parse_flatpak_pub_sources(text: str, source: str) -> list[Observation]:
    """Pub package names from the Flatpak source manifest's archive entries."""
    try:
        entries = json.loads(text)
    except json.JSONDecodeError as error:
        raise SourceError(f"{source}: not valid JSON: {error}") from error
    if not isinstance(entries, list):
        raise SourceError(f"{source}: expected a list of sources")

    names: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("type") != "archive":
            continue
        dest = entry.get("dest")
        if not isinstance(dest, str):
            continue
        match = _PUB_ARCHIVE_DEST.match(dest)
        if match:
            names.add(match.group("name"))
    if not names:
        raise SourceError(f"{source}: no pub.dev archives found")
    return [
        Observation("dart", name, source, "flatpak archive") for name in sorted(names)
    ]


def parse_generated_plugins(text: str, source: str) -> list[Observation]:
    """Plugin package names from a Flutter `generated_plugins.cmake`."""
    names: set[str] = set()
    found_list = False
    for block in _CMAKE_PLUGIN_LIST.finditer(text):
        found_list = True
        for token in block.group("body").split():
            if re.fullmatch(r"[A-Za-z0-9_]+", token):
                names.add(token)
    if not found_list:
        raise SourceError(f"{source}: no FLUTTER_PLUGIN_LIST block found")
    return [
        Observation("dart", name, source, "linked plugin") for name in sorted(names)
    ]


def strip_gradle_comments(text: str) -> tuple[str, list[str]]:
    """Remove Gradle comments, and collect the string literals left behind.

    String-aware, because a Gradle file is full of `https://` inside quotes and
    a line-based comment stripper would eat half of every URL. Triple-quoted
    Groovy strings are handled so a docstring-style block cannot leave the
    scanner stuck inside a string for the rest of the file.
    """
    out: list[str] = []
    literals: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char in "'\"":
            quote = (
                text[index : index + 3]
                if text[index : index + 3] in ("'''", '"""')
                else char
            )
            index += len(quote)
            start = index
            while index < length:
                if text[index] == "\\":
                    index += 2
                    continue
                if text.startswith(quote, index):
                    break
                index += 1
            literals.append(text[start:index])
            out.append(quote + text[start:index] + quote)
            index += len(quote)
            continue
        if char == "/" and text.startswith("//", index):
            while index < length and text[index] != "\n":
                index += 1
            continue
        if char == "/" and text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = length if end == -1 else end + 2
            continue
        out.append(char)
        index += 1
    return "".join(out), literals


def parse_gradle(text: str, source: str) -> list[Observation]:
    """Maven coordinates and Gradle plugin ids declared in a Gradle file."""
    stripped, literals = strip_gradle_comments(text)

    coordinates: set[str] = set()
    for literal in literals:
        match = _MAVEN_COORDINATE.match(literal)
        if match:
            coordinates.add(f"{match.group('group')}:{match.group('artifact')}")

    plugins: set[str] = set()
    for pattern in (_GRADLE_PLUGIN_ID, _GRADLE_APPLY_PLUGIN):
        for match in pattern.finditer(stripped):
            plugins.add(match.group("id"))

    return [
        Observation("maven", name, source, "maven coordinate")
        for name in sorted(coordinates)
    ] + [
        Observation("gradle-plugin", name, source, "gradle plugin")
        for name in sorted(plugins)
    ]


def parse_cargo_lock(text: str, source: str) -> list[Observation]:
    """Crate names from a Cargo lockfile."""
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise SourceError(f"{source}: not valid TOML: {error}") from error
    packages = data.get("package", [])
    if not isinstance(packages, list):
        raise SourceError(f"{source}: `package` is not a list of tables")
    names = set()
    for package in packages:
        name = package.get("name") if isinstance(package, dict) else None
        if not isinstance(name, str):
            raise SourceError(f"{source}: a [[package]] entry has no name")
        names.add(name)
    return [Observation("cargo", name, source, "crate") for name in sorted(names)]


# --------------------------------------------------------------------------
# Collection
# --------------------------------------------------------------------------

#: The files the check reads, in report order. Every one of them is required:
#: a check that passes because the file it reads was deleted is worse than no
#: check, so a missing path — or a glob that matches nothing — is a failure.
SOURCES: tuple[tuple[str, str, object], ...] = (
    ("pubspec.lock", "file", parse_pubspec_lock),
    ("flatpak/generated/sources/pubspec.json", "file", parse_flatpak_pub_sources),
    ("linux/flutter/generated_plugins.cmake", "file", parse_generated_plugins),
    ("android/**/*.gradle", "glob", parse_gradle),
    ("android/**/*.gradle.kts", "glob-optional", parse_gradle),
    ("native/**/Cargo.lock", "glob", parse_cargo_lock),
)

_KINDS = {
    "dart": ("dart package", "dart packages"),
    "maven": ("maven coordinate", "maven coordinates"),
    "gradle-plugin": ("gradle plugin id", "gradle plugin ids"),
    "cargo": ("crate", "crates"),
}


def collect(root: Path) -> tuple[list[Observation], list[Inspected]]:
    """Read every source file and return what was seen, in report order."""
    observations: list[Observation] = []
    inspected: list[Inspected] = []

    for pattern, kind, parser in SOURCES:
        if kind == "file":
            paths = [root / pattern]
            if not paths[0].is_file():
                raise SourceError(
                    f"{pattern}: expected this file to exist. The audit reads it, "
                    "so its absence is a hole in the audit, not a pass."
                )
        else:
            paths = sorted(root.glob(pattern))
            if not paths and kind == "glob":
                raise SourceError(
                    f"{pattern}: matched no files. The audit reads them, so an "
                    "empty match is a hole in the audit, not a pass."
                )

        for path in paths:
            relative = path.relative_to(root).as_posix()
            found = parser(path.read_text(encoding="utf-8"), relative)
            observations.extend(found)
            counts = []
            for ecosystem, (singular, plural) in _KINDS.items():
                total = sum(1 for o in found if o.ecosystem == ecosystem)
                if total:
                    counts.append((singular if total == 1 else plural, total))
            inspected.append(Inspected(relative, tuple(counts)))

    return observations, inspected


def audit(root: Path, policy: Policy) -> Report:
    """Run the policy over the collected identifiers."""
    observations, inspected = collect(root)
    report = Report(
        policy=policy, inspected=inspected, identifier_count=len(observations)
    )

    # Keyed by (policy entry, identifier) rather than by policy entry alone: a
    # Maven group rule matches several coordinates, and collapsing them would
    # print one of their names and silently drop the rest.
    matched: dict[tuple[int, str], list[Observation]] = {}
    for observation in observations:
        entry = policy.entry_for(observation.ecosystem, observation.identifier)
        if entry is None:
            continue
        excused = next(
            (
                exception
                for exception in policy.exceptions
                if exception.covers(
                    observation.ecosystem, observation.identifier, observation.source
                )
            ),
            None,
        )
        if excused is not None:
            if excused not in report.applied_exceptions:
                report.applied_exceptions.append(excused)
            continue
        matched.setdefault((entry.index, observation.identifier), []).append(
            observation
        )

    for index, identifier in sorted(matched):
        found = sorted(matched[(index, identifier)], key=lambda o: o.source)
        report.findings.append(
            Finding(entry=policy.entries[index], observations=tuple(found))
        )

    report.stale_exceptions = [
        exception
        for exception in policy.exceptions
        if exception not in report.applied_exceptions
    ]
    return report


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def render_text(report: Report) -> str:
    policy = report.policy
    lines = [
        "Linthra tracker-dependency audit (#504)",
        f"  policy: {policy.path.name} — {len(policy.entries)} reviewed entries",
        "",
        "Inspected:",
    ]
    width = max(len(item.source) for item in report.inspected)
    for item in report.inspected:
        lines.append(f"  {item.source.ljust(width)}  {item.describe()}")
    lines.append(f"  {report.identifier_count} identifiers in total")
    lines.append("")

    if report.findings:
        total = sum(len(finding.observations) for finding in report.findings)
        lines.append(
            f"FAIL: {len(report.findings)} policy "
            f"{'entry matches' if len(report.findings) == 1 else 'entries match'} "
            f"Linthra's dependency graph ({total} "
            f"{'occurrence' if total == 1 else 'occurrences'})."
        )
        lines.append("")
        for finding in report.findings:
            title = policy.categories[finding.entry.category]
            lines.append(f"  {finding.identifier}  [{title}]")
            lines.append(f"      ecosystem: {finding.entry.ecosystem}")
            lines.append(f"      vendor:    {finding.entry.vendor}")
            lines.append(f"      matched:   {finding.entry.describe()}")
            lines.append(f"      found in:  {finding.observations[0].where}")
            for observation in finding.observations[1:]:
                lines.append(f"                 {observation.where}")
            lines.append(f"      why it is flagged: {finding.entry.rationale}")
            lines.append("")

    for exception in report.stale_exceptions:
        lines.append(
            f"FAIL: reviewed exception {exception.index} "
            f"({exception.ecosystem} {exception.identifier}) matches nothing."
        )
        lines.append(
            "      The dependency it excuses is gone. Delete the exception: a "
            "reason may not outlive what it explains."
        )
        lines.append("")

    if report.ok:
        lines.append("Result — no reviewed tracker-dependency matched:")
        for key in sorted(policy.categories):
            lines.append(f"  {policy.categories[key]}: none")
        if report.applied_exceptions:
            lines.append("")
            lines.append("Reviewed exceptions in force:")
            for exception in report.applied_exceptions:
                lines.append(
                    f"  {exception.ecosystem} {exception.identifier} "
                    f"— {exception.reason} ({exception.reviewed_in})"
                )
    else:
        lines.append("Every match needs a human decision before this check can pass.")
        lines.append(f"How to review one: {DOC}")
        lines.append(
            "If Linthra should ship it anyway, record the decision in the "
            f'"exceptions" list in {policy.path.name}.'
        )

    lines.append("")
    lines.append(
        "This compares dependency identifiers against a reviewed list. It does "
        "not prove Linthra cannot"
    )
    lines.append(
        f"track users, and it says nothing about Linthra's own code. See {DOC}."
    )
    return "\n".join(lines)


def render_json(report: Report) -> str:
    """Machine-readable twin of the text report. Key order is fixed."""
    return json.dumps(
        {
            "check": "tracker-dependencies",
            "issue": 504,
            "policy": {
                "file": report.policy.path.name,
                "version": report.policy.version,
                "entries": len(report.policy.entries),
            },
            "inspected": [
                {"source": item.source, "identifiers": dict(item.counts)}
                for item in report.inspected
            ],
            "identifiers": report.identifier_count,
            "categories": {
                key: sum(
                    1 for finding in report.findings if finding.entry.category == key
                )
                for key in sorted(report.policy.categories)
            },
            "findings": [
                {
                    "identifier": finding.identifier,
                    "ecosystem": finding.entry.ecosystem,
                    "category": finding.entry.category,
                    "vendor": finding.entry.vendor,
                    "matched": finding.entry.describe(),
                    "rationale": finding.entry.rationale,
                    "found_in": [
                        {"source": o.source, "detail": o.detail}
                        for o in finding.observations
                    ],
                }
                for finding in report.findings
            ],
            "stale_exceptions": [
                {"ecosystem": e.ecosystem, "identifier": e.identifier}
                for e in report.stale_exceptions
            ],
            "ok": report.ok,
        },
        indent=2,
        sort_keys=False,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check Linthra's shipped dependencies against the reviewed "
        "tracker policy (#504).",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="Repository root to inspect (default: this checkout).",
    )
    parser.add_argument(
        "--policy",
        type=Path,
        default=DEFAULT_POLICY,
        help="Policy file to apply (default: scripts/tracker_policy.json).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the report as JSON instead of text.",
    )
    args = parser.parse_args(argv)

    try:
        policy = load_policy(args.policy)
        report = audit(args.root, policy)
    except (PolicyError, SourceError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print(render_json(report) if args.json else render_text(report))
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
