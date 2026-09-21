import 'package:flutter/foundation.dart';

/// Whether Linthra can answer the question "what optical drives does this
/// machine have?" at all — as opposed to what the answer is.
///
/// The distinction is the same one [SourceAvailability] and
/// [LocalRootAvailability] already draw elsewhere in Linthra, and it exists for
/// the same reason: "there is no optical drive" and "nothing here can see one"
/// are different facts, and only the first is about the user's hardware. A UI
/// that collapses them tells somebody with a perfectly good CD drive that they
/// do not have one.
enum OpticalMediaAvailability {
  /// Detection ran and [OpticalMediaSnapshot.drives] is the answer.
  ///
  /// An empty drive list under this value is a *positive* finding: the host was
  /// asked and it has no optical drive.
  supported,

  /// Nothing in this build can answer on this platform.
  ///
  /// Android (which has no optical media and must stay untouched), every
  /// non-Linux desktop, and — today — the Flatpak, whose sandbox deliberately
  /// grants no system-bus reach. See `docs/optical-media.md`.
  unsupported,

  /// The host refused to answer: the detection service is there and said no.
  ///
  /// Recoverable by the user in a way [error] is not — a polkit rule or a
  /// group membership — so it is kept apart rather than folded into a generic
  /// failure.
  permissionDenied,

  /// Detection was attempted and failed for a reason that is not a refusal: no
  /// service on the bus, a malformed reply, a connection that dropped.
  error,
}

/// What is in one optical drive right now.
///
/// Deliberately *not* a filesystem state. An audio CD is not a mounted
/// directory of files — it is a table of contents of CD-DA tracks with no
/// filesystem on it at all — so nothing here is expressed in terms of mount
/// points, paths or readable directories. Conflating the two is exactly how a
/// disc source ends up trying to list a folder that does not exist.
///
/// **There is no "unreadable disc" value, and that is a limit of detection
/// rather than a gap in the model.** A disc the drive cannot read reaches
/// Linthra as an *empty drive*. On Linux both facts come from one udev
/// property, `ID_CDROM_MEDIA`: udisks2 sets `Drive.Optical` from it directly
/// and derives `MediaAvailable` from it too for any drive udev tagged
/// `ID_CDROM`, so the two can never disagree and nothing this layer can see
/// tells a damaged disc from an empty tray. The moment just after a disc goes
/// in is the same: the drive reads as [empty] until the host has identified
/// the disc, then goes straight to its real state, which is one transition
/// rather than a state worth modelling. Telling a damaged disc apart means
/// actually reading it, which is the table-of-contents work later in #631;
/// until then, claiming to distinguish them would be a promise the hardware
/// does not keep. See `docs/optical-media.md`.
enum OpticalDiscState {
  /// The drive is there and there is nothing in it.
  ///
  /// Also what a disc the host could not identify looks like, per the note
  /// above: this is "the drive reports nothing usable", not a proof that the
  /// tray is physically empty.
  empty,

  /// A CD-DA disc with at least one audio track.
  ///
  /// Mixed-mode discs (CD-Extra: audio tracks plus a data session) land here
  /// too, because from a music player's point of view a disc with audio tracks
  /// is a disc with audio tracks.
  audioCd,

  /// Media is present and it is not CD-DA: a data CD, a DVD, a Blu-ray, a
  /// blank disc waiting to be burnt.
  ///
  /// Says nothing about whether the host mounted it or whether it holds
  /// playable files. That is the ordinary local-library path's question
  /// (issue #631, phase 2), not this one's.
  otherMedia,
}

/// One optical drive attached to this machine, and what is in it.
///
/// Carries the two things a later PR actually needs and nothing else. There is
/// deliberately no vendor, no model, no serial and no firmware revision here:
/// none of it is needed to list or play a disc, and hardware identifiers are
/// exactly the kind of thing that should not travel into a UI, a log or a bug
/// report just because the platform happened to hand them over.
@immutable
class OpticalDrive {
  const OpticalDrive({required this.id, required this.disc});

  /// A stable, secret-free handle for this drive.
  ///
  /// **Opaque to everything above the platform layer.** Presentation code may
  /// compare it, key a widget on it and pass it back down; it may not parse it
  /// or show it. On Linux it is the kernel device node (`/dev/sr0`), which is
  /// what the playback seam in a later PR has to open and which says nothing
  /// about the user or the hardware. Another platform would put its own handle
  /// here, and nothing above would change.
  ///
  /// Stable for as long as the drive stays attached. A USB drive that is
  /// unplugged and plugged back in may come back under a different node, and
  /// that is honestly a different drive as far as anything here can prove —
  /// the same rule [LocalRootProbe] follows for a removable disk that returns
  /// at a new mount point.
  final String id;

  /// What is in the drive right now.
  final OpticalDiscState disc;

  /// Whether this drive currently holds a playable audio CD.
  bool get hasAudioCd => disc == OpticalDiscState.audioCd;

  /// This drive with a different disc in it. Used by the detection services to
  /// build the next snapshot without rebuilding the identity.
  OpticalDrive withDisc(OpticalDiscState disc) =>
      OpticalDrive(id: id, disc: disc);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OpticalDrive && other.id == id && other.disc == disc);

  @override
  int get hashCode => Object.hash(id, disc);

  @override
  String toString() => 'OpticalDrive($id, ${disc.name})';
}

/// Everything Linthra knows about this machine's optical drives at one moment.
///
/// A value type, so a detection service can publish it on a stream and callers
/// can compare two of them instead of reconstructing a diff from events they
/// might have missed — the same shape
/// [AudioOutputDeviceService.deviceChanges] uses for output devices.
@immutable
class OpticalMediaSnapshot {
  const OpticalMediaSnapshot({
    required this.availability,
    this.drives = const <OpticalDrive>[],
  });

  /// Nothing here can look. The answer on Android, on non-Linux desktops, and
  /// inside the Flatpak until #631's sandbox work lands.
  const OpticalMediaSnapshot.unsupported()
      : availability = OpticalMediaAvailability.unsupported,
        drives = const <OpticalDrive>[];

  /// The host answered and has no optical drive. A finding, not a failure.
  const OpticalMediaSnapshot.noDrive()
      : availability = OpticalMediaAvailability.supported,
        drives = const <OpticalDrive>[];

  /// The host refused to answer.
  const OpticalMediaSnapshot.permissionDenied()
      : availability = OpticalMediaAvailability.permissionDenied,
        drives = const <OpticalDrive>[];

  /// Detection was attempted and failed.
  const OpticalMediaSnapshot.error()
      : availability = OpticalMediaAvailability.error,
        drives = const <OpticalDrive>[];

  /// The drives the host reported, in a stable order (by [OpticalDrive.id]), so
  /// two snapshots of the same machine compare equal however the platform
  /// happened to enumerate them.
  ///
  /// Always empty unless [availability] is [OpticalMediaAvailability.supported]:
  /// a failed look reports no drives rather than the ones it saw last time,
  /// because a stale list presented as current is worse than no list.
  final List<OpticalDrive> drives;

  final OpticalMediaAvailability availability;

  /// Whether this machine has at least one optical drive Linthra could see.
  bool get hasDrive => drives.isNotEmpty;

  /// Whether detection ran at all. False for every failure mode, so a caller
  /// that only wants "is there anything to show" asks one question.
  bool get isSupported => availability == OpticalMediaAvailability.supported;

  /// The drives holding an audio CD right now, in [drives] order. Empty is the
  /// normal case.
  Iterable<OpticalDrive> get audioCdDrives =>
      drives.where((OpticalDrive drive) => drive.hasAudioCd);

  /// Whether any drive holds an audio CD.
  bool get hasAudioCd => drives.any((OpticalDrive drive) => drive.hasAudioCd);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OpticalMediaSnapshot &&
          other.availability == availability &&
          listEquals(other.drives, drives));

  @override
  int get hashCode => Object.hash(availability, Object.hashAll(drives));

  @override
  String toString() =>
      'OpticalMediaSnapshot(${availability.name}, ${drives.length} drive(s))';
}
