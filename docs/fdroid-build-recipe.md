# F-Droid build recipe planning & reproducible-build notes

This document plans the F-Droid build recipe (the `metadata/<appid>.yml` entry
in [fdroiddata](https://gitlab.com/fdroid/fdroiddata)) for Linthra and records
the reproducible-build groundwork needed before any submission. It is a
planning aid only.

> **Linthra is _not_ on F-Droid and has _not_ been submitted.** Nothing here
> publishes, signs, or submits anything. The snippets below are drafts to be
> finalized — and verified against an actual build — before a future merge
> request to fdroiddata.

See also the broader [F-Droid readiness checklist](./fdroid-readiness.md),
which tracks assets, anti-features, and overall submission status.

## 1. App identity

| Field    | Value                            |
| -------- | -------------------------------- |
| Name     | Linthra                          |
| App ID   | `io.github.thezupzup.linthra`    |
| License  | MPL-2.0                          |

- The App ID is the Android `namespace` and `applicationId` in
  `android/app/build.gradle` and must stay stable across all releases.
- License is MPL-2.0 (see [`LICENSE`](../LICENSE)), an FSF/OSI-approved free
  license accepted by F-Droid. F-Droid expects the SPDX identifier `MPL-2.0`.

## 2. Expected F-Droid metadata repo fields

These are the top-level fields the fdroiddata `metadata/io.github.thezupzup.linthra.yml`
entry is expected to carry. Values marked _(draft)_ are proposals to confirm at
submission time.

| Field             | Planned value | Notes |
| ----------------- | ------------- | ----- |
| `Categories`      | `Multimedia` _(draft)_ | A music player fits Multimedia; `Internet` is **not** appropriate (local-first, no required network). |
| `License`         | `MPL-2.0` | SPDX identifier; matches `LICENSE`. |
| `AuthorName`      | TheZupZup _(draft)_ | Optional; confirm preferred attribution. |
| `SourceCode`      | `https://github.com/thezupzup/linthra` | Public repository. |
| `IssueTracker`    | `https://github.com/thezupzup/linthra/issues` | GitHub issues. |
| `Changelog`       | `https://github.com/thezupzup/linthra/releases` | Tagged GitHub Releases now exist, so this is set. |
| `AutoUpdateMode`  | `Version v%v` | Track annotated git tags of the form `v<versionName>` (see § release plan). |
| `UpdateCheckMode` | `Tags ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha\|beta\|rc)\.[0-9]+)?$` | Linthra ships only pre-release `-alpha.N` tags so far; the regex must accept the alpha/beta/rc suffix. Confirm with F-Droid whether it will track a pre-release CurrentVersion (see [fdroid-readiness.md §8](./fdroid-readiness.md#8-remaining-blockers-before-submission)). |

`AutoUpdateMode`/`UpdateCheckMode` only work cleanly if the tag and the
`pubspec.yaml` version stay in lockstep (§5). Confirm the exact regex against
the first real tag before submission.

## 3. Build source expectations

Linthra is a Flutter (Dart) application targeting Android.

| Item | Current state |
| ---- | ------------- |
| Flutter version (pinned in CI) | **3.27.4**, `stable` channel — pinned identically in `ci.yml`, `android-release-build.yml`, and `generate-drift.yml`. The F-Droid recipe's `srclibs`/`sudo`-installed Flutter (or `flutter` build plugin) should target the same version. |
| Dart SDK constraint | `>=3.6.0 <4.0.0` (`pubspec.yaml`), satisfied by Flutter 3.27.4. |
| Java / JDK | **JDK 17** (Temurin in CI) — matches the bundled Gradle wrapper. |
| Gradle | **8.3**, declared in `android/gradle/wrapper/gradle-wrapper.properties` (`gradle-8.3-all.zip`). |
| Android Gradle Plugin | **8.1.0**, declared in `android/settings.gradle`. |
| Kotlin Gradle plugin | **1.8.22**, declared in `android/settings.gradle`. |
| Android SDK | `compileSdk`, `minSdk`, `targetSdk`, `versionCode`, and `versionName` all come from Flutter (`flutter.*` in `android/app/build.gradle`); they follow the pinned Flutter version rather than being hard-coded. |
| Gradle wrapper committed? | **Partly.** `gradle-wrapper.properties` is committed; **`gradle-wrapper.jar` is _not_ committed.** F-Droid's build server can regenerate/restore the wrapper jar, but the recipe must account for this (e.g. `gradle` build type, or a prebuild that runs `flutter build` which provisions the wrapper). Worth re-checking before submission. |
| Generated files committed? | **Yes for Drift.** `lib/data/database/linthra_database.g.dart` is committed. This means `build_runner` is **not** required during the F-Droid build (see §4). |
| Native components | `sqlite3_flutter_libs` ships a native SQLite engine built from source; no prebuilt closed blobs. |

**Build commands** (what the recipe effectively performs):

```
flutter pub get
flutter build apk --release   # or split-per-ABI; appbundle is for stores, not F-Droid
```

Because the Drift output is committed, **no `dart run build_runner build`
prebuild step is required** as long as the committed `*.g.dart` is in sync with
the schema at the tagged commit (§4).

## 4. Reproducibility notes

1. **Generated Drift files must be committed before release tags.** The
   `*.g.dart` output (currently `lib/data/database/linthra_database.g.dart`)
   must be regenerated and committed on the exact commit that gets tagged. If
   the schema changes without regenerating, the committed file drifts out of
   sync and the F-Droid build either fails to compile or builds stale code.
   Use the `generate-drift.yml` workflow (or local `dart run build_runner build
   --delete-conflicting-outputs`) and commit the result _before_ tagging.
2. **`build_runner` should not be needed by F-Droid.** Because generated files
   are committed, the recipe does not need a codegen prebuild. This is the
   preferred posture — it removes a non-trivial, network-dependent prebuild
   step from the reproducible build. If we ever stop committing generated
   files, the recipe would need a `prebuild`/`build` step running
   `build_runner`, which is more fragile; avoid that.
3. **Lockfile policy.** `pubspec.lock` is currently **gitignored** (CI resolves
   dependencies fresh on each run). F-Droid reproducibility benefits from a
   committed lockfile so dependency versions are pinned at the tagged commit.
   **Recommendation:** before the first release tag, decide whether to commit
   `pubspec.lock` for releases. Committing it makes the dependency set
   deterministic for the F-Droid build; this is a policy change to make
   deliberately (it is out of scope for this documentation PR).
4. **Dependency source review.** Every runtime dependency must be free software
   and buildable from source on F-Droid's infrastructure — no Google Play
   Services, Firebase, or proprietary blobs. The per-package licenses and the
   native/bundled-component review are in
   [dependency-license-audit.md](./dependency-license-audit.md): all direct deps
   are permissive (MIT/BSD-3-Clause). A mechanical **transitive** audit is still
   an open blocker (§6).
5. **Toolchain pinning.** Reproducibility depends on the F-Droid build using the
   same Flutter (3.27.4), Dart (3.6.x), JDK (17), and Gradle (8.3) versions the
   project builds with. Keep the CI pin and any recipe-side pin in sync; a
   Flutter bump may also require reformatting (`dart format`) and regenerating
   Drift output.

## 5. Release / tagging plan

F-Droid builds from a git tag. Summary below; the canonical, step-by-step
process (and the GitHub-Release flow) is in
[docs/release-process.md](./release-process.md), and it is consistent with
[fdroid-readiness.md §6](./fdroid-readiness.md):

1. **Source of truth:** for a release the **git tag** drives
   `versionName`/`versionCode` (derived by `tool/version_from_tag.dart`, see
   [release-process.md §1](./release-process.md#1-versioning-model));
   `pubspec.yaml` `version: x.y.z+<versionCode>` is the local/dev default.
   **F-Droid handling (decided):** F-Droid builds from source and does not run
   our workflow, so a plain `flutter build` would take the static
   `pubspec.yaml` version (versionCode **15** for every tag). The draft recipe
   therefore derives the version from the checked-out tag with
   `tool/version_from_tag.dart` and passes `--build-name`/`--build-number`, so
   `v0.1.0-alpha.29` builds to `0.1.0-alpha.29` / **100029** — matching the
   metadata and the GitHub channel, and AutoUpdate-safe for future tags. See
   [fdroid-submission.md §2](./fdroid-submission.md).
2. **`versionCode` increases monotonically** by construction (the encoding can
   never go backwards); never reuse or decrease it.
3. **Tag format suggestion:** annotated tag `vX.Y.Z` (e.g. `v0.1.0`) on the
   commit to be built. This matches the `UpdateCheckMode`/`AutoUpdateMode`
   recommendation in §2.
4. **Changelog expectations:** add a per-version Fastlane changelog at
   `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` for each
   release (e.g. `1.txt` for `0.1.0+1`). If GitHub Releases are also published,
   the `Changelog` metadata field (§2) can point there.
5. Ensure committed generated files (§4.1) are current on the tagged commit.

## 6. Known blockers

These must be resolved before an actual F-Droid submission (see also
[fdroid-readiness.md §8](./fdroid-readiness.md)):

1. **Release signing strategy.** `android/app/build.gradle` still signs release
   builds with the debug key (`signingConfig = signingConfigs.debug`). F-Droid
   signs its own builds, so this does not block F-Droid functionally, but the
   debug-key fallback should be removed / replaced with a proper release signing
   story before publishing anywhere. **No signing secrets are added in this PR.**
2. **Android storage / SAF limitations.** Scanning relies on the Storage Access
   Framework; `SafTreeUriResolver` currently maps only the common
   `com.android.externalstorage.documents` provider to a real path, and other
   SAF providers / fully content-resolver-based scanning are still follow-ups
   (see README "Android folder selection & known limitations"). This is a
   functionality maturity note, not an F-Droid build blocker per se.
3. **Toolchain provisioning + `fdroid build` validation.** The Flutter-on-F-Droid
   incantation (sudo git-clone vs. `flutter` srclib) must match fdroiddata's
   current convention and be validated by an actual `fdroid build`.
4. **Gradle wrapper jar.** Confirm the recipe handles the missing committed
   `gradle-wrapper.jar` (§3) reproducibly.

**Resolved:** the store icon, feature graphic, and eight real phone screenshots
are committed (the core set tracked by issue #77; see
[docs/listing-assets.md §6](./listing-assets.md)); a `v*` tag now exists (target
`v0.1.0-alpha.29`; the broken `v0.1.0-alpha.24` is excluded); the versionCode
scheme is decided (tag-derived `100029`, §5.1); and the full transitive
dependency audit is complete
([dependency-license-audit.md](./dependency-license-audit.md)).

## 7. Draft F-Droid metadata recipe

A complete, current draft recipe now lives in the repo at
[`metadata/io.github.thezupzup.linthra.yml`](../metadata/io.github.thezupzup.linthra.yml),
pinned to the latest working alpha (`commit: v0.1.0-alpha.29`, versionName
`0.1.0-alpha.29`, versionCode `100029`). That file is the canonical draft; edit
it there rather than duplicating a snippet here.

> **Still a draft — not submitted.** The exact Flutter-on-F-Droid build
> incantation (Flutter srclib vs. `sudo`-installed SDK, ABI splitting, `output`
> path) must still be validated against fdroiddata's current Flutter recipes via
> an actual `fdroid build` at submission time. The version target and
> tag-derived versionCode are now set; see the
> [submission package](./fdroid-submission.md) for the MR text and next steps and
> the [readiness checklist](./fdroid-readiness.md#8-remaining-blockers-before-submission)
> for the remaining blockers.
