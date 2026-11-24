"""Tests for scripts/check_apk_rust_core.py."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_apk_rust_core", ROOT / "scripts" / "check_apk_rust_core.py"
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class CheckApkRustCoreTest(unittest.TestCase):
    def apk(self, *names: str) -> Path:
        folder = Path(tempfile.mkdtemp())
        path = folder / "app.apk"
        with zipfile.ZipFile(path, "w") as archive:
            for name in names:
                archive.writestr(name, b"")
        return path

    def test_passes_when_every_abi_has_the_core(self) -> None:
        apk = self.apk(
            "lib/arm64-v8a/libflutter.so",
            "lib/arm64-v8a/liblinthra_core.so",
            "lib/x86_64/libflutter.so",
            "lib/x86_64/liblinthra_core.so",
        )
        self.assertEqual(check.main([str(apk)]), 0)

    def test_fails_when_one_abi_lacks_the_core(self) -> None:
        apk = self.apk(
            "lib/arm64-v8a/libflutter.so",
            "lib/arm64-v8a/liblinthra_core.so",
            "lib/armeabi-v7a/libflutter.so",
        )
        self.assertEqual(
            check.missing_abis(apk),
            (["arm64-v8a", "armeabi-v7a"], ["armeabi-v7a"]),
        )
        self.assertEqual(check.main([str(apk)]), 1)

    def test_fails_without_a_flutter_engine(self) -> None:
        apk = self.apk("classes.dex")
        self.assertEqual(check.main([str(apk)]), 1)

    def test_a_split_apk_checks_its_own_abi(self) -> None:
        apk = self.apk(
            "lib/armeabi-v7a/libflutter.so",
            "lib/armeabi-v7a/liblinthra_core.so",
        )
        self.assertEqual(check.main([str(apk)]), 0)


if __name__ == "__main__":
    unittest.main()
