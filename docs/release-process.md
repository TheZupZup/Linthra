# Release process (versioning, tagging & GitHub Releases)

This is the canonical reference for how Linthra cuts a release: versioning,
git tagging, changelogs, and the (manual) GitHub-Release flow. The F-Droid
docs reference this document rather than restating the plan.

> **Sideloadable alphas only; nothing here publishes to a store.** Linthra has
> tagged pre-release alphas (latest `v0.1.0-alpha.36`) attached to GitHub
> Releases as sideloadable APKs/AABs, but is **not** on F-Droid. Pushing a `v*`
> tag builds the release artifacts automatically. For **alpha/beta/rc** tags the
> build can create a GitHub **pre-release** and attach the APK/AAB to it; for
> **stable** tags it only attaches to a Release you created. **Writing the
> release notes stays manual** — and nothing is published to any store or to
> F-Droid.

## 1. Versioning model

**`pubspec.yaml` is the single source of truth for the version; each release
bumps it to match the tag.** Its `version: <versionName>+<versionCode>` feeds
Android's `versionName`/`versionCode` *and* the in-app display alike, for **every**
build — a plain `flutter build` locally, in CI, and on F-Droid. The release tag
must match it, and CI **fails the build** if they disagree (§4), so the tag,
`pubspec.yaml`, the APK/AAB metadata, and the in-app version can never drift. To
cut a release you bump the version in `pubspec.yaml` (and its in-app mirror) and
tag the matching version (§3) — there are no per-release `--build-name`/
`--build-number` flags to pass anywhere.

```
pubspec.yaml                     ┌─▶ Android versionName/versionCode (APK/AAB)
version: 0.1.0-alpha.36+100036  ─┤
   ( == tag v0.1.0-alpha.36 )    └─▶ AppInfo.version (Settings/About, diagnostics, Jellyfin header)
```

> **Why this matters for F-Droid.** Because the version lives in `pubspec.yaml`
> at each tagged commit, F-Droid reads it directly and **auto-detects new
> releases** (`UpdateCheckMode: Tags` + `UpdateCheckData`, `AutoUpdateMode:
> Version`) from a plain build, instead of needing a hand-written `Builds` entry
> per release. See
> [fdroid-build-recipe.md §2](./fdroid-build-recipe.md#2-expected-f-droid-metadata-repo-fields).

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

The encoding rules live in **`tool/version_from_tag.dart`**, exercised by
`test/tooling/version_from_tag_test.dart`. You use it to **preview** the
`versionCode` for a version before bumping `pubspec.yaml` (§3); CI uses it to
**verify** the tag matches `pubspec.yaml` (§4); and
`test/core/app_info_version_test.dart` uses it to confirm `pubspec.yaml`'s
`versionCode` is the canonical encoding of its `versionName`. Nothing bakes the
version in from the tag — `pubspec.yaml` carries it.

### In-app version (`AppInfo.version`)

Settings/About, the diagnostics / "Report a bug" output, and the Jellyfin
client-version header all read `AppInfo.version` in `lib/core/app_info.dart`.
For **every** build — local, CI release, and F-Droid — it resolves to
`AppInfo._devVersionName`, a `const` that mirrors `pubspec.yaml`'s `versionName`,
so the in-app version always matches the released APK/AAB.
`test/core/app_info_version_test.dart` **fails CI** if `_devVersionName` drifts
from `pubspec.yaml`, or if `pubspec.yaml`'s `versionCode` is not the canonical
encoding of its `versionName` — so the two files (and the tag) can never diverge.

A runtime package-metadata plugin was deliberately avoided: the `const` keeps
`AppInfo.version` resolvable without a plugin and uses the *same* value the
Android build metadata gets, so there is only one effective version per build.
An optional `--dart-define=LINTHRA_VERSION_NAME=...` override remains as an
escape hatch (normally unused; see `AppInfo._definedVersionName`), but standard
builds need it nowhere.

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
supported release tag, **or when `pubspec.yaml` does not match the tag** (§4).
The "Verify the tag matches pubspec.yaml" step runs `tool/version_from_tag.dart`,
which exits non-zero for, e.g.:

- a non-`X.Y.Z` core (`v1.2`, `v1.2.3.4`, `vfoo`);
- an unknown or numberless pre-release (`v1.2.3-alpha`, `v1.2.3-preview.1`);
- SemVer build metadata (`v1.2.3-alpha.1+build`);
- fields outside the encodable range (`v0.100.0`, `v0.1.0-alpha.300`).

The error names the offending tag (or the `pubspec.yaml` mismatch) and the
expected value. Fix it — bump `pubspec.yaml` to match, or delete the bad tag and
push a corrected one — and re-run; nothing stale is ever published.

### Manual builds vs. tag builds

Both a manual `workflow_dispatch` run and a tag build are a plain `flutter build`
that takes the version from `pubspec.yaml`. The difference is only naming and
attachment: a manual run names its artifacts without a tag
(`linthra-<signing>.apk`) so it can't be mistaken for a tagged release, and it
neither verifies against nor attaches to any tag. Only a `v*` tag push verifies
that `pubspec.yaml` matches the tag (§4) and can attach to a Release.

### What to bump for a release

To cut a release you edit the version in **two files in the same commit** (a
drift test enforces they agree), then tag:

1. `pubspec.yaml` → `version: <versionName>+<versionCode>` (e.g.
   `0.1.0-alpha.31+100031`).
2. `lib/core/app_info.dart` → `AppInfo._devVersionName` = the same `versionName`
   (e.g. `0.1.0-alpha.31`).

That's the whole version change. `test/core/app_info_version_test.dart` fails CI
if the two drift, or if the `versionCode` is not the canonical encoding of the
`versionName` (preview it with `tool/version_from_tag.dart`). There is **no
generated version file** and **no `--build-name`/`--build-number` to pass** — the
tag (§2) just has to match what you put in `pubspec.yaml`.

## 2. Tagging

F-Droid (and our own release tracking) builds from a **git tag**.

- **Format:** an **annotated** tag `vX.Y.Z` (e.g. `v0.1.0`) on the exact commit
  to be released:

  ```sh
  git tag -a v0.1.0 -m "Linthra 0.1.0"
  git push origin v0.1.0
  ```

- **The tag must match `pubspec.yaml`'s version.** `vX.Y.Z(-suffix.N)` is the
  `versionName`, and the `+<versionCode>` in `pubspec.yaml` must be its canonical
  encoding (§1). Bump `pubspec.yaml` (and `AppInfo._devVersionName`) **before**
  tagging (§3); the tag build verifies the match and fails fast if they diverge
  (§4). Because `pubspec.yaml` now tracks the tag in lockstep, F-Droid
  auto-detects new releases (`AutoUpdateMode: Version`, `UpdateCheckMode: Tags`)
  instead of needing a manual `Builds` entry per release — see
  [fdroid-build-recipe.md §2](./fdroid-build-recipe.md#2-expected-f-droid-metadata-repo-fields).
- Tag only commits where CI is green **and** generated files are current (§3).

## 3. Pre-tag checklist

Every release requires three version-linked actions — **bump `pubspec.yaml`**,
**add the Fastlane changelog**, and **tag the matching version** — plus the usual
green-CI / generated-files hygiene. The flow below is the *safe* order; doing
the version bump in a merged PR **before** creating the tag is what stops the
"tag pushed against a stale `pubspec.yaml`" failure mode that wasted
`v0.1.0-alpha.35`.

1. **Choose the version** = the tag you will push, e.g. `v0.1.0-alpha.31`.
   Preview its canonical `versionCode`:

   ```sh
   dart run tool/version_from_tag.dart v0.1.0-alpha.31
   # LINTHRA_VERSION_NAME=0.1.0-alpha.31
   # LINTHRA_VERSION_CODE=100031
   ```

2. **Bump the version in `pubspec.yaml` (and its in-app mirror)** — in one
   commit on a PR, since a drift test enforces they agree:
   - `pubspec.yaml` → `version: 0.1.0-alpha.31+100031` (the `versionName` plus the
     canonical `versionCode` from step 1).
   - `lib/core/app_info.dart` → `AppInfo._devVersionName = '0.1.0-alpha.31'`.

   This is **required** — it is the version the release (and F-Droid) ships.
   `test/core/app_info_version_test.dart` fails CI if the two files drift or if
   the `versionCode` is not the canonical encoding of the `versionName`.
3. **Add the Fastlane changelog** named by that `versionCode` at
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` — e.g.
   `100031.txt`. Keep it short and factual; this is what F-Droid shows. A longer
   GitHub-Release body can live under `docs/release-notes/vX.Y.Z*.md` (see the
   [v0.1.0-alpha.9 notes](./release-notes/v0.1.0-alpha.9.md)); the version inside
   it must match the tag.
4. **Regenerate committed generated files** (Drift `*.g.dart`) so they match the
   schema at the tagged commit — run the
   [Generate Drift files workflow](../README.md#generating-drift-files-in-ci) or
   `dart run build_runner build --delete-conflicting-outputs` locally, and commit
   the result. The committed output means the F-Droid build needs no `build_runner`
   prebuild (see [fdroid-build-recipe.md §4](./fdroid-build-recipe.md#4-reproducibility-notes)).
5. **Open the version-bump PR and wait for CI green**
   (`flutter analyze`, `flutter test`, formatting) — this includes the
   version-drift test from step 2.
6. **Confirm licensing** is still accurate if dependencies changed — re-run the
   [dependency & license audit](./dependency-license-audit.md).
7. **Merge the version-bump PR.** Do **not** tag yet — see the warning box
   below.
8. **Pull latest `main` locally** so the tag points at the merged bump:

   ```sh
   git checkout main
   git pull origin main
   ```

9. **Run the release preflight script** — the same script the GitHub release
   workflow runs, so any mismatch fails locally with the same wording instead
   of wasting a tag:

   ```sh
   ./scripts/release_preflight.sh v0.1.0-alpha.31
   # OK: v0.1.0-alpha.31 matches pubspec.yaml version 0.1.0-alpha.31+100031.
   # ...
   # Next safe commands:
   #   git tag -a v0.1.0-alpha.31 -m "Linthra 0.1.0-alpha.31"
   #   git push origin v0.1.0-alpha.31
   ```

   The preflight is pure bash — it needs **no** Flutter/Dart toolchain. It
   checks the same things CI checks: tag shape, canonical `versionCode`,
   `pubspec.yaml` `version:`, and (locally — CI's `flutter test` already
   covers it) `AppInfo._devVersionName`. On any mismatch it prints the
   pushed tag, the expected `pubspec.yaml` version, the actual `pubspec.yaml`
   version, and the exact fix; nothing is tagged.
10. **Create the annotated tag (§2)** — `vX.Y.Z(-suffix.N)` must equal the
    `versionName` you set in `pubspec.yaml` (step 2). The tag build re-verifies
    the match (§4) and fails fast if they diverge.

    ```sh
    git tag -a v0.1.0-alpha.31 -m "Linthra 0.1.0-alpha.31"
    git push origin v0.1.0-alpha.31
    ```

11. **Watch GitHub Actions.** The Android Release Build workflow runs
    automatically on a `v*` tag push, re-verifies `pubspec.yaml` matches the
    tag (§4), builds the APK/AAB, and attaches them to a Release (pre-release
    for alpha/beta/rc; existing Release only for stable).
12. **Install the APK and smoke-test** the build before announcing.

> **Warnings (the "lost-tag" failure mode).**
>
> * **Never push the tag before the version-bump PR is merged into `main`.**
>   If `pubspec.yaml` still lists the previous version when the tag lands, the
>   release workflow's preflight will refuse to build — and the workflow
>   summary will say so explicitly ("Version mismatch: release was not
>   built.") so it is not confused with an APK build failure.
> * **Never reuse or move an already-pushed release tag.** Tags are immutable
>   to downstream consumers (Android updaters, F-Droid mirrors, GitHub Release
>   pages). If a wrong tag was pushed, **skip to the next version** — bump
>   `pubspec.yaml` again, merge, and tag `v0.1.0-alpha.<N+1>`. The skipped
>   version stays unbuilt; that is the safe outcome.
> * **The git tag does NOT include the `+versionCode`.** It looks like
>   `v0.1.0-alpha.31`. `pubspec.yaml`'s `version:` **does** include
>   `+versionCode` — `0.1.0-alpha.31+100031` — and the canonical encoding
>   from `tool/version_from_tag.dart` is what `+` must contain.
> * **A tag/pubspec mismatch is "release was not built"**, not an APK build
>   failure. The preflight step fails *before* `flutter build` runs, so
>   nothing was compiled or signed; the fix is to bump `pubspec.yaml` (or
>   skip to the next version), not to debug Gradle.

## 4. GitHub Releases (notes manual, artifact build & attachment automatic)

Pushing a `v*` tag starts the build. The **Android Release Build** workflow
(`.github/workflows/android-release-build.yml`) runs automatically on a `v*`
tag, **verifies that `pubspec.yaml` matches the tag** (§1; it fails fast on a
mismatch or a malformed tag, before any build), builds the APK/AAB with the
`pubspec.yaml` version, verifies the built APK carries it, and attaches them to a
GitHub Release. **Writing the release notes stays manual** — the workflow never
authors production notes, publishes to a store, or submits to F-Droid. It listens
only to the tag `push` (not to `release: published`), so a tag builds exactly
once. See [docs/release-signing.md](./release-signing.md) for the signing
details.

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
| Verifying the tag matches `pubspec.yaml` (versionName/versionCode) | **Automatic** on a `v*` tag build (`scripts/release_preflight.sh`, encoding-checked against `tool/version_from_tag.dart`); fails fast on a mismatch and the workflow summary explicitly says "Version mismatch: release was not built." so it is not confused with an APK build failure. The same script is intended to be run locally before tagging (§3 step 9). Both manual and tag builds take the version from `pubspec.yaml`. |
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
2. **A `vX.Y.Z` tag** exists — alpha tags through `v0.1.0-alpha.36` have been
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
