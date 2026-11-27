import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/sources/local/local_catalog_reconciliation.dart';

/// Replays test/fixtures/local_reconcile_cases.txt: the moves and removals,
/// in order, for tags that are easy to get wrong and for random libraries
/// where files stay, move and turn up. The answers were recorded from the
/// Dart rules the Rust ones replaced. A change here either hands one song's
/// play count and heart to another, or forgets a move and drops the history
/// it should have kept.
void main() {
  test('libraries reconcile to the recorded moves and removals', () {
    final List<String> lines =
        File('test/fixtures/local_reconcile_cases.txt').readAsLinesSync();
    expect(lines, hasLength(greaterThan(100)));
    for (final String line in lines) {
      final Map<String, Object?> c = jsonDecode(line) as Map<String, Object?>;
      final Set<String> unread =
          (c['unread']! as List<Object?>).cast<String>().toSet();
      final LocalCatalogReconciliation result =
          LocalCatalogReconciliation.resolve(
        previous: _tracks(c['previous']),
        scanned: _tracks(c['scanned']),
        wasRefreshed: (String uri) => !unread.contains(uri),
      );
      expect(
        <List<String>>[
          for (final LocalTrackMove m in result.moves) <String>[m.from, m.to],
        ],
        c['moves'],
        reason: line,
      );
      expect(result.removedUris, c['removed'], reason: line);
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

  test('keeps two different malformed titles apart', () {
    // Both would read as U+FFFD: they must not look like one file.
    final LocalCatalogReconciliation result =
        LocalCatalogReconciliation.resolve(
      previous: <Track>[
        _track('/a/1.flac', 'x\uD800'),
        _track('/a/2.flac', 'x\uDC00'),
      ],
      scanned: <Track>[_track('/b/1.flac', 'x\uD800')],
      wasRefreshed: (String uri) => true,
    );
    expect(result.moves, <LocalTrackMove>[
      const LocalTrackMove(from: '/a/1.flac', to: '/b/1.flac'),
    ]);
    expect(result.removedUris, <String>['/a/2.flac']);
  });
}

List<Track> _tracks(Object? json) => <Track>[
      for (final Object? t in json! as List<Object?>)
        _fromJson(t! as List<Object?>),
    ];

Track _fromJson(List<Object?> f) => _track(
      f[0]! as String,
      f[1]! as String,
      artist: f[2] as String?,
      album: f[3] as String?,
      albumArtist: f[4] as String?,
      albumId: f[5] as String?,
      micros: f[6]! as int,
      number: f[7] as int?,
    );

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
