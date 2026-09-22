import '../../models/audio_cd.dart';
import '../../models/optical_media.dart';

/// Reads the table of contents of an audio CD that detection has already
/// found.
///
/// The second half of #631's discovery layer, and deliberately a separate seam
/// from [OpticalMediaService]. Detection answers "is there an audio CD in a
/// drive", cheaply, from a daemon that already knows; this answers "what is on
/// that disc", which costs a real read of the disc itself. Keeping them apart
/// is what stops a drive being spun up every time a snapshot is published.
///
/// ## It is still not playback
///
/// Nothing here opens an audio stream, decodes a sector or touches
/// `PlaybackController`. It produces a description: the ordered, playable
/// tracks of the disc, their exact lengths, and whatever the disc says its
/// titles are. Playing one of them is the next PR's job, and the pair
/// ([AudioCdDisc.driveId], [AudioCdTrack.number]) is the whole locator it
/// needs from here.
///
/// ## It never throws
///
/// Every outcome — no disc, a disc pulled out mid-read, a scratched disc, a
/// refused open, a platform with no optical media at all — comes back as an
/// [AudioCdInspection]. A drive is the one piece of hardware a user can remove
/// with their thumb while the software is reading it, so "the disc went away"
/// has to be an ordinary answer rather than an exception somebody forgot to
/// catch.
abstract interface class AudioCdTocService {
  /// Whether this build can read a table of contents at all.
  ///
  /// A fact about the platform and the packaging, not about the hardware:
  /// false everywhere but a native Linux build. Answerable without touching a
  /// drive, so a caller can decide whether to offer a disc at all.
  bool get isSupported;

  /// Reads the disc in [drive] now.
  ///
  /// [drive] comes from an [OpticalMediaSnapshot]. It may already be stale —
  /// the disc it described can be in somebody's hand by the time this runs —
  /// which is exactly why the answer is a value with a status on it.
  Future<AudioCdInspection> inspect(OpticalDrive drive);
}
