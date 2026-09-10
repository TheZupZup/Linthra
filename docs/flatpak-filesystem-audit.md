# Flatpak filesystem sandbox audit

Issue: #439  
Parent: #376

This document records the filesystem surface Linthra's Flatpak is allowed to
use, why each path is reachable, and how to prove that unrelated host files
remain outside the sandbox.

## Result

The shipped Flatpak needs **no `--filesystem=` finish argument and no
`--persist=` grant**.

The authoritative manifest (`flatpak/flatpak-flutter.yml`) and the generated
manifest (`flatpak/io.github.thezupzup.linthra.yml`) intentionally contain none.
`scripts/check_linux_runner.py` already compares both manifests against an exact
finish-args allow-list, so adding `--filesystem=host`, `--filesystem=home`, an
XDG filesystem grant, `--persist`, or any other new finish arg fails the Linux
runner check until it is explicitly reviewed.

The approved sandbox surface remains:

```text
--socket=wayland
--socket=fallback-x11
--share=ipc
--device=dri
--socket=pulseaudio
--share=network
--own-name=org.mpris.MediaPlayer2.linthra
--own-name=org.mpris.MediaPlayer2.linthra.*
```

None of those grants host filesystem access.

The two `--own-name` entries arrived with the MPRIS media session (#397) and are
the only D-Bus grants. They let Linthra own its own player names so desktop
shells can find it; they are not `--talk-name`, so they give Linthra no way to
call any other service, and they are scoped to Linthra's own names, so no other
player's MPRIS interface becomes reachable. `--socket=session-bus` and an
`org.mpris.MediaPlayer2.*` wildcard are both still rejected by the allow-list.

## Why local music still works

The Linux runner uses `GtkFileChooserNative`. Inside Flatpak, GTK routes that
chooser through `xdg-desktop-portal`.

When the user chooses a music directory, the document portal exposes only that
selection to the application. Linthra stores and reuses the portal-visible path;
it does not need `--filesystem=home` or `--filesystem=host` to scan it.

This is a user-mediated grant: choosing `/home/alice/Music` does not make
`/home/alice/Documents`, `/etc`, another mounted disk, or the rest of `$HOME`
readable to Linthra.

If the portal grant later disappears, the local-source availability path added
with #438 reports the folder as unavailable instead of treating an unreadable
folder as an empty library and deleting unrelated catalog state.

## App-owned data and cache

Flatpak gives every application private writable XDG locations under
`~/.var/app/<app-id>/`. Linthra uses platform/XDG APIs for app-owned state, so
these paths need no host-filesystem permission.

| Data | Linthra code | API | Flatpak behavior |
| --- | --- | --- | --- |
| SQLite catalog (`linthra.sqlite`) | `lib/data/database/linthra_database.dart` | `getApplicationDocumentsDirectory()` | resolves inside the app's private sandbox data tree |
| Remote provider cache (`remote_cache/`) | `lib/data/repositories/file_remote_cache_store.dart` | `getApplicationSupportDirectory()` | private app support directory |
| Artwork cache (`artwork_cache/`) | `lib/core/services/artwork_disk_cache.dart` | `getApplicationSupportDirectory()` | private app support directory |
| Offline audio (`offline_audio/`) | `lib/data/repositories/file_system_offline_file_store.dart` | `getApplicationSupportDirectory()` | private app support directory |
| Provider credentials | `SecureSessionStorage` / libsecret | Secret portal | encrypted platform storage; no filesystem finish arg |
| Preferences | Flutter plugin/XDG | application-scoped platform path | private app configuration/data |

The application never needs to write its database, artwork cache, remote cache,
offline audio, or credentials into a user's arbitrary host directory.

A user uninstall with `--delete-data` may remove the app-owned tree, which is
expected. It must never remove the user's portal-selected music folder itself.

## Deliberately forbidden workarounds

Do not solve a filesystem problem by adding any of these to the manifest:

```text
--filesystem=host
--filesystem=home
--filesystem=host-os
--filesystem=host-etc
--filesystem=xdg-download
--filesystem=xdg-music
--filesystem=/some/absolute/path
--persist=...
```

If a feature needs a user-selected host file or directory, prefer the relevant
portal. If a future feature genuinely cannot use a portal, it needs a separate
issue and security review instead of silently widening #439's policy.

## Clean sandbox smoke test

After building and installing the Flatpak, run:

```bash
bash scripts/flatpak_filesystem_smoke.sh
```

The smoke test does four things without modifying persistent Flatpak overrides:

1. inspects the **installed** package and fails if it exposes a filesystem or
   persist permission;
2. refuses to run if **any global or app-specific override, in either user or
   system scope**, grants filesystem/persist access, because an effective
   override would make the package-level result meaningless;
3. creates a temporary sentinel in the real host home and proves a shell inside
   Linthra's sandbox cannot see or read it;
4. proves the sandbox's own XDG data/cache directories remain writable, which
   is what Linthra's database/cache/offline stores rely on.

The script removes its host and sandbox probes before exiting.

### User-selected library check

Most of this is now automated. `scripts/flatpak_local_library_smoke.sh` (#447)
grants the installed sandbox one disposable music folder for the length of one
run and proves the whole flow below it: the folder scans, its tags and embedded
artwork load, a track plays, a sentinel file and a sibling directory beside that
folder stay unreadable, the library survives a relaunch, and taking the grant
away produces the recoverable `folderUnavailable` state from #438 with the
previously indexed tracks kept. See
[flatpak-local-library-smoke.md](./flatpak-local-library-smoke.md).

What it cannot do is press the button. A FileChooser portal grant is minted only
by the user's chooser action, and no headless runner can perform it, nor does a
`--filesystem=` run grant exercise the document portal's `/run/user/<uid>/doc/`
path rewriting. So complete the audit with this manual pass using the installed
Flatpak:

1. Create a small test directory outside `~/.var/app/`, containing one supported
   audio file. Also create a neighbouring file **outside** that directory.
2. Launch `flatpak run io.github.thezupzup.linthra`.
3. In Local music, choose only the test music directory through Linthra's
   system folder chooser.
4. Scan it. The selected track must appear and be playable.
5. Quit and relaunch. The selected library must remain usable while the portal
   grant persists.
6. Run `bash scripts/flatpak_filesystem_smoke.sh` again. The unrelated host
   sentinel must still be invisible.
7. Revoke/remove the selected directory's portal access or make the directory
   unavailable, then rescan. Linthra must surface the recoverable unavailable
   source state from #438 rather than wiping unrelated tracks.

Do not use `flatpak override --filesystem=...` during this test. An override
would test the override, not the package Linthra intends to ship.

## Inspecting the final package manually

These commands are useful before a release or Flathub submission:

```bash
flatpak info --show-permissions io.github.thezupzup.linthra
flatpak override --user --show
flatpak override --user --show io.github.thezupzup.linthra
flatpak override --system --show
flatpak override --system --show io.github.thezupzup.linthra
```

Expected package/test result:

- `shared=network;ipc;`
- Wayland/fallback-X11, DRI and PulseAudio sockets/devices as documented by the
  manifest
- **no `filesystems=` entry** in package metadata
- no filesystem/persist grant in any global/app-specific user/system override
  used for the validation run

The filesystem audit should be repeated after any future change to Flatpak
finish-args, local folder selection, cache/offline storage, or downloads.
