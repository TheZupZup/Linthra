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
`--talk-name` or `--see-name` to anything, and no host device beyond the GPU.
The widest of the eight is the audio socket, for a reason that is Flatpak's
rather than Linthra's, written out below the table.

| Permission | Feature | Where it is used | Why nothing narrower works |
| --- | --- | --- | --- |
| `--socket=wayland` | The application window | `linux/runner/my_application.cc` | A GUI app needs a display server connection. Preferred over X11 wherever a compositor offers it. |
| `--socket=fallback-x11` | The window on X11 sessions | same | `fallback-x11` is the narrow form: it grants X11 **only** when no Wayland display is present, so a Wayland session never hands out an X socket. Plain `--socket=x11` would. Note the installed package spells this as `x11` *and* `fallback-x11`; see below for why, and what it costs. |
| `--share=ipc` | Shared memory on X11 | same | X11 clients pass frames through SysV shared memory (MIT-SHM). Without it the X11 fallback path renders every frame over the socket. Grants no filesystem or network reach of its own. |
| `--device=dri` | GPU rendering | Flutter's GTK embedder | Flutter renders through OpenGL. Without the render node the sandbox falls back to software rasterisation, which on a music library's scrolling artwork grid is visible. `--device=dri` is the render-node-only grant; `--device=all` (which would add cameras, USB and input devices) is refused below. |
| `--socket=pulseaudio` | Audio output, and unavoidably audio **input** | `lib/core/services/linux_playback_controller.dart`, and the `mpv` module built with `-Dpulse=enabled` | libmpv needs a path to the audio server. This one socket covers PulseAudio and PipeWire alike, because every PipeWire desktop ships `pipewire-pulse`. There is no narrower audio grant in Flatpak, and no output-only form: see below. |
| `--share=network` | Self-hosted servers | `lib/core/sources/jellyfin/`, `lib/core/sources/subsonic/`, `lib/core/sources/plex/`, `lib/core/sources/audiobookshelf/` | Jellyfin, Navidrome/Subsonic, Plex and Audiobookshelf are HTTP(S) endpoints the user configures, on the LAN or beyond. Flatpak's network permission is all-or-nothing: there is no per-host form to ask for instead. |
| `--own-name=org.mpris.MediaPlayer2.linthra` | Media keys, and the player controls in a desktop shell | `lib/core/services/mpris/mpris_media_session.dart` | MPRIS is a well-known bus name a shell looks for. Flatpak lets an app own names under its own app id for free, and this is not one of those, so it has to be granted. **Owning is not talking**: it lets other clients call Linthra and gives Linthra no way to call anything. |
| `--own-name=org.mpris.MediaPlayer2.linthra.*` | A second window's media session | same | The MPRIS spec's `.instance<pid>` fallback, used when a second Linthra window finds the plain name taken. Scoped to Linthra's own names, since an `org.mpris.MediaPlayer2.*` wildcard would reach every other player's session, and is refused below. |

### The audio socket grants recording too

`--socket=pulseaudio` hands the sandbox the PulseAudio protocol, not an
output-only endpoint. A client with that socket can open a record stream on
any source the server offers, which means the microphone and the monitor
sources that capture whatever is currently playing. On a PipeWire desktop the
same is true through `pipewire-pulse`.

So the honest reading of this row is that Linthra's sandbox *could* record,
and a reviewer should be able to see that from this page rather than infer it
from a protocol.

What is true alongside it:

- **Nothing in Linthra opens a capture stream.** Playback goes through
  `just_audio` and `just_audio_media_kit` to libmpv; there is no recorder
  package in `pubspec.yaml` and no capture path in `lib/`.
- **There is no narrower grant to ask for.** Flatpak has no output-only audio
  socket, and no per-stream-direction form of this one. The alternative is no
  audio at all.
- **Nothing here mitigates it.** A permission is what the sandbox may do, not
  what the current code happens to do, and this row is the sandbox.

The reason it stays is that a music player without audio is not a music
player. The reason it is written down is that "Audio output" alone understated
it, and this page is supposed to be the thing a reviewer can trust.

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

"In the installed package" is the half that is easy to get wrong, because
`flatpak info --show-permissions` does not print finish-args: it prints
metadata sections that have to be turned back into them. A section the parser
skips is silently invisible, so a grant can be present in the artifact, absent
from the check, and reported as a clean pass.

Two of those were found by reading the code rather than by anything failing.
`--env=` is banned here and read literally from a manifest, but in the
installed metadata it appears under `[Environment]`, which the parser skipped
entirely. A bus policy has four values and three of them are grants; only
`own` and `talk` were mapped, so a package that could `see` a name on the bus
read back as one that could not.

The parser now fails closed. An unknown section, an unknown `[Context]` key
and an unknown bus policy value each stop the check with the thing they could
not read named in the error, instead of quietly answering a narrower question
than the one they were asked. The cost is that a newer flatpak printing
something new breaks this check until somebody teaches it, which is the right
way round. Every refused spelling has a test on both paths.

### The one grant the installed check cannot tell apart

`--socket=fallback-x11` sets the plain X11 bit as well as its own. flatpak's
own option handler does it (`common/flatpak-context.c`):

```c
if (socket == FLATPAK_CONTEXT_SOCKET_FALLBACK_X11)
  socket |= FLATPAK_CONTEXT_SOCKET_X11;
```

and `flatpak run` clears that bit again when a Wayland display is present,
which is what makes the grant a fallback. So Linthra's built package reads
`sockets=x11;wayland;fallback-x11;pulseaudio;` even though neither manifest
declares `--socket=x11`. The first CI run of `--installed` against a real
package reported it as a refused grant, and the package was right.

The two bits together are the only shape `--socket=fallback-x11` can produce,
so the checker reads them back as that one grant. `x11` on its own is
untouched and still refused.

What that costs: a package declaring **both** `--socket=x11` and
`--socket=fallback-x11` is indistinguishable from one declaring only the
fallback, because the metadata is the same two bits either way. This is the
one permission the installed check cannot verify on its own, and it is why the
manifest checks matter rather than being a weaker version of this one: they
read finish-args literally, and `check_flatpak_permissions.py` and
`check_linux_runner.py` both reject `--socket=x11` before anything is built.

| Refused | Why |
| --- | --- |
| `--filesystem=host`, `--filesystem=host-os`, `--filesystem=host-etc` | The whole host. Nothing Linthra does needs a file the user did not choose. |
| `--filesystem=home` | Every document, key and config file the user owns, to play music. |
| `--filesystem=xdg-music`, `--filesystem=xdg-download`, and any absolute path | Narrower, and still a standing grant the user never made. The portal grant is per-folder and revocable. |
| `--persist=` | Redirects a path into the app tree, which is a filesystem grant in a different spelling. |
| `--socket=session-bus`, `--socket=system-bus` | The entire bus. Every service on the session bus, including the keyring and every other app's private interfaces. |
| `--socket=x11` | Always hands out an X socket, including on a Wayland session where nothing needs one. X11 has no isolation between clients: any client can read every other window's contents and keystrokes. `--socket=fallback-x11` is the narrow form and is what is granted. |
| `--talk-name=…` (any) | Linthra calls no D-Bus service. It owns two names so shells can call *it*. If a future feature needs to call one, it needs its own issue and this table's fourth column. |
| `--system-talk-name=…`, `--system-own-name=…`, `--system-see-name=…` (any) | The system bus carries the machine's own services: disks, network, login sessions, firmware. A music player has no business on it in any direction. |
| `--see-name=…` (any) | Narrower than talking, and still bus reach Linthra has no use for. It is here mainly so the refusal is not silently spelling-dependent: `see` is a real `flatpak build-finish` option and one of the four bus policy values. |
| `--own-name=org.mpris.MediaPlayer2.*`, and any other own-name wildcard | Would let Linthra impersonate every other media player on the bus, and a broader prefix such as `org.mpris.*` or `org.gnome.*` reaches further still. The rule is inverted for this reason: a wildcard is refused unless it is exactly `org.mpris.MediaPlayer2.linthra.*`. |
| `--own-name=org.freedesktop.…` (any) | Names in the freedesktop namespace are the ones desktop components look up by convention, so owning one is a way to be mistaken for a system service. |
| `--device=all`, `--device=shm` | Cameras, USB and every other device node, for a music player. |
| `--device=input` | Raw evdev input devices, which is every keystroke on the machine and not only the ones aimed at Linthra. Media keys do not need it: they arrive over MPRIS, which is what the two `--own-name` grants are for. |
| `--socket=ssh-auth`, `--socket=gpg-agent`, `--socket=cups` | Agents and services with nothing to do with playback. |
| `--allow=devel` | Disables seccomp filtering (`ptrace`, `perf`). A debugging grant that has repeatedly shipped in other projects by accident. |
| `--allow=multiarch`, `--allow=bluetooth`, `--allow=canbus` | Nothing here uses any of them. |
| `--env=` | An environment variable baked into the package is a build-time workaround that outlives its reason. |

## How the current set was validated

"The permission is justified" and "the feature still works with only these
permissions" are different claims. This is the evidence for the second, and
what is still a person's job.

Everything in the "automated evidence" column runs in the `Flatpak build`
workflow against a package that workflow just built. The manifest half of this
check is cheaper and runs on every PR in the main CI workflow instead
(`Check every Flatpak permission has a written rationale`).

| Feature | Automated evidence | Still manual |
| --- | --- | --- |
| The app starts and is a real desktop window | `scripts/flatpak_launch_smoke.sh`, which installs the package, waits for the window, and holds it to the app id and its icon | none |
| No host filesystem reach | `scripts/flatpak_filesystem_smoke.sh`, where the installed package declares no filesystem or persist grant, no override adds one, an unrelated host file is invisible, and the private XDG tree is writable | none |
| The installed package carries exactly this table | the same script, which then runs `check_flatpak_permissions.py --installed` against the built package | none |
| Audio output | `scripts/flatpak_audio_smoke.sh` (#446), the full transport lifecycle on the libmpv the manifest built | That a speaker actually makes a sound: no CI runner has an audio device |
| Local libraries | `scripts/flatpak_local_library_smoke.sh` (#447), where a user-selected folder scans, its tags and artwork load, a track plays, and unrelated host paths stay unreadable | The chooser dialog itself, which only a person can click |
| Self-hosted servers | none | Sign in to a Jellyfin/Navidrome/Plex/Audiobookshelf server from the installed Flatpak and play a track. Needs a server and a credential, so it is not a CI job |
| Secure credentials | none | Sign in, quit, relaunch, and confirm the session survived, which is what proves libsecret's portal-backed store worked with no `--talk-name` |
| MPRIS | none | `playerctl status` and the media keys while the packaged app plays; a second window to exercise the `.instance` name |
| Notifications | none | Whatever surfaces a notification, once one does. Nothing in Linthra posts one on Linux today, which is why no permission is listed for it |

The two gaps that matter for [#456](https://github.com/TheZupZup/Linthra/issues/456)
are server playback and secure credentials: both are manual today, and neither
has been signed off against the current package.

## When to re-run this audit

Any change to `finish-args`, to the folder-selection path, to where caches or
downloads are written, or to how credentials are stored. The check keeps the
table and the manifests in step; it cannot tell you that a new feature quietly
started needing something.

## Related

- [flatpak-filesystem-audit.md](./flatpak-filesystem-audit.md), the filesystem
  half in detail, and the manual portal pass
- [flathub-builder-lint.md](./flathub-builder-lint.md), Flathub's own view of
  the same permissions
- `scripts/check_linux_runner.py`, the exact allow-list, checked against both
  manifests
