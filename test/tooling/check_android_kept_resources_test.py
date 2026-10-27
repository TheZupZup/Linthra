#!/usr/bin/env python3
"""Tests for scripts/check_android_kept_resources.py.

A stub aapt2 stands in for the SDK's: `dump resources` prints the artifact's
resources.txt member (an AAB's resources.pb, once repackaged) as if it were the
resource table, and `convert` copies the proto APK it is given. That is enough
to drive the APK path, the AAB repackaging path and every refusal offline,
with no Android SDK.
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
    "check_android_kept_resources",
    ROOT / "scripts" / "check_android_kept_resources.py",
)
assert spec is not None and spec.loader is not None
checker = importlib.util.module_from_spec(spec)
sys.modules["check_android_kept_resources"] = checker
spec.loader.exec_module(checker)

STUB_AAPT2 = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import shutil, sys, zipfile
    args = sys.argv[1:]
    if args[:2] == ["dump", "resources"]:
        with zipfile.ZipFile(args[2]) as apk:
            for name in ("resources.txt", "resources.pb"):
                if name in apk.namelist():
                    sys.stdout.write(apk.read(name).decode())
        sys.exit(0)
    if args[0] == "convert":
        out = args[args.index("-o") + 1]
        shutil.copy(args[-1], out)
        sys.exit(0)
    sys.exit("unexpected: " + " ".join(args))
    """
)

KEEP = (
    '<resources xmlns:tools="http://schemas.android.com/tools"\n'
    '    tools:keep="@drawable/ic_shuffle,@drawable/audio_service_stop,\n'
    '        @drawable/audio_service_pause" />\n'
)


def table(*resources: str) -> str:
    lines = ["Binary APK", "Package name=io.github.thezupzup.linthra id=7f"]
    for index, resource in enumerate(resources):
        lines.append(f"    resource 0x7f0700{index:02x} {resource}")
        lines.append("      () (file) res/x.png type=PNG")
    return "\n".join(lines) + "\n"


ALL_KEPT = table(
    "drawable/ic_shuffle",
    "drawable/audio_service_stop",
    "drawable/audio_service_pause",
    "mipmap/ic_launcher",
)


class CheckAndroidKeptResourcesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        tools = self.dir / "sdk" / "build-tools" / "37.0.0"
        tools.mkdir(parents=True)
        aapt2 = tools / "aapt2"
        aapt2.write_text(STUB_AAPT2)
        aapt2.chmod(0o755)
        self.env = {"ANDROID_HOME": str(self.dir / "sdk")}
        self.keep = self.dir / "keep.xml"
        self.keep.write_text(KEEP)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def apk(self, name: str, resources: str) -> Path:
        path = self.dir / name
        with zipfile.ZipFile(path, "w") as apk:
            apk.writestr("AndroidManifest.xml", "manifest")
            apk.writestr("resources.txt", resources)
        return path

    def aab(self, name: str, resources: str) -> Path:
        path = self.dir / name
        with zipfile.ZipFile(path, "w") as bundle:
            bundle.writestr("base/manifest/AndroidManifest.xml", "manifest")
            bundle.writestr("base/resources.pb", resources)
            bundle.writestr("BundleConfig.pb", b"cfg")
        return path

    def check(self, *artifacts: Path) -> int:
        saved = dict(os.environ)
        os.environ.pop("ANDROID_SDK_ROOT", None)
        os.environ.update(self.env)
        try:
            return checker.main(["--keep", str(self.keep), *map(str, artifacts)])
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_an_apk_and_a_bundle_with_every_kept_resource_pass(self) -> None:
        self.assertEqual(
            self.check(self.apk("app.apk", ALL_KEPT), self.aab("app.aab", ALL_KEPT)),
            0,
        )

    def test_a_bundle_the_shrinker_took_the_media_icons_from_fails(self) -> None:
        # What v0.2.10 shipped: the app's own icons kept, audio_service's gone.
        shrunk = table("drawable/ic_shuffle", "mipmap/ic_launcher")
        self.assertEqual(self.check(self.aab("app.aab", shrunk)), 1)

    def test_one_missing_artifact_among_good_ones_fails(self) -> None:
        shrunk = table("drawable/ic_shuffle", "drawable/audio_service_stop")
        self.assertEqual(
            self.check(self.apk("good.apk", ALL_KEPT), self.apk("bad.apk", shrunk)),
            1,
        )

    def test_a_package_prefixed_listing_is_read(self) -> None:
        prefixed = ALL_KEPT.replace(
            " drawable/", " io.github.thezupzup.linthra:drawable/"
        )
        self.assertEqual(self.check(self.apk("app.apk", prefixed)), 0)

    def test_a_wildcard_entry_matches_by_pattern(self) -> None:
        self.keep.write_text(
            '<resources xmlns:tools="http://schemas.android.com/tools"\n'
            '    tools:keep="@drawable/audio_service_*" />\n'
        )
        self.assertEqual(self.check(self.apk("app.apk", ALL_KEPT)), 0)
        self.assertEqual(
            self.check(self.apk("none.apk", table("drawable/ic_shuffle"))), 1
        )

    def test_an_empty_listing_is_an_error_not_a_pass(self) -> None:
        self.assertEqual(self.check(self.apk("blank.apk", "Binary APK\n")), 2)

    def test_a_keep_file_without_a_keep_list_is_refused(self) -> None:
        self.keep.write_text("<resources />\n")
        self.assertEqual(self.check(self.apk("app.apk", ALL_KEPT)), 2)

    def test_a_missing_keep_file_is_refused(self) -> None:
        self.keep.unlink()
        self.assertEqual(self.check(self.apk("app.apk", ALL_KEPT)), 2)

    def test_a_missing_aapt2_never_skips(self) -> None:
        self.env = {"ANDROID_HOME": str(self.dir / "nowhere")}
        self.assertEqual(self.check(self.apk("app.apk", ALL_KEPT)), 2)

    def test_a_missing_artifact_fails(self) -> None:
        self.assertEqual(self.check(self.dir / "absent.aab"), 2)

    def test_the_repository_keep_file_is_readable(self) -> None:
        kept = checker.kept_resources(
            (ROOT / "android/app/src/main/res/raw/keep.xml").read_text()
        )
        self.assertIn("drawable/audio_service_stop", kept)


if __name__ == "__main__":
    unittest.main()
