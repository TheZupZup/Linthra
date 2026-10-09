#!/usr/bin/env python3
"""Check the SDK levels a built APK or AAB really declares.

Linthra sets targetSdk in android/app/build.gradle, but what Google Play and
Android act on is the manifest inside the artifact. This reads it back from the
artifact itself with the Android SDK's own aapt2, so a build that lost the
setting somewhere (a plugin, a merge, a Flutter default) fails here instead of
at upload time.

    python3 scripts/check_android_target_sdk.py --target 37 --min 24 \\
        build/app/outputs/flutter-apk/app-release.apk \\
        build/app/outputs/bundle/release/app-release.aab

An APK is read directly. An AAB keeps its manifest in protobuf form under
base/, so its base module is repackaged as a proto APK and converted to the
binary form with `aapt2 convert` first. Nothing is downloaded; aapt2 comes from
$ANDROID_HOME/build-tools. Exits non-zero if aapt2 is missing (it never skips),
if an artifact can't be read, or if a level differs from what was asked for.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# `dump badging` names the minimum "sdkVersion" (aapt) or "minSdkVersion"
# (newer aapt2); `dump xmltree` prints the manifest attributes themselves.
BADGING_MIN = re.compile(r"^\s*(?:sdkVersion|minSdkVersion):'(\d+)'", re.MULTILINE)
BADGING_TARGET = re.compile(r"^\s*targetSdkVersion:'(\d+)'", re.MULTILINE)
XMLTREE_LEVEL = re.compile(
    r"android:(minSdkVersion|targetSdkVersion)\(0x[0-9a-fA-F]+\)=(\d+)"
)


class CheckError(Exception):
    pass


def _version_key(name: str) -> list[tuple[int, int | str]]:
    """Orders build-tools directory names numerically ("36.0.0" > "9.0.0")."""
    return [
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.split(r"[.-]", name)
    ]


def find_aapt2(sdk_root: str | None) -> Path:
    """The newest aapt2 under the SDK's build-tools."""
    if not sdk_root:
        raise CheckError("ANDROID_HOME / ANDROID_SDK_ROOT is not set; aapt2 is needed.")
    build_tools = Path(sdk_root) / "build-tools"
    found = sorted(
        build_tools.glob("*/aapt2"), key=lambda p: _version_key(p.parent.name)
    )
    if not found:
        raise CheckError(f"no aapt2 under {build_tools}.")
    return found[-1]


def parse_levels(badging: str) -> dict[str, int]:
    """minSdk and targetSdk from `aapt2 dump badging` output."""
    min_sdk = BADGING_MIN.search(badging)
    target = BADGING_TARGET.search(badging)
    if min_sdk is None or target is None:
        raise CheckError("aapt2 badging did not report the SDK levels.")
    return {"min": int(min_sdk.group(1)), "target": int(target.group(1))}


def parse_xmltree_levels(xmltree: str) -> dict[str, int]:
    """minSdk and targetSdk from `aapt2 dump xmltree` of AndroidManifest.xml."""
    levels = {name: int(value) for name, value in XMLTREE_LEVEL.findall(xmltree)}
    if "minSdkVersion" not in levels or "targetSdkVersion" not in levels:
        raise CheckError("the manifest's uses-sdk carries no numeric SDK levels.")
    return {"min": levels["minSdkVersion"], "target": levels["targetSdkVersion"]}


def _excerpt(text: str) -> str:
    lines = [line for line in text.splitlines() if "Sdk" in line or "sdk" in line]
    return "; ".join(lines[:6]) or "(nothing about SDK levels)"


def levels_of_apk(aapt2: Path, apk: Path) -> dict[str, int]:
    """Reads the levels from badging, or from the manifest tree if badging
    words them in a way this does not know."""
    badging = run([str(aapt2), "dump", "badging", str(apk)])
    try:
        return parse_levels(badging)
    except CheckError:
        pass
    xmltree = run(
        [str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)]
    )
    try:
        return parse_xmltree_levels(xmltree)
    except CheckError as error:
        raise CheckError(
            f"{error} badging: {_excerpt(badging)} | xmltree: {_excerpt(xmltree)}"
        ) from None


def proto_apk_from_bundle(aab: Path, out: Path) -> None:
    """Repackages an AAB's base module as a proto-format APK aapt2 can read."""
    with zipfile.ZipFile(aab) as bundle:
        names = bundle.namelist()
        if "base/manifest/AndroidManifest.xml" not in names:
            raise CheckError(f"{aab} has no base/manifest/AndroidManifest.xml.")
        with zipfile.ZipFile(out, "w") as apk:
            apk.writestr(
                "AndroidManifest.xml", bundle.read("base/manifest/AndroidManifest.xml")
            )
            if "base/resources.pb" in names:
                apk.writestr("resources.pb", bundle.read("base/resources.pb"))
            for name in names:
                if name.startswith("base/res/") and not name.endswith("/"):
                    apk.writestr(name[len("base/") :], bundle.read(name))


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise CheckError(
            f"{' '.join(cmd)} failed: {result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout


def levels_of(aapt2: Path, artifact: Path) -> dict[str, int]:
    if not artifact.is_file():
        raise CheckError(f"{artifact} does not exist.")
    if artifact.suffix == ".aab":
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
            return levels_of_apk(aapt2, binary)
    return levels_of_apk(aapt2, artifact)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--target", type=int, required=True, help="expected targetSdkVersion"
    )
    parser.add_argument(
        "--min", type=int, help="expected minSdkVersion (not checked when omitted)"
    )
    parser.add_argument("artifacts", nargs="+", type=Path)
    args = parser.parse_args(argv)

    try:
        aapt2 = find_aapt2(
            os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        )
        print(f"Using {aapt2}")
        failed = False
        for artifact in args.artifacts:
            levels = levels_of(aapt2, artifact)
            ok = levels["target"] == args.target and args.min in (None, levels["min"])
            expected_min = "any" if args.min is None else args.min
            print(
                f"{'OK' if ok else 'FAIL'}: {artifact} minSdk={levels['min']} "
                f"targetSdk={levels['target']} "
                f"(expected {expected_min} / {args.target})"
            )
            failed = failed or not ok
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
