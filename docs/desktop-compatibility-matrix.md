# GNOME and KDE Plasma compatibility matrix

A repeatable pass that says whether Linthra behaves the same on the two Linux
desktops most of its users are on ([issue #458](https://github.com/TheZupZup/Linthra/issues/458)).

Linux support is easy to tune to whichever desktop the person writing it
happens to run. Everything still builds, every test still passes, and the other
desktop is the one that breaks after release. This page is the antidote: one
list of checks, run on both desktops, with the answers written down.

**Scope.** Wayland is the primary session on both desktops and is what a pass
means. X11 is checked second, and only the rows where the display server
genuinely changes something are re-run. This is compatibility validation, not a
desktop redesign: a check that fails is a bug to file, not a reason to add a
branch on which desktop is running.

**Not in scope.** Distributions. Nothing in Linthra keys off a distribution and
nothing here asks which one you are on; the [required
packages](./linux-desktop.md#required-packages) differ by package manager and
that is all. Run the matrix on whatever you already have.

## Contents

* [Before you start](#before-you-start)
* [Session facts to record first](#session-facts-to-record-first)
* [The checks](#the-checks)
  * [A. Launch and window](#a-launch-and-window)
  * [B. Appearance](#b-appearance)
  * [C. Files and local library](#c-files-and-local-library)
  * [D. Desktop integration](#d-desktop-integration)
  * [E. Audio](#e-audio)
  * [F. Credentials and providers](#f-credentials-and-providers)
  * [G. Packaging](#g-packaging)
* [Result sheet](#result-sheet)
* [Differences Linthra does not normalize](#differences-linthra-does-not-normalize)
* [What CI already answers](#what-ci-already-answers)
* [Why there are no desktop checks in the code](#why-there-are-no-desktop-checks-in-the-code)
* [When a check fails](#when-a-check-fails)

## Before you start

You need a GNOME session and a KDE Plasma session. Two machines, two user
accounts, or a VM each; a login-screen session switch on one machine is fine
and is the cheapest way to do it.

Use throwaway data. A few local music files you own, and a test server account
if you are running the provider rows. **Never point a compatibility pass at
production or private server credentials**: the pass includes deleting and
re-entering sign-ins.

Two builds behave differently enough to matter, so say which one you ran:

| Build | Get it | Reaches the desktop through |
| --- | --- | --- |
| **Native** | `flutter build linux --release`, or the [release tarball](./linux-desktop.md#release-tarball) | GTK directly, the session bus directly, the Secret Service directly |
| **Flatpak** | the [`.flatpak` bundle](./linux-desktop.md#installing-from-github-releases-flatpak), or a local build | xdg-desktop-portal for files and notifications, the Secret portal for credentials, two `--own-name` grants for MPRIS |

A full pass is both builds on both desktops under Wayland. A minimum pass,
before a Linux milestone release, is the Flatpak on both desktops under
Wayland, plus the X11 rows.

**The native build installs nothing.** `flutter build linux` and the release
tarball both produce a bundle you run in place, so a clean machine has no
desktop entry and no icons, and A1, A2 and D9 would fail for that reason alone
rather than for anything about Linthra.

The metadata lives in the repository, not in the tarball, which packages only
the build output. So this step needs a **source checkout at the version you are
testing**; with the tarball alone there is nothing to install, and the honest
options are to clone the repository at that tag, or to mark A1, A2 and D9 `n/a`
for the native pass and let the Flatpak, whose exports do get installed, cover
them. From a checkout:

```bash
install -Dm644 linux/packaging/io.github.thezupzup.linthra.desktop \
  ~/.local/share/applications/io.github.thezupzup.linthra.desktop
for size in 48 64 128 256; do
  install -Dm644 "linux/packaging/icons/hicolor/${size}x${size}/apps/io.github.thezupzup.linthra.png" \
    ~/.local/share/icons/hicolor/${size}x${size}/apps/io.github.thezupzup.linthra.png
done
install -Dm644 tool/branding/linthra_icon.svg \
  ~/.local/share/icons/hicolor/scalable/apps/io.github.thezupzup.linthra.svg
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor
```

The entry's `Exec=linthra` is a bare command resolved from `PATH`, which the
bundle's binary is not on, so link it somewhere that is:

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/build/linux/x64/release/bundle/linthra" ~/.local/bin/linthra   # or the tarball's
```

Confirm with `command -v linthra` before running A1, since a launcher entry
that cannot start anything fails the row for the wrong reason. Uninstall by
deleting the files installed above and that symlink.

## Session facts to record first

These four lines go at the top of every result, because half of a "works for
me" disagreement turns out to be one of them:

```bash
echo "$XDG_SESSION_TYPE"                 # wayland or x11
busctl --user list | grep -i portal      # which portal backend is running
busctl --user list | grep -i secrets     # which Secret Service holds the name (F1 tests whether it works)
pactl info | head -n 3                   # the audio server answering, if pactl exists
```

Read them, do not act on them. Linthra itself never reads any of this, and the
[neutrality guardrails](#why-there-are-no-desktop-checks-in-the-code) exist to
keep it that way.

## The checks

Each row is one check, what to do, and what a pass looks like. The
[result sheet](#result-sheet) below is the copy-paste grid to fill in.

### A. Launch and window

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| A1 | **Application launch** | Open the desktop's application launcher, search for Linthra, launch it. | The entry is there, named **Linthra**, with Linthra's icon and not a generic one. It reaches a usable first frame: the library shell, or the onboarding prompt on an empty catalog. |
| A2 | **Window identity** | While it runs, look at the task switcher, the window list and the dock or task manager. | One entry, grouped with the launcher entry it was started from, carrying the same name and icon. Not a second, unnamed or generically iconned entry beside it. |
| A3 | **Window title** | Read the window's caption wherever the desktop shows one: task switcher, window list, a task manager tooltip. On X11 you can also run `xprop WM_NAME` and click the window. | The caption is **Linthra**, never blank. This is the one the header bar does not supply: see [the window title](#the-window-title-was-missing-under-a-header-bar) below. |
| A4 | **Initial window size** | Delete the saved geometry and launch. Native: `rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/io.github.thezupzup.linthra/window-state"`, since the runner builds that path with `g_get_user_config_dir()` and a session that sets `XDG_CONFIG_HOME` keeps it elsewhere. Flatpak: `rm -f ~/.var/app/io.github.thezupzup.linthra/config/io.github.thezupzup.linthra/window-state`. The application id appears twice on purpose: `g_get_user_config_dir()` already resolves to the sandbox's `config/`, and `StateFilePath()` appends the id again, so `config/window-state` is not the file and deleting it leaves the saved geometry in place. | The window opens at its 1180x780 default, fully on screen and within the work area, with the desktop's panels not covering its controls. On a display shorter than that the compositor constrains it, and the layout still works at the size that results. |
| A5 | **Minimum sizing** | Drag the window as small as it will go, in both directions. | It stops at 420x600 and the layout at that size is still usable: the navigation is reachable, nothing is clipped, no overflow warnings. |
| A6 | **Maximize / restore** | Maximize with the title bar control, with a double-click on the title bar, and with the desktop's keyboard shortcut. Restore each way. | Maximizes to the work area (not over the panels), restores to the size it had before, and the content re-lays-out both ways without a visible stall. |
| A7 | **Tile / snap** | Drag the window to a screen edge, or use the desktop's tiling shortcut, then restore. | It tiles to half the work area, stays usable at that width, and restores to its previous size. Which gestures exist is the desktop's business; behaving at whatever size results is Linthra's. |
| A8 | **Geometry survives a restart** | Resize to something distinctive, quit, relaunch. Repeat maximized. | The size comes back. Maximized comes back maximized, and un-maximizing lands back on the earlier size. Position comes back on X11 only, [by design](./linux-desktop.md#window-state). |
| A9 | **Shutdown and relaunch** | Quit from the window control, relaunch from the launcher. Then quit while a track is paused and relaunch. | Clean exit with no leftover process (`pgrep -a linthra` is empty). The relaunch is an ordinary cold start and the crash-safe session restores the paused track. |
| A10 | **Second launch reaches the first window** | With Linthra running, click the launcher entry again. | The existing window is presented. No second process, no second entry in the media controls. If the compositor's focus-stealing prevention marks it as needing attention instead of raising it, that is [a compositor difference](#differences-linthra-does-not-normalize), not a failure. |
| A11 | **Title bar owner (X11 only)** | Look at who painted the title bar: Linthra's own header bar has the window controls inside the application's own bar, a window-manager title bar is drawn in the desktop's own style above it. Compare the two X11 sessions. | A header bar under GNOME Shell, the window manager's own title bar elsewhere. This is the one place the [grandfathered desktop-name check](#why-there-are-no-desktop-checks-in-the-code) is observable, so it is the row that notices if that condition is ever inverted. Nothing else changes with it: title, identity, icon and geometry are the same either way, which is why no other row would catch it. Under Wayland there is only the client-side option, so this row is `n/a` there. |

### B. Appearance

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| B1 | **System appearance, dark** | Set the desktop to its dark appearance. In Linthra, Settings ▸ Appearance ▸ Theme = **System**. | Linthra is dark. |
| B2 | **System appearance, light** | Switch the desktop to light with Linthra still running. | Linthra follows, live, without a restart. |
| B3 | **Explicit Light / Dark** | Set Theme to Light, then Dark, with the desktop set to the opposite each time. | Linthra honours its own setting and ignores the desktop's. |
| B4 | **Appearance survives a restart** | Quit and relaunch on each of the three settings. | The setting is remembered, and System re-reads the desktop's current preference at launch. |
| B5 | **Contrast and palette** | Walk Library, an album, an artist, Now Playing and Settings in both appearances. | Nothing unreadable, no dark-on-dark or light-on-light text, no control that disappears. |

The system preference itself arrives through Flutter's GTK embedder, which
reads the `org.freedesktop.appearance` `color-scheme` setting from the desktop
portal and falls back to GNOME's GSettings schema where there is no portal.
Linthra has no Linux-specific theme code at all (`test/app/theme_mode_test.dart`
holds that), so B1 and B2 are the rows that exercise the native bridge Linthra
does not own. A desktop that publishes no preference at all is worth writing
down in the result rather than treating as a failure: there is nothing for
Linthra to follow, and where the preference comes from is the embedder's half
of this.

### C. Files and local library

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| C1 | **Folder portal opens** | Settings ▸ Local music ▸ Add folder. | A folder chooser appears. In the Flatpak it is the desktop's own portal chooser, drawn by the desktop and not by Linthra. It is modal to Linthra's window and parented to it. |
| C2 | **Local music folder selection** | Pick a folder with a few albums in it. | The scan runs, tracks appear with real tags (title, artist, album, track number, duration) rather than filenames, and the count matches the folder. |
| C3 | **Cancel is not a failure** | Open the chooser and cancel it. | Nothing changes, no error, no half-added folder. |
| C4 | **A second folder** | Add another folder, including one nested inside the first. | Both are listed, the nested one is walked once rather than twice, and the library is the union. |
| C5 | **Removing a folder** | Remove one folder. | Only its tracks go. The other folder's tracks stay, and the files on disk are untouched. |
| C6 | **An unreachable folder** | Point a folder at a removable drive and unplug it, or `chmod 000` a test folder. | The folder's row says *which* problem it has and offers Retry, Select folder again and Remove folder. The indexed catalog is kept rather than replaced with an empty scan. See [when a music folder can't be read](./linux-desktop.md#when-a-music-folder-cant-be-read). |
| C7 | **Selection survives a restart** | Quit and relaunch. | The folders are still selected and the library is still there, with no second full scan of unchanged files. |

### D. Desktop integration

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| D1 | **MPRIS appears** | Start a track. Open the desktop's media controls (the panel widget, lock screen, or notification area). | Linthra is listed, named **Linthra**, with its icon and the current track's title, artist and album, plus the cover when the track has one. |
| D2 | **MPRIS transport** | Drive play, pause, next and previous from the desktop widget. | Each one takes effect in the app immediately, and the widget's own state follows. |
| D3 | **MPRIS position** | Let a track play and watch the widget's progress. Seek in the app. | The position advances and follows a seek, rather than sitting at zero. |
| D4 | **MPRIS volume** | Move the volume slider in the desktop's media widget, if it has one. Then mute in Linthra. | Linthra's level follows the widget, and the widget reads zero while Linthra is muted. |
| D5 | **MPRIS raise and quit** | With background mode on (Settings ▸ Music & playback ▸ Desktop window) and the window closed while playing, use the widget's raise and quit affordances. Whether a shell draws those is its own choice, so when it does not, call the methods directly instead: `busctl --user call org.mpris.MediaPlayer2.linthra /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2 Raise`, and the same with `Quit`. | Raise brings the same window back, or, where the compositor's focus-stealing prevention intervenes, marks it as wanting attention (see [the differences table](#differences-linthra-does-not-normalize)). Quit stops playback, releases the bus name, and the entry disappears from the widget. A shell with no such buttons is not a failure of this row; a method that does nothing when called directly is. |
| D6 | **Media keys** | Press play/pause, next and previous on a keyboard or headset that has them, with Linthra unfocused. | They reach Linthra. Both desktops route media keys to the active MPRIS player, so this is the same interface D2 uses and needs no key binding inside Linthra. |
| D7 | **Media keys with another player running** | Start any other MPRIS player, then repeat D6. | Whichever player the desktop considers active gets the key. Linthra does not grab keys globally and must not steal them. |
| D8 | **Notifications** | Turn on Settings ▸ Music & playback ▸ Desktop notifications, then play through a few tracks. | One notification per track change, showing the title and the "Artist • Album" subtitle, plus the cover when there is one. Each replaces the last rather than stacking. |
| D9 | **Notification identity** | Look at the notification's own icon and app name. | Linthra's icon and name, resolved from the installed desktop entry, not a generic bell. |
| D10 | **Notifications off** | Turn the setting off and change tracks. | Nothing appears. |
| D11 | **Do not disturb** | Turn the desktop's do-not-disturb on and change tracks. | The desktop suppresses or queues the notification, and Linthra keeps playing normally either way. Linthra sends these at low priority precisely so this happens. |
| D12 | **MPRIS is released at exit** | Quit Linthra and re-check the media widget. Optionally `busctl --user list \| grep mpris`. | The entry disappears and `org.mpris.MediaPlayer2.linthra` is no longer on the bus. No ghost player. |

### E. Audio

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| E1 | **Basic playback** | Play a local track. Pause, resume, seek, skip forward and back, let one track end into the next. | Audio comes out, every transport control works, and the next track starts on its own without a stall at the end of the last one. |
| E2 | **Audio output device list** | Settings ▸ Music & playback ▸ Audio output. | The list covers the sinks the desktop's own volume control shows, and offers the system default alongside them. |
| E3 | **Routing to a chosen device** | Pick a non-default sink and play. | Sound comes from that device, and the desktop's volume control shows Linthra on it. |
| E4 | **A chosen device survives a restart** | Quit and relaunch with a non-default device selected. | The device is re-applied. If it is gone, playback falls back to the system default and says so rather than failing silently. |
| E5 | **Hotplug** | While playing, plug in or remove a headset, a Bluetooth sink or an HDMI display. | Playback recovers without restarting the track and without a second player. A chosen device that comes back takes playback back. See [device hotplug](./linux-desktop.md#device-hotplug). |
| E6 | **Per-app volume** | Move Linthra's own slider in the desktop's volume control. | It moves Linthra alone, and Linthra keeps playing. The desktop identifies the stream as Linthra rather than as a generic media stream. |
| E7 | **Suspend and resume** | Suspend the machine while playing, then wake it. | The [suspend / resume matrix](./linux-desktop.md#suspend--resume-manual-matrix) is the detailed version of this row; the short answer is the same track and queue, audio back within a few seconds, and never a second stream. |
| E8 | **Playback diagnostics** | Settings ▸ Diagnostics & support ▸ Linux playback. | A report that names the backend, libmpv and the output subsystem actually in use, and contains no path, URL, token or device name. |

### F. Credentials and providers

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| F1 | **Secure storage is usable** | Listing the bus name proves only that a process holds it, not that its collection is unlocked or that a write would succeed, so do a real round trip. Native, if `secret-tool` is installed: `secret-tool store --label='Linthra matrix probe' linthra-matrix probe` (type any value), then `secret-tool lookup linthra-matrix probe`, then `secret-tool clear linthra-matrix probe`. Flatpak: there is no host-side probe of the Secret portal, so this row is `n/a` there and F2 and F5 carry the verdict instead. | The value written comes back and then deletes cleanly, unlocking the keyring on the way if the desktop asks. Which daemon supplies it is the desktop's business, and Linthra never asks which. If `secret-tool` is missing, mark this `n/a` too rather than substituting a bus listing: a provider sign-in that survives a restart (F2 plus F5) is the honest test either way. |
| F2 | **Jellyfin configuration** | Settings ▸ Jellyfin: enter a server URL and sign in. | It connects, the library appears, and the sign-in is saved. |
| F3 | **Navidrome / Subsonic configuration** | The same, against a Navidrome or other Subsonic-compatible server. | The same. |
| F4 | **Plex configuration** | The same, against Plex. | The same. |
| F4b | **Audiobookshelf configuration** | The same, against an Audiobookshelf server, including picking a library. | The same. It has its own settings section and its own secure session store, so it is a fourth credential path rather than a variation on one already covered, and F5 to F9 below mean it too. |
| F5 | **Credentials survive a restart** | Quit and relaunch after each sign-in. | Still signed in, with no second password prompt. |
| F6 | **Credentials are really encrypted** (native) | Open the desktop's own credential manager and look for Linthra's entries. | One entry per configured provider, and no password among them: Jellyfin stores an access token, Subsonic a salt and token pair, Plex a token. |
| F6b | **Credentials are really encrypted** (Flatpak) | The sandbox reaches secure storage through the Secret portal, and libsecret keeps its own encrypted store rather than per-provider entries in the shared keyring, so there is nothing for a credential manager to list. Check what can be observed instead: an encrypted keyring file exists under `~/.var/app/io.github.thezupzup.linthra/data/keyrings/`, and `grep -ri` across `~/.var/app/io.github.thezupzup.linthra/` for the **secret** values only, the access token and the password you signed in with, finds nothing. | The keyring file is there, the grep is empty, and F5 and F8 behave: the sign-in survives a restart, and signing out stops it surviving. That triple is what shows the session is stored, stored encrypted, and stored there. Grep for the token, not for the server's hostname or your username: those are ordinary catalog data, and the indexed library legitimately holds the base URL inside track artwork URIs, so a hostname hit is expected and proves nothing either way. |
| F7 | **A locked keyring is reported, not swallowed** | Order matters, because F2 to F5 leave every provider connected and a connected provider shows its status rather than a sign-in form. **Sign out of one provider first**, then lock the keyring (or stop the provider), then try to sign in to that one. Do not lock first and try to sign out: a sign-out whose secure-storage delete fails deliberately keeps the session rather than pretending it went, so that is a different row's behaviour and leaves you still connected. | A recoverable message asking you to unlock and retry. The app stays usable, and the session that could not be saved is not adopted. Unlock and retry the same sign-in to confirm it then completes. |
| F8 | **Sign out** | Sign out of each provider. | The stored entry goes with it, and the library falls back to what is left. |
| F9 | **Server playback** | Play a track from each configured server. | Audio comes out, transport works, and the desktop's media controls show the server's metadata and cover. |

### G. Packaging

| # | Check | Do this | Pass |
| --- | --- | --- | --- |
| G1 | **Flatpak install** | `flatpak install --user <bundle>`, or through the desktop's software centre. | It installs, and the software centre shows the AppStream name, summary and icon. |
| G2 | **Flatpak launch** | Launch it from the application launcher, not from a terminal. | Same as A1 and A2, from the sandbox. |
| G3 | **Flatpak portals** | Repeat C1, C2 and D8 inside the Flatpak, and for credentials use F2 plus F5 rather than F1: F1 is a `secret-tool` round trip against the host's Secret Service, which the sandbox does not use and which is marked `n/a` there. F6b is the storage-side half. | The chooser is the portal's, notifications arrive, and a provider sign-in persists across a restart with no extra D-Bus permission. This is the row the [permission audit](./flatpak-permissions.md) is really about. |
| G4 | **Flatpak audio** | Repeat E1 and E2 inside the Flatpak. | Audio from the packaged libmpv, and the sink list matches the host's. |
| G5 | **Flatpak uninstall** | `flatpak uninstall --user io.github.thezupzup.linthra`. | It goes cleanly, and the music files you added are still on disk untouched. |

The shorter release-time version of G is the
[manual Flatpak smoke checklist](./linux-desktop.md#manual-flatpak-smoke-checklist);
this section is that checklist run on both desktops.

## Result sheet

Copy this into the issue or PR you are recording the pass in. Fill in `✓`,
`✗` or `n/a`, and put a note under it for every `✗`.

```
Linthra <version> | build: native / flatpak | date:
GNOME <version>   | session: wayland / x11
KDE Plasma <ver>  | session: wayland / x11

                              GNOME      KDE Plasma
                              way   x11  way   x11
A1  application launch         .     .    .     .
A2  window identity            .     .    .     .
A3  window title               .     .    .     .
A4  initial window size        .     .    .     .
A5  minimum sizing             .     .    .     .
A6  maximize / restore         .     .    .     .
A7  tile / snap                .     .    .     .
A8  geometry across restart    .     .    .     .
A9  shutdown and relaunch      .     .    .     .
A10 second launch              .     .    .     .
A11 title bar owner (X11)      n/a   .    n/a   .
B1  system dark                .     .    .     .
B2  system light, live         .     .    .     .
B3  explicit light / dark      .     .    .     .
B4  appearance across restart  .     .    .     .
B5  contrast and palette       .     .    .     .
C1  folder portal opens        .     .    .     .
C2  music folder selection     .     .    .     .
C3  cancel is not a failure    .     .    .     .
C4  a second folder            .     .    .     .
C5  removing a folder          .     .    .     .
C6  an unreachable folder      .     .    .     .
C7  selection across restart   .     .    .     .
D1  MPRIS appears              .     .    .     .
D2  MPRIS transport            .     .    .     .
D3  MPRIS position             .     .    .     .
D4  MPRIS volume               .     .    .     .
D5  MPRIS raise and quit       .     .    .     .
D6  media keys                 .     .    .     .
D7  media keys, two players    .     .    .     .
D8  notifications              .     .    .     .
D9  notification identity      .     .    .     .
D10 notifications off          .     .    .     .
D11 do not disturb             .     .    .     .
D12 MPRIS released at exit     .     .    .     .
E1  basic playback             .     .    .     .
E2  output device list         .     .    .     .
E3  routing to a device        .     .    .     .
E4  device across restart      .     .    .     .
E5  hotplug                    .     .    .     .
E6  per-app volume             .     .    .     .
E7  suspend and resume         .     .    .     .
E8  playback diagnostics       .     .    .     .
F1  secure storage usable      .     .    .     .
F2  Jellyfin configuration     .     .    .     .
F3  Navidrome configuration    .     .    .     .
F4  Plex configuration         .     .    .     .
F4b Audiobookshelf config      .     .    .     .
F5  credentials across restart .     .    .     .
F6  credentials encrypted      .     .    .     .
F6b credentials encrypted (fp) .     .    .     .
F7  locked keyring reported    .     .    .     .
F8  sign out                   .     .    .     .
F9  server playback            .     .    .     .
G1  Flatpak install            .     .    .     .
G2  Flatpak launch             .     .    .     .
G3  Flatpak portals            .     .    .     .
G4  Flatpak audio              .     .    .     .
G5  Flatpak uninstall          .     .    .     .
```

X11 columns only need re-running where the display server changes something:
A2, A3, A4, A6, A7, A8, A10 and A11. Mark the rest `n/a` rather than repeating
them. A11 is X11-only in the other direction: there is nothing to check for it
under Wayland.

**A2 is in that list for a reason that is easy to miss.** Window identity is
not one mechanism checked once: Wayland reads the `xdg_toplevel` app id, and
X11 reads `WM_CLASS` and `_NET_WM_ICON`, which the runner sets with different
calls (see [Desktop identity](./linux-desktop.md#desktop-identity)). Passing A2
under Wayland says nothing about X11, and an X11-only identity regression looks
exactly like a window that will not group with its launcher.

## Differences Linthra does not normalize

These are real, visible differences between the two desktops that Linthra
deliberately leaves alone, because they belong to the compositor, the window
manager or the portal backend. A pass records them; it does not fail on them,
and none of them is a reason to add a branch on which desktop is running.

| Difference | What you will see | Why it stays |
| --- | --- | --- |
| **Title bar decorations** | On a header-bar desktop the title bar is Linthra's own, with its controls inside the window. Elsewhere under X11 the window manager draws its own title bar in its own style. | GTK 3 implements no xdg-decoration protocol, so under Wayland the toolkit only has the client-side option, and under X11 there is no standard to ask. It changes who paints the title bar and nothing else. This is the [one grandfathered desktop-name check](#why-there-are-no-desktop-checks-in-the-code). |
| **Window position** | Position is restored on X11 and not under Wayland. | Wayland gives a client neither its own position nor a way to set one. Restoring only the size is what Wayland users expect. See [window state](./linux-desktop.md#window-state). |
| **Raise and focus** | MPRIS `Raise`, and a second launcher click, may present the window or may only mark it as needing attention, depending on the compositor's focus-stealing prevention. | Whether a background client may take focus is the compositor's decision. GTK 3 sends no xdg-activation token, so there is nothing for Linthra to pass along. |
| **Tiling and snapping** | Different edge gestures, different keyboard shortcuts, different tiled widths, and a half-screen tile that is narrower on one desktop than the other. | Window management. What Linthra owns is being usable at whatever width results, which is what A5 and A7 check. |
| **Fractional scaling** | A desktop that implements fractional scaling for its clients renders sharply at 125% or 150%; one that scales an integer-scaled surface down renders slightly soft. | GTK 3 has no fractional-scale protocol support. See [hidpi-and-scaling.md](./hidpi-and-scaling.md), which has the full scale pass. |
| **Notification presentation** | Placement, timeout, whether the cover is shown, whether a transient notification is kept in a history, and how do-not-disturb treats it. | The notification daemon's and the portal's decisions. Linthra sends a title, a body, a cover and low priority, and everything after that is the desktop's. |
| **File chooser appearance** | Two different choosers with different sidebars, different recent-file behaviour and different bookmark handling. | The portal backend is the desktop's implementation of a standard interface. Linthra asks for a folder through `GtkFileChooserNative` and takes the path it gets. |
| **Secret Service backend** | Different credential managers, different unlock prompts, different names for the keyring in their own UI. | Linthra speaks the freedesktop Secret Service interface (native) or the Secret portal (Flatpak). Which daemon answers is the desktop's business, and a locked one is reported rather than worked around. |
| **Audio server** | Sink names, per-app volume UI, and whether a sink reappears under the same name after a hotplug. | libmpv talks to whatever the session provides. E2 and E5 check Linthra's behaviour, not the server's naming. |
| **System appearance source** | A desktop that publishes `color-scheme` over the portal switches Linthra live; one that does not falls back to the GSettings path Flutter's embedder also implements. | Supplying the preference is the embedder's job, and the portal setting is the standard both desktops implement. Linthra has no Linux-specific theme code to make desktop-specific. |

### The window title was missing under a header bar

Worth calling out because this audit is what found it, and because it looks
like a difference and is not.

`gtk_header_bar_set_title()` draws a string inside the process.
`gtk_window_set_title()` is the call that reaches the display server, as X11's
`_NET_WM_NAME` and Wayland's `xdg_toplevel.set_title`. The Flutter Linux
template only made the second call on the branch where it had no header bar, so
on a header-bar desktop the window arrived with no title at all, and everything
that reads a window title rather than resolving an application id had nothing to
show: task manager tooltips, window switchers, overview labels, window rules
matched on a caption, `wmctrl` and `xdotool`, and a screen reader announcing the
focused window.

The runner now sets it before the decoration choice is made, so it is set
whichever way that choice goes, on both display servers.
`scripts/check_linux_runner.py` holds it there. That is check A3.

## What CI already answers

Everything below already runs on every PR, so a manual pass is for what only a
real desktop session can answer, not for re-checking these.

| Guardrail | What it proves |
| --- | --- |
| `scripts/check_linux_runner.py` | The window title is set unconditionally, the four desktop-identity calls are present in the places GTK honours them, the desktop entry and icon agree with the application id, the folder-picker and window-lifecycle channels agree with their Dart halves, the app is single-instance, and no new desktop-name check has appeared under `linux/`. Tests: `test/tooling/check_linux_runner_test.py`. |
| `test/tooling/desktop_environment_neutrality_test.dart` | No Dart source reads a desktop session environment variable or compares against a desktop's name. |
| `scripts/flatpak_launch_smoke.sh` | The packaged Flatpak launches twice and the real window answers to the application id, with an icon, both times. |
| `scripts/flatpak_audio_smoke.sh` | The whole playback transport works on the packaged libmpv, inside the sandbox. |
| `scripts/flatpak_local_library_smoke.sh` | A chosen music folder is scanned, tagged and played inside the sandbox. |
| `scripts/check_flatpak_permissions.py` | The sandbox holds exactly the permissions it is documented to hold, MPRIS's two `--own-name` grants included. |
| `test/core/services/mpris/…` | The MPRIS object's properties, metadata, position and transport methods, without a session bus. |
| `test/core/services/notifications/dbus_desktop_notifier_test.dart` | The portal route, the freedesktop route, the fallback between them, and the bounds on both. |
| `test/app/theme_mode_test.dart` | Light/Dark/System is one shared code path with no Linux-specific branch. |
| `.github/workflows/cpp-desktop-window.yml` | The window geometry rules (clamping, damaged state, a monitor that went away) as pure C++, with no display server. |

Two things CI structurally cannot answer, and that a pass therefore must:
whether a *real* compositor honours what Linthra asks for, and whether the
native brightness bridge under System actually delivers a preference. Both are
outside Linthra's code.

## Why there are no desktop checks in the code

Every Linux integration Linthra has goes through something both desktops
implement:

| Integration | Standard |
| --- | --- |
| Folder selection | `GtkFileChooserNative`, which GTK routes to the xdg-desktop-portal FileChooser when sandboxed |
| Notifications | `org.freedesktop.portal.Notification`, falling back to `org.freedesktop.Notifications` |
| Media controls and media keys | MPRIS on the session bus |
| Credentials | the freedesktop Secret Service, or the Secret portal when sandboxed |
| Window identity | the Wayland `xdg_toplevel` app id, X11's `WM_CLASS`, `_NET_WM_ICON`, `_NET_WM_NAME` |
| System appearance | the portal's `org.freedesktop.appearance` `color-scheme`, through Flutter's embedder |
| Audio | libmpv against whatever sound server the session runs |

None of those needs to know which desktop is on the other end, and a check that
does know is how "Linux support" quietly becomes "support for the desktop the
author uses". Two guardrails keep it that way:

* `scripts/check_linux_runner.py` scans every string literal under `linux/` for
  a desktop session environment variable or a desktop name, and
* `test/tooling/desktop_environment_neutrality_test.dart` does the same for
  `lib/`.

Both fail the build on a new one. Prose is exempt, and should be: comments and
docs name both desktops constantly, and only a runtime branch is the problem.

There is exactly **one** grandfathered exception, recorded in the checker's
`GRANDFATHERED_DESKTOP_NAME_CHECKS` table with its reason: the X11 title bar
decoration style in `linux/runner/my_application.cc`. It is X11-only, the
Wayland path never reaches it, it decides nothing but who paints the title bar,
and GTK 3 offers no xdg-decoration seam to replace it with. If it ever goes
away, the checker asks for the table entry to go with it.

Adding a second exception means editing that table, with a reason, and adding a
row to [differences Linthra does not normalize](#differences-linthra-does-not-normalize).
That is the intended amount of friction.

## When a check fails

Work out which layer owns it before filing:

1. **Does it fail on both desktops?** Then it is not a compatibility problem,
   it is a Linux bug. File it against the feature.
2. **Does it fail on one desktop, in both the native build and the Flatpak?**
   Most likely Linthra or the toolkit. File it with the session facts from the
   top of this page, both results side by side, and the exact row number.
3. **Does it fail only in the Flatpak?** Look at the sandbox first:
   [flatpak-permissions.md](./flatpak-permissions.md) and
   [flatpak-development.md](./flatpak-development.md) have the commands for
   inspecting it by hand.
4. **Is it in the [differences](#differences-linthra-does-not-normalize)
   table?** Then it is recorded behaviour. If it is a *new* difference of that
   kind, add a row rather than a branch.

A failure is never a reason to add a desktop-name check. If a row genuinely
cannot be satisfied through a standard, the honest outcome is a documented
difference, an upstream bug, or both.

## Related

| Topic | Doc |
| --- | --- |
| Linux desktop build, and everything it supports | [linux-desktop.md](./linux-desktop.md) |
| Manual QA checklist (Android, plus the Linux passes) | [manual-test-checklist.md](./manual-test-checklist.md) |
| HiDPI and fractional scaling | [hidpi-and-scaling.md](./hidpi-and-scaling.md) |
| Flatpak development | [flatpak-development.md](./flatpak-development.md) |
| Flatpak permission audit | [flatpak-permissions.md](./flatpak-permissions.md) |
| Suspend / resume matrix | [linux-desktop.md](./linux-desktop.md#suspend--resume-manual-matrix) |
| Closing the window (background mode) | [linux-desktop.md](./linux-desktop.md#closing-the-window) |
| Reporting a bug | [reporting-bugs.md](./reporting-bugs.md) |
