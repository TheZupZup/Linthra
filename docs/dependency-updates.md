# Dependency updates

Linthra checks its own dependencies on a schedule and prepares a pull request
when something can move. It never merges anything. The bot's job is to say
*"here is an update, and here is what CI thinks of it"*; deciding what happens
next is a human's (issue #362).

Seven things are covered, by four different mechanisms:

| What | Handled by | Cadence | Outcome |
| --- | --- | --- | --- |
| GitHub Actions | Dependabot — [`.github/dependabot.yml`](../.github/dependabot.yml) | weekly | PR |
| Cargo (`native/linthra_core`) | Dependabot — same file | weekly | PR |
| Dart / Flutter packages | [`dart-dependency-updates.yml`](../.github/workflows/dart-dependency-updates.yml) | weekly | draft PR |
| Flutter SDK | [`flutter-sdk-updates.yml`](../.github/workflows/flutter-sdk-updates.yml) | weekly | draft PR, or an issue for a major |
| Gradle | [`android-toolchain-updates.yml`](../.github/workflows/android-toolchain-updates.yml) | weekly | draft PR, and/or an issue for a major |
| Android Gradle Plugin | same file | weekly | draft PR, and/or an issue for a major |
| Kotlin Gradle plugin | same file | weekly | draft PR, and/or an issue for a major |

The JDK is deliberately not on that list. `.java-version` is what CI, the local
setup and the F-Droid builder all install, and a JDK change ripples through the
whole Android build at once — issue #362 lists it under the upgrades that stay
manual, and it still is.

## How this was built

Issue #362 was delivered in five phases, in this order:

| Phase | PR | What it added |
| --- | --- | --- |
| 1 | #363 | One source of truth per toolchain pin, plus the guardrail tests that stop docs and workflows drifting from them |
| 2 | #364 | Dependabot for GitHub Actions and Cargo |
| 3 | #370 | The Dart/Flutter package updater, resolving with Linthra's pinned SDK |
| 4 | #373 | The Flutter SDK update checker |
| 5 | this one | Gradle, AGP and Kotlin update checking |

Every phase reuses the same safety model rather than inventing its own, and the
later ones tightened it where the earlier ones had been too loose — #373's
switch from a `toolchain/*` prefix match to an exact branch match is the clearest
example, and phase 5 keeps that rule.

The shared rules, in one place:

- **Nothing ever merges automatically.** No workflow here contains a merge
  command, and tests assert that stays true.
- **Nothing migrates code.** A bot may move a version; making the repository
  work at that version is a human's PR.
- **Red is the finding, not a failure.** An update PR that fails CI has told you
  something useful.
- **Each updater has a tiny, explicit allowlist**, checked twice: inside the
  updater before a commit exists, and again in CI against the real PR diff.
- **Update PRs run normal CI**, which is why publication uses a dedicated token
  rather than the workflow's own `GITHUB_TOKEN`.
- **Majors get an issue, never a PR.**

## Dart / Flutter packages

### What it does

Once a week (and on demand from **Actions → Dart dependency updates → Run
workflow**) the workflow checks out `main`, installs the pinned Flutter SDK and
runs:

```bash
flutter pub upgrade
```

That resolves every dependency to the newest version the constraints already in
`pubspec.yaml` allow, and writes the result to `pubspec.lock` — nothing else. If
the lockfile does not change, the run stops there and no PR is opened.

If it does change, the workflow:

1. asserts that `pubspec.lock` is the only file that moved,
2. re-checks the result with `flutter pub get --enforce-lockfile`,
3. runs `dart format`, `flutter analyze` and `flutter test`,
4. opens — or updates — a single draft PR on the `deps/dart-packages` branch.

Step 3 is reported, not enforced. A dependency that needs application changes
produces a red PR on purpose; see [Red PRs are the point](#red-prs-are-the-point).

### Why `flutter pub upgrade`, and not `--major-versions=false`

There is no `--major-versions=false`. `--major-versions` is a non-negatable
flag, and giving it a value fails outright:

```console
$ flutter pub upgrade --major-versions=false
Flag option "--major-versions" should not be given a value.
$ echo $?
64
```

The flag also does the opposite of what an automatic update wants: it *rewrites
the constraints in `pubspec.yaml`* so that majors can be pulled in. Plain
`flutter pub upgrade` is already the "newest compatible versions, no constraint
edits" command — `just_audio: ^0.9.42` cannot resolve to `0.10.0`, and
`permission_handler: ^11.3.1` cannot resolve to `12.0.0`. The rule is enforced
by the caret ranges a human wrote, which is exactly where that decision belongs.

One honest caveat: `pubspec.yaml` does not constrain *transitive* packages, so a
lockfile refresh can move them across major versions — the analyzer / build /
`source_gen` chain behind `drift_dev` is the usual example. That is what a
lockfile refresh is. It stays bounded by the pinned SDK and by what the direct
constraints admit, and it is a large part of why this ends in a reviewed PR
instead of a silent commit.

### Why not Dependabot

Dependabot does support the `pub` ecosystem, and using it would have been less
code. It cannot meet two of Linthra's requirements:

- **The pinned SDK.** Dependabot's pub updater resolves with its own bare Dart
  SDK and installs no Flutter at all. `pubspec.lock` is committed so the F-Droid
  build resolves the same dependency set we tested
  ([release-process.md](./release-process.md) §7), which means the lockfile has
  to come from the SDK in `.flutter-version`. The difference is not theoretical:
  resolving with the pinned SDK writes an `sdks:` block into the lockfile that
  names the Flutter line it was resolved against, which a Flutter-less resolver
  cannot produce.
- **Constraints must not move.** pub has no `lockfile-only` versioning strategy.
  All three strategies it offers — `widen`, `increase`, `increase-if-necessary`
  — rewrite the constraints in `pubspec.yaml`.

Dependabot keeps GitHub Actions and Cargo, where neither problem exists.
`test/tooling/dependency_update_guardrails_test.dart` fails if a `pub` ecosystem
is ever added to `.github/dependabot.yml`, so the two cannot start fighting over
the same lockfile.

### What the bot may touch

Exactly one file:

```text
pubspec.lock
```

Anything else fails the run before a commit exists.
`scripts/check_dependency_update_files.sh` owns that list, and it runs twice:
once inside the updater, and again in CI against the real PR diff for any
`deps/` branch — so a "just fix the failing test" commit pushed onto the update
PR afterwards is caught too.

In particular an automatic update never changes dependency constraints,
application code, test code, the app version, F-Droid metadata, Fastlane files,
release notes, signing files or licenses.

### Packages that deserve a closer look

The PR body calls these out by name when they move, because the Flutter checks
job cannot fully judge them — it does not build an APK, and it does not
regenerate the committed Drift output:

| Package(s) | Why |
| --- | --- |
| `just_audio`, `audio_service`, `audio_session` | Platform plugins behind playback, the media session and audio focus. Only a real Android build and a device exercise them. |
| `drift`, `drift_dev`, `sqlparser` | `drift_dev` generates the committed `*.g.dart`. If the generator's output changes, regeneration is an application change — run **Generate Drift files**, in its own PR. |
| `sqlite3`, `sqlite3_flutter_libs` | The native SQLite engine shipped in the APK; relevant to reproducibility. |
| `flutter_secure_storage` | Android Keystore-backed token storage. |
| `permission_handler` | Runtime `POST_NOTIFICATIONS` request. |
| `file_picker` | Native folder chooser. |
| `cast`, `bonsoir` | Chromecast transport and mDNS discovery, both F-Droid-safe by choice. |

This is a list of things to *read carefully*, not a resolution rule. Nothing
here needs special grouping: `pub upgrade` re-resolves the whole graph as one
consistent set, so packages that must move together already do, and a version
that would break a co-dependency is simply never selected.

### Red PRs are the point

If the update needs application changes, the PR stays red. That is the finding,
not a failure of the bot — the Flutter 3.44.7 upgrade is the worked example of
why blind auto-updates are not wanted here.

So the Flutter CI fixer is kept away from these branches. It skips `deps/*`
exactly the way it skips `dependabot/*`: while resolving the failed run, before
any repair is generated, and again in the publish job where the push would
happen. A repair commit would both hide which bump broke what and put
application code into a PR that is guarded to contain nothing but the lockfile.

### One-time setup

The workflow needs one repository Actions secret:

- `DEPENDENCY_UPDATE_TOKEN` — a dedicated fine-grained token with **Contents:
  read/write** and **Pull requests: read/write** on this repository.

This is the same pattern as `CI_FIXER_GITHUB_TOKEN` in
[flutter-ci-fixer.md](./flutter-ci-fixer.md), and for the same reason: a push or
a PR made with the workflow's default `GITHUB_TOKEN` does not trigger further
workflows, so the PR would open with no checks on it. An update PR that runs no
CI is a broken updater, so the workflow fails loudly rather than opening one —
but only when there is actually an update to publish. A week with no updates
never touches the token.

The job's own `GITHUB_TOKEN` stays `contents: read`.

### Reproducing it locally

The workflow runs the same script a contributor can:

```bash
./scripts/setup_flutter.sh
export PATH="$PWD/.tool/flutter/bin:$PATH"
./scripts/update_dart_dependencies.sh
```

It refuses to run against a Flutter that is not the pinned one, refuses to run
on a dirty tree (so every changed file is attributable to the run), and commits
nothing. Exit codes: `0` updated, `3` already up to date, `1` a guard failed.

Pass `--output-dir DIR` to also write the Markdown summary and the raw
`pub upgrade` log the workflow puts in the PR body.

### Reviewing an update PR

- Read the package list in the PR body, and the "needs a closer look" section.
- Check CI. Red is informative; work out *which* bump caused it.
- If it needs code changes, do that in a separate PR. Do not push the fix onto
  the update branch — the CI guard rejects it, and the next scheduled run
  refuses to force-push over commits it did not write.
- The Flatpak's pinned Dart sources are derived from `pubspec.lock`, and the
  same guard keeps them off this branch, so refresh them in a follow-up PR:
  `./scripts/regenerate_flatpak_sources.sh`. Until that lands, the Flatpak
  source checks are red and name the package they are missing, which is
  another red that is the point rather than something to work around (see
  [source pinning](./flatpak-source-pinning.md)).
- Merge manually when it is green and you are happy with it. Nothing
  auto-merges, by design.

## Flutter SDK

### Where the pin lives

`.flutter-version`, at the repository root, holds one bare stable version and
nothing else. It is the single source of truth for the SDK: CI installs from it
through [`.github/actions/setup-flutter`](../.github/actions/setup-flutter/action.yml),
contributors install from it through `scripts/setup_flutter.sh`, the Dart
package updater resolves the lockfile with it, and the F-Droid recipe reads the
same file. `test/tooling/toolchain_pins_test.dart` fails if a workflow or a
document starts naming a version instead of reading this one.

A Flutter SDK update is therefore a one-line change — and that is exactly what
the updater is allowed to write.

### Where the release information comes from

The official Flutter release manifest:

```text
https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
```

That is the machine-readable index behind Flutter's own archive page, served
from the same `flutter_infra_release` bucket `scripts/setup_flutter.sh` already
downloads the pinned SDK from. So a version this checker proposes is by
construction a version the pinned setup path can install. No third-party
version API, no scraped web page, no `git ls-remote` against the SDK repo.

The manifest lists every release on every channel. A release is a candidate
here only if all three hold:

1. its `channel` is exactly `stable` — beta, dev and master are ignored, and so
   are the `-0.N.pre` builds that ride the beta channel;
2. its `version` is a bare `MAJOR.MINOR.PATCH` — this drops the historical
   `v1.12.13+hotfix.9`-style stable tags, the only stable rows that are not
   plain triples;
3. its `archive` lives under `stable/`.

The newest candidate is the one with the highest `(major, minor, patch)`, not
the first row in the array — a hotfix on an older line can be published after a
newer line already exists. The manifest's own `current_release.stable` pointer
is resolved as a cross-check and any disagreement is reported, but the highest
version wins either way, so the answer never depends on array order.

### What it does

Once a week (and on demand from **Actions → Flutter SDK updates → Run
workflow**) the workflow compares the pin against that manifest. A manual run is
the scheduled run: same detection, same classification, same safety checks.

| Gap between pin and newest stable | Result |
| --- | --- |
| none | nothing happens, no PR, no issue |
| newer patch, same major and minor | draft PR |
| newer minor, same major | draft PR |
| newer major | **issue**, and nothing else |

The comparison lives in `scripts/check_flutter_sdk_update.py`, not in the
workflow YAML, so it can be tested offline against fixture manifests
(`test/tooling/flutter_sdk_update_guardrails_test.dart`). It uses no
third-party semantic-version package; three integers and a tuple comparison are
the whole algorithm.

It fails loudly rather than guessing. A pin it cannot parse, a manifest it
cannot parse, a manifest with no usable stable release, or a "newest stable"
that is *older* than the pin all stop the run with a non-zero exit. In
particular the updater never proposes a downgrade.

Run it yourself:

```bash
python3 scripts/check_flutter_sdk_update.py
python3 scripts/check_flutter_sdk_update.py --json
```

It reads two things and writes nothing.

### Patch and minor: one draft PR

The workflow keeps a single reusable branch:

```text
toolchain/flutter-sdk
```

A deliberately separate namespace from `deps/`, so it inherits none of the Dart
package updater's rules; each branch namespace has its own allowlist. Repeated
runs update that one PR rather than opening a new one every Monday, and a run
whose target is already on the branch pushes nothing at all.

The PR body states the currently pinned version, the proposed version, whether
the gap is a patch or a minor, and the manifest entry (archive, commit,
release date) that confirms the target really is published on the stable
channel.

### What the bot may touch

Exactly one file:

```text
.flutter-version
```

Notably **not** `pubspec.lock`. A new SDK can require the lockfile to be
re-resolved, but that resolution is what the reproducible F-Droid build depends
on ([release-process.md](./release-process.md) §7), so it is a human's decision
in a human's PR — not something an SDK bump drags along.

`scripts/check_dependency_update_files.sh` owns the list. It takes an explicit
`--kind`, because the two updaters have deliberately different reach:

| `--kind` | Branch | May write |
| --- | --- | --- |
| `dart-packages` (default) | `deps/` | `pubspec.lock` |
| `flutter-sdk` | `toolchain/flutter-sdk` | `.flutter-version` |

Neither kind can write the other's file. And as with the Dart updater, the
guard runs twice: once inside the workflow before a commit exists, and again in
CI against the **real PR diff** for the `toolchain/flutter-sdk` branch — so a
commit pushed onto the update PR afterwards is caught too. CI matches that
branch exactly, not by `toolchain/` prefix: a human's own toolchain PR is an
ordinary PR and is not held to the pin-only rule. An automatic SDK update
never changes application code, test code, dependency constraints, the app
version, F-Droid metadata, Fastlane files, release notes, signing files or
licenses, and it never migrates a deprecated API.

### Normal CI runs on it, and red is the point

The PR is published with the dedicated token, so GitHub triggers the repository's
normal `pull_request` checks on it exactly like any other PR — format, analyze,
test, the lockfile-enforced dependency install, the secret scan, and the
`toolchain/flutter-sdk` file guard.

A new SDK can deprecate an API Linthra uses, reformat the codebase with a newer
Dart, or make the committed lockfile fail its enforced resolve. Any of those
turns the PR red, and **that is the finding**: the bump needs a migration. The
migration is a separate, human PR. Do not push it onto the update branch — the
file guard rejects it, and the next scheduled run refuses to force-push over
commits it did not write.

So the Flutter CI fixer is kept away from this branch too. It skips
`toolchain/*` exactly the way it skips `dependabot/*` and `deps/*`: while
resolving the failed run, before any repair is generated, and again in the
publish job where the push would happen. "Repair the application code until the
checks pass" *is* the migration, and it is not a bot's call.

Nothing auto-merges. There is no merge command anywhere in the workflow, and a
test asserts that stays true.

### Major releases get an issue, not a PR

A new major stable release produces no branch, no commit and no change to
`.flutter-version`. The workflow opens — or updates, so the weekly run does not
refile it — one issue explaining that a major migration is available, which
version it is, and why it is intentionally manual:

- **Application APIs.** A major removes what earlier releases only deprecated.
- **The dependency graph.** The lockfile almost certainly has to be re-resolved,
  possibly with constraint changes in `pubspec.yaml` that no bot may write.
- **F-Droid and reproducibility.** The recipe and the build environment install
  this same pin; a major bump can change what a builder must provide and whether
  the build still reproduces, and CI cannot prove either.
- **The Android toolchain.** A major SDK often expects a different
  Gradle/AGP/Kotlin/JDK combination, which is its own review.

### Reviewing an SDK update PR

- Confirm the proposed version against the manifest details in the PR body.
- Check CI. Red is informative; work out whether it is an API deprecation, a
  formatting change from the newer Dart, or a lockfile that needs re-resolving.
- Do any migration in a separate PR, and refresh `pubspec.lock` with the new SDK
  there as well — the F-Droid build resolves from the committed lockfile.
- Re-read [`fdroid-build-recipe.md`](./fdroid-build-recipe.md) and the
  reproducibility notes, and update them if the bump changes what a builder must
  install.
- The Flatpak builds the SDK from the same pin, so the migration PR is also
  where its sources get regenerated (`./scripts/regenerate_flatpak_sources.sh`)
  and the template's Flutter `commit` moves to the one the new tag resolves to.
  See [source pinning](./flatpak-source-pinning.md).
- Merge manually when you are happy with it. Nothing auto-merges, by design.

### One-time setup

The same repository Actions secret the Dart package updater uses:

- `DEPENDENCY_UPDATE_TOKEN` — a dedicated fine-grained token with **Contents:
  read/write** and **Pull requests: read/write** on this repository.

There is deliberately no second credential. A PR opened with the workflow's
default `GITHUB_TOKEN` triggers no checks, and an update PR that runs no CI is a
broken updater — so the workflow fails loudly rather than opening one. It only
asks for the token in the job that publishes, so a week with no update (or a
major, which files an issue) never touches it.

The major-update path needs no token at all: it uses the workflow's own
`GITHUB_TOKEN` with `issues: write`, granted in that one job. An issue runs no
CI, so it needs none of the publication token's reach. Everything else in the
workflow stays `contents: read`.

## Gradle, AGP and Kotlin

The fifth and last phase of #362, and the one with a sharp edge in it: two of
these three versions live in the **same file**.

### Where the pins live

```text
android/gradle/wrapper/gradle-wrapper.properties   the Gradle distribution
android/settings.gradle                            AGP and the Kotlin plugin
```

`test/tooling/toolchain_pins_test.dart` already requires each of those to be an
exact `MAJOR.MINOR.PATCH` — the F-Droid build resolves them offline from these
files, so a range or a `+` wildcard is not allowed. That means every update here
is, like the Flutter SDK one, a single version string.

### Where the release information comes from

Official, machine-readable and first-party, one index per tool. No HTML is
fetched or scraped, and no third-party version API is consulted.

| Tool | Index |
| --- | --- |
| Gradle | `https://services.gradle.org/versions/all` |
| AGP | `https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml` |
| Kotlin | `https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml` |

Each of those is the index Gradle itself would resolve the pin from:
`services.gradle.org` is the host in `distributionUrl`, and the two
`maven-metadata.xml` files describe the artifacts the `com.android.application`
and `org.jetbrains.kotlin.android` plugin ids resolve to — served by the
`google()` and `mavenCentral()` repositories already declared in
`android/settings.gradle`'s `pluginManagement` block. So a version this checker
proposes is one this project can actually resolve, by construction.

### Which releases count

A release is a candidate only if it is a bare `MAJOR.MINOR.PATCH`. That single
rule does the prerelease filtering structurally rather than by trying to
enumerate every marker upstream might invent: `-alpha01`, `-beta02`, `-rc01`,
`-RC`, `-Beta1`, `-milestone-1`, `-preview`, `-eap-1`, `-dev-123`, `-M1` and
`-SNAPSHOT` builds all carry a suffix and are therefore not triples. It also
excludes Gradle's historical two-component tags, which a pin file may not hold.

On top of that:

- a Gradle entry must be `final`, must not be `broken`, a snapshot, a nightly, a
  release-nightly, an active RC or a milestone for another release, and must
  download from `https://services.gradle.org/distributions/`. Those flags are
  upstream's own statement about the build, which is better evidence than
  anything guessable from a version string;
- Maven metadata must declare the group and artifact that was asked for, so a
  redirect or a typo cannot make the updater start tracking someone else's
  numbers. Its `<latest>` and `<release>` pointers are *ignored* — Kotlin's
  `<release>` routinely names an `-RC` build — and the version list is filtered
  instead.

### Two answers, kept apart

This is the part worth reading twice. For each tool the checker reports two
independent things:

- **the newest release still on the pinned major** — the only version an
  automatic PR may ever propose;
- **the newest release overall**, and whether that is on a newer major.

Both can be true in the same week, and when they are, both happen. If a pin is
on the 8.x line and upstream publishes both a newer 8.x and a first 9.x release,
the newer 8.x still gets its ordinary draft PR *and* the 9.x independently gets
a major-upgrade issue. Collapsing the two into one "how far behind are we"
number is exactly how a new major would silently swallow every later patch on
the line Linthra actually ships.

| Situation | Result |
| --- | --- |
| pinned version is the newest on its major, no newer major | nothing happens |
| newer patch or minor on the pinned major | draft PR |
| newer major, pin already newest on its own major | **issue**, and nothing else |
| newer patch or minor **and** a newer major | draft PR *and* an issue |

The comparison lives in `scripts/check_android_toolchain_update.py`, not in the
workflow YAML, so it can be tested offline against fixture indexes
(`test/tooling/android_toolchain_update_guardrails_test.dart` end to end, and
`test/tooling/android_toolchain_update_test.py` for the parsers). It uses no
third-party semantic-version package; three integers and a tuple comparison are
the whole algorithm.

It fails loudly rather than guessing, and a failure stops the whole run rather
than letting two tools publish while a third is misread. A pin it cannot parse,
an index it cannot parse, an index that is not the document it should be, an
index with no usable release, an index that lists nothing at all on the pinned
major line, or a "newest release" that is *older* than the pin all exit
non-zero. In particular the updater never proposes a downgrade.

Run it yourself:

```bash
python3 scripts/check_android_toolchain_update.py
python3 scripts/check_android_toolchain_update.py --tool kotlin --json
```

It reads files and writes nothing.

### One draft PR per tool

Three reusable branches, one reusable draft PR each:

```text
toolchain/gradle
toolchain/agp
toolchain/kotlin
```

Repeated runs update those PRs rather than opening a new one every Monday, and a
run whose target is already on the branch pushes nothing at all. Each tool has
its own commit subject prefix, so a commit belonging to one tool is *foreign* on
another's branch and the updater will not force-push over it.

### What the bot may touch, and why a filename is not enough

Each updater owns one file:

| Branch | May write |
| --- | --- |
| `toolchain/gradle` | `android/gradle/wrapper/gradle-wrapper.properties` |
| `toolchain/agp` | `android/settings.gradle` |
| `toolchain/kotlin` | `android/settings.gradle` |

Look at the last two rows. **AGP and Kotlin are pinned in the same file**, so
"only `android/settings.gradle` changed" says nothing about *which* of the two
moved. A filename allowlist is satisfied by an AGP PR that also quietly bumps
Kotlin, or reword the comment above both. That is not a boundary.

So there are two guards, and they run together:

1. `scripts/check_dependency_update_files.sh --kind gradle|agp|kotlin` bounds
   **which files** moved. It is the same script the Dart and Flutter SDK
   updaters use, with three more deliberately separate allowlists.
2. `scripts/check_toolchain_pin_diff.py --kind gradle|agp|kotlin` bounds **what
   changed inside them**. It finds the tool's own version in the previous and
   the new text, puts the *old* version back into the new text, and requires the
   result to be byte-identical to the old file.

That second check is the interesting one, because it needs no list of things to
watch out for. Everything outside the one captured version — the other plugin's
version, comments, whitespace, ordering, the other wrapper properties, the
distribution flavour — is protected by construction: putting the old version
back could not possibly reproduce the old file if anything else had moved. It
also rejects a target that is not a bare triple, a downgrade, and any change
that crosses a major.

Both guards run twice: inside the workflow before a commit exists, and again in
CI against the **real PR diff**, so a commit pushed onto an update PR afterwards
is caught too.

CI matches the three automatic branches **exactly**, never by `toolchain/`
prefix. A prefix rule would be wrong twice over: it would hold every future
human `toolchain/*` PR to the pin-only rule, and it could not tell which of the
three pins a given PR is allowed to move. #373 deliberately fixed the first half
of that problem for the Flutter SDK branch; this phase keeps the rule and adds
the second half.

An automatic toolchain update therefore never changes application code, test
code, `pubspec.yaml`, `pubspec.lock`, `.flutter-version`, `.java-version`,
`metadata/`, `fastlane/`, the app version or versionCode, release notes, signing
files, licenses, or unrelated workflows and docs. AGP cannot change Kotlin,
Kotlin cannot change AGP, and Gradle cannot change either.

The write itself is `scripts/set_android_toolchain_pin.py`, which is the only
script in the repository allowed to move one of these pins. It refuses a
downgrade, a major, a non-triple version and a no-op rewrite, and it reads the
file back afterwards. It shares `scripts/toolchain_pins.py` with the guard on
purpose: if the writer's idea of "the AGP version" ever drifted from the guard's,
the guard would be checking something the writer never touches.

### Normal CI runs on it, and red is the point

These PRs are published with the dedicated token, so GitHub triggers the
repository's normal `pull_request` checks on them exactly like any other PR.

A newer build tool can change a default, tighten a deprecation or need
configuration this project does not have yet. Any of that turns the PR red, and
**that is the finding**. The migration is a separate, human PR. Do not push it
onto the update branch — the guards reject it, and the next scheduled run
refuses to force-push over commits it did not write.

So the Flutter CI fixer is kept away from these branches too. It already skips
`toolchain/*` the way it skips `dependabot/*` and `deps/*`, both while resolving
the failed run and again in the publish job, and that now covers all four
toolchain branches. Its protected-path guard also refuses to let an agent patch
touch `android/settings.gradle` or `gradle-wrapper.properties` in *any* PR:
"repair the build by moving a build-tool version" is never the fix.

Nothing auto-merges. There is no merge command anywhere in the workflow, and a
test asserts that stays true.

### Major releases get an issue, not a PR

A new major produces no branch, no commit and no pin change. The workflow opens
— or updates, so the weekly run does not refile it — one issue per tool, titled
for the whole major line so a later release within that major edits it in place.

The issue states the currently pinned version, the newest stable version, the
newest stable version still available on the pinned major, the upstream index it
came from, and why the upgrade is manual:

- **Flutter compatibility.** Flutter ships its own Gradle plugin and supports a
  bounded range of build tooling. The SDK in `.flutter-version` decides what this
  project may use, and "newer" is not the same as "supported".
- **The Android build itself.** A major changes defaults, removes deprecated DSL
  and can alter what ends up in the APK.
- **F-Droid and reproducibility.** The F-Droid builder resolves this toolchain
  offline from these files. A major can change what a builder must provide and
  whether the build still reproduces, and CI cannot prove either. See
  [`fdroid-build-recipe.md`](./fdroid-build-recipe.md) and the reproducibility
  notes.
- **The rest of the toolchain.** Gradle, AGP, Kotlin and the JDK move as a
  compatible set.

The AGP issue carries an extra warning, and it is the most important sentence in
this whole document: Linthra's F-Droid release still builds its per-ABI
`versionCode`s by iterating `applicationVariants` in `android/app/build.gradle`.
That is legacy Android DSL, and the next AGP major removes the API it depends
on. Bumping that pin without first porting the logic does not necessarily
produce a build failure — it can produce a **wrong `versionCode` scheme**, which
is the one thing an F-Droid release cannot get wrong, because published version
codes can never be reused or walked back. The port is the work item; the version
bump is the easy part.

### Reviewing a toolchain update PR

- Confirm the proposed version against the index details in the PR body.
- Check that the Flutter SDK in `.flutter-version` actually supports it. Newer
  is not the same as supported.
- Check CI. Red is informative; work out what the new version changed.
- Do any migration in a separate PR.
- Re-read [`fdroid-build-recipe.md`](./fdroid-build-recipe.md) and the
  reproducibility notes, and update them if the bump changes what a builder must
  install.
- Merge manually when you are happy with it. Nothing auto-merges, by design.

### One-time setup

The same repository Actions secret the other two updaters use, and no second
credential:

- `DEPENDENCY_UPDATE_TOKEN` — a dedicated fine-grained token with **Contents:
  read/write** and **Pull requests: read/write** on this repository.

The token is only required in the job that publishes a PR, so a week with
nothing to propose never touches it — and neither does the major path, which
uses the workflow's own `GITHUB_TOKEN` with `issues: write` granted in that one
job. Everything else in the workflow stays `contents: read`.

### Running the tests

```bash
flutter test test/tooling/android_toolchain_update_guardrails_test.dart
python3 test/tooling/android_toolchain_update_test.py
```

Both are fully offline: fixture release indexes, throwaway git repositories, and
no network access at all.
