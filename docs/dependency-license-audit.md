# Dependency & license audit

This document audits Linthra's declared dependencies and their licenses, so a
future F-Droid submission (and any GitHub-Release distribution) can state the
project's licensing accurately. It is a planning/compliance aid.

> **Linthra is _not_ on F-Droid and has _not_ been submitted.** Nothing here
> publishes or submits anything. This audit records the licensing posture of the
> code as it stands; see the [F-Droid readiness checklist](./fdroid-readiness.md)
> for the overall submission status and blockers.

## 1. Project license

Linthra is licensed under the **GNU Affero General Public License v3.0 or later**
(`AGPL-3.0-or-later`), an
[FSF/OSI-approved free license](https://www.gnu.org/licenses/license-list.html)
accepted by F-Droid. The full text is the unmodified GNU AGPLv3 in
[`LICENSE`](../LICENSE), and the SPDX identifier F-Droid expects is
`AGPL-3.0-or-later`.

Linthra was previously **MPL-2.0**. Releases up to and including **v0.2.4** were
published under MPL-2.0 and remain under those terms; that text is preserved
verbatim at [`licenses/MPL-2.0.txt`](./licenses/MPL-2.0.txt). See
[`license-transition.md`](./license-transition.md) for the transition record and
[`relicensing-consent.md`](./relicensing-consent.md) for contributor consent.

### Why the dependency set is compatible

AGPL-3.0-or-later is a **strong** copyleft, and compatibility with it is
**one-way**: permissive code can be taken into an AGPL work, but AGPL terms
cannot be imposed back on the dependency, whose own license and notices continue
to apply. Every dependency Linthra ships is either permissive (MIT / BSD-2-Clause
/ BSD-3-Clause / Apache-2.0 / public domain / Unlicense / ISC) or, for the native
Linux media chain, LGPL-2.1-**or-later**.

The specific combinations that need stating rather than assuming:

- **Apache-2.0 → AGPLv3: compatible.** GNU states Apache-2.0 is compatible with
  GPLv3 (and therefore AGPLv3), though not with GPLv2. `just_audio` is the
  Apache-2.0 dependency in the shipped set.
- **MPL-2.0 → AGPLv3: compatible, conditionally.** MPL-2.0 §1.12 defines a
  "Secondary License" as *"either the GNU General Public License, Version 2.0,
  the GNU Lesser General Public License, Version 2.1, the GNU Affero General
  Public License, Version 3.0, or any later versions of those licenses"*, and
  §3.3 permits distributing MPL-covered code as part of a Larger Work under such
  a Secondary License **provided the covered software is not marked
  "Incompatible With Secondary Licenses"** (the Exhibit B notice, §1.5).
  The one MPL-2.0 dependency in the tree, `dbus` (§3), is **not** so marked —
  verified by scanning every file in the published `dbus-0.7.12` archive: the
  phrase appears only inside the boilerplate Exhibit B *template* in its own
  `LICENSE`, and no source file carries the notice. The combination is therefore
  permitted.
- **LGPL-2.1-or-later → AGPLv3: compatible via the upgrade path.** LGPL-2.1
  **-or-later** may be used as LGPLv3, which is compatible with GPLv3/AGPLv3.
  `LGPL-2.1-only` would **not** be. The Linux media chain (§5) is
  or-later throughout.
- **`GPL-2.0-only` would be a blocker.** None is present; the Linux media chain
  is deliberately configured to exclude every GPL-only component (§5).

## 2. How this audit was produced (and its limits)

- **Scope:** the **committed** [`pubspec.lock`](../pubspec.lock) — the exact
  resolved set, not the `pubspec.yaml` constraints — plus the native components
  in the Android, Linux/Flatpak and Rust build paths (§5).
- **Method (mechanical and reproducible).** For every package resolved from
  pub.dev, the audit downloads that package's **published archive at the exact
  locked version** (`https://pub.dev/api/archives/<name>-<version>.tar.gz`),
  reads the `LICENSE` / `LICENCE` / `COPYING` file inside it, and classifies the
  text. Licenses are taken from the shipped archive rather than from the pub.dev
  web page, because pub.dev renders "unknown" on version pages for
  non-latest versions — an artifact of the site, not a real unknown license, and
  a trap that a page-scraping audit falls into for ~1/3 of this tree.
- **Ordering caveat that matters.** MPL-2.0's own text *names* the GPL, LGPL and
  AGPL in its §1.12 "Secondary License" definition. A naive text classifier that
  tests for "GNU Affero General Public License" before "Mozilla Public License"
  will mis-report every MPL-2.0 package as AGPL. Match MPL first.
- **Result — 163 entries in `pubspec.lock`:**

  | Source | Count | Licenses |
  | --- | --- | --- |
  | pub.dev hosted | 158 | **101** BSD-3-Clause, **43** MIT, **7** Apache-2.0, **6** BSD-2-Clause, **1** MPL-2.0 |
  | Flutter SDK (`flutter`, `flutter_test`, `flutter_web_plugins`, `sky_engine`) | 4 | BSD-3-Clause (the SDK's own license) |
  | Vendored path dependency (`just_audio_media_kit`) | 1 | Unlicense (public domain) — see §5 |

  **No GPL, no LGPL, no proprietary, and no unknown or unverifiable license** in
  the resolved Dart/Flutter set. The single MPL-2.0 package is `dbus 0.7.12`
  (§3). Counts by dependency kind: 22 direct-main, 3 direct-dev and 133
  transitive hosted packages.
- **Supersedes the earlier snapshot.** A previous revision of this document
  reported 152 packages against Flutter 3.27.4 and, separately, classified
  `just_audio` as MIT. Both are corrected here: the tree is now 163 entries
  against the committed lockfile, and `just_audio 0.9.46` ships an
  **Apache-2.0** `LICENSE`.
- **Limits.** This is a repository/license engineering audit against the
  committed lockfile and committed build manifests. It is **not legal advice**,
  and it describes the *declared* build inputs — a distribution that rebuilds
  Linthra against different system libraries is responsible for its own
  compliance.
- **To reproduce:**

  ```sh
  # Every resolved package's license, read from its published archive.
  # (See the "Ordering caveat" above before writing the classifier.)
  flutter pub get
  flutter pub deps --style=compact
  dart pub global activate pana && pana --no-warning .
  ```

## 3. Runtime dependencies (shipped in the APK)

All entries below are permissive free-software licenses (MIT, BSD-3-Clause or
Apache-2.0), compatible with AGPL-3.0-or-later (§1) and acceptable to F-Droid.
The **Locked** column is the version in the committed
[`pubspec.lock`](../pubspec.lock); the license is the one read from that exact
published archive (§2).

| Package                  | Constraint   | Publisher (pub.dev) | License        | Purpose in Linthra |
| ------------------------ | ------------ | ------------------- | -------------- | ------------------ |
| `flutter` (SDK)          | (SDK)        | flutter.dev         | BSD-3-Clause   | Framework. |
| `flutter_riverpod`       | `^2.6.1`     | (rrousselGit)       | MIT            | State management. |
| `go_router`              | `^14.6.2`    | flutter.dev         | BSD-3-Clause   | Navigation/routing. |
| `path`                   | `^1.9.0`     | dart.dev            | BSD-3-Clause   | Path parsing for the scanner. |
| `drift`                  | `^2.18.0`    | simonbinder.eu      | MIT            | Typed SQLite query layer. |
| `sqlite3_flutter_libs`   | `^0.5.20`    | simonbinder.eu      | MIT            | Bundles the native SQLite engine (see §5). |
| `path_provider`          | `^2.1.4`     | flutter.dev         | BSD-3-Clause   | Locates the on-device DB file. |
| `just_audio`             | `^0.9.42`    | ryanheise.com       | **Apache-2.0** | Local audio playback engine. Apache-2.0, not MIT — corrected in this revision (§2). |
| `audio_service`          | `^0.18.15`   | ryanheise.com       | MIT            | Background playback / media session. |
| `file_picker`            | `^8.1.4`     | (miguelpruivo)      | MIT            | Native folder chooser (SAF). |
| `shared_preferences`     | `^2.3.3`     | flutter.dev         | BSD-3-Clause   | Persists the selected folder. |
| `http`                   | `^1.2.0`     | dart.dev            | BSD-3-Clause   | HTTP client for the optional self-hosted sources — Jellyfin and Navidrome/Subsonic (§7). |
| `crypto`                 | `^3.0.3`     | dart.dev            | BSD-3-Clause   | MD5 hashing for the Subsonic/Navidrome `token = md5(password + salt)` auth scheme, so only the derived `(salt, token)` is stored — never the plaintext password (§7). Also pulled in transitively by `just_audio`. |
| `flutter_secure_storage` | `^9.2.2`     | (juliansteenbakker) | BSD-3-Clause   | Encrypted store for the Jellyfin/Subsonic session token (§7). |
| `cast`                   | `^2.1.0`     | (johnvuko)          | MIT            | Pure-Dart Google Cast v2 protocol for real Chromecast — **no** Google Play Services / proprietary Cast SDK. See §5 (Casting). |
| `bonsoir`                | `^5.1.11`    | (Skyost)            | MIT            | mDNS/Bonjour service discovery used by `cast`; Android side is AOSP `NsdManager`, not GMS. Pinned to 5.x for Dart 3.6 (6.x+ needs Dart ≥3.8). See §5 (Casting). |
| `url_launcher`           | `^6.3.0`     | flutter.dev         | BSD-3-Clause   | Opens the browser for the "Report a bug" → "Open GitHub issue" action (a prefilled, **unsubmitted** issue the user reviews). AOSP `ACTION_VIEW` intent; **no** GMS. See note below and §7 (Reporting a bug). |
| `permission_handler`     | `^11.3.1`    | baseflow.com        | MIT            | Runtime permission requests. |
| `audio_metadata_reader`  | `^1.7.1`     | (ClementBeal)       | MIT            | Reads local audio tags on desktop/Linux (ID3, Vorbis comments, MP4 atoms, APEv2, RIFF INFO). Pure Dart, parses tag structures rather than loading whole files. |
| `audio_session`          | `^0.1.25`    | ryanheise.com       | MIT            | Audio-focus / interruption handling. |
| `media_kit_libs_linux`   | `^1.2.1`     | media-kit.dev       | MIT            | Linux native registration for media_kit; links the **system/Flatpak libmpv** built in §5. Ships no prebuilt binary. |
| `dbus`                   | `^0.7.12`    | canonical.com       | **MPL-2.0**    | D-Bus client behind the Linux MPRIS media session, so desktop shells and media keys can control Linthra. Already in the tree transitively (via `bonsoir_linux`); now declared directly. Compatible with AGPL-3.0-or-later under MPL-2.0 §3.3 — see §1 and §3. |
| `just_audio_media_kit`   | (vendored)   | — (see §5)          | Unlicense      | Vendored Linux `just_audio` backend. Third-party code — **not** relicensed (§5). |
| `media_kit`              | `^1.2.6`     | media-kit.dev       | MIT            | The libmpv binding the vendored Linux backend already runs on. Already in the tree transitively (via `just_audio_media_kit`); now declared directly, because Linthra calls its audio output device API for Linux output selection ([#402](https://github.com/thezupzup/linthra/issues/402)). |

> `audio_metadata_reader` was added so a Linux local library shows real titles,
> artists, albums and durations instead of filenames
> ([#407](https://github.com/thezupzup/linthra/issues/407)). It is **MIT**, pure
> Dart, and pulls in two transitive runtime packages: `charset` (`2.0.1`,
> (shirne), **Apache-2.0**) for the legacy text encodings ID3v2 tags can use, and
> `intl` (`0.20.3`, dart.dev, **BSD-3-Clause**) for date parsing. Apache-2.0 is
> compatible with AGPL-3.0-or-later (§1). The package reads only files the user
> selected; it makes no network calls and Android does not use it at all (tags
> there still come from the native SAF walk).

> The `http` and `flutter_secure_storage` entries were added with the Jellyfin
> source foundation; `cast` and `bonsoir` were added with real Chromecast
> support (§5, Casting). All four are permissive (MIT / BSD-3-Clause) Dart/Flutter-
> ecosystem packages. `cast` pulls in one transitive runtime package, `protobuf`
> (`^3.1.0`, dart.dev, **BSD-3-Clause**), used only to frame cast-channel
> messages — also free software, no GMS. `url_launcher` was added with the
> "Report a bug" flow; it is the official Flutter-team plugin (**BSD-3-Clause**),
> and on Android it fires a standard AOSP `ACTION_VIEW` intent (no Google Play
> Services). It is wrapped behind the `ExternalLinkLauncher` interface and is
> invoked only on an explicit user tap — the app never opens a link on its own.
> See §7.

### The one MPL-2.0 dependency (`dbus`)

`dbus 0.7.12` (Canonical, **MPL-2.0**) is the only non-permissive package in the
resolved Dart set. It reaches the tree two ways now:

```
bonsoir  ->  bonsoir_linux 5.1.3  ->  dbus 0.7.12
linthra  ->  dbus 0.7.12                            (declared directly)
```

It was transitive-only until the Linux MPRIS media session
([#397](https://github.com/thezupzup/linthra/issues/397)) started using it
directly. Same package, same version, same license — what changed is that
Linthra now depends on it deliberately rather than inheriting it. It remains a
**Linux-desktop-only** dependency (mDNS/Cast discovery, and now MPRIS) and it
*is* in the shipped Linux build path — not a dev-only package.

It is compatible with AGPL-3.0-or-later under MPL-2.0 §3.3, because it is not
marked "Incompatible With Secondary Licenses"; see §1 for the clause-by-clause
reasoning and the verification actually performed.

**Its MPL-2.0 terms continue to apply to it.** Linthra's relicensing does not
relicense `dbus`; the combination is distributed as a Larger Work, and `dbus`'s
own license and notices are preserved.

## 4. Dev / build-only dependencies (NOT shipped in the APK)

These run only during development, analysis, or code generation and are not part
of the released artifact, so they do not affect the APK's license. They are
listed for completeness.

| Package         | Constraint   | Publisher | License        | Purpose |
| --------------- | ------------ | --------- | -------------- | ------- |
| `flutter_lints` | `^5.0.0`     | flutter.dev | BSD-3-Clause | Lint rule set. |
| `flutter_test`  | (SDK)        | flutter.dev | BSD-3-Clause | Test framework. |
| `drift_dev`     | `^2.18.0`    | simonbinder.eu | MIT       | Drift code generation. |
| `build_runner`  | `^2.4.13`    | dart.dev  | BSD-3-Clause   | Runs the code generators. |
| `audio_service_platform_interface` | `^0.1.3` | ryanheise.com | MIT | Test-only: the Android media-session boundary test. Already in the graph under `audio_service`. |

## 5. Native / bundled components

F-Droid requires every shipped component to be free software and buildable from
source (no prebuilt proprietary blobs).

### 5.1 Linux / Flatpak native media stack

This is the part of the build most likely to carry copyleft, and it is the part
the earlier Flutter-only audit did not cover. Every component below is built
**from pinned upstream source** by
[`flatpak/io.github.thezupzup.linthra.yml`](../flatpak/io.github.thezupzup.linthra.yml)
(hash-pinned; the manifest is generated from
[`flatpak/flatpak-flutter.yml`](../flatpak/flatpak-flutter.yml)). No prebuilt
media binary is shipped.

| Component | Pinned version | License as built | Why it is AGPL-compatible |
| --- | --- | --- | --- |
| **FFmpeg** | `n9.0.1` | **LGPL-2.1-or-later** | Built with **neither `--enable-gpl` nor `--enable-nonfree`**, which is what keeps FFmpeg on its LGPL default. No GPL-only filters/codecs are enabled; Linthra is audio-only and every supported format decodes with a native FFmpeg decoder. LGPL-2.1-or-later → LGPLv3 → AGPLv3. |
| **mpv (libmpv)** | `v0.41.0` | **LGPL-2.1-or-later** | Built with **`-Dgpl=false`**. See the caveat below. |
| **libplacebo** | `v7.360.1` | **LGPL-2.1-or-later** | Hard mpv dependency (no feature toggle). Or-later, so the LGPLv3 upgrade path applies. |
| **libass** | `0.17.5` | **ISC** | Permissive. Hard mpv dependency. |
| **GnuTLS** | runtime-provided (`org.gnome.Sdk//50`, 3.8.x) | **LGPL-2.1-or-later** | TLS backend for FFmpeg's `https://`. Chosen over OpenSSL specifically to avoid OpenSSL's historical GPL-linking caveats. |
| **jinja / markupsafe** | `3.1.6` / `3.0.3` | **BSD-3-Clause** | libplacebo build-time shader-template generation. |
| **glad** | `v2.0.8` | **MIT** (generator; emits public-domain/MIT loader code) | libplacebo GL/Vulkan loader generation. |
| **SQLite amalgamation** | `3.52.0` | **Public domain** | Compiled from source via `sqlite3_flutter_libs`; hash-pinned by a committed patch. |
| **mimalloc** | `v2.1.2` | **MIT** | **Disabled in Linthra's build** — see below. |

**The `-Dgpl=false` caveat, checked rather than assumed.** mpv's own guidance is
that `-Dgpl=false` yields an LGPL-2.1-or-later libmpv *only if the GPL-only
components are actually excluded*; the switch alone is not a licensing
guarantee. Linthra's manifest disables exactly those components explicitly:

```
-Dcdda=disabled        -Ddvdnav=disabled      -Ddvbin=disabled
-Dlibbluray=disabled   -Dlibarchive=disabled  -Drubberband=disabled
-Dlua=disabled         -Djavascript=disabled  -Dvapoursynth=disabled
-Dcplugins=disabled    -Dcplayer=false        -Dlibmpv=true
```

`cdda` (libcdio), `dvdnav`, `dvbin` and `rubberband` are the GPL-encumbered
inputs; each is off. `-Dcplayer=false` also drops the mpv CLI player entirely,
so only the LGPL `libmpv` library is produced. Audio output is `-Dalsa=enabled`
/ `-Dpulse=enabled` (both LGPL-2.1-or-later), with `-Dpipewire=disabled` set
explicitly so a future SDK bump cannot silently add an undeclared backend.

**mimalloc is not linked.** `media_kit_libs_linux` would otherwise download and
statically link mimalloc during CMake configure.
[`linux/CMakeLists.txt`](../linux/CMakeLists.txt) sets
`MIMALLOC_USE_STATIC_LIBS OFF ... FORCE` before the generated plugin CMake is
included, so it is not built into Linthra. The pinned tarball still appears in
`flatpak/generated/sources/pubspec.json` only so the network-isolated Flatpak
build cannot attempt a fetch. It is MIT either way, so this is a build-hygiene
note, not a licensing one.

**Verdict:** the Linux/Flatpak media path is LGPL-2.1-or-later at its most
restrictive, with no `GPL-2.0-only`, no GPL-3.0-only, and no non-free component.
It is compatible with AGPL-3.0-or-later via the LGPL upgrade path (§1).

**Obligation that survives relicensing.** LGPL components stay LGPL. Because
they are built as **shared libraries** from unmodified, hash-pinned upstream
source and the corresponding sources are identified in the committed manifest,
the LGPL relinking obligation is satisfied by that manifest. Anyone
redistributing a modified media stack must continue to meet LGPL §6 themselves.

### 5.2 Rust core (`native/linthra_core`)

`native/linthra_core` declares `license = "AGPL-3.0-or-later"` and
`publish = false`. Its `Cargo.lock` resolves to **`linthra_core` and nothing
else** — it has **zero third-party crate dependencies**, so it introduces no
external license obligation at all. It is entirely first-party code, which is
why relicensing it is unambiguous.

### 5.3 Vendored third-party code (`third_party/`)

[`third_party/just_audio_media_kit`](../third_party/just_audio_media_kit) is a
vendored fork of the upstream package, carried with its upstream `LICENSE`
(**the Unlicense** — public domain), plus `PATCHES.md`, `upstream.patch` and
`upstream.sha256` recording provenance.

**This code is not relicensed and must not be relabelled.** Linthra's move to
AGPL-3.0-or-later covers Linthra's own work. Vendored third-party code keeps its
own upstream terms, and its license/provenance files are preserved byte-for-byte.
The same applies to every other third-party notice in the tree.

### 5.4 Android native components

- **SQLite** (via `sqlite3_flutter_libs`): the SQLite amalgamation is in the
  **public domain** and is compiled from source as part of the build — not a
  prebuilt closed binary. The Dart wrapper packages are MIT.
- **Android Keystore / EncryptedSharedPreferences** (used by
  `flutter_secure_storage`): part of the **AOSP** platform, not Google Play
  Services. No proprietary dependency is introduced.
- **AndroidX Media3 / ExoPlayer** (Maven AAR pulled by `just_audio`):
  `androidx.media3:media3-exoplayer:1.4.1` (+ the `-dash`, `-hls`,
  `-smoothstreaming` modules) is the playback engine for both local files and
  streaming. **Media3 is part of AndroidX/Jetpack and is licensed Apache-2.0 —
  open source and buildable from source. It is _not_ Google Play Services / the
  proprietary Cast SDK.** `audio_service` and `audio_session` likewise use only
  `androidx.media:media:1.7.0` and `androidx.core:core` (AndroidX, Apache-2.0).
  Media3's bundled manifest is the source of the merged `ACCESS_NETWORK_STATE`
  permission (it reads connectivity state for adaptive streaming); see the
  permissions table in [fdroid-readiness.md](./fdroid-readiness.md).
- **No Google Play Services / Firebase / GMS.** Confirmed by the transitive walk
  (§2): no `com.google.android.gms`, `play-services`, Firebase, or other
  proprietary Google library appears in the resolved dependency tree. The
  Android Auto declaration uses the standard `MediaBrowserService` /
  `media-session` APIs from `audio_service` (AOSP media APIs), not a proprietary
  car SDK — the `com.google.android.gms.car.application` manifest entry is just
  the meta-data key name Android Auto reads to list a media app; it links no GMS
  library.

### Casting (Chromecast) — real Cast without Google Play Services

Real Chromecast support is implemented **without** the official Google Cast
SDK, which is the important F-Droid distinction:

- **Why not the official SDK.** Google's Cast SDK for Android
  (`com.google.android.gms.cast.*`) is part of **Google Play Services** —
  proprietary and not buildable from source. Depending on it would introduce a
  GMS requirement and almost certainly warrant the `NonFreeDep` anti-feature, so
  it was **rejected**.
- **What is used instead.** The pure-Dart `cast` package speaks the Google Cast
  **v2 wire protocol** directly: mDNS discovery (via `bonsoir`), a TLS socket to
  the device, and `protobuf`-framed messages to the device's *Default Media
  Receiver*. No Google library is linked.
  - `cast` — **MIT**, pure Dart.
  - `bonsoir` (+ `bonsoir_android`, `bonsoir_platform_interface`, …) — **MIT**.
    The Android implementation uses **`android.net.nsd.NsdManager`**, an **AOSP**
    API, not GMS. Its `build.gradle` pulls in only Kotlin stdlib and test-only
    libraries (no `com.google.android.gms`/`play-services`). Pinned to `5.x`
    because `6.x`+ require Dart ≥3.8 while the project targets Dart 3.6.
  - `protobuf` — **BSD-3-Clause** (dart.dev), transitive via `cast`, used only to
    encode/decode cast-channel frames.
- **New permission.** `bonsoir` adds **`CHANGE_WIFI_MULTICAST_STATE`** (declared
  explicitly in `AndroidManifest.xml` for auditability). It is an **AOSP**
  permission allowing receipt of multicast Wi-Fi packets for mDNS discovery; it
  grants no internet or storage access. The cast session itself uses the
  existing `INTERNET` permission to reach the device on the LAN.
- **No secrets leave the device improperly.** A castable URL (which, for
  Jellyfin, embeds the access token in its query) is resolved **on demand at
  cast time**, handed straight to the cast session for the device to fetch, and
  **never persisted or logged** (`CastMedia.toString()` redacts the query, like
  `JellyfinSession`). On-device files have no reachable URL and are surfaced as a
  clear limitation rather than cast.
- **F-Droid verdict.** Casting introduces **no proprietary/GMS dependency and no
  anti-feature**, so it can ship in the F-Droid build. (As always, the mechanical
  transitive walk in §6 should confirm no GMS pull-in; the manual review of
  `bonsoir_android`'s `build.gradle` above already shows none.)

## 6. Anti-features / non-free check

Mapped to F-Droid's [anti-features](https://f-droid.org/docs/Anti-Features/):

| Concern                    | Status | Notes |
| -------------------------- | ------ | ----- |
| Ads                        | None   | No advertising libraries or code. |
| Tracking / analytics       | None   | No telemetry, analytics, or crash-reporting SDK is present. |
| Proprietary dependencies   | **None** (transitive walk confirmed) | All 160 resolved lockfile entries are free software (MIT/BSD-2/BSD-3/Apache-2.0/MPL-2.0/Unlicense); no GMS/Firebase/proprietary package present (§2). The Linux media chain is LGPL-2.1-or-later, built from pinned source (§5.1). Native AARs are AndroidX Media3/`media`/`core` (Apache-2.0) and SQLite (public domain) — all open source (§5). Chromecast deliberately avoids the GMS Cast SDK (pure-Dart `cast` + AOSP `NsdManager` via `bonsoir`); see §5 (Casting). |
| Non-free network services  | See §7 | Local-first core needs no network; the self-hosted Jellyfin/Navidrome/Subsonic sources are optional and user-configured. |

## 7. Network use & the optional self-hosted sources

Linthra is **local-first**: the core (folder selection, scanning, the persisted
catalog) works with **no network access at all**. Optional self-hosted sources —
**Jellyfin** and **Navidrome / Subsonic** — let the user stream from a server
they run themselves. These are the reason `http`, `crypto`, and
`flutter_secure_storage` are dependencies. The production
`AndroidManifest.xml` now declares the `INTERNET` permission (so release builds
can reach the user's server); this is a normal, expected permission for a
user-opted-in remote source and is not an anti-feature by itself. F-Droid
implications:

- **Optional and user-configured.** No server is bundled, promoted, or required;
  the user supplies their own server URL and credentials. The app does not
  depend on, default to, or promote any specific hosted service, and the
  local-first core remains fully functional with no network at all.
- **The servers are free software.** Jellyfin, Navidrome, and the Subsonic API
  ecosystem are themselves free/open-source. Linthra only speaks plain HTTP(S)
  to them via the permissive `http` package; the Subsonic/Navidrome
  `token = md5(password + salt)` scheme is computed locally with `crypto`.
- **Anti-feature judgement (`NonFreeNet`):** because every non-local source is
  optional, user-supplied, and points at free software the user hosts, it does
  **not** warrant the `NonFreeNet` anti-feature. This should still be **reviewed
  at submission time** — if any future source defaults to or promotes a non-free
  hosted service, it must be reassessed (the
  [readiness doc](./fdroid-readiness.md#5-anti-features-review) carries the same
  caveat).

### Reporting a bug (browser hand-off, no auto-send)

The in-app "Report a bug" flow (Settings → Report a bug) is the reason
`url_launcher` is a dependency. Its network/privacy posture:

- **Nothing is sent automatically.** The report is assembled **on device** from
  the existing secret-free diagnostics and a bounded in-memory ring of
  structural breadcrumbs. The user reviews it in a preview, then chooses to copy,
  save, or open a GitHub issue. There is **no backend**, no Linthra server, and
  **no upload to Claude/OpenAI/Anthropic or any third-party/AI service**.
- **"Open GitHub issue" is a browser hand-off.** It builds a
  `github.com/.../issues/new?...` URL with the report prefilled and opens it via
  `url_launcher` (AOSP `ACTION_VIEW`). The issue is **unsubmitted**: the user
  reviews and submits it themselves in their browser. **No GitHub token** is used
  and the app posts nothing on the user's behalf.
- **No new data collection.** The recent-events buffer holds only the same
  secret-free labels `StabilityDiagnostics` already emits (an output name, a
  lifecycle state, an error *kind*); it is memory-only, capped, never persisted,
  and surfaced solely when the user opts in while building a report.
- **Anti-feature judgement:** opening a user-chosen link in the browser is not an
  anti-feature and introduces no tracking. `url_launcher` is the official
  Flutter-team plugin and pulls in only its own federated platform packages — no
  GMS (to be confirmed by the mechanical transitive walk in §9).

## 8. Summary

- **Project license:** AGPL-3.0-or-later (free, F-Droid-accepted). Releases up
  to and including v0.2.4 remain MPL-2.0 (§1).
- **Direct dependencies:** MIT / BSD-3-Clause / Apache-2.0, plus one MPL-2.0
  (`dbus`, for MPRIS), all AGPL-compatible. No proprietary direct deps.
- **Transitive set:** the full committed lockfile (163 entries) was audited from
  each package's published archive (§2): 101 BSD-3-Clause, 43 MIT, 7
  Apache-2.0, 6 BSD-2-Clause, 1 MPL-2.0, plus 4 BSD-3-Clause SDK entries and 1
  Unlicense vendored package. **No GPL, no LGPL, no proprietary, no unknown.**
  The three most recent entries (`audio_metadata_reader` MIT, `charset`
  Apache-2.0, `intl` BSD-3-Clause) were read from their archives the same way
  when local metadata reading landed (§3).
- **The one MPL-2.0 package** (`dbus`, now direct for MPRIS and still reached
  transitively through `bonsoir_linux`) is not marked "Incompatible With
  Secondary Licenses", so MPL-2.0 §3.3 permits the AGPL combination (§1, §3).
- **Linux/Flatpak media stack:** FFmpeg `n9.0.1` (no `--enable-gpl`, no
  `--enable-nonfree`), mpv `v0.41.0` (`-Dgpl=false` **with** every GPL-only
  component explicitly disabled), libplacebo LGPL-2.1-or-later, libass ISC —
  LGPL-2.1-or-later at worst, AGPL-compatible via the LGPLv3 upgrade path (§5.1).
- **Rust core:** zero third-party crates (§5.2).
- **Vendored code:** `third_party/just_audio_media_kit` stays under the
  Unlicense and is **not** relicensed (§5.3).
- **Android native bits:** SQLite (public domain, built from source), AndroidX
  Media3 / `media` / `core` (Apache-2.0 — the playback engine, not GMS), and
  Android Keystore (AOSP). No Google Play Services / Firebase anywhere.
- **Bottom line:** no `GPL-2.0-only`, non-free, or unknown-license component was
  found in the declared build path, and nothing in the dependency set blocks
  either F-Droid or the move to AGPL-3.0-or-later.

## 9. Outstanding before submission

1. ~~**Run the mechanical transitive audit.**~~ **Done** (§2): 160 lockfile
   entries audited from their published archives; no GPL/LGPL/proprietary/unknown
   license in the Dart set.
2. ~~**Decide the `pubspec.lock` policy.**~~ **Done** — `pubspec.lock` is now
   committed, so the audited set is pinned at the tagged commit.
3. **Re-run this audit whenever a dependency is added or bumped**, and update the
   tables above. This includes the Flatpak media pins: a bump to FFmpeg or mpv
   must re-confirm that `--enable-gpl` / `--enable-nonfree` are still absent and
   that mpv's GPL-only components are still disabled (§5.1).
4. **Re-check the LGPL relinking posture** if the media stack ever moves from
   shared to static linking, which would change the obligations in §5.1.

## 10. Related docs

- [docs/fdroid-readiness.md](./fdroid-readiness.md) — overall F-Droid submission
  checklist and blockers.
- [docs/fdroid-build-recipe.md](./fdroid-build-recipe.md) — build recipe and
  reproducible-build notes.
- [docs/release-process.md](./release-process.md) — release/tagging and
  GitHub-Release process.
- [docs/release-signing.md](./release-signing.md) — how release builds are
  signed.
