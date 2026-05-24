# Release process (versioning, tagging & GitHub Releases)

This is the canonical reference for how Linthra cuts a release: versioning,
git tagging, changelogs, and the (manual) GitHub-Release flow. The F-Droid
docs reference this document rather than restating the plan.

> **No release has been cut and nothing here publishes to a store.** Linthra
> has no tagged release yet, is **not** on F-Droid, and no APK/AAB has been
> published. Pushing a `v*` tag now builds the release artifacts automatically
> (and attaches them to a matching GitHub Release if one exists), but **creating
> the Release and writing its notes stays manual** — and nothing is published to
> any store or to F-Droid. This document describes the intended process.

## 1. Versioning model

`pubspec.yaml` is the **single source of truth** for the version:

```
version: x.y.z+<versionCode>      # currently 0.1.0-alpha.1+1
```

- **`versionName` = `x.y.z`** — the human-facing [SemVer](https://semver.org/)
  string.
- **`versionCode` = the integer after `+`** — Android's internal build number.

Android reads both from Flutter (`flutter.versionName` / `flutter.versionCode`
in `android/app/build.gradle`); they are **not** hard-coded in Gradle, so
bumping `pubspec.yaml` is enough.

**Rules:**

- `versionCode` **must increase monotonically** on every release. Never reuse or
  decrease it — Android refuses to install an update with an equal/lower code,
  and F-Droid relies on it to order versions.
- `versionName` follows SemVer. Pre-1.0, treat `0.y.z` as "still early; the API
  and feature set can change between minor versions." A SemVer pre-release
  suffix (e.g. `0.1.0-alpha.1`) marks an explicitly unstable build; the matching
  tag is `vX.Y.Z-suffix` and the GitHub Release should be marked **pre-release**.

## 2. Tagging

F-Droid (and our own release tracking) builds from a **git tag**.

- **Format:** an **annotated** tag `vX.Y.Z` (e.g. `v0.1.0`) on the exact commit
  to be released:

  ```sh
  git tag -a v0.1.0 -m "Linthra 0.1.0"
  git push origin v0.1.0
  ```

- The tag's `vX.Y.Z` must match `pubspec.yaml`'s `versionName`. This keeps the
  F-Droid `UpdateCheckMode: Tags ^v[0-9.]+$` / `AutoUpdateMode: Version v%v`
  recommendation (see [fdroid-build-recipe.md §2](./fdroid-build-recipe.md#2-expected-f-droid-metadata-repo-fields))
  working without false positives.
- Tag only commits where CI is green **and** generated files are current (§3).

## 3. Pre-tag checklist

Before creating a release tag:

1. **Bump the version** in `pubspec.yaml` (`versionName` and `versionCode`).
2. **Add a changelog** for the new `versionCode` at
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` (e.g.
   `1.txt` for `0.1.0-alpha.1+1`). Keep it short and factual; this is what
   F-Droid shows. A longer GitHub-Release body can live under
   `docs/release-notes/vX.Y.Z*.md` (see the
   [v0.1.0-alpha.1 draft](./release-notes/v0.1.0-alpha.1.md)).
3. **Regenerate committed generated files** (Drift `*.g.dart`) so they match the
   schema at the tagged commit — run the
   [Generate Drift files workflow](../README.md#generating-drift-files-in-ci) or
   `dart run build_runner build --delete-conflicting-outputs` locally, and commit
   the result. The committed output means the F-Droid build needs no `build_runner`
   prebuild (see [fdroid-build-recipe.md §4](./fdroid-build-recipe.md#4-reproducibility-notes)).
4. **CI is green** (`flutter analyze`, `flutter test`, formatting) on the commit.
5. **Confirm licensing** is still accurate if dependencies changed — re-run the
   [dependency & license audit](./dependency-license-audit.md).
6. Create the annotated tag (§2).

## 4. GitHub Releases (notes manual, artifact build automatic)

Publishing a GitHub Release — and **writing its notes** — stays **manual and
operator-initiated**. No workflow creates a Release or authors notes for you.

What *is* automated is the **artifact build**: the **Android Release Build**
workflow (`.github/workflows/android-release-build.yml`) runs automatically when
a `v*` tag is pushed, builds the APK/AAB, and — if the build is release-signed
and a GitHub Release already exists for that tag — attaches the signed APK/AAB
to it. It never creates a Release, writes notes, publishes to a store, or
submits to F-Droid. The workflow listens only to the tag `push` (not to
`release: published`), so a tag builds exactly once. See
[docs/release-signing.md](./release-signing.md) for the signing details.

### Recommended flow (notes written first, build attaches automatically)

1. Ensure generated files are current (§3) and `pubspec.yaml` matches the tag.
2. Make sure the `LINTHRA_*` keystore secrets are configured (see
   [release-signing.md §2](./release-signing.md#2-required-github-secrets-ci)),
   otherwise the tag build will fall back to debug-signed artifacts that are
   **not** attached to the Release.
3. In the GitHub UI, **create the Release** against a **new** tag `vX.Y.Z`,
   write the notes (the Fastlane changelog from §3 is a good basis), and mark it
   **pre-release** for `-alpha`/`-beta` tags. Creating the Release on a new tag
   also creates and pushes that tag.
4. That tag push triggers **Android Release Build** automatically. When it
   finishes, the **release-signed** `app-release.apk` / `app-release.aab` are
   attached to the Release. Done.

### Alternative flow (tag from git first)

1. Push the annotated tag from git (§2). The build starts automatically and the
   **release-signed** artifacts are produced as workflow artifacts. Because no
   Release exists yet, nothing is attached.
2. Create the GitHub Release for the tag and write its notes, then either
   **re-run** the workflow for that tag (it will now find the Release and
   attach) or download the artifacts from the original run and attach them
   manually.

> A `signed = false` manual run, or any build without the signing secrets,
> produces **`linthra-debug-signed-*`** artifacts. Those are previews only and
> **must never** be attached to a Release.

Manual `workflow_dispatch` runs remain available for ad-hoc test builds and are
unchanged.

> **Signature note.** A GitHub-Release APK is signed with **our** release key,
> while an F-Droid build of the same version is signed with **F-Droid's** key.
> The two cannot be cross-installed as updates of each other. This is expected;
> call it out in the release notes so users don't mix sources. See
> [release-signing.md §6](./release-signing.md#6-f-droid-signing-considerations).

## 5. F-Droid relationship

F-Droid does **not** consume our signed artifacts. When/if Linthra is submitted:

- F-Droid builds **from source** at the `vX.Y.Z` tag on its own infrastructure
  and signs with **F-Droid's** key.
- The recipe tracks new releases via the `vX.Y.Z` tags this process creates.
- The full submission flow, metadata fields, and draft recipe live in
  [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md); overall status and
  blockers live in [docs/fdroid-readiness.md](./fdroid-readiness.md).

## 6. What is automated vs. manual

| Action | Automated? |
| ------ | ---------- |
| Quality CI (analyze/test/format) on PRs & `main` | **Automatic** (`ci.yml`). |
| Debug APK build | Manual (`workflow_dispatch`) + on PRs (`android-debug-apk.yml`). |
| Release APK/AAB build | **Manual** (`workflow_dispatch`) **and automatic on `v*` tags** (`android-release-build.yml`). |
| Attaching signed APK/AAB to a Release | **Automatic** on a `v*` tag build, **only if** the build is release-signed and a Release already exists. |
| Drift code generation | **Manual only** (`generate-drift.yml`, `workflow_dispatch`). |
| Creating a git tag | **Manual** (operator runs `git tag`, or creates a Release on a new tag). |
| Creating a GitHub Release / writing notes | **Manual** (operator, §4). |
| Publishing to a store / F-Droid | **Not done by this repo.** |

CI builds release artifacts on a tag and can attach them to a Release you
created, but it never creates a Release, writes notes, signs a store build, or
submits to F-Droid.

## 7. Remaining blockers before a first release

1. **Real release signing secrets** are configured (`LINTHRA_*`) if a
   GitHub-Release artifact is wanted — see
   [release-signing.md](./release-signing.md). (Not needed for F-Droid itself,
   which signs its own builds.)
2. **A `vX.Y.Z` tag** exists — none does yet.
3. **Decide the `pubspec.lock` policy** for reproducible release builds
   ([fdroid-build-recipe.md §4](./fdroid-build-recipe.md#4-reproducibility-notes)).
4. **Feature-maturity call — made for the alpha.** `0.1.0-alpha.1` ships local
   scanning + playback, background playback / media notification, an Android
   Auto browse foundation, Jellyfin connect/sync/stream, and explicit offline
   downloads. It is published as a sideloadable, pre-release alpha (no F-Droid
   submission yet). See
   [docs/release-notes/v0.1.0-alpha.1.md](./release-notes/v0.1.0-alpha.1.md).

See [fdroid-readiness.md §8](./fdroid-readiness.md#8-remaining-blockers-before-submission)
for the full F-Droid blocker list.

## 8. Related docs

- [docs/release-signing.md](./release-signing.md) — signing keys, CI secrets,
  rotation.
- [docs/fdroid-readiness.md](./fdroid-readiness.md) — F-Droid submission checklist.
- [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md) — F-Droid build recipe.
- [docs/dependency-license-audit.md](./dependency-license-audit.md) — dependency
  licensing.
- [docs/listing-assets.md](./listing-assets.md) — store icon / feature graphic /
  screenshots.
