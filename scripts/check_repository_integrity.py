#!/usr/bin/env python3
"""Fail-closed repository-integrity checks for pull requests.

This guard is intentionally narrower and stricter than the general PR security
surface classifier. It protects repository trust policy, IDE auto-execution
surfaces, and binary assets that can be disguised as executable text.

The workflow that invokes this script must load it from the trusted PR base
commit (or be pinned as a required workflow by a repository ruleset).
"""

from __future__ import annotations

import argparse
import fnmatch
import html
import json
import re
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    # `commit` is the precise commit that introduced this violation, resolved by
    # the history scan below. It is required: every finding is attributable.
    commit: str
    path: str
    reason: str
    severity: str = "blocked"
    rule: str = "repository-integrity"
    remediation: str = "Remove the prohibited change and rebuild the feature from the current clean main branch."

    def as_dict(self) -> dict[str, str | None]:
        """Render this finding for the JSON artifact, clamped to what the
        reporter accepts. Clamping affects the report only, never the verdict."""
        return {
            "severity": self.severity,
            "commit": self.commit,
            "path": _clamp_report_field(self.path),
            "rule": _clamp_report_field(self.rule),
            "reason": _clamp_report_field(self.reason),
            "remediation": _clamp_report_field(self.remediation),
        }


PROTECTED_IGNORE_ENTRIES = (".idea/", ".vscode/")

# Must stay in step with MAX_FINDINGS in render_repository_integrity_comment.py:
# the reporter fails closed on a longer list, which would strand a stale comment.
MAX_REPORT_FINDINGS = 100

# Must stay in step with MAX_FIELD_LENGTH in render_repository_integrity_comment.py.
# Git accepts paths longer than this (components stay under NAME_MAX while the
# whole path does not), and the reporter fails closed on an over-long field, so
# an unclamped path would sink the entire artifact and strand a stale comment.
MAX_REPORT_FIELD_CHARS = 2000
_TRUNCATION_SUFFIX = "...[truncated]"


def _clamp_report_field(value: str) -> str:
    """Bound one artifact field, keeping the tail that identifies the offender.

    The leading path components are the least distinguishing part of an
    over-long path, so the end is preserved rather than the start.
    """
    if len(value) <= MAX_REPORT_FIELD_CHARS:
        return value
    keep = MAX_REPORT_FIELD_CHARS - len(_TRUNCATION_SUFFIX)
    return _TRUNCATION_SUFFIX + value[-keep:]


# Files that must be able to hold literal attack strings, because they are the
# fixtures this guard is tested against. Only lines carrying the explicit marker
# below are exempted, and only inside these exact paths.
SELF_TEST_FIXTURE_PATHS = frozenset({"test/tooling/check_repository_integrity_test.py"})

FIXTURE_EXEMPTION_MARKER = "integrity-guard-fixture"

_EXTERNAL_BLOCKED_PATHS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"^\.vscode/", re.I),
        "VS Code workspace configuration is maintainer-controlled",
    ),
    (
        re.compile(r"^\.idea/", re.I),
        "IDE project configuration is maintainer-controlled",
    ),
    (
        re.compile(r"(?:^|/).*\.code-workspace$", re.I),
        "VS Code workspace file is maintainer-controlled",
    ),
    (
        re.compile(r"^\.github/workflows/"),
        "GitHub Actions workflows are maintainer-controlled",
    ),
    (
        re.compile(r"^\.github/actions/"),
        "GitHub composite actions are maintainer-controlled",
    ),
    (
        re.compile(r"^(?:scripts|tools)/|^tool/(?!linux_audio_backend_smoke\.dart$)"),
        "repository automation scripts are maintainer-controlled",
    ),
    (
        re.compile(r"(?:^|/)CODEOWNERS$"),
        "code-ownership policy is maintainer-controlled",
    ),
    (
        re.compile(r"^\.github/dependabot\.ya?ml$"),
        "dependency-update policy is maintainer-controlled",
    ),
    (
        re.compile(r"^\.gitattributes$"),
        "Git diff/attribute policy is maintainer-controlled",
    ),
    (re.compile(r"^\.gitmodules$"), "Git submodule policy is maintainer-controlled"),
)

# The self-test paths are maintainer-controlled by construction: an external PR
# cannot add (or mark) a line that the fixture exemption would then skip.
EXTERNAL_BLOCKED_PATHS: tuple[tuple[re.Pattern[str], str], ...] = (
    _EXTERNAL_BLOCKED_PATHS
    + tuple(
        (
            re.compile(rf"^{re.escape(path)}$"),
            "repository-integrity self-test fixtures are maintainer-controlled",
        )
        for path in sorted(SELF_TEST_FIXTURE_PATHS)
    )
)


def _u16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "big")


def _u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 4], "big")


# A magic prefix alone is worthless here: `wOF2` followed by JavaScript is still
# four valid bytes. Each validator below checks a self-describing structural
# field — a declared length that must equal the real file size, or a redundant
# field derived from another — so appended or substituted script breaks it.


def _valid_woff(data: bytes, signature: bytes, header_size: int) -> bool:
    """WOFF/WOFF2 declare their own total length and a zeroed reserved field."""
    if len(data) < header_size or not data.startswith(signature):
        return False
    if _u32(data, 8) != len(data):
        return False
    return _u16(data, 12) != 0 and _u16(data, 14) == 0


def _valid_sfnt(data: bytes) -> bool:
    """TrueType/OpenType: searchRange and friends are derived from numTables."""
    if len(data) < 12 or data[:4] not in (
        b"\x00\x01\x00\x00",
        b"true",
        b"typ1",
        b"OTTO",
    ):
        return False
    num_tables = _u16(data, 4)
    if num_tables == 0 or len(data) < 12 + 16 * num_tables:
        return False
    entry_selector = num_tables.bit_length() - 1
    search_range = (1 << entry_selector) * 16
    return (
        _u16(data, 6) == search_range
        and _u16(data, 8) == entry_selector
        and _u16(data, 10) == num_tables * 16 - search_range
    )


def _valid_png(data: bytes) -> bool:
    """The 8-byte signature must be followed by a well-formed 13-byte IHDR."""
    if len(data) < 33 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return False
    return _u32(data, 8) == 13 and data[12:16] == b"IHDR"


_JPEG_MARKERS = frozenset(range(0xC0, 0xFF)) - {0xD8, 0xD9}


def _valid_jpeg(data: bytes) -> bool:
    if len(data) < 4 or not data.startswith(b"\xff\xd8\xff"):
        return False
    return data[3] in _JPEG_MARKERS and b"\xff\xd9" in data


def _skip_gif_sub_blocks(data: bytes, pos: int) -> int:
    """Walk a chain of length-prefixed sub-blocks; -1 if it runs off the end."""
    while pos < len(data):
        size = data[pos]
        pos += 1
        if size == 0:
            return pos
        pos += size
    return -1


def _valid_gif(data: bytes) -> bool:
    """Walk the whole block structure through to the trailer.

    A header check is not enough: `GIF89a=0;` parses as a header with non-zero
    canvas dimensions *and* as JavaScript. Requiring the block chain to resolve
    exactly onto the trailer leaves no room for a trailing script.
    """
    if len(data) < 14 or data[:6] not in (b"GIF87a", b"GIF89a"):
        return False
    if (
        int.from_bytes(data[6:8], "little") == 0
        or int.from_bytes(data[8:10], "little") == 0
    ):
        return False

    flags = data[10]
    pos = 13
    if flags & 0x80:
        pos += 3 * (1 << ((flags & 0x07) + 1))

    while 0 <= pos < len(data):
        block = data[pos]
        pos += 1
        if block == 0x3B:
            return pos == len(data)
        if block == 0x21:
            if pos >= len(data):
                return False
            pos = _skip_gif_sub_blocks(data, pos + 1)
        elif block == 0x2C:
            if pos + 9 > len(data):
                return False
            local = data[pos + 8]
            pos += 9
            if local & 0x80:
                pos += 3 * (1 << ((local & 0x07) + 1))
            if pos >= len(data):
                return False
            pos = _skip_gif_sub_blocks(data, pos + 1)
        else:
            return False
    return False


_VP8_KEYFRAME_START_CODE = b"\x9d\x01\x2a"


def _valid_vp8_payload(fourcc: bytes, payload: bytes) -> bool:
    """Check the image chunk's own bitstream signature.

    Self-consistent chunk lengths are not enough on their own: a payload can
    declare honest sizes and still be script, provided it opens with `*/` to
    close a comment covering the header. The bitstream signatures below occupy
    exactly those bytes, so the payload can be a real frame or valid script,
    not both.
    """
    if fourcc == b"VP8 ":
        return len(payload) >= 10 and payload[3:6] == _VP8_KEYFRAME_START_CODE
    if fourcc == b"VP8L":
        return len(payload) >= 5 and payload[0] == 0x2F
    if fourcc == b"VP8X":
        return len(payload) >= 10
    return True


def _walk_webp_chunks(data: bytes, pos: int, end: int) -> tuple[bool, bool]:
    """Walk the chunk chain in [pos, end).

    Returns (structure_is_sound, a_real_frame_was_seen). The two are separate
    because `VP8X` is only the extended-file header — it announces features and
    carries no image data, so a file holding nothing but `VP8X` is not an image
    however well-formed its chunk lengths are.
    """
    saw_frame = False
    while pos + 8 <= end:
        fourcc = data[pos : pos + 4]
        if not all(0x20 <= byte <= 0x7E for byte in fourcc):
            return False, saw_frame
        size = int.from_bytes(data[pos + 4 : pos + 8], "little")
        start = pos + 8
        stop = start + size
        if stop > end:
            return False, saw_frame
        payload = data[start:stop]

        if fourcc in (b"VP8 ", b"VP8L"):
            if not _valid_vp8_payload(fourcc, payload):
                return False, saw_frame
            saw_frame = True
        elif fourcc == b"VP8X":
            if len(payload) < 10:
                return False, saw_frame
        elif fourcc == b"ANMF":
            # An animation frame nests its own chunk chain after a 16-byte header.
            if len(payload) < 16:
                return False, saw_frame
            sound, nested = _walk_webp_chunks(data, start + 16, stop)
            if not sound:
                return False, saw_frame
            saw_frame = saw_frame or nested

        pos = stop + (size & 1)
    return pos == end, saw_frame


def _valid_webp(data: bytes) -> bool:
    """Declared RIFF length, a chunk chain landing exactly on the end, and at
    least one real VP8/VP8L frame — nested inside ANMF for animations."""
    if len(data) < 16 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return False
    if int.from_bytes(data[4:8], "little") != len(data) - 8:
        return False
    sound, saw_frame = _walk_webp_chunks(data, 12, len(data))
    return sound and saw_frame


def _valid_pdf(data: bytes) -> bool:
    """A deliberately shallow check — see the note below.

    Structural PDF validation cannot rule out a shell polyglot. A shell reads a
    file line by line and carries on past errors, so only the opening lines
    decide what runs; no amount of trailing xref, trailer or object structure
    prevents a payload on line two. A genuine PDF is itself "runnable" that way,
    as a series of failing commands. Parsing the object graph would therefore
    buy nothing against the attack it appears to address.

    What actually defends a disguised PDF is denying it an execution path: the
    executable-bit check in `check_asset_modes`, and the text scan that catches
    anything in the repository invoking it. This function is the cheap sanity
    layer — it rejects a bare script with no PDF header at all — and the limit
    is documented rather than papered over.
    """
    if len(data) < 32 or not data.startswith(b"%PDF-"):
        return False
    return b"%%EOF" in data[-2048:]


def _valid_ico(data: bytes) -> bool:
    """Header, directory, and every entry pointing at real image bytes."""
    if (
        len(data) < 6
        or data[:2] != b"\x00\x00"
        or data[2:4] not in (b"\x01\x00", b"\x02\x00")
    ):
        return False
    count = int.from_bytes(data[4:6], "little")
    directory_end = 6 + 16 * count
    if count == 0 or len(data) < directory_end:
        return False
    for index in range(count):
        entry = 6 + 16 * index
        size = int.from_bytes(data[entry + 8 : entry + 12], "little")
        offset = int.from_bytes(data[entry + 12 : entry + 16], "little")
        if size == 0 or offset < directory_end or offset + size > len(data):
            return False
    return True


# PDF is deliberately absent: a standards-compliant PDF can be entirely ASCII —
# objects, xref table, trailer and %%EOF — so the binary backstop would reject
# legitimate documents. Its structural validator carries the weight instead.
BINARY_ASSET_SUFFIXES = frozenset(
    {
        ".woff",
        ".woff2",
        ".ttf",
        ".otf",
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".ico",
    }
)

ASSET_VALIDATORS: dict[str, tuple[str, "Callable[[bytes], bool]"]] = {
    ".woff2": ("WOFF2", lambda data: _valid_woff(data, b"wOF2", 48)),
    ".woff": ("WOFF", lambda data: _valid_woff(data, b"wOFF", 44)),
    ".ttf": ("TrueType", _valid_sfnt),
    ".otf": ("OpenType", _valid_sfnt),
    ".png": ("PNG", _valid_png),
    ".jpg": ("JPEG", _valid_jpeg),
    ".jpeg": ("JPEG", _valid_jpeg),
    ".gif": ("GIF", _valid_gif),
    ".webp": ("WEBP", _valid_webp),
    ".pdf": ("PDF", _valid_pdf),
    ".ico": ("ICO", _valid_ico),
}

# Extensions the guard treats as inert assets. Nothing here should ever carry
# the executable bit, so the mode is checked independently of the contents.
ASSET_SUFFIXES = frozenset(
    {
        ".woff",
        ".woff2",
        ".ttf",
        ".otf",
        ".eot",
        ".png",
        ".jpg",
        ".jpeg",
        ".gif",
        ".webp",
        ".ico",
        ".pdf",
        ".svg",
    }
)


def _split_literal(*parts: str) -> str:
    return "".join(parts)


_INTERPRETERS = (
    _split_literal("no", "de"),
    "python",
    "python3",
    "perl",
    "ruby",
    "php",
    "sh",
    "bash",
    "zsh",
    "dash",
    "ksh",
    "pwsh",
    "powershell",
)

EXECUTABLE_ASSET_EXTENSIONS = (
    _split_literal("wo", "ff2?"),
    _split_literal("t", "tf"),
    _split_literal("o", "tf"),
    _split_literal("e", "ot"),
    _split_literal("p", "ng"),
    _split_literal("jp", "e?g"),
    _split_literal("g", "if"),
    _split_literal("we", "bp"),
    _split_literal("i", "co"),
    _split_literal("p", "df"),
)
_EXECUTABLE_ASSET_RE = re.compile(
    rf"""(?ix)
    \b(?:{"|".join(_INTERPRETERS)})
    \b[^\n\r]{{0,240}}
    \.(?:{"|".join(EXECUTABLE_ASSET_EXTENSIONS)})\b
    |
    \bchmod\b[^\n\r]{{0,120}}\+x[^\n\r]{{0,160}}
    \.(?:{"|".join(EXECUTABLE_ASSET_EXTENSIONS)})\b
    |
    (?:^|[;&|()])\s*(?:source|\.)\s+[^\n\r]{{0,240}}
    \.(?:{"|".join(EXECUTABLE_ASSET_EXTENSIONS)})\b
    """
)

_NUMERIC_CHMOD_ASSET_RE = re.compile(
    rf"""(?ix)
    \bchmod\b[^\n\r]{{0,120}}?\b(?P<mode>[0-7]{{3,4}})\b
    [^\n\r]{{0,160}}\.(?:{"|".join(EXECUTABLE_ASSET_EXTENSIONS)})\b
    """
)

ACTIVE_SVG_RE = re.compile(
    r"""(?ix)
    <\s*script\b
    |javascript\s*:
    |\bon[a-z][a-z0-9_:-]*\s*=
    |<\s*foreignObject\b
    |(?:href|xlink:href)\s*=\s*["']\s*(?:https?:|data:text/html)
    """
)


class IntegrityError(RuntimeError):
    pass


def run_git(*args: str, text: bool = True) -> str | bytes:
    try:
        proc = subprocess.run(
            ["git", *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=text,
            encoding="utf-8" if text else None,
            errors="surrogateescape" if text else None,
        )
    except FileNotFoundError as exc:
        raise IntegrityError("git executable is unavailable") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr if text else exc.stderr.decode("utf-8", "replace")
        raise IntegrityError(
            f"git {' '.join(args)} failed ({exc.returncode}): {stderr.strip()}"
        ) from exc
    return proc.stdout


def changed_files(base: str, head: str) -> list[str]:
    raw = run_git(
        "-c",
        "core.quotePath=false",
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        f"{base}...{head}",
        "--",
    )
    assert isinstance(raw, str)
    return [item for item in raw.split("\0") if item]


def blob_bytes(head: str, path: str) -> bytes | None:
    try:
        value = run_git("show", f"{head}:{path}", text=False)
    except IntegrityError:
        return None
    assert isinstance(value, bytes)
    return value


def blob_text(head: str, path: str) -> str | None:
    data = blob_bytes(head, path)
    if data is None:
        return None
    return data.decode("utf-8", "surrogateescape")


def git_mode(head: str, path: str) -> str | None:
    try:
        out = run_git("ls-tree", head, "--", path)
    except IntegrityError:
        return None
    assert isinstance(out, str)
    if not out.strip():
        return None
    return out.split(None, 1)[0]


def is_external(pr_author: str, repo_owner: str) -> bool:
    return pr_author.casefold() != repo_owner.casefold()


def _ignore_rules(text: str) -> list[str]:
    rules: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rules.append(line[1:] if line.startswith("\\") else line)
    return rules


def _negation_reenables(pattern: str, name: str) -> bool:
    """Whether a `!` rule re-enables `name`, using Git's matching semantics.

    Python's fnmatch has no notion of `**/`, so `!**/.vscode/` — which Git
    applies at every depth including the root — would otherwise slip through.
    """
    pattern = pattern.strip().strip("/")
    if not pattern:
        return False
    candidates = {pattern}
    while pattern.startswith("**/"):
        pattern = pattern[3:]
        candidates.add(pattern)
    return any(fnmatch.fnmatch(name, candidate) for candidate in candidates)


def _ignore_state(rules: list[str], entry: str) -> tuple[bool, str | None]:
    """Resolve whether `entry` ends up ignored, the way Git resolves it.

    Git applies the *last* matching rule, so a later `!.vscode/` re-enables a
    directory an earlier `.vscode/` ignored. Checking only for the presence of
    the positive entry misses that. Negations are matched as globs, since
    `!.vs*` re-enables the directory just as surely as `!.vscode/`.
    """
    name = entry.strip("/")
    ignored = False
    negated_by: str | None = None
    for rule in rules:
        if rule.startswith("!"):
            if _negation_reenables(rule[1:], name):
                ignored = False
                negated_by = rule
        elif rule.strip("/") == name:
            ignored = True
            negated_by = None
    return ignored, negated_by


def check_ignore_policy(head: str) -> list[Finding]:
    text = blob_text(head, ".gitignore")
    if text is None:
        return [
            Finding(head, ".gitignore", "required repository .gitignore is missing")
        ]
    rules = _ignore_rules(text)

    findings: list[Finding] = []
    for entry in PROTECTED_IGNORE_ENTRIES:
        ignored, negated_by = _ignore_state(rules, entry)
        if ignored:
            continue
        if negated_by is not None:
            findings.append(
                Finding(
                    head,
                    ".gitignore",
                    f"required ignore entry `{entry}` is re-enabled by `{negated_by}`",
                )
            )
        else:
            findings.append(
                Finding(
                    head, ".gitignore", f"required ignore entry `{entry}` was removed"
                )
            )
    return findings


def check_external_paths(commit: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        for pattern, reason in EXTERNAL_BLOCKED_PATHS:
            if pattern.search(path):
                findings.append(Finding(commit, path, reason))
                break
    return findings


def check_symlinks(head: str, files: list[str], external: bool) -> list[Finding]:
    if not external:
        return []
    findings: list[Finding] = []
    for path in files:
        if git_mode(head, path) == "120000":
            findings.append(
                Finding(head, path, "external PR introduces or modifies a Git symlink")
            )
    return findings


def check_asset_modes(head: str, files: list[str]) -> list[Finding]:
    """Assets are inert data; the executable bit is the thing that runs them.

    The text scan only catches an interpreter or a literal `chmod +x` written
    into a file. It cannot see a payload committed already-executable, which
    needs no invocation written down anywhere.
    """
    findings: list[Finding] = []
    for path in files:
        if Path(path).suffix.lower() not in ASSET_SUFFIXES:
            continue
        if git_mode(head, path) == "100755":
            findings.append(
                Finding(
                    head, path, "asset file is committed with the executable bit set"
                )
            )
    return findings


def check_asset_magic(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        entry = ASSET_VALIDATORS.get(Path(path).suffix.lower())
        if entry is None:
            continue
        label, is_valid = entry
        data = blob_bytes(head, path)
        if data is None:
            continue
        suffix = Path(path).suffix.lower()
        if suffix in BINARY_ASSET_SUFFIXES and data and b"\x00" not in data:
            # Every real asset in these formats carries binary content. A file
            # that is pure text is a polyglot candidate regardless of how well
            # it fakes a header, so reject it before the format check.
            findings.append(
                Finding(
                    head,
                    path,
                    f"file extension claims {label} but the file is entirely text",
                )
            )
            continue
        if not is_valid(data):
            findings.append(
                Finding(
                    head,
                    path,
                    f"file extension claims {label} but the file is not a valid {label}",
                )
            )
    return findings


# URL parsers strip ASCII tabs and newlines from anywhere inside a URL before
# resolving the scheme, so `java&#x09;script:` is a live javascript: URL. This
# pass is anchored to URL-bearing attributes on purpose: control characters are
# removed from the whole document to find it, and a bare scheme match would then
# also fire on ordinary prose in a `<text>` or `<desc>` node, where nothing ever
# parses it as a URL.
ACTIVE_SVG_SCHEME_RE = re.compile(
    r"""(?ix)
    (?:href|xlink:href)\s*=\s*["']?\s*(?:javascript:|data:text/html)
    """
)

_URL_CONTROL_CHARS = dict.fromkeys(b"\x00\x09\x0a\x0d")


def svg_is_active(text: str) -> bool:
    """Match active content on the raw source, its decoded form, and its
    URL-normalised form.

    An XML parser resolves character references before acting on an attribute,
    and a URL parser then discards embedded tabs and newlines. Each layer is
    checked because a payload only has to survive all of them once.
    """
    if ACTIVE_SVG_RE.search(text):
        return True
    decoded = html.unescape(text)
    if decoded != text and ACTIVE_SVG_RE.search(decoded):
        return True
    normalised = decoded.translate(_URL_CONTROL_CHARS)
    return normalised != decoded and bool(ACTIVE_SVG_SCHEME_RE.search(normalised))


def check_active_svg(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        if Path(path).suffix.lower() != ".svg":
            continue
        text = blob_text(head, path)
        if text is not None and svg_is_active(text):
            findings.append(
                Finding(head, path, "SVG contains active/external executable content")
            )
    return findings


def is_exempt_fixture_line(path: str, line: str) -> bool:
    """Report whether a single line opts out of the asset-execution text scan.

    The exemption exists so the guard's own test module can hold the literal
    attack strings it asserts against. It is deliberately narrow: it applies
    only inside `SELF_TEST_FIXTURE_PATHS`, only to individual lines that carry
    the marker, and only to this one check. Every other line of those files is
    scanned normally, and external PRs cannot modify them at all.
    """
    return path in SELF_TEST_FIXTURE_PATHS and FIXTURE_EXEMPTION_MARKER in line


def asset_execution_finding(path: str, text: str) -> Finding | None:
    """Return a finding when `text` invokes or marks an asset as executable.

    Shell removes a backslash-newline pair before parsing commands, so perform
    that exact normalisation before matching. Fixture exemptions remain
    physical-line scoped and are removed first; their marker can neither exempt
    a neighbouring line nor become part of a reconstructed command.
    """
    scannable: list[str] = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        ending = line[len(body) :]
        scannable.append(ending if is_exempt_fixture_line(path, body) else line)

    normalised = re.sub(r"\\\r?\n", "", "".join(scannable))
    for line in re.split(r"[\r\n]", normalised):
        if _EXECUTABLE_ASSET_RE.search(line):
            return Finding(
                "", path, "text invokes or marks an asset file as executable"
            )
        for match in _NUMERIC_CHMOD_ASSET_RE.finditer(line):
            permission_digits = match.group("mode")[-3:]
            if any(int(digit) & 1 for digit in permission_digits):
                return Finding(
                    "", path, "text invokes or marks an asset file as executable"
                )
    return None


def check_asset_execution(head: str, files: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for path in files:
        data = blob_bytes(head, path)
        if data is None or b"\x00" in data:
            continue
        finding = asset_execution_finding(path, data.decode("utf-8", "surrogateescape"))
        if finding is not None:
            findings.append(Finding(head, finding.path, finding.reason))
    return findings


def dedupe(findings: list[Finding]) -> list[Finding]:
    seen: set[tuple[str, str, str]] = set()
    result: list[Finding] = []
    for finding in findings:
        key = (finding.commit, finding.path, finding.reason)
        if key not in seen:
            seen.add(key)
            result.append(finding)
    return result


def actionable(finding: Finding) -> Finding:
    """Attach a stable rule id and a concrete remediation to a raw finding.

    Attribution is not reconstructed here: the history scan already resolved the
    exact commit that introduced the violation, so this only maps the low-level
    reason onto deterministic, actionable guidance for the PR comment.
    """
    reason = finding.reason.lower()
    if "executable bit" in reason:
        rule, remediation = (
            "asset-executable-mode",
            "Remove the executable permission from the asset and recommit the mode change.",
        )
    elif "file extension claims" in reason:
        rule, remediation = (
            "invalid-disguised-asset",
            "Replace the invalid asset with a real file of the declared asset type.",
        )
    elif "svg contains" in reason:
        rule, remediation = (
            "active-svg-content",
            "Remove scripts, event handlers, foreign objects, and external active references from the SVG.",
        )
    elif "invokes or marks an asset" in reason:
        rule, remediation = (
            "asset-execution-command",
            "Remove commands that execute the asset or grant it executable permission.",
        )
    elif "gitignore" in reason or "ignore entry" in reason:
        rule, remediation = (
            "protected-ignore-policy",
            "Restore the required .idea/ and .vscode/ ignore rules without later negations.",
        )
    elif "symlink" in reason:
        rule, remediation = (
            "external-symlink",
            "Remove the Git symlink or move the repository-control change to a maintainer-owned PR.",
        )
    elif "maintainer-controlled" in reason:
        rule, remediation = (
            "external-maintainer-controlled-path",
            "Recreate or rebase the legitimate feature work onto a clean main history, or move this repository-control change to a maintainer-owned PR.",
        )
    else:
        rule, remediation = finding.rule, finding.remediation
    return replace(finding, rule=rule, remediation=remediation)


def resolve_commit(revision: str) -> str:
    value = run_git("rev-parse", "--verify", f"{revision}^{{commit}}")
    assert isinstance(value, str)
    return value.strip()


def commit_parents(commit: str) -> list[str]:
    value = run_git("show", "-s", "--format=%P", commit)
    assert isinstance(value, str)
    return value.strip().split()


def changed_files_between(old: str, new: str) -> list[str]:
    raw = run_git(
        "-c",
        "core.quotePath=false",
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        old,
        new,
        "--",
    )
    assert isinstance(raw, str)
    return [item for item in raw.split("\0") if item]


EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def commit_introduced_files(commit: str) -> list[str]:
    """Paths whose state was introduced by this commit rather than a parent.

    For an ordinary commit this is its parent diff. For a merge, only paths
    different from *every* parent are merge-introduced. That catches novel
    conflict resolutions without blaming an Update-branch merge for content
    copied unchanged from either the PR or trusted-main parent.
    """
    parents = commit_parents(commit)
    if not parents:
        return changed_files_between(EMPTY_TREE, commit)
    changed_by_parent = [
        set(changed_files_between(parent, commit)) for parent in parents
    ]
    return sorted(set.intersection(*changed_by_parent))


def introduced_commits(base: str, head: str) -> list[str]:
    # A GitHub PR must share ancestry with its trusted base. Refuse unrelated
    # histories rather than broadening the scan to an entire foreign history.
    merge_base = run_git("merge-base", base, head)
    assert isinstance(merge_base, str)
    if not merge_base.strip():
        raise IntegrityError("PR head has no merge base with the trusted base")
    raw = run_git("rev-list", "--reverse", "--topo-order", head, "--not", base)
    assert isinstance(raw, str)
    return raw.split()


def scan_tree(
    commit: str, files: list[str], external: bool, *, check_ignore: bool
) -> list[Finding]:
    findings: list[Finding] = []
    if check_ignore:
        findings.extend(check_ignore_policy(commit))
    if external:
        findings.extend(check_external_paths(commit, files))
    findings.extend(check_symlinks(commit, files, external))
    findings.extend(check_asset_modes(commit, files))
    findings.extend(check_asset_magic(commit, files))
    findings.extend(check_active_svg(commit, files))
    findings.extend(check_asset_execution(commit, files))
    return findings


def scan(base: str, head: str, pr_author: str, repo_owner: str) -> list[Finding]:
    base = resolve_commit(base)
    head = resolve_commit(head)
    external = is_external(pr_author, repo_owner)

    findings: list[Finding] = []
    for commit in introduced_commits(base, head):
        files = commit_introduced_files(commit)
        findings.extend(
            scan_tree(commit, files, external, check_ignore=".gitignore" in files)
        )

    # Preserve the final-tree check as defense in depth, but do not attribute a
    # historical violation to a later merge merely because it remains present
    # there. Historical findings are the more precise explanation.
    files = changed_files(base, head)
    historical_keys = {(finding.path, finding.reason) for finding in findings}
    for finding in scan_tree(head, files, external, check_ignore=".gitignore" in files):
        if (finding.path, finding.reason) not in historical_keys:
            findings.append(finding)
    return [actionable(finding) for finding in dedupe(findings)]


def write_report(path: Path, findings: list[Finding]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", errors="backslashreplace") as out:
        out.write("## Repository integrity guard\n\n")
        if not findings:
            out.write("No repository-integrity violation was detected.\n")
            return
        out.write("### Blocked findings\n\n")
        for finding in findings:
            out.write(
                f"- commit `{finding.commit}` — `{finding.path}` — {finding.reason}\n"
            )
        out.write(
            "\nThese checks fail closed. Repository-control changes must be "
            "performed from a trusted maintainer-controlled branch.\n"
        )


def write_json_report(
    path: Path,
    findings: list[Finding],
    *,
    pr_number: int,
    head: str,
    head_repository: str,
) -> None:
    """Write the machine-readable artifact the trusted reporter consumes.

    The list is capped to the bound the reporter enforces. Without the cap a PR
    with more findings than that bound produces an artifact its own reporter
    rejects, so the sticky comment silently goes stale while the guard is
    blocking. Truncation is a reporting concern only: it never affects the
    verdict, which is computed from the complete finding list.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    reported = findings[:MAX_REPORT_FINDINGS]
    payload = {
        "schema_version": 1,
        "pr_number": pr_number,
        "head_sha": head,
        "head_repository": head_repository,
        "truncated": len(findings) - len(reported),
        "findings": [finding.as_dict() for finding in reported],
    }
    path.write_text(
        json.dumps(payload, ensure_ascii=True, sort_keys=True) + "\n", encoding="utf-8"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--pr-author", required=True)
    parser.add_argument("--repo-owner", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--json-report", required=True)
    parser.add_argument("--pr-number", required=True, type=int)
    parser.add_argument("--head-repository", required=True)
    args = parser.parse_args(argv)

    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="backslashreplace")

    try:
        findings = scan(args.base, args.head, args.pr_author, args.repo_owner)
    except IntegrityError as exc:
        print(
            f"::error::Repository integrity scan failed closed: {exc}", file=sys.stderr
        )
        return 2

    write_report(Path(args.report), findings)
    write_json_report(
        Path(args.json_report),
        findings,
        pr_number=args.pr_number,
        head=args.head,
        head_repository=args.head_repository,
    )

    if findings:
        print("Repository integrity guard blocked the PR:")
        for finding in findings:
            print(f"  {finding.commit} {finding.path}: {finding.reason}")
        return 1

    print("Repository integrity guard passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
