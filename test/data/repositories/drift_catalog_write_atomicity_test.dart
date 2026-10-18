// A catalog write that SQLite refuses part way must leave the catalog as it
// was.
//
// Every source re-sync replaces that source's slice: delete the old rows,
// insert the new ones. Run as two separate writes, an insert that fails after
// the delete (a full disk, an I/O error) would leave the source with no tracks
// at all, or with half of the new batch, until the next successful sync. The
// sync controllers' tests only assume the repository rolls back, with fakes;
// these stage the failure in real SQLite, with a trigger that refuses one row
// the way the disk would, and check what is left afterwards.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/local_file_stamp.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';

Track _track(String uri, {int durationMs = 1000}) => Track(
      id: uri.substring(uri.indexOf(':') + 1),
      title: 'Track $uri',
      uri: uri,
      duration: Duration(milliseconds: durationMs),
    );

StampedTrack _stamped(String uri, {required int size, required int mtime}) =>
    StampedTrack(
      track: _track(uri),
      stamp: LocalFileStamp(sizeBytes: size, modifiedAtMs: mtime),
    );

/// The error the trigger raises, so a test can tell it from any other.
final Matcher _throwsInjectedFailure = throwsA(
  predicate<Object>(
    (Object error) => error.toString().contains('disk I/O error'),
    'the injected disk I/O error',
  ),
);

void main() {
  late LinthraDatabase db;
  late DriftMusicLibraryRepository repository;

  setUp(() {
    db = LinthraDatabase.forTesting(NativeDatabase.memory());
    repository = DriftMusicLibraryRepository(db);
  });

  tearDown(() => db.close());

  /// Has SQLite refuse the insert of [uri] mid-statement, the way a full disk
  /// or an I/O error refuses one row of a batch.
  Future<void> failInsertOf(String uri) => db.customStatement(
        'CREATE TRIGGER fail_insert BEFORE INSERT ON tracks '
        "WHEN NEW.uri = '$uri' "
        "BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END;",
      );

  Future<void> diskRecovers() =>
      db.customStatement('DROP TRIGGER fail_insert;');

  /// Each stored row of [sourceId] by uri, with its duration, so a rolled-back
  /// update is caught as well as a missing or extra row.
  Future<Map<String, Duration>> slice(String sourceId) async =>
      <String, Duration>{
        for (final Track t in await repository.getTracksForSource(sourceId))
          t.uri: t.duration,
      };

  Future<void> upsert(String sourceId, List<Track> tracks) =>
      repository.upsertCatalog(
        sourceId: sourceId,
        tracks: tracks,
        albums: const <Album>[],
        artists: const <Artist>[],
      );

  /// A Jellyfin slice {a, b} beside a Plex one the failure must not touch.
  Future<void> seedTwoSources() async {
    await upsert('jellyfin', <Track>[
      _track('jellyfin:a', durationMs: 1000),
      _track('jellyfin:b', durationMs: 2000),
    ]);
    await upsert('plex', <Track>[_track('plex:p', durationMs: 3000)]);
  }

  const Map<String, Duration> jellyfinBefore = <String, Duration>{
    'jellyfin:a': Duration(milliseconds: 1000),
    'jellyfin:b': Duration(milliseconds: 2000),
  };
  const Map<String, Duration> plexBefore = <String, Duration>{
    'plex:p': Duration(milliseconds: 3000),
  };

  group('a slice replacement that fails part way', () {
    test('upsertCatalog keeps the previous slice and leaves others alone',
        () async {
      await seedTwoSources();
      await failInsertOf('jellyfin:boom');

      await expectLater(
        upsert('jellyfin', <Track>[
          _track('jellyfin:c'),
          _track('jellyfin:boom'),
          _track('jellyfin:d'),
        ]),
        _throwsInjectedFailure,
      );

      expect(await slice('jellyfin'), jellyfinBefore);
      expect(await slice('plex'), plexBefore);
      expect(await repository.countTracks(), 3);
    });

    test('upsertStampedCatalog keeps the previous rows and their stamps',
        () async {
      await repository.upsertStampedCatalog(
        sourceId: 'local',
        tracks: <StampedTrack>[
          _stamped('file:///a.flac', size: 100, mtime: 1700000000000),
          _stamped('file:///b.flac', size: 200, mtime: 1700000001000),
        ],
      );
      await upsert('plex', <Track>[_track('plex:p', durationMs: 3000)]);
      final List<StampedTrack> before =
          await repository.getStampedTracksForSource('local');
      expect(before, hasLength(2));
      expect(
        <LocalFileStamp?>[for (final StampedTrack t in before) t.stamp],
        everyElement(isNotNull),
      );
      await failInsertOf('file:///boom.flac');

      await expectLater(
        repository.upsertStampedCatalog(
          sourceId: 'local',
          tracks: <StampedTrack>[
            _stamped('file:///c.flac', size: 300, mtime: 1700000002000),
            _stamped('file:///boom.flac', size: 1, mtime: 1),
            _stamped('file:///d.flac', size: 400, mtime: 1700000003000),
          ],
        ),
        _throwsInjectedFailure,
      );

      // A lost stamp would only cost a re-parse; a lost row costs the track.
      // Both must come back exactly as they were.
      expect(
        await repository.getStampedTracksForSource('local'),
        unorderedEquals(before),
      );
      expect(await slice('plex'), plexBefore);
    });

    test('beginCatalogReplacement keeps the previous slice', () async {
      await seedTwoSources();
      await failInsertOf('jellyfin:boom');

      await expectLater(
        repository.beginCatalogReplacement(
          sourceId: 'jellyfin',
          tracks: <Track>[
            _track('jellyfin:c'),
            _track('jellyfin:boom'),
            _track('jellyfin:d'),
          ],
        ),
        _throwsInjectedFailure,
      );

      expect(await slice('jellyfin'), jellyfinBefore);
      expect(await slice('plex'), plexBefore);
    });

    test('goes through unchanged once the disk recovers', () async {
      // The failed write left no transaction open behind it: the very same
      // replacement succeeds on the same connection.
      await seedTwoSources();
      await failInsertOf('jellyfin:boom');
      final List<Track> next = <Track>[
        _track('jellyfin:c'),
        _track('jellyfin:boom'),
        _track('jellyfin:d'),
      ];
      await expectLater(upsert('jellyfin', next), _throwsInjectedFailure);

      await diskRecovers();
      await upsert('jellyfin', next);

      expect(
        (await slice('jellyfin')).keys,
        unorderedEquals(<String>['jellyfin:c', 'jellyfin:boom', 'jellyfin:d']),
      );
      expect(await slice('plex'), plexBefore);
    });
  });

  group('a batch written without a delete that fails part way', () {
    test('upsertTracks writes none of its batch, updates included', () async {
      await seedTwoSources();
      await failInsertOf('jellyfin:boom');

      await expectLater(
        repository.upsertTracks(
          sourceId: 'jellyfin',
          tracks: <Track>[
            _track('jellyfin:x'),
            // An update of a stored row, earlier in the same batch.
            _track('jellyfin:a', durationMs: 9999),
            _track('jellyfin:boom'),
            _track('jellyfin:y'),
          ],
        ),
        _throwsInjectedFailure,
      );

      expect(await slice('jellyfin'), jellyfinBefore);
      expect(await repository.getTrackByUri('jellyfin:x'), isNull);
      expect(await slice('plex'), plexBefore);
    });

    test('appendToCatalog keeps the batches an incremental sync already wrote',
        () async {
      await repository.beginCatalogReplacement(
        sourceId: 'plex',
        tracks: <Track>[_track('plex:1'), _track('plex:2')],
      );
      await failInsertOf('plex:boom');

      await expectLater(
        repository.appendToCatalog(
          sourceId: 'plex',
          tracks: <Track>[_track('plex:3'), _track('plex:boom')],
        ),
        _throwsInjectedFailure,
      );

      expect(
        (await slice('plex')).keys,
        unorderedEquals(<String>['plex:1', 'plex:2']),
      );
    });
  });

  group('a prune that fails part way', () {
    // removeTracksNotIn deletes in chunks of 500 to stay under SQLite's bound
    // parameter limit. A failure in a later chunk must not leave the earlier
    // chunks' deletes behind: a reader would see a source missing a few
    // hundred tracks that the server still has.
    const int seeded = 1200;

    setUp(() async {
      await repository.upsertTracks(
        sourceId: 'subsonic',
        tracks: <Track>[
          for (int i = 0; i < seeded; i++) _track('subsonic:$i'),
        ],
      );
      await repository.upsertTracks(
        sourceId: 'jellyfin',
        tracks: <Track>[_track('jellyfin:1')],
      );
      // Counts every row deleted, and fails the delete that would be the
      // 601st: in the second chunk, after the first has gone through.
      await db.customStatement('CREATE TABLE deletes_seen (n INTEGER);');
      await db.customStatement('INSERT INTO deletes_seen VALUES (0);');
      await db.customStatement(
        'CREATE TRIGGER fail_delete BEFORE DELETE ON tracks BEGIN '
        'UPDATE deletes_seen SET n = n + 1; '
        "SELECT RAISE(ABORT, 'disk I/O error') "
        'WHERE (SELECT n FROM deletes_seen) > 600; '
        'END;',
      );
    });

    test('deletes nothing, and a re-run once the disk recovers prunes it all',
        () async {
      await expectLater(
        repository.removeTracksNotIn(
          sourceId: 'subsonic',
          keepUris: <String>{'subsonic:7'},
        ),
        _throwsInjectedFailure,
      );

      expect(await repository.countTracks(sourceId: 'subsonic'), seeded);
      expect(await repository.countTracks(sourceId: 'jellyfin'), 1);

      await db.customStatement('DROP TRIGGER fail_delete;');
      final List<String> removed = await repository.removeTracksNotIn(
        sourceId: 'subsonic',
        keepUris: <String>{'subsonic:7'},
      );

      expect(removed, hasLength(seeded - 1));
      expect(
        (await repository.getTracksForSource('subsonic'))
            .map((Track t) => t.uri),
        <String>['subsonic:7'],
      );
      expect(await repository.countTracks(sourceId: 'jellyfin'), 1);
    });
  });
}
