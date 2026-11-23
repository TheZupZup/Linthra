import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/features/library/library_search.dart';
import 'package:linthra/features/library/song_search_index.dart';
import 'package:linthra/features/library/unified_library_providers.dart';

const List<String> _artists = <String>[
  'Björk',
  'Metallica',
  'Motörhead',
  'Daft Punk',
  'Sigur Rós',
  'The Weeknd',
  '久石 譲',
];

/// A catalog big enough to be indexed, with accents, shared words and
/// tracks without an album or an artist.
List<Track> _catalog(int count) => List<Track>.generate(
      count,
      (int i) => Track(
        id: 't$i',
        uri: 'file:///t$i.mp3',
        title: i.isEven ? 'Track $i Midnight Signal' : 'Song $i — Café',
        artistName: i % 11 == 0 ? null : _artists[i % _artists.length],
        albumName: i % 13 == 0 ? null : 'Album ${i % 40}',
        albumArtistName:
            i % 5 == 0 ? _artists[(i + 1) % _artists.length] : null,
      ),
      growable: false,
    );

const List<String> _queries = <String>[
  '',
  '   ',
  'm',
  'midnight',
  'signal midnight',
  'track 12',
  'song 1999',
  'cafe',
  'café song',
  'bjork',
  'BJÖRK album 3',
  'metal',
  'daft punk',
  'punk daft',
  'ros',
  '久石',
  'weeknd',
  'eeknd',
  'album 3 metallica',
  '!!!',
  'zzzz',
];

void main() {
  final List<Track> catalog = _catalog(2500);

  for (final bool useRustCore in <bool>[true, false]) {
    final String which = useRustCore ? 'Rust core' : 'Dart fallback';
    group('SongSearchIndex with the $which', () {
      late SongSearchIndex index;

      setUpAll(() async {
        index = await buildSongSearchIndex(catalog, useRustCore: useRustCore);
      });
      tearDownAll(() => index.dispose());

      test('finds exactly what filterTracks finds, in catalog order', () {
        for (final String query in _queries) {
          expect(
            index.filter(query).map((Track t) => t.id).toList(),
            filterTracks(catalog, query).map((Track t) => t.id).toList(),
            reason: 'query "$query"',
          );
        }
      });

      test('a blank query keeps the very same list', () {
        expect(index.filter(''), same(catalog));
      });
    },
        skip: useRustCore && !LinthraCore.isAvailable
            ? 'Rust core not built in this environment'
            : false);
  }

  group('searchSongs', () {
    test('answers from the index built from this exact list', () async {
      final SongSearchIndex index =
          await buildSongSearchIndex(catalog, useRustCore: false);
      addTearDown(index.dispose);
      expect(
        searchSongs(catalog, 'bjork', index).map((Track t) => t.id),
        filterTracks(catalog, 'bjork').map((Track t) => t.id),
      );
    });

    test('filters directly when the index is for another list', () async {
      final SongSearchIndex index =
          await buildSongSearchIndex(catalog, useRustCore: false);
      addTearDown(index.dispose);
      final List<Track> newer = <Track>[
        ...catalog,
        const Track(id: 'new', uri: 'file:///new.mp3', title: 'Brand New'),
      ];
      expect(
        searchSongs(newer, 'brand', index).map((Track t) => t.id),
        <String>['new'],
      );
    });

    test('filters directly without an index', () {
      expect(searchSongs(catalog, 'zzzz', null), isEmpty);
    });
  });

  group('songSearchIndexProvider', () {
    ProviderContainer containerWith(List<Track> tracks) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          libraryUnifiedTracksProvider.overrideWithValue(tracks),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('builds no index for a small catalog', () async {
      final ProviderContainer container = containerWith(
        _catalog(kIndexedSongSearchMinimum - 1),
      );
      expect(await container.read(songSearchIndexProvider.future), isNull);
    });

    test('indexes a large catalog, for that exact list', () async {
      final ProviderContainer container = containerWith(catalog);
      final SongSearchIndex? index =
          await container.read(songSearchIndexProvider.future);
      expect(index, isNotNull);
      expect(index!.tracks, same(catalog));
      expect(
        index.filter('bjork').map((Track t) => t.id),
        filterTracks(catalog, 'bjork').map((Track t) => t.id),
      );
    });
  });
}
