#!/usr/bin/env python3
"""Unit tests for scripts/flatpak_bundle.py (#618).

    python3 test/tooling/flatpak_bundle_test.py

Two things in the release path have rules rather than steps, and both are here:
the artifact's name, and what a bundle has to contain before it is attached to
a GitHub Release.

A real `.flatpak` is a few hundred megabytes and takes a full flatpak-builder
run to produce, so every case below builds the *extracted* tree instead — the
`metadata`, `files/` and `export/` layout `ostree checkout` leaves behind — and
calls the same checks the script runs on it. That is exactly the surface the
script reads, so a fixture is a faithful stand-in, and it keeps these tests
offline and independent of the Flatpak toolchain.

What is deliberately not faked is the manifest: `manifest_expectations` reads
Linthra's real `flatpak/io.github.thezupzup.linthra.yml`, because "the check
knows what the package installs" is the property that keeps the rest honest.

Everything is offline. No network, no builds, no repository writes.
"""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

sys.path.insert(0, str(SCRIPTS))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


bundle = _load("flatpak_bundle", "flatpak_bundle.py")

ARCH = "x86_64"
TAG = "v0.2.7"


def real_expectations() -> dict[str, object]:
    return bundle.manifest_expectations(bundle.DEFAULT_MANIFEST)


def good_tree(destination: Path, expectations: dict[str, object]) -> Path:
    """An extracted bundle with everything the checks require.

    Built from the manifest's own expectations, so adding an icon size to the
    package does not need a matching edit here.
    """
    app_id = str(expectations["app_id"])
    command = str(expectations["command"])

    (destination / "files" / "bin").mkdir(parents=True)
    (destination / "files" / "bin" / command).write_text("#!/bin/sh\n")

    (destination / "files" / "lib" / "linthra" / "lib").mkdir(parents=True)
    (destination / "files" / "lib" / "linthra" / "lib" / "libapp.so").write_bytes(
        b"\x7fELF fake snapshot"
    )
    # #433's packaged audio runtime.
    (destination / "files" / "lib" / "libmpv.so.2").write_bytes(b"\x7fELF fake libmpv")

    for installed in expectations["installed"]:  # type: ignore[union-attr]
        target = destination / "files" / str(installed)[len("/app/") :]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture\n")

    exported_desktop = destination / "export" / "share" / "applications"
    exported_desktop.mkdir(parents=True)
    (exported_desktop / f"{app_id}.desktop").write_text("[Desktop Entry]\n")

    exported_icons = destination / "export" / "share" / "icons" / "hicolor" / "scalable" / "apps"
    exported_icons.mkdir(parents=True)
    (exported_icons / f"{app_id}.svg").write_text("<svg/>\n")

    (destination / "metadata").write_text(
        "[Application]\n"
        f"name={app_id}\n"
        "runtime={}/{}/{}\n".format(
            expectations["runtime"], ARCH, expectations["runtime_version"]
        )
        + "sdk=org.gnome.Sdk/{}/{}\n".format(ARCH, expectations["runtime_version"])
        + f"command={command}\n"
    )
    return destination


class NamingTest(unittest.TestCase):
    """The asset name is the one thing a release workflow must never guess."""

    def test_names_a_stable_release_asset(self):
        self.assertEqual(
            bundle.bundle_name("v0.2.7", "x86_64"), "Linthra-v0.2.7-x86_64.flatpak"
        )

    def test_accepts_a_bare_version_and_restores_the_v(self):
        # The tarball asset, the tag and the Android assets all carry the v, so
        # a caller that passes the pubspec version still gets the release name.
        self.assertEqual(
            bundle.bundle_name("0.2.7", "x86_64"), "Linthra-v0.2.7-x86_64.flatpak"
        )

    def test_keeps_prerelease_tags_intact(self):
        self.assertEqual(
            bundle.bundle_name("v0.3.0-rc.2", "aarch64"),
            "Linthra-v0.3.0-rc.2-aarch64.flatpak",
        )

    def test_rejects_a_malformed_tag(self):
        for tag in ("", "0.2", "v0.2.7-nightly", "main", "v0.2.7 ; rm -rf /"):
            with self.subTest(tag=tag):
                with self.assertRaises(bundle.BundleError):
                    bundle.bundle_name(tag, "x86_64")

    def test_rejects_an_unexpected_architecture(self):
        for arch in ("", "x86_64/../..", "x86 64"):
            with self.subTest(arch=arch):
                with self.assertRaises(bundle.BundleError):
                    bundle.bundle_name("v0.2.7", arch)


class ManifestExpectationsTest(unittest.TestCase):
    """Read from the real manifest, or the rest of this proves nothing."""

    def test_reads_identity_from_the_committed_manifest(self):
        expectations = real_expectations()

        self.assertEqual(expectations["app_id"], "io.github.thezupzup.linthra")
        self.assertEqual(expectations["runtime"], "org.gnome.Platform")
        self.assertEqual(expectations["command"], "linthra")
        self.assertTrue(str(expectations["runtime_version"]).isdigit())

    def test_collects_every_installed_package_path(self):
        installed = real_expectations()["installed"]

        # The desktop entry (#434), the AppStream metainfo (#435) and the
        # scalable icon (#436) are the three a launcher entry depends on.
        self.assertIn(
            "/app/share/applications/io.github.thezupzup.linthra.desktop", installed
        )
        self.assertIn(
            "/app/share/metainfo/io.github.thezupzup.linthra.metainfo.xml", installed
        )
        self.assertIn(
            "/app/share/icons/hicolor/scalable/apps/io.github.thezupzup.linthra.svg",
            installed,
        )
        # `install -d /app/bin` creates a directory and installs nothing; it
        # must not be read as a file the bundle has to contain.
        self.assertNotIn("/app/bin", installed)

    def test_a_manifest_that_installs_nothing_is_an_error(self):
        with tempfile.TemporaryDirectory() as scratch:
            empty = Path(scratch) / "manifest.yml"
            empty.write_text(
                "app-id: io.github.thezupzup.linthra\n"
                "runtime: org.gnome.Platform\n"
                "runtime-version: '50'\n"
                "command: linthra\n"
            )
            with self.assertRaises(bundle.BundleError):
                bundle.manifest_expectations(empty)


class TreeContentsTest(unittest.TestCase):
    """What has to be inside the bundle a user installs."""

    def setUp(self):
        self.expectations = real_expectations()
        self.app_id = str(self.expectations["app_id"])
        self.ref = f"app/{self.app_id}/{ARCH}/{bundle.DEFAULT_BRANCH}"
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.tree = good_tree(Path(self._scratch.name) / "tree", self.expectations)

    def problems(self, ref: str | None = None) -> list[str]:
        return bundle.tree_problems(
            self.tree, ref or self.ref, self.expectations, arch=ARCH
        )

    def test_a_complete_bundle_has_no_problems(self):
        self.assertEqual(self.problems(), [])

    def test_a_foreign_ref_is_rejected(self):
        problems = self.problems(ref="app/com.example.Other/x86_64/master")

        self.assertTrue(any("expected app/" in problem for problem in problems))

    def test_a_missing_desktop_export_is_rejected(self):
        (
            self.tree / "export" / "share" / "applications" / f"{self.app_id}.desktop"
        ).unlink()

        self.assertTrue(
            any("would not appear in the launcher" in p for p in self.problems())
        )

    def test_a_missing_exported_icon_is_rejected(self):
        for icon in (self.tree / "export" / "share" / "icons").rglob("*"):
            if icon.is_file():
                icon.unlink()

        self.assertTrue(any("generic icon" in p for p in self.problems()))

    # #433. A bundle with no packaged libmpv is the regression this whole
    # packaging effort exists to prevent: it would run only where the host
    # already had one installed.
    def test_a_bundle_without_the_packaged_libmpv_is_rejected(self):
        (self.tree / "files" / "lib" / "libmpv.so.2").unlink()

        self.assertTrue(
            any("host-installed libmpv" in p for p in self.problems())
        )

    def test_a_missing_installed_file_is_rejected(self):
        metainfo = (
            self.tree / "files" / "share" / "metainfo" / f"{self.app_id}.metainfo.xml"
        )
        metainfo.unlink()

        self.assertTrue(any("metainfo" in p for p in self.problems()))

    def test_a_bundle_without_compiled_dart_is_rejected(self):
        (self.tree / "files" / "lib" / "linthra" / "lib" / "libapp.so").unlink()

        self.assertTrue(any("compiled Dart" in p for p in self.problems()))

    def test_a_missing_entry_point_is_rejected(self):
        (self.tree / "files" / "bin" / str(self.expectations["command"])).unlink()

        self.assertTrue(any("flatpak run" in p for p in self.problems()))

    def test_metadata_naming_another_runtime_is_rejected(self):
        (self.tree / "metadata").write_text(
            "[Application]\n"
            f"name={self.app_id}\n"
            "runtime=org.freedesktop.Platform/x86_64/24.08\n"
            "command=linthra\n"
        )

        self.assertTrue(any("metadata runtime=" in p for p in self.problems()))

    def test_metadata_naming_another_application_is_rejected(self):
        (self.tree / "metadata").write_text(
            "[Application]\nname=com.example.Other\ncommand=linthra\n"
        )

        self.assertTrue(any("metadata name=" in p for p in self.problems()))

    def test_a_bundle_with_no_metadata_is_rejected(self):
        (self.tree / "metadata").unlink()

        self.assertTrue(any("declares no identity" in p for p in self.problems()))


class VerifyBundleTest(unittest.TestCase):
    """The whole check, with extraction stubbed out."""

    def setUp(self):
        self.expectations = real_expectations()
        self._scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self._scratch.cleanup)
        self.scratch = Path(self._scratch.name)
        self.app_id = str(self.expectations["app_id"])

    def extractor(self, ref: str | None = None):
        def extract(_bundle: Path, destination: Path) -> str:
            destination.mkdir(parents=True)
            good_tree(destination, self.expectations)
            return ref or f"app/{self.app_id}/{ARCH}/{bundle.DEFAULT_BRANCH}"

        return extract

    def written_bundle(self, name: str) -> Path:
        path = self.scratch / name
        path.write_bytes(b"not really an ostree static delta")
        return path

    def test_records_the_digest_of_the_file_that_was_checked(self):
        artifact = self.written_bundle(f"Linthra-{TAG}-{ARCH}.flatpak")

        record = bundle.verify_bundle(
            artifact,
            tag=TAG,
            arch=ARCH,
            manifest=bundle.DEFAULT_MANIFEST,
            extract=self.extractor(),
        )

        self.assertEqual(record["artifact"], artifact.name)
        self.assertEqual(record["bytes"], artifact.stat().st_size)
        self.assertEqual(
            record["sha256"], hashlib.sha256(artifact.read_bytes()).hexdigest()
        )
        self.assertEqual(record["app_id"], self.app_id)

    def test_a_bundle_named_for_another_release_is_rejected(self):
        artifact = self.written_bundle(f"Linthra-v0.1.0-{ARCH}.flatpak")

        with self.assertRaises(bundle.BundleError) as caught:
            bundle.verify_bundle(
                artifact,
                tag=TAG,
                arch=ARCH,
                manifest=bundle.DEFAULT_MANIFEST,
                extract=self.extractor(),
            )

        self.assertIn(f"Linthra-{TAG}-{ARCH}.flatpak", str(caught.exception))

    def test_a_bundle_holding_another_application_is_rejected(self):
        artifact = self.written_bundle(f"Linthra-{TAG}-{ARCH}.flatpak")

        with self.assertRaises(bundle.BundleError):
            bundle.verify_bundle(
                artifact,
                tag=TAG,
                arch=ARCH,
                manifest=bundle.DEFAULT_MANIFEST,
                extract=self.extractor(ref="app/com.example.Other/x86_64/master"),
            )

    def test_a_missing_file_is_rejected(self):
        with self.assertRaises(bundle.BundleError):
            bundle.verify_bundle(
                self.scratch / f"Linthra-{TAG}-{ARCH}.flatpak",
                tag=TAG,
                arch=ARCH,
                manifest=bundle.DEFAULT_MANIFEST,
                extract=bundle.extract_bundle,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
