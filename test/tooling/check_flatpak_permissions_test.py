#!/usr/bin/env python3
"""Unit tests for scripts/check_flatpak_permissions.py (#455).

    python3 test/tooling/check_flatpak_permissions_test.py

The check exists to make two failures loud: a permission nobody explained, and
an explanation for a permission that is no longer there. Both directions are
tested here, along with the refusal list, because a refusal that quietly stops
matching is the one that would let the sandbox widen unnoticed.

The real repository is read, never written. Fixtures are built in temporary
directories, and nothing here runs flatpak.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


checker = _load("check_flatpak_permissions", "check_flatpak_permissions.py")

TABLE = """
| Permission | Feature | Where it is used | Why nothing narrower works |
| --- | --- | --- | --- |
| `--socket=wayland` | The window | runner | a GUI app needs a display |
| `--share=network` | Servers | sources | all-or-nothing in Flatpak |
"""

MANIFEST = """\
app-id: io.github.thezupzup.linthra
finish-args:
  - --socket=wayland
  # A comment about the next one.
  - --share=network
modules:
  - name: linthra
"""

METADATA = """\
[Application]
name=io.github.thezupzup.linthra

[Context]
shared=network;ipc;
sockets=wayland;fallback-x11;pulseaudio;
devices=dri;

[Session Bus Policy]
org.mpris.MediaPlayer2.linthra=own
org.mpris.MediaPlayer2.linthra.*=own
"""


@contextlib.contextmanager
def written(name: str, text: str):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / name
        path.write_text(text, encoding="utf-8")
        yield path


class DocumentedPermissionsTest(unittest.TestCase):
    def test_reads_a_permission_table(self) -> None:
        with written("permissions.md", TABLE) as path:
            documented = checker.documented_permissions(path)
        self.assertEqual(
            set(documented), {"--socket=wayland", "--share=network"}
        )
        self.assertIn("all-or-nothing", documented["--share=network"])

    def test_ignores_rows_that_are_not_permissions(self) -> None:
        table = TABLE + "| Local libraries | none needed | portal | n/a |\n"
        with written("permissions.md", table) as path:
            self.assertEqual(len(checker.documented_permissions(path)), 2)

    # A row with a blank "why" column is a placeholder, not a rationale.
    def test_rejects_a_row_with_an_empty_column(self) -> None:
        table = TABLE + "| `--device=dri` | GPU |  | because |\n"
        with written("permissions.md", table) as path:
            with self.assertRaises(ValueError):
                checker.documented_permissions(path)


class ManifestPermissionsTest(unittest.TestCase):
    def test_reads_finish_args_past_comments(self) -> None:
        with written("manifest.yml", MANIFEST) as path:
            self.assertEqual(
                checker.manifest_permissions(path),
                {"--socket=wayland", "--share=network"},
            )

    def test_stops_at_the_next_top_level_key(self) -> None:
        with written("manifest.yml", MANIFEST) as path:
            self.assertNotIn("name: linthra", checker.manifest_permissions(path))

    def test_reads_the_real_manifests(self) -> None:
        for manifest in checker.MANIFESTS:
            permissions = checker.manifest_permissions(manifest)
            self.assertIn("--share=network", permissions)
            self.assertIn("--socket=wayland", permissions)


class MetadataTest(unittest.TestCase):
    def test_turns_installed_metadata_back_into_finish_args(self) -> None:
        self.assertEqual(
            checker.parse_metadata(METADATA),
            {
                "--share=network",
                "--share=ipc",
                "--socket=wayland",
                "--socket=fallback-x11",
                "--socket=pulseaudio",
                "--device=dri",
                "--own-name=org.mpris.MediaPlayer2.linthra",
                "--own-name=org.mpris.MediaPlayer2.linthra.*",
            },
        )

    def test_reads_a_filesystem_grant_the_manifest_never_declared(self) -> None:
        text = METADATA + "\n[Context]\nfilesystems=home;\n"
        self.assertIn("--filesystem=home", checker.parse_metadata(text))

    # `--env=` is on the refusal list, but the ban held only for the manifest,
    # where finish-args are read literally. In the installed metadata an env
    # grant becomes an [Environment] section, which parse_metadata skipped
    # entirely, so the artifact a user actually gets could carry one and
    # --installed would still report a match.
    def test_reads_an_environment_grant_the_manifest_never_declared(self) -> None:
        text = METADATA + "\n[Environment]\nLINTHRA_DEBUG=1\n"
        permissions = checker.parse_metadata(text)
        self.assertIn("--env=LINTHRA_DEBUG=1", permissions)
        self.assertEqual(checker.refused(permissions), ["--env=LINTHRA_DEBUG=1"])

    # A value containing "=" must survive, or the grant is misreported.
    def test_an_environment_value_may_contain_an_equals_sign(self) -> None:
        text = METADATA + "\n[Environment]\nURL=https://example.invalid/?a=b\n"
        self.assertIn(
            "--env=URL=https://example.invalid/?a=b",
            checker.parse_metadata(text),
        )

    def test_reads_a_talk_name(self) -> None:
        text = METADATA + "org.freedesktop.secrets=talk\n"
        self.assertIn(
            "--talk-name=org.freedesktop.secrets", checker.parse_metadata(text)
        )


class RefusedTest(unittest.TestCase):
    # Each of these has a written reason in the rationale document. What is
    # tested here is that the pattern still matches the spelling it refuses.
    def test_catches_every_refused_grant(self) -> None:
        for permission in (
            "--filesystem=host",
            "--filesystem=home",
            "--filesystem=xdg-music",
            "--filesystem=/srv/music",
            "--persist=.config",
            "--socket=session-bus",
            "--socket=system-bus",
            "--socket=x11",
            "--socket=ssh-auth",
            "--talk-name=org.freedesktop.secrets",
            "--talk-name=org.freedesktop.Notifications",
            "--system-talk-name=org.freedesktop.UDisks2",
            "--own-name=org.mpris.MediaPlayer2.*",
            "--device=all",
            "--allow=devel",
            "--env=LINTHRA_DEBUG=1",
        ):
            self.assertEqual(
                checker.refused({permission}),
                [permission],
                msg="{} is not refused".format(permission),
            )

    def test_leaves_the_granted_set_alone(self) -> None:
        self.assertEqual(checker.refused(checker.parse_metadata(METADATA)), [])

    # fallback-x11 only hands out an X socket when there is no Wayland display;
    # plain x11 always does, which is why they are spelled differently.
    def test_fallback_x11_is_not_refused_but_x11_is(self) -> None:
        self.assertEqual(checker.refused({"--socket=fallback-x11"}), [])
        self.assertEqual(checker.refused({"--socket=x11"}), ["--socket=x11"])


class CheckTest(unittest.TestCase):
    documented = {"--socket=wayland": "why", "--share=network": "why"}

    def test_a_matching_set_has_no_problems(self) -> None:
        self.assertEqual(
            checker.check(
                self.documented, {"--socket=wayland", "--share=network"}, "src"
            ),
            [],
        )

    def test_an_undocumented_permission_fails(self) -> None:
        problems = checker.check(
            self.documented,
            {"--socket=wayland", "--share=network", "--device=dri"},
            "src",
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("--device=dri", problems[0])
        self.assertIn("no row", problems[0])

    # A rationale for a permission that is gone is how this page rots into
    # something that describes a sandbox nobody ships.
    def test_a_stale_rationale_fails(self) -> None:
        problems = checker.check(self.documented, {"--socket=wayland"}, "src")
        self.assertEqual(len(problems), 1)
        self.assertIn("--share=network", problems[0])
        self.assertIn("no longer", problems[0])

    def test_a_refused_permission_fails_even_when_documented(self) -> None:
        problems = checker.check(
            {**self.documented, "--filesystem=home": "someone wrote a reason"},
            {"--socket=wayland", "--share=network", "--filesystem=home"},
            "src",
        )
        self.assertTrue(any("refused" in problem for problem in problems))


class MainTest(unittest.TestCase):
    def _main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = checker.main(argv)
        return code, out.getvalue() + err.getvalue()

    def test_the_repository_as_committed_passes(self) -> None:
        code, output = self._main([])
        self.assertEqual(code, 0, msg=output)
        self.assertIn("each with a written rationale", output)

    def test_the_committed_set_is_the_eight_documented_grants(self) -> None:
        documented = checker.documented_permissions(checker.RATIONALE)
        self.assertEqual(
            set(documented),
            {
                "--socket=wayland",
                "--socket=fallback-x11",
                "--share=ipc",
                "--device=dri",
                "--socket=pulseaudio",
                "--share=network",
                "--own-name=org.mpris.MediaPlayer2.linthra",
                "--own-name=org.mpris.MediaPlayer2.linthra.*",
            },
        )

    # An installed package that cannot be read is not a clean installed
    # package.
    def test_an_unreadable_installed_package_is_not_a_pass(self) -> None:
        original = checker.installed_permissions

        def fail(_app_id):
            raise RuntimeError("not installed")

        checker.installed_permissions = fail
        try:
            code, output = self._main(["--installed"])
        finally:
            checker.installed_permissions = original
        self.assertEqual(code, 2)
        self.assertIn("not a pass", output)

    def test_an_installed_package_with_an_extra_grant_fails(self) -> None:
        original = checker.installed_permissions
        checker.installed_permissions = lambda _app_id: checker.parse_metadata(
            METADATA + "\n[Context]\nfilesystems=home;\n"
        )
        try:
            code, output = self._main(["--installed"])
        finally:
            checker.installed_permissions = original
        self.assertEqual(code, 1)
        self.assertIn("--filesystem=home", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
