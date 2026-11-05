import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/cue_sheet.dart';

void main() {
  test('decodes UTF-8 Cyrillic without changing file names or metadata', () {
    const String source =
        'FILE "\u0410\u043b\u044c\u0431\u043e\u043c.flac" WAVE\n'
        'TRACK 01 AUDIO\nTITLE "\u0401\u0436"\nINDEX 01 00:00:00\n';
    for (final List<int> bytes in <List<int>>[
      utf8.encode(source),
      <int>[0xef, 0xbb, 0xbf, ...utf8.encode(source)],
    ]) {
      final tracks = CueSheet.parse('/music/disc.cue', CueSheet.decode(bytes));
      expect(tracks.single.audioPath,
          '/music/\u0410\u043b\u044c\u0431\u043e\u043c.flac');
      expect(tracks.single.title, '\u0401\u0436');
    }
  });

  test('decodes Windows-1251 file references and metadata before parsing', () {
    final List<int> bytes = <int>[
      ...'FILE "'.codeUnits,
      0xc0,
      0xeb,
      0xfc,
      0xe1,
      0xee,
      0xec,
      ...'.flac" WAVE\nTRACK 01 AUDIO\nTITLE "'.codeUnits,
      0xa8,
      0xe6,
      ...'"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 03:00:00\n'.codeUnits,
    ];
    final tracks = CueSheet.parse('/music/disc.cue', CueSheet.decode(bytes));

    expect(tracks, hasLength(2));
    expect(tracks.first.audioPath,
        '/music/\u0410\u043b\u044c\u0431\u043e\u043c.flac');
    expect(tracks.first.title, '\u0401\u0436');
    expect(tracks.first.end, const Duration(minutes: 3));
  });

  test('parses quoted metadata and derives adjacent track boundaries', () {
    final List<CueSheetTrack> tracks = CueSheet.parse(
      '/music/album/disc.cue',
      '''
PERFORMER "Album Artist"
TITLE "A Long Album"
FILE "disc one.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Opening"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Second Song"
    PERFORMER "Guest Singer"
    INDEX 01 03:15:37
''',
    );

    expect(tracks, hasLength(2));
    expect(tracks[0].audioPath, '/music/album/disc one.flac');
    expect(tracks[0].number, 1);
    expect(tracks[0].title, 'Opening');
    expect(tracks[0].album, 'A Long Album');
    expect(tracks[0].albumPerformer, 'Album Artist');
    expect(tracks[0].start, Duration.zero);
    expect(tracks[0].end, const Duration(milliseconds: 195493));
    expect(tracks[1].performer, 'Guest Singer');
    expect(tracks[1].start, const Duration(milliseconds: 195493));
    expect(tracks[1].end, isNull);
  });

  test('supports multiple referenced audio files and unquoted FILE names', () {
    final List<CueSheetTrack> tracks = CueSheet.parse(
      '/music/album.cue',
      '''
FILE first.flac WAVE
  TRACK 01 AUDIO
    TITLE "First"
    INDEX 01 00:00:00
FILE second.flac WAVE
  TRACK 02 AUDIO
    TITLE "Second"
    INDEX 01 00:00:00
''',
    );

    expect(tracks.map((CueSheetTrack track) => track.audioPath), <String>[
      '/music/first.flac',
      '/music/second.flac',
    ]);
    expect(tracks.map((CueSheetTrack track) => track.end), <Duration?>[
      null,
      null,
    ]);
  });

  test('ignores data tracks on mixed-mode discs', () {
    final List<CueSheetTrack> tracks = CueSheet.parse(
      '/music/enhanced.cue',
      '''
TITLE "Enhanced Album"
FILE disc.bin WAVE
  TRACK 01 AUDIO
    TITLE "Music"
    INDEX 01 00:00:00
  TRACK 02 MODE1/2352
    TITLE "Data Session"
    INDEX 01 40:00:00
''',
    );

    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'Music');
    expect(tracks.single.album, 'Enhanced Album');
  });
}
