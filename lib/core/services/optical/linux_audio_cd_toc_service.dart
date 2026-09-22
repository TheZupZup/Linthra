import 'dart:async';

import '../../models/audio_cd.dart';
import '../../models/optical_media.dart';
import '../../platform/flatpak_sandbox.dart';
import 'audio_cd_toc_service.dart';
import 'cd_toc_reading.dart';
import 'cdrom_toc_source.dart';
import 'method_channel_cdrom_toc_source.dart';

/// Linux audio-CD table-of-contents reading.
///
/// The state machine of PR 2, and the twin of [LinuxOpticalMediaService] one
/// layer down: [CdromTocSource] talks to the drive and [audioCdDiscFrom] does
/// the arithmetic, and this decides what a read that did not work *means*.
/// Every decision in it is over an injected seam, so the whole class is
/// exercised without a drive, a disc or a running engine.
///
/// ## It asks the drive, not the last snapshot
///
/// [inspect] does not refuse a drive whose [OpticalDrive.disc] says `empty` or
/// `otherMedia`. Detection cannot tell a damaged disc from an empty tray —
/// both properties it reads come from the same udev flag, which is written up
/// in `docs/optical-media.md` — and actually reading the disc is the only
/// thing that can. Short-circuiting on the snapshot would throw that away and
/// hand the user "there is no disc" for a disc they are holding the case of.
///
/// ## Nothing here spins a drive on its own
///
/// There is no timer, no watch and no stream: a read happens when a caller
/// asks for one. Reading a table of contents wakes the drive and makes it
/// audible, so it is a thing the app does in response to somebody, never in
/// the background.
///
/// ## Every failure is a value
///
/// [inspect] cannot throw, including when the disc leaves the drive while it
/// is being read — the one failure this feature is guaranteed to meet in the
/// field, because ejecting is a button on the hardware.
class LinuxAudioCdTocService implements AudioCdTocService {
  LinuxAudioCdTocService({
    CdromTocSource? source,
    bool? sandboxed,
    this.readDeadline = defaultReadDeadline,
  })  : _source = source ?? const MethodChannelCdromTocSource(),
        _sandboxed = sandboxed ?? isFlatpakSandbox;

  /// How long a drive gets to answer before the read is given up on.
  ///
  /// Generous on purpose: a drive that has been idle has to spin up, focus and
  /// read the lead-in, which takes seconds on healthy media and longer on a
  /// marginal disc. Unbounded is not an option — a drive struggling with a
  /// scratched disc can retry for minutes, and a caller waiting on that has no
  /// way to tell it from a hang.
  static const Duration defaultReadDeadline = Duration(seconds: 20);

  final Duration readDeadline;
  final CdromTocSource _source;

  /// Whether this process is inside the Flatpak sandbox. See [isSupported].
  final bool _sandboxed;

  /// Whether this build can read a table of contents.
  ///
  /// False inside the Flatpak, and for a reason that is packaging rather than
  /// hardware: reading a disc means opening its device node, and Linthra's
  /// sandbox exposes no device nodes. Widening it would mean `--device=`
  /// access to the drive, which is #631's Flatpak PR to weigh and not this
  /// one's to grant. See `docs/optical-media.md`.
  @override
  bool get isSupported => !_sandboxed && _source.isSupported;

  @override
  Future<AudioCdInspection> inspect(OpticalDrive drive) async {
    if (!isSupported) return const AudioCdInspection.unsupported();
    // The node came from UDisks2, not from a person, so this is a guard
    // against a bug rather than against an attacker — but the thing on the
    // other side of it is an open() on a device, and a guard there is cheap.
    if (!isPlausibleOpticalDeviceNode(drive.id)) {
      return const AudioCdInspection.driveUnavailable();
    }

    final RawCdToc toc;
    try {
      toc = await _source.readToc(drive.id).timeout(readDeadline);
    } on CdromTocException catch (error) {
      return _inspectionForFailure(error.failure);
    } on TimeoutException {
      // A drive still trying after this is a drive that cannot read the disc,
      // whatever it would eventually have said.
      return const AudioCdInspection.unreadable();
    } catch (_) {
      // A source that broke its own contract. The whole point of this class is
      // that a caller never has to catch anything, so it is caught here.
      return const AudioCdInspection.unreadable();
    }

    // Two separate "no": a table of contents that does not describe a disc at
    // all, and one that describes a perfectly good disc with no music on it.
    if (normalizedTocEntries(toc) == null) {
      return const AudioCdInspection.unreadable();
    }
    final AudioCdDisc? disc = audioCdDiscFrom(toc, driveId: drive.id);
    if (disc == null) return const AudioCdInspection.notAudioCd();
    return AudioCdInspection.success(disc);
  }

  static AudioCdInspection _inspectionForFailure(CdromTocFailure failure) {
    switch (failure) {
      case CdromTocFailure.noDisc:
        return const AudioCdInspection.noDisc();
      case CdromTocFailure.discChanged:
        return const AudioCdInspection.discChanged();
      case CdromTocFailure.unreadable:
        return const AudioCdInspection.unreadable();
      case CdromTocFailure.driveUnavailable:
        return const AudioCdInspection.driveUnavailable();
      case CdromTocFailure.permissionDenied:
        return const AudioCdInspection.permissionDenied();
      case CdromTocFailure.unsupported:
        return const AudioCdInspection.unsupported();
    }
  }
}
