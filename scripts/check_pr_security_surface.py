#!/usr/bin/env python3
"""Classify security-sensitive PR diffs and block a few high-risk additions.

This is intentionally conservative: ordinary UI/tests/docs PRs should pass
without maintainer involvement, while changes that touch trust boundaries are
surfaced for an explicit second review.

Every ambiguity is resolved in the fail-closed direction. If git metadata is
missing, if a diff header cannot be parsed, or if the scanner cannot complete,
it exits non-zero rather than reporting an ordinary-risk diff.
"""

from __future__ import annotations

import argparse
import bisect
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    path: str
    reason: str


# Attributed to added lines whose file header could not be decoded. Scanning
# still happens; the unresolved path itself is reported as sensitive so that a
# parser failure can never downgrade a diff to "ordinary risk".
UNKNOWN_PATH = "<unresolved diff path>"


SENSITIVE_PATH_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    # Default-sensitive for the whole directory, with a short allowlist for
    # non-executable community metadata. Enumerating the automation instead
    # would have to be extended for each new kind: .github/codex/prompts/ holds
    # the prompt flutter-ci-fixer.yml reads from main and feeds to an agent with
    # workspace-write and a repository secret, which no `workflows|actions` rule
    # would ever have matched.
    (
        re.compile(r"^\.github/(?!ISSUE_TEMPLATE/|PULL_REQUEST_TEMPLATE|FUNDING\.)"),
        "CI / automation configuration",
    ),
    # scripts/, tool/ and tools/ all hold code that CI executes:
    # tool/version_from_tag.dart gates release versioning and
    # tools/large_library/ is run by the large-library workflow.
    (re.compile(r"^(?:scripts|tool|tools)/"), "repository automation script"),
    (re.compile(r"^(pubspec\.ya?ml|pubspec\.lock)$"), "dependency manifest / lockfile"),
    (
        re.compile(
            r"^android/.*(AndroidManifest\.xml|\.gradle(?:\.kts)?|gradle\.properties)$"
        ),
        "Android permissions / build configuration",
    ),
    # The Gradle wrapper decides which Gradle is downloaded and from where
    # (distributionUrl), and the wrapper jar is executed by every Android
    # build. The repository's own toolchain guard covers only the automated
    # `toolchain/flutter-sdk` branch, by design, so an ordinary PR editing a
    # pin is unreviewed without this.
    # res/xml holds the app's security and privacy policy: the network security
    # config decides HTTPS trust anchors and cleartext, and the backup and
    # data-extraction rules decide what app data leaves the device.
    (re.compile(r"^android/.*/res/xml/"), "Android security / privacy policy"),
    # Kotlin/Java under android/ implements the platform channels, the SAF
    # scanner, sharing and the artwork FileProvider, and is compiled into every
    # release APK by android-release-build.yml. The other trees do not exist
    # today; naming them keeps a future `flutter create --platforms=` from
    # landing unclassified privileged code.
    (
        re.compile(r"^(?:android|ios|macos|windows)/.*\.(?:kt|java|swift|m|mm)$"),
        "platform / native app code",
    ),
    (re.compile(r"(?:^|/)gradle/wrapper/"), "build toolchain distribution / wrapper"),
    (re.compile(r"^\.[a-z0-9]+-version$"), "build toolchain pin"),
    # linux/ is the desktop runner; native/ holds the C++ DSP library and the
    # Rust core, both compiled by CI and the Rust one also executed by it
    # (`cargo run --locked` in rust-core.yml).
    (
        re.compile(r"^(?:linux|native)/.*\.(?:cc|cpp|cxx|c|h|hpp|hxx|rs|cmake)$"),
        "native code",
    ),
    (re.compile(r"(?:^|/)CMakeLists\.txt$"), "native build configuration"),
    # A Dart build hook runs on every `flutter build`, `flutter run` and
    # `flutter test`, on contributors' machines and in CI. Anything under
    # hook/ is build-time code execution.
    (re.compile(r"^hook/"), "Dart build hook (runs at build time)"),
    # A Cargo dependency may carry a build script, which runs at build time on
    # the CI machine — the same trust boundary pubspec.yaml crosses.
    (re.compile(r"(?:^|/)Cargo\.(?:toml|lock)$"), "dependency manifest / lockfile"),
    # flutter-ci-fixer.yml keeps its own list of paths its agent may not touch.
    # Cross-checking against it turned up these, beyond the analyzer config that
    # was reported: `flutter analyze` is a required check on every PR, licence
    # text is a legal boundary, and signing material is the release identity.
    (re.compile(r"(?:^|/)analysis_options\.ya?ml$"), "static analysis configuration"),
    (re.compile(r"(?:^|/)(?:LICENSE|COPYING|NOTICE)(?:$|\.)"), "licensing"),
    (
        re.compile(r"(?:^|/)key\.properties$|\.(?:jks|keystore)$"),
        "release signing material",
    ),
    # metadata/*.yml is the F-Droid build recipe: its Builds entries carry
    # sudo/prebuild/build commands, and docs/fdroid-submission.md has the
    # maintainer copy it into fdroiddata and run a full build from it. The
    # fastlane changelog and description text beside it really is just text,
    # and stays ordinary.
    (re.compile(r"^metadata/.*\.ya?ml$"), "F-Droid build recipe"),
    (
        re.compile(r"^lib/.*(?:auth|credential|token|session|secure|secret)", re.I),
        "authentication / credential handling",
    ),
    (
        re.compile(r"^lib/.*(?:network|http|client|socket|provider|source)", re.I),
        "network / provider boundary",
    ),
    (
        re.compile(
            r"^lib/.*(?:database|repository|store|storage|persistence|cache)", re.I
        ),
        "persistent storage",
    ),
    # `.gitattributes` can change how git renders a diff (for example marking a
    # path `-diff`), which is a direct attack on this scanner's input.
    (re.compile(r"(?:^|/)\.gitattributes$"), "git diff / attribute behavior"),
    (re.compile(r"(?:^|/)CODEOWNERS$"), "code ownership / review routing"),
    (
        re.compile(r"^(?:\.gitmodules|\.github/dependabot\.ya?ml)$"),
        "supply-chain configuration",
    ),
)

SENSITIVE_ADDITION_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(
            r"\b(?:HttpClient|WebSocket|Socket)\b|package:http/|\bhttp\.(?:get|post|put|delete|patch)\b"
        ),
        "new network-capable code",
    ),
    (
        re.compile(
            r"\b(?:SharedPreferences|FlutterSecureStorage|File|Directory|RandomAccessFile)\s*\("
        ),
        "new local persistence / filesystem access",
    ),
    (
        re.compile(
            r"\b(?:writeAsString|writeAsBytes|openWrite|setString|setStringList)\s*\("
        ),
        "new write-to-disk behavior",
    ),
    (re.compile(r"\b(?:MethodChannel|EventChannel)\s*\("), "new platform channel"),
    (
        re.compile(
            r"\b(?:authorization|bearer|access[_-]?token|api[_-]?key|password|credential)\b",
            re.I,
        ),
        "credential-sensitive logic",
    ),
    (
        re.compile(r"\b(?:schemaVersion|MigrationStrategy|createIndex|alterTable)\b"),
        "database schema / migration",
    ),
)


def _split_literal(*fragments: str) -> str:
    """Join the fragments of a literal this file must not contain contiguously.

    Blocked rules are matched against every added line of every changed file —
    including the lines of this file and of its tests. Spelling a blocked
    literal out here would make the guard reject any PR that edits its own
    source, so the handful that would otherwise self-match are assembled at
    import time. The compiled pattern is exactly the intended literal;
    `check_pr_security_surface_test.py` asserts both that the assembly is
    complete and that the guard's own sources stay clean.
    """

    return "".join(fragments)


_DOWNLOAD_CLIENT = rf"(?:{_split_literal('cu', 'rl')}|{_split_literal('wg', 'et')})"


# Separator allowed between the tokens of a blocked construct. Dart accepts a
# comment anywhere whitespace is legal, so a block or line comment wedged
# between an API's receiver, its dot and its member name is the same call.
#
# This is deliberately a *separator*, not a comment-stripping pass over the
# diff. Stripping would have to decide what is a comment and what is a string
# literal, and getting that wrong is itself a bypass: a crafted `/*` inside a
# string would make the stripper swallow the real code that follows it. Widening
# the gap between two tokens cannot hide anything, because the separator only
# ever matches whitespace and comments — never code.
# Shell whitespace, including a backslash continuation. A command may be broken
# across lines at any point where a space is legal, so every gap in the download
# rules has to accept one — the flag, its value and the interpreter's argument
# alike, not just the first of them.
# Commands that launch another command. `| env sh` and `&& nohup bash f` run the
# interpreter just as surely as naming it alone does, so the whole class is
# allowed in front of one rather than each wrapper being added as it turns up.
_EXEC_WRAPPER = (
    r"(?:(?:sudo|env|command|exec|nohup|nice|stdbuf|setsid|ionice|timeout)\s+"
    r"(?:[-\w=./]+\s+)*)*"
)


# The download half of the download-then-execute rules, shared by the blocked
# tier (the file is run) and the sensitive tier (it is only made runnable).
#
#   `;`, `|` and `&&` end the download command, so the output flag has to be
#   found before one; a single `&` is kept, being ordinary inside a quoted
#   query string. Short options bundle and may carry the value attached
#   (`-o f`, `-qO f`, `-of`); the long forms cover both clients' output options.
#   Quotes live outside the capture so quoted and unquoted target paths compare
#   equal when the same downloaded file is later executed.
def _download_to_file(gap: str) -> str:
    return (
        rf"{_DOWNLOAD_CLIENT}(?:[^\n;|&]|&(?!&)|\\\n)*?"
        rf"(?:{gap}+-[A-Za-z]*[oO]{gap}*"
        rf"|{gap}+--output(?:-document)?(?:=|{gap}){gap}*"
        rf"|{gap}*>{gap}*)"
        rf"['\"]?(?P<target>[^\s'\";&|<>]+)['\"]?"
        rf"[\s\S]{{0,2000}}?"
    )


# The same file again, ending at a real argument boundary rather than \b, so
# `/tmp/data` does not match inside `/tmp/data-cleanup.sh`.
_SAME_TARGET = r"""['\"]?(?P=target)(?=$|[\s'\";&|)<>])"""

_SH_GAP = r"(?:[ \t]|\\\n)"

# One shell argument/fragment that may contain separators only while quoted.
# A quoted URL may legitimately contain `&` or `;`; it must still be recognized
# when its download stream is piped into an interpreter. Unquoted separators end
# that command so a later unrelated local pipeline cannot become a hard block.
_SHELL_QUOTED = r"""(?:'(?:[^']*)'|"(?:\\.|[^"\\])*")"""
_SHELL_COMMAND_SEGMENT = rf"(?:{_SHELL_QUOTED}|\\\n|[^\n|;&])*"

_SEP = r"(?:\s|(?s:/\*.*?\*/)|//[^\n]*)*"

_FFI = _split_literal("f", "fi")
_PR_TARGET_TRIGGER = _split_literal("pull_request", "_target")

# These are matched as *references*, not only as direct call syntax: binding one
# of these APIs to a local and calling it through that name grants exactly the
# same runtime capability as calling it inline, so requiring a following `(`
# would leave a trivial bypass.
BLOCKED_ADDITION_RULES: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(
            rf"\bProcess{_SEP}\.{_SEP}(?:run|runSync|start|startSync|killPid)\b"
        ),
        "runtime process execution",
    ),
    # Anything but an explicit `false`: `true` enables a shell, and a variable
    # or expression cannot be judged from here. `false` genuinely disables it,
    # and blocking that would be a false positive an approval could not clear.
    (
        # The whitespace sits inside the lookahead on purpose: with `\s*` before
        # it, the engine backtracks to zero width and tests the space instead of
        # the value, so `false` slips through as "not false".
        #
        # `false` also has to be the entire value. `false || true` and
        # `false == false` both start with it and both evaluate true, so the
        # exemption ends at a value delimiter. Comments are valid whitespace in
        # Dart, so an explicit false followed only by comments and a delimiter
        # remains exempt without making expressions that merely start with false
        # exempt as well.
        re.compile(
            rf"""\b{_split_literal("runIn", "Shell")}['"]?\s*:"""
            rf"""(?!\s*false{_SEP}(?:[,);}}\]\n]|$))"""
        ),
        "runtime shell execution",
    ),
    (
        re.compile(
            rf"""['"]dart:{_FFI}['"]"""
            rf"""|package:{_FFI}/"""
            rf"""|\b{_split_literal("Dynamic", "Library")}\b"""
            rf"""|\b{_split_literal("Native", "Api")}\b"""
        ),
        "runtime FFI / dynamic library loading",
    ),
    (
        re.compile(rf"\b{_PR_TARGET_TRIGGER}\b"),
        f"{_PR_TARGET_TRIGGER} workflow trigger",
    ),
    (
        re.compile(
            r"""\bpermissions\s*:\s*['"]?write-all\b|^[ \t]*['"]?write-all['"]?[ \t]*$""",
            re.MULTILINE,
        ),
        "GitHub Actions write-all permissions",
    ),
    (
        re.compile(
            # Quoted arguments may legitimately contain `;`, `&`, or `|`; an
            # unquoted separator ends the download command. Intermediate pipe
            # stages use the same quote-aware segment so quoted transformation
            # expressions remain part of that pipeline without crossing into a
            # later unrelated command.
            rf"{_DOWNLOAD_CLIENT}{_SHELL_COMMAND_SEGMENT}"
            rf"(?:(?<!\|)\|(?!\|){_SHELL_COMMAND_SEGMENT})*"
            rf"(?<!\|)\|(?!\|)[ \t]*\n?[ \t]*"
            rf"{_EXEC_WRAPPER}(?:/\S+/)?(?:sh|bash|zsh|dash|ksh|python3?|perl|ruby|node)\b"
            rf"|\b(?:sh|bash|zsh)\s+<\(\s*{_DOWNLOAD_CLIENT}\b"
            rf"|\b(?:sh|bash|zsh)\s+-c\s+['\"]?\$\(\s*{_DOWNLOAD_CLIENT}\b"
            rf"|\beval\s+.*\$\(\s*{_DOWNLOAD_CLIENT}\b"
        ),
        "download-and-execute shell pattern",
    ),
    (
        # Download-to-file, then run that same file. The backreference is what
        # keeps this precise: fetching a data file and separately running an
        # unrelated local script does not match.
        re.compile(
            _download_to_file(_SH_GAP) + rf"(?:[\s;&|(]{_EXEC_WRAPPER}(?:/\S+/)?"
            rf"(?:sh|bash|zsh|dash|ksh|python3?|perl|ruby|node){_SH_GAP}+"
            # `. f` and `source f` execute the file in the current shell, which
            # is the same capability by a different spelling.
            rf"|(?:^|[\n;&|(]){_SH_GAP}*(?:\.|source){_SH_GAP}+)" + _SAME_TARGET
        ),
        "download-then-execute shell pattern",
    ),
    (
        re.compile(
            _download_to_file(_SH_GAP)
            + rf"[\s;&|(]chmod{_SH_GAP}+\+x{_SH_GAP}+"
            + _SAME_TARGET
            + rf"[\s\S]{{0,2000}}?(?:^|[\n;&|(]){_SH_GAP}*"
            + _SAME_TARGET
        ),
        "download-then-execute shell pattern",
    ),
)


# Downloaded, then marked runnable, but not invoked here. Fetching a tool and
# installing it is a normal packaging step, so this is not the unconditional
# block that running it is — an approval must remain possible. It is still a
# supply-chain event an owner should see.
SENSITIVE_ADDITION_RULES = SENSITIVE_ADDITION_RULES + (
    (
        re.compile(
            _download_to_file(_SH_GAP)
            + rf"[\s;&|(]chmod{_SH_GAP}+\+x{_SH_GAP}+"
            + _SAME_TARGET
        ),
        "downloaded file made executable",
    ),
)


# Addition rules that must not fire on prose. The credential words are ordinary
# English, so matching them in documentation would put every docs PR through
# owner review — exactly the ceremony this guard promises ordinary PRs will not
# face. Code keeps the rule; a sentence explaining how to sign in does not.
_PROSE_PATH = re.compile(r"\.(?:md|markdown|txt|rst|html?|example)$", re.I)

ADDITION_RULE_SKIP_PATHS: dict[str, re.Pattern[str]] = {
    "credential-sensitive logic": _PROSE_PATH,
}

# The few files where a blocked capability is the reviewed design rather than
# an accident. There a match is reported as sensitive instead of blocked: an
# external PR still needs the owner's approval of its exact HEAD, and the same
# construct anywhere else stays blocked. Keyed by the blocked rule's reason;
# keep each pattern as narrow as the design allows.
BLOCKED_RULE_REVIEWED_PATHS: dict[str, re.Pattern[str]] = {
    # The Dart build hook compiles the Rust core by running cargo. A hook has
    # no other way to invoke a native toolchain.
    "runtime process execution": re.compile(r"^hook/build\.dart$"),
    # The Rust core's Dart bindings and their wrapper: FFI is the boundary
    # itself. Direct children only, so a new subdirectory is a new decision.
    "runtime FFI / dynamic library loading": re.compile(
        r"^lib/core/native/[^/]+\.dart$"
    ),
}


class ScannerError(RuntimeError):
    """Raised when the diff cannot be inspected and the scan must fail closed."""


def run_git(*args: str) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            check=True,
            # `--text` renders binary blobs inline, so git's output is not
            # guaranteed to be valid UTF-8, and a pathname may hold any byte at
            # all. surrogateescape keeps those bytes intact and reversible:
            # decoding must not crash on an added image, and must not corrupt a
            # pathname that then has to be handed back to `git show`. "replace"
            # would do exactly that, turning the path into one git cannot find.
            encoding="utf-8",
            errors="surrogateescape",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as error:  # pragma: no cover - environment failure
        raise ScannerError("git executable is not available") from error
    except subprocess.CalledProcessError as error:
        raise ScannerError(
            f"git {' '.join(args)} failed ({error.returncode}): {error.stderr.strip()}"
        ) from error
    return result.stdout


# `git diff` renders the *content* of a diff according to the checked-out
# `.gitattributes`, and quotes unusual pathnames. Both are contributor
# controlled, so pin the rendering explicitly:
#   core.quotePath=false  keep non-ASCII paths literal
#   --text                a `-diff` attribute cannot hide added lines
#   --no-textconv         no attribute-selected content transformation
#   --no-ext-diff         no external diff driver
#   --no-renames          a rename shows both paths and re-adds the content
#   --src-prefix/--dst-prefix   header prefixes are never config dependent
DIFF_FLAGS: tuple[str, ...] = (
    "--no-ext-diff",
    "--no-textconv",
    "--no-renames",
    "--text",
    "--src-prefix=a/",
    "--dst-prefix=b/",
)

GIT_CONFIG_FLAGS: tuple[str, ...] = ("-c", "core.quotePath=false")


_C_ESCAPES = {
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    '"': '"',
    "\\": "\\",
}


def unquote_git_path(value: str) -> str:
    """Decode a C-quoted pathname as emitted by git.

    `core.quotePath=false` stops git escaping non-ASCII bytes, but a path that
    contains a quote, backslash, tab or other control character is still
    wrapped and escaped. Decoding it is what keeps an anchored path rule such
    as `^scripts/` from silently failing to match.
    """

    if len(value) < 2 or not value.startswith('"') or not value.endswith('"'):
        return value

    body = value[1:-1]
    decoded = bytearray()
    index = 0
    while index < len(body):
        char = body[index]
        if char != "\\":
            decoded.extend(char.encode("utf-8"))
            index += 1
            continue
        index += 1
        if index >= len(body):
            break
        escape = body[index]
        if escape in _C_ESCAPES:
            decoded.extend(_C_ESCAPES[escape].encode("utf-8"))
            index += 1
        elif escape in "01234567" and len(body) - index >= 3:
            decoded.append(int(body[index : index + 3], 8) & 0xFF)
            index += 3
        else:
            decoded.extend(escape.encode("utf-8"))
            index += 1
    return decoded.decode("utf-8", "surrogateescape")


def changed_files(base: str, head: str) -> list[str]:
    output = run_git(
        *GIT_CONFIG_FLAGS,
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        f"{base}...{head}",
        "--",
    )
    # -z keeps pathnames raw, so no unquoting is needed here.
    return [path for path in output.split("\0") if path]


# Destination of a `+++ /dev/null` header: the file is gone at head. Distinct
# from None, which means the header could not be parsed at all — one is an
# ordinary deletion, the other is a reason to stop and ask for a human.
DELETED = "\0deleted"


def _header_path(rest: str) -> str | None:
    """Resolve the destination path from a `+++ ` diff header."""

    path = unquote_git_path(rest.strip())
    if path == "/dev/null":
        return DELETED
    if path.startswith("b/"):
        return path[2:]
    return None


@dataclass(frozen=True)
class ChangedSource:
    """A changed file's post-change text plus the lines this PR added to it."""

    path: str
    text: str
    added_lines: frozenset[int]
    suppression_removed: bool


# Lines whose removal can make neighbouring code live without that code being
# retyped: block and markup comment delimiters, a disabled preprocessor branch,
# a `false` guard. This is the signal the sensitive tier watches, in place of a
# net line count.
#
# Net loss was too weak — replacing `/*` with a blank line loses nothing — and
# "any removed line" is far too strong, since a one-for-one edit removes its old
# line and 216 files carry a sensitive match. Looking at what was removed is
# both narrower and more complete than either.
_SUPPRESSION_REMOVED = re.compile(
    r"^\s*(?:/\*+|\*+/|<!--|-->|#\s*if\s+0\b|#\s*endif\b"
    r"|(?:\}\s*)?if\s*\(\s*false\s*\)\s*\{?)\s*$"
)

_HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def added_line_numbers(base: str, head: str) -> dict[str, tuple[set[int], bool]]:
    """Map each path still at head to the lines it gained, and whether the PR
    removed a line that had been suppressing code.

    Added text is taken from the file's post-change blob rather than from the
    diff, which is why `--text` matters here: without it a `.gitattributes`
    `-diff` entry would suppress the hunk headers too. Removed lines have no
    post-change counterpart, so they are read here for their content alone.
    """

    diff = run_git(
        *GIT_CONFIG_FLAGS,
        "diff",
        "--unified=0",
        *DIFF_FLAGS,
        f"{base}...{head}",
        "--",
    )

    added: dict[str, tuple[set[int], bool]] = {}
    current_path: str | None = None
    seen_header = False
    in_hunk = False

    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            current_path = None
            seen_header = False
            in_hunk = False
            continue
        if line.startswith("+++ ") and not seen_header:
            current_path = _header_path(line[4:])
            seen_header = True
            continue

        match = _HUNK.match(line)
        if match is None:
            # Removed lines are read for their content only; they do not exist
            # in the post-change file and so have no line number to record.
            if (
                in_hunk
                and line.startswith("-")
                and current_path not in (None, DELETED)
                and _SUPPRESSION_REMOVED.match(line[1:])
            ):
                path = current_path or UNKNOWN_PATH
                lines, _ = added.setdefault(path, (set(), False))
                added[path] = (lines, True)
            continue

        seen_header = True
        in_hunk = True
        start = int(match.group(2))
        count = 1 if match.group(3) is None else int(match.group(3))

        if current_path == DELETED:
            # The whole file is gone at head. There is no post-change content to
            # scan, and changed_files() still classifies the path it had.
            continue

        path = current_path or UNKNOWN_PATH
        lines, suppression_removed = added.setdefault(path, (set(), False))
        if count:
            lines.update(range(start, start + count))
        added[path] = (lines, suppression_removed)

    return added


def file_text(head: str, path: str) -> str | None:
    """Post-change content of `path`, or None if the PR deleted it.

    Read as a blob rather than out of the diff: blob output is not affected by
    any `.gitattributes` the PR ships, and it carries the untouched context that
    a blocked construct may have been completed from.
    """

    try:
        return run_git(*GIT_CONFIG_FLAGS, "show", f"{head}:{path}")
    except ScannerError:
        return None


def changed_sources(base: str, head: str) -> tuple[list[ChangedSource], bool]:
    """Post-change text for every file this PR added lines to.

    Returns the sources and whether any hunk could not be attributed to a path.
    """

    sources: list[ChangedSource] = []
    unresolved = False

    for path, (lines, suppression_removed) in added_line_numbers(base, head).items():
        if path == UNKNOWN_PATH:
            unresolved = True
            continue
        text = file_text(head, path)
        if text is None:
            # This path changed, so its post-change blob must exist. If it
            # cannot be read then the diff and the tree disagree, and skipping
            # the file would silently drop it from the scan.
            raise ScannerError(
                f"{path!r} changed but has no readable content at {head}"
            )
        sources.append(ChangedSource(path, text, frozenset(lines), suppression_removed))

    return sources, unresolved


def _line_index(text: str) -> list[int]:
    """Offset at which each 1-based line starts."""

    offsets = [0]
    for index, char in enumerate(text):
        if char == "\n":
            offsets.append(index + 1)
    return offsets


def touches_added_lines(
    offsets: list[int], added: frozenset[int], start: int, end: int
) -> bool:
    """Does a match spanning [start, end) overlap a line this PR added?

    This is what lets the scanner read whole post-change files without
    punishing code the PR never touched: a construct already present in an
    untouched region matches, but does not count. It also catches the reverse
    case, where a PR completes a blocked construct out of existing tokens — the
    match then spans the added fragment and is reported.
    """

    first = bisect.bisect_right(offsets, start)
    last = bisect.bisect_right(offsets, max(start, end - 1))
    return any(line in added for line in range(first, last + 1))


def dedupe(findings: list[Finding]) -> list[Finding]:
    seen: set[tuple[str, str]] = set()
    result: list[Finding] = []
    for finding in findings:
        key = (finding.path, finding.reason)
        if key not in seen:
            seen.add(key)
            result.append(finding)
    return result


def classify(
    files: list[str],
    sources: list[ChangedSource],
    unresolved_paths: bool = False,
) -> tuple[list[Finding], list[Finding]]:
    sensitive: list[Finding] = []
    blocked: list[Finding] = []

    for path in files:
        for pattern, reason in SENSITIVE_PATH_RULES:
            if pattern.search(path):
                sensitive.append(Finding(path, reason))

    if unresolved_paths:
        sensitive.append(
            Finding(UNKNOWN_PATH, "diff header could not be decoded; review manually")
        )

    for source in sources:
        offsets = _line_index(source.text)
        is_prose = bool(_PROSE_PATH.search(source.path))
        for rules, sink in (
            (SENSITIVE_ADDITION_RULES, sensitive),
            (BLOCKED_ADDITION_RULES, blocked),
        ):
            for pattern, reason in rules:
                skip = ADDITION_RULE_SKIP_PATHS.get(reason)
                if skip is not None and skip.search(source.path):
                    continue

                # A capability rule matching a documentation or plain-text file
                # has found the name of a capability, not the capability: a page
                # explaining which APIs are forbidden necessarily writes them
                # down. Downgrade rather than drop, because a README telling a
                # reader to pipe a download into a shell is still worth an
                # owner's eyes — it just must not be an unclearable block.
                reviewed = BLOCKED_RULE_REVIEWED_PATHS.get(reason)
                if rules is BLOCKED_ADDITION_RULES and is_prose:
                    hit_sink, hit_reason = sensitive, f"textual reference to {reason}"
                elif (
                    rules is BLOCKED_ADDITION_RULES
                    and reviewed is not None
                    and reviewed.search(source.path)
                ):
                    hit_sink, hit_reason = (
                        sensitive,
                        f"{reason} in its reviewed location",
                    )
                else:
                    hit_sink, hit_reason = sink, reason

                elsewhere = False
                for match in pattern.finditer(source.text):
                    if touches_added_lines(
                        offsets, source.added_lines, match.start(), match.end()
                    ):
                        hit_sink.append(Finding(source.path, hit_reason))
                        break
                    elsewhere = True
                else:
                    # The construct is in the file, but on lines this PR left
                    # alone. That is usually grandfathered code and no concern —
                    # except that a change elsewhere in the file can make it
                    # live without retyping it. Deleting a comment opener does
                    # that; so does flipping `if (false)` to `if (true)`, which
                    # loses no lines at all. Rather than trying to enumerate the
                    # ways (a regex cannot decide reachability), any change to a
                    # file that still holds a blocked construct asks for a
                    # maintainer. Eight files in this repository qualify.
                    if not elsewhere:
                        continue
                    if hit_sink is blocked:
                        # Only eight files in the repository hold one of these,
                        # so any change to one can afford to ask.
                        sensitive.append(
                            Finding(
                                source.path,
                                f"change to a file containing existing {hit_reason}",
                            )
                        )
                    elif source.suppression_removed:
                        # The sensitive patterns are far broader — 356 files
                        # carry one. Asking on every edit to any of them would
                        # make the ordinary UI/tests/docs PR a reviewed PR,
                        # which is the one thing this guard must not do. So the
                        # signal here is narrow and specific: the PR removed a
                        # line that had been suppressing code. An edit that
                        # activates without removing such a line is not caught,
                        # and is accepted — this tier gates review, not merge.
                        sensitive.append(
                            Finding(
                                source.path,
                                f"removed suppression may activate existing {hit_reason}",
                            )
                        )

    return dedupe(sensitive), dedupe(blocked)


def write_report(
    report_path: Path,
    files: list[str],
    sensitive: list[Finding],
    blocked: list[Finding],
) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    # backslashreplace: a pathname byte that is not valid UTF-8 survives as a
    # surrogate in `path`, and must render readably here rather than raising.
    with report_path.open("w", encoding="utf-8", errors="backslashreplace") as report:
        report.write("## PR security surface scan\n\n")
        report.write(f"Changed files: **{len(files)}**\n\n")
        if blocked:
            report.write("### Blocked high-risk additions\n\n")
            for finding in blocked:
                report.write(f"- `{finding.path}` — {finding.reason}\n")
            report.write(
                "\nThese patterns require redesign or a separate maintainer-controlled implementation; an approval does not bypass them.\n\n"
            )
        if sensitive:
            report.write("### Sensitive surfaces requiring maintainer review\n\n")
            for finding in sensitive:
                report.write(f"- `{finding.path}` — {finding.reason}\n")
        else:
            report.write(
                "No security-sensitive trust boundary was detected in this diff.\n"
            )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    # Findings may carry a pathname that is not valid UTF-8; print it rather
    # than dying on it.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(errors="backslashreplace")

    try:
        files = changed_files(args.base, args.head)
        sources, unresolved_paths = changed_sources(args.base, args.head)
    except ScannerError as error:
        print(
            f"::error::PR security surface scan could not inspect the diff: {error}",
            file=sys.stderr,
        )
        return 2

    sensitive, blocked = classify(files, sources, unresolved_paths)

    write_report(Path(args.report), files, sensitive, blocked)

    if args.github_output:
        with open(
            args.github_output, "a", encoding="utf-8", errors="backslashreplace"
        ) as output:
            output.write(f"sensitive={'true' if sensitive else 'false'}\n")
            output.write(f"blocked={'true' if blocked else 'false'}\n")

    if blocked:
        print("PR security scan blocked high-risk additions:")
        for finding in blocked:
            print(f"  {finding.path}: {finding.reason}")
        return 1

    if sensitive:
        print("Security-sensitive PR surface detected; maintainer review required.")
    else:
        print("PR security surface scan passed: ordinary-risk diff.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
