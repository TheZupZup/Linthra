import 'package:flutter/foundation.dart';

/// Red Book frames per second: a CD-DA sector is 1/75 of a second, exactly.
///
/// Every duration on an audio CD is a whole number of these, which is why
/// nothing in this file stores a `double`. A track is 13 037 frames long, not
/// "173.83 seconds"; the [Duration] getters are a convenience for the UI, and
/// the frame counts are the truth the arithmetic is done in.
const int cdFramesPerSecond = 75;

/// Frames between the start of a disc's lead-in and logical block 0.
///
/// The 2-second pre-gap Red Book puts in front of track 1. Kernel TOC reads
/// report positions as LBAs, which are relative to logical block 0; absolute
/// positions — the ones a disc identifier is computed from — are LBA + this.
const int cdLeadInFrames = 150;

/// The title Linthra shows for a disc whose CD-Text does not name it.
const String fallbackAudioCdTitle = 'Audio CD';

/// The title Linthra shows for a track whose CD-Text does not name it:
/// `Track 01`, `Track 02`, … — two digits, so a track list sorts and aligns.
String fallbackAudioCdTrackTitle(int trackNumber) =>
    'Track ${trackNumber.toString().padLeft(2, '0')}';

/// [frames] as a [Duration], rounded to the nearest microsecond.
///
/// One frame is 40 000/3 µs, so only multiples of three frames land exactly on
/// a microsecond. The rounding is done once, here, on the way *out* of the
/// model — never in the middle of a calculation — so a track list's durations
/// can never drift from the frame counts they came from.
Duration framesToDuration(int frames) =>
    Duration(microseconds: (frames * 40000 + 1) ~/ 3);

/// One playable CD-DA track on an audio disc.
///
/// A description of a track on the physical disc, not a library row. There is
/// no album, no year, no artwork, no file path and no identifier that would
/// survive the disc being taken out of the drive, because none of those are
/// things an audio CD carries. What a CD carries is a number, a position, a
/// length and — if the disc was mastered with CD-Text — a couple of strings.
@immutable
class AudioCdTrack {
  const AudioCdTrack({
    required this.number,
    required this.startFrame,
    required this.frameCount,
    this.title,
    this.artist,
  });

  /// The track's number in the disc's table of contents, 1-99.
  ///
  /// **The physical track number, not an index.** On a mixed-mode disc whose
  /// first track is data, the first playable track is number 2 and there is no
  /// track 1 in [AudioCdDisc.tracks]. Renumbering them 1..n would be a lie the
  /// next layer could not undo: this number, with the drive's device node, is
  /// what a player has to hand the drive to play this track.
  final int number;

  /// Where the track starts, in frames from the start of the lead-in.
  ///
  /// Absolute (LBA + [cdLeadInFrames]), so it is comparable with the
  /// lead-out position and with the offsets a disc identifier is computed
  /// from.
  final int startFrame;

  /// How long the track is, in frames. Always greater than zero: a track whose
  /// boundaries do not produce a positive length is not a playable track and
  /// does not reach this model.
  final int frameCount;

  /// The track title from CD-Text, or null when the disc carries none.
  ///
  /// Null is a fact, not a gap to paper over. [displayTitle] is where the
  /// fallback lives, so a caller that wants to *know* whether the disc named
  /// this track can still ask.
  final String? title;

  /// The track performer from CD-Text, or null when the disc carries none.
  final String? artist;

  /// Where the track ends, in frames from the start of the lead-in. Exclusive:
  /// the first frame of whatever comes next.
  int get endFrame => startFrame + frameCount;

  /// The track's length.
  Duration get duration => framesToDuration(frameCount);

  /// What to show for this track: its CD-Text title, or `Track 07`.
  String get displayTitle => title ?? fallbackAudioCdTrackTitle(number);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioCdTrack &&
          other.number == number &&
          other.startFrame == startFrame &&
          other.frameCount == frameCount &&
          other.title == title &&
          other.artist == artist);

  @override
  int get hashCode =>
      Object.hash(number, startFrame, frameCount, title, artist);

  @override
  String toString() => 'AudioCdTrack($number, $frameCount frames)';
}

/// The playable contents of one audio CD, as its table of contents describes
/// them.
///
/// Platform-neutral and disposable: it describes the disc that was in the
/// drive when it was read, and it stops being true the moment somebody presses
/// eject. Nothing here is persisted, and deliberately so — a CD's tracks are
/// not library rows and giving them stable catalog identities is a decision
/// for the PR that adds a disc source, not this one.
///
/// ## Playing a track
///
/// The locator a player needs is the pair ([driveId], [AudioCdTrack.number]):
/// the drive to open and the physical track on the disc in it. Both are
/// already here, which is the whole reason [driveId] is carried on the disc
/// rather than being left for the caller to remember.
@immutable
class AudioCdDisc {
  /// Takes a copy of [tracks] rather than holding the caller's list, for the
  /// same reason [OpticalMediaSnapshot] does: a value that can be rewritten
  /// through the reference that built it is not a value.
  AudioCdDisc({
    required this.driveId,
    required List<AudioCdTrack> tracks,
    this.discId,
    this.title,
    this.artist,
  }) : tracks = List<AudioCdTrack>.unmodifiable(tracks);

  /// The drive this disc was read from — an [OpticalDrive.id], opaque above
  /// the platform layer.
  ///
  /// Identifies the *drive*, never the disc. [discId] is the disc's own
  /// identity; conflating the two is how a player ends up playing track 4 of
  /// whatever disc happens to be in the tray now.
  final String driveId;

  /// A stable identifier derived from this disc's table of contents, or null
  /// when the TOC could not produce one.
  ///
  /// Computed entirely offline from the track offsets (see
  /// `cd_disc_id.dart`). Two reads of the same disc produce the same value and
  /// two different discs practically never collide, so it is what tells "the
  /// same disc, read again" from "a different disc in the same drive". Nothing
  /// in Linthra sends it anywhere.
  final String? discId;

  /// The disc title from CD-Text, or null when the disc carries none.
  final String? title;

  /// The disc performer from CD-Text, or null when the disc carries none.
  final String? artist;

  /// The playable CD-DA tracks, in disc order.
  ///
  /// **Audio only.** A mixed-mode disc's data track is not here: it is not
  /// playable audio, and a list that included it would put a burst of noise in
  /// somebody's queue. Never empty — a disc with no playable audio track is
  /// not an [AudioCdDisc] at all.
  final List<AudioCdTrack> tracks;

  /// What to show for this disc: its CD-Text title, or `Audio CD`.
  String get displayTitle => title ?? fallbackAudioCdTitle;

  /// The playable audio on the disc, in frames: the sum of the track lengths.
  ///
  /// Deliberately the sum rather than "lead-out minus the first track's
  /// start". On a mixed-mode disc the second one would count the data track
  /// and the gap in front of it as music.
  int get totalFrames => tracks.fold<int>(
        0,
        (int total, AudioCdTrack track) => total + track.frameCount,
      );

  /// How long the playable audio on this disc runs.
  Duration get totalDuration => framesToDuration(totalFrames);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioCdDisc &&
          other.driveId == driveId &&
          other.discId == discId &&
          other.title == title &&
          other.artist == artist &&
          listEquals(other.tracks, tracks));

  @override
  int get hashCode =>
      Object.hash(driveId, discId, title, artist, Object.hashAll(tracks));

  @override
  String toString() =>
      'AudioCdDisc($driveId, ${discId ?? 'no id'}, ${tracks.length} track(s))';
}

/// Why an attempt to read a disc's table of contents ended the way it did.
///
/// The same shape [OpticalMediaAvailability] uses, and for the same reason:
/// "there is no disc", "Linthra was not allowed to look" and "that disc is
/// damaged" are different things to put in front of somebody, and a single
/// null cannot tell them apart.
enum AudioCdInspectionStatus {
  /// The disc was read and [AudioCdInspection.disc] describes it.
  success,

  /// The drive is there and empty, or its tray is open.
  noDisc,

  /// There is a disc, and it has no playable CD-DA track: a data CD, a DVD, a
  /// Blu-ray, a blank.
  notAudioCd,

  /// The disc changed — or left — while it was being read.
  ///
  /// Its own outcome rather than a generic failure, because the one thing that
  /// must never happen is answering with the tracks of a disc that is no
  /// longer in the drive. A caller that sees this asks again.
  discChanged,

  /// There is a disc and its table of contents could not be read: a scratched
  /// or unfinalised disc, a drive that gave up, a TOC that does not parse.
  ///
  /// **This is the state detection alone could never reach.** UDisks2 reports
  /// a disc it cannot identify as an empty drive (see `docs/optical-media.md`);
  /// actually trying to read it is what tells the two apart.
  ///
  /// It is also where a medium with no CD table of contents at all lands — a
  /// Blu-ray, a blank disc, and some DVDs — rather than in [notAudioCd]. A
  /// data CD reaches [notAudioCd] correctly, because it really does have a
  /// table of contents with one data track in it; the others have nothing for
  /// this layer to read, and telling "no CD TOC" from "a damaged CD" needs the
  /// drive's current profile, which is another MMC command. See
  /// `docs/optical-media.md`.
  unreadable,

  /// The drive itself is gone: unplugged, or a device node that no longer
  /// names an optical drive.
  driveUnavailable,

  /// The host refused. Recoverable by the user — a group membership, a udev
  /// rule — in a way [unreadable] is not.
  permissionDenied,

  /// Nothing in this build can read a table of contents: every non-Linux
  /// platform, and the Flatpak. See `docs/optical-media.md`.
  unsupported,
}

/// The outcome of one attempt to read an audio CD.
///
/// A value, never an exception. Every implementation of [AudioCdTocService]
/// answers with one of these, because "that disc is unreadable" is something a
/// UI can show and a thrown error is not.
@immutable
class AudioCdInspection {
  /// The disc was read.
  const AudioCdInspection.success(AudioCdDisc this.disc)
      : status = AudioCdInspectionStatus.success;

  const AudioCdInspection.noDisc()
      : status = AudioCdInspectionStatus.noDisc,
        disc = null;

  const AudioCdInspection.notAudioCd()
      : status = AudioCdInspectionStatus.notAudioCd,
        disc = null;

  const AudioCdInspection.discChanged()
      : status = AudioCdInspectionStatus.discChanged,
        disc = null;

  const AudioCdInspection.unreadable()
      : status = AudioCdInspectionStatus.unreadable,
        disc = null;

  const AudioCdInspection.driveUnavailable()
      : status = AudioCdInspectionStatus.driveUnavailable,
        disc = null;

  const AudioCdInspection.permissionDenied()
      : status = AudioCdInspectionStatus.permissionDenied,
        disc = null;

  const AudioCdInspection.unsupported()
      : status = AudioCdInspectionStatus.unsupported,
        disc = null;

  final AudioCdInspectionStatus status;

  /// The disc, and only when [status] is [AudioCdInspectionStatus.success].
  /// Every failure carries null rather than the last disc that worked.
  final AudioCdDisc? disc;

  bool get isSuccess => status == AudioCdInspectionStatus.success;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AudioCdInspection &&
          other.status == status &&
          other.disc == disc);

  @override
  int get hashCode => Object.hash(status, disc);

  @override
  String toString() => 'AudioCdInspection(${status.name})';
}
