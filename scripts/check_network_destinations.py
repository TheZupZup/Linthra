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

**How it reads.** Four structured shapes, never a keyword list:

  * `scheme://host` for http, https, ws, wss, ftp and ftps, plus the network
    schemes the Linux player accepts (rtp, rtsp, rtmp, udp, tcp, tls, mms,
    srt), including URLs with `user:pass@` in front of the host. The whole host has to be a
    literal: `http://$host`, `https://${server}` or `https://api.${domain}` is
    a user-configured address and is skipped by construction.
  * IP literals outside a URL, such as `InternetAddress('203.0.113.9')` or an
    IPv6 address (which has to parse as one, and outside a string literal
    also contain a digit).
  * Mail recipients: a `mailto:` link or an address written as a whole string
    literal. The domain is what gets reviewed.
  * A host passed as a bare string to the common APIs that take one, such as
    `Uri.https('host', ...)`, `InetAddress.getByName("host")`,
    `getaddrinfo("host", ...)` or `TcpStream::connect("host:443")`, matched
    across line breaks.

Reserved names are recognised and never need an entry: names under the
example domains (RFC 2606; the domains themselves resolve, so they don't), the `.test`/`.example`/`.invalid`/`.localhost` TLDs, `localhost`,
loopback, and the RFC 5737 / RFC 3849 documentation address ranges. A private
LAN address is *not* reserved: a hard-coded `192.168.1.1` could be a real
destination on somebody's network, so it gets reviewed like any other. Nor is a
dotless name like `metrics`: it can resolve through a search domain.

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

#: Files Flutter or Android package as assets are read whatever their type
#: (JSON, text, config), because an asset can hold a URL the app loads at run
#: time. Binary files (images, audio) are skipped. Flutter assets are the ones
#: pubspec.yaml declares; Android ones live under a source set's `assets/` or
#: `res/raw*/`.
ASSET_ROOT_NAME = "declared assets"

#: Asset types that are binary by nature and are skipped. Any other asset has
#: to decode as text (UTF-8, or UTF-16/32 with a byte-order mark, or BOM-less
#: UTF-16), or the check fails: an asset it cannot read is a hole, not a pass.
#: A new binary format goes on this list in a reviewed change.
BINARY_ASSET_SUFFIXES = frozenset(
    {
        ".aac",
        ".bin",
        ".bmp",
        ".flac",
        ".gif",
        ".gz",
        ".ico",
        ".jpeg",
        ".jpg",
        ".m4a",
        ".mp3",
        ".mp4",
        ".ogg",
        ".opus",
        ".otf",
        ".png",
        ".ttf",
        ".wav",
        ".webm",
        ".webp",
        ".woff",
        ".woff2",
        ".xz",
        ".zip",
    }
)

#: Build files that put values into the shipped app (Gradle's
#: `buildConfigField`, `resValue` and manifest placeholders, Gradle
#: properties) for the app module and the vendored Android modules. Globs from
#: the repository root; they may match nothing.
BUILD_INPUT_GLOBS: tuple[str, ...] = (
    "android/app/*.gradle",
    "android/app/*.gradle.kts",
    "android/gradle.properties",
    "third_party/*/build.gradle",
    "third_party/*/android/build.gradle",
)
BUILD_INPUT_ROOT_NAME = "build inputs"

#: Directory names that never ship: tests, examples, and the vendored plugins'
#: Apple platforms (Linthra builds for Android and Linux only).
EXCLUDED_DIRS = frozenset(
    {"androidTest", "build", "darwin", "example", "ios", "macos", "test", "tests"}
)

#: One label of a host name. Underscores are not valid in DNS host names, but
#: private resolvers answer for them (`api_v2.internal`), so they count.
_HOST_LABEL = r"[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?"
_URL = re.compile(
    # Web, WebSocket and FTP, plus the network schemes the Linux player (mpv)
    # accepts, so a fixed stream handed straight to the player is seen too.
    r"\b(?P<scheme>https?|wss?|ftps?|rtmps?|rtsp|rtp|udp|tcp|tls|mms|srt)://"
    # Optional user information (`user:pass@`). Without it, the user name would
    # be read as the host and the real destination after the `@` never seen.
    r"(?:[^\s/?#@'\"<>]*@)?"
    r"(?P<host>\[[0-9A-Fa-f:.]+\]|" + _HOST_LABEL + r"(?:\." + _HOST_LABEL + r")*)"
    # The host has to end where the authority ends. `https://api.${domain}` or
    # `https://cdn-$region.example.org` is a configured address, not a URL for
    # the host `api` or `cdn`, and in `ftp://anonymous@$server` or
    # `https://user:pass@${host}` the name before the `@` is not a host at all.
    # A trailing full stop in prose still ends a host.
    r"(?![\w$\{@-])(?!\.[\w$\{])(?![:][^\s/?#@'\"<>]*@)",
    re.IGNORECASE,
)
_IPV4 = re.compile(r"(?<![\w.])(?P<host>\d{1,3}(?:\.\d{1,3}){3})(?![\w.])")
#: IPv6 literals outside a URL, bracketed or not. Candidates are only kept when
#: they parse as an IPv6 address, which rules out times, MAC addresses and
#: `a::b` style paths.
_IPV6 = re.compile(
    r"(?<![\w:.])\[?(?P<host>[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7})\]?(?![\w:.])"
)
#: An IPv6 literal that is the whole of a string literal, optionally bracketed
#: and with a port: `'dead:beef::cafe'` or `"[face::feed]:443"`.
_QUOTED_IPV6 = re.compile(
    r"['\"]\[?(?P<host>[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7})\]?(?::\d+)?['\"]"
)
#: Mail recipients: a `mailto:` link, or an address written as a whole string
#: literal (`'support@example.org'`). The domain is what gets reviewed.
_MAIL = re.compile(
    # A mailto: link, whose domain may be a single label (`ops@metrics`).
    r"\bmailto:[^@\s'\"<>?]+@(?P<host>" + _HOST_LABEL + r"(?:\." + _HOST_LABEL + r")*)"
    # Or an address written as a whole string literal. A dot is required here,
    # because `'name@version'` style strings are common outside mail.
    r"|['\"][A-Za-z0-9._%+-]+@(?P<literal_host>"
    + _HOST_LABEL
    + r"(?:\."
    + _HOST_LABEL
    + r")+)"
)

#: A string literal holding a host, optionally with a `:port`. A literal
#: containing `$` or `{` is an interpolation, which means a configured address,
#: and never matches.
#: Raw literals count too: Dart `r'host'`, Rust `r"host"` / `r#"host"#`, C++
#: `R"(host)"`.
_HOST_LITERAL = r"(?:r#*|R)?['\"]\(?(?P<host>[^'\"$\{\s:()]+)(?::\d+)?\)?['\"]#*"

#: APIs that take a host as a bare string rather than inside a URL, one or two
#: per language the scan reads (Dart, Kotlin/Java, C/C++, Rust). Best effort,
#: not a parser: see docs/network-destinations.md for what it cannot see.
#:
#: The flag says whether a dotless name counts. For the networking calls it
#: does, because `metrics` can resolve through a search domain. For a `host:`
#: named argument or a `lookup(...)` call it does not, because those shapes are
#: too common outside networking code to read a bare word as a destination.
_HOST_ARGUMENTS: tuple[tuple[re.Pattern[str], bool], ...] = tuple(
    (re.compile(pattern), single_label)
    for pattern, single_label in (
        (r"\bUri\.(?:https?|wss?)\(\s*" + _HOST_LITERAL, True),
        (r"\bhost\s*:\s*" + _HOST_LITERAL, False),
        # Dart Socket.connect / WebSocket.connect, Rust TcpStream::connect.
        (r"(?:\.|::)connect\(\s*" + _HOST_LITERAL, True),
        # `lookup` is also an ordinary map/table method, so only a dotted name
        # or an IP counts there.
        (r"\blookup\(\s*" + _HOST_LITERAL, False),
        # Kotlin/Java.
        (r"\bget(?:All)?ByName\(\s*" + _HOST_LITERAL, True),
        (r"\b(?:InetSocketAddress|Socket|SSLSocket)\(\s*" + _HOST_LITERAL, True),
        # C/C++.
        (r"\b(?:getaddrinfo|gethostbyname2?)\(\s*" + _HOST_LITERAL, True),
        # Rust: "host:443".to_socket_addrs()
        (_HOST_LITERAL + r"\s*\.to_socket_addrs\(", True),
        # Dart HttpClient's host-and-port methods: get/post/put/delete/patch/
        # head(host, port, path) and open(method, host, port, path). Scoped to
        # the three-argument shape so `map.get('key')` never matches.
        (
            r"\.(?:get|post|put|delete|patch|head)\(\s*"
            + _HOST_LITERAL
            + r"\s*,\s*[^,()]+,\s*['\"]",
            True,
        ),
        (r"\.open\(\s*['\"][A-Za-z]+['\"]\s*,\s*" + _HOST_LITERAL, True),
    )
)

#: Names *under* these are reserved. The three domains themselves resolve and
#: answer connections, so `https://example.com/collect` needs an entry.
_RESERVED_DOMAINS = ("example.com", "example.net", "example.org")
_RESERVED_TLDS = ("example", "invalid", "localhost", "test")
_RESERVED_NAMES = ("localhost",)
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
    if host in _RESERVED_NAMES:
        return "loopback name"
    if any(host.endswith("." + name) for name in _RESERVED_DOMAINS):
        return "name under a reserved example domain (RFC 2606)"
    if host.rsplit(".", 1)[-1] in _RESERVED_TLDS:
        return "reserved top-level domain (RFC 2606 / RFC 6761)"
    return None


def looks_like_host(value: str, single_label: bool = True) -> bool:
    """A bare-string argument worth classifying: a host name or an IP."""
    repeat = "*" if single_label else "+"
    return parse_ip(value) is not None or bool(
        re.fullmatch(_HOST_LABEL + r"(?:\." + _HOST_LABEL + r")" + repeat, value)
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
        quoted = {
            normalise_host(match.group("host")) for match in _QUOTED_IPV6.finditer(line)
        }
        for pattern in (_IPV4, _IPV6):
            for match in pattern.finditer(line):
                start, end = match.span()
                if any(low <= start and end <= high for low, high in spans):
                    continue
                host = normalise_host(match.group("host"))
                if parse_ip(host) is None:
                    continue
                if (
                    pattern is _IPV6
                    and host not in quoted
                    and not any(char.isdigit() for char in host)
                ):
                    # Outside a string literal, `a::b` and `ff::` are code paths
                    # that happen to parse as IPv6. A letter-only address still
                    # counts when it is written as a string, like
                    # `'dead:beef::cafe'`.
                    continue
                found.append(Observation(host, source, number, "IP literal"))
        for match in _MAIL.finditer(line):
            literal = match.group("literal_host")
            if literal and literal.rsplit(".", 1)[-1].isdigit():
                # `'name@1.2'` is a version, not an address: a real top-level
                # domain always has a letter in it.
                continue
            found.append(
                Observation(
                    normalise_host(match.group("host") or match.group("literal_host")),
                    source,
                    number,
                    "mail recipient",
                )
            )
    # Calls are matched against the whole file rather than line by line, so a
    # host written on the line after `Socket.connect(` is still seen.
    for pattern, single_label in _HOST_ARGUMENTS:
        for match in pattern.finditer(text):
            host = normalise_host(match.group("host"))
            if looks_like_host(host, single_label):
                number = text.count("\n", 0, match.start("host")) + 1
                found.append(Observation(host, source, number, "host argument"))
    # Report in file order. The sort is stable, so literals on the same line
    # keep the order they were found in.
    found.sort(key=lambda observation: observation.line)
    return found


def flutter_asset_paths(pubspec: str) -> list[str]:
    """The `flutter: assets:` entries of a pubspec, as written.

    Hand-read rather than YAML-parsed so the check needs no PyYAML. Handles
    both the plain `- path` form and the newer `- path: path` map form.
    """
    paths: list[str] = []
    in_flutter = in_assets = False
    assets_indent = 0
    item_indent: int | None = None
    for line in pubspec.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            in_flutter = stripped == "flutter:"
            in_assets = False
            continue
        if in_flutter and stripped == "assets:":
            in_assets, assets_indent, item_indent = True, indent, None
            continue
        if in_assets:
            if indent <= assets_indent:
                in_assets = False
                continue
            # Only items at the list's own indentation are assets. Deeper ones
            # are metadata of a map-form entry (`flavors: [...]` as a list).
            if stripped.startswith("- ") and item_indent is None:
                item_indent = indent
            if stripped.startswith("- ") and indent == item_indent:
                value = stripped[2:].strip()
                if value.startswith("path:"):
                    value = value[len("path:") :].strip()
                paths.append(value.strip("'\""))
    return paths


def is_android_asset(parts: tuple[str, ...]) -> bool:
    """`android/app/src/<set>/assets/...` or `.../res/raw*/...`."""
    return len(parts) > 5 and (
        parts[4] == "assets" or (parts[4] == "res" and parts[5].startswith("raw"))
    )


def decode_text(data: bytes) -> str | None:
    """Text in the encodings an app asset realistically uses, or None."""
    boms = (
        (b"\xef\xbb\xbf", "utf-8-sig"),
        (b"\xff\xfe\x00\x00", "utf-32"),
        (b"\x00\x00\xfe\xff", "utf-32"),
        (b"\xff\xfe", "utf-16"),
        (b"\xfe\xff", "utf-16"),
    )
    for bom, encoding in boms:
        if data.startswith(bom):
            try:
                return data.decode(encoding)
            except UnicodeDecodeError:
                return None
    if b"\0" not in data:
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return None
    # BOM-less UTF-16: every other byte of ASCII-range text is NUL.
    if len(data) % 2 == 0:
        encoding = "utf-16-le" if data[1::2].count(0) > len(data) // 4 else "utf-16-be"
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            return None
    return None


def read_asset(root: Path, path: Path) -> str | None:
    """An asset's text, None for a known binary type, or a SourceError."""
    if path.suffix.lower() in BINARY_ASSET_SUFFIXES:
        return None
    text = decode_text(path.read_bytes())
    if text is None:
        raise SourceError(
            f"{path.relative_to(root).as_posix()}: a packaged asset that is "
            "neither a known binary type nor readable text. If it is binary, add "
            "its suffix to BINARY_ASSET_SUFFIXES in a reviewed change."
        )
    return text


def asset_files(root: Path) -> list[Path]:
    """Text files Flutter or Android package as assets."""
    found: set[Path] = set()
    pubspec = root / "pubspec.yaml"
    if pubspec.is_file():
        for entry in flutter_asset_paths(pubspec.read_text(encoding="utf-8")):
            target = root / entry
            if target.is_dir():
                found.update(p for p in target.iterdir() if p.is_file())
            elif target.is_file():
                found.add(target)
            else:
                raise SourceError(
                    f"pubspec.yaml declares the asset {entry!r}, which does not "
                    "exist. An asset the check cannot read is a hole, not a pass."
                )
    android = root / "android" / "app" / "src"
    if android.is_dir():
        found.update(
            path
            for path in android.rglob("*")
            if path.is_file() and is_android_asset(path.relative_to(root).parts)
        )
    return sorted(
        path for path in found if path.suffix.lower() not in BINARY_ASSET_SUFFIXES
    )


def build_input_files(root: Path) -> list[Path]:
    found: set[Path] = set()
    for pattern in BUILD_INPUT_GLOBS:
        found.update(path for path in root.glob(pattern) if path.is_file())
    return sorted(found)


def shipped_files(root: Path) -> tuple[list[Path], list[tuple[str, int]]]:
    """The files the check reads, in a stable order, and a count per root."""
    files: list[Path] = []
    counts: list[tuple[str, int]] = []
    assets = asset_files(root)
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
            and path not in assets
            and not EXCLUDED_DIRS.intersection(path.relative_to(root).parts[:-1])
        )
        if not found and required:
            raise SourceError(
                f"{relative}/: no source files found. An empty root is a hole "
                "in the check, not a pass."
            )
        files.extend(found)
        counts.append((relative, len(found)))
    files.extend(assets)
    counts.append((ASSET_ROOT_NAME, len(assets)))
    build_inputs = [path for path in build_input_files(root) if path not in files]
    files.extend(build_inputs)
    counts.append((BUILD_INPUT_ROOT_NAME, len(build_inputs)))
    return files, counts


def audit(root: Path, inventory: Inventory) -> Report:
    files, counts = shipped_files(root)
    report = Report(inventory=inventory, files_read=len(files), roots=counts)

    assets = set(asset_files(root))
    observations: list[Observation] = []
    for path in files:
        relative = path.relative_to(root).as_posix()
        if path in assets:
            text = read_asset(root, path)
            if text is None:
                continue
        else:
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
        label = name if name in (ASSET_ROOT_NAME, BUILD_INPUT_ROOT_NAME) else name + "/"
        lines.append(f"  {label.ljust(width + 1)}  {count} files")
    lines.append(
        f"  {report.literals} host literals found, {len(report.reserved)} of them "
        "reserved example or loopback names"
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
