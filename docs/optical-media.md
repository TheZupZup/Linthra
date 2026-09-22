# Optical media (Linux)

How Linthra notices that a machine has a CD drive, whether there is an audio CD
in it, and what is on that disc. Part of
[#631](https://github.com/TheZupZup/Linthra/issues/631), which will eventually
let a music disc be browsed and played like any other source.

Two layers, and they are deliberately separate:

1. **Detection** — is there a drive, and is there an audio CD in it? Cheap, and
   answered by a daemon that already knows.
2. **Discovery** — what is on that disc? A real read of the disc itself: its
   table of contents, its track boundaries and durations, and its CD-Text.

**Neither of them plays anything.** Nothing here opens an audio stream, decodes
a sector, mounts anything, rips anything or touches `PlaybackController`. That
lands in later PRs (see [What comes next](#what-comes-next)), and it builds on
the seams described here rather than beside them.

## Part 1: detection

### What Linthra can tell you

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

#### There is no "unreadable disc" state in *detection*, and that is the hardware's limit

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
disc, which is what part 2 below does: `unreadable` is the one state detection
alone can never reach.

### How it works

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

#### Nothing polls

UDisks2 already watches the hardware, so Linthra does not. Inserting a disc,
ejecting one, plugging in a USB drive or pulling it out each produce a D-Bus
signal, and a signal is what makes Linthra look again. At rest there is no
timer armed, no device open and no syscall on a schedule — which also means
Linthra never spins a drive back up that the user let go quiet.

The one timer in the implementation is a 250 ms *settle* delay between a
signal and the read it triggers, because one physical insertion produces a
short burst of signals while the kernel and UDisks2 work out what the disc is.
It is armed by an event and never by a clock.

#### Nothing is written, and nothing needs root

Linthra calls exactly one UDisks2 method, `GetManagedObjects`, and listens for
signals. It never calls `Drive.Eject`, `Filesystem.Mount`, `Block.Format` or
anything else the daemon offers, so there is no path through this code that
can mount, move or erase anything. Reading drive properties is allowed for a
logged-in local user out of the box: there is no polkit prompt, no `cdrom`
group requirement and no privileged helper.

#### What was considered instead

| Approach | Why not |
| --- | --- |
| `CDROM_*` ioctls on `/dev/sr0` | Means opening the device (waking the drive), and polling — an ioctl cannot tell you a disc was inserted. Also fails outright without the right group membership. |
| libcdio / libdiscid | A native dependency and a build-system change on every target, to learn one integer that is already on the bus. Revisited — and again declined — for the table of contents; see [What was considered instead](#what-was-considered-instead-1) below. |
| Parsing `lsblk`, `udevadm`, `/proc/sys/dev/cdrom/info` | Scraping human-readable output from a subprocess, which a music player should not be spawning. Fragile across distributions and versions. |
| Watching mount points | Cannot work: an audio CD has no filesystem, so it is never mounted. This is the mistake the feature is designed around. |

UDisks2 also costs **no new dependency**: Linthra already speaks D-Bus through
the `dbus` package for MPRIS (#397) and desktop notifications (#400).

## Part 2: reading the disc

Once detection has found an audio CD, one call describes it:
[`AudioCdTocService.inspect`](../lib/core/services/optical/audio_cd_toc_service.dart)
takes the drive and answers with an
[`AudioCdInspection`](../lib/core/models/audio_cd.dart).

| Status | What it means |
| --- | --- |
| `success` | The disc was read. `disc` holds its playable tracks. |
| `noDisc` | The drive is empty, its tray is open, or it has not finished spinning up. |
| `notAudioCd` | There is a disc and it has no playable CD-DA track: a data CD, a DVD, a Blu-ray, a blank. |
| `discChanged` | The disc changed, or left, **while it was being read**. The numbers gathered describe a disc that is no longer there, so they are dropped rather than answered with. |
| `unreadable` | There is a disc and its table of contents could not be read: scratched, unfinalised, or a TOC that contradicts itself. **The state detection alone can never reach.** Also where a medium with no CD table of contents at all lands — see the note below. |
| `driveUnavailable` | The drive is gone, or the handle does not name an optical drive. |
| `permissionDenied` | Opening the drive was refused — a group membership, a udev rule. The one failure a user can act on. |
| `unsupported` | Nothing in this build can read a disc: Android, every non-Linux desktop, the Flatpak. |

A successful read produces an `AudioCdDisc`: the drive it came from, a disc
identity, optional CD-Text title and performer, and the ordered playable
tracks. Each `AudioCdTrack` carries its **physical** track number, its start
and length in frames, and whatever CD-Text named it.

Nothing about this is persisted. A CD's tracks are not library rows, and giving
them catalog identities is a decision for the PR that adds a disc source.

### How the disc is read

Through the kernel's own CD-ROM ioctls, issued by Linthra's Linux runner
(`linux/runner/optical_toc_channel.cc`) and surfaced over a method channel:

```
CDROM_GET_CAPABILITY   is this actually a CD-ROM
CDROM_DRIVE_STATUS     is there a disc in it
CDROMREADTOCHDR        the first and last track numbers
CDROMREADTOCENTRY      each track's start (LBA) and control field
CDROMREADTOCENTRY      again, for CDROM_LEADOUT: where the disc ends
SG_IO + READ TOC/PMA/ATIP (format 0101b)   the disc's CD-Text, best effort
```

The device is opened `O_RDONLY | O_NONBLOCK`. The `O_NONBLOCK` is not an
optimisation: without it, opening a CD-ROM blocks until a disc is present, and
on an open tray it can make the kernel close the tray. The read runs on a
worker thread, because a drive that has been idle takes seconds to spin up and
the GTK main loop is where Linthra's window is drawn.

Only a *definite* empty tray short-circuits the read. `CDROM_DRIVE_STATUS` also
answers `CDS_NO_INFO` (a drive with no status query at all) and
`CDS_DRIVE_NOT_READY` (one spinning up, or fighting a damaged disc), and
collapsing either into "no disc" would hide a disc the user is holding the case
of. Those fall through to the table-of-contents read, whose own failure is a
better answer than a guess made before trying.

**One read per drive at a time.** A deadline on the Dart side stops the caller
waiting; it cannot abort an ioctl a struggling drive has not returned from, and
that read keeps its worker thread and its descriptor until the drive gives up.
Without a guard, each retry would strand another one — so a second read on a
drive that already has one is refused immediately, which is what the disc looks
like from the caller's side anyway.

**Nothing is written, and nothing needs root.** The runner never ejects, never
locks the tray, never starts playback and never opens the device for writing;
`test/tooling/optical_toc_channel_contract_test.dart` asserts that it does not
even name those ioctls. Every command it does issue is on the kernel's
read-safe list for an unprivileged caller who can open the device — which the
desktop already grants the logged-in user.

**The platform half decides nothing.** It issues the ioctls and passes the raw
numbers and the undecoded CD-Text bytes to Dart. Every rule — which tracks are
playable, where each one ends, what the CD-Text says, what the disc's identity
is — is a pure function in `lib/core/services/optical/`, driven by fixtures.

#### What was considered instead

| Approach | Why not |
| --- | --- |
| `dart:ffi` into libc or libcdio | Linthra's own security guard rejects runtime FFI and dynamic library loading outright, by a rule approval cannot clear ([pr-security-guard.md](./pr-security-guard.md)). That is a deliberate property of this codebase, not an obstacle to route around. |
| libcdio | A native library, a build-system change on every target, a `.so` whose soname has moved repeatedly, and a package many distributions do not install by default — to wrap ioctls Linthra can issue itself. Its GPL-3.0-or-later licence would have been compatible with Linthra's AGPL-3.0-or-later; the cost was never the licence. |
| libdiscid | The same costs, for a narrower library: a TOC and a disc ID, and no CD-Text at all. Its *algorithm* is what Linthra actually needed, and reading an algorithm costs no dependency (see [Disc identity](#disc-identity)). |
| Reading the TOC through libmpv | Linthra already links libmpv, and mpv can open `cdda://` — but only when it was built with libcdio, which is not guaranteed; it spins the drive through the player; and it would make the metadata layer depend on the playback engine, which is exactly the coupling PR 3 must not inherit. |
| Parsing `cd-info`, `cdparanoia`, `cdda2wav`, `udevadm` | Scraping human-readable output from a subprocess. The same guard blocks subprocess execution outright, and it is fragile across distributions and versions besides. |
| Asking UDisks2 | It publishes how many audio tracks a disc has and nothing about where they are. There is no TOC on the bus to read. |

No dependency was added for any of this. The only new native code is one file
in the runner that was already there.

### Track boundaries and durations

A CD's table of contents gives **start positions only**, so every track's
length is the distance to whatever comes next — and everything hard about this
feature is in "whatever comes next".

Positions are in **frames**: 75 to the second, exactly, and a whole number of
them for every track. Nothing in the calculation uses a `double`. A track is
13 959 frames long, and `Duration` is derived from that once, on the way out to
the UI, rounded to the nearest microsecond (one frame is 40 000/3 µs, so only
multiples of three land exactly). Doing it that way means a disc's total
duration cannot drift from the sum of its tracks.

The rules, in order:

- the **last track on the disc** ends at the lead-out;
- a track followed by another track ends where that one starts;
- the **last audio track followed by a data track** — a CD-Extra — ends
  **11 400 frames** (2:32) before the data track starts. The second session's
  run-out, lead-in and pre-gap sit in that gap. Counting them as music adds
  two and a half minutes of silence to the last song on the disc.

A data track *before* the last audio track — an ordinary single-session
mixed-mode disc, whose track 1 is data — gets no such adjustment: there is no
session boundary there, and the next audio track starts exactly where the data
track ends.

### Mixed-mode discs

**Data tracks are never playable tracks.** `AudioCdDisc.tracks` holds the
audio, wherever the data sits: a game CD whose track 1 is data has a first
playable track numbered **2**, and there is no track 1 in the list.

The numbers are the disc's own. Renumbering them 1..n would be a lie the next
layer could not undo, because the physical track number — with the drive's
device node — is exactly what a player has to hand the drive to play it.

A disc whose every track is data is not an audio CD at all, and reports
`notAudioCd`.

#### Media with no CD table of contents read as `unreadable`

A **data CD** reports `notAudioCd` correctly: it really does have a Red Book
table of contents, with one data track in it, and that is what the reader sees.

A **Blu-ray, a blank disc, and some DVDs** have no CD table of contents at all,
so the read fails and they report `unreadable` instead. That is honest as far as
it goes — this layer genuinely could not read a CD table of contents off them —
but `notAudioCd` would be the more useful answer.

Telling "this medium has no CD TOC" from "this CD is damaged" means asking the
drive for its current profile, which is another MMC command over `SG_IO`, and
the `SG_IO` surface here is deliberately staying as small as it is until the
CD-Text path has been validated on real hardware. Noted for a later PR rather
than guessed at now.

In practice it is a narrow gap: detection (part 1) already answers "is this an
audio CD" from UDisks2 without touching the drive, so a Blu-ray reaching the
table-of-contents reader at all is an unusual path.

### CD-Text

Read when the disc has it, from the same drive, in the same call. Linthra takes
four fields — disc title, disc performer, track title, track performer — and
ignores the other nine pack types. A disc's "message area" is free text
somebody typed at mastering time, and putting it in front of a listener as
metadata is how a track ends up called `THANKS FOR BUYING THIS CD`.

**Nothing is guessed.** The decoder returns *no* CD-Text at all — so the whole
disc falls back — whenever it cannot be sure:

- a truncated header, or a byte count that is not a whole number of packs. A
  drive that transfers less than it promised is cut back to what actually
  arrived (and to whole packs) before Dart ever sees it, so the zero tail of
  the buffer can never reach the decoder as CD-Text the disc does not carry;
- a pack whose CRC does not match (a CRC of zero means the drive did not fill
  it in, which many do not, and is not a mismatch);
- a gap in the block's sequence numbers, which means a pack went missing and
  every continuation after it would join the wrong text;
- double-byte text (MS-JIS), which Linthra has no decoder for. Rendering those
  bytes as Latin-1 produces mojibake that *looks* like metadata, and a disc
  that honestly says `Track 01` is better than one that confidently says
  `ï¾€ï½`.

Non-ASCII single-byte text is fully supported: a block declaring ISO-8859-1
decodes accented Latin text as the disc meant it. Only block 0 — the primary
language — is read; choosing between a disc's eight language blocks means
matching them against the user's locale, which is a feature with a UI attached.

A disc that names only some of its tracks gets a partial answer, not a
discarded one.

### Fallback metadata

When the disc says nothing, Linthra says the obvious thing and nothing more:

```
Audio CD
  Track 01
  Track 02
  Track 03
  …
```

Two digits, so a track list sorts and aligns. `AudioCdDisc.title` and
`AudioCdTrack.title` stay **null** — the fallbacks live in `displayTitle`, so a
caller that needs to know whether the disc actually named something still can.

### Disc identity

`AudioCdDisc.discId` is a **MusicBrainz Disc ID**, computed offline from the
track offsets.

A disc needs an identity that is the *disc's*: `/dev/sr0` names the tray, and
using it would make every disc anybody ever puts in that drive the same disc.
The standard answer is a hash of the disc's own geometry, and Linthra computes
it exactly as `libdiscid` does — the first and last *audio* track numbers, 100
offsets in frames, SHA-1, base64 with `+/=` replaced by `._-`. A CD-Extra's
data track is excluded, and the data track's start minus the XA interval stands
in for the lead-out.

Reusing the standard rather than inventing a fingerprint costs nothing and buys
the one thing an invented one could not: a later, *opt-in* metadata lookup
would need this exact string.

**Computing it is not looking it up.** It is arithmetic over bytes the drive
already handed us. Nothing sends it anywhere, and this layer makes no network
request of any kind — no MusicBrainz, no Discogs, no cover art.

### Ejecting mid-read

A drive is the one piece of hardware a user can empty with their thumb while
the software is reading it, so every outcome is a value and none of them is an
exception:

- the drive **disappears before** the read → `driveUnavailable`;
- the disc is **removed during** the read → `discChanged`;
- the disc is **swapped during** the read → `discChanged`. After gathering
  everything the runner reads the **whole** table of contents again — header,
  every track's position and control field, and the lead-out — and compares it
  with what it started from. The full comparison matters because two different
  discs can easily share a track range and even a lead-out; only the track
  positions prove the disc in the drive is still the one that was read;
- the drive **never answers** → `unreadable` after a 20-second deadline,
  because a caller waiting forever cannot tell a slow drive from a hang;
- the disc is **unreadable** → `unreadable`, which is the whole point of this
  layer existing.

No failure ever carries a disc, and no stale disc is ever returned as though it
were current.

## The Flatpak limitation

**Neither optical detection nor disc reading works in the Flatpak today, and
nothing in either PR changes that.** No manifest has been touched, no
permission added, and `scripts/check_flatpak_permissions.py` is unweakened.

Both halves check `FLATPAK_ID` and report `unsupported` up front, rather than
opening something that is certain to be refused and reporting it as an error
the user could fix.

They are blocked on two different things, and the Flatpak PR has to weigh both.

**Detection needs the system bus.** UDisks2 lives on it, Linthra's sandbox
grants no system-bus reach of any kind, and
[flatpak-permissions.md](./flatpak-permissions.md) refuses
`--system-talk-name=`, `--system-own-name=` and `--system-see-name=` outright,
with the reasoning that the system bus carries the machine's own services and a
music player has no business on it. Then:

- the narrowest grant that could work is
  `--system-talk-name=org.freedesktop.UDisks2`, which is one service rather
  than the bus;
- it is still reach into a service that can mount, unmount and format every
  disk on the machine, so the grant is much wider than what Linthra would use
  it for;
- there is no portal for optical media, so there is no user-grants-it-once
  alternative the way the file chooser is for folders.

**Reading a disc needs the device node.** `/dev/sr0` is not in the sandbox, and
the options are all worse than they look:

- `--device=all` exposes *every* device on the machine, which is far more than
  a CD drive and is exactly the kind of blanket grant the permission policy
  exists to refuse. It is not on the table.
- `--device=` has no per-node form for optical drives, so there is no narrow
  version of the same grant to reach for instead.
- a `--filesystem=` rule over `/dev` would be broad filesystem access wearing a
  different name, and would still not carry the ioctl permissions the read
  needs.
- there is no portal for this either.

Whatever is decided needs a row in the permission table, a written rationale,
and a pass through `scripts/check_flatpak_permissions.py` — which checks both
the manifests *and* the installed package.

Until then, the native Linux build is the one that can see a disc, and the
Flatpak says so honestly instead of showing an empty drive list.

## Android

Unchanged, and deliberately so. Android gets `UnsupportedOpticalMediaService`
and `UnsupportedAudioCdTocService`, never loads a line of the Linux
implementation, never opens a bus, never names a device and gains no
permission. No Android manifest, Gradle file or platform channel is touched by
this feature, and no Android native code exists for it.

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
| `lib/core/models/audio_cd.dart` | The disc model: `AudioCdDisc`, `AudioCdTrack`, `AudioCdInspection`, frame arithmetic and the fallback titles. |
| `lib/core/services/optical/audio_cd_toc_service.dart` | The platform-neutral discovery seam. |
| `lib/core/services/optical/unsupported_audio_cd_toc_service.dart` | Android and every other non-Linux host. |
| `lib/core/services/optical/platform_audio_cd_toc_service.dart` | The one place that knows about the platform split. |
| `lib/core/services/optical/linux_audio_cd_toc_service.dart` | The state machine: what a read that did not work means. |
| `lib/core/services/optical/cdrom_toc_source.dart` | The hardware seam: `RawCdToc`, `CdromTocException`, and the device-node guard. |
| `lib/core/services/optical/cd_toc_reading.dart` | The pure derivation: TOC in, playable tracks with exact boundaries out. |
| `lib/core/services/optical/cd_text_reading.dart` | The pure CD-Text decoder: packs, CRCs, continuations, character sets. |
| `lib/core/services/optical/cd_disc_id.dart` | The pure disc identity. |
| `lib/core/services/optical/method_channel_cdrom_toc_source.dart` | The thin channel half. |
| `lib/core/platform/flatpak_sandbox.dart` | The one `FLATPAK_ID` check both halves share. |
| `linux/runner/optical_toc_channel.cc` | The native half: three ioctls, a worker thread, and no decisions. |

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

### Reading the disc

Continuing on the same machine, with the same build. Nothing below writes to a
disc, ejects one, or changes anything on the machine.

1. With an audio CD in the drive, inspect it. Expect `success`, and a track
   count that matches the number of tracks printed on the disc.
2. Check the durations against the case or the booklet. They should match to
   the second — the last track included, which is the one a wrong lead-out
   would get wrong.
3. Check the total. It should equal the sum of the track durations, and the
   disc's stated running time.
4. Check the disc identity. Inspect the same disc twice: the identifier must be
   the same both times. Inspect a *different* disc: it must differ. If the
   machine has two drives, the same disc in either drive gives the same
   identifier.
5. With a disc that carries CD-Text (many 1990s and later pressings do; the
   case usually says so), expect the real disc title, performer and track
   titles. With a disc that does not, expect `Audio CD` and `Track 01`,
   `Track 02`, … — and **no invented names**.
   **Try several CD-Text discs from different labels and eras.** The decoder
   refuses a pack whose item byte or character position contradicts the
   stream, which is correct by the specification but stricter than some
   mastering tools were; a disc that falls back to `Track NN` while its case
   promises titles is the signal that the check needs relaxing, and it is
   worth knowing before PR 4 puts those titles in front of anyone.
6. With a CD-Extra or enhanced CD (audio tracks plus a data session), expect
   only the audio tracks, and expect the last one **not** to run two and a half
   minutes long.
7. With a mixed-mode disc whose first track is data — a 1990s game CD — expect
   the first playable track to be numbered **2**, not 1.
8. With a data CD or a DVD, expect `notAudioCd`.
9. With a badly scratched or unfinalised disc, expect `unreadable` — not a
   hang, not a crash, and not an empty track list presented as success.
10. Start an inspection and **press eject while it is running**. Expect
    `discChanged` or `noDisc`, never a track list. The app must stay
    responsive throughout: the read happens on a worker thread, so the window
    should keep redrawing.
11. Eject, then inspect. Expect `noDisc`. Insert a *different* disc and inspect
    again: expect that disc's tracks and its own identifier, with nothing of
    the previous disc left over.
12. Unplug a USB optical drive and inspect it. Expect `driveUnavailable`.
13. On a machine where the user is not in the group that owns `/dev/sr0`
    (check with `ls -l /dev/sr0`), expect `permissionDenied` rather than a
    generic failure. Do not change any system permission to test this — if the
    desktop already grants access, this step is simply not reproducible on
    that machine.
14. Run the same build inside the Flatpak: reading reports `unsupported`.
15. Confirm the read is offline. With the network disconnected, every step
    above behaves identically — nothing here contacts MusicBrainz, Discogs or
    anything else.

## What comes next

Detection and discovery are the foundation. Still to come under #631:

- **PR 3** — playback through the existing `PlaybackController` and queue. No
  second player implementation. The locator it needs is already here: the pair
  (`AudioCdDisc.driveId`, `AudioCdTrack.number`).
- **PR 4** — the desktop optical-disc source and its UI, including what a
  queued track does when its disc leaves the machine, and whether a disc's
  metadata is worth caching against its identifier.
- **PR 5** — the Flatpak decision described above, for **both** the system bus
  and the device node, and sandbox validation.

Out of scope for all of them, per the issue: ripping, importing to the
library, online metadata lookup, cover-art downloading, DRM or copy-protection
circumvention, Blu-ray video, and burning.

## Related

- [flatpak-permissions.md](./flatpak-permissions.md) — every permission
  Linthra asks for, and the ones it refuses
- [local-music.md](./local-music.md) — the ordinary local-file path, which is
  what a *data* disc of audio files would eventually reuse
- [linux-desktop.md](./linux-desktop.md) — building and running the Linux
  desktop build
