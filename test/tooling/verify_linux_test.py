#!/usr/bin/env python3
"""`scripts/verify_linux.sh` keeps going after its native audio smoke.

    python3 test/tooling/verify_linux_test.py

The script runs its checks one after another and keeps going past a failed
one, so a single run reports everything: the native audio lifecycle smoke, then
`flutter build linux --release` and the summary of failed steps.

The smoke's step is run here for real, in a throwaway checkout under a
directory with a space in its name, against a stub bundle and a stub
`xvfb-run`. What has to hold is that the steps after it still run, and that the
ALSA config the script writes for the smoke is removed.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify_linux.sh"

# The script's last line runs every check; the copy here leaves it out, so the
# functions can be sourced and one step run on its own.
RUNS_MAIN = re.compile(r'^main "\$@"$', re.MULTILINE)

# Runs the smoke's step and the one after it, then says which steps failed.
STEPS = (
    'source "$1"; '
    'run_step "audio smoke" run_audio_smoke; '
    'run_step "next step" true; '
    'printf "failed: %s\\n" "${FAILED[*]-}"'
)


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents)
    path.chmod(0o755)


class AudioSmokeStepTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="linthra verify linux ")
        self.checkout = Path(self._tmp.name)
        self.recorded = self.checkout / "alsa-config-path"

        text = SCRIPT.read_text()
        self.assertEqual(
            len(RUNS_MAIN.findall(text)),
            1,
            'the script should end by running main "$@"',
        )
        (self.checkout / "scripts").mkdir()
        self.script = self.checkout / "scripts" / "verify_linux.sh"
        self.script.write_text(RUNS_MAIN.sub("", text, count=1))

        # The bundle the smoke runs: notes the ALSA config it was given.
        bundle = self.checkout / "build" / "linux" / "x64" / "release" / "bundle"
        bundle.mkdir(parents=True)
        write_executable(
            bundle / "linthra",
            "#!/bin/sh\n"
            f'printf "%s" "$ALSA_CONFIG_PATH" > "{self.recorded}"\n'
            'exit "${SMOKE_EXIT:-0}"\n',
        )
        # Headless runs go through xvfb-run; this one just runs the command.
        (self.checkout / "bin").mkdir()
        write_executable(
            self.checkout / "bin" / "xvfb-run",
            '#!/bin/sh\nshift\nexec "$@"\n',
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_smoke_then_next_step(
        self, smoke_exit: int = 0
    ) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env["PATH"] = f"{self.checkout / 'bin'}{os.pathsep}{env.get('PATH', '')}"
        env["SMOKE_EXIT"] = str(smoke_exit)
        return subprocess.run(
            ["bash", "-c", STEPS, "bash", str(self.script)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_config_removed(self) -> None:
        config = Path(self.recorded.read_text())
        self.assertFalse(
            config.exists(), "the ALSA config written for the smoke is left behind"
        )

    def test_the_steps_after_the_audio_smoke_still_run(self) -> None:
        result = self.run_smoke_then_next_step()

        self.assertEqual(
            result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
        self.assertIn("==> next step", result.stdout)
        self.assertIn("failed: \n", result.stdout)
        self.assert_config_removed()

    def test_a_failed_audio_smoke_is_reported_and_the_steps_after_it_still_run(
        self,
    ) -> None:
        result = self.run_smoke_then_next_step(smoke_exit=3)

        self.assertEqual(
            result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
        self.assertIn("==> next step", result.stdout)
        self.assertIn("failed: audio smoke\n", result.stdout)
        self.assert_config_removed()


if __name__ == "__main__":
    unittest.main()
