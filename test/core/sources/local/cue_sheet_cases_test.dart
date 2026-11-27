import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/cue_sheet.dart';

/// Replays test/fixtures/cue_sheet_cases.json: the tracks, files, start and
/// end times, titles and performers the CUE reader gave for lines that are
/// easy to get wrong and for a few hundred random sheets, and how it decoded
/// random bytes. The answers were recorded from the Dart reader the Rust one
/// replaced, so a change here splits a rip at a new place or renames a song.
void main() {
  final Map<String, Object?> cases = jsonDecode(
    File('test/fixtures/cue_sheet_cases.json').readAsStringSync(),
  ) as Map<String, Object?>;

  test('sheets parse to the recorded tracks', () {
    final List<Object?> parse = cases['parse']! as List<Object?>;
    expect(parse, hasLength(greaterThan(300)));
    for (final Object? entry in parse) {
      final Map<String, Object?> c = entry! as Map<String, Object?>;
      final String sheet = c['sheet']! as String;
      expect(
        _describe(CueSheet.parse('/music/disc.cue', sheet)),
        c['tracks'],
        reason: jsonEncode(sheet),
      );
    }
  });

  test('bytes decode to the recorded text', () {
    for (final Object? entry in cases['decode']! as List<Object?>) {
      final Map<String, Object?> c = entry! as Map<String, Object?>;
      final List<int> bytes = (c['bytes']! as List<Object?>).cast<int>();
      expect(
        CueSheet.decode(bytes).codeUnits,
        c['text'],
        reason: '$bytes',
      );
    }
  });

  test('an unpaired surrogate reads as U+FFFD', () {
    final List<CueSheetTrack> tracks = CueSheet.parse(
      '/music/disc.cue',
      'FILE a.flac WAVE\nTRACK 01 AUDIO\nTITLE x\uD800\nINDEX 01 00:00:00',
    );
    expect(tracks.single.title, 'x�');
  });
}

List<String> _describe(List<CueSheetTrack> tracks) => <String>[
      for (final CueSheetTrack t in tracks)
        jsonEncode(<Object?>[
          t.number,
          t.audioPath,
          t.start.inMicroseconds,
          t.end?.inMicroseconds,
          t.title,
          t.performer,
          t.album,
          t.albumPerformer,
        ]),
    ];
