# Release process (versioning, tagging & GitHub Releases)

This is the canonical reference for how Linthra cuts a release: versioning,
git tagging, changelogs, and the (manual) GitHub-Release flow. The F-Droid
docs reference this document rather than restating the plan.

> **Sideloadable alphas only; nothing here publishes to a store.** Linthra has
> tagged pre-release alphas (latest `v0.1.0-alpha.15`) attached to GitHub
> Releases as sideloadable APKs/AABs, but is **not** on F-Droid. Pushing a `v*`
> tag builds the release artifacts automatically. For **alpha/beta/rc** tags the
> build can create a GitHub **pre-release** and attach the APK/AAB to it; for
> **stable** tags it only attaches to a Release you created. **Writing the
> release notes stays manual** — and nothing is published to any store or to
> F-Droid.

## 1. Versioning model

**The Git tag is the source of truth for a release; `pubspec.yaml` is the
default for local/dev builds.** A tagged release build derives its version from
the tag and bakes the same value into the APK/AAB metadata *and* the in-app
display, so they can never drift. You do **not** edit any version constant to
cut a release — you just push the tag.

```
                       ┌─ --build-name / --build-number ─▶ Android versionName/versionCode (APK/AAB)
push tag  ─▶  parse ───┤
v0.1.0-alpha.16        └─ --dart-define=LINTHRA_VERSION_NAME ─▶ AppInfo.version (Settings/About, diagnostics, Jellyfin header)
```

### versionName

The tag with its leading `v` stripped, **pre-release suffix preserved**:

| Tag               | versionName      |
| ----------------- | ---------------- |
| `v0.1.0-alpha.16` | `0.1.0-alpha.16` |
| `v0.1.0-beta.1`   | `0.1.0-beta.1`   |
| `v0.1.0-rc.1`     | `0.1.0-rc.1`     |
| `v0.1.0`          | `0.1.0`          |
| `v1.2.3`          | `1.2.3`          |

### versionCode (fully encoded, strictly monotonic)

`versionCode` is computed from the version so it can **never go backwards**, with
no manual counter to maintain:

```
versionCode = MAJOR*10_000_000 + MINOR*100_000 + PATCH*1_000 + preReleaseRank
```

`preReleaseRank` orders the pre-release tiers below the stable release of the
*same* `x.y.z`: `alpha.N → N`, `beta.N → 300 + N`, `rc.N → 600 + N`, stable
`→ 999`. Worked examples:

| Tag               | versionCode |
| ----------------- | ----------- |
| `v0.1.0-alpha.16` | `100016`    |
| `v0.1.0-beta.1`   | `100301`    |
| `v0.1.0-rc.1`     | `100601`    |
| `v0.1.0`          | `100999`    |
| `v0.1.1-alpha.1`  | `101001`    |
| `v0.2.0-alpha.1`  | `200001`    |
| `v1.2.3`          | `10203999`  |

The fields are bounded (minor/patch ≤ 99, pre-release `N` ≤ 299) so the result
stays a valid Android `versionCode` (1‥2,100,000,000) and the tiers never
collide. A tag that violates these bounds, or is otherwise malformed, **fails
the build** (see "Malformed tags" below) instead of shipping guessed metadata.

> **Note — the encoding intentionally jumps from the legacy hand-numbered
> codes.** Alphas through `0.1.0-alpha.15` used `versionCode = N` (so `+15`).
> The first encoded build, `v0.1.0-alpha.16`, is `100016` — far larger than `15`,
> so it is still a strict increase (Android only requires monotonicity; gaps are
> fine). F-Droid changelog files are named by `versionCode`, so new entries live
> at `fastlane/metadata/android/en-US/changelogs/<encoded code>.txt` (e.g.
> `100016.txt`); the historical `1.txt`/`9.txt`/`15.txt` stay as-is.

The parsing/encoding rules live in **`tool/version_from_tag.dart`** (the single
source of truth), exercised by `test/tooling/version_from_tag_test.dart`. The
release workflow calls it; nothing else needs to know the formula.

### In-app version (`AppInfo.version`)

Settings/About, the diagnostics / "Report a bug" output, and the Jellyfin
client-version header all read `AppInfo.version` in `lib/core/app_info.dart`:

- **Tagged release build:** the workflow passes
  `--dart-define=LINTHRA_VERSION_NAME=<derived versionName>`, so `AppInfo.version`
  is exactly the tag's version — matching the APK/AAB metadata.
- **Local/dev build & the test suite** (no dart-define): `AppInfo.version` falls
  back to `AppInfo._devVersionName`, a `const` that mirrors `pubspec.yaml`'s
  `versionName`. `test/core/app_info_version_test.dart` **fails CI if that
  fallback drifts from `pubspec.yaml`**, so the two stay aligned for dev builds.

A runtime package-metadata plugin was deliberately avoided: the dart-define keeps
`AppInfo.version` resolvable without a plugin and uses the *same* value the
Android build metadata gets, so there is only one effective version per build.

### Rules

- `versionCode` **increases monotonically** by construction — never reuse or
  decrease it. Android refuses to install an update with an equal/lower code, and
  F-Droid relies on it to order versions.
- `versionName` follows SemVer. Pre-1.0, treat `0.y.z` as "still early; the API
  and feature set can change between minor versions." A SemVer pre-release suffix
  (e.g. `0.1.0-alpha.1`) marks an explicitly unstable build; its tag is
  `vX.Y.Z-suffix` and the GitHub Release should be marked **pre-release**.

### Malformed tags

The build **fails fast** — before producing any artifact — when the tag is not a
supported release tag. `tool/version_from_tag.dart` exits non-zero (failing the
"Derive version from tag" step) for, e.g.:

- a non-`X.Y.Z` core (`v1.2`, `v1.2.3.4`, `vfoo`);
- an unknown or numberless pre-release (`v1.2.3-alpha`, `v1.2.3-preview.1`);
- SemVer build metadata (`v1.2.3-alpha.1+build`);
- fields outside the encodable range (`v0.100.0`, `v0.1.0-alpha.300`).

The error names the offending tag and the expected format. Fix it (delete the
bad tag, push a corrected one) and re-run — nothing stale is ever published.

### Manual builds vs. tag builds

A manual `workflow_dispatch` run is **not** a release: it passes none of the
version flags, builds the `pubspec.yaml` version, and names its artifacts without
a tag (`linthra-<signing>.apk`) so it can't be mistaken for a tagged release.
Only a `v*` tag push derives the version from the tag.

### Do not hand-edit version metadata

There is **no generated version file to edit.** For a release, edit nothing — push
the tag. `AppInfo._devVersionName` and `pubspec.yaml` only affect local/dev builds
and are kept in lock-step by the drift test; bump them together (in one commit) if
you want dev builds to show a newer baseline, but they are not what a release
ships.

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

1. **Choose the version** = the tag you will push, e.g. `v0.1.0-alpha.16`. The
   build derives `versionName`/`versionCode` from it automatically (§1); there is
   **no version constant to bump** for the release. Preview the derived values:

   ```sh
   dart run tool/version_from_tag.dart v0.1.0-alpha.16
   # LINTHRA_VERSION_NAME=0.1.0-alpha.16
   # LINTHRA_VERSION_CODE=100016
   ```

2. **(Optional) Refresh the dev baseline.** `pubspec.yaml`'s `version:` and
   `AppInfo._devVersionName` only drive local/dev builds; bump them together (the
   drift test `test/core/app_info_version_test.dart` enforces they match) if you
   want `flutter run` to show the new version. **Not required** for the release —
   the tag overrides both.
3. **Add a changelog** named by the **derived `versionCode`** at
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` — e.g.
   `100016.txt` for `v0.1.0-alpha.16` (use the value `tool/version_from_tag.dart`
   prints). Keep it short and factual; this is what F-Droid shows. A longer
   GitHub-Release body lives under `docs/release-notes/vX.Y.Z*.md` (see the
   [v0.1.0-alpha.9 notes](./release-notes/v0.1.0-alpha.9.md)). The `vX.Y.Z` in the
   file name and the version inside it must match the tag.
4. **Regenerate committed generated files** (Drift `*.g.dart`) so they match the
   schema at the tagged commit — run the
   [Generate Drift files workflow](../README.md#generating-drift-files-in-ci) or
   `dart run build_runner build --delete-conflicting-outputs` locally, and commit
   the result. The committed output means the F-Droid build needs no `build_runner`
   prebuild (see [fdroid-build-recipe.md §4](./fdroid-build-recipe.md#4-reproducibility-notes)).
5. **CI is green** (`flutter analyze`, `flutter test`, formatting) on the
   commit — this includes the version-drift test from step 2.
6. **Confirm licensing** is still accurate if dependencies changed — re-run the
   [dependency & license audit](./dependency-license-audit.md).
7. Create the annotated tag (§2).

## 4. GitHub Releases (notes manual, artifact build & attachment automatic)

Pushing a `v*` tag starts the build. The **Android Release Build** workflow
(`.github/workflows/android-release-build.yml`) runs automatically on a `v*`
tag, **derives the version from the tag** (§1), builds the APK/AAB with that
version, verifies the built APK carries it, and attaches them to a GitHub
Release. **Writing the
release notes stays manual** — the workflow never authors production notes,
publishes to a store, or submits to F-Droid. It listens only to the tag `push`
(not to `release: published`), so a tag builds exactly once. See
[docs/release-signing.md](./release-signing.md) for the signing details.

The attachment behavior depends on whether the tag is a **pre-release**:

- **Alpha/beta/rc tags** (any tag containing `alpha`, `beta`, or `rc`, e.g.
  `v0.1.0-alpha.1`) may attach **debug-signed** *or* **release-signed**
  artifacts to a GitHub **pre-release**. If no Release exists for the tag yet,
  the workflow **creates one as a pre-release** with placeholder notes (edit
  them afterwards). Debug-signed artifacts are clearly named and labeled as
  **testing-only** builds — never as a production release.
- **Stable tags** (e.g. `v1.0.0`) **require release signing**. If the
  `LINTHRA_*` secrets are missing, the tag build **fails fast** rather than
  shipping a debug-signed build. Stable assets are only uploaded to a Release
  that **already exists**; the workflow does not auto-create stable Releases.

Artifacts are named with the version and signing label, e.g.
`linthra-v0.1.0-alpha.1-debug-signed.apk` or
`linthra-v0.1.0-alpha.1-release-signed.aab`.

### Recommended flow for an alpha/beta/rc pre-release (fully automatic)

1. Ensure generated files are current (§3) and `pubspec.yaml` matches the tag.
2. (Optional but recommended) configure the `LINTHRA_*` keystore secrets (see
   [release-signing.md §2](./release-signing.md#2-required-github-secrets-ci))
   so the attached artifacts are release-signed. Without them, the pre-release
   gets clearly-labeled **debug-signed** artifacts for testing only.
3. Push the annotated tag (§2), e.g. `v0.1.0-alpha.1`. The build runs, and a
   GitHub **pre-release** is created (if absent) with the APK/AAB attached.
4. Edit the auto-created pre-release notes (the Fastlane changelog from §3 is a
   good basis). Done.

### Recommended flow for a stable release (notes written first)

1. Ensure generated files are current (§3) and `pubspec.yaml` matches the tag.
2. Configure the `LINTHRA_*` keystore secrets — **required** for stable tags
   (the tag build fails without them).
3. In the GitHub UI, **create the Release** against a **new** stable tag
   `vX.Y.Z`, write the notes. Creating the Release on a new tag also creates and
   pushes that tag.
4. That tag push triggers **Android Release Build** automatically. When it
   finishes, the **release-signed** APK/AAB are attached to the Release. Done.

### Alternative flow (tag from git first)

1. Push the annotated tag from git (§2). For a stable tag with no Release yet,
   the **release-signed** artifacts are produced as workflow artifacts but
   nothing is attached.
2. Create the GitHub Release for the tag and write its notes, then either
   **re-run** the workflow for that tag (it will now find the Release and
   attach) or download the artifacts from the original run and attach them
   manually.

> A `signed = false` manual run, or any build without the signing secrets,
> produces **debug-signed** artifacts. Those are previews/testing builds only.
> They may be attached to an alpha/beta/rc **pre-release** (clearly labeled), but
> **must never** be attached to a stable Release.

Manual `workflow_dispatch` runs remain available for ad-hoc test builds; they
never touch any GitHub Release.

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
| Deriving versionName/versionCode + in-app version from the tag | **Automatic** on a `v*` tag build (`tool/version_from_tag.dart`); manual runs use `pubspec.yaml`. |
| Attaching APK/AAB to a Release | **Automatic** on a `v*` tag build. Alpha/beta/rc tags attach (debug- or release-signed) to a **pre-release**; stable tags attach **release-signed** assets to an existing Release only. |
| Creating a GitHub **pre-release** (alpha/beta/rc) | **Automatic** on the tag build if no Release exists yet (placeholder notes; edit afterwards). |
| Creating a stable GitHub Release | **Manual** (operator, §4); never auto-created. |
| Drift code generation | **Manual only** (`generate-drift.yml`, `workflow_dispatch`). |
| Creating a git tag | **Manual** (operator runs `git tag`, or creates a Release on a new tag). |
| Writing production release notes | **Manual** (operator, §4). |
| Publishing to a store / F-Droid | **Not done by this repo.** |

CI builds release artifacts on a tag and attaches them: it can auto-create a
**pre-release** for alpha/beta/rc tags, but it never auto-creates a stable
Release, writes production notes, signs a store build, or submits to F-Droid.

## 7. Remaining blockers before a first release

1. **Real release signing secrets** are configured (`LINTHRA_*`) if a
   GitHub-Release artifact is wanted — see
   [release-signing.md](./release-signing.md). (Not needed for F-Droid itself,
   which signs its own builds.)
2. **A `vX.Y.Z` tag** exists — alpha tags through `v0.1.0-alpha.15` have been
   cut; F-Droid submission itself is still pending the other blockers.
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
