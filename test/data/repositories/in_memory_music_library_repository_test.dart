import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';

Track _track(String id) => Track(id: id, title: 'Track $id', uri: id);

Album _album(String id) => Album(id: id, title: 'Album $id');

Artist _artist(String id) => Artist(id: id, name: 'Artist $id');

void main() {
  group('InMemoryMusicLibraryRepository', () {
    late InMemoryMusicLibraryRepository repository;

    setUp(() {
      repository = InMemoryMusicLibraryRepository();
    });

    test('starts empty', () async {
      expect(await repository.getAllTracks(), isEmpty);
      expect(await repository.getAllAlbums(), isEmpty);
      expect(await repository.getAllArtists(), isEmpty);
    });

    test('upsertCatalog stores tracks', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('a'), _track('b')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(await repository.getAllTracks(), hasLength(2));
    });

    test('getAllTracks returns the stored tracks', () async {
      final List<Track> stored = <Track>[_track('a'), _track('b')];
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: stored,
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(await repository.getAllTracks(), stored);
    });

    test('getAllAlbums and getAllArtists return stored items', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: const <Track>[],
        albums: <Album>[_album('a')],
        artists: <Artist>[_artist('a')],
      );

      expect(await repository.getAllAlbums(), <Album>[_album('a')]);
      expect(await repository.getAllArtists(), <Artist>[_artist('a')]);
    });

    test('getTrackById returns a match, or null if absent', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('a'), _track('b')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(await repository.getTrackById('b'), _track('b'));
      expect(await repository.getTrackById('missing'), isNull);
    });

    test('second upsert for a source replaces its tracks', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('old')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('new')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(await repository.getAllTracks(), <Track>[_track('new')]);
      expect(await repository.getTrackById('old'), isNull);
    });

    test('upserting another source keeps existing tracks', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('local-1')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await repository.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: <Track>[_track('jellyfin-1')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));
      expect(all, contains(_track('local-1')));
      expect(all, contains(_track('jellyfin-1')));
    });
  });
}
