#!/usr/bin/env python3
"""Trust-boundary regression tests for the Flutter CI fixer."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (
    ROOT / ".github/workflows/flutter-ci-fixer.yml"
).read_text()


class FlutterCiFixerTrustTests(unittest.TestCase):
    def test_only_main_pushes_are_accepted(self):
        self.assertIn(
            '[[ "$event_name" != "push" || "$head_branch" != "main" ]]',
            WORKFLOW,
        )

    def test_source_workflow_is_verified(self):
        self.assertIn(
            'actions/workflows/ci.yml',
            WORKFLOW,
        )
        self.assertIn(
            '"$run_workflow_id" != "$expected_workflow_id"',
            WORKFLOW,
        )

    def test_stale_main_runs_are_rejected(self):
        self.assertIn(
            'branches/main',
            WORKFLOW,
        )
        self.assertIn(
            '"$head_sha" != "$current_main_sha"',
            WORKFLOW,
        )

    def test_trust_checks_run_before_credentials(self):
        guard = WORKFLOW.index(
            'Skipping CI run outside main.'
        )
        credential = WORKFLOW.index(
            '- name: Check Codex credential'
        )
        self.assertLess(guard, credential)

    def test_publication_requires_main_origin(self):
        publish = WORKFLOW.split(
            "\n  publish:\n", 1
        )[1]
        condition = publish.split(
            "    if: >-", 1
        )[1].split("    runs-on:", 1)[0]

        self.assertIn(
            "needs.fix.outputs.target_branch == 'main'",
            condition,
        )
        self.assertIn(
            "needs.fix.outputs.base_branch == 'main'",
            condition,
        )
        self.assertIn(
            "needs.fix.outputs.source_pr == ''",
            condition,
        )

    def test_publication_still_uses_pull_request(self):
        publish = WORKFLOW.split(
            "\n  publish:\n", 1
        )[1]
        self.assertIn("gh pr create", publish)
        self.assertNotIn("gh pr merge", publish)

class FlutterCiFixerBehaviorTests(unittest.TestCase):
    """Run the real trust guard against mocked GitHub API responses."""

    def run_guard(
        self,
        *,
        event="push",
        branch="main",
        workflow_id="4512",
        head_sha="correct",
        current_sha="correct",
    ):
        import os
        import subprocess
        import textwrap

        start = WORKFLOW.index(
            "          # Only repair failed CI pushes from the current main commit."
        )
        end = WORKFLOW.index(
            "          # A dependency update that breaks CI", start
        )
        guard = textwrap.dedent(WORKFLOW[start:end])

        shell = r"""
set -euo pipefail
GITHUB_REPOSITORY="TheZupZup/Linthra"
event_name="$MOCK_EVENT"
head_branch="$MOCK_BRANCH"
head_sha="$MOCK_HEAD_SHA"
run_json='{"workflow_id": '"$MOCK_WORKFLOW_ID"'}'

gh() {
  [[ "$1" == "api" ]] || return 1
  case "$2" in
    "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml")
      printf '%s\n' 4512 ;;
    "repos/$GITHUB_REPOSITORY/branches/main")
      printf '%s\n' "$MOCK_CURRENT_MAIN" ;;
    *) return 1 ;;
  esac
}
""" + guard + "\necho __ALLOWED__\n"

        result = subprocess.run(
            ["bash", "-c", shell],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "MOCK_EVENT": event,
                "MOCK_BRANCH": branch,
                "MOCK_WORKFLOW_ID": workflow_id,
                "MOCK_HEAD_SHA": head_sha,
                "MOCK_CURRENT_MAIN": current_sha,
            },
        )

        self.assertEqual(
            result.returncode,
            0,
            result.stdout + result.stderr,
        )
        return "__ALLOWED__" in result.stdout.splitlines()

    def test_current_main_push_is_accepted(self):
        self.assertTrue(self.run_guard())

    def test_pull_request_is_rejected(self):
        self.assertFalse(self.run_guard(event="pull_request"))

    def test_other_branch_is_rejected(self):
        self.assertFalse(self.run_guard(branch="feature/test"))

    def test_wrong_workflow_is_rejected(self):
        self.assertFalse(self.run_guard(workflow_id="999"))

    def test_missing_workflow_id_is_rejected(self):
        self.assertFalse(self.run_guard(workflow_id="null"))

    def test_stale_main_commit_is_rejected(self):
        self.assertFalse(self.run_guard(head_sha="old"))


if __name__ == "__main__":
    unittest.main()
