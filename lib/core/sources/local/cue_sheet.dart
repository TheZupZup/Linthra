import 'dart:convert';

import 'package:path/path.dart' as p;

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
  static String decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return String.fromCharCodes(bytes.map((int byte) {
        if (byte < 0x80) return byte;
        if (byte >= 0xc0) return 0x0410 + byte - 0xc0;
        return _windows1251[byte - 0x80];
      }));
    }
  }

  static const List<int> _windows1251 = <int>[
    0x0402,
    0x0403,
    0x201a,
    0x0453,
    0x201e,
    0x2026,
    0x2020,
    0x2021,
    0x20ac,
    0x2030,
    0x0409,
    0x2039,
    0x040a,
    0x040c,
    0x040b,
    0x040f,
    0x0452,
    0x2018,
    0x2019,
    0x201c,
    0x201d,
    0x2022,
    0x2013,
    0x2014,
    0x0098,
    0x2122,
    0x0459,
    0x203a,
    0x045a,
    0x045c,
    0x045b,
    0x045f,
    0x00a0,
    0x040e,
    0x045e,
    0x0408,
    0x00a4,
    0x0490,
    0x00a6,
    0x00a7,
    0x0401,
    0x00a9,
    0x0404,
    0x00ab,
    0x00ac,
    0x00ad,
    0x00ae,
    0x0407,
    0x00b0,
    0x00b1,
    0x0406,
    0x0456,
    0x0491,
    0x00b5,
    0x00b6,
    0x00b7,
    0x0451,
    0x2116,
    0x0454,
    0x00bb,
    0x0458,
    0x0405,
    0x0455,
    0x0457,
  ];

  static List<CueSheetTrack> parse(String cuePath, String contents) {
    final String directory = p.dirname(cuePath);
    final String source =
        contents.startsWith('\uFEFF') ? contents.substring(1) : contents;
    String? currentAudioPath;
    String? album;
    String? albumPerformer;
    String? trackTitle;
    String? trackPerformer;
    int? trackNumber;
    bool isAudioTrack = false;
    Duration? trackStart;
    final List<CueSheetTrack> tracks = <CueSheetTrack>[];

    void finishTrack() {
      final int? number = trackNumber;
      final Duration? start = trackStart;
      final String? audioPath = currentAudioPath;
      if (isAudioTrack &&
          number != null &&
          start != null &&
          audioPath != null) {
        tracks.add(CueSheetTrack(
          number: number,
          audioPath: audioPath,
          start: start,
          title: trackTitle,
          performer: trackPerformer,
          album: album,
          albumPerformer: albumPerformer,
        ));
      }
      trackNumber = null;
      trackStart = null;
      trackTitle = null;
      trackPerformer = null;
      isAudioTrack = false;
    }

    for (final String rawLine in source.split(RegExp(r'\r?\n'))) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('REM ') || line.startsWith('REM\t')) {
        continue;
      }
      final RegExpMatch? file = RegExp(
        r'^FILE\s+(?:"([^"]+)"|(\S+))\s+\S+',
        caseSensitive: false,
      ).firstMatch(line);
      if (file != null) {
        finishTrack();
        final String name = file.group(1) ?? file.group(2)!;
        currentAudioPath = p.normalize(p.join(directory, name));
        continue;
      }
      final RegExpMatch? track = RegExp(
        r'^TRACK\s+(\d+)\s+(\S+)',
        caseSensitive: false,
      ).firstMatch(line);
      if (track != null) {
        finishTrack();
        trackNumber = int.tryParse(track.group(1)!);
        isAudioTrack = track.group(2)!.toUpperCase() == 'AUDIO';
        continue;
      }
      final RegExpMatch? index = RegExp(
        r'^INDEX\s+01\s+(\d{1,3}):(\d{2}):(\d{2})\s*$',
        caseSensitive: false,
      ).firstMatch(line);
      if (index != null && isAudioTrack && trackNumber != null) {
        final int minutes = int.parse(index.group(1)!);
        final int seconds = int.parse(index.group(2)!);
        final int frames = int.parse(index.group(3)!);
        if (seconds < 60 && frames < 75) {
          trackStart = Duration(
            milliseconds: ((minutes * 60 + seconds) * 75 + frames) * 1000 ~/ 75,
          );
        }
        continue;
      }
      final RegExpMatch? title = _quotedValue('TITLE', line);
      if (title != null) {
        if (trackNumber == null) {
          album = title.group(1);
        } else {
          trackTitle = title.group(1);
        }
        continue;
      }
      final RegExpMatch? performer = _quotedValue('PERFORMER', line);
      if (performer != null) {
        if (trackNumber == null) {
          albumPerformer = performer.group(1);
        } else {
          trackPerformer = performer.group(1);
        }
      }
    }
    finishTrack();

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

  static RegExpMatch? _quotedValue(String directive, String line) => RegExp(
        '^${RegExp.escape(directive)}\\s+"(.*)"\\s*\$',
        caseSensitive: false,
      ).firstMatch(line);
}
