import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/text_folding.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/features/library/library_search.dart';

Track _track(
  String id, {
  String? title,
  String? artist,
  String? album,
}) =>
    Track(
      id: id,
      title: title ?? 'Track $id',
      uri: 'file:///$id.mp3',
      artistName: artist,
      albumName: album,
    );

void main() {
  group('foldText', () {
    test('lower-cases and trims', () {
      expect(foldText('  Hello World  '), 'hello world');
    });

    test('collapses internal whitespace', () {
      expect(foldText('a\t b\n c'), 'a b c');
    });

    test('strips common Latin diacritics', () {
      expect(foldText('Beyoncé'), 'beyonce');
      expect(foldText('Amélie'), 'amelie');
      expect(foldText('Mötley Crüe'), 'motley crue');
      expect(foldText('Sigur Rós'), 'sigur ros');
    });

    test('expands ligatures', () {
      expect(foldText('Straße'), 'strasse');
    });
  });

  group('filterTracks', () {
    final List<Track> tracks = <Track>[
      _track('1', title: 'Levitating', artist: 'Dua Lipa', album: 'Future'),
      _track('2', title: 'Blinding Lights', artist: 'The Weeknd'),
      _track('3', title: 'Café del Mar', artist: 'Energy 52', album: 'Ibiza'),
    ];

    test('empty query returns the same list instance', () {
      expect(filterTracks(tracks, ''), same(tracks));
      expect(filterTracks(tracks, '   '), same(tracks));
    });

    test('matches by title, case-insensitively', () {
      final List<Track> result = filterTracks(tracks, 'levit');
      expect(result.map((Track t) => t.id), <String>['1']);
    });

    test('matches by artist', () {
      final List<Track> result = filterTracks(tracks, 'weeknd');
      expect(result.map((Track t) => t.id), <String>['2']);
    });

    test('matches by album', () {
      final List<Track> result = filterTracks(tracks, 'future');
      expect(result.map((Track t) => t.id), <String>['1']);
    });

    test('matches accent-insensitively', () {
      // Typing the unaccented form still finds the accented title.
      final List<Track> result = filterTracks(tracks, 'cafe');
      expect(result.map((Track t) => t.id), <String>['3']);
    });

    test('no match yields an empty list', () {
      expect(filterTracks(tracks, 'zzz'), isEmpty);
    });
  });

  group('filterAlbums', () {
    final List<Album> albums = <Album>[
      const Album(id: 'a', title: 'Random Access Memories', artistName: 'Daft'),
      const Album(id: 'b', title: 'Discovery', artistName: 'Daft Punk'),
    ];

    test('matches by album title', () {
      expect(
        filterAlbums(albums, 'discovery').map((Album a) => a.id),
        <String>['b'],
      );
    });

    test('matches by album artist', () {
      expect(
        filterAlbums(albums, 'daft').map((Album a) => a.id),
        <String>['a', 'b'],
      );
    });
  });

  group('filterArtists', () {
    final List<Artist> artists = <Artist>[
      const Artist(id: 'a', name: 'Tame Impala'),
      const Artist(id: 'b', name: 'Glass Animals'),
    ];

    test('matches by name', () {
      expect(
        filterArtists(artists, 'tame').map((Artist a) => a.id),
        <String>['a'],
      );
    });
  });
}
