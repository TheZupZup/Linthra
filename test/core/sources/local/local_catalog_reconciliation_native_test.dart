import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';

/// The Rust reconciliation has to give exactly what the Dart rules give: the
/// same moves and the same removals, in the same order. A drift either hands
/// one song's play count and heart to another, or forgets a move and drops
/// the history it should have kept.
///
/// Runs through the real Rust library hook/build.dart builds for the test
/// host, and is skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead).
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  group('native local reconciliation', skip: skip, () {
    test('matches Dart on tags that are easy to get wrong', () {
      final List<Track> previous = <Track>[
        for (int i = 0; i < _trickyTitles.length; i++)
          _track('/old/$i.flac', _trickyTitles[i], micros: 180000000 + i % 3),
      ];
      final List<Track> scanned = <Track>[
        for (int i = 0; i < _trickyTitles.length; i++)
          _track(
            '/new/$i.flac',
            _trickyTitles[(i * 7) % _trickyTitles.length],
            micros: 180000000 + i % 2,
          ),
      ];
      _expectSameAsDart(previous, scanned, (String uri) => true);
    });

    test('matches Dart on random libraries', () {
      for (int seed = 0; seed < 400; seed++) {
        final Random random = Random(seed);
        final List<Track> previous = _randomLibrary(random, 'a');
        final List<Track> scanned = <Track>[
          // Some files stay, some move, some are new.
          for (final Track t in previous)
            if (random.nextInt(3) == 0) t,
          ..._randomLibrary(random, 'b'),
        ];
        final Set<String> unread = <String>{
          for (final Track t in previous)
            if (random.nextInt(5) == 0) t.uri,
        };
        _expectSameAsDart(
          previous,
          scanned,
          (String uri) => !unread.contains(uri),
        );
      }
    });

    test('moves a re-cased, re-padded file and keeps the rest', () {
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: <Track>[
          _track('/a/1.flac', 'Flume', artist: 'Bon Iver'),
          _track('/a/2.flac', 'Skinny Love', artist: 'Bon Iver'),
        ],
        scanned: <Track>[
          _track('/b/1.flac', '  FLUME ', artist: 'bon  iver'),
        ],
        wasRefreshed: (String uri) => true,
      );
      expect(result.moves, <LocalTrackMove>[
        const LocalTrackMove(from: '/a/1.flac', to: '/b/1.flac'),
      ]);
      expect(result.removedUris, <String>['/a/2.flac']);
    });

    test('leaves text with an unpaired surrogate to Dart', () {
      _expectSameAsDart(
        <Track>[
          _track('/a/1.flac', 'x\uD800'),
          _track('/a/2.flac', 'x\uDC00'),
        ],
        <Track>[_track('/b/1.flac', 'x\uD800')],
        (String uri) => true,
      );
    });
  });
}

/// Case, whitespace and separators where Dart's `toLowerCase`, `trim` and
/// `RegExp(r'\s+')` each have their own idea of what counts.
const List<String> _trickyTitles = <String>[
  'Flume',
  'flume',
  ' FLUME\t',
  'Flu  me',
  'Flu me',
  'Flu\u0085me',
  '\u0085Flume\u0085',
  '﻿Flume',
  'Flu　me',
  'İstanbul',
  'i̇stanbul',
  'ΣΟΦΟΣ',
  'σοφος',
  'σοφοσ',
  'STRASSE',
  'ẞtraße',
  'a\u0000b',
  'a',
  '',
  '   ',
  ' ',
  'Kelvin K',
  'kelvin k',
];

Track _track(
  String uri,
  String title, {
  String? artist = 'Artist',
  String? album = 'Album',
  String? albumArtist,
  String? albumId,
  int micros = 180000000,
  int? number = 1,
}) =>
    Track(
      id: uri,
      title: title,
      uri: uri,
      artistName: artist,
      albumName: album,
      albumArtistName: albumArtist,
      albumId: albumId,
      duration: Duration(microseconds: micros),
      trackNumber: number,
    );

List<Track> _randomLibrary(Random random, String folder) {
  const List<String> words = <String>[
    'Song',
    'song',
    ' SONG ',
    'So  ng',
    'So ng',
    'Café',
    'CAFÉ',
    '',
  ];
  const List<int> micros = <int>[0, -5, 999, 1000, 1999, 180000000, 180000999];
  final int count = random.nextInt(40);
  return <Track>[
    for (int i = 0; i < count; i++)
      _track(
        // Few names, so uris repeat within and across the lists.
        '/$folder/${random.nextInt(count + 3)}.flac',
        words[random.nextInt(words.length)],
        artist: random.nextInt(6) == 0 ? null : words[random.nextInt(4)],
        album: random.nextInt(6) == 0 ? null : 'Album ${random.nextInt(2)}',
        albumArtist: random.nextBool() ? null : 'VA',
        albumId: random.nextInt(4) == 0 ? 'ID${random.nextInt(2)}' : null,
        micros: micros[random.nextInt(micros.length)],
        number: random.nextBool() ? null : random.nextInt(3) - 1,
      ),
  ];
}

void _expectSameAsDart(
  List<Track> previous,
  List<Track> scanned,
  bool Function(String uri) wasRefreshed,
) {
  final LocalCatalogReconciliation dart =
      LocalCatalogReconciliation.resolveInDart(
    previous: previous,
    scanned: scanned,
    wasRefreshed: wasRefreshed,
  );
  final LocalCatalogReconciliation rust = LocalCatalogReconciliation.resolve(
    previous: previous,
    scanned: scanned,
    wasRefreshed: wasRefreshed,
  );
  expect(rust.moves, dart.moves);
  expect(rust.removedUris, dart.removedUris);
}
