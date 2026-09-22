import '../../models/audio_cd.dart';
import 'cd_disc_id.dart';
import 'cd_text_reading.dart';
import 'cdrom_toc_source.dart';

/// Turns one raw table of contents into the audio CD Linthra can describe.
///
/// The pure half of this feature: a [RawCdToc] in, an [AudioCdDisc] out, no
/// drive, no channel, no clock. Every rule about what an audio CD *is* lives
/// here or in the two files beside it ([cdTextFrom], [musicBrainzDiscId]),
/// which is why those three carry the fixture tests rather than the platform
/// code under them.
///
/// Returns null when the table of contents describes no playable audio — a
/// data CD, a DVD, a blank — or when it does not describe a disc at all. The
/// service above turns the first into [AudioCdInspectionStatus.notAudioCd] and
/// the second into [AudioCdInspectionStatus.unreadable], which is a
/// distinction this function deliberately does not make: it reports what it
/// found, not what the user should be told.
AudioCdDisc? audioCdDiscFrom(RawCdToc toc, {required String driveId}) {
  final List<RawCdTocTrack>? entries = normalizedTocEntries(toc);
  if (entries == null) return null;

  final List<AudioCdTrack> tracks =
      playableAudioTracks(entries, toc.leadOutLba);
  if (tracks.isEmpty) return null;

  final CdTextMetadata text = cdTextFrom(toc.cdText);
  return AudioCdDisc(
    driveId: driveId,
    discId: musicBrainzDiscId(toc),
    title: text.discTitle,
    artist: text.discPerformer,
    tracks: <AudioCdTrack>[
      for (final AudioCdTrack track in tracks)
        AudioCdTrack(
          number: track.number,
          startFrame: track.startFrame,
          frameCount: track.frameCount,
          title: text.trackTitles[track.number],
          artist: text.trackPerformers[track.number],
        ),
    ],
  );
}

/// The TOC entries in disc order, or null when the table of contents is not
/// one Linthra will read.
///
/// Everything a real drive can hand back that is *not* a well-formed TOC is
/// rejected here rather than being coaxed into a track list:
///
///  * a header whose track range is outside 1-99, or inverted;
///  * an entry outside the header's own range, which belongs to no disc the
///    header describes;
///  * two entries claiming the same track number;
///  * a negative position, or a lead-out at or before the **last** track.
///    The lead-out is the physical end of the disc, so every track starts
///    before it; a TOC placing it in the middle of its own track list is
///    describing a disc that cannot exist, and checking only the first track
///    would let the tracks after the lead-out resolve to boundaries past the
///    end of the disc;
///  * entries whose positions do not increase with their numbers — a disc
///    cannot play track 5 before track 4, so a TOC saying otherwise is
///    corrupt rather than unusual.
///
/// Rejecting is the safe direction: a rejected TOC becomes "this disc is
/// unreadable", which is true and recoverable, while a salvaged one becomes a
/// track list with wrong boundaries that nothing downstream can tell from a
/// right one.
List<RawCdTocTrack>? normalizedTocEntries(RawCdToc toc) {
  if (toc.firstTrack < 1 || toc.lastTrack > 99) return null;
  if (toc.firstTrack > toc.lastTrack) return null;
  if (toc.leadOutLba < 0) return null;

  final Map<int, RawCdTocTrack> byNumber = <int, RawCdTocTrack>{};
  for (final RawCdTocTrack entry in toc.tracks) {
    if (entry.number < toc.firstTrack || entry.number > toc.lastTrack) {
      return null;
    }
    if (entry.startLba < 0) return null;
    if (byNumber.containsKey(entry.number)) return null;
    byNumber[entry.number] = entry;
  }
  if (byNumber.isEmpty) return null;

  final List<RawCdTocTrack> ordered = byNumber.values.toList(growable: false)
    ..sort((RawCdTocTrack a, RawCdTocTrack b) => a.number.compareTo(b.number));

  for (int i = 1; i < ordered.length; i++) {
    if (ordered[i].startLba < ordered[i - 1].startLba) return null;
  }
  // Against the *last* entry, not the first: positions are non-decreasing by
  // now, so this is the strictest form of "every track starts before the disc
  // ends" — and the only form that rejects a lead-out sitting between two
  // tracks, which would otherwise let the earlier one resolve to a boundary
  // past the physical end of the disc.
  if (toc.leadOutLba <= ordered.last.startLba) return null;

  return ordered;
}

/// The playable CD-DA tracks in [entries], with their boundaries resolved.
///
/// [entries] must already be normalized by [normalizedTocEntries].
///
/// ## Where a track ends
///
/// A CD's table of contents gives only start positions, so every track's
/// length is the distance to whatever comes next — and "whatever comes next"
/// is where mixed-mode discs are won or lost:
///
///  * the **last track on the disc** ends at the lead-out;
///  * a track followed by another track ends where that one starts;
///  * the **last audio track followed by a data track** — a CD-Extra — ends
///    [cdXaInterval] frames before the data track starts. The second session's
///    run-out, lead-in and pre-gap sit in that gap, and counting them as music
///    adds 2:32 of silence to the last song on the disc.
///
/// A data track *before* the last audio track (an ordinary single-session
/// mixed-mode disc, whose track 1 is data) gets no such adjustment: there is
/// no session boundary there, and the next audio track starts exactly where
/// the data track ends.
///
/// ## What is left out
///
/// Data tracks, wherever they sit. And any track whose resolved length is not
/// positive: a lead-out at or before the last track's start, or two entries at
/// the same position, describe a disc that cannot be played there. Both happen
/// on damaged and deliberately broken ("copy-protected") discs, and a
/// zero-length track in a queue is a track that ends the moment it starts.
List<AudioCdTrack> playableAudioTracks(
  List<RawCdTocTrack> entries,
  int leadOutLba,
) {
  int lastAudioNumber = -1;
  for (final RawCdTocTrack entry in entries) {
    if (!entry.isData) lastAudioNumber = entry.number;
  }
  if (lastAudioNumber < 0) return const <AudioCdTrack>[];

  final List<AudioCdTrack> tracks = <AudioCdTrack>[];
  for (int i = 0; i < entries.length; i++) {
    final RawCdTocTrack entry = entries[i];
    if (entry.isData) continue;

    final RawCdTocTrack? next = i + 1 < entries.length ? entries[i + 1] : null;
    final int endLba;
    if (next == null) {
      endLba = leadOutLba;
    } else if (next.isData && entry.number == lastAudioNumber) {
      endLba = next.startLba - cdXaInterval;
    } else {
      endLba = next.startLba;
    }

    final int frameCount = endLba - entry.startLba;
    if (frameCount <= 0) continue;

    tracks.add(
      AudioCdTrack(
        number: entry.number,
        startFrame: entry.startLba + cdLeadInFrames,
        frameCount: frameCount,
      ),
    );
  }
  return tracks;
}
