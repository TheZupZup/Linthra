# Flutter CI fixer

Linthra has a guarded Codex-based repair workflow for failed **Flutter checks** jobs.

## What it does

When `CI` fails, the fixer accepts only a failed push to the current `main` commit from this repository. It verifies the source workflow and requires the failing job to be `Flutter checks`.

Pull-request runs, forks, other branches, and stale commits are skipped.

A validated fix is published in a dedicated `codex/ci-fix-*` pull request. The fixer never commits directly to `main` or merges automatically.

The agent gets at most two repair attempts. A patch is published only after all of these pass on the runner:

```text
flutter pub get --enforce-lockfile
dart format --set-exit-if-changed .
flutter analyze
flutter test
./scripts/check_secrets.sh
```

## One-time setup

Two repository Actions secrets are required:

- `OPENAI_API_KEY` — used only by the read-token Codex repair job.
- `CI_FIXER_GITHUB_TOKEN` — a dedicated fine-grained GitHub token used only by the separate publication job.

The publication token must be able to push branches and create/comment on pull requests. For a fine-grained personal access token, grant repository access to Linthra with **Contents: read/write**, **Pull requests: read/write**, and **Issues: read/write**. Do not give this token to the Codex job.

A dedicated publication token is intentional: pushes or PRs created with the workflow `GITHUB_TOKEN` do not trigger normal follow-up workflows. Publishing with `CI_FIXER_GITHUB_TOKEN` lets GitHub run the repository's standard `pull_request`/`push` CI naturally on the repaired commit instead of relying on a manual-dispatch workaround.

If `OPENAI_API_KEY` is absent, the fixer safely no-ops with a notice. If a repair is validated but `CI_FIXER_GITHUB_TOKEN` is absent, publication fails before any repository write occurs.

## Safety boundaries

The fixer only accepts CI pushes to the current `main` commit. It rejects pull-request runs and refuses to process its own `codex/ci-fix-*` branches, preventing an automatic repair loop.

The Codex job itself only receives read permissions. It cannot push. The publication credential is available only in the separate publish job after a patch has passed the full local verification gate.

The publish guard rejects changes to protected areas including:

- `.github/`
- license/copyright notice files at any path depth
- `pubspec.yaml` and the toolchain pins (`.flutter-version`, `.java-version`)
- F-Droid/store metadata and release notes
- secret-scan policy
- analyzer policy
- signing keys and keystore configuration

New files are marked intent-to-add before each secret scan so generated files are scanned before a patch can be published.

The prompt also forbids deleting/skipping tests, weakening assertions, blanket ignores, telemetry, version bumps, releases, and unrelated refactors.

Before publication, the fixer verifies that the target branch still points to the commit it repaired. If `main` has moved, publication is aborted instead of applying a stale patch. The repair is proposed through a separate pull request.

## Manual retry

The workflow also supports `workflow_dispatch`. Open **Actions → Flutter CI fixer → Run workflow** and provide the numeric ID of a failed `CI` run. Only a failed push to the current `main` commit can qualify; old runs and pull-request runs are skipped.