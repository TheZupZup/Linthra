#!/usr/bin/env python3
"""The Flatpak smokes clean up what they created, and nothing else (#629).

    python3 test/tooling/flatpak_smoke_cleanup_test.py

A smoke borrows a contributor's machine for a few minutes. What it installed it
may remove; what it found there it may not. The audio and local-library smokes
used to end with `flatpak uninstall -y --delete-data`, which deletes
`~/.var/app/io.github.thezupzup.linthra/` (library database, settings, offline
audio, credentials) and drops the app's entries from Flatpak's permission store,
where the document-portal grants for a user's music folders live.

Both scripts refuse to start when Linthra is already installed, and that was
read as permission for the flag. It is not: an ordinary uninstall removes the
installation and leaves the data tree and the grants behind, so a contributor
who removed an older build has both while `flatpak info` reports nothing
installed. The guard was about the installation; the flag reached past it.

Two kinds of test here:

  * text rules over the smoke scripts, so the flag cannot come back and the
    "was this tree here first" question cannot drift to after the install;
  * the real scripts run end to end against stub `flatpak`, `xvfb-run` and
    `dbus-run-session` binaries in a throwaway HOME, which is how "a
    pre-existing tree survives" gets proven rather than asserted. The stub
    honours `--delete-data` the way flatpak does, so a script that reaches for
    it again fails these tests rather than passing them quietly, and it maps
    the sandbox's XDG directories the way Flatpak does (`XDG_CACHE_HOME` is
    `~/.var/app/<app id>/cache`), which is what makes the in-sandbox negative
    control and the host-side cleanup of its shadow directory meet.

Nothing here needs flatpak, a built package, a display or the network.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
APP_ID = "io.github.thezupzup.linthra"

# The smokes that remove app data, and so have to know whose it is.
# flatpak_launch_smoke.sh installs the package too but removes no app data, and
# flatpak_offline_build_smoke.sh installs nothing at all.
SMOKES_THAT_REMOVE_APP_DATA = (
    "flatpak_audio_smoke.sh",
    "flatpak_local_library_smoke.sh",
    "flatpak_filesystem_smoke.sh",
)

DOC_CLAIMS = {
    "flatpak-audio-smoke.md": (
        "never runs `flatpak uninstall --delete-data`",
        "only if that tree was not already there",
        "permission-store grants are never touched",
    ),
    "flatpak-local-library-smoke.md": (
        "never runs `flatpak uninstall --delete-data`",
        "only if that tree was not already there",
        "Flatpak permission-store grants",
    ),
    "flatpak-ci.md": (
        "None of them uses `flatpak uninstall --delete-data`",
        "removes what it created, and nothing else",
        "only when it was not already there",
    ),
}

# Claims the docs used to make, which were wrong in exactly the way #629
# describes. Named here so a revert of the prose is as loud as a revert of the
# code.
RETIRED_DOC_CLAIMS = {
    "flatpak-audio-smoke.md": "removes on exit, app data included",
    "flatpak-local-library-smoke.md": (
        "the installed app and its data) is removed on exit"
    ),
}


def script_text(name: str) -> str:
    return (ROOT / "scripts" / name).read_text(encoding="utf-8")


def squashed(path: Path) -> str:
    """One-line form of a document, so a wrapped sentence still matches."""
    return " ".join(path.read_text(encoding="utf-8").split())


def commands_only(text: str) -> str:
    """`text` without its whole-line comments.

    The scripts explain at length which flag they deliberately do not use, so a
    search for the flag has to read what they run rather than the prose about
    it.
    """
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


class DestructiveDeletionIsGone(unittest.TestCase):
    def test_nothing_under_scripts_or_workflows_passes_delete_data(self) -> None:
        offenders = []
        searched = 0
        for directory in (ROOT / "scripts", ROOT / ".github" / "workflows"):
            for path in sorted(directory.rglob("*")):
                if not path.is_file():
                    continue
                try:
                    text = path.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                searched += 1
                if "--delete-data" in commands_only(text):
                    offenders.append(str(path.relative_to(ROOT)))
        self.assertGreater(searched, 0, msg="nothing was searched")
        self.assertEqual(
            offenders,
            [],
            msg=(
                "`flatpak uninstall --delete-data` deletes ~/.var/app/<app id>/ "
                "and the app's Flatpak permission-store grants whether or not "
                "the run created them (#629). Remove the tree directly, and "
                "only when the run made it."
            ),
        )


class CleanupOwnership(unittest.TestCase):
    """The guard and the deletion have to be about the same thing."""

    def test_the_data_tree_is_checked_before_anything_is_installed(self) -> None:
        for name in SMOKES_THAT_REMOVE_APP_DATA:
            with self.subTest(script=name):
                text = script_text(name)
                self.assertIn('APP_DATA_DIR="$HOME/.var/app/$APP_ID"', text)
                self.assertIn('[[ -e "$APP_DATA_DIR" ]] && APP_DATA_EXISTED=1', text)
                self.assertLess(
                    text.index("APP_DATA_EXISTED=1"),
                    text.index("flatpak --user install"),
                    msg=(
                        "after the install there is no way to tell whose tree "
                        "it is, so the question has to be asked before it"
                    ),
                )

    def test_the_uninstall_is_plain_and_the_tree_is_still_cleaned_in_ci(
        self,
    ) -> None:
        for name in SMOKES_THAT_REMOVE_APP_DATA:
            with self.subTest(script=name):
                text = script_text(name)
                self.assertIn('flatpak --user uninstall -y "$APP_ID"', text)
                self.assertIn('rm -rf -- "$APP_DATA_DIR"', text)

    def test_every_removal_of_the_tree_sits_behind_the_ownership_guard(
        self,
    ) -> None:
        for name in SMOKES_THAT_REMOVE_APP_DATA:
            with self.subTest(script=name):
                lines = script_text(name).splitlines()
                removals = [
                    index
                    for index, line in enumerate(lines)
                    if 'rm -rf -- "$APP_DATA_DIR"' in line
                ]
                self.assertTrue(removals, msg="the tree is never removed at all")
                for index in removals:
                    guard = self._enclosing_condition(lines, index)
                    self.assertIsNotNone(
                        guard, msg="line {} removes the tree unguarded".format(index + 1)
                    )
                    self.assertIn("! APP_DATA_EXISTED", guard)

    @staticmethod
    def _enclosing_condition(lines: list[str], index: int) -> str | None:
        """The `if`/`elif` line the statement at `index` is governed by."""
        for line in reversed(lines[: index + 1]):
            if re.match(r"\s*(if|elif)\b", line):
                return line
        return None


class TheAudioShadowDirectory(unittest.TestCase):
    """The negative control's own leftovers, now that the tree may stay."""

    def setUp(self) -> None:
        self.text = script_text("flatpak_audio_smoke.sh")

    def test_the_control_and_the_cleanup_agree_on_one_name(self) -> None:
        self.assertIn(
            'SHADOW_DIR_NAME="linthra-audio-smoke-shadow-libmpv"', self.text
        )
        self.assertIn(
            'SHADOW_HOST_DIR="$APP_DATA_DIR/cache/$SHADOW_DIR_NAME"', self.text
        )
        # The in-sandbox control is told the name rather than repeating it,
        # and writes it where Flatpak maps $APP_DATA_DIR/cache.
        self.assertIn('shadow="$XDG_CACHE_HOME/$2"', self.text)
        self.assertIn('sh "$SMOKE_COMMAND" "$SHADOW_DIR_NAME"', self.text)

    def test_it_is_removed_on_its_own_when_the_tree_stays(self) -> None:
        self.assertIn('rm -rf -- "$SHADOW_HOST_DIR"', self.text)
        # Marked before the control runs: a control that died halfway still
        # left a directory behind.
        self.assertLess(
            self.text.index("SHADOW_CREATED=1"),
            self.text.index('expect_failure "a libmpv that carries'),
        )

    def test_the_control_itself_is_unchanged(self) -> None:
        # The cleanup rewrite must not have softened what the control proves.
        self.assertIn("for soname in libmpv.so libmpv.so.2 libmpv.so.1", self.text)
        self.assertIn('cp -L "$donor" "$shadow/$soname"', self.text)
        self.assertIn('LD_LIBRARY_PATH="$shadow', self.text)


class DocumentedLocalBehaviour(unittest.TestCase):
    """The docs that tell contributors to run these locally."""

    def test_each_one_says_what_a_run_may_delete(self) -> None:
        for name, claims in DOC_CLAIMS.items():
            with self.subTest(doc=name):
                text = squashed(ROOT / "docs" / name)
                self.assertIn("~/.var/app/io.github.thezupzup.linthra/", text)
                for claim in claims:
                    self.assertIn(claim, text)

    def test_the_old_promise_to_delete_app_data_is_gone(self) -> None:
        for name, claim in RETIRED_DOC_CLAIMS.items():
            with self.subTest(doc=name):
                self.assertNotIn(claim, squashed(ROOT / "docs" / name))

    def test_the_uninstall_table_names_the_permission_store(self) -> None:
        # The flag's second reach is the one a data-directory check cannot
        # cover, so the table that documents it has to say so.
        text = squashed(ROOT / "docs" / "flatpak-development.md")
        self.assertIn("entries in Flatpak's permission store", text)
        self.assertIn("document-portal grants", text)


FLATPAK_STUB = '''#!/usr/bin/env python3
"""A `flatpak` just real enough to exercise a smoke harness's cleanup path."""

import json
import os
import shutil
import subprocess
import sys

APP_DIR = os.environ["LINTHRA_STUB_APP_DIR"]
PERMISSION_STORE = os.environ["LINTHRA_STUB_PERMISSION_STORE"]
SCENARIO = os.environ["LINTHRA_STUB_SCENARIO"]
LOG = os.environ["LINTHRA_STUB_LOG"]
INSTALLED_MARKER = os.path.join(APP_DIR, ".stub-installed")

args = sys.argv[1:]


def record(event):
    with open(LOG, "a", encoding="utf-8") as handle:
        print(json.dumps(event), file=handle)


record({"argv": args})
positional = [a for a in args if not a.startswith("-")]
command = positional[0] if positional else ""

if command == "info":
    sys.exit(0 if os.path.exists(INSTALLED_MARKER) else 1)

if command == "install":
    # Real flatpak creates the app's private tree when it installs the app.
    for name in ("cache", "config", "data"):
        os.makedirs(os.path.join(APP_DIR, name), exist_ok=True)
    open(INSTALLED_MARKER, "w").close()
    sys.exit(0)

if command == "uninstall":
    if os.path.exists(INSTALLED_MARKER):
        os.remove(INSTALLED_MARKER)
    # A plain uninstall leaves ~/.var/app and the permission store alone.
    # --delete-data is what #629 is about, so the stub performs it: a script
    # that reaches for the flag again fails the tests instead of passing them.
    if "--delete-data" in args:
        shutil.rmtree(APP_DIR, ignore_errors=True)
        if os.path.exists(PERMISSION_STORE):
            os.remove(PERMISSION_STORE)
    sys.exit(0)

if command != "run":
    # kill, remote-add, remote-delete, override --show, and anything else a
    # harness asks for on the way past.
    sys.exit(0)

script = None
rest = []
if "-c" in args:
    index = args.index("-c")
    script = args[index + 1]
    rest = args[index + 2 :]

if script is not None and '[ -x "$1" ]' in script:
    sys.exit(0)

if script is not None and "shadow=" in script:
    # The negative control. Run it for real, with the sandbox's XDG paths
    # mapped the way Flatpak maps them, so the directory it writes lands where
    # the harness's cleanup looks for it.
    shadow_name = rest[2] if len(rest) > 2 else ""
    env = dict(os.environ)
    env["HOME"] = APP_DIR
    env["XDG_CACHE_HOME"] = os.path.join(APP_DIR, "cache")
    env["XDG_CONFIG_HOME"] = os.path.join(APP_DIR, "config")
    env["XDG_DATA_HOME"] = os.path.join(APP_DIR, "data")
    status = subprocess.run(["sh", "-c", script, *rest], env=env).returncode
    record(
        {
            "shadow_dir_after_control": os.path.isdir(
                os.path.join(APP_DIR, "cache", shadow_name)
            )
        }
    )
    if status == 3:
        # "I could not set this control up" travels back unchanged.
        sys.exit(3)
    print("error: the library opened as libmpv exports none of mpv's symbols")
    sys.exit(1)

if SCENARIO == "audio":
    if "--env=LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX=/app/" in args:
        print("libmpv in use: /app/lib/libmpv.so.2")
        print("PASS: Linux native audio lifecycle smoke passed.")
        sys.exit(0)
    print("error: libmpv in use: /usr/lib/libmpv.so.2, outside the required prefix")
    sys.exit(1)

mode = ""
for arg in args:
    if arg.startswith("--env=LINTHRA_LOCAL_LIBRARY_SMOKE_MODE="):
        mode = arg.split("=", 2)[2]
print("PASS: local-library smoke ({}) passed.".format(mode))
sys.exit(0)
'''

XVFB_RUN_STUB = '''#!/usr/bin/env python3
"""`xvfb-run` without an X server: run the command, drop the display flags."""

import os
import sys

args = [
    a
    for a in sys.argv[1:]
    if not a.startswith("--auto-servernum") and not a.startswith("--server-args")
]
os.execvp(args[0], args)
'''

DBUS_RUN_SESSION_STUB = '''#!/usr/bin/env python3
"""`dbus-run-session` without a bus: run the command after the `--`."""

import os
import sys

args = sys.argv[1:]
if args and args[0] == "--":
    args = args[1:]
os.execvp(args[0], args)
'''


class RunAgainstStubs(unittest.TestCase):
    """The scripts themselves, run end to end in a throwaway HOME."""

    maxDiff = None

    def _run(self, script: str, scenario: str, *, preexisting: bool) -> SimpleNamespace:
        tmp = Path(tempfile.mkdtemp(prefix="linthra-smoke-cleanup-"))
        self.addCleanup(shutil.rmtree, tmp, True)

        home = tmp / "home"
        bin_dir = tmp / "bin"
        repo = tmp / "repo"
        for path in (home, bin_dir, repo):
            path.mkdir(parents=True)
        (repo / "config").write_text("[core]\n", encoding="utf-8")

        app_dir = home / ".var" / "app" / APP_ID
        # Flatpak's permission store lives outside ~/.var/app entirely, which is
        # the whole reason a check on the data tree cannot authorise
        # --delete-data.
        store = home / ".local" / "share" / "flatpak" / "db" / "documents"
        store.parent.mkdir(parents=True)
        store.write_bytes(b"a document-portal grant for a music folder\n")

        library = app_dir / "data" / "linthra" / "library.sqlite"
        settings = app_dir / "config" / "settings.json"
        if preexisting:
            library.parent.mkdir(parents=True)
            library.write_text("a contributor's library\n", encoding="utf-8")
            settings.parent.mkdir(parents=True)
            settings.write_text('{"volume": 0.4}\n', encoding="utf-8")

        log = tmp / "flatpak-calls.jsonl"
        for name, source in (
            ("flatpak", FLATPAK_STUB),
            ("xvfb-run", XVFB_RUN_STUB),
            ("dbus-run-session", DBUS_RUN_SESSION_STUB),
        ):
            stub = bin_dir / name
            stub.write_text(source, encoding="utf-8")
            stub.chmod(0o755)

        env = {
            "PATH": "{}:{}".format(bin_dir, os.environ.get("PATH", "")),
            "HOME": str(home),
            "TMPDIR": str(tmp),
            "USER": "smoke-user",
            "LINTHRA_FLATPAK_SMOKE_TIMEOUT": "120",
            "LINTHRA_STUB_APP_DIR": str(app_dir),
            "LINTHRA_STUB_PERMISSION_STORE": str(store),
            "LINTHRA_STUB_SCENARIO": scenario,
            "LINTHRA_STUB_LOG": str(log),
        }
        process = subprocess.run(
            ["bash", str(ROOT / "scripts" / script), str(repo)],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )
        calls = []
        if log.exists():
            calls = [json.loads(line) for line in log.read_text().splitlines() if line]
        return SimpleNamespace(
            process=process,
            output=process.stdout + process.stderr,
            calls=calls,
            home=home,
            app_dir=app_dir,
            store=store,
            library=library,
            settings=settings,
            shadow=app_dir / "cache" / "linthra-audio-smoke-shadow-libmpv",
        )

    def assertRanToCompletion(self, run: SimpleNamespace, banner: str) -> None:
        self.assertEqual(run.process.returncode, 0, msg=run.output)
        self.assertIn(banner, run.output)

    def assertPreexistingDataSurvived(self, run: SimpleNamespace) -> None:
        for path, expected in (
            (run.library, "a contributor's library\n"),
            (run.settings, '{"volume": 0.4}\n'),
        ):
            self.assertTrue(
                path.exists(),
                msg="the smoke deleted {}, which was here before it ran".format(
                    path.name
                ),
            )
            self.assertEqual(path.read_text(), expected)

    def assertCleanupWasNotDestructive(self, run: SimpleNamespace) -> None:
        uninstalls = [c["argv"] for c in run.calls if "uninstall" in c.get("argv", [])]
        self.assertTrue(uninstalls, msg="the run never uninstalled anything")
        for argv in uninstalls:
            self.assertNotIn("--delete-data", argv)
        self.assertTrue(
            run.store.exists(),
            msg="a permission-store grant was removed by a smoke run",
        )

    # --- the audio smoke ---------------------------------------------------

    def test_audio_smoke_removes_the_tree_its_own_install_created(self) -> None:
        run = self._run("flatpak_audio_smoke.sh", "audio", preexisting=False)
        self.assertRanToCompletion(run, "PASS: Flatpak audio playback smoke complete.")
        self.assertShadowWasWritten(run)
        self.assertFalse(
            run.app_dir.exists(),
            msg="a tree this run created was left on the machine",
        )
        self.assertCleanupWasNotDestructive(run)

    def test_audio_smoke_keeps_a_tree_it_found(self) -> None:
        run = self._run("flatpak_audio_smoke.sh", "audio", preexisting=True)
        self.assertRanToCompletion(run, "PASS: Flatpak audio playback smoke complete.")
        self.assertPreexistingDataSurvived(run)
        self.assertCleanupWasNotDestructive(run)
        # The tree stays, so the negative control's shadow directory inside it
        # has to be removed on its own.
        self.assertShadowWasWritten(run)
        self.assertFalse(
            run.shadow.exists(),
            msg="the negative control's shadow directory outlived the run",
        )

    def assertShadowWasWritten(self, run: SimpleNamespace) -> None:
        self.assertTrue(
            any(call.get("shadow_dir_after_control") for call in run.calls),
            msg=(
                "the negative control never created its shadow directory, so "
                "this test proves nothing about cleaning it up"
            ),
        )

    # --- the local-library smoke ------------------------------------------

    def test_local_library_smoke_removes_the_tree_its_own_install_created(
        self,
    ) -> None:
        run = self._run(
            "flatpak_local_library_smoke.sh", "local-library", preexisting=False
        )
        self.assertRanToCompletion(
            run, "PASS: Flatpak local-library sandbox smoke complete."
        )
        self.assertFalse(
            run.app_dir.exists(),
            msg="a tree this run created was left on the machine",
        )
        self.assertCleanupWasNotDestructive(run)
        self.assertFixtureFoldersAreGone(run)

    def test_local_library_smoke_keeps_a_tree_it_found(self) -> None:
        run = self._run(
            "flatpak_local_library_smoke.sh", "local-library", preexisting=True
        )
        self.assertRanToCompletion(
            run, "PASS: Flatpak local-library sandbox smoke complete."
        )
        self.assertPreexistingDataSurvived(run)
        self.assertCleanupWasNotDestructive(run)
        self.assertFixtureFoldersAreGone(run)

    def assertFixtureFoldersAreGone(self, run: SimpleNamespace) -> None:
        leftovers = sorted(
            str(path.name)
            for path in run.home.iterdir()
            if path.name.startswith(".linthra-local-library-sentinel")
            or path.name.startswith("linthra-local-library-")
        )
        self.assertEqual(leftovers, [], msg="the fixture library was left behind")


if __name__ == "__main__":
    unittest.main(verbosity=2)
