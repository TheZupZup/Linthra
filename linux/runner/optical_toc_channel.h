#ifndef RUNNER_OPTICAL_TOC_CHANNEL_H_
#define RUNNER_OPTICAL_TOC_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// The native half of Linthra's audio-CD table-of-contents reader (issue #631,
// PR 2 of 5).
//
// Dart's `MethodChannelCdromTocSource` asks this channel for the table of
// contents of the disc in a drive and gets back the raw numbers the kernel
// reported: the first and last track, each track's start and control field,
// and where the lead-out begins — plus, when the drive can supply it, the
// undecoded CD-Text the disc carries in its lead-in.
//
// Why the runner: detection (PR 1) can ask UDisks2 how many audio tracks a
// disc has, but nothing on the system bus can say where they start or how long
// they run. That answer only comes from the drive, through the kernel's
// long-standing CDROMREADTOCHDR / CDROMREADTOCENTRY ioctls, and Linthra does
// not use `dart:ffi` — `scripts/check_pr_security_surface.py` rejects runtime
// FFI and dynamic library loading outright. So the ioctls are issued here, in
// the runner that is already the home of Linthra's other two Linux channels.
//
// What it is allowed to do: open a CD-ROM device read-only and ask it three
// questions. It never ejects, never locks the tray, never plays, never writes,
// and needs no privilege beyond read access to the device node the desktop
// already grants the logged-in user. Nothing here decides anything about the
// disc — every rule about what the numbers mean lives in Dart, under test.
typedef struct _OpticalTocChannel OpticalTocChannel;

// Registers the optical-TOC channel on `view`'s engine. Never returns NULL.
OpticalTocChannel* optical_toc_channel_new(FlView* view);

// Tears the channel down. Reads already running on a worker thread are allowed
// to finish and find the channel gone rather than being interrupted mid-ioctl.
void optical_toc_channel_free(OpticalTocChannel* self);

G_END_DECLS

#endif  // RUNNER_OPTICAL_TOC_CHANNEL_H_
