import 'package:path/path.dart' as p;

import '../../native/native_cue_sheet.dart';

/// One indexed audio track described by a CUE sheet.
class CueSheetTrack {
  const CueSheetTrack({
    required this.number,
    required this.audioPath,
    required this.start,
    this.title,
    this.performer,
    this.end,
    this.album,
    this.albumPerformer,
  });

  final int number;
  final String audioPath;
  final Duration start;
  final Duration? end;
  final String? title;
  final String? performer;
  final String? album;
  final String? albumPerformer;
}

/// Parses the common CUE directives used by CD rips: FILE, TRACK, TITLE,
/// PERFORMER and INDEX 01.
abstract final class CueSheet {
  /// Older Cyrillic CD-ripping tools write Windows-1251 without an encoding
  /// declaration. Try strict UTF-8 first so valid Unicode sheets stay intact.
  ///
  /// Runs in the Rust core (native/linthra_core/src/cue_sheet.rs).
  static String decode(List<int> bytes) => NativeCueSheet.decode(bytes);

  /// The audio tracks of the sheet at [cuePath], whose text is [contents].
  ///
  /// The directives are read in the Rust core
  /// (native/linthra_core/src/cue_sheet.rs). Joining each FILE to the sheet's
  /// folder and working out where each track ends happen here.
  static List<CueSheetTrack> parse(String cuePath, String contents) {
    final List<NativeCueTrack> native = NativeCueSheet.parse(contents);
    final String directory = p.dirname(cuePath);
    return _bounded(<CueSheetTrack>[
      for (final NativeCueTrack track in native)
        CueSheetTrack(
          number: track.number,
          audioPath: p.normalize(p.join(directory, track.file)),
          start: Duration(milliseconds: track.startMs),
          title: track.title,
          performer: track.performer,
          album: track.album,
          albumPerformer: track.albumPerformer,
        ),
    ]);
  }

  /// Ends each track where the next one on the same FILE starts.
  static List<CueSheetTrack> _bounded(List<CueSheetTrack> tracks) {
    final List<CueSheetTrack> bounded = <CueSheetTrack>[];
    for (int i = 0; i < tracks.length; i++) {
      final CueSheetTrack current = tracks[i];
      Duration? end = current.end;
      for (int next = i + 1; next < tracks.length; next++) {
        if (tracks[next].audioPath == current.audioPath) {
          if (tracks[next].start > current.start) {
            end = tracks[next].start;
          }
          break;
        }
        // A different FILE starts a new timeline; the previous file's actual
        // duration supplies its end when available.
        if (tracks[next].audioPath != current.audioPath) break;
      }
      bounded.add(CueSheetTrack(
        number: current.number,
        audioPath: current.audioPath,
        start: current.start,
        end: end,
        title: current.title,
        performer: current.performer,
        album: current.album,
        albumPerformer: current.albumPerformer,
      ));
    }
    return List<CueSheetTrack>.unmodifiable(bounded);
  }
}
