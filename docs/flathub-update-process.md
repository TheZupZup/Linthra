# From an upstream release to a Flathub update

Issues: #453, #452  
Parent: #376

How a normal Linthra release becomes a reviewed Flatpak update, and who owns
what along the way. It is written for a maintainer doing this the first time,
so every command is spelled out.

This page does **not** repeat the Android/F-Droid release steps. Cutting the
release itself (version bump, tag, GitHub Release) is
[release-process.md](./release-process.md); this page starts from the tag that
already exists and ends at a published Flatpak.

Related pages, each with a different job:

* [flatpak-development.md](./flatpak-development.md): building, installing and
  debugging the Flatpak on your own machine.
* [flatpak-ci.md](./flatpak-ci.md): what the automated Flatpak build proves on
  every packaging PR, and how to reproduce it locally.
* [flathub-builder-lint.md](./flathub-builder-lint.md): Flathub's own submission
  linter, the exact commands, and the exceptions policy.
* [flatpak-offline-build.md](./flatpak-offline-build.md): why the sandboxed
  build needs no network, and how that is audited.
* [`flatpak/README.md`](../flatpak/README.md): what each packaging file is and
  why the manifest looks the way it does.

## Current state

Linthra is **not on Flathub yet**. The packaging in this repository builds,
installs and launches, and CI validates it on every packaging PR, but the
submission itself is still open work: the submission repository (#451), the
Flathub linter run (#449), real Linux screenshots (#437), the metadata accuracy
pass (#450), the final permission audit (#455) and the submission (#456).

So the steps below are split: everything under
[In this repository](#1-in-this-repository-linthra) is live today and should be
followed for every release. Everything under
[In the Flathub repository](#2-in-the-flathub-repository) describes the shape
of the update once #451 and #456 have landed, and should be re-read (and
corrected) when they do.

## Who owns what

| Thing | Lives in | Source of truth |
| --- | --- | --- |
| App source, version, tag | `TheZupZup/Linthra` | `pubspec.yaml` |
| AppStream listing (`<release>`, description, screenshots) | `TheZupZup/Linthra` | `linux/packaging/io.github.thezupzup.linthra.metainfo.xml` |
| Desktop entry, icon | `TheZupZup/Linthra` | `linux/packaging/` |
| Development manifest (builds the working checkout) | `TheZupZup/Linthra` | `flatpak/io.github.thezupzup.linthra.yml`, generated from `flatpak/flatpak-flutter.yml` |
| Published manifest (builds a tagged release) | `flathub/io.github.thezupzup.linthra` (once #451 lands) | the Linthra tag it pins |

The two manifests differ in exactly one thing that matters here: the one in
this repository builds `type: dir`, the checkout you are standing in, so it has
no version of its own to keep in step. The published one pins a Linthra git
tag, which is what makes a Flathub update a deliberate, reviewable change
rather than something that follows `main`.

## 1. In this repository (Linthra)

### 1.1 Cut the release

Follow [release-process.md §3](./release-process.md#3-pre-tag-checklist). The
version bump writes the AppStream release entry along with everything else:

```sh
python3 scripts/prepare_release_bump.py 0.2.7
```

Merge that PR, then tag, exactly as the release process describes. The tag is
what the Flathub manifest will point at.

### 1.2 Check every surface names that release

```sh
python3 scripts/check_release_metadata_sync.py --tag v0.2.7
```

This reads `pubspec.yaml`, `lib/core/app_info.dart`, the Play changelog, the
F-Droid entry and the AppStream `<release>` list, and reports every
disagreement at once. CI runs it on every push, so it should already be green;
run it here because the AppStream entry is the one a software centre shows for
the build people just installed, and a stale entry breaks nothing else.

### 1.3 Regenerate the pinned sources, if the inputs changed

Only needed when `.flutter-version` or `pubspec.lock` changed since the last
release:

```sh
./scripts/regenerate_flatpak_sources.sh
```

This needs network access (it pins every dependency by URL and sha256) and
rewrites `flatpak/io.github.thezupzup.linthra.yml` and `flatpak/generated/`.
Commit the result in its own PR. Never hand-edit the generated manifest; see
[`flatpak/README.md`](../flatpak/README.md#regenerating-the-pinned-sources).

### 1.4 Validate the packaging metadata

```sh
python3 scripts/check_linux_runner.py
python3 test/tooling/check_linux_runner_test.py

desktop-file-validate linux/packaging/io.github.thezupzup.linthra.desktop
appstreamcli validate linux/packaging/io.github.thezupzup.linthra.metainfo.xml
```

`check_linux_runner.py` holds the app id, binary name, window title, desktop
entry, icon and their install steps to their real sources of truth.
`appstreamcli validate` is the upstream AppStream check; Flathub's own linter
is stricter, and is step 1.6.

### 1.5 Build and smoke-test the Flatpak

The full local sequence is in
[flatpak-ci.md](./flatpak-ci.md#reproduce-the-build-locally). The short form,
from `flatpak/`:

```sh
flatpak-builder --user --install-deps-from=flathub --install-deps-only \
  --force-clean flatpak-builder-ci io.github.thezupzup.linthra.yml

rm -rf -- flatpak-builder-ci repo-ci
flatpak-builder --user --force-clean --disable-cache --disable-rofiles-fuse \
  --repo=repo-ci flatpak-builder-ci io.github.thezupzup.linthra.yml

flatpak build-update-repo repo-ci
bash ../scripts/flatpak_launch_smoke.sh repo-ci
```

Then install it and use it as a person would, because CI cannot: play a local
file, connect a server you actually run, check that credentials survive a
restart. The manual list is
[manual-test-checklist.md](./manual-test-checklist.md), and the sandbox-specific
notes are in
[`flatpak/README.md`](../flatpak/README.md#network-access-and-endpoint-validation).

### 1.6 Run the Flathub linter

Flathub runs `flatpak-builder-lint` on the submission and treats its warnings
as failures. Wiring that into CI is #449; until that lands, run it by hand
from the repository root (step 1.5 left you in `flatpak/`), against the
manifest and the repository it exported:

```sh
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  manifest flatpak/io.github.thezupzup.linthra.yml
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  repo flatpak/repo-ci
```

Fix what it reports in this repository, not in the Flathub one: the
submission manifest should be a thin wrapper around packaging that is already
clean here.

## 2. In the Flathub repository

Once #451 and #456 have landed, Flathub hosts
`flathub/io.github.thezupzup.linthra`, and Linthra's entry there is a manifest
that pins a tag of this repository instead of building a local directory.

An update is then one small pull request **in that repository**:

1. Point the Linthra source at the new tag (and its commit, when the manifest
   pins one).
2. Refresh anything else the release changed: the Flutter SDK module and the
   pinned pub sources, if step 1.3 regenerated them.
3. Open the PR. Flathub's build bot builds it and publishes a test build to a
   per-PR remote.
4. Install that test build and repeat the smoke checks from step 1.5 against
   the artifact Flathub actually built.
5. Get the PR reviewed and merged. Nothing here is auto-merged, and nothing in
   this repository pushes to Flathub on its own.

After it publishes, install the real thing from Flathub and confirm the version
the About screen shows is the release you tagged, and that the software centre
shows the `<release>` entry from step 1.1.

No credentials from this repository are involved at any point. The Flathub PR
is made with a maintainer's own GitHub account, and Flathub signs and publishes
the build itself.

## When an update goes wrong

Flathub publishes from its own build of a tagged source, so a bad update is
fixed in whichever repository actually holds the mistake.

**A packaging mistake** (wrong tag, a source that no longer resolves, a
permission that should not have changed): revert that pull request in the
Flathub repository, which returns the published manifest to the previous
release, and let the build bot republish. Nothing in this repository changes.

**An app bug that reached the published build**: fix it upstream and cut a new
patch release (§1), then point Flathub at the new tag. Do not rewrite the
`<release>` entry of the version people already installed: add the new one
above it, so the listing stays an accurate history. If the bad version needs to
be withdrawn as well, that is a Flathub-side end-of-life/rollback request, not
an edit to this repository.

**Something is wrong but you are not sure which side**: build the tag locally
with the development manifest (step 1.5). If it reproduces there, it is an
upstream bug; if it only happens in the Flathub build, the difference is in the
published manifest.

Either way, prefer fixing forward with a new release over holding a broken
build in place: users get updates from Flathub automatically, and a revert that
pins the previous tag is itself an update.
