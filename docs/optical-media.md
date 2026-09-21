# Optical media detection (Linux)

How Linthra notices that a machine has a CD drive, and whether there is an
audio CD in it. Part of
[#631](https://github.com/TheZupZup/Linthra/issues/631), which will eventually
let a music disc be browsed and played like any other source.

**This is detection only.** Nothing here reads a table of contents, lists
tracks, mounts anything or plays a note. Those land in later PRs (see
[What comes next](#what-comes-next)), and they build on the seam described
here rather than beside it.

## What Linthra can tell you

One value, [`OpticalMediaSnapshot`](../lib/core/models/optical_media.dart),
answers the whole question:

| State | What it means |
| --- | --- |
| `unsupported` | Nothing in this build can look: Android, a non-Linux desktop, the Flatpak (see below), or a Linux box with no UDisks2 on it. |
| `supported`, no drives | The host was asked and it has no optical drive. A finding, not a failure — and the difference matters, because telling somebody with a perfectly good CD drive that they do not have one is the bug this distinction exists to prevent. |
| `supported`, drives listed | Each drive reports `empty`, `audioCd` or `otherMedia`. |
| `permissionDenied` | The host refused. Rare, and the one failure a user can actually act on. |
| `error` | Something else went wrong: a timeout, a dropped connection, a reply that did not parse. |

Each drive carries an opaque handle and its disc state, and nothing else. No
vendor, no model, no serial, no firmware revision: none of it is needed to
list or play a disc, and hardware identifiers should not travel into a UI, a
log or a bug report just because the platform handed them over.

### There is no "unreadable disc" state, and that is the hardware's limit

A disc the drive cannot read reaches Linthra as an **empty drive**, and no
amount of modelling changes that. Both of the properties detection reads come
from the same udev property, `ID_CDROM_MEDIA`:

- `Drive.Optical` is set from it directly
  (`udisks_drive_set_optical (iface, is_disc)` in `src/udiskslinuxdrive.c`),
  and
- `MediaAvailable` is derived from it for any drive udev tagged `ID_CDROM`
  (`udisks_daemon_util_block_get_size` in `src/udisksdaemonutil.c`, which
  deliberately never opens an optical device because doing so can close the
  tray).

So the two can never disagree. When `cdrom_id` cannot identify a disc it does
not set `ID_CDROM_MEDIA`, and the drive is reported as holding nothing.

The same applies to the moment just after a disc goes in: it reads as `empty`
until the host has identified the disc, then goes straight to its real state.
That is one transition, not an intermediate state, which is why detection
publishes one change rather than a flicker.

Telling a damaged disc from an empty tray means actually trying to read the
disc. That is the table-of-contents work in PR 2, and until it lands claiming
to distinguish them would be a promise the hardware does not keep.

## How it works

Linthra asks **UDisks2** over D-Bus. UDisks2 is the daemon GNOME Disks, GVfs
and every Linux file manager already use to talk about removable media, it
ships with every desktop distribution Linthra targets, and it publishes
exactly the property this feature turns on:

```
org.freedesktop.UDisks2.Drive
  MediaCompatibility   as   optical_cd, optical_dvd, …   (what the drive takes)
  MediaAvailable       b    is there anything in it
  Optical              b    is what is in it an optical disc
  OpticalNumAudioTracks u   CD-DA tracks in the table of contents  ← the one
```

`OpticalNumAudioTracks` is how a real audio CD is told apart from a disc that
merely holds audio files. It counts CD-DA tracks that the drive reads off the
disc itself, so it is non-zero only for a Red Book audio disc. A data CD full
of FLAC files has an ISO 9660 filesystem and zero audio tracks, and reads as
`otherMedia` no matter what is inside that filesystem. Nothing in this path
looks at a mount point, a directory listing or a file extension — which is
also why a CD-DA disc, which has no filesystem to mount at all, is never
missed for want of one.

A disc with both (a CD-Extra, audio tracks plus a data session) counts as an
audio CD. From a music player's point of view a disc with audio tracks is a
disc with audio tracks.

### Nothing polls

UDisks2 already watches the hardware, so Linthra does not. Inserting a disc,
ejecting one, plugging in a USB drive or pulling it out each produce a D-Bus
signal, and a signal is what makes Linthra look again. At rest there is no
timer armed, no device open and no syscall on a schedule — which also means
Linthra never spins a drive back up that the user let go quiet.

The one timer in the implementation is a 250 ms *settle* delay between a
signal and the read it triggers, because one physical insertion produces a
short burst of signals while the kernel and UDisks2 work out what the disc is.
It is armed by an event and never by a clock.

### Nothing is written, and nothing needs root

Linthra calls exactly one UDisks2 method, `GetManagedObjects`, and listens for
signals. It never calls `Drive.Eject`, `Filesystem.Mount`, `Block.Format` or
anything else the daemon offers, so there is no path through this code that
can mount, move or erase anything. Reading drive properties is allowed for a
logged-in local user out of the box: there is no polkit prompt, no `cdrom`
group requirement and no privileged helper.

### What was considered instead

| Approach | Why not |
| --- | --- |
| `CDROM_*` ioctls on `/dev/sr0` | Means opening the device (waking the drive), and polling — an ioctl cannot tell you a disc was inserted. Also fails outright without the right group membership. |
| libcdio / libdiscid | A native dependency and a build-system change on every target, to learn one integer that is already on the bus. Worth it for reading a table of contents (PR 2 may revisit it); not worth it for detection. |
| Parsing `lsblk`, `udevadm`, `/proc/sys/dev/cdrom/info` | Scraping human-readable output from a subprocess, which a music player should not be spawning. Fragile across distributions and versions. |
| Watching mount points | Cannot work: an audio CD has no filesystem, so it is never mounted. This is the mistake the feature is designed around. |

UDisks2 also costs **no new dependency**: Linthra already speaks D-Bus through
the `dbus` package for MPRIS (#397) and desktop notifications (#400).

## The Flatpak limitation

**Optical detection does not work in the Flatpak today, and this PR does not
change that.**

UDisks2 lives on the **system** bus. Linthra's sandbox grants no system-bus
reach of any kind, and [flatpak-permissions.md](./flatpak-permissions.md)
refuses `--system-talk-name=`, `--system-own-name=` and `--system-see-name=`
outright, with the reasoning that the system bus carries the machine's own
services and a music player has no business on it.

So the Linux service checks `FLATPAK_ID` and reports `unsupported` up front,
rather than opening a connection that is certain to be denied and reporting
it as an error the user could fix. Nothing in the sandbox is widened, and no
manifest changed in this PR.

What the Flatpak PR will have to weigh, when it comes:

- the narrowest grant that could work is
  `--system-talk-name=org.freedesktop.UDisks2`, which is one service rather
  than the bus;
- it is still reach into a service that can mount, unmount and format every
  disk on the machine, so the grant is much wider than what Linthra would use
  it for;
- there is no portal for optical media, so there is no
  user-grants-it-once alternative the way the file chooser is for folders;
- whatever is decided needs a row in the permission table, a written
  rationale, and a pass through `scripts/check_flatpak_permissions.py` —
  which checks both manifests *and* the installed package.

Until then, the native Linux build is the one that can detect a disc, and the
Flatpak says so honestly instead of showing an empty drive list.

## Android

Unchanged, and deliberately so. Android gets
`UnsupportedOpticalMediaService`, never loads a line of the Linux
implementation, never opens a bus and gains no permission. No Android
manifest, Gradle file or platform channel is touched by this feature.

## Where the code lives

| File | What it is |
| --- | --- |
| `lib/core/models/optical_media.dart` | The model: `OpticalMediaSnapshot`, `OpticalDrive`, `OpticalMediaAvailability`, `OpticalDiscState`. |
| `lib/core/services/optical/optical_media_service.dart` | The platform-neutral seam. |
| `lib/core/services/optical/unsupported_optical_media_service.dart` | Android and every other non-Linux host. |
| `lib/core/services/optical/platform_optical_media_service.dart` | The one place that knows about the platform split. |
| `lib/core/services/optical/linux_optical_media_service.dart` | The state machine: when to look, and what to say about a look that failed. |
| `lib/core/services/optical/udisks_drive_reading.dart` | The pure decoding: UDisks2 properties in, Linthra's model out. Where the audio-CD rule lives. |
| `lib/core/services/optical/udisks_object_source.dart` | The thin D-Bus half: the connection and the signal filter. |

The split is what makes it testable. Everything with a decision in it is a
pure function or a state machine over an injected seam, so the whole feature
is exercised with fixtures — **no test needs a drive, a disc or a bus, and CI
never depends on `/dev/sr0` existing**.

## Manual smoke test (needs real hardware)

CI cannot do any of this. On a Linux machine with an optical drive, on the
native (non-Flatpak) build:

1. With the drive empty, detection reports one drive in the `empty` state.
2. Insert an audio CD. Within a second or two the drive reports `audioCd`,
   with a track count matching the disc.
3. Eject it. The drive returns to `empty`; nothing else in the library,
   queue, playlists or downloads changes.
4. Insert a data CD or a DVD. The drive reports `otherMedia`, **not**
   `audioCd`, even if the disc is full of FLAC files.
5. Insert a badly scratched or unfinalised disc. Expect `empty`, per the
   limitation above, and confirm nothing hangs or crashes.
6. Insert and eject several times in quick succession. The final state
   matches what is actually in the drive.
7. Unplug a USB optical drive while a disc is in it. The drive disappears
   from the list; the app does not crash or hang.
8. Run the same build inside the Flatpak: detection reports `unsupported`.

## What comes next

This PR is the foundation. Still to come under #631:

- **PR 2** — reading the disc's table of contents, track list and durations,
  plus CD-Text where the disc has it. This is also what can finally tell a
  damaged disc from an empty drive.
- **PR 3** — playback through the existing `PlaybackController` and queue. No
  second player implementation.
- **PR 4** — the desktop optical-disc source and its UI, including what a
  queued track does when its disc leaves the machine.
- **PR 5** — the Flatpak decision described above, and sandbox validation.

Out of scope for all of them, per the issue: ripping, importing to the
library, DRM or copy-protection circumvention, Blu-ray video, and burning.

## Related

- [flatpak-permissions.md](./flatpak-permissions.md) — every permission
  Linthra asks for, and the ones it refuses
- [local-music.md](./local-music.md) — the ordinary local-file path, which is
  what a *data* disc of audio files would eventually reuse
- [linux-desktop.md](./linux-desktop.md) — building and running the Linux
  desktop build
