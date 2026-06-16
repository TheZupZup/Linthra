import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';

Track _track(String id, {int durationMs = 0, String? artworkUri}) => Track(
      id: id,
      title: 'Track $id',
      uri: 'file:///$id.flac',
      artistName: 'Artist $id',
      albumName: 'Album $id',
      duration: Duration(milliseconds: durationMs),
      trackNumber: 1,
      artworkUri: artworkUri == null ? null : Uri.parse(artworkUri),
    );

void main() {
  group('DriftMusicLibraryRepository', () {
    late LinthraDatabase db;
    late DriftMusicLibraryRepository repository;

    setUp(() {
      db = LinthraDatabase.forTesting(NativeDatabase.memory());
      repository = DriftMusicLibraryRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('starts empty', () async {
      expect(await repository.getAllTracks(), isEmpty);
      expect(await repository.getAllAlbums(), isEmpty);
      expect(await repository.getAllArtists(), isEmpty);
    });

    test('upsertCatalog persists tracks that getAllTracks returns', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('a'), _track('b')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));
      expect(all.map((Track t) => t.id), containsAll(<String>['a', 'b']));
    });

    test('round-trips duration and artwork through the mappers', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[
          _track('a', durationMs: 187000, artworkUri: 'file:///art/a.jpg'),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final Track? track = await repository.getTrackById('a');
      expect(track, isNotNull);
      expect(track!.duration, const Duration(milliseconds: 187000));
      expect(track.artworkUri, Uri.parse('file:///art/a.jpg'));
      expect(track.artistName, 'Artist a');
      expect(track.albumName, 'Album a');
      expect(track.trackNumber, 1);
    });

    test('getTrackById returns null when absent', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('a')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

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

      final List<Track> all = await repository.getAllTracks();
      expect(all.map((Track t) => t.id), <String>['new']);
      expect(await repository.getTrackById('old'), isNull);
    });

    test('upserting another source leaves existing tracks intact', () async {
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
      expect(
        all.map((Track t) => t.id),
        containsAll(<String>['local-1', 'jellyfin-1']),
      );
    });

    test(
        'upsertCatalog with a duplicate track id collapses to one row '
        '(idempotent, last wins) instead of failing the sync', () async {
      // A duplicate stable id within one sync (e.g. a Subsonic album fetched
      // twice across shifting pagination) must not raise a UNIQUE-constraint
      // error and roll back the whole catalog.
      await repository.upsertCatalog(
        sourceId: 'subsonic',
        tracks: <Track>[
          _track('dup', durationMs: 1000),
          _track('other'),
          _track('dup', durationMs: 2000),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));
      expect(all.map((Track t) => t.id), containsAll(<String>['dup', 'other']));
      final Track? dup = await repository.getTrackById('dup');
      expect(dup, isNotNull);
      expect(dup!.duration, const Duration(milliseconds: 2000));
    });

    test('incremental append tolerates a duplicate id across batches',
        () async {
      // The Plex incremental path writes in batches; the same id can appear in
      // two batches. The second append must not fail on a UNIQUE constraint.
      await repository.beginCatalogReplacement(
        sourceId: 'plex',
        tracks: <Track>[_track('a'), _track('shared', durationMs: 1000)],
      );
      await repository.appendToCatalog(
        sourceId: 'plex',
        tracks: <Track>[_track('b'), _track('shared', durationMs: 2000)],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(3));
      expect(
        all.map((Track t) => t.id),
        containsAll(<String>['a', 'b', 'shared']),
      );
      final Track? shared = await repository.getTrackById('shared');
      expect(shared, isNotNull);
      expect(shared!.duration, const Duration(milliseconds: 2000));
    });
  });
}
