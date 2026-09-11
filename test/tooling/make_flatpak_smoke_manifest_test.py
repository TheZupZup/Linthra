#!/usr/bin/env python3
"""Unit tests for scripts/make_flatpak_smoke_manifest.py (#446).

    python3 test/tooling/make_flatpak_smoke_manifest_test.py

The generator's whole claim is that the manifest CI builds is the submission
manifest plus one test binary. These tests hold it to that from both ends: the
happy path really does add only the smoke commands, and every way the
submission manifest could drift out from under it (a renamed module, a
reordered build, a manifest that already carries the harness) is a loud
failure rather than a quietly wrong package.

Fixtures are built in memory. Nothing here writes to the repository, runs
flatpak-builder, or reaches the network. The one test that reads the real
committed manifest is checking that today's manifest is still a shape the
generator understands.
"""

from __future__ import annotations

import copy
import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


generator = _load("make_flatpak_smoke_manifest", "make_flatpak_smoke_manifest.py")


def sample_manifest() -> dict:
    """A manifest with the shape the generator cares about, and nothing else."""
    return {
        "app-id": "io.github.thezupzup.linthra",
        "runtime": "org.gnome.Platform",
        "runtime-version": "50",
        "sdk": "org.gnome.Sdk",
        "command": "linthra",
        "finish-args": ["--socket=wayland", "--socket=pulseaudio"],
        "modules": [
            {"name": "mpv", "sources": [{"type": "archive", "url": "file:///mpv"}]},
            {
                "name": "linthra",
                "buildsystem": "simple",
                "build-commands": [
                    "setup-flutter.sh",
                    "flutter build linux --release --no-pub",
                    "install -d /app/lib/linthra",
                    "cp -r build/linux/x64/release/bundle/. /app/lib/linthra/",
                ],
                "sources": [{"type": "dir", "path": ".."}],
            },
        ],
    }


class BuildSmokeManifestTest(unittest.TestCase):
    def test_appends_only_the_smoke_commands(self) -> None:
        original = sample_manifest()
        smoke = generator.build_smoke_manifest(original)

        commands = generator.find_app_module(smoke)["build-commands"]
        self.assertEqual(
            commands[-len(generator.SMOKE_BUILD_COMMANDS) :],
            generator.SMOKE_BUILD_COMMANDS,
        )
        self.assertEqual(
            commands[: -len(generator.SMOKE_BUILD_COMMANDS)],
            original["modules"][1]["build-commands"],
        )

    def test_does_not_mutate_the_submission_manifest(self) -> None:
        original = sample_manifest()
        untouched = copy.deepcopy(original)
        generator.build_smoke_manifest(original)
        self.assertEqual(original, untouched)

    def test_leaves_runtime_permissions_and_other_modules_alone(self) -> None:
        original = sample_manifest()
        smoke = generator.build_smoke_manifest(original)
        for key in ("app-id", "runtime", "runtime-version", "sdk", "command"):
            self.assertEqual(smoke[key], original[key])
        self.assertEqual(smoke["finish-args"], original["finish-args"])
        self.assertEqual(smoke["modules"][0], original["modules"][0])

    def test_equality_check_accepts_its_own_output(self) -> None:
        original = sample_manifest()
        smoke = generator.build_smoke_manifest(original)
        generator.assert_only_smoke_commands_added(original, smoke)

    # The equality check is the load-bearing claim: "the submission manifest
    # plus a test binary". Prove it actually notices a second edit.
    def test_equality_check_rejects_any_other_change(self) -> None:
        original = sample_manifest()
        smoke = generator.build_smoke_manifest(original)
        smoke["finish-args"].append("--filesystem=home")
        with self.assertRaises(generator.ManifestShapeError):
            generator.assert_only_smoke_commands_added(original, smoke)

    def test_equality_check_rejects_a_dropped_smoke_command(self) -> None:
        original = sample_manifest()
        smoke = generator.build_smoke_manifest(original)
        generator.find_app_module(smoke)["build-commands"].pop()
        with self.assertRaises(generator.ManifestShapeError):
            generator.assert_only_smoke_commands_added(original, smoke)


class ManifestShapeTest(unittest.TestCase):
    def test_rejects_a_manifest_without_the_app_module(self) -> None:
        manifest = sample_manifest()
        manifest["modules"][1]["name"] = "linthra-app"
        with self.assertRaises(generator.ManifestShapeError):
            generator.build_smoke_manifest(manifest)

    def test_rejects_a_manifest_with_no_modules(self) -> None:
        with self.assertRaises(generator.ManifestShapeError):
            generator.build_smoke_manifest({"app-id": "x"})

    def test_rejects_an_app_module_that_no_longer_builds_the_app(self) -> None:
        manifest = sample_manifest()
        manifest["modules"][1]["build-commands"] = ["setup-flutter.sh"]
        with self.assertRaises(generator.ManifestShapeError):
            generator.build_smoke_manifest(manifest)

    # Building after the copy would ship the smoke binary as the app.
    def test_rejects_a_build_that_happens_after_the_copy(self) -> None:
        manifest = sample_manifest()
        commands = manifest["modules"][1]["build-commands"]
        commands.remove("flutter build linux --release --no-pub")
        commands.append("flutter build linux --release --no-pub")
        with self.assertRaises(generator.ManifestShapeError):
            generator.build_smoke_manifest(manifest)

    def test_rejects_a_submission_manifest_that_already_has_the_harness(
        self,
    ) -> None:
        manifest = sample_manifest()
        manifest["modules"][1]["build-commands"].extend(
            generator.SMOKE_BUILD_COMMANDS
        )
        with self.assertRaises(generator.ManifestShapeError):
            generator.build_smoke_manifest(manifest)


class RenderTest(unittest.TestCase):
    def test_output_parses_back_to_the_same_manifest(self) -> None:
        original = sample_manifest()
        smoke = generator.build_smoke_manifest(original)
        text = generator.render(smoke, generator.DEFAULT_MANIFEST)
        self.assertEqual(yaml.safe_load(text), smoke)

    def test_output_warns_against_committing_or_submitting_it(self) -> None:
        text = generator.render(sample_manifest(), generator.DEFAULT_MANIFEST)
        self.assertIn("DO NOT EDIT, DO NOT COMMIT, DO NOT SUBMIT.", text)

    # PyYAML folds long plain scalars by default, which turns each install
    # command into two lines and makes the generated manifest hard to diff
    # against the one it came from.
    def test_long_install_commands_stay_on_one_line(self) -> None:
        manifest = sample_manifest()
        long_command = "install -Dm644 " + "a" * 120 + " /app/share/x"
        manifest["modules"][1]["build-commands"].insert(1, long_command)
        text = generator.render(manifest, generator.DEFAULT_MANIFEST)
        self.assertIn("- " + long_command + "\n", text)


class CommittedManifestTest(unittest.TestCase):
    """The committed manifest must still be a shape the generator handles."""

    def test_real_manifest_generates_cleanly(self) -> None:
        original = yaml.safe_load(
            generator.DEFAULT_MANIFEST.read_text(encoding="utf-8")
        )
        smoke = generator.build_smoke_manifest(original)
        generator.assert_only_smoke_commands_added(original, smoke)

    def test_real_manifest_ships_no_test_harness(self) -> None:
        text = generator.DEFAULT_MANIFEST.read_text(encoding="utf-8")
        for name, target in generator.SMOKE_TARGETS.items():
            self.assertNotIn(generator.install_dir(name), text)
            self.assertNotIn(Path(target).stem, text)

    def test_every_smoke_binary_lands_outside_the_user_facing_path(self) -> None:
        seen = set()
        for name in generator.SMOKE_TARGETS:
            directory = generator.install_dir(name)
            self.assertTrue(directory.startswith("/app/libexec/"))
            self.assertTrue(generator.smoke_command(name).startswith(directory))
            self.assertNotIn(directory, seen)
            seen.add(directory)

    def test_smoke_command_rejects_an_unknown_target(self) -> None:
        with self.assertRaises(KeyError):
            generator.smoke_command("nope")

    # Every `flutter build linux` writes to the same bundle directory, so a
    # target that does not copy its output before the next build starts would
    # ship the wrong binary under its own name.
    def test_each_target_copies_its_bundle_before_the_next_build(self) -> None:
        commands = generator.SMOKE_BUILD_COMMANDS
        for index, command in enumerate(commands):
            if not command.startswith("flutter build"):
                continue
            following = commands[index + 1 : index + 3]
            self.assertTrue(
                any(c.startswith("cp -r build/") for c in following),
                msg="{!r} is not followed by a copy".format(command),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
