# Release process (versioning, tagging & GitHub Releases)

This is the canonical reference for how Linthra cuts a release: versioning,
git tagging, changelogs, and the (manual) GitHub-Release flow. The F-Droid
docs reference this document rather than restating the plan.

> **Linthra is now on F-Droid.** The accepted F-Droid build is
> `0.1.0-alpha.40+100040`; F-Droid builds it from source at the git tag and signs
> with its own key. The **next clean release should be the stable `v0.1.1`**
> (`pubspec.yaml` version `0.1.1+101999` — see the *Next release* checklist just
> below, and §1 for the encoding). Pushing a `v*` tag still builds the
> GitHub-Release artifacts automatically: **alpha/beta/rc** tags can create a
> GitHub **pre-release** and attach the APK/AAB; a **stable** tag attaches only to
> a Release you created and **requires** the release-signing secrets (§4).
> **Writing the release notes stays manual.** F-Droid signs and publishes its own
> builds; this repo never publishes to a store or pushes to fdroiddata.

## Next release: `v0.1.1` — F-Droid-compatible quick checklist

Linthra is already on F-Droid (accepted `0.1.0-alpha.40+100040`), so every future
release must keep the version **monotonic** and the GitHub-Release **asset names
stable**. This is the at-a-glance checklist for the next release; the numbered
sections below are the full reference.

**Target version**

| Field | Value |
| ----- | ----- |
| Tag (annotated, created from `main`) | `v0.1.1` |
| `pubspec.yaml` `version:` | `0.1.1+101999` |
| `lib/core/app_info.dart` `_devVersionName` | `0.1.1` |
| Fastlane changelog | `fastlane/metadata/android/en-US/changelogs/101999.txt` |
| versionCode (universal / base) | `101999` |
| versionCode (per-ABI — what F-Droid publishes) | `1019991` / `1019992` / `1019993` (armeabi-v7a / arm64-v8a / x86_64) |

`101999` is the canonical encoding of `0.1.1` from `tool/version_from_tag.dart`
(`MAJOR*10_000_000 + MINOR*100_000 + PATCH*1_000 + 999` for a stable release; see
§1). Preview it before bumping:

```sh
dart run tool/version_from_tag.dart v0.1.1
# LINTHRA_VERSION_NAME=0.1.1
# LINTHRA_VERSION_CODE=101999
```

**Why `101999` is safe (monotonic).** It is strictly greater than the accepted
F-Droid build at every level, and the per-ABI override (`base*10 + abi`) preserves
that order, so Android and F-Droid both accept it as an update:

| Level | `0.1.0-alpha.40` (on F-Droid) | `v0.1.1` | Increases? |
| ----- | ----- | ----- | ----- |
| base / universal | `100040` | `101999` | ✅ |
| per-ABI armeabi-v7a | `1000401` | `1019991` | ✅ |
| per-ABI arm64-v8a | `1000402` | `1019992` | ✅ |
| per-ABI x86_64 | `1000403` | `1019993` | ✅ |

**Invariants that must hold before tagging**

- [ ] `pubspec.yaml` (`0.1.1+101999`) and `lib/core/app_info.dart`
      (`_devVersionName = '0.1.1'`) are bumped **together, in the same commit** —
      they must stay in sync.
- [ ] **Version-drift tests pass:** `flutter test
      test/core/app_info_version_test.dart` (also run by CI). It fails if the two
      files disagree, or if the `versionCode` is not the canonical encoding of the
      `versionName`.
- [ ] **`pubspec.lock` stays committed** (it is tracked — do **not** re-ignore
      it). F-Droid runs `flutter pub get --enforce-lockfile`, which needs the
      committed, in-sync lockfile (this is exactly why `alpha.40` was cut).
      Regenerate it with pinned Flutter `3.27.4` only if dependencies changed.
- [ ] The **tag is created from `main`**, on the merged version-bump commit —
      never from a feature branch, and never before the bump PR is merged.
- [ ] **Do not rewrite or move old tags**, and **do not replace old GitHub-Release
      assets.** Tags and published assets are immutable to F-Droid mirrors and
      Android updaters; if a tag is wrong, skip to the next version.
- [ ] **Signing (GitHub-Release channel):** a stable tag **requires** the
      `LINTHRA_*` signing secrets — the tag build fails fast without them (no
      debug-key fallback, unlike alphas). F-Droid signs its own builds and needs
      none. Configure the secrets before tagging.
- [ ] **Verify the Release assets before assuming F-Droid can update.** A stable
      tag does **not** auto-create a GitHub Release the way an alpha/beta/rc tag
      does, so the F-Droid-referenced assets only appear once the Release exists
      and the build has attached them. Confirm them by name (below).

**F-Droid-compatible asset names (must not change).** F-Droid's per-Build
`binary:` URLs point at these exact names on the GitHub Release, with `%v`
expanding to the versionName (so `v%v` = `v0.1.1`):

```
linthra-v%v-armeabi-v7a-release-signed.apk   ->  linthra-v0.1.1-armeabi-v7a-release-signed.apk
linthra-v%v-arm64-v8a-release-signed.apk     ->  linthra-v0.1.1-arm64-v8a-release-signed.apk
linthra-v%v-x86_64-release-signed.apk        ->  linthra-v0.1.1-x86_64-release-signed.apk
```

(plus the universal `linthra-v0.1.1-release-signed.apk` / `.aab`). The tag build
names assets `linthra-<tag>-…`, so they only line up when the tag is exactly
`v` + versionName (`v0.1.1`). Keep the `vX.Y.Z` tag shape.

**If fdroiddata ever needs a manual edit** (the normal path is automatic —
`AutoUpdateMode: Version` + `UpdateCheckMode: Tags`; see §5): a `Builds` entry's
`commit:` field must be the **full 40-character commit SHA** behind the tag,
**not** the tag name. Resolve it with:

```sh
git rev-list -n 1 v0.1.1
```

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
| `v0.1.1`          | `101999`    |
| `v0.2.0-alpha.1`  | `200001`    |
| `v1.2.3`          | `10203999`  |

The fields are bounded (minor/patch ≤ 99, pre-release `N` ≤ 299) so the result
stays a valid Android `versionCode` (1‥2,100,000,000) and the tiers never
collide. A tag that violates these bounds, or is otherwise malformed, **fails
the build** (see "Malformed tags" below) instead of shipping guessed metadata.

> **Per-ABI versionCode.** When `flutter build apk --release --split-per-abi`
> produces per-ABI APKs, `android/app/build.gradle` applies a
> `versionCodeOverride = base * 10 + abi` per output, where `armeabi-v7a = 1`,
> `arm64-v8a = 2`, `x86_64 = 3`. The matching `VercodeOperation` in
> `metadata/io.github.thezupzup.linthra.yml` keeps the F-Droid recipe and the
> gradle build in lockstep. The override is silently skipped when no ABI filter
> is present, so the universal APK still ships at the base `versionCode` and a
> plain tag build is unchanged. The GitHub-Release CI now runs **both** a
> universal `flutter build apk --release` and a `--split-per-abi` build on every
> tag, and attaches all four signed APKs (universal + three per-ABI) plus the
> universal AAB to the Release, so F-Droid can point at the per-ABI APK as the
> upstream binary for each ABI build via per-Build `binary:` URLs (no `%a`
> placeholder exists, so the ABI slug is hardcoded per Build entry). Added in
> response to the F-Droid maintainer's feedback on MR !39329 ("Please host
> per-abi apks in github release and add binary to every version").

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

### Recommended flow — `Prepare release bump` workflow

The fast path is the manual **Prepare release bump** GitHub Action
(`.github/workflows/prepare-release-bump.yml`). It runs the same edits a
contributor would do by hand — pubspec, in-app mirror, Fastlane changelog,
F-Droid metadata — and opens a draft PR. It does NOT create the tag and does
NOT publish a release; those still happen manually after the PR is merged.

1. **Run the workflow** — GitHub Actions ▸ *Prepare release bump* ▸ *Run workflow*.
   Enter the **version name** (e.g. `0.1.1`, no leading `v`, no `+versionCode`),
   and paste a hand-written **changelog text**. For a **stable** release (e.g.
   `v0.1.1`) do **not** leave the changelog empty: the empty-input default is an
   alpha-worded, "not on F-Droid yet" maintenance note that is wrong for a stable,
   on-F-Droid release.
2. **Review the generated PR** (`chore(release): prepare v0.1.0-alpha.37`).
   Confirm the computed `versionCode`, the updated files, and the changelog
   body. Edit the changelog in the PR if you want to refine it.
3. **Wait for CI green** — `flutter analyze`, `flutter test`, formatting all run
   against the bump, including the version-drift test.
4. **Merge the PR** into `main`. Do **not** tag yet.
5. **Confirm** that `main`'s `pubspec.yaml` now reads
   `version: 0.1.0-alpha.37+100037`.
6. **Draft/publish the GitHub Release** with tag `v0.1.0-alpha.37` targeting
   `main`. (Or push the annotated tag from git, then add notes — see §4.)
7. **Watch the Android Release Build** workflow on the pushed tag; install the
   resulting APK and smoke-test.
8. **Update `fdroiddata`** to the new tag/version if the F-Droid submission has
   landed (see [fdroid-submission.md](./fdroid-submission.md)).

> **The workflow never creates the tag.** The tag is created only after the
> bump PR is merged. Never publish a release tag before the bump PR is
> merged — that is exactly the "lost-tag" failure mode the warnings below
> describe. If a wrong tag was pushed, skip to the next version.

The workflow refuses to run when the tag already exists locally or on origin,
when `pubspec.yaml` is already at the requested version, when `app_info.dart`
has no `_devVersionName` to update, or when an existing Fastlane changelog
would be overwritten without `--force-changelog`. See
[scripts/prepare_release_bump.py](../scripts/prepare_release_bump.py) for the
full safety list — that is the same script the workflow invokes, so you can
run it locally:

```sh
python3 scripts/prepare_release_bump.py 0.1.0-alpha.37
# (optionally with --changelog "..." or --force-changelog)
./scripts/release_preflight.sh v0.1.0-alpha.37
```

### Manual flow (the long form)

If you prefer to bump everything by hand — or if the workflow doesn't fit your
PR — the steps below are what `prepare_release_bump.py` automates. They remain
the canonical source of truth for what the bump must contain.

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

> **F-Droid asset-name compatibility (do not change these names).** On a tag
> build the public Release assets are named `linthra-<tag>-…-release-signed.…`,
> and F-Droid's per-Build `binary:` URLs in
> `metadata/io.github.thezupzup.linthra.yml` point at the per-ABI ones, with `%v`
> expanding to the versionName (so for a `vX.Y.Z` release `v%v` equals the tag):
>
> ```
> linthra-v%v-armeabi-v7a-release-signed.apk
> linthra-v%v-arm64-v8a-release-signed.apk
> linthra-v%v-x86_64-release-signed.apk
> ```
>
> (plus the universal `linthra-v%v-release-signed.apk` / `.aab`). These names must
> stay stable across releases, and the tag must be exactly `v` + versionName for
> them to line up. **Never replace or rename the assets on an already-published
> Release** — F-Droid and sideload users resolve these exact URLs.

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
   `vX.Y.Z` **targeting `main`**, write the notes. Creating the Release on a new
   tag also creates and pushes that tag — so `main` must already carry the merged
   version bump (§3).
4. That tag push triggers **Android Release Build** automatically. When it
   finishes, the **release-signed** APK/AAB are attached to the Release.
5. **Verify the attached assets before announcing or assuming F-Droid can
   update.** A stable tag does **not** auto-create a pre-release the way an
   alpha/beta/rc tag does, so if the Release did not already exist (or the signing
   secrets were missing) nothing is attached. Confirm all five
   F-Droid-referenced assets are present by name — the three per-ABI
   `linthra-v%v-<abi>-release-signed.apk` plus the universal
   `linthra-v%v-release-signed.apk` / `.aab` (see the asset-name box above). Only
   once they are attached do F-Droid's `binary:` URLs resolve.

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

**Linthra is on F-Droid** (accepted `0.1.0-alpha.40+100040`). F-Droid does **not**
consume our signed artifacts:

- F-Droid builds **from source** at the `vX.Y.Z` tag on its own infrastructure
  and signs with **F-Droid's** key. (So an F-Droid APK and a GitHub-Release APK of
  the same version cannot update each other — call it out in the release notes.)
- **Updates are auto-detected.** The fdroiddata recipe uses `UpdateCheckMode:
  Tags` + `AutoUpdateMode: Version` with an `UpdateCheckData` regex that reads the
  `versionName`/`versionCode` straight from `pubspec.yaml` at each tag. F-Droid
  scans the tags, picks the highest `versionCode`, and auto-generates the per-ABI
  `Builds` entries (`VercodeOperation: %c*10 + 1/2/3`). Because `0.1.1+101999` is
  the highest, **no manual fdroiddata edit is needed for `v0.1.1`** in the normal
  case.
- **If a manual fdroiddata edit is ever required**, a `Builds` entry's `commit:`
  field must be the **full 40-character commit SHA** behind the tag, **not** the
  tag name (matching the existing entries). Resolve it with:

  ```sh
  git rev-list -n 1 v0.1.1
  ```

  Then set `CurrentVersion` / `CurrentVersionCode` to the new release (`0.1.1` /
  `1019993`, the highest per-ABI code). **This repo never pushes to fdroiddata** —
  that change, if needed, is made in the fdroiddata repo.
- The submission flow, metadata fields, and recipe live in
  [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md) and
  [docs/fdroid-submission.md](./fdroid-submission.md); overall status lives in
  [docs/fdroid-readiness.md](./fdroid-readiness.md).

## 6. What is automated vs. manual

| Action | Automated? |
| ------ | ---------- |
| Quality CI (format/analyze/test) + lockfile-enforced `pub get` on PRs & `main` | **Automatic** (`ci.yml`, job `flutter`; `flutter pub get --enforce-lockfile` catches a dependency change that forgot to refresh `pubspec.lock`). |
| Secret & privacy scan on PRs & `main` | **Automatic** (`ci.yml`, job `secret-scan`; runs `scripts/check_secrets.sh` — offline, no secrets). |
| Fastlane changelog exists for the current `versionCode` | **Automatic** on PRs & `main` (`flutter test` ▸ `test/tooling/release_changelog_test.dart`). |
| Release-bump PR touches only version files | **Automatic** on `release/*` PRs only (`ci.yml`, job `release-bump-guard`; `scripts/check_release_bump_files.sh`). |
| Debug APK build + build-output verification | Manual (`workflow_dispatch`) + on PRs (`android-debug-apk.yml`; a "Verify build output exists" step rejects a missing/empty APK). |
| Release APK/AAB build | **Manual** (`workflow_dispatch`) **and automatic on `v*` tags** (`android-release-build.yml`). |
| Preparing the version-bump PR (pubspec, in-app mirror, Fastlane changelog, F-Droid `CurrentVersion`) | **Manual** (`workflow_dispatch`, `prepare-release-bump.yml`); opens a draft PR but never tags, builds, or publishes. The same edits are reproducible locally with `scripts/prepare_release_bump.py`. |
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

### Which workflow runs on PRs, `main`, and tags

| Workflow · job | PR | Push to `main` | `v*` tag | Manual |
| -------------- | -- | -------------- | -------- | ------ |
| `ci.yml` · `flutter` — format, analyze, test, `pub get --enforce-lockfile` | ✅ | ✅ | — | — |
| `ci.yml` · `secret-scan` — `scripts/check_secrets.sh` | ✅ | ✅ | — | — |
| `ci.yml` · `release-bump-guard` — `scripts/check_release_bump_files.sh` | ✅ (only `release/*` branches) | — | — | — |
| `android-debug-apk.yml` — build debug APK + verify output | ✅ | — | — | ✅ |
| `android-release-build.yml` — release APK/AAB, tag↔pubspec preflight, attach | — | — | ✅ | ✅ |
| `prepare-release-bump.yml` — open the version-bump PR | — | — | — | ✅ |
| `generate-drift.yml` — regenerate `*.g.dart` | — | — | — | ✅ |

The `flutter` job also runs the whole `test/` suite, which includes the
release-safety guardrail tests below — so those gate every PR, not just release
PRs. Nothing in `ci.yml` uses a secret, so all three jobs run identically on
fork PRs.

### What the guardrails catch (and how to run them locally)

These complement, and do not replace, the release invariants already enforced
elsewhere: the in-app/`pubspec.yaml` version-drift and canonical-`versionCode`
checks (`test/core/app_info_version_test.dart`); the cross-file F-Droid
invariants — monotonic `versionCode`, per-ABI `base*10 + rank`, stable release
asset names, tracked `pubspec.lock` (`test/tooling/fdroid_release_guardrails_test.dart`);
and the tag↔`pubspec.yaml` preflight (`scripts/release_preflight.sh`, run on a
`v*` tag and locally before tagging — §3 step 9, §4).

- **Lockfile drift** — `flutter pub get --enforce-lockfile` (CI `flutter` job;
  also in `scripts/verify_android.sh` and `android-debug-apk.yml`). Fails if a
  dependency change did not refresh `pubspec.lock`, keeping it in sync with the
  lockfile the reproducible F-Droid build resolves against (§7).
- **Committed secrets / private data** — `./scripts/check_secrets.sh` (CI
  `secret-scan` job). Offline, dependency-free. Flags committed `.env` files,
  keystores (`*.jks`/`*.keystore`), private keys, `key.properties`, Play
  service-account JSON, and high-signal tokens (GitHub / Slack / AWS / Google);
  `*.example`/`*.sample`/`*.template` placeholders are allowed. It also scans any
  committed diagnostics **fixture/snapshot** for a real private URL, credential,
  token, or home path — reserved example hosts (`example.com`, `localhost`,
  RFC1918, TEST-NET) are allowed. The runtime diagnostics redaction itself is
  unit-tested in `test/core/diagnostics/`.
- **Missing release changelog** — `test/tooling/release_changelog_test.dart`
  (runs in `flutter test`). Fails if there is no non-empty
  `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` for the version
  in `pubspec.yaml`. The `Prepare release bump` workflow creates it; this catches
  a hand-edited bump that forgot it.
- **Release-bump scope creep** — `./scripts/check_release_bump_files.sh` (CI
  `release-bump-guard`, `release/*` PRs only). A version bump must be a clean,
  version-only diff (pubspec, `app_info.dart`, the Fastlane changelog, the
  F-Droid metadata, optionally `pubspec.lock`/`docs/release-notes/**`).
- **Debug build sanity** — `android-debug-apk.yml` verifies the debug APK exists
  and is a sane size before uploading, so a silent build failure is caught.

Run the Flutter checks plus the secret scan in one local pass with
`./scripts/verify_android.sh`. The two guard scripts also run standalone with no
Flutter toolchain:

```sh
./scripts/check_secrets.sh
# A release-bump PR's changed files (compare against the base branch):
git diff --name-only origin/main...HEAD | ./scripts/check_release_bump_files.sh
```

## 7. Release status

The blockers that gated the first F-Droid release are resolved:

1. **Release signing secrets** (`LINTHRA_*`) are used for the GitHub-Release
   artifacts — see [release-signing.md](./release-signing.md). A **stable** tag
   now **requires** them (the tag build fails fast without them); F-Droid itself
   signs its own builds and needs none.
2. **Tags exist and F-Droid is live.** Alpha tags through `v0.1.0-alpha.40` are
   cut, and F-Droid accepted `0.1.0-alpha.40+100040`. The next release is the
   stable `v0.1.1` (`0.1.1+101999`; see the checklist near the top of this doc).
3. **`pubspec.lock` is committed** (decided as of `alpha.40`) so the F-Droid build
   can run `flutter pub get --enforce-lockfile` against a pinned dependency set.
   Keep it committed and in sync.
4. **Feature maturity** is tracked per release in the GitHub Release notes and the
   Fastlane changelogs; `0.1.0-alpha.1` shipped the initial feature set (see
   [docs/release-notes/v0.1.0-alpha.1.md](./release-notes/v0.1.0-alpha.1.md)).

See [fdroid-readiness.md](./fdroid-readiness.md) for the broader F-Droid status.

## 8. Related docs

- [docs/release-signing.md](./release-signing.md) — signing keys, CI secrets,
  rotation.
- [docs/fdroid-readiness.md](./fdroid-readiness.md) — F-Droid submission checklist.
- [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md) — F-Droid build recipe.
- [docs/dependency-license-audit.md](./dependency-license-audit.md) — dependency
  licensing.
- [docs/listing-assets.md](./listing-assets.md) — store icon / feature graphic /
  screenshots.
