#!/usr/bin/env python3
"""Make a new fixed network destination impossible to add quietly (#504).

Linthra talks to the servers its user configures. Those addresses are data,
typed in at run time, and nothing here tries to list them. What this check
lists is the other kind: every host name or IP address written into the code
Linthra ships, and what each one is for.

    python3 scripts/check_network_destinations.py
    python3 scripts/check_network_destinations.py --json

The reviewed inventory lives in `scripts/network_destinations.json`. Every
entry names a host, says whether Linthra's own code connects to it
(`app-request`), only hands it to the browser or mail client (`browser-link`),
or merely mentions it in a comment, hint text, licence header or XML namespace
(`reference`), and lists the files allowed to mention it. The check then reads
the shipped source tree and fails when:

  * a host or IP literal appears that the inventory does not list;
  * a listed host appears in a file its entry does not cover, so an address
    reviewed as a doc link in one file cannot quietly become a request in
    another;
  * an entry, or one of its paths, matches nothing any more, so a reason can
    never outlive what it explains.

**What is read.** The source that ends up in a shipped build: `lib/`, the
Android app module, the Linux runner and packaging metadata, the native
libraries and the vendored packages under `third_party/`, minus their tests,
examples and non-shipped platforms. Build-time sources (Gradle repositories,
the Flatpak manifests) are not runtime destinations and are pinned by their own
checks. Everything read is committed, so the check needs no network and no
toolchain.

**How it reads.** Three structured shapes, never a keyword list:

  * `scheme://host` for http, https, ws, wss, ftp and ftps. The host has to be
    a literal: `http://$host` or `https://${server}` is a user-configured
    address and is skipped by construction.
  * IPv4 literals outside a URL, such as `InternetAddress('203.0.113.9')`.
  * A host passed as a bare string to the few APIs that take one, such as
    `Uri.https('host', ...)` or `InetAddress.getByName("host")`.

Reserved names are recognised and never need an entry: example domains
(RFC 2606), the `.test`/`.example`/`.invalid`/`.localhost` TLDs, single-label
placeholders like `host`, loopback, and the RFC 5737 / RFC 3849 documentation
address ranges. A private LAN address is *not* reserved: a hard-coded
`192.168.1.1` could be a real destination on somebody's network, so it gets
reviewed like any other.

**What this does not prove.** It lists hosts written down in source. It cannot
see a host assembled from pieces, decoded from base64, or returned by a server
at run time (Plex's `*.plex.direct` addresses arrive that way, from plex.tv),
and it does not look inside pub packages that are not vendored. The compiled
app and its runtime traffic are separate parts of #504.
docs/network-destinations.md spells the boundary out.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INVENTORY = REPO_ROOT / "scripts" / "network_destinations.json"
DOC = "docs/network-destinations.md"

#: What Linthra does with a host. The order is the order the report prints.
KINDS = ("app-request", "browser-link", "reference")

#: When an `app-request` host is contacted. Only `app-request` entries carry a
#: trigger: a browser link or a comment is never contacted by Linthra at all.
TRIGGERS = ("user-action", "automatic-after-opt-in", "automatic")

#: Which builds carry the code that mentions the host.
BUILDS = ("all", "github-sponsor")

_ENTRY_KEYS = frozenset({"host", "kind", "builds", "paths", "rationale", "trigger"})
_OPTIONAL_KEYS = frozenset({"trigger"})

#: The shipped source tree, as (directory, required). A required root that is
#: missing fails the run: a check that passes because the tree it reads moved is
#: worse than no check.
SCAN_ROOTS: tuple[tuple[str, bool], ...] = (
    ("lib", True),
    ("android/app/src", True),
    ("linux/runner", True),
    ("linux/packaging", True),
    ("native", True),
    ("third_party", True),
)

#: File types that hold shipped source or shipped metadata. Build files
#: (CMakeLists.txt, *.gradle) and docs are deliberately not in the list: they
#: describe build-time downloads or nothing at all, and those are pinned by the
#: Flatpak source and toolchain checks instead.
SOURCE_SUFFIXES = frozenset(
    {
        ".c",
        ".cc",
        ".cpp",
        ".dart",
        ".desktop",
        ".h",
        ".hpp",
        ".java",
        ".kt",
        ".rs",
        ".xml",
    }
)

#: Directory names that never ship: tests, examples, and the vendored plugins'
#: Apple platforms (Linthra builds for Android and Linux only).
EXCLUDED_DIRS = frozenset(
    {"androidTest", "build", "darwin", "example", "ios", "macos", "test", "tests"}
)

_HOST_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
_URL = re.compile(
    r"\b(?P<scheme>https?|wss?|ftps?)://"
    r"(?P<host>\[[0-9A-Fa-f:.]+\]|" + _HOST_LABEL + r"(?:\." + _HOST_LABEL + r")*)",
    re.IGNORECASE,
)
_IPV4 = re.compile(r"(?<![\w.])(?P<host>\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")

#: APIs that take a host as a bare string rather than inside a URL. Best
#: effort, and deliberately few: each one is a shape that has turned up in
#: Dart, Kotlin or Java networking code. A literal containing `$` or `{` is an
#: interpolation, which means a configured address, and is skipped.
_HOST_ARGUMENTS = tuple(
    re.compile(pattern)
    for pattern in (
        r"\bUri\.(?:https?|wss?)\(\s*['\"](?P<host>[^'\"$\{\s]+?)(?::\d+)?['\"]",
        r"\bhost\s*:\s*['\"](?P<host>[^'\"$\{\s]+)['\"]",
        r"\.connect\(\s*['\"](?P<host>[^'\"$\{\s]+)['\"]",
        r"\blookup\(\s*['\"](?P<host>[^'\"$\{\s]+)['\"]",
        r"\bgetByName\(\s*\"(?P<host>[^\"$\{\s]+)\"",
        r"\bInetSocketAddress\(\s*\"(?P<host>[^\"$\{\s]+)\"",
    )
)

_RESERVED_DOMAINS = ("example.com", "example.net", "example.org")
_RESERVED_TLDS = ("example", "invalid", "localhost", "test")
_DOCUMENTATION_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in (
        "192.0.2.0/24",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "2001:db8::/32",
    )
)


class InventoryError(ValueError):
    """The inventory file is not something this check is willing to act on."""


class SourceError(ValueError):
    """The source tree is not in the shape the check expects."""


@dataclass(frozen=True)
class Entry:
    host: str
    kind: str
    builds: str
    paths: tuple[str, ...]
    rationale: str
    trigger: str | None
    index: int

    def covers(self, path: str) -> bool:
        return any(glob_matches(pattern, path) for pattern in self.paths)


@dataclass(frozen=True)
class Inventory:
    path: Path
    version: int
    kinds: dict[str, str]
    entries: tuple[Entry, ...]

    def for_host(self, host: str) -> tuple[Entry, ...]:
        return tuple(entry for entry in self.entries if entry.host == host)


@dataclass(frozen=True)
class Observation:
    """One host, as one line of one file spells it."""

    host: str
    source: str
    line: int
    shape: str

    @property
    def where(self) -> str:
        return f"{self.source}:{self.line}"


@dataclass
class Report:
    inventory: Inventory
    files_read: int = 0
    literals: int = 0
    roots: list[tuple[str, int]] = field(default_factory=list)
    reviewed: list[Observation] = field(default_factory=list)
    reserved: list[Observation] = field(default_factory=list)
    unreviewed_hosts: dict[str, list[Observation]] = field(default_factory=dict)
    outside_paths: dict[str, list[Observation]] = field(default_factory=dict)
    stale_paths: list[tuple[Entry, str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not (self.unreviewed_hosts or self.outside_paths or self.stale_paths)


# --------------------------------------------------------------------------
# Host classification
# --------------------------------------------------------------------------


def normalise_host(raw: str) -> str:
    host = raw.strip().lower().rstrip(".")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    return host


def parse_ip(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        return None


def reserved_reason(host: str) -> str | None:
    """Why a host can never be a real fixed destination, or None if it can."""
    address = parse_ip(host)
    if address is not None:
        if address.is_loopback:
            return "loopback address"
        if address.is_unspecified:
            return "unspecified address"
        if any(address in network for network in _DOCUMENTATION_NETWORKS):
            return "documentation address range (RFC 5737 / RFC 3849)"
        return None
    if "." not in host:
        return "single-label placeholder name"
    if any(host == name or host.endswith("." + name) for name in _RESERVED_DOMAINS):
        return "reserved example domain (RFC 2606)"
    if host.rsplit(".", 1)[-1] in _RESERVED_TLDS:
        return "reserved top-level domain (RFC 2606 / RFC 6761)"
    return None


def looks_like_host(value: str) -> bool:
    """A bare-string argument worth classifying: a dotted name or an IP."""
    return parse_ip(value) is not None or bool(
        re.fullmatch(_HOST_LABEL + r"(?:\." + _HOST_LABEL + r")+", value)
    )


# --------------------------------------------------------------------------
# Path globs
# --------------------------------------------------------------------------


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """`**` crosses directories, `*` and `?` stay inside one. Nothing else."""
    out = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out.append(r"(?:[^/]+/)*")
            index += 3
        elif pattern.startswith("**", index):
            out.append(r".*")
            index += 2
        elif pattern[index] == "*":
            out.append(r"[^/]*")
            index += 1
        elif pattern[index] == "?":
            out.append(r"[^/]")
            index += 1
        else:
            out.append(re.escape(pattern[index]))
            index += 1
    return re.compile("".join(out) + r"\Z")


def glob_matches(pattern: str, path: str) -> bool:
    return glob_to_regex(pattern).match(path) is not None


# --------------------------------------------------------------------------
# Inventory
# --------------------------------------------------------------------------


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise InventoryError(message)


def _text(value: object, what: str) -> str:
    _require(isinstance(value, str), f"{what} must be a string")
    assert isinstance(value, str)
    _require(value.strip() != "", f"{what} must not be empty")
    return value


def load_inventory(path: Path) -> Inventory:
    """Read and validate the inventory.

    Strict on purpose, for the same reason as the tracker policy: this file is
    the whole claim the check makes. An unknown key, a blank rationale, an
    unsorted list or a trigger on an entry Linthra never contacts is an error,
    not something to skip past.
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise InventoryError(f"inventory file not found: {path}") from error
    except json.JSONDecodeError as error:
        raise InventoryError(f"{path}: not valid JSON: {error}") from error

    _require(isinstance(raw, dict), f"{path}: top level must be an object")
    unknown_top = sorted(
        key
        for key in raw
        if not key.startswith("_") and key not in ("version", "kinds", "destinations")
    )
    _require(
        not unknown_top, f"{path}: unknown top-level key(s) {', '.join(unknown_top)}"
    )
    _require(
        raw.get("version") == 1,
        f"{path}: unsupported inventory version {raw.get('version')!r} "
        "(this checker understands version 1)",
    )

    kinds_raw = raw.get("kinds")
    _require(
        isinstance(kinds_raw, dict) and sorted(kinds_raw) == sorted(KINDS),
        f'{path}: "kinds" must describe exactly {", ".join(KINDS)}',
    )
    kinds = {kind: _text(kinds_raw[kind], f'{path}: kind "{kind}"') for kind in KINDS}

    destinations = raw.get("destinations")
    _require(isinstance(destinations, list), f'{path}: "destinations" must be a list')
    entries: list[Entry] = []
    for index, item in enumerate(destinations):
        where = f"{path}: destinations[{index}]"
        _require(isinstance(item, dict), f"{where} must be an object")
        unknown = sorted(set(item) - _ENTRY_KEYS)
        _require(not unknown, f"{where}: unknown key(s) {', '.join(unknown)}")
        missing = sorted(_ENTRY_KEYS - _OPTIONAL_KEYS - set(item))
        _require(not missing, f"{where}: missing key(s) {', '.join(missing)}")

        host = _text(item["host"], f"{where}: host")
        _require(
            host == normalise_host(host),
            f"{where}: host {host!r} must be written in lower case, without "
            "brackets or a trailing dot",
        )
        reason = reserved_reason(host)
        _require(
            reason is None,
            f"{where}: {host!r} is a {reason}; reserved names never need an entry",
        )
        kind = _text(item["kind"], f"{where}: kind")
        _require(
            kind in KINDS, f"{where}: unknown kind {kind!r} (known: {', '.join(KINDS)})"
        )
        builds = _text(item["builds"], f"{where}: builds")
        _require(
            builds in BUILDS,
            f"{where}: unknown builds {builds!r} (known: {', '.join(BUILDS)})",
        )
        trigger = item.get("trigger")
        if kind == "app-request":
            trigger = _text(trigger, f"{where}: trigger")
            _require(
                trigger in TRIGGERS,
                f"{where}: unknown trigger {trigger!r} (known: {', '.join(TRIGGERS)})",
            )
        else:
            _require(
                trigger is None,
                f'{where}: only an "app-request" entry has a trigger; Linthra '
                f"never contacts a {kind} host itself",
            )
        paths = item["paths"]
        _require(
            isinstance(paths, list) and paths != [],
            f'{where}: "paths" must be a non-empty list of files or globs',
        )
        checked = tuple(
            _text(value, f"{where}: paths[{position}]")
            for position, value in enumerate(paths)
        )
        _require(
            list(checked) == sorted(set(checked)),
            f'{where}: "paths" must be sorted and unique',
        )
        entries.append(
            Entry(
                host=host,
                kind=kind,
                builds=builds,
                paths=checked,
                rationale=_text(item["rationale"], f"{where}: rationale"),
                trigger=trigger,
                index=index,
            )
        )

    keys = [(entry.host, entry.kind) for entry in entries]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    _require(
        not duplicates,
        f"{path}: duplicate destinations: "
        + ", ".join(f"{host} ({kind})" for host, kind in duplicates),
    )
    _require(
        keys == sorted(keys),
        f"{path}: destinations must be sorted by (host, kind) so review diffs "
        "stay readable",
    )
    return Inventory(path=path, version=1, kinds=kinds, entries=tuple(entries))


# --------------------------------------------------------------------------
# Scanning
# --------------------------------------------------------------------------


def scan_text(text: str, source: str) -> list[Observation]:
    """Every host literal in one file, with its line number."""
    found: list[Observation] = []
    for number, line in enumerate(text.splitlines(), start=1):
        spans: list[tuple[int, int]] = []
        for match in _URL.finditer(line):
            spans.append(match.span())
            found.append(
                Observation(
                    normalise_host(match.group("host")),
                    source,
                    number,
                    f"{match.group('scheme').lower()} URL",
                )
            )
        for match in _IPV4.finditer(line):
            start, end = match.span()
            if any(low <= start and end <= high for low, high in spans):
                continue
            host = match.group("host")
            if parse_ip(host) is None:
                continue
            found.append(Observation(host, source, number, "IP literal"))
        for pattern in _HOST_ARGUMENTS:
            for match in pattern.finditer(line):
                host = normalise_host(match.group("host"))
                if looks_like_host(host):
                    found.append(Observation(host, source, number, "host argument"))
    return found


def shipped_files(root: Path) -> tuple[list[Path], list[tuple[str, int]]]:
    """The files the check reads, in a stable order, and a count per root."""
    files: list[Path] = []
    counts: list[tuple[str, int]] = []
    for relative, required in SCAN_ROOTS:
        directory = root / relative
        if not directory.is_dir():
            if required:
                raise SourceError(
                    f"{relative}/: expected this directory to exist. The check "
                    "reads it, so its absence is a hole in the check, not a pass."
                )
            continue
        found = sorted(
            path
            for path in directory.rglob("*")
            if path.is_file()
            and path.suffix in SOURCE_SUFFIXES
            and not EXCLUDED_DIRS.intersection(path.relative_to(root).parts[:-1])
        )
        if not found and required:
            raise SourceError(
                f"{relative}/: no source files found. An empty root is a hole "
                "in the check, not a pass."
            )
        files.extend(found)
        counts.append((relative, len(found)))
    return files, counts


def audit(root: Path, inventory: Inventory) -> Report:
    files, counts = shipped_files(root)
    report = Report(inventory=inventory, files_read=len(files), roots=counts)

    observations: list[Observation] = []
    for path in files:
        relative = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            raise SourceError(f"{relative}: not UTF-8 text ({error})") from error
        observations.extend(scan_text(text, relative))
    report.literals = len(observations)

    used: set[tuple[int, str]] = set()
    for observation in observations:
        if reserved_reason(observation.host) is not None:
            report.reserved.append(observation)
            continue
        entries = inventory.for_host(observation.host)
        if not entries:
            report.unreviewed_hosts.setdefault(observation.host, []).append(observation)
            continue
        covering = [entry for entry in entries if entry.covers(observation.source)]
        if not covering:
            report.outside_paths.setdefault(observation.host, []).append(observation)
            continue
        report.reviewed.append(observation)
        for entry in covering:
            for pattern in entry.paths:
                if glob_matches(pattern, observation.source):
                    used.add((entry.index, pattern))

    for entry in inventory.entries:
        for pattern in entry.paths:
            if (entry.index, pattern) not in used:
                report.stale_paths.append((entry, pattern))
    return report


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def _describe(entry: Entry) -> str:
    parts = [entry.kind]
    if entry.trigger:
        parts.append(entry.trigger)
    if entry.builds != "all":
        parts.append(f"{entry.builds} build only")
    return ", ".join(parts)


def automatic_hosts(inventory: Inventory) -> list[Entry]:
    """Entries Linthra contacts with no user action at all, in any build."""
    return [entry for entry in inventory.entries if entry.trigger == "automatic"]


def render_text(report: Report) -> str:
    inventory = report.inventory
    lines = [
        "Linthra fixed network destination audit (#504)",
        f"  inventory: {inventory.path.name}, {len(inventory.entries)} reviewed "
        "entries",
        "",
        "Inspected:",
    ]
    width = max(len(name) for name, _ in report.roots)
    for name, count in report.roots:
        lines.append(f"  {(name + '/').ljust(width + 1)}  {count} files")
    lines.append(
        f"  {report.literals} host literals found, {len(report.reserved)} of them "
        "reserved example or placeholder names"
    )
    lines.append("")

    for host in sorted(report.unreviewed_hosts):
        found = report.unreviewed_hosts[host]
        lines.append(f"FAIL: {host} is not in the reviewed inventory.")
        for observation in found:
            lines.append(f"      {observation.where}  ({observation.shape})")
        lines.append("")

    for host in sorted(report.outside_paths):
        found = report.outside_paths[host]
        kinds = ", ".join(_describe(entry) for entry in inventory.for_host(host))
        lines.append(f"FAIL: {host} is reviewed ({kinds}), but not in these files:")
        for observation in found:
            lines.append(f"      {observation.where}  ({observation.shape})")
        lines.append("")

    for entry, pattern in report.stale_paths:
        lines.append(
            f"FAIL: inventory entry {entry.index} ({entry.host}, {entry.kind}) "
            f"lists {pattern}, which no longer mentions it."
        )
        lines.append(
            "      Remove the path (or the whole entry): a reason may not outlive "
            "what it explains."
        )
        lines.append("")

    if report.ok:
        lines.append("Result: every fixed destination in shipped source is reviewed:")
        for kind in KINDS:
            entries = [entry for entry in inventory.entries if entry.kind == kind]
            lines.append(f"  {kind} ({len(entries)}): {inventory.kinds[kind]}")
            for entry in entries:
                detail = _describe(entry).removeprefix(kind).lstrip(", ")
                suffix = f"  [{detail}]" if detail else ""
                lines.append(f"    {entry.host}{suffix}")
        automatic = automatic_hosts(inventory)
        after_opt_in = [
            f"{entry.host} ({entry.builds} build)"
            if entry.builds != "all"
            else entry.host
            for entry in inventory.entries
            if entry.trigger == "automatic-after-opt-in"
        ]
        lines.append("")
        lines.append(
            "Contacted with no user action in any build: "
            + (", ".join(entry.host for entry in automatic) if automatic else "none")
        )
        lines.append(
            "Contacted on its own only after the user opted in: "
            + (", ".join(after_opt_in) if after_opt_in else "none")
        )
    else:
        lines.append("Every failure needs a human decision before this check can pass.")
        lines.append(f"How to review one: {DOC}")

    lines.append("")
    lines.append(
        "This lists hosts written into shipped source. It does not prove Linthra "
        "cannot contact"
    )
    lines.append(
        "anything else: runtime-built, server-supplied and obfuscated addresses "
        f"are out of its reach. See {DOC}."
    )
    return "\n".join(lines)


def render_json(report: Report) -> str:
    """Machine-readable twin of the text report. Key order is fixed."""
    inventory = report.inventory

    def files_for(entry: Entry) -> list[str]:
        return sorted(
            {
                observation.source
                for observation in report.reviewed
                if observation.host == entry.host and entry.covers(observation.source)
            }
        )

    return json.dumps(
        {
            "check": "network-destinations",
            "issue": 504,
            "inventory": {
                "file": inventory.path.name,
                "version": inventory.version,
                "entries": len(inventory.entries),
            },
            "inspected": [
                {"root": name, "files": count} for name, count in report.roots
            ],
            "destinations": [
                {
                    "host": entry.host,
                    "kind": entry.kind,
                    "trigger": entry.trigger,
                    "builds": entry.builds,
                    "rationale": entry.rationale,
                    "files": files_for(entry),
                }
                for entry in inventory.entries
            ],
            "automatic": [entry.host for entry in automatic_hosts(inventory)],
            "reserved_literals": len(report.reserved),
            "unreviewed": [
                {"host": host, "found_in": [o.where for o in found]}
                for host, found in sorted(report.unreviewed_hosts.items())
            ],
            "outside_reviewed_paths": [
                {"host": host, "found_in": [o.where for o in found]}
                for host, found in sorted(report.outside_paths.items())
            ],
            "stale_paths": [
                {"host": entry.host, "kind": entry.kind, "path": pattern}
                for entry, pattern in report.stale_paths
            ],
            "ok": report.ok,
        },
        indent=2,
        sort_keys=False,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check every fixed host in Linthra's shipped source against "
        "the reviewed network destination inventory (#504).",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="Repository root to inspect (default: this checkout).",
    )
    parser.add_argument(
        "--inventory",
        type=Path,
        default=DEFAULT_INVENTORY,
        help="Inventory file to apply (default: scripts/network_destinations.json).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the report as JSON instead of text.",
    )
    args = parser.parse_args(argv)

    try:
        inventory = load_inventory(args.inventory)
        report = audit(args.root, inventory)
    except (InventoryError, SourceError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print(render_json(report) if args.json else render_text(report))
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
