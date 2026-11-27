import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/sources/local/cue_sheet.dart';
import 'package:linthra/core/sources/local/local_audio_metadata.dart';
import 'package:linthra/core/sources/local/local_track_mapper.dart';
import 'package:linthra/core/sources/local/saf_document_lister.dart';

/// The Rust mapping has to name every track as the Dart rules do: a drift
/// renames a library on the next scan, splits an album, or files a song
/// under the wrong artist.
///
/// Runs through the real Rust library hook/build.dart builds for the test
/// host, and is skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead).
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  group('native track mapping', skip: skip, () {
    test('matches Dart on file names', () {
      for (final String name in <String>[
        '01 - Intro (Live)',
        '03. Song',
        '4 Song',
        '05_Song',
        '1984',
        '1234 Song',
        '12) Song',
        '12] Song',
        '01 -',
        '01 - ',
        '01 ',
        '01 a\nb',
        '01\nab',
        '01 \u0085x',
        '01\u0085x',
        '01 -\n',
        '01  ',
        '01᠎x',
        '01﻿x',
        '﻿',
        '﻿﻿',
        '   ',
        '',
        '.hidden',
        'a.b.c',
        '01 - 🎵',
        '٠١ - Arabic digits',
      ]) {
        for (final String ext in <String>['.flac', '', '.']) {
          _expectSame('/music/A/B/$name$ext', scanRoot: '/music');
        }
      }
    });

    test('matches Dart on random files, documents and CUE tracks', () {
      final Random random = Random(41);
      for (int i = 0; i < 20000; i++) {
        final String path = _randomPath(random);
        final String? root = _pick(random, _roots);
        final LocalAudioMetadata? metadata =
            random.nextInt(3) == 0 ? null : _randomMetadata(random);
        _expectSame(path, scanRoot: root, metadata: metadata);
        _expectSameDocument(
          SafAudioDocument(
            uri: 'content://doc/$i',
            name: path.split('/').last,
            metadata: metadata,
          ),
        );
        _expectSameCue(
          _randomCue(random, path),
          metadata: metadata,
          scanRoot: root ?? '',
        );
      }
    });

    test('leaves text with an unpaired surrogate to Dart', () {
      const LocalAudioMetadata odd = LocalAudioMetadata(title: 'x\uD800');
      _expectSame('/m/A/01 - a.flac', scanRoot: '/m', metadata: odd);
      _expectSame('/m/A/01 - \uDC00.flac', scanRoot: '/m');
    });
  });
}

void _expectSame(
  String path, {
  String? scanRoot,
  LocalAudioMetadata? metadata,
}) {
  expect(
    _describe(LocalTrackMapper.fromPath(
      path,
      scanRoot: scanRoot,
      metadata: metadata,
    )),
    _describe(LocalTrackMapper.fromPathInDart(
      path,
      scanRoot: scanRoot,
      metadata: metadata,
    )),
    reason: '$path under $scanRoot with ${_tags(metadata)}',
  );
}

void _expectSameDocument(SafAudioDocument document) {
  expect(
    _describe(LocalTrackMapper.fromSafDocument(document)),
    _describe(LocalTrackMapper.fromSafDocumentInDart(document)),
    reason: '${document.name} with ${_tags(document.metadata)}',
  );
}

void _expectSameCue(
  CueSheetTrack cue, {
  LocalAudioMetadata? metadata,
  required String scanRoot,
}) {
  Track map({required bool native}) => (native
          ? LocalTrackMapper.fromCueTrack
          : LocalTrackMapper.fromCueTrackInDart)(
        cue,
        cuePath: '/music/sheet.cue',
        metadata: metadata,
        scanRoot: scanRoot,
        cueSheetSizeBytes: 10,
        cueSheetModifiedAtMs: 20,
      );
  expect(
    _describe(map(native: true)),
    _describe(map(native: false)),
    reason: '#${cue.number} ${cue.start}-${cue.end} "${cue.title}" '
        '"${cue.performer}" "${cue.album}" "${cue.albumPerformer}" '
        '${cue.audioPath} under $scanRoot with ${_tags(metadata)}',
  );
}

String _tags(LocalAudioMetadata? m) => m == null
    ? 'no tags'
    : '"${m.title}" "${m.artist}" "${m.album}" "${m.albumArtist}" '
        '"${m.albumId}" #${m.trackNumber} ${m.duration}';

List<Object?> _describe(Track t) => <Object?>[
      t.id,
      t.uri,
      t.title,
      t.artistName,
      t.albumName,
      t.albumId,
      t.albumArtistName,
      t.trackNumber,
      t.duration,
      t.cueStart,
      t.cueEnd,
      t.cueSheetSizeBytes,
      t.cueSheetModifiedAtMs,
      t.discNumber,
      t.artworkUri,
    ];

T _pick<T>(Random random, List<T> from) => from[random.nextInt(from.length)];

const List<String?> _roots = <String?>[
  '/music',
  '/music/',
  '/music//',
  '/music/./A/..',
  '/music/A',
  '/',
  '',
  null,
  'music',
  '/other',
];

const List<String> _folders = <String>[
  'A',
  'Bon Iver',
  '  Padded  ',
  ' ',
  '﻿',
  '\u0085',
  '.',
  '..',
  '',
  '中文',
  '🎵',
];

const List<String> _words = <String>[
  'Song',
  'Intro (Live)',
  '',
  ' ',
  'a\nb',
  ' ',
  ' x ',
  '\u0085',
  '中',
  '🎵',
  '-',
];

const List<String> _separators = <String>[
  ' ',
  '.',
  '_',
  '-',
  ')',
  ']',
  '\t',
  '\n',
  '\r',
  ' ',
  '\u0085',
  '﻿',
  ' ',
  '　',
  '᠎',
  'x',
];

String _randomPath(Random random) {
  final StringBuffer path = StringBuffer(
      _pick(random, <String>['/music', '/', 'music', '/other', '']));
  for (int i = 0; i < random.nextInt(4); i++) {
    path
      ..write('/')
      ..write(_pick(random, _folders));
  }
  path.write('/');
  if (random.nextBool()) {
    path.write(<String>['1', '01', '001', '0001', '٠١'][random.nextInt(5)]);
    for (int i = 0; i < random.nextInt(4); i++) {
      path.write(_pick(random, _separators));
    }
  }
  path.write(_pick(random, _words));
  if (random.nextBool()) path.write(_pick(random, _separators));
  path.write(_pick(random, <String>['.flac', '', '.', '.a.b', '/']));
  return path.toString();
}

String? _randomText(Random random) => random.nextInt(3) == 0
    ? null
    : _pick(
        random, <String>['Real', ' padded ', '', ' ', '\u0085', '﻿', 'Ünï']);

LocalAudioMetadata _randomMetadata(Random random) => LocalAudioMetadata(
      title: _randomText(random),
      artist: _randomText(random),
      album: _randomText(random),
      albumArtist: _randomText(random),
      albumId: _randomText(random),
      trackNumber: random.nextBool() ? null : random.nextInt(30) - 1,
      discNumber: random.nextBool() ? null : 2,
      duration: switch (random.nextInt(3)) {
        0 => null,
        // Whole seconds, so some land right on a CUE track's start.
        1 => Duration(seconds: random.nextInt(600)),
        _ => Duration(microseconds: random.nextInt(1 << 30)),
      },
      artworkUri: random.nextBool() ? null : Uri.parse('file:///cover.jpg'),
    );

CueSheetTrack _randomCue(Random random, String audioPath) {
  final int start = random.nextBool()
      ? random.nextInt(600) * 1000000
      : random.nextInt(600) * 1000000 + random.nextInt(1000) * 1000;
  return CueSheetTrack(
    number: random.nextInt(120) - 1,
    audioPath: audioPath,
    start: Duration(microseconds: start),
    end: switch (random.nextInt(4)) {
      0 => null,
      // Right at the start, or a microsecond either side of it.
      1 => Duration(microseconds: start + random.nextInt(3) - 1),
      _ => Duration(
          microseconds: start + random.nextInt(400000000) - 100000000,
        ),
    },
    title: _randomText(random),
    performer: _randomText(random),
    album: _randomText(random),
    albumPerformer: _randomText(random),
  );
}
