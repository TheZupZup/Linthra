import 'package:flutter/foundation.dart';

/// The control field bit that marks a TOC entry as a data track rather than
/// CD-DA audio (Red Book Q sub-channel, bit 2).
const int cdDataTrackControlFlag = 0x04;

/// The gap a multi-session disc leaves between the last audio track and the
/// data session that follows it: 152 seconds, in frames.
///
/// On a CD-Extra the data track's start position is *not* where the audio
/// stops — the run-out, the second session's lead-in and its pre-gap all sit in
/// between. Treating the data track's start as the last audio track's end
/// would add two and a half minutes of silence to it.
const int cdXaInterval = (60 + 90 + 2) * 75;

/// Why a table-of-contents read did not produce a table of contents.
///
/// The failures the platform can actually distinguish, and no more. They map
/// one-to-one onto the failing values of [AudioCdInspectionStatus], which is
/// where the reasoning about what each one means to a person lives.
enum CdromTocFailure {
  /// The drive is empty, its tray is open, or it is still spinning up.
  noDisc,

  /// The disc changed, or left, while the table of contents was being read.
  discChanged,

  /// There is a disc and its table of contents could not be read.
  unreadable,

  /// The drive is gone, or the device node does not name an optical drive.
  driveUnavailable,

  /// Opening the drive was refused.
  permissionDenied,

  /// This build has no way to read a table of contents at all.
  unsupported,
}

/// A table-of-contents read that failed, with the one fact the caller needs.
///
/// Carries no device node, no errno string and no drive model: a failure
/// travelling up through a UI or a bug report should not be carrying the
/// user's hardware with it. [detail] is a short, fixed, developer-facing
/// phrase chosen by the thrower, never platform text passed through.
@immutable
class CdromTocException implements Exception {
  const CdromTocException(this.failure, [this.detail]);

  final CdromTocFailure failure;
  final String? detail;

  @override
  String toString() =>
      'CdromTocException(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// One entry of a disc's table of contents, exactly as the drive reported it.
///
/// Undecoded on purpose: this is the platform's answer, and every rule about
/// what it *means* — which tracks are playable, where each one ends, how long
/// it runs — is applied above it by pure functions that fixtures can drive.
@immutable
class RawCdTocTrack {
  const RawCdTocTrack({
    required this.number,
    required this.startLba,
    required this.control,
  });

  /// The track number the drive reported, 1-99.
  final int number;

  /// The track's start as a logical block address: frames from logical block
  /// 0, which is [cdLeadInFrames] frames into the disc.
  final int startLba;

  /// The Q sub-channel control field. Only [cdDataTrackControlFlag] is read;
  /// the rest (pre-emphasis, copy permission, quadraphonic) is kept because it
  /// costs nothing and dropping it would mean changing this type to add it
  /// back.
  final int control;

  /// Whether this entry is a data track rather than playable CD-DA audio.
  bool get isData => (control & cdDataTrackControlFlag) != 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RawCdTocTrack &&
          other.number == number &&
          other.startLba == startLba &&
          other.control == control);

  @override
  int get hashCode => Object.hash(number, startLba, control);

  @override
  String toString() => 'RawCdTocTrack($number, lba $startLba, '
      'control 0x${control.toRadixString(16)})';
}

/// One whole table of contents, as read off a disc.
///
/// The boundary type of the whole feature: everything below it is platform
/// code that cannot be unit-tested, and everything above it is a pure function
/// over this value. A fixture is one of these, which is why no test in this
/// feature needs a drive.
@immutable
class RawCdToc {
  /// Takes a copy of [tracks] *and* of [cdText]; see [AudioCdDisc] for why the
  /// model layer does not hold bytes somebody else can still write to. The
  /// CD-Text buffer is the same argument as the track list: it feeds both the
  /// decoded metadata and this value's [hashCode], so a caller that kept the
  /// list it passed in could change what an already-published disc says.
  ///
  /// Copied *and* handed out unmodifiable, which are two different holes. The
  /// copy closes the one the constructor's argument opens; the view closes the
  /// one the getter opens, since a plain copy is still a writable list once a
  /// caller has it.
  RawCdToc({
    required this.firstTrack,
    required this.lastTrack,
    required this.leadOutLba,
    required List<RawCdTocTrack> tracks,
    Uint8List? cdText,
  })  : tracks = List<RawCdTocTrack>.unmodifiable(tracks),
        cdText = cdText == null
            ? null
            : Uint8List.fromList(cdText).asUnmodifiableView();

  /// The first and last track numbers from the TOC header. Not necessarily 1
  /// and `tracks.length`: a disc may start at any number, and a mixed-mode
  /// disc's range includes its data track.
  final int firstTrack;
  final int lastTrack;

  /// Where the lead-out starts, as an LBA. The end of the last track, and the
  /// end of the disc.
  final int leadOutLba;

  /// The TOC entries, in whatever order the platform reported them.
  final List<RawCdTocTrack> tracks;

  /// The drive's raw answer to a CD-Text read, or null when the drive or the
  /// disc has none.
  ///
  /// Deliberately undecoded bytes rather than parsed strings. CD-Text is a
  /// stream of 18-byte packs with CRCs, continuations and a character-set
  /// declaration, and every one of those is a place to get it wrong — so the
  /// decoding happens in Dart, under test, instead of in the platform half
  /// where no fixture can reach it.
  final Uint8List? cdText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RawCdToc &&
          other.firstTrack == firstTrack &&
          other.lastTrack == lastTrack &&
          other.leadOutLba == leadOutLba &&
          listEquals(other.tracks, tracks) &&
          listEquals(other.cdText, cdText));

  @override
  int get hashCode => Object.hash(
        firstTrack,
        lastTrack,
        leadOutLba,
        Object.hashAll(tracks),
        cdText == null ? null : Object.hashAll(cdText!),
      );

  @override
  String toString() => 'RawCdToc($firstTrack-$lastTrack, lead-out $leadOutLba, '
      '${tracks.length} entries)';
}

/// Reads a disc's table of contents from a drive.
///
/// The one seam in this feature that touches hardware. Implementations throw
/// [CdromTocException] and nothing else, so the service above can turn every
/// outcome into a value without a bare `catch` that would swallow a
/// programming error along with a missing disc.
///
/// Small on purpose: one method, one argument, one return type. A test
/// implements it in four lines; the real one opens a device.
abstract interface class CdromTocSource {
  /// Whether this build can read a table of contents at all. Answerable
  /// without touching the host.
  bool get isSupported;

  /// Reads the table of contents of the disc in [deviceNode] now.
  ///
  /// Throws [CdromTocException] for every failure, including "there is no
  /// disc", which is an ordinary answer rather than an error in the drive.
  Future<RawCdToc> readToc(String deviceNode);
}

/// Whether [deviceNode] is a plausible Linux optical-drive device node.
///
/// Checked here, in Dart, *and* again in the runner before the device is
/// opened. The value comes from UDisks2 rather than from a person, so this is
/// not input validation against an attacker so much as a guard against a bug
/// or a future caller handing the open() in the runner something that is not a
/// CD drive: `/dev/sda`, a path with `..` in it, a FIFO somebody planted. The
/// runner additionally requires the thing it opened to be a block device that
/// answers as a CD-ROM, because a name is only a name.
bool isPlausibleOpticalDeviceNode(String deviceNode) =>
    RegExp(r'^/dev/(?:sr|scd)\d{1,3}$').hasMatch(deviceNode);
