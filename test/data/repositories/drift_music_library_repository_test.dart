import 'dart:io';

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

/// A track with an explicit provider-namespaced [uri] but a caller-chosen bare
/// [id], so a test can give two providers the *same* server-side id.
Track _providerTrack(
  String uri, {
  required String id,
  int durationMs = 0,
  String? artworkUri,
}) =>
    Track(
      id: id,
      title: 'Track $uri',
      uri: uri,
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

      final Track? track = await repository.getTrackByUri('file:///a.flac');
      expect(track, isNotNull);
      expect(track!.duration, const Duration(milliseconds: 187000));
      expect(track.artworkUri, Uri.parse('file:///art/a.jpg'));
      expect(track.artistName, 'Artist a');
      expect(track.albumName, 'Album a');
      expect(track.trackNumber, 1);
    });

    test('getTrackByUri returns null when absent', () async {
      await repository.upsertCatalog(
        sourceId: 'local',
        tracks: <Track>[_track('a')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(await repository.getTrackByUri('file:///missing.flac'), isNull);
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
      expect(await repository.getTrackByUri('file:///old.flac'), isNull);
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
      final Track? dup = await repository.getTrackByUri('file:///dup.flac');
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
      final Track? shared =
          await repository.getTrackByUri('file:///shared.flac');
      expect(shared, isNotNull);
      expect(shared!.duration, const Duration(milliseconds: 2000));
    });

    test(
        'a Jellyfin and a Plex track that share a server-side id both survive '
        'a sync (no cross-provider overwrite)', () async {
      // The bug this fixes: the catalog was keyed by the bare server-side id, so
      // `insertOrReplace` let the second provider's row clobber the first.
      await repository.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: <Track>[
          _providerTrack('jellyfin:101', id: '101', durationMs: 1000),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await repository.upsertCatalog(
        sourceId: 'plex',
        tracks: <Track>[
          _providerTrack('plex:101', id: '101', durationMs: 2000),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));
      expect(
        all.map((Track t) => t.uri),
        containsAll(<String>['jellyfin:101', 'plex:101']),
      );
      // Each copy keeps its own metadata — neither overwrote the other.
      expect((await repository.getTrackByUri('jellyfin:101'))!.duration,
          const Duration(milliseconds: 1000));
      expect((await repository.getTrackByUri('plex:101'))!.duration,
          const Duration(milliseconds: 2000));
    });

    test(
        'a Jellyfin and a Navidrome/Subsonic track that share a server-side id '
        'both survive a sync', () async {
      await repository.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: <Track>[_providerTrack('jellyfin:101', id: '101')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await repository.upsertCatalog(
        sourceId: 'subsonic',
        tracks: <Track>[_providerTrack('subsonic:101', id: '101')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));
      expect(
        all.map((Track t) => t.uri),
        containsAll(<String>['jellyfin:101', 'subsonic:101']),
      );
    });

    test('removeTracks deletes by uri, sparing another provider\'s same id',
        () async {
      await repository.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: <Track>[_providerTrack('jellyfin:101', id: '101')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await repository.upsertCatalog(
        sourceId: 'subsonic',
        tracks: <Track>[_providerTrack('subsonic:101', id: '101')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      await repository.removeTracks(<String>['jellyfin:101']);

      final List<Track> all = await repository.getAllTracks();
      expect(all.map((Track t) => t.uri), <String>['subsonic:101']);
    });
  });

  group('LinthraDatabase v1 -> v2 migration (tracks re-keyed id -> uri)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('linthra_migration_test');
      dbFile = File('${tempDir.path}/linthra.sqlite');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// Builds the v1-shaped `tracks` table (primary key on the bare `id`) on
    /// [dbFile], seeds it with [rows], and stamps `user_version = 1` so the next
    /// open of [LinthraDatabase] (schemaVersion 2) runs the real upgrade.
    Future<void> seedV1(List<Map<String, Object?>> rows) async {
      final LinthraDatabase setup =
          LinthraDatabase.forTesting(NativeDatabase(dbFile));
      await setup.customStatement('DROP TABLE tracks;');
      await setup.customStatement(
        'CREATE TABLE tracks ('
        'id TEXT NOT NULL, source_id TEXT NOT NULL, title TEXT NOT NULL, '
        'uri TEXT NOT NULL, artist_name TEXT, album_name TEXT, '
        'duration_ms INTEGER NOT NULL DEFAULT 0, track_number INTEGER, '
        'artwork_uri TEXT, PRIMARY KEY (id));',
      );
      for (final Map<String, Object?> r in rows) {
        await setup.customStatement(
          'INSERT INTO tracks (id, source_id, title, uri, artist_name, '
          'album_name, duration_ms, track_number, artwork_uri) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
          <Object?>[
            r['id'],
            r['source_id'],
            r['title'],
            r['uri'],
            r['artist_name'],
            r['album_name'],
            r['duration_ms'],
            r['track_number'],
            r['artwork_uri'],
          ],
        );
      }
      await setup.customStatement('PRAGMA user_version = 1;');
      await setup.close();
    }

    test('preserves every existing row, re-keyed on uri', () async {
      await seedV1(<Map<String, Object?>>[
        <String, Object?>{
          'id': '101',
          'source_id': 'jellyfin',
          'title': 'J Song',
          'uri': 'jellyfin:101',
          'artist_name': 'Adele',
          'album_name': '25',
          'duration_ms': 187000,
          'track_number': 3,
          'artwork_uri': 'https://art/1.jpg',
        },
        <String, Object?>{
          'id': '7',
          'source_id': 'local',
          'title': 'L Song',
          'uri': 'file:///7.flac',
          'artist_name': null,
          'album_name': null,
          'duration_ms': 0,
          'track_number': null,
          'artwork_uri': null,
        },
      ]);

      // Opening at schemaVersion 2 over a user_version-1 file runs the upgrade.
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);
      final repository = DriftMusicLibraryRepository(db);

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));

      final Track? j = await repository.getTrackByUri('jellyfin:101');
      expect(j, isNotNull);
      expect(j!.id, '101');
      expect(j.title, 'J Song');
      expect(j.duration, const Duration(milliseconds: 187000));
      expect(j.trackNumber, 3);
      expect(j.artworkUri, Uri.parse('https://art/1.jpg'));

      final Track? local = await repository.getTrackByUri('file:///7.flac');
      expect(local, isNotNull);
      expect(local!.title, 'L Song');
      expect(local.artistName, isNull);
    });

    test('after upgrade a same-id row from another provider can coexist',
        () async {
      await seedV1(<Map<String, Object?>>[
        <String, Object?>{
          'id': '101',
          'source_id': 'jellyfin',
          'title': 'J Song',
          'uri': 'jellyfin:101',
          'artist_name': 'Adele',
          'album_name': '25',
          'duration_ms': 1000,
          'track_number': 1,
          'artwork_uri': null,
        },
      ]);

      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);
      final repository = DriftMusicLibraryRepository(db);

      // The migrated Jellyfin 101 and a freshly-synced Plex 101 coexist.
      await repository.upsertCatalog(
        sourceId: 'plex',
        tracks: <Track>[_providerTrack('plex:101', id: '101')],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      final List<Track> all = await repository.getAllTracks();
      expect(all, hasLength(2));
      expect(
        all.map((Track t) => t.uri),
        containsAll(<String>['jellyfin:101', 'plex:101']),
      );
    });
  });
}
