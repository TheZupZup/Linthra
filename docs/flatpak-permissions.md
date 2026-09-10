# Flatpak permission audit

Issue: [#455](https://github.com/TheZupZup/Linthra/issues/455)
Parent: #376

Every permission Linthra's Flatpak asks for, the feature that needs it, and
what a reviewer should conclude if one of them ever changes.

This page is the source of truth: `scripts/check_flatpak_permissions.py` parses
the table below and requires it to match both manifests exactly. A permission
with no row here fails the check, and a row with no permission fails it too, so
this cannot drift into a page that used to be accurate.

## The result

Eight permissions. No filesystem access of any kind, no session-bus access, no
`--talk-name` to anything, and no host device beyond the GPU.

| Permission | Feature | Where it is used | Why nothing narrower works |
| --- | --- | --- | --- |
| `--socket=wayland` | The application window | `linux/runner/my_application.cc` | A GUI app needs a display server connection. Preferred over X11 wherever a compositor offers it. |
| `--socket=fallback-x11` | The window on X11 sessions | same | `fallback-x11` is the narrow form: it grants X11 **only** when no Wayland display is present, so a Wayland session never hands out an X socket. Plain `--socket=x11` would. |
| `--share=ipc` | Shared memory on X11 | same | X11 clients pass frames through SysV shared memory (MIT-SHM). Without it the X11 fallback path renders every frame over the socket. Grants no filesystem or network reach of its own. |
| `--device=dri` | GPU rendering | Flutter's GTK embedder | Flutter renders through OpenGL. Without the render node the sandbox falls back to software rasterisation, which on a music library's scrolling artwork grid is visible. `--device=dri` is the render-node-only grant; `--device=all` (which would add cameras, USB and input devices) is refused below. |
| `--socket=pulseaudio` | Audio output | `lib/core/services/linux_playback_controller.dart`, and the `mpv` module built with `-Dpulse=enabled` | libmpv needs a path to the audio server. This one socket covers PulseAudio and PipeWire alike, because every PipeWire desktop ships `pipewire-pulse`. There is no narrower audio grant in Flatpak. |
| `--share=network` | Self-hosted servers | `lib/core/sources/jellyfin/`, `lib/core/sources/subsonic/`, `lib/core/sources/plex/` | Jellyfin, Navidrome/Subsonic and Plex are HTTP(S) endpoints the user configures, on the LAN or beyond. Flatpak's network permission is all-or-nothing: there is no per-host form to ask for instead. |
| `--own-name=org.mpris.MediaPlayer2.linthra` | Media keys, and the player controls in a desktop shell | `lib/core/services/mpris/mpris_media_session.dart` | MPRIS is a well-known bus name a shell looks for. Flatpak lets an app own names under its own app id for free, and this is not one of those, so it has to be granted. **Owning is not talking**: it lets other clients call Linthra and gives Linthra no way to call anything. |
| `--own-name=org.mpris.MediaPlayer2.linthra.*` | A second window's media session | same | The MPRIS spec's `.instance<pid>` fallback, used when a second Linthra window finds the plain name taken. Scoped to Linthra's own names — an `org.mpris.MediaPlayer2.*` wildcard would reach every other player's session, and is refused below. |

## Features that work with no permission at all

These are the interesting ones. Each is a place where the obvious permission
was avoided.

| Feature | The permission it did not need | What it uses instead |
| --- | --- | --- |
| Local music libraries | `--filesystem=home`, `--filesystem=xdg-music`, `--filesystem=host` | `GtkFileChooserNative` (`linux/runner/folder_picker_channel.cc`), which GTK redirects to the xdg-desktop-portal FileChooser inside a sandbox. The user's choice becomes a document-portal grant for that folder alone. See [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md). |
| Server credentials | `--talk-name=org.freedesktop.secrets` | `flutter_secure_storage_linux` → libsecret. Inside a Flatpak with the Secret portal available, libsecret keeps its own encrypted file under the app's data directory, with the master secret handed over by the portal from the host keyring. Documented at `lib/data/repositories/secure_session_storage.dart`. |
| Desktop notifications | `--talk-name=org.freedesktop.Notifications` | The Notification portal, which every Flatpak may use without a finish-arg. |
| The app's own database, caches and downloads | `--persist=`, `--filesystem=~/.local/share/linthra` | The private XDG tree Flatpak gives every app under `~/.var/app/<app-id>/`, reached through `path_provider`. |
| Opening a link (bug report, docs) | `--talk-name=org.freedesktop.portal.OpenURI` | The OpenURI portal, again available without a grant. |

The pattern is the same each time: a portal turns a permission the app would
hold permanently into a grant the user makes once, for one thing.

## Permissions that are refused

`scripts/check_flatpak_permissions.py` rejects these outright, in both
manifests and in the installed package, even if somebody adds one to the
allow-list in `scripts/check_linux_runner.py`. Two independent checks have to
be edited to widen the sandbox, and each edit is a diff a reviewer reads.

| Refused | Why |
| --- | --- |
| `--filesystem=host`, `--filesystem=host-os`, `--filesystem=host-etc` | The whole host. Nothing Linthra does needs a file the user did not choose. |
| `--filesystem=home` | Every document, key and config file the user owns, to play music. |
| `--filesystem=xdg-music`, `--filesystem=xdg-download`, and any absolute path | Narrower, and still a standing grant the user never made. The portal grant is per-folder and revocable. |
| `--persist=` | Redirects a path into the app tree, which is a filesystem grant in a different spelling. |
| `--socket=session-bus`, `--socket=system-bus` | The entire bus. Every service on the session bus, including the keyring and every other app's private interfaces. |
| `--talk-name=…` (any) | Linthra calls no D-Bus service. It owns two names so shells can call *it*. If a future feature needs to call one, it needs its own issue and this table's fourth column. |
| `--own-name=org.mpris.MediaPlayer2.*` | Would let Linthra impersonate every other media player on the bus. |
| `--device=all`, `--device=shm` | Cameras, USB and input devices, for a music player. |
| `--socket=ssh-auth`, `--socket=gpg-agent`, `--socket=cups` | Agents and services with nothing to do with playback. |
| `--allow=devel` | Disables seccomp filtering (`ptrace`, `perf`). A debugging grant that has repeatedly shipped in other projects by accident. |
| `--allow=multiarch`, `--allow=bluetooth`, `--allow=canbus` | Nothing here uses any of them. |
| `--env=` | An environment variable baked into the package is a build-time workaround that outlives its reason. |

## How the current set was validated

"The permission is justified" and "the feature still works with only these
permissions" are different claims. This is the evidence for the second, and
what is still a person's job.

| Feature | Automated evidence | Still manual |
| --- | --- | --- |
| The app starts and is a real desktop window | `scripts/flatpak_launch_smoke.sh` — installs the package, waits for the window, and holds it to the app id and its icon | — |
| No host filesystem reach | `scripts/flatpak_filesystem_smoke.sh` — the installed package declares no filesystem or persist grant, no override adds one, an unrelated host file is invisible, and the private XDG tree is writable | — |
| Audio output | `scripts/flatpak_audio_smoke.sh` (#446) — the full transport lifecycle on the libmpv the manifest built | That a speaker actually makes a sound: no CI runner has an audio device |
| Local libraries | `scripts/flatpak_local_library_smoke.sh` (#447) — a user-selected folder scans, its tags and artwork load, a track plays, and unrelated host paths stay unreadable | The chooser dialog itself, which only a person can click |
| Self-hosted servers | — | Sign in to a Jellyfin/Navidrome/Plex server from the installed Flatpak and play a track. Needs a server and a credential, so it is not a CI job |
| Secure credentials | — | Sign in, quit, relaunch, and confirm the session survived — which is what proves libsecret's portal-backed store worked with no `--talk-name` |
| MPRIS | — | `playerctl status` and the media keys while the packaged app plays; a second window to exercise the `.instance` name |
| Notifications | — | Whatever surfaces a notification, once one does. Nothing in Linthra posts one on Linux today, which is why no permission is listed for it |

The two gaps that matter for [#456](https://github.com/TheZupZup/Linthra/issues/456)
are server playback and secure credentials: both are manual today, and neither
has been signed off against the current package.

## When to re-run this audit

Any change to `finish-args`, to the folder-selection path, to where caches or
downloads are written, or to how credentials are stored. The check keeps the
table and the manifests in step; it cannot tell you that a new feature quietly
started needing something.

## Related

- [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md) — the filesystem
  half in detail, and the manual portal pass
- [flathub-builder-lint.md](./flathub-builder-lint.md) — Flathub's own view of
  the same permissions
- `scripts/check_linux_runner.py` — the exact allow-list, checked against both
  manifests
