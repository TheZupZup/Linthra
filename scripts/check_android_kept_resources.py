#!/usr/bin/env python3
"""Check that a built APK or AAB still has every resource keep.xml keeps.

The release resource shrinker removes what it can't see the code use, and
some resources are only ever looked up by name at runtime: audio_service
resolves every media notification and session icon with
Resources.getIdentifier. Since AGP 9 the shrinker dropped those icons, and on
Android 13+ the media session then never started its foreground service, so
music stopped once the screen went off (v0.2.10). They are listed under
tools:keep in android/app/src/main/res/raw/keep.xml; this reads each built
artifact back with the SDK's aapt2 and fails unless every resource on that list
is really in it.

    python3 scripts/check_android_kept_resources.py \\
        --keep android/app/src/main/res/raw/keep.xml \\
        build/app/outputs/bundle/release/app-release.aab

An AAB's base module is converted to a binary APK first, the same way
check_android_target_sdk.py does it. Exits non-zero if aapt2 is missing (it
never skips), if an artifact or keep.xml can't be read, or if a kept resource
is missing.
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
# The aapt2 lookup and the AAB repackaging live in check_android_target_sdk.py.
# Python only guarantees the script's own directory is importable when the
# script is run directly, so make it so for the imported case too.
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from check_android_target_sdk import (  # noqa: E402
    CheckError,
    find_aapt2,
    proto_apk_from_bundle,
    run,
)

TOOLS_KEEP = re.compile(r'tools:keep="([^"]*)"')
# `aapt2 dump resources` names each entry on a line of its own, as in
# "resource 0x7f07005c drawable/audio_service_stop", sometimes with the
# package in front of the type.
RESOURCE_LINE = re.compile(
    r"^\s*resource 0x[0-9a-fA-F]+ (?:[\w.]+:)?(\S+)", re.MULTILINE
)


def kept_resources(keep_xml: str) -> list[str]:
    """The `type/name` patterns a keep.xml lists under tools:keep."""
    match = TOOLS_KEEP.search(keep_xml)
    if match is None:
        raise CheckError("keep.xml has no tools:keep list.")
    kept = [entry.strip().lstrip("@") for entry in match.group(1).split(",")]
    return [entry for entry in kept if entry]


def resources_in(dump: str) -> set[str]:
    """The `type/name` of every resource an `aapt2 dump resources` lists."""
    return set(RESOURCE_LINE.findall(dump))


def dump_resources(aapt2: Path, artifact: Path) -> str:
    if not artifact.is_file():
        raise CheckError(f"{artifact} does not exist.")
    if artifact.suffix != ".aab":
        return run([str(aapt2), "dump", "resources", str(artifact)])
    with tempfile.TemporaryDirectory() as tmp:
        proto = Path(tmp) / "base-proto.apk"
        binary = Path(tmp) / "base-binary.apk"
        proto_apk_from_bundle(artifact, proto)
        run(
            [
                str(aapt2),
                "convert",
                "--output-format",
                "binary",
                "-o",
                str(binary),
                str(proto),
            ]
        )
        return run([str(aapt2), "dump", "resources", str(binary)])


def missing_from(aapt2: Path, artifact: Path, kept: list[str]) -> list[str]:
    """The kept patterns no resource in [artifact] matches."""
    present = resources_in(dump_resources(aapt2, artifact))
    if not present:
        raise CheckError(f"aapt2 listed no resources for {artifact}.")
    return [pattern for pattern in kept if not fnmatch.filter(present, pattern)]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--keep",
        type=Path,
        required=True,
        help="the res/raw/keep.xml the artifacts were built from",
    )
    parser.add_argument("artifacts", nargs="+", type=Path)
    args = parser.parse_args(argv)

    try:
        kept = kept_resources(args.keep.read_text(encoding="utf-8"))
        aapt2 = find_aapt2(
            os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        )
        print(f"Using {aapt2}")
        failed = False
        for artifact in args.artifacts:
            missing = missing_from(aapt2, artifact, kept)
            if missing:
                print(f"FAIL: {artifact} is missing {', '.join(missing)}")
                failed = True
            else:
                print(f"OK: {artifact} has all {len(kept)} kept resources")
    except (CheckError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
