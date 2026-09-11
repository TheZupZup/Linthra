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
import re
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


# The permissions Linthra's built Flatpak actually carries, in the format
# `flatpak info --show-permissions` prints. Transcribed from the Flatpak build
# job rather than written by hand, because the point of --installed is that the
# artifact is allowed to disagree with the manifest, and a fixture invented
# from the manifest could not show that.
#
# Note `x11` next to `fallback-x11`: that is flatpak spelling the fallback
# grant, not a second one.
INSTALLED_METADATA = """\
[Context]
shared=network;ipc;
sockets=x11;wayland;fallback-x11;pulseaudio;
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


class DocumentedRefusalsTest(unittest.TestCase):
    # The refusals table is what makes a refusal readable, and it was being
    # kept in step by hand. By the time anyone checked, six patterns had no row
    # at all. Now the two are compared both ways, like the granted table.
    def test_reads_only_the_table_under_the_refusals_heading(self) -> None:
        doc = (
            "## The result\n"
            "| Permission | Feature | Where | Why |\n"
            "| --- | --- | --- | --- |\n"
            "| `--socket=fallback-x11` | window | runner | plain `--socket=x11` "
            "would |\n"
            "\n"
            "## Permissions that are refused\n"
            "| Refused | Why |\n"
            "| --- | --- |\n"
            "| `--filesystem=home` | every file the user owns |\n"
        )
        with written("permissions.md", doc) as path:
            # Not --socket=fallback-x11: that is a granted permission, and
            # reading the wrong table would report it as an unrefused refusal.
            self.assertEqual(
                checker.documented_refusals(path), ["--filesystem=home"]
            )

    def test_every_refusal_in_the_repository_is_written_down(self) -> None:
        spellings = checker.documented_refusals(checker.RATIONALE)
        self.assertTrue(spellings)
        for pattern in checker.REFUSED:
            self.assertTrue(
                any(re.fullmatch(pattern, spelling) for spelling in spellings),
                msg="{} has no spelling in the refusals table".format(pattern),
            )

    def test_every_written_refusal_is_actually_refused(self) -> None:
        for spelling in checker.documented_refusals(checker.RATIONALE):
            self.assertEqual(
                checker.refused({spelling}), [spelling], msg=spelling
            )


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

    # YAML lets an entry be quoted and carry a trailing comment, and
    # scripts/check_linux_runner.py reads exactly that shape out of exactly
    # these files. Stripping quotes by hand gave the two checkers different
    # answers about the same line: the permission came out as
    # `--socket=wayland"  # the window`, which no refusal pattern matches.
    def test_reads_quoted_entries_and_trailing_comments(self) -> None:
        manifest = (
            "app-id: io.github.thezupzup.linthra\n"
            "finish-args:\n"
            '  - "--socket=wayland"  # the application window\n'
            "  - '--share=network'\n"
            "  - --device=dri # the GPU\n"
            "modules:\n"
            "  - name: linthra\n"
        )
        with written("manifest.yml", manifest) as path:
            self.assertEqual(
                checker.manifest_permissions(path),
                {"--socket=wayland", "--share=network", "--device=dri"},
            )

    # A refusal that stops matching is the failure this check exists to
    # prevent, so the refusal list has to still apply to an entry written
    # with a comment on it.
    def test_a_refused_grant_is_still_refused_when_commented(self) -> None:
        manifest = (
            'finish-args:\n  - "--filesystem=home"  # just while I debug something\n'
        )
        with written("manifest.yml", manifest) as path:
            self.assertEqual(
                checker.refused(checker.manifest_permissions(path)),
                ["--filesystem=home"],
            )

    def test_an_unreadable_entry_fails_rather_than_ending_the_block(self) -> None:
        manifest = "finish-args:\n  --socket=wayland\n"
        with written("manifest.yml", manifest) as path:
            with self.assertRaises(ValueError):
                checker.manifest_permissions(path)

    def test_an_entry_that_is_not_one_permission_fails(self) -> None:
        manifest = "finish-args:\n  - --socket=wayland --share=network\n"
        with written("manifest.yml", manifest) as path:
            with self.assertRaises(ValueError):
                checker.manifest_permissions(path)


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

    # A bus policy has four values and three of them are grants. `see` was
    # missing from the table, and because an unknown value was skipped, a
    # package that could see a name on the bus read back as one that could
    # not: the same silent-drop shape as the [Environment] hole above.
    def test_reads_a_see_name(self) -> None:
        text = METADATA + "org.freedesktop.secrets=see\n"
        self.assertIn(
            "--see-name=org.freedesktop.secrets", checker.parse_metadata(text)
        )

    def test_reads_a_system_see_name(self) -> None:
        text = METADATA + "\n[System Bus Policy]\norg.freedesktop.UDisks2=see\n"
        self.assertIn(
            "--system-see-name=org.freedesktop.UDisks2",
            checker.parse_metadata(text),
        )

    # `none` is the fourth value and the only one that is a denial rather than
    # a grant, so it is the only one that may produce nothing.
    def test_a_none_policy_grants_nothing(self) -> None:
        text = METADATA + "org.freedesktop.secrets=none\n"
        permissions = checker.parse_metadata(text)
        self.assertNotIn("--talk-name=org.freedesktop.secrets", permissions)
        self.assertNotIn("--see-name=org.freedesktop.secrets", permissions)

    def test_an_unknown_bus_policy_fails_rather_than_being_dropped(self) -> None:
        text = METADATA + "org.freedesktop.secrets=whatever\n"
        with self.assertRaises(ValueError) as caught:
            checker.parse_metadata(text)
        self.assertIn("whatever", str(caught.exception))

    # The failure mode this whole parser is shaped around: a grant that is in
    # the artifact, absent from the report, and reported as OK. A section
    # nobody taught it about has to stop the check, not shrink it.
    def test_an_unknown_section_fails_rather_than_being_skipped(self) -> None:
        text = METADATA + "\n[Somewhere New]\nkey=value\n"
        with self.assertRaises(ValueError) as caught:
            checker.parse_metadata(text)
        self.assertIn("Somewhere New", str(caught.exception))

    def test_an_unknown_context_key_fails(self) -> None:
        text = METADATA + "\n[Context]\nsomething-new=value;\n"
        with self.assertRaises(ValueError) as caught:
            checker.parse_metadata(text)
        self.assertIn("something-new", str(caught.exception))

    # [Application] carries an app id and a runtime, not a permission.
    # `flatpak info --show-permissions` builds its output from the context
    # alone, but a metadata file read from anywhere else has this group.
    def test_identity_sections_are_ignored_rather_than_refused(self) -> None:
        self.assertNotIn(
            "--name=io.github.thezupzup.linthra", checker.parse_metadata(METADATA)
        )

    # The first CI run of --installed against a real package failed here, and
    # the package was right. `--socket=fallback-x11` sets the plain X11 bit as
    # well as its own (common/flatpak-context.c: `socket |=
    # FLATPAK_CONTEXT_SOCKET_X11`), and `flatpak run` clears it again when
    # there is a Wayland display. So the metadata of a package that asked only
    # for the fallback carries both, and reading it literally reported a
    # refused `--socket=x11` nobody had declared.
    def test_fallback_x11_metadata_is_not_read_as_plain_x11(self) -> None:
        text = INSTALLED_METADATA
        permissions = checker.parse_metadata(text)
        self.assertIn("--socket=fallback-x11", permissions)
        self.assertNotIn("--socket=x11", permissions)
        self.assertEqual(checker.refused(permissions), [])

    # The whole point of the collapse is that it is the pair that is narrow.
    def test_plain_x11_alone_is_still_refused(self) -> None:
        permissions = checker.parse_metadata(
            "[Context]\nsockets=x11;wayland;\n"
        )
        self.assertIn("--socket=x11", permissions)
        self.assertEqual(checker.refused(permissions), ["--socket=x11"])

    # What the installed package really carries, byte for byte as
    # `flatpak info --show-permissions` printed it in the Flatpak build job.
    def test_the_real_installed_metadata_matches_the_documented_table(self) -> None:
        documented = checker.documented_permissions(checker.RATIONALE)
        self.assertEqual(
            checker.check(
                documented, checker.parse_metadata(INSTALLED_METADATA), "installed"
            ),
            [],
        )

    def test_reads_an_unset_environment_entry(self) -> None:
        text = METADATA + "\n[Context]\nunset-environment=LD_PRELOAD;\n"
        self.assertIn("--unset-env=LD_PRELOAD", checker.parse_metadata(text))


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
            "--see-name=org.freedesktop.secrets",
            "--system-see-name=org.freedesktop.UDisks2",
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

    # `--own-name=org.mpris.*` owns every name below that prefix, so it is
    # strictly broader than the `org.mpris.MediaPlayer2.*` the list named
    # explicitly, and it went straight through. Naming bad spellings one at a
    # time loses that race, so the rule is now that a wildcard is refused
    # unless it is the reviewed one.
    def test_catches_every_bus_name_wildcard(self) -> None:
        for permission in (
            "--own-name=org.mpris.*",
            "--own-name=org.mpris.MediaPlayer2.*",
            "--own-name=org.gnome.*",
            "--own-name=org.*",
            "--own-name=com.example.*",
            # A wildcard that only starts like the approved one.
            "--own-name=org.mpris.MediaPlayer2.linthra.*.evil",
        ):
            self.assertEqual(
                checker.refused({permission}),
                [permission],
                msg="{} is not refused".format(permission),
            )

    # The two names Linthra actually owns have to survive it, or this stops
    # being a rule and becomes a ban on the feature.
    def test_leaves_linthras_own_names_alone(self) -> None:
        self.assertEqual(
            checker.refused(
                {
                    "--own-name=org.mpris.MediaPlayer2.linthra",
                    "--own-name=org.mpris.MediaPlayer2.linthra.*",
                }
            ),
            [],
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

    # A row describing a refusal that no pattern enforces is the same rot the
    # granted table is already protected from: a page that says the sandbox is
    # narrower than it is.
    def test_a_refusal_row_that_nothing_enforces_fails(self) -> None:
        doc = checker.RATIONALE.read_text(encoding="utf-8").replace(
            "| `--filesystem=home` |", "| `--filesystem=home`, `--share=network` |", 1
        )
        original = checker.RATIONALE
        with written("permissions.md", doc) as path:
            checker.RATIONALE = path
            try:
                code, output = self._main([])
            finally:
                checker.RATIONALE = original
        self.assertEqual(code, 1)
        self.assertIn("--share=network", output)
        self.assertIn("nothing refuses it", output)

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
