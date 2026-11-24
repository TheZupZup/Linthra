#!/usr/bin/env python3
"""Fail when an APK ships an ABI without the Rust core.

hook/build.dart skips the Rust core (native/linthra_core) when the build
machine lacks Rust or the Android target, and the app still builds: it falls
back to Dart. That is right for a contributor's machine and wrong for a
release, so the release workflows run this on every APK they build. An ABI is
any `lib/<abi>/` that carries Flutter's engine (`libflutter.so`); each one must
carry `liblinthra_core.so` too.

Usage: check_apk_rust_core.py APK [APK ...]
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

ENGINE = "libflutter.so"
CORE = "liblinthra_core.so"


def missing_abis(apk: Path) -> tuple[list[str], list[str]]:
    """The ABIs in [apk], and those of them that lack the Rust core."""
    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
    abis = sorted(
        name.split("/")[1]
        for name in names
        if name.startswith("lib/") and name.endswith("/" + ENGINE)
    )
    missing = [abi for abi in abis if "lib/{}/{}".format(abi, CORE) not in names]
    return abis, missing


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    failed = False
    for arg in argv:
        apk = Path(arg)
        abis, missing = missing_abis(apk)
        if not abis:
            print("{}: no Flutter engine found in lib/".format(apk), file=sys.stderr)
            failed = True
        elif missing:
            print(
                "{}: no {} for {}. Is the Rust toolchain from .rust-version "
                "installed with the Android targets?".format(
                    apk, CORE, ", ".join(missing)
                ),
                file=sys.stderr,
            )
            failed = True
        else:
            print("{}: Rust core present for {}".format(apk, ", ".join(abis)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
