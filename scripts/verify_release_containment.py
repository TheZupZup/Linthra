#!/usr/bin/env python3
"""Checks a built artifact for the Cast security containment.

Casting is withheld from shipped builds while a reported security issue is
resolved (see lib/core/services/cast/cast_containment.dart and docs/cast.md).
`scripts/check_cast_containment.py` looks at the *source tree*; this script looks
at the *artifact a user installs* — an APK, an AAB, the Linux tarball, or the
Linux `.flatpak` bundle — and asks whether the compiled Dart in it looks like a
contained build.

It reads every Dart AOT payload in the artifact (`libapp.so`) and looks for
three things:

  * the containment message, exactly as `CastContainment.userMessage` spells it
    in this checkout. The message is a compile-time constant reached only
    through the contained production wiring, so it is compiled into the snapshot
    when containment holds and folded away when it does not;
  * `UnavailableCastService`, the service the contained wiring binds; and
  * the absence of `DefaultCastService`, `ChromecastCastTransport`, and the Cast
    protocol namespaces the live transport talks — none of which survive tree
    shaking when nothing constructs them.

WHAT THIS IS NOT
----------------
This is NOT a proof that the binary cannot cast, and it must not be described as
one. It is a byte search over a compiled snapshot, so what it really reports is
"this artifact was built from a tree whose containment constants were still
reachable, and carries none of the live-cast strings we know to look for". It
cannot see:

  * a bypass that keeps every string in place — a second cast implementation
    under a different name, a live path reached through code this script has no
    string for, or a receiver socket opened from platform code rather than Dart;
  * anything outside the Dart snapshot: platform channels, native libraries,
    the Android manifest, or a plugin's own Java/Kotlin;
  * whether the absent strings are absent because the code is gone or because
    the compiler happened to store them differently in this build.

WHAT IS THE EVIDENCE
--------------------
The same evidence as ever: `test/app/production_cast_containment_test.dart` and
`test/core/services/cast/cast_containment_test.dart` drive the real production
wiring and the transport at runtime, at the commit the artifact is built from.
This script adds one thing those cannot — it is run against the file that is
actually distributed, so a release whose artifacts were built from some other
tree does not pass quietly. Treat a green run as "the markers we know to look
for are as expected in the shipped bytes", and a red one as a question to answer
before publishing.

Ambiguity fails closed. An artifact with no readable Dart payload, a message
this script cannot parse out of the Dart source, an unknown file type, or an
unreadable archive all exit non-zero rather than reporting success.

Usage:

    python3 scripts/verify_release_containment.py dist/*.apk dist/*.aab
    python3 scripts/verify_release_containment.py --json report.json build/*.tar.gz
    python3 scripts/verify_release_containment.py Linthra-v0.2.7-x86_64.flatpak
    python3 .../verify_release_containment.py \
        --containment-source lib/core/services/cast/cast_containment.dart *.apk

Every artifact's SHA-256 is printed (and written to `--json`) so a release can
record exactly which bytes were checked.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
CONTAINMENT_SOURCE = REPO_ROOT / "lib/core/services/cast/cast_containment.dart"

# scripts/flatpak_bundle.py is imported lazily (only for a .flatpak artifact),
# the same way check_release_metadata_sync.py imports prepare_release_bump.
# Python only guarantees the script's own directory is importable when the
# script is run directly, so make it so for the imported case too.
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

# The expected message must come from the tree the artifact was BUILT from, which
# is not always the tree this script lives in: a release build checks out the tag
# it is building, while the workflow (and this script with it) comes from the
# revision that runs. `--containment-source` is how that caller says so.

# The compiled Dart snapshot inside every Flutter release artifact. Android puts
# one per ABI under lib/<abi>/ (an AAB nests that under base/), the Linux bundle
# ships a single one next to the other bundled libraries, and the Flatpak ships
# that same bundle under /app/lib/linthra/lib/.
AOT_PAYLOAD = "libapp.so"

# Strings that must be in a contained build's snapshot.
REQUIRED_MARKERS = ("UnavailableCastService",)

# Strings a contained build must NOT have. Each one exists only in the live cast
# path, which nothing constructs while containment holds, so tree shaking drops
# them along with the code.
FORBIDDEN_MARKERS = (
    "DefaultCastService",
    "ChromecastCastTransport",
    "urn:x-cast:com.google.cast.media",
    "urn:x-cast:com.google.cast.receiver",
)


class VerificationError(Exception):
    """A reason this script cannot report success. Always fatal."""


def containment_message(source: Path) -> str:
    """Reads `CastContainment.userMessage` out of the Dart source.

    Taking the expected string from the checkout rather than hard-coding it here
    means editing the user-facing copy cannot silently turn this check into a
    search for a string nothing says any more. A message this cannot parse is an
    error, not a fallback.
    """
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise VerificationError(f"cannot read {source}: {error}") from error

    match = re.search(r"static const String userMessage\s*=\s*(.*?);", text, re.DOTALL)
    if match is None:
        raise VerificationError(
            f"no `static const String userMessage` in {source}; this script "
            "cannot tell what a contained build should say."
        )

    # The literal is written as adjacent single-quoted parts across several
    # lines; Dart concatenates them, so join them in the same order.
    parts = re.findall(r"'([^']*)'", match.group(1))
    if not parts:
        raise VerificationError(f"could not parse the userMessage literal in {source}.")
    return "".join(parts)


def encodings_of(marker: str) -> list[bytes]:
    """Both ways Dart stores a string literal in an AOT snapshot.

    Latin-1-representable literals are stored one byte per code unit; anything
    with a wider character (the containment message has an em dash) is stored as
    UTF-16. Searching for both keeps the check working whichever way the copy is
    written.
    """
    candidates = [marker.encode("utf-16-le")]
    try:
        candidates.append(marker.encode("latin-1"))
    except UnicodeEncodeError:
        pass
    return candidates


def contains(blob: bytes, marker: str) -> bool:
    return any(encoded in blob for encoded in encodings_of(marker))


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def aot_payloads(path: Path) -> dict[str, bytes]:
    """Every Dart AOT payload in the artifact, keyed by its path inside it."""
    suffixes = "".join(path.suffixes[-2:])
    if path.suffix in {".apk", ".aab", ".zip"}:
        return _zip_payloads(path)
    if suffixes in {".tar.gz", ".tar.xz"} or path.suffix == ".tgz":
        return _tar_payloads(path)
    if path.suffix == ".flatpak":
        return _flatpak_payloads(path)
    raise VerificationError(
        f"{path.name}: unknown artifact type; this script reads .apk, .aab, the "
        "Linux .tar.gz and the Linux .flatpak bundle."
    )


def _zip_payloads(path: Path) -> dict[str, bytes]:
    try:
        with zipfile.ZipFile(path) as archive:
            names = [
                name
                for name in archive.namelist()
                if name.rsplit("/", 1)[-1] == AOT_PAYLOAD
            ]
            return {name: archive.read(name) for name in names}
    except (OSError, zipfile.BadZipFile) as error:
        raise VerificationError(f"cannot read {path.name}: {error}") from error


def _tar_payloads(path: Path) -> dict[str, bytes]:
    payloads: dict[str, bytes] = {}
    try:
        with tarfile.open(path, "r:*") as archive:
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                if member.name.rsplit("/", 1)[-1] != AOT_PAYLOAD:
                    continue
                handle = archive.extractfile(member)
                if handle is None:
                    raise VerificationError(f"{path.name}: cannot read {member.name}.")
                payloads[member.name] = handle.read()
    except (OSError, tarfile.TarError) as error:
        raise VerificationError(f"cannot read {path.name}: {error}") from error
    return payloads


def _flatpak_payloads(path: Path) -> dict[str, bytes]:
    """The payloads inside a `.flatpak`, read out of the bundle itself.

    A bundle is an OSTree static delta, not an archive Python can open, so this
    unpacks it with the same extractor scripts/flatpak_bundle.py uses for its
    own packaging checks — one way of opening a bundle, shared by both. Nothing
    is installed and no existing Flatpak installation is read or changed.

    A missing `flatpak`/`ostree` is an error, not a skip: the caller asked for
    this artifact to be verified, and a check that cannot run has not passed.
    """
    try:
        from flatpak_bundle import BundleError, extract_bundle
    except ImportError as error:  # pragma: no cover - packaging accident
        raise VerificationError(
            f"{path.name}: scripts/flatpak_bundle.py is not importable, so this "
            f"script cannot open a Flatpak bundle: {error}"
        ) from error

    payloads: dict[str, bytes] = {}
    with tempfile.TemporaryDirectory(prefix="linthra-containment-") as scratch:
        tree = Path(scratch) / "tree"
        try:
            extract_bundle(path, tree)
        except BundleError as error:
            raise VerificationError(f"cannot read {path.name}: {error}") from error
        for payload in sorted(tree.rglob(AOT_PAYLOAD)):
            if payload.is_file():
                payloads[str(payload.relative_to(tree))] = payload.read_bytes()
    return payloads


def verify_artifact(path: Path, message: str) -> dict[str, object]:
    """Checks one artifact and returns what was found. Raises on any failure."""
    if not path.is_file():
        raise VerificationError(f"{path}: not a file.")

    payloads = aot_payloads(path)
    if not payloads:
        raise VerificationError(
            f"{path.name}: no {AOT_PAYLOAD} inside, so there is no compiled "
            "Dart to check. Failing closed rather than reporting a pass."
        )

    problems: list[str] = []
    for name, blob in sorted(payloads.items()):
        if not contains(blob, message):
            problems.append(
                f"{name}: the containment message is missing, so this payload "
                "was not built from a contained tree."
            )
        for marker in REQUIRED_MARKERS:
            if not contains(blob, marker):
                problems.append(f"{name}: expected marker {marker!r} is missing.")
        for marker in FORBIDDEN_MARKERS:
            if contains(blob, marker):
                problems.append(
                    f"{name}: live-cast marker {marker!r} is present; this "
                    "artifact carries the cast path containment removes."
                )

    if problems:
        raise VerificationError(f"{path.name}:\n  - " + "\n  - ".join(problems))

    return {
        "artifact": path.name,
        "bytes": path.stat().st_size,
        "sha256": sha256_of(path),
        "payloads": sorted(payloads),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Verify the Cast containment in built release artifacts."
    )
    parser.add_argument("artifacts", nargs="+", type=Path)
    parser.add_argument(
        "--containment-source",
        type=Path,
        default=CONTAINMENT_SOURCE,
        help=(
            "cast_containment.dart of the tree the artifacts were built from "
            "(default: this checkout's). The expected message is read from it."
        ),
    )
    parser.add_argument(
        "--json",
        type=Path,
        help="Write the per-artifact record (name, size, SHA-256) here.",
    )
    args = parser.parse_args(argv)

    try:
        message = containment_message(args.containment_source)
    except VerificationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    records: list[dict[str, object]] = []
    failures = 0
    for artifact in args.artifacts:
        try:
            record = verify_artifact(artifact, message)
        except VerificationError as error:
            print(f"FAIL {error}", file=sys.stderr)
            failures += 1
            continue
        records.append(record)
        print(f"OK   {record['artifact']}  sha256={record['sha256']}")
        for payload in record["payloads"]:
            print(f"       contained: {payload}")

    if args.json and records:
        args.json.write_text(
            json.dumps(records, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    if failures:
        print(
            f"\n{failures} artifact(s) did not verify. Do not publish them.",
            file=sys.stderr,
        )
        return 1

    print(f"\nVerified {len(records)} artifact(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
