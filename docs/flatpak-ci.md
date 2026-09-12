# Flatpak CI validation

Linthra's Flatpak packaging has a dedicated GitHub Actions build in
`.github/workflows/flatpak-build.yml`. It runs on packaging-relevant pull
requests and pushes to `main`, plus manual dispatches.

The workflow is intentionally read-only and does not use repository secrets, so
fork pull requests can run the same validation as maintainer branches.

## What CI proves

The job starts from a clean Ubuntu runner and:

1. installs Flatpak, flatpak-builder, AppStream, desktop-entry and headless X11
   validation tools;
2. runs Linthra's committed Linux packaging checks;
3. validates the desktop entry and AppStream metadata;
4. adds a user-level Flathub remote;
5. asks flatpak-builder to install the SDK/runtime prerequisites declared by the
   generated manifest;
6. builds the real generated Flatpak manifest with module-cache reuse disabled;
7. exports the result into a local Flatpak repository and verifies that export;
8. installs Linthra from that local repository;
9. launches the packaged app inside an Xvfb + D-Bus session and waits for a real
   `Linthra` desktop window before terminating and cleaning up the test install.

For a **release build** (a `workflow_dispatch` with `release_tag` set, which is
how `publish-stable-release.yml` produces the `.flatpak` a Release carries) the
same job additionally checks out that exact tag, verifies the release metadata
at it, exports the bundle from the repository it just built, checks the bundle
against the manifest, and installs and launches *that file*. A separate,
gated job then attaches it. See
[release-process.md §4b](./release-process.md#4b-linux-flatpak-bundle-dispatched-alongside-the-android-and-linux-builds).
Nothing about a PR or push run changes.

No `actions/cache` entry is used by this workflow. Correctness therefore does
not depend on developer machine state or a warm GitHub Actions cache. The build
uses `--disable-rofiles-fuse` only to avoid requiring FUSE support from the
hosted runner; it does not widen the application's Flatpak sandbox.

The launch smoke is also deliberately local and credential-free. Its temporary
`--no-gpg-verify` remote points only at the unsigned repository built by the
same CI job; that option is never used for Flathub or another public remote.

## Reproduce the build locally

Install the host tooling first. On Fedora Atomic, the contributor setup in
[`flatpak-development.md`](./flatpak-development.md) remains the recommended
path. On a distribution with native `flatpak-builder`, the core CI sequence is:

> Two host packages are easy to miss because nothing hard-depends on them, and
> both fail late and confusingly:
>
> * **elfutils** (`eu-strip`), which `flatpak-builder` uses to split debug
>   symbols out of each module. Debian and Ubuntu only *recommend* it, so a
>   minimal install leaves it out and the build fails on the first native module
>   with `Failed to execute child process "eu-strip"`.
> * **librsvg2-common**, the gdk-pixbuf SVG loader. Without it the
>   `appstreamcli compose` step at finish time cannot read Linthra's scalable
>   icon and fails the build with `file-read-error` plus
>   `filters-but-no-output`. Nothing in `appstream` depends on or recommends it.
>
> The CI job names both explicitly for that reason.

```bash
python3 scripts/check_linux_runner.py
python3 test/tooling/check_linux_runner_test.py

desktop-file-validate \
  linux/packaging/io.github.thezupzup.linthra.desktop
appstreamcli validate \
  linux/packaging/io.github.thezupzup.linthra.metainfo.xml

flatpak remote-add --user --if-not-exists \
  flathub https://dl.flathub.org/repo/flathub.flatpakrepo

cd flatpak
flatpak-builder \
  --user \
  --install-deps-from=flathub \
  --install-deps-only \
  --force-clean \
  flatpak-builder-ci \
  io.github.thezupzup.linthra.yml

rm -rf -- flatpak-builder-ci repo-ci
flatpak-builder \
  --user \
  --force-clean \
  --disable-cache \
  --disable-rofiles-fuse \
  --repo=repo-ci \
  flatpak-builder-ci \
  io.github.thezupzup.linthra.yml

flatpak build-update-repo repo-ci
bash ../scripts/flatpak_launch_smoke.sh repo-ci
```

To reproduce the release bundle from that same export (nothing here uploads
anything):

```bash
cd flatpak
name="$(python3 ../scripts/flatpak_bundle.py name --tag v0.2.7)"
flatpak build-bundle \
  --arch="$(flatpak --default-arch)" \
  --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  repo-ci "$name" io.github.thezupzup.linthra master

python3 ../scripts/flatpak_bundle.py verify "$name" --tag v0.2.7
bash ../scripts/flatpak_launch_smoke.sh "$name"
```

`flatpak_bundle.py verify` needs `ostree` as well as `flatpak`: reading a
bundle means importing its OSTree static delta into a scratch repository and
checking it out. It installs nothing and does not touch an existing Flatpak
installation. Its rules are unit-tested offline by
`python3 test/tooling/flatpak_bundle_test.py`, which `ci.yml` runs on every PR.

The launch command requires `xvfb-run`, `xwininfo`, `xprop` and
`dbus-run-session`, the same tools installed by the CI job. It intentionally refuses to run if Linthra
is already installed for the current user or system-wide, so a local smoke can
never launch or remove a contributor's existing installation. Use a clean test
user/environment for this final step when Linthra is already installed.

### What a smoke may delete on your machine

CI runners start clean, so none of this matters there. It matters locally, and
the rule is the same for every smoke in `scripts/`: each removes what it
created, and nothing else.

None of them uses `flatpak uninstall --delete-data`. That flag deletes
`~/.var/app/io.github.thezupzup.linthra/` (library database, settings, offline
audio, credentials) and clears the app's Flatpak permission-store entries, the
document-portal grants for the music folders you picked, and it reaches both
whether or not the run put them there. An ordinary uninstall leaves a data tree
behind, so "Linthra is not installed" says nothing about whether one exists.

The three smokes that install the app themselves (`flatpak_audio_smoke.sh`,
`flatpak_local_library_smoke.sh`, `flatpak_filesystem_smoke.sh`) therefore
look for
`~/.var/app/io.github.thezupzup.linthra/` *before* they install anything,
uninstall plainly on the way out, and remove that directory only when it was
not already there. `flatpak_launch_smoke.sh` never removes app data at all. So
a data tree you already had, and your permission-store grants, are never
removed by a smoke. For the commands that *do* delete that data, when you want
it gone, see
[flatpak-development.md § Clean and uninstall](./flatpak-development.md#clean-and-uninstall).

## The audio smoke job beside it

The same workflow runs a second job, `Audio lifecycle smoke in the sandbox`,
on its own runner and in parallel. It builds a manifest derived from the
submission manifest (the same package plus a test binary under `/app/libexec`)
and walks the real playback lifecycle inside the installed sandbox, on the
libmpv the manifest built rather than one the host happens to have.

That job has its own document:
[flatpak-audio-smoke.md](./flatpak-audio-smoke.md), including what it
deliberately does *not* prove.

The workflow does not replace the stricter offline-source smoke from #442 or the
installed-Flatpak library sandbox smoke tracked in #447. Its job
is to catch broken manifests, missing declared build inputs, SDK/runtime
resolution problems, clean-runner packaging failures, install failures and
startup regressions before they reach Flathub.
