import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/sources/local/cue_sheet.dart';

/// The Rust CUE reader has to give exactly what the Dart regular expressions
/// give: the same tracks, files, start times, titles and performers. A drift
/// splits a rip at the wrong place or puts a song under the wrong name.
///
/// Runs through the real Rust library hook/build.dart builds for the test
/// host, and is skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead).
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  group('native CUE sheets', skip: skip, () {
    test('match Dart on lines that are easy to get wrong', () {
      for (final String line in _trickyLines) {
        _expectSameAsDart(
          'FILE "a.flac" WAVE\nTRACK 01 AUDIO\n$line\nINDEX 01 00:00:00\n'
          'TRACK 02 AUDIO\n$line\nINDEX 01 01:00:00\n',
        );
        _expectSameAsDart('$line\nFILE a.flac WAVE\nTRACK 1 AUDIO\n$line\n'
            'INDEX 01 00:01:00\n');
      }
    });

    test('match Dart on random sheets', () {
      for (int seed = 0; seed < 2000; seed++) {
        final Random random = Random(seed);
        _expectSameAsDart(<String>[
          for (int i = 0; i < random.nextInt(14); i++)
            _parts[random.nextInt(_parts.length)] +
                _parts[random.nextInt(_parts.length)],
        ].join(<String>['\n', '\r\n', '\r', ' '][random.nextInt(4)]));
      }
    });

    test('decode bytes the way Dart does', () {
      final Random random = Random(7);
      for (int i = 0; i < 2000; i++) {
        final List<int> bytes = <int>[
          for (int b = 0; b < random.nextInt(12); b++) random.nextInt(256),
        ];
        expect(CueSheet.decode(bytes), CueSheet.decodeInDart(bytes));
      }
      // utf8.decode drops one leading byte order mark, and only one.
      for (final String text in <String>[
        'TITLE "Ёж Ⅻ 😀"',
        '\uFEFFTITLE x',
        '\uFEFF\uFEFFTITLE x',
        'TITLE \uFEFF',
      ]) {
        final List<int> bytes = utf8.encode(text);
        expect(CueSheet.decode(bytes), CueSheet.decodeInDart(bytes));
      }
      expect(CueSheet.decode(<int>[for (int b = 0x80; b < 0x100; b++) b]),
          CueSheet.decodeInDart(<int>[for (int b = 0x80; b < 0x100; b++) b]));
    });

    test('leave text with an unpaired surrogate to Dart', () {
      _expectSameAsDart(
          'FILE a.flac WAVE\nTRACK 01 AUDIO\nTITLE x\uD800\nINDEX 01 00:00:00');
    });
  });
}

/// Lines around every corner of the Dart patterns.
const List<String> _trickyLines = <String>[
  'TITLE  "a" b',
  'TITLE "a" b',
  'TITLE "a"  ',
  'TITLE ""',
  'TITLE "',
  'TITLE a b',
  'TITLE a  ',
  'TITLE  a',
  'TITLE a\rb',
  'title Lower Case',
  'TiTlE "Mixed"',
  'TITLE\tTabbed',
  'TITLE NBSP',
  'TITLE\u0085NEL',
  'TITLEx Glued',
  'TITLE',
  'PERFORMER "Ünïcödé 😀"',
  'PERFORMER  "x" y z',
  'REM TITLE hidden',
  'rem TITLE shown',
  'REM\tCOMMENT',
  'TİTLE dotted',
  'TITLE trailing \u0085',
  '﻿TITLE bom',
];

/// Fragments random sheets are stitched from.
const List<String> _parts = <String>[
  'FILE "a.flac" WAVE',
  'FILE b.flac WAVE',
  'FILE "c d.flac"',
  'FILE "" WAVE',
  'FILE "CD1\\e.flac" WAVE',
  'file f.flac mp3',
  'FILE',
  'TRACK 01 AUDIO',
  'TRACK 2 audio',
  'TRACK 03 MODE1/2352',
  'TRACK 99999999999999999999 AUDIO',
  'TRACK x AUDIO',
  'TRACK 04 audıo',
  'INDEX 01 00:00:00',
  'INDEX 01 03:25:74',
  'INDEX 01 999:59:74',
  'INDEX 01 1000:00:00',
  'INDEX 01 00:60:00',
  'INDEX 01 00:00:75',
  'INDEX 00 00:00:00',
  'INDEX 01 00:00:00 x',
  'TITLE ',
  'TITLE "q"',
  'TITLE  "q" r',
  'PERFORMER ',
  'PERFORMER p',
  'REM ',
  ' ',
  '\t',
  '"',
  ' ',
  '\u0085',
  ' ',
  '﻿',
  'x',
  'ß',
];

void _expectSameAsDart(String contents) {
  final List<String> dart =
      _describe(CueSheet.parseInDart('/music/disc.cue', contents));
  final List<String> rust =
      _describe(CueSheet.parse('/music/disc.cue', contents));
  expect(rust, dart, reason: jsonEncode(contents));
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
