# Flatpak (local build — issues #432, #433, #434)

This is the packaging **foundation**: enough to build Linthra's native Flutter
Linux bundle inside `flatpak-builder`, install it, launch the real
`io.github.thezupzup.linthra` app from the application menu, and get real,
audible local and remote playback through a fully self-contained audio
runtime, with Linthra's own icon on the launcher entry and AppStream metainfo
for a software-centre listing, and let the user point Linthra at a music
folder through the desktop portal without granting any host filesystem
access, and keep provider credentials in platform secure storage through the
desktop's Secret portal. It is deliberately not the Flathub submission:
some sandbox permissions are still deferred; see "What's deferred" below and
the comments in `io.github.thezupzup.linthra.yml` itself.

## Audio runtime

The Flatpak bundles its own `libmpv`, built from source together with its
`ffmpeg`/`libplacebo`/`libass` dependencies (see the `modules:` comments in
`flatpak-flutter.yml`) and installed under `/app/lib`. **Host `mpv-libs` /
`libmpv` is never used and is not required to install or run the Flatpak** —
`media_kit`/`just_audio_media_kit` dlopen the bundled copy, which resolves
before anything under `/usr/lib*` or `/lib*` because the Flatpak sandbox
exposes no host library path. Playback uses `--socket=pulseaudio` for audio
output, which reaches both a native PulseAudio session and PipeWire's
`pipewire-pulse` compatibility server (there is no separate PipeWire
finish-arg). The bundled ffmpeg is also built with `--enable-network
--enable-gnutls`, so the same libmpv decodes local files and plays HTTP(S)
audio streams (Jellyfin, Navidrome/Subsonic, Plex) without any host codec or
TLS library — see the `ffmpeg` module comments for exactly which formats that
covers and why no additional codec library was needed.

**Native, non-Flatpak Linthra is unaffected**: `flutter build linux` outside
this packaging still links nothing at build time and still expects the
system `mpv-libs`/`libmpv` runtime documented in
[docs/linux-desktop.md](../docs/linux-desktop.md#required-packages). The two
are independent audio runtimes by design; only the Flatpak is self-contained.

## Desktop entry

`../linux/packaging/io.github.thezupzup.linthra.desktop` is what puts Linthra
in the application menu. The `linthra` module installs it verbatim:

```
install -Dm644 linux/packaging/io.github.thezupzup.linthra.desktop \
  /app/share/applications/io.github.thezupzup.linthra.desktop
```

`/app/share/applications` is the only directory flatpak-builder exports from at
`finish` time, and it only exports files whose name starts with the app id —
this one *is* the app id, so there is no `rename-desktop-file` in the manifest.
Export
rewrites `Exec=linthra` into the host-side `flatpak run …` form, so the entry
carries the bare command and no absolute path; the same file works unchanged
for a native package that puts `linthra` on `PATH`.

Two things keep it honest, both offline and both already in CI
(`.github/workflows/linux-desktop-build.yml`):

```bash
desktop-file-validate linux/packaging/io.github.thezupzup.linthra.desktop
python3 scripts/check_linux_runner.py
```

The first is syntax — note that `desktop-file-validate` exits 0 even for
warnings and "will be fatal in the future" errors, so CI and
`scripts/verify_linux.sh` treat *any* output from it as a failure rather than
trusting its exit status. The second is identity: `scripts/check_linux_runner.py`
checks the entry's filename, `Name`, `Exec`, `Icon` and `Categories` against
the same sources of truth the Linux runner is held to (`AppInfo.name`,
`pubspec.yaml`'s `name`, Android's `applicationId`), and checks that **both**
this directory's manifests — the hand-authored template and the generated
manifest — actually install it, so a regeneration that was never run shows up
as a failure rather than as a Flatpak with no menu entry.

## Application icon

`Icon=io.github.thezupzup.linthra` in that entry is an icon-theme **name**, not
a path. It resolves because the `linthra` module installs a file of exactly that
name into the icon theme:

```
install -Dm644 tool/branding/linthra_icon.svg \
  /app/share/icons/hicolor/scalable/apps/io.github.thezupzup.linthra.svg
install -Dm644 linux/packaging/icons/hicolor/48x48/apps/io.github.thezupzup.linthra.png \
  /app/share/icons/hicolor/48x48/apps/io.github.thezupzup.linthra.png
# ... and the same for 64, 128 and 256.
```

Three decisions worth stating:

* **The source is Linthra's canonical vector mark, installed as-is.**
  `tool/branding/linthra_icon.svg` is the design
  `tool/branding/generate_icons.py` rasterises into the Android launcher
  mipmaps and the store graphics — same squircle, same four bars, same
  violet→orange gradient. Nothing here redraws or re-exports it, so there is no
  packaging-only copy that can drift from the brand, exactly as with the
  desktop entry above. Android's icon pipeline is untouched by this.
* **A scalable SVG for launchers, PNGs for the window icon.** `hicolor` is the
  theme every icon theme inherits from, `scalable/apps` is where an
  application's own resolution-independent icon belongs, and a vector is sharp
  at every launcher size and HiDPI scale by construction. The window icon is a
  different story: GTK builds X11's `_NET_WM_ICON` by asking gdk-pixbuf to
  decode whatever the icon theme hands it, and gdk-pixbuf has no SVG loader —
  librsvg's pixbuf module is obsolete and glycin, its replacement, is not wired
  into GTK 3's icon-theme path in `org.gnome.Platform`. With only the SVG
  installed the lookup produced nothing, GTK set no icon list, and the packaged
  window carried no `_NET_WM_ICON` for panels and task switchers to read (caught
  by `scripts/flatpak_launch_smoke.sh`). The PNGs in
  `linux/packaging/icons/hicolor/` fix that: `generate_icons.py` rasterises them
  from the same source design, gdk-pixbuf's built-in PNG loader always decodes
  them, and GTK prefers an exact fixed-size match over a scalable one, so
  launcher rendering is unchanged.
* **No `rename-icon`.** flatpak-builder exports `/app/share/icons/hicolor/**`
  by the same rule it exports desktop files — the basename must start with the
  app id — and this basename *is* the app id.

`scripts/check_linux_runner.py` covers this too, offline and with no extra
packages to install: it holds the installed basename to the entry's `Icon=`,
requires **both** manifests to install it, and checks the SVG itself — that it
is well-formed, that it carries a `viewBox` (a file in `scalable/` that cannot
scale is resampled by every launcher), and that it has no absolute host path
and no reference to anything it does not carry (an external image, stylesheet
or font would render differently, or not at all, inside the sandbox).

## AppStream metainfo

`../linux/packaging/io.github.thezupzup.linthra.metainfo.xml` is the software-
centre listing (#435). The `linthra` module installs it:

```
install -Dm644 linux/packaging/io.github.thezupzup.linthra.metainfo.xml \
  /app/share/metainfo/io.github.thezupzup.linthra.metainfo.xml
```

`/app/share/metainfo` is exported the same way as the desktop entry — the
filename is the app id, so there is no `rename-appdata-file`. `<launchable
type="desktop-id">` and `<icon type="stock">` point at the desktop entry and
icon already installed under that id. Screenshots are omitted until there are
Linux captures; Android shots would misrepresent the desktop window.

The description covers local playback. The sandbox also permits normal network
connections for user-configured Jellyfin, Navidrome/Subsonic, and Plex servers.

## Files here

| File | What it is |
| --- | --- |
| `flatpak-flutter.yml` | Hand-authored input. Never built directly. |
| `../linux/packaging/io.github.thezupzup.linthra.desktop` | Hand-authored, and not Flatpak-only: the installed desktop entry (#434), which this manifest copies into `/app/share/applications/` for flatpak-builder to export. It lives beside the rest of the Linux packaging inputs rather than here so a future native package installs the same file. |
| `../linux/packaging/io.github.thezupzup.linthra.metainfo.xml` | Hand-authored AppStream listing (#435). Installed to `/app/share/metainfo/` so software centres can describe Linthra. Lives next to the desktop entry for the same reason. |
| `io.github.thezupzup.linthra.yml` | **Generated.** The real manifest `flatpak-builder` consumes. Do not hand-edit — regenerate instead (below). |
| `generated/sources/pubspec.json` | **Generated.** One pinned, hashed source per package in the committed `pubspec.lock` (plus Flutter's own internal `flutter_tools` package), so `flutter pub get --offline` inside the sandbox never touches pub.dev. Also carries two known per-plugin fixes from flatpak-flutter's own `foreign-deps` database: `sqlite3_flutter_libs` and `media_kit_libs_linux`'s own CMake `FetchContent` downloads (sqlite amalgamation, mimalloc) are pre-placed at the exact cache paths CMake checks before downloading, so they're satisfied without a network hit even though `linux/CMakeLists.txt` already disables/redirects both independently. |
| `generated/modules/flutter-sdk-3.44.7.json` | **Generated.** Pins the Dart SDK and Linux engine artifacts for the exact `.flutter-version` tag by their real `storage.googleapis.com` URLs and sha256, plus a small patch so Flutter's own internal tool bootstrap runs `pub upgrade --offline`. |
| `generated/patches/` | **Generated.** The two patches referenced above. |

## Building, installing, running

The full contributor workflow — host tools, build, install, run, rebuild,
clean/uninstall and debugging, written for Fedora Atomic (Kinoite/Silverblue)
and usable anywhere else — is
[docs/flatpak-development.md](../docs/flatpak-development.md). Turning a tagged
release into a published Flatpak is a different walk, in
[docs/flathub-update-process.md](../docs/flathub-update-process.md). The short
version, run from this directory:

```bash
flatpak run org.flatpak.Builder --user --force-clean --repo=repo \
  flatpak-builder-build io.github.thezupzup.linthra.yml

flatpak --user remote-add --if-not-exists --no-gpg-verify linthra-dev repo
flatpak --user install -y linthra-dev io.github.thezupzup.linthra

flatpak run io.github.thezupzup.linthra
```

On a distribution with a native `flatpak-builder`, drop the
`flatpak run org.flatpak.Builder` prefix and run plain `flatpak-builder ...`.
To uninstall: `flatpak --user uninstall io.github.thezupzup.linthra` and
`flatpak --user remote-delete linthra-dev`.

A stable release turns that same exported repository into the single
`Linthra-<tag>-x86_64.flatpak` file attached to the GitHub Release (#618) — one
manifest, one package, two ways of installing it. The commands are in
[docs/flatpak-ci.md](../docs/flatpak-ci.md#reproduce-the-build-locally) and the
release path is
[docs/release-process.md §4b](../docs/release-process.md#4b-linux-flatpak-bundle-dispatched-alongside-the-android-and-linux-builds).

Nothing above needs network access during the actual sandboxed build —
`flatpak-builder`'s normal declared-source fetch (`generated/sources/pubspec.json`,
the Flutter SDK module, the ffmpeg/libplacebo/libass/mpv archives) happens
before the sandbox is entered, exactly like any other Flatpak module.

## Network access and endpoint validation

The committed manifest grants exactly `--share=network` for networking. Flatpak
otherwise gives an application no network namespace access, so this is the
minimum capability that lets Linthra's existing HTTP clients connect to a
user-configured Jellyfin, Navidrome/Subsonic, or Plex server. It covers ordinary
IPv4/IPv6 sockets: direct LAN addresses, DNS hostnames, HTTPS, and remote or
tunnel endpoints all behave as normal network destinations.

This grant does **not** expose arbitrary host files and adds no D-Bus access.
There is still no `--filesystem=host`, `--filesystem=home`, or D-Bus
permission of any kind: credential storage needs none either, see
[Secure credential storage](#secure-credential-storage). It also does not add
mDNS, SSDP, or broadcast discovery behavior: issue #440 covers endpoints the
user configured directly; provider discovery remains separate.

After building and installing the Flatpak, validate a LAN endpoint by entering
its direct address (for example `http://192.168.1.20:8096`) in the matching
provider's connection screen, signing in, syncing, and playing a track. Repeat
with a hostname if the server has one. Validate a remote endpoint by entering a
real `https://` hostname (including a tunnel URL if that is how the server is
normally exposed), then sign in, sync, and play a track. Do not disable TLS or
certificate verification: use the same valid endpoint that native Linthra uses.

Verify recoverable failure behavior without changing the manifest:

1. While connected, note that the provider is available and its tracks play.
2. Stop the test server, disconnect the network, or run a one-shot denial with
   `flatpak run --unshare=network io.github.thezupzup.linthra`.
3. Retry the provider operation. Linthra should report its existing configured
   but unreachable/offline provider state; the app must remain usable and any
   cached track must remain playable.
4. Restore the server/network, launch normally, and retry. The provider should
   become available again through the existing reachability recovery path.

Inspect the installed package rather than relying on the source file:

```bash
flatpak info --show-permissions io.github.thezupzup.linthra
flatpak override --user --show io.github.thezupzup.linthra
```

The first command prints the installed metadata: `shared=network;ipc;`
(alongside the existing windowing, GPU, and audio grants), no `filesystems=`
line at all, and no `[Session Bus Policy]` section. The second reveals
persistent local overrides that could invalidate the test.

## Secure credential storage

Provider credentials (#441) go to platform secure storage, and the sandbox
needs **no finish-args at all** for it: the path in is a portal, exactly as it
is for local music folders.

### Why no permission

`flutter_secure_storage`'s Linux implementation
(`flutter_secure_storage_linux` 1.2.3) has no store of its own: it calls
libsecret's `secret_password_storev_sync` / `secret_password_lookupv_sync` and
nothing else. libsecret chooses its own backend at runtime
(`secret-backend.c`, `backend_get_impl_type`):

* If `/.flatpak-info` exists **and** xdg-desktop-portal answers
  `org.freedesktop.portal.Secret` version 1, libsecret uses its **file
  backend**: a gcrypt-encrypted store under the app's own data directory whose
  master secret is handed over by the portal, which gets it from the host's
  keyring. Every Flatpak may talk to the portal, so nothing grants this.
* Otherwise it falls back to the **Secret Service backend** and connects to the
  session-bus name `org.freedesktop.secrets`, which the sandbox's D-Bus proxy
  hides unless a manifest grants it.

The portal is exported only when the desktop ships a backend implementing
`org.freedesktop.impl.portal.Secret` (xdg-desktop-portal's
`desktop-portal/secret.c`, `init_secret`: with no impl configured the
interface is never exported). Both desktops this package targets ship one:

| Desktop | Secret portal backend |
| --- | --- |
| GNOME | gnome-keyring (`daemon/dbus/gkd-secret-portal.c`) |
| KDE Plasma 6 | KWallet's `ksecretd` (`src/runtime/ksecretd/kwalletportalsecrets.cpp`), which installs `org.freedesktop.impl.portal.desktop.kwallet.service` and `kwallet.portal` |

KDE's backend is KF6-only; the KF5 `kwalletd` had none, which is where the
older "Flatpak apps can't use KWallet" reports come from. And
`org.gnome.Platform//50` carries libsecret 0.21.7 built with libgcrypt
(freedesktop-sdk 25.08 `elements/components/libsecret.bst`), so the file
backend is compiled in and the sandbox detection above is live.

So `--talk-name=org.freedesktop.secrets` is **not** granted. It would be dead
weight on both supported desktops, and `scripts/check_linux_runner.py` now
rejects it, along with `--socket=session-bus`, any `org.freedesktop.*` or
`…secrets.*` wildcard, `--own-name`, and the system-bus forms. The manifest
has no D-Bus permission of any kind, and no filesystem grant either.

**On a host with no Secret portal backend** (a KF5-era KDE, a bare window
manager running only a Secret Service daemon), libsecret falls back to the bus
name, the proxy hides it, and Linthra reports a recoverable storage error and
stays signed out. It never falls back to storage of its own. A user who wants
that fallback can grant it for their own install, which is their decision
rather than a permission on every install:

```bash
flatpak override --user --talk-name=org.freedesktop.secrets \
  io.github.thezupzup.linthra
```

### What is stored, and where

One entry per provider, each the JSON of a session object, written by the three
secure stores in `../lib/data/repositories/` through the single
`SecureSessionStorage` wrapper:

| Key | Provider | Contents |
| --- | --- | --- |
| `jellyfin_session_v1` | Jellyfin | server URL, user id/name, access token, device id |
| `subsonic_session_v1` | Navidrome/Subsonic | server URL, username, salt, derived token |
| `plex_session_v1` | Plex | server URL, machine identifier, token, selected library keys |

Passwords are never stored: Jellyfin exchanges one for an access token,
Subsonic derives a salt+token pair and discards it, Plex is token-based from
the start. Everything else (library rows, preferences, playback state) stays in
SQLite and preferences and holds no secret.

Where the bytes land depends on which libsecret backend is in use, and both are
encrypted at rest:

* **Portal file backend** (the path inside this Flatpak on GNOME and Plasma 6):
  libsecret's own gcrypt-encrypted
  `~/.var/app/io.github.thezupzup.linthra/data/keyrings/default.keyring`,
  unlockable only with the master secret the Secret portal hands over from the
  host keyring. It is ciphertext written and read by libsecret; Linthra never
  opens it.
* **Secret Service backend** (native Linthra, and a sandbox with the name
  granted by user override): items in the desktop keyring itself, labelled
  `io.github.thezupzup.linthra/FlutterSecureStorage` with the attribute
  `account=io.github.thezupzup.linthra.secureStorage`.

### What "no plaintext fallback" means precisely

* **Linthra** has no plaintext or custom file fallback. It writes credentials
  through `SecureSessionStorage` and nowhere else.
* Secrets never go to `shared_preferences`, SQLite, the app cache, a log, a
  diagnostics report, an exception, or any file Linthra writes.
* **libsecret** may legitimately use its own encrypted, portal-keyed file
  backend. That is the platform's storage, not a Linthra fallback, and it is
  ciphertext, not plaintext.
* When neither libsecret backend can store the value, the write fails and
  nothing is written anywhere.

`SecureSessionStorage` is the single wrapper the Jellyfin, Navidrome/Subsonic
and Plex session stores use. (The GitHub Sponsors token store calls
`flutter_secure_storage` directly; it holds no provider credential and is
outside #441.) It has no alternative path: a failed write stores nothing, and a
failed read is an error rather than a silent "no session" that would look like
a clean sign-out. Failures become a typed `SecureStorageException` carrying
only an operation and a cause (unavailable, locked, denied, unknown), never the
platform error text, the key, or the value, so a storage problem cannot leak a
token into a log or a crash report. Jellyfin, Navidrome/Subsonic and Plex each
turn that into a visible, recoverable message ("Couldn't save your … sign-in on
this device. Unlock your keyring and try again."), and a session that could not
be saved is not adopted, because it would look signed in until the next launch
and then be gone.

`test/data/repositories/secure_session_storage_test.dart` drives the real
plugin channel (`plugins.it_nomads.com/flutter_secure_storage`) with the exact
`PlatformException`s the Linux plugin raises, and covers save, read after a
restart, delete, the missing/locked/denied service, and the absence of any
fallback write.

### Testing it in the sandbox

Save, read after restart, delete:

1. Build, install and launch (above). Sign in to Jellyfin, Navidrome/Subsonic
   and Plex.
2. Confirm which backend is in play, since that decides where to look. On a
   GNOME or Plasma 6 host with the Secret portal, expect the encrypted file:

   ```bash
   ls -l ~/.var/app/io.github.thezupzup.linthra/data/keyrings/
   ```

   `secret-tool search account io.github.thezupzup.linthra.secureStorage` will
   find nothing there, which is correct: the item is in that file, not in the
   host keyring's own collection. On a host using the Secret Service backend
   the reverse holds, and the item shows in Seahorse or KWalletManager. Do not
   print the secret: `secret-tool search` shows attributes, which is what you
   are checking, while `secret-tool lookup` would print the value.
3. Quit and relaunch: `flatpak run io.github.thezupzup.linthra`. All three
   providers come back signed in, without re-entering anything, and a track
   streams.
4. Sign out of each provider. The card returns to the signed-out state and the
   entry is gone (the keyring file no longer holds it; on the Secret Service
   path it disappears from Seahorse/KWalletManager).
5. Check nothing readable was written. The keyring file is ciphertext, so a
   grep for the token must not match it or anything else:

   ```bash
   grep -rIl "your-test-token" ~/.var/app/io.github.thezupzup.linthra/ || \
     echo "no readable credential anywhere in app data"
   ```

Locked or unavailable secure storage:

1. **Locked.** Lock the host keyring, then launch and sign in. On
   gnome-keyring that is `secret-tool lock --collection=default` (libsecret
   0.20.5+; `--collection` wants a full D-Bus path or the literal `default`
   alias, not a wallet name, and a bare `secret-tool lock` locks every
   collection), or right-click the login keyring in Seahorse and choose
   *Lock*. On KDE, close the wallet in KWalletManager. The portal's
   `RetrieveSecret` cannot complete against a locked keyring, so expect a
   visible "Couldn't save your … sign-in on this device. Unlock your keyring
   and try again.", the app still usable, and no crash. Unlock, retry, and the
   sign-in completes.
2. **Unavailable.** Use a session with neither a Secret portal backend nor a
   reachable Secret Service (a bare window manager with no keyring daemon is
   the easy case). Saved sessions report a restore error, signing in reports
   the storage failure, nothing is written anywhere else, and local music keeps
   working. Returning to a normal session recovers with credentials intact.
3. There is no `--no-talk-name` test any more, because nothing is granted to
   withhold. To exercise the Secret Service fallback deliberately, add the
   override above on a portal-less host and confirm sign-in then succeeds.

## Regenerating the pinned sources

Re-run this whenever `.flutter-version` or `pubspec.lock` changes:

```bash
./scripts/regenerate_flatpak_sources.sh
```

It fetches [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter)
(the tool referenced by Flutter's own deployment docs and by
`flatpak/flatpak-builder-tools`) into `.tool/` if needed — pinned to an exact
commit SHA in `scripts/regenerate_flatpak_sources.sh` (`TOOL_COMMIT`, the
`0.15.0` release), never a moving branch — and re-generates
`io.github.thezupzup.linthra.yml` and `generated/` from `flatpak-flutter.yml`
and the current `pubspec.lock`. Diff the result before committing.

## Local music folders

Choosing a music folder (#438) needs **no** `finish-args` entry, and adding
`--filesystem=host` or `--filesystem=home` would be the wrong fix for it.

Linthra's Linux runner opens the folder chooser with GTK's
`GtkFileChooserNative` (`../linux/runner/folder_picker_channel.cc`). GTK checks
for `/.flatpak-info` itself and, inside a sandbox, routes that chooser to the
**xdg-desktop-portal** `FileChooser` interface instead of drawing it in
process. Every Flatpak may talk to the portal, so nothing has to be granted:

* the chooser runs on the *host*, so it can browse the user's real home
  directory while the sandbox still cannot;
* only the folder the user actually picked comes back, exported through the
  **document portal** (mounted for every Flatpak at `$XDG_RUNTIME_DIR/doc`) as
  a path under Linthra's own document store;
* that path is a real directory the `dart:io` scan walks unchanged, so the
  scanner needs no Flatpak-specific branch and no hardcoded sandbox path;
* the export persists, so the folder is still readable after a restart, and
  revoking it (or unplugging the drive) makes the path stop resolving rather
  than silently returning nothing — Linthra reports that as "select the folder
  again" and leaves the indexed library alone.

What the Flatpak deliberately does **not** get is everything else: unrelated
host files stay invisible, which is the whole point of picking this route over
a filesystem grant.

`file_picker`, which the app uses on other desktops, cannot do this — its Linux
implementation shells out to `zenity`/`qarma`/`kdialog`, and the sandbox
contains none of them. It stays as the fallback for a build with no runner
channel; native (non-Flatpak) Linux gets the ordinary in-process GTK dialog
from the same code path.

`scripts/check_linux_runner.py` holds the runner's channel name to the Dart
side's, so the two cannot drift into a silent fallback.

## What's deferred

Not in this manifest — each has its own issue:

* **The remaining filesystem-permission audit** (#439): still no
  `--filesystem=host|home`. Picking a music folder does not need a filesystem
  grant at all (see [Local music folders](#local-music-folders)), and neither
  does credential storage (see
  [Secure credential storage](#secure-credential-storage)).
* **Video codecs, hardware acceleration/hwaccel, subtitle-adjacent tuning
  beyond what libmpv/libass require to build** — Linthra is audio-only; the
  ffmpeg/mpv build stays scoped to the container/codec/protocol support
  Linthra's supported formats and HTTP(S) streaming actually need.
* **CI** (#444), **automated launch/audio smoke tests** (#445/#446), **local-
  library sandbox test** (#447) — out of scope here; this file is the minimal
  "how do I build and validate this locally" note #432/#433 asked for, and
  [docs/flatpak-development.md](../docs/flatpak-development.md) is the
  contributor workflow around it.
