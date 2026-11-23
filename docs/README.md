# Linthra documentation

The full index of Linthra's docs. New to the project? Start with the
[main README](../README.md) for an overview, then
[CONTRIBUTING.md](../CONTRIBUTING.md) for setup.

## Getting started & contributing

| Topic | Doc |
| --- | --- |
| Contributing & setup | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Development, build & CI | [development.md](./development.md) |
| Linux desktop build (experimental) | [linux-desktop.md](./linux-desktop.md) |
| Flatpak development (Fedora Atomic) | [Flatpak development on Fedora Atomic](distribution/flatpak/development.md) |
| Codebase tour (where everything lives) | [codebase-tour.md](./codebase-tour.md) |
| Architecture & extension points | [architecture.md](./architecture.md) |
| Where to help (contributor roadmap) | [contributor-roadmap.md](./contributor-roadmap.md) |
| Product roadmap (phased direction) | [roadmap.md](./roadmap.md) |
| Supporting Linthra (optional supporter model) | [SUPPORT.md](./SUPPORT.md) |

## Features

| Topic | Doc |
| --- | --- |
| Library browsing & search | [library.md](features/library.md) |
| Local music (on-device folders) | [local-music.md](features/local-music.md) |
| Optical media detection (Linux) | [optical-media.md](./optical-media.md) |
| Music providers (overview) | [Music providers](servers/overview.md) |
| Jellyfin setup | [jellyfin.md](servers/jellyfin.md) · [compatibility](servers/jellyfin-compatibility.md) · [sync](servers/jellyfin-sync.md) |
| Plex setup | [plex.md](servers/plex.md) |
| WebDAV / NAS provider (design) | [webdav.md](./webdav.md) |
| Streaming, buffering & recovery | [streaming.md](features/streaming.md) |
| Queue / Up Next | [queue.md](features/queue.md) |
| Offline cache & downloads | [offline-cache.md](features/offline-cache.md) |
| Cast / Chromecast | [cast.md](features/cast.md) · [receiver trust](./cast-receiver-trust.md) · [hardened design](./cast-hardened-design.md) · [what a handoff delegates](./cast-media-access.md) · [client design](./cast-client-design.md) |
| Remote control (drive Linthra from another app) | [remote-control.md](features/remote-control.md) |
| Android Auto | [android-auto.md](features/android-auto.md) |
| Playlists & safe removal | [playlists-and-delete.md](features/playlists-and-delete.md) |
| Smart mixes (automatic playlists) | [smart-mixes.md](features/smart-mixes.md) |
| Backup & restore (file format) | [backup-restore-format.md](features/backup-restore-format.md) |
| Battery usage | [battery.md](features/battery.md) · [playback audit](audits/battery-playback.md) |
| App icon & branding (in-app + real Android launcher icon) | [app-icon-branding.md](./app-icon-branding.md) |

## Quality & releases

| Topic | Doc |
| --- | --- |
| Reporting a bug | [reporting-bugs.md](./reporting-bugs.md) |
| Manual QA checklist | [manual-test-checklist.md](./manual-test-checklist.md) |
| Accessibility, TalkBack & Linux Orca checklists | [accessibility.md](features/accessibility.md) |
| GNOME & KDE Plasma compatibility matrix | [desktop-compatibility-matrix.md](./desktop-compatibility-matrix.md) |
| Desktop HiDPI & fractional scaling | [hidpi-and-scaling.md](./hidpi-and-scaling.md) |
| Linux startup benchmark | [tools/startup/README.md](../tools/startup/README.md) |
| Release process & signing | [release-process.md](distribution/release-process.md) · [signing](distribution/release-signing.md) · [artifact verification](distribution/release-artifact-verification.md) |
| Dependency update bots | [dependency-updates.md](./dependency-updates.md) |
| PR security surface guard | [pr-security-guard.md](audits/pr-security-guard.md) |
| Tracker dependency audit (no ads/analytics/telemetry SDKs) | [Tracker dependency audit](audits/tracker-dependencies.md) |
| Fixed network destinations (every host the shipped code names) | [network-destinations.md](audits/network-destinations.md) |
| Privacy audit status (what is checked, and the limits) | [PRIVACY_AUDIT.md](../PRIVACY_AUDIT.md) |
| F-Droid readiness | [F-Droid readiness checklist](distribution/f-droid/readiness.md) |
| Google Play readiness | [Google Play readiness checklist](distribution/google-play/readiness.md) |
| Flatpak build CI | [Flatpak CI validation](distribution/flatpak/ci.md) |
| Flatpak audio playback smoke | [Flatpak audio playback smoke](distribution/flatpak/audio-smoke.md) |
| Flatpak local-library sandbox smoke | [Flatpak local-library sandbox smoke](distribution/flatpak/local-library-smoke.md) |
| Flatpak sandbox filesystem audit | [Flatpak filesystem sandbox audit](audits/flatpak-filesystem.md) |
| Flatpak permission audit | [flatpak-permissions.md](audits/flatpak-permissions.md) |
| Flatpak source pinning & refresh | [Flatpak source pinning](distribution/flatpak/source-pinning.md) |
| Flathub builder lint | [flathub-builder-lint.md](distribution/flatpak/flathub-builder-lint.md) |
| Flathub screenshots | [flathub-screenshots.md](distribution/flatpak/flathub-screenshots.md) |
| Flathub updates (release to published Flatpak) | [flathub-update-process.md](distribution/flatpak/flathub-update-process.md) |

## Licensing & legal

Linthra is **AGPL-3.0-or-later**. Releases up to and including v0.2.4 were
published under MPL-2.0 and remain under those terms.

| Topic | Doc |
| --- | --- |
| Current license (GNU AGPLv3) | [LICENSE](../LICENSE) |
| Historical license texts | [licenses/](./licenses/README.md) · [MPL-2.0.txt](./licenses/MPL-2.0.txt) |
| License transition record | [license-transition.md](audits/license-transition.md) |
| Contributor consent record | [relicensing-consent.md](audits/relicensing-consent.md) |
| Dependency & license audit | [Dependency & license audit](audits/dependency-licenses.md) |
| Branding / trademark policy | [TRADEMARKS.md](../TRADEMARKS.md) |
| Privacy policy | [privacy-policy.md](./privacy-policy.md) |
