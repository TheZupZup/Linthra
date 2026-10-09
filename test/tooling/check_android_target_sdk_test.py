#!/usr/bin/env python3
"""Tests for scripts/check_android_target_sdk.py.

A stub aapt2 stands in for the SDK's: `dump badging` prints the artifact's
AndroidManifest.xml member as if it were badging output, and `convert` copies
the proto APK it is given. That is enough to drive the APK path, the AAB
repackaging path and every refusal offline, with no Android SDK.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

spec = importlib.util.spec_from_file_location(
    "check_android_target_sdk", ROOT / "scripts" / "check_android_target_sdk.py"
)
assert spec is not None and spec.loader is not None
checker = importlib.util.module_from_spec(spec)
sys.modules["check_android_target_sdk"] = checker
spec.loader.exec_module(checker)

STUB_AAPT2 = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import shutil, sys, zipfile
    args = sys.argv[1:]
    def member(path, name):
        with zipfile.ZipFile(path) as apk:
            return apk.read(name).decode() if name in apk.namelist() else ""
    if args[:2] == ["dump", "badging"]:
        sys.stdout.write(member(args[2], "AndroidManifest.xml"))
        sys.exit(0)
    if args[:2] == ["dump", "xmltree"]:
        sys.stdout.write(member(args[-1], "xmltree.txt"))
        sys.exit(0)
    if args[0] == "convert":
        out = args[args.index("-o") + 1]
        with zipfile.ZipFile(args[-1]) as apk:
            if "AndroidManifest.xml" not in apk.namelist():
                sys.exit("no manifest")
        shutil.copy(args[-1], out)
        sys.exit(0)
    sys.exit("unexpected: " + " ".join(args))
    """
)


def badging(min_sdk: int, target: int) -> str:
    return (
        "package: name='io.github.thezupzup.linthra' versionCode='210999' "
        "versionName='0.2.10'\n"
        f"sdkVersion:'{min_sdk}'\ntargetSdkVersion:'{target}'\n"
        "uses-permission: name='android.permission.INTERNET'\n"
    )


class CheckAndroidTargetSdkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        tools = self.dir / "sdk" / "build-tools" / "36.0.0"
        tools.mkdir(parents=True)
        aapt2 = tools / "aapt2"
        aapt2.write_text(STUB_AAPT2)
        aapt2.chmod(0o755)
        self.env = {"ANDROID_HOME": str(self.dir / "sdk")}

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def apk(self, name: str, text: str) -> Path:
        path = self.dir / name
        with zipfile.ZipFile(path, "w") as apk:
            apk.writestr("AndroidManifest.xml", text)
            apk.writestr("classes.dex", b"dex")
        return path

    def aab(self, name: str, text: str) -> Path:
        path = self.dir / name
        with zipfile.ZipFile(path, "w") as bundle:
            bundle.writestr("base/manifest/AndroidManifest.xml", text)
            bundle.writestr("base/resources.pb", b"pb")
            bundle.writestr("base/res/drawable/icon.xml", b"xml")
            bundle.writestr("BundleConfig.pb", b"cfg")
        return path

    def check(self, *artifacts: Path) -> int:
        saved = dict(os.environ)
        os.environ.pop("ANDROID_SDK_ROOT", None)
        os.environ.update(self.env)
        try:
            return checker.main(["--target", "37", "--min", "24", *map(str, artifacts)])
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_an_apk_and_a_bundle_on_target_pass(self) -> None:
        self.assertEqual(
            self.check(
                self.apk("app.apk", badging(24, 37)),
                self.aab("app.aab", badging(24, 37)),
            ),
            0,
        )

    def test_a_bundle_left_on_36_fails(self) -> None:
        self.assertEqual(self.check(self.aab("app.aab", badging(24, 36))), 1)

    def test_a_raised_min_sdk_fails(self) -> None:
        # Targeting 37 must not drop the devices minSdk 24 still reaches.
        self.assertEqual(self.check(self.apk("app.apk", badging(26, 37))), 1)

    def test_min_sdk_is_only_checked_when_asked(self) -> None:
        saved = dict(os.environ)
        os.environ.update(self.env)
        try:
            artifact = str(self.apk("old.apk", badging(21, 37)))
            self.assertEqual(checker.main(["--target", "37", artifact]), 0)
            self.assertEqual(checker.main(["--target", "36", artifact]), 1)
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_aapt2s_min_sdk_version_wording_is_read(self) -> None:
        # Newer aapt2 badging says minSdkVersion where aapt said sdkVersion.
        text = badging(24, 37).replace("sdkVersion:'24'", "minSdkVersion:'24'")
        self.assertEqual(self.check(self.apk("app.apk", text)), 0)

    def test_the_manifest_tree_is_read_when_badging_is_not_understood(self) -> None:
        path = self.dir / "tree.apk"
        with zipfile.ZipFile(path, "w") as apk:
            apk.writestr("AndroidManifest.xml", "package: name='x'\n")
            apk.writestr(
                "xmltree.txt",
                "N: android=http://schemas.android.com/apk/res/android\n"
                "  E: manifest (line=2)\n"
                "    E: uses-sdk (line=7)\n"
                "      A: http://schemas.android.com/apk/res/android:minSdkVersion"
                "(0x0101020c)=24\n"
                "      A: http://schemas.android.com/apk/res/android:targetSdkVersion"
                "(0x01010270)=37\n",
            )
        self.assertEqual(self.check(path), 0)

    def test_nothing_readable_fails_and_says_what_it_saw(self) -> None:
        path = self.apk("blank.apk", "package: name='x'\n")
        self.assertEqual(self.check(path), 2)

    def test_a_missing_aapt2_never_skips(self) -> None:
        self.env = {"ANDROID_HOME": str(self.dir / "nowhere")}
        self.assertEqual(self.check(self.apk("app.apk", badging(24, 37))), 2)

    def test_a_missing_artifact_fails(self) -> None:
        self.assertEqual(self.check(self.dir / "absent.aab"), 2)

    def test_a_bundle_without_a_base_manifest_fails(self) -> None:
        path = self.dir / "broken.aab"
        with zipfile.ZipFile(path, "w") as bundle:
            bundle.writestr("BundleConfig.pb", b"cfg")
        self.assertEqual(self.check(path), 2)

    def test_badging_without_levels_is_refused(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.parse_levels("package: name='x'\n")

    def test_the_newest_build_tools_win(self) -> None:
        for version in ("9.0.0", "35.0.1", "36.1.0-rc1"):
            tools = self.dir / "sdk" / "build-tools" / version
            tools.mkdir(parents=True)
            (tools / "aapt2").write_text("")
        found = checker.find_aapt2(str(self.dir / "sdk"))
        self.assertEqual(found.parent.name, "36.1.0-rc1")


if __name__ == "__main__":
    unittest.main()
