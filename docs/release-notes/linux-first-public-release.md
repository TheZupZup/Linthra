# Linthra on Linux: first public release

Notes for Linthra's first public Linux build, distributed as a Flatpak
(issue [#454](https://github.com/TheZupZup/Linthra/issues/454)).

The rule for this page is that a feature is listed as working only if it has
been **run on Linux**, in the packaged Flatpak, and something checks it on
every build. Passing unit tests are not the same thing, and neither is "the
Android app does this". Everything else is either under Known limitations or
absent.

## What Linthra does on Linux

**Plays music from folders you choose.** You pick a folder, Linthra indexes it
and plays from it. Titles, artists, albums and track numbers come from the
files' own tags rather than from filenames, embedded cover art is extracted and
cached, and files it cannot decode are skipped and counted rather than silently
dropped.

**Plays through your normal audio output.** Playback runs on libmpv built into
the Flatpak, not on whatever the host happens to have installed. Play, pause,
seek, stop and track changes all work, and the output device can be chosen
under **Settings > Music & playback > Audio output**.

**Stays out of the rest of your filesystem.** See the sandbox section below.
This is the part most worth reading.

**No account, no ads, no tracking, no telemetry.** Linthra has no backend.

### What is checked, and how

Both of these run on every build, inside an actually-installed Flatpak, not
against a development checkout:

| Area | Check |
| --- | --- |
| Playback | The whole transport is exercised on the packaged libmpv, asserting on the playback clock rather than on a status flag, three times per run. [Details](../flatpak-audio-smoke.md) |
| Local library | A chosen folder is scanned, its tags and embedded artwork are read, a track is played from it, unrelated host paths are confirmed unreachable, and losing access is confirmed recoverable. [Details](../flatpak-local-library-smoke.md) |

## What the sandbox means for you

Linthra's Flatpak declares **no filesystem permission at all**. Not
`--filesystem=home`, not `--filesystem=host`, nothing. That is unusual for a
music player and it is deliberate.

The practical consequences:

- **You choose the folders.** Linthra can read a music folder because you
  picked it in the system file chooser, and it gets that folder and nothing
  else. Your documents, your keys, the rest of your home directory: not
  reachable, and that is verified on every build rather than asserted here.
- **Moving or unplugging a folder is not data loss.** If a folder becomes
  unreachable, whether a drive was unplugged, the folder was deleted, or the
  permission was withdrawn, Linthra reports it as a recoverable error and
  **keeps** the tracks it had already indexed. It will not decide your library
  is empty and overwrite it. Re-select the folder to recover.
- **Flatpak permissions can be inspected and revoked.** `flatpak info
  --show-permissions io.github.thezupzup.linthra` lists exactly what the
  package asks for. Folder grants you made through the file chooser can be
  reviewed with `flatpak documents` and revoked with `flatpak document-unexport`.
- **Self-hosted servers need network access**, which the package does declare.
  It is a general network permission, since a self-hosted server can be at any
  address on your LAN or beyond; it is not scoped to particular hosts.

## Known limitations

Listed rather than hidden, which is the point of this page.

**Self-hosted servers are not validated on Linux.** Linthra supports Jellyfin,
Navidrome/Subsonic and Plex, and the Flatpak carries the network permission
they need. But nobody has yet signed in to a real server from the installed
Flatpak and played a track through it. It may well work. It has not been shown
to, so this release does not claim it, and the software-centre listing does not
mention it. If you try it, a report either way is genuinely useful.

**Sound reaching a speaker is not covered by automated checks.** Build machines
have no audio device, so the automated playback checks use an output that
discards the samples while still keeping real time. Decoding, timing, seeking
and the transport are all real; the last hop to your hardware is checked by
hand, not on every build.

**The file chooser dialog itself is not covered by automated checks.** What is
checked is everything after you click: the scan, the metadata, the artwork, the
playback, and the isolation. The click needs a person.

**Stored credentials surviving a restart is not yet validated in the Flatpak.**
Linthra uses the desktop secret portal rather than asking for broad access to
your keyring. That is the right design, and it has not been through a
sign-in-quit-relaunch pass in the packaged app.

**Desktop media controls (MPRIS) are not yet validated in the Flatpak.** They
work in the native Linux build and the package declares the names they need,
but media keys and `playerctl` against the installed Flatpak have not been
confirmed.

**Automatic folder watching and incremental rescans are not yet validated in
the Flatpak.** Linthra watches the folders you selected and refreshes when they
change, and a rescan only re-reads files that actually changed. Both have unit
tests, and neither is exercised inside the packaged Flatpak on every build: the
local-library check above scans, reads and plays, but never changes a file
underneath a running app. A sandbox is exactly where filesystem watching can
behave differently, so treat a manual rescan as the reliable path for now. See
[local-music.md](../local-music.md) for what is and is not watched.

**Nothing posts a desktop notification yet**, which is why the package asks for
no notification permission.

**Android-only features are not present**: Chromecast, Android Auto, the system
share sheet, launcher-icon switching.

## Reporting a Linux bug

Use the GitHub issue tracker:
<https://github.com/TheZupZup/Linthra/issues>.

Linthra can build the report for you, and it is worth using rather than writing
one from scratch. **Settings → Report a bug** assembles a Markdown report on
your device, shows you a live preview of exactly what will be copied, and
copies it only when you choose to. Nothing is uploaded anywhere, there is no
backend and no token involved. See [reporting-bugs.md](../reporting-bugs.md).

Useful things to include for a Linux problem:

- your distribution and desktop (GNOME, KDE, something else), and whether you
  are on Wayland or X11
- the Flatpak version: `flatpak info io.github.thezupzup.linthra`
- whether the music is local or from a server, and which server software
- for playback problems, the output device you selected

**Please do not paste** server URLs or hostnames, usernames, passwords, API
keys or tokens, or full paths that contain your username. None of them help
diagnose a bug, and an issue is public and permanent. The built-in reporter is
designed to leave them out; if you are writing by hand, replace them with
placeholders.

## See also

- [local-music.md](../local-music.md), how local libraries work
- [flatpak-filesystem-audit.md](../flatpak-filesystem-audit.md), the sandbox filesystem policy
- [linux-desktop.md](../linux-desktop.md), the Linux build itself
- [flatpak-development.md](../flatpak-development.md), building the Flatpak locally
