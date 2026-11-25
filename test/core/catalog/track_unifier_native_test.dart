// Merging one song's copies from different servers gives the same library
// rows in Dart and in the Rust core (native/linthra_core/src/track_unifier.rs),
// and songs tagged in any script merge (#877).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/logical_track.dart';
import 'package:linthra/core/catalog/source_priority.dart';
import 'package:linthra/core/catalog/track_unifier.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';

const List<String> _schemes = <String>['jellyfin', 'subsonic', 'plex'];

/// Every row as the uris of its copies, in order.
List<String> _rows(List<LogicalTrack> rows) => <String>[
      for (final LogicalTrack row in rows)
        row.candidates.map((c) => c.track.uri).join(' + '),
    ];

/// A catalog where most songs sit on two or three servers, each copy drifting
/// the ways real servers drift, among songs that must stay apart.
List<Track> _catalog(int songs, int seed) {
  final Random random = Random(seed);
  const List<(String, String, String)> base = <(String, String, String)>[
    ('Careful', 'NF', 'Hope'),
    ('Hello', 'Adele', '25'),
    ('Группа крови', 'Кино', 'Группа крови'),
    ('夜に駆ける', 'YOASOBI', 'THE BOOK'),
    ('ΟΔΟΣ', 'ΣΩΚΡΑΤΗΣ', 'ΑΠΟΣ'),
    ('Café del Mar', 'Energy 52', 'Café del Mar'),
    ('Song', 'Hall & Oates', 'Album'),
    ('', 'Nobody', 'Untagged'),
  ];
  String drift(String title) => switch (random.nextInt(7)) {
        0 => '$title (feat. Someone)',
        1 => '$title feat. Someone',
        2 => '$title (Live)',
        3 => title.toUpperCase(),
        4 => '$title [FT. X] (Remix)',
        _ => title,
      };
  final List<Track> tracks = <Track>[];
  for (int s = 0; s < songs; s++) {
    final (String title, String artist, String album) = base[s % base.length];
    final int copies = 1 + random.nextInt(3);
    for (int c = 0; c < copies; c++) {
      final String scheme = _schemes[(s + c) % _schemes.length];
      tracks.add(Track(
        id: '$s-$c',
        title: c == 0 ? '$title $s' : drift('$title $s'),
        uri: '$scheme:$s-$c',
        artistName: random.nextInt(5) == 0 ? '$artist, Guest' : artist,
        albumName: random.nextInt(5) == 0 ? '$album (Deluxe)' : album,
        duration: Duration(seconds: 200 + random.nextInt(4)),
        trackNumber: random.nextInt(4) == 0 ? null : 1 + random.nextInt(2),
      ));
    }
  }
  tracks.shuffle(random);
  return tracks;
}

void main() {
  final Object skip =
      LinthraCore.isAvailable ? false : 'Rust core not built in this build';
  const SourcePriority priority =
      SourcePriority(<String>['jellyfin', 'subsonic', 'plex']);

  test('the Rust core and Dart build the same library rows', skip: skip, () {
    for (int seed = 0; seed < 5; seed++) {
      final List<Track> catalog = _catalog(400, seed);
      final List<String> rust = _rows(unifyTracks(catalog, priority));
      final List<String> dart =
          _rows(unifyTracks(catalog, priority, useNative: false));
      expect(rust, dart, reason: 'seed $seed');
      // Something merged, and something stayed apart.
      expect(rust.length, lessThan(catalog.length));
      expect(rust.length, greaterThan(400 ~/ 4));
    }
  });

  for (final bool useNative in <bool>[false, true]) {
    test(
        '#877: songs tagged in any script merge (${useNative ? 'Rust' : 'Dart'})',
        skip: useNative ? skip : false, () {
      Track copy(String scheme, String title, String artist, String album) =>
          Track(
            id: '$scheme-$title',
            title: title,
            uri: '$scheme:$title',
            artistName: artist,
            albumName: album,
            duration: const Duration(seconds: 250),
          );
      final List<LogicalTrack> rows = unifyTracks(<Track>[
        copy('jellyfin', 'Группа крови', 'Кино', 'Группа крови'),
        copy('subsonic', 'Группа крови', 'Кино', 'Группа крови'),
        copy('jellyfin', '夜に駆ける', 'YOASOBI', 'THE BOOK'),
        copy('subsonic', '夜に駆ける', 'YOASOBI', 'THE BOOK'),
        // One server upper-cases its tags: a final sigma either way.
        copy('jellyfin', 'Οδός', 'Σωκράτης', 'Άλμπουμ'),
        copy('subsonic', 'ΟΔΌΣ', 'ΣΩΚΡΆΤΗΣ', 'ΆΛΜΠΟΥΜ'),
      ], priority, useNative: useNative);

      expect(rows, hasLength(3));
      for (final LogicalTrack row in rows) {
        expect(row.candidates, hasLength(2));
      }
    });
  }
}
