// The Songs list's order and sections are the same in Dart and in the Rust
// core (native/linthra_core/src/song_sort.rs), for every order, on catalogs
// built to hit each rule: accents and case, titles that don't start with a
// letter, songs missing what they are sorted by, albums sharing a name, discs
// and tracks, and a search sorted against the whole catalog.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/features/library/song_sort.dart';

List<Track> _catalog(int size, int seed) {
  final Random random = Random(seed);
  const List<String> titles = <String>[
    'Alpha',
    'alpha',
    'Été',
    'ete',
    '  Zebra',
    '1999',
    '#hash',
    '😀 smile',
    'Ünïcode',
    'Çava',
    'Straße',
    'beta',
    'Beta',
    '',
    'Œuvre',
  ];
  const List<String?> artists = <String?>[
    'Édith Piaf',
    'edith piaf',
    'ABBA',
    'Abba',
    null,
    '',
    '  ',
    'Кино',
    'The Band',
    '2Pac',
  ];
  const List<String?> albums = <String?>[
    'Weezer',
    'Greatest Hits',
    null,
    'Album',
    'Été',
    '1',
    '',
  ];
  return <Track>[
    for (int i = 0; i < size; i++)
      Track(
        id: '$i',
        title: '${titles[random.nextInt(titles.length)]}'
            '${random.nextBool() ? ' $i' : ''}',
        uri: '${random.nextBool() ? 'jellyfin' : 'subsonic'}:$i',
        artistName: artists[random.nextInt(artists.length)],
        albumName: albums[random.nextInt(albums.length)],
        albumArtistName: random.nextInt(4) == 0 ? 'Various Artists' : null,
        albumId: random.nextInt(3) == 0 ? 'album-${random.nextInt(5)}' : null,
        discNumber: random.nextInt(3) == 0 ? 1 + random.nextInt(2) : null,
        trackNumber: random.nextInt(4) == 0 ? null : 1 + random.nextInt(12),
      ),
  ];
}

String _describe(SortedSongs sorted) => <String>[
      for (int i = 0; i < sorted.tracks.length; i++)
        '${sorted.sections?[i] ?? '-'} ${sorted.tracks[i].uri}',
    ].join('\n');

void main() {
  test('Rust and Dart sort every catalog the same way, in every order',
      skip: LinthraCore.isAvailable ? false : 'Rust core not built', () {
    for (int seed = 0; seed < 4; seed++) {
      final List<Track> catalog = _catalog(600, seed);
      final Random random = Random(seed);
      final Map<String, DateTime> addedAt = <String, DateTime>{
        for (final Track t in catalog)
          if (random.nextInt(5) != 0)
            t.uri: DateTime.utc(2026).add(Duration(hours: random.nextInt(50))),
      };
      // A search: a part of the catalog, sorted against all of it.
      final List<Track> search = <Track>[
        for (final Track t in catalog)
          if (random.nextInt(3) == 0) t,
      ];
      for (final SongSort sort in SongSort.values) {
        for (final (List<Track> tracks, SongAlbums? albums)
            in <(List<Track>, SongAlbums?)>[
          (catalog, null),
          (search, SongAlbums.of(catalog)),
        ]) {
          final SortedSongs rust =
              sortSongs(tracks, sort, addedAt: addedAt, albums: albums);
          final SortedSongs dart = sortSongs(tracks, sort,
              addedAt: addedAt, albums: albums, useNative: false);
          expect(_describe(rust), _describe(dart),
              reason:
                  'seed $seed, $sort, ${albums == null ? 'catalog' : 'search'}');
        }
      }
    }
  });
}
