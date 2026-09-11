#!/usr/bin/env python3
"""Unit tests for scripts/verify_release_containment.py (#574).

    python3 test/tooling/verify_release_containment_test.py

The script decides whether a *shipped* artifact looks like a contained build, so
the thing worth testing is that it says no when it should. Real APKs are 25-70 MB
and cannot be built here, so every case is a synthetic archive: a zip or a
tarball holding a `libapp.so` that is a few hundred bytes of made-up snapshot
with (or without) the markers the script looks for. That is exactly the surface
the script reads — it searches bytes for strings — so a fixture is a faithful
stand-in, and it keeps the tests independent of Linthra's current version, the
Flutter SDK, and the network.

The one case that does use the real repository is the message parser: "the
expected message is the one the app actually shows" is the property that keeps
this check honest, and only reading the real `cast_containment.dart` proves it.

Everything is offline. No network, no builds, no repository writes.
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import sys
import tarfile
import tempfile
import unittest
import zipfile
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


verifier = _load("verify_release_containment", "verify_release_containment.py")

MESSAGE = "Casting is off — everything else works."

# Filler around the markers, so a fixture payload looks like what the script
# really reads: a blob where the strings sit among unrelated bytes.
NOISE = b"\x00\x01flutter\x00snapshot\x00" * 8


def contained_payload(
    *,
    message: str = MESSAGE,
    required: tuple[str, ...] = verifier.REQUIRED_MARKERS,
    extra: tuple[str, ...] = (),
) -> bytes:
    """A fake `libapp.so` carrying the strings a contained build would have."""
    blob = bytearray(NOISE)
    blob += message.encode("utf-16-le")
    for marker in required + extra:
        blob += NOISE
        blob += marker.encode("utf-16-le")
    blob += NOISE
    return bytes(blob)


class ContainmentMessageTest(unittest.TestCase):
    """The expected string comes from the app's own source, or not at all."""

    def test_reads_the_real_message_from_the_app_source(self):
        message = verifier.containment_message(verifier.CONTAINMENT_SOURCE)

        # Not an equality check against a copy of the copy: what matters is that
        # the parser returns the real sentence, including the parts that live on
        # later lines of the adjacent-literal expression.
        self.assertIn("Casting is temporarily turned off", message)
        self.assertIn("your servers", message)
        self.assertNotIn("'", message)

    def test_joins_adjacent_literals_in_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "cast_containment.dart"
            source.write_text(
                "abstract final class CastContainment {\n"
                "  static const String userMessage =\n"
                "      'one '\n"
                "      'two '\n"
                "      'three';\n"
                "}\n",
                encoding="utf-8",
            )

            self.assertEqual(
                verifier.containment_message(source), "one two three"
            )

    def test_missing_message_is_an_error_not_a_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "cast_containment.dart"
            source.write_text("class CastContainment {}\n", encoding="utf-8")

            with self.assertRaises(verifier.VerificationError):
                verifier.containment_message(source)

    def test_unreadable_source_is_an_error(self):
        with self.assertRaises(verifier.VerificationError):
            verifier.containment_message(Path("does/not/exist.dart"))


class ArtifactVerificationTest(unittest.TestCase):
    """Take a good artifact, break exactly one thing, expect it to be caught."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

    def write_zip(self, name: str, entries: dict[str, bytes]) -> Path:
        path = self.tmp / name
        with zipfile.ZipFile(path, "w") as archive:
            for entry, blob in entries.items():
                archive.writestr(entry, blob)
        return path

    def write_tar(self, name: str, entries: dict[str, bytes]) -> Path:
        path = self.tmp / name
        with tarfile.open(path, "w:gz") as archive:
            for entry, blob in entries.items():
                info = tarfile.TarInfo(entry)
                info.size = len(blob)
                archive.addfile(info, io.BytesIO(blob))
        return path

    def verify(self, path: Path):
        return verifier.verify_artifact(path, MESSAGE)

    def test_contained_apk_passes_and_reports_its_digest(self):
        apk = self.write_zip(
            "linthra-release-signed.apk",
            {
                "lib/arm64-v8a/libapp.so": contained_payload(),
                "lib/armeabi-v7a/libapp.so": contained_payload(),
                "AndroidManifest.xml": b"<manifest/>",
            },
        )

        record = self.verify(apk)

        self.assertEqual(record["artifact"], "linthra-release-signed.apk")
        self.assertEqual(len(record["sha256"]), 64)
        self.assertEqual(
            record["payloads"],
            ["lib/arm64-v8a/libapp.so", "lib/armeabi-v7a/libapp.so"],
        )

    def test_latin1_message_is_found_too(self):
        # A message with no wide character is stored one byte per code unit, so
        # rewording the copy must not quietly stop the check from finding it.
        plain = "Casting is off for now."
        apk = self.write_zip(
            "plain.apk",
            {
                "lib/arm64-v8a/libapp.so": bytes(NOISE)
                + plain.encode("latin-1")
                + b"".join(
                    NOISE + m.encode("latin-1")
                    for m in verifier.REQUIRED_MARKERS
                )
            },
        )

        self.assertEqual(
            verifier.verify_artifact(apk, plain)["artifact"], "plain.apk"
        )

    def test_aab_payloads_under_base_are_checked(self):
        aab = self.write_zip(
            "linthra-release-signed.aab",
            {"base/lib/x86_64/libapp.so": contained_payload()},
        )

        self.assertEqual(
            self.verify(aab)["payloads"], ["base/lib/x86_64/libapp.so"]
        )

    def test_linux_tarball_is_checked(self):
        archive = self.write_tar(
            "Linthra-linux-x64.tar.gz",
            {
                "Linthra-linux-x64/linthra": b"ELF",
                "Linthra-linux-x64/lib/libapp.so": contained_payload(),
            },
        )

        self.assertEqual(
            self.verify(archive)["payloads"], ["Linthra-linux-x64/lib/libapp.so"]
        )

    def test_missing_containment_message_fails(self):
        apk = self.write_zip(
            "uncontained.apk",
            {"lib/arm64-v8a/libapp.so": contained_payload(message="something else")},
        )

        with self.assertRaises(verifier.VerificationError) as caught:
            self.verify(apk)
        self.assertIn("containment message is missing", str(caught.exception))

    def test_missing_required_marker_fails(self):
        apk = self.write_zip(
            "no-unavailable-service.apk",
            {"lib/arm64-v8a/libapp.so": contained_payload(required=())},
        )

        with self.assertRaises(verifier.VerificationError) as caught:
            self.verify(apk)
        self.assertIn("expected marker", str(caught.exception))

    def test_each_live_cast_marker_fails_on_its_own(self):
        for marker in verifier.FORBIDDEN_MARKERS:
            with self.subTest(marker=marker):
                apk = self.write_zip(
                    "live.apk",
                    {
                        "lib/arm64-v8a/libapp.so": contained_payload(
                            extra=(marker,)
                        )
                    },
                )

                with self.assertRaises(verifier.VerificationError) as caught:
                    self.verify(apk)
                self.assertIn("live-cast marker", str(caught.exception))

    def test_one_bad_payload_among_good_ones_fails(self):
        # The universal APK carries one payload per ABI, and a build that lost
        # containment for a single architecture is still a build that must not
        # ship.
        apk = self.write_zip(
            "universal.apk",
            {
                "lib/arm64-v8a/libapp.so": contained_payload(),
                "lib/x86_64/libapp.so": contained_payload(message="nope"),
            },
        )

        with self.assertRaises(verifier.VerificationError) as caught:
            self.verify(apk)
        self.assertIn("lib/x86_64/libapp.so", str(caught.exception))

    def test_artifact_without_dart_payload_fails_closed(self):
        apk = self.write_zip("empty.apk", {"AndroidManifest.xml": b"<manifest/>"})

        with self.assertRaises(verifier.VerificationError) as caught:
            self.verify(apk)
        self.assertIn("no libapp.so", str(caught.exception))

    def test_unknown_artifact_type_fails_closed(self):
        stray = self.tmp / "release-notes.txt"
        stray.write_text("not an artifact", encoding="utf-8")

        with self.assertRaises(verifier.VerificationError) as caught:
            self.verify(stray)
        self.assertIn("unknown artifact type", str(caught.exception))

    def test_unreadable_archive_fails_closed(self):
        broken = self.tmp / "truncated.apk"
        broken.write_bytes(b"PK\x03\x04 not really a zip")

        with self.assertRaises(verifier.VerificationError):
            self.verify(broken)

    def test_missing_file_fails_closed(self):
        with self.assertRaises(verifier.VerificationError):
            self.verify(self.tmp / "never-built.apk")


class FlatpakBundleTest(unittest.TestCase):
    """The Flatpak release bundle (#618) is read like every other artifact.

    A real `.flatpak` is an OSTree static delta produced by a full
    flatpak-builder run, so what is faked here is the unpacking — the same seam
    the script itself uses, scripts/flatpak_bundle.py's `extract_bundle`. The
    payload it finds afterwards is the ordinary synthetic `libapp.so` every
    other case uses, because that is all the containment check ever reads.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)

        import flatpak_bundle

        self.flatpak_bundle = flatpak_bundle
        self.addCleanup(
            setattr, flatpak_bundle, "extract_bundle", flatpak_bundle.extract_bundle
        )

    def stub_extractor(self, payload: bytes | None):
        def extract(_bundle: Path, destination: Path) -> str:
            target = destination / "files" / "lib" / "linthra" / "lib"
            target.mkdir(parents=True)
            if payload is not None:
                (target / "libapp.so").write_bytes(payload)
            return "app/io.github.thezupzup.linthra/x86_64/master"

        self.flatpak_bundle.extract_bundle = extract

    def bundle(self, name: str = "Linthra-v0.2.7-x86_64.flatpak") -> Path:
        path = self.tmp / name
        path.write_bytes(b"not really an ostree static delta")
        return path

    def test_contained_bundle_passes_and_reports_its_digest(self):
        self.stub_extractor(contained_payload())
        artifact = self.bundle()

        record = verifier.verify_artifact(artifact, MESSAGE)

        # The digest is of the bundle a user downloads, not of the payload
        # unpacked out of it — that is the whole point of hashing here.
        self.assertEqual(record["artifact"], "Linthra-v0.2.7-x86_64.flatpak")
        self.assertEqual(
            record["sha256"],
            hashlib.sha256(artifact.read_bytes()).hexdigest(),
        )
        self.assertEqual(record["payloads"], ["files/lib/linthra/lib/libapp.so"])

    def test_uncontained_bundle_is_refused(self):
        self.stub_extractor(contained_payload(extra=("DefaultCastService",)))

        with self.assertRaises(verifier.VerificationError) as caught:
            verifier.verify_artifact(self.bundle(), MESSAGE)
        self.assertIn("DefaultCastService", str(caught.exception))

    def test_a_bundle_with_no_payload_fails_closed(self):
        self.stub_extractor(None)

        with self.assertRaises(verifier.VerificationError) as caught:
            verifier.verify_artifact(self.bundle(), MESSAGE)
        self.assertIn("no libapp.so", str(caught.exception))

    def test_an_unreadable_bundle_fails_closed(self):
        def refuse(_bundle: Path, _destination: Path) -> str:
            raise self.flatpak_bundle.BundleError("ostree is not installed")

        self.flatpak_bundle.extract_bundle = refuse

        with self.assertRaises(verifier.VerificationError) as caught:
            verifier.verify_artifact(self.bundle(), MESSAGE)
        self.assertIn("ostree is not installed", str(caught.exception))


class CommandLineTest(unittest.TestCase):
    """The exit code is what CI reads, so it gets its own coverage."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        # main() checks against the real app message, not this file's fixture.
        self.message = verifier.containment_message(verifier.CONTAINMENT_SOURCE)

    def apk(self, name: str, *, message: str) -> Path:
        path = self.tmp / name
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                "lib/arm64-v8a/libapp.so", contained_payload(message=message)
            )
        return path

    def test_passing_run_writes_the_json_record(self):
        good = self.apk("good.apk", message=self.message)
        record = self.tmp / "record.json"

        self.assertEqual(
            verifier.main([str(good), "--json", str(record)]),
            0,
        )
        self.assertIn('"sha256"', record.read_text(encoding="utf-8"))

    def test_the_expected_message_can_come_from_another_tree(self):
        # A release build checks out the tag it builds; the verifier comes from
        # the workflow's own revision. --containment-source is how the caller
        # says which tree's message the artifact should carry.
        source = self.tmp / "cast_containment.dart"
        source.write_text(
            "abstract final class CastContainment {\n"
            "  static const String userMessage = 'An older wording.';\n"
            "}\n",
            encoding="utf-8",
        )
        matching = self.apk("old.apk", message="An older wording.")
        mismatched = self.apk("new.apk", message=self.message)

        self.assertEqual(
            verifier.main([str(matching), "--containment-source", str(source)]),
            0,
        )
        self.assertEqual(
            verifier.main(
                [str(mismatched), "--containment-source", str(source)]
            ),
            1,
        )

    def test_one_bad_artifact_fails_the_whole_run(self):
        good = self.apk("good.apk", message=self.message)
        bad = self.apk("bad.apk", message="not the containment message")

        self.assertEqual(verifier.main([str(good), str(bad)]), 1)


if __name__ == "__main__":
    unittest.main()
