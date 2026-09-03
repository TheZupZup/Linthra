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

The launch command requires `xvfb-run`, `xwininfo` and `dbus-run-session`, the
same tools installed by the CI job. It intentionally refuses to run if Linthra
is already installed for the current user or system-wide, so a local smoke can
never launch or remove a contributor's existing installation. Use a clean test
user/environment for this final step when Linthra is already installed.

The workflow does not replace the stricter offline-source smoke from #442 or the
installed-Flatpak audio/library sandbox smokes tracked in #446 and #447. Its job
is to catch broken manifests, missing declared build inputs, SDK/runtime
resolution problems, clean-runner packaging failures, install failures and
startup regressions before they reach Flathub.
