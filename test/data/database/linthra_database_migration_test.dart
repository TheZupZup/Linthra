import 'dart:io';

// Named imports only: drift also exports an `isNull` that would collide with
// matcher's.
import 'package:drift/drift.dart' show MigrationStrategy, Migrator, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/database/linthra_database.dart';

/// The v2 → v3 migration (issue #281) adds the nullable `album_id` /
/// `album_artist_name` columns album grouping keys off. It must be purely
/// additive: a user upgrading the app keeps every track already in their
/// offline catalog, with the new columns simply reading back null until the
/// next source re-scan populates them.
///
/// These tests build a *real* v2-shaped `tracks` table by hand, run the
/// database's own [MigrationStrategy] over it, and assert on the result —
/// rather than trusting the schema definition, which is what changed.

/// The exact `tracks` DDL and column list as of schema v2, so the fixture is a
/// genuine pre-migration database rather than today's shape minus two columns.
const String _v2CreateTracks = '''
CREATE TABLE tracks (
  id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  title TEXT NOT NULL,
  uri TEXT NOT NULL,
  artist_name TEXT NULL,
  album_name TEXT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  track_number INTEGER NULL,
  artwork_uri TEXT NULL,
  PRIMARY KEY (uri)
);
''';

/// The exact `tracks` DDL as of schema v3 -- the v2 shape plus the nullable
/// album-grouping columns, still with no index on `source_id`.
const String _v3CreateTracks = '''
CREATE TABLE tracks (
  id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  title TEXT NOT NULL,
  uri TEXT NOT NULL,
  artist_name TEXT NULL,
  album_name TEXT NULL,
  album_id TEXT NULL,
  album_artist_name TEXT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  track_number INTEGER NULL,
  artwork_uri TEXT NULL,
  PRIMARY KEY (uri)
);
''';

/// The exact `tracks` DDL as of schema v4: the v3 shape, still without the
/// local-file stamp columns, plus the `source_id` index that v4 added.
const String _v4CreateTracks = '''
CREATE TABLE tracks (
  id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  title TEXT NOT NULL,
  uri TEXT NOT NULL,
  artist_name TEXT NULL,
  album_name TEXT NULL,
  album_id TEXT NULL,
  album_artist_name TEXT NULL,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  track_number INTEGER NULL,
  artwork_uri TEXT NULL,
  PRIMARY KEY (uri)
);
''';

const String _v4CreateSourceIdIndex =
    'CREATE INDEX tracks_source_id ON tracks (source_id);';

/// Opens a database whose underlying file is already at schema v4 with
/// [seedStatements] inserted, then lets the real migration run on first use.
Future<LinthraDatabase> _openMigratedFromV4(
  List<String> seedStatements,
) async {
  final NativeDatabase executor = NativeDatabase.memory(
    setup: (db) {
      db.execute(_v4CreateTracks);
      db.execute(_v4CreateSourceIdIndex);
      for (final String statement in seedStatements) {
        db.execute(statement);
      }
      // Mark the file as schema v4 so drift runs onUpgrade(4 -> 5).
      db.execute('PRAGMA user_version = 4;');
    },
  );
  return LinthraDatabase.forTesting(executor);
}

/// Opens a database whose underlying file is already at schema v3 with
/// [seedStatements] inserted, then lets the real migration run on first use.
Future<LinthraDatabase> _openMigratedFromV3(
  List<String> seedStatements,
) async {
  final NativeDatabase executor = NativeDatabase.memory(
    setup: (db) {
      db.execute(_v3CreateTracks);
      for (final String statement in seedStatements) {
        db.execute(statement);
      }
      // Mark the file as schema v3 so drift runs onUpgrade(3 -> 4), not
      // onCreate.
      db.execute('PRAGMA user_version = 3;');
    },
  );
  return LinthraDatabase.forTesting(executor);
}

/// Whether SQLite's own catalog reports an index on `tracks.source_id` --
/// asserting the real effect of the migration (a usable index exists),
/// rather than just that `createIndex` didn't throw.
Future<bool> _hasSourceIdIndex(LinthraDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'tracks' AND sql LIKE '%source_id%';",
      )
      .getSingle();
  return (rows.data['c'] as int) > 0;
}

/// Opens a database whose underlying file is already at schema [version] with
/// [seed] rows inserted, then lets the real migration run on first use.
Future<LinthraDatabase> _openMigratedFromV2(
  List<String> seedStatements,
) async {
  final NativeDatabase executor = NativeDatabase.memory(
    setup: (db) {
      db.execute(_v2CreateTracks);
      for (final String statement in seedStatements) {
        db.execute(statement);
      }
      // Mark the file as schema v2 so drift runs onUpgrade(2 -> 3), not
      // onCreate.
      db.execute('PRAGMA user_version = 2;');
    },
  );
  return LinthraDatabase.forTesting(executor);
}

/// An older release opening the file: it reads the rows it knows about, finds
/// nothing in its own migration for a version it has never heard of (every
/// step it has is guarded by `from < N`, with N no higher than its own
/// version), and drift then records [olderVersion] on the way in.
class _OlderRelease extends LinthraDatabase {
  _OlderRelease(super.executor, this.olderVersion) : super.forTesting();

  final int olderVersion;

  @override
  int get schemaVersion => olderVersion;

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onUpgrade: (Migrator m, int from, int to) async {});
}

Future<int> _userVersion(LinthraDatabase db) async {
  final row = await db.customSelect('PRAGMA user_version;').getSingle();
  return row.data['user_version'] as int;
}

void main() {
  group('v2 → v3 migration', () {
    late LinthraDatabase db;

    tearDown(() async => db.close());

    test('preserves every existing row and all of its values', () async {
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, duration_ms, track_number, artwork_uri) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', 'Adele', '25', "
            "180000, 1, 'https://media.example/a.jpg');",
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, duration_ms, track_number, artwork_uri) VALUES "
            "('t2', 'subsonic', 'Two', 'subsonic:t2', 'Queen', "
            "'Greatest Hits', 240000, 2, NULL);",
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) VALUES "
            "('/music/a.mp3', 'local', 'A', '/music/a.mp3', 0);",
      ]);

      final List<TrackRow> rows = await db.select(db.tracks).get();
      expect(rows, hasLength(3));

      final TrackRow jellyfin =
          rows.firstWhere((TrackRow r) => r.uri == 'jellyfin:t1');
      expect(jellyfin.id, 't1');
      expect(jellyfin.sourceId, 'jellyfin');
      expect(jellyfin.title, 'One');
      expect(jellyfin.artistName, 'Adele');
      expect(jellyfin.albumName, '25');
      expect(jellyfin.durationMs, 180000);
      expect(jellyfin.trackNumber, 1);
      expect(jellyfin.artworkUri, 'https://media.example/a.jpg');

      final TrackRow subsonic =
          rows.firstWhere((TrackRow r) => r.uri == 'subsonic:t2');
      expect(subsonic.albumName, 'Greatest Hits');
      expect(subsonic.artworkUri, isNull);

      final TrackRow local =
          rows.firstWhere((TrackRow r) => r.uri == '/music/a.mp3');
      expect(local.title, 'A');
      expect(local.artistName, isNull);
    });

    test('reads migrated rows back with null album grouping fields', () async {
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, album_name, "
            "duration_ms) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', '25', 0);",
      ]);

      final TrackRow row = await db.select(db.tracks).getSingle();
      // Nothing to backfill from — the source re-scan populates these.
      expect(row.albumId, isNull);
      expect(row.albumArtistName, isNull);
    });

    test('the migrated table accepts writes to the new columns', () async {
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', 0);",
      ]);

      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: 't2',
              sourceId: 'jellyfin',
              title: 'Two',
              uri: 'jellyfin:t2',
              albumId: const Value('jellyfin:al-1'),
              albumArtistName: const Value('Main Artist'),
            ),
          );

      final TrackRow written = await (db.select(db.tracks)
            ..where((t) => t.uri.equals('jellyfin:t2')))
          .getSingle();
      expect(written.albumId, 'jellyfin:al-1');
      expect(written.albumArtistName, 'Main Artist');
      // The pre-existing row is untouched.
      expect(await db.select(db.tracks).get(), hasLength(2));
    });

    test('lands on the current schema version, not just v3', () async {
      db = await _openMigratedFromV2(<String>[]);
      // A v2 database runs every subsequent onUpgrade branch in one pass
      // (v2 -> v3 -> v4), landing on whatever the current version actually
      // is -- not hardcoded to 4, so this doesn't go stale again the next
      // time schemaVersion bumps.
      await db.select(db.tracks).get();
      final result = await db.customSelect('PRAGMA user_version;').getSingle();
      expect(result.data.values.first, db.schemaVersion);
    });

    test('also picks up the v4 index along the way', () async {
      db = await _openMigratedFromV2(<String>[]);
      await db.select(db.tracks).get();
      expect(await _hasSourceIdIndex(db), isTrue);
    });
  });

  group('v3 → v4 migration', () {
    late LinthraDatabase db;

    tearDown(() async => db.close());

    test('preserves every existing row and all of its values', () async {
      db = await _openMigratedFromV3(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, album_id, album_artist_name, duration_ms, "
            "track_number, artwork_uri) VALUES "
            "('t1', 'jellyfin', 'One', 'jellyfin:t1', 'Adele', '25', "
            "'jellyfin:al-1', 'Adele', 180000, 1, "
            "'https://media.example/a.jpg');",
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) "
            "VALUES ('t2', 'subsonic', 'Two', 'subsonic:t2', 240000);",
      ]);

      final List<TrackRow> rows = await db.select(db.tracks).get();
      expect(rows, hasLength(2));

      final TrackRow jellyfin =
          rows.firstWhere((TrackRow r) => r.uri == 'jellyfin:t1');
      expect(jellyfin.sourceId, 'jellyfin');
      expect(jellyfin.albumId, 'jellyfin:al-1');
      expect(jellyfin.albumArtistName, 'Adele');
      expect(jellyfin.artworkUri, 'https://media.example/a.jpg');

      final TrackRow subsonic =
          rows.firstWhere((TrackRow r) => r.uri == 'subsonic:t2');
      expect(subsonic.albumId, isNull);
    });

    test('adds a usable index on source_id', () async {
      db = await _openMigratedFromV3(<String>[]);
      // Force the migration to run.
      await db.select(db.tracks).get();
      expect(await _hasSourceIdIndex(db), isTrue);
    });

    test('a source-scoped delete still only removes that source\'s rows',
        () async {
      // Not a performance benchmark (an in-memory DB with two rows can't
      // demonstrate that) -- this is the actual access pattern the index
      // exists for (`_deleteSource` in drift_music_library_repository.dart),
      // proving the migrated table still behaves correctly under it.
      db = await _openMigratedFromV3(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) "
            "VALUES ('t1', 'jellyfin', 'One', 'jellyfin:t1', 0);",
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) "
            "VALUES ('t2', 'subsonic', 'Two', 'subsonic:t2', 0);",
      ]);

      await (db.delete(db.tracks)..where((t) => t.sourceId.equals('jellyfin')))
          .go();

      final List<TrackRow> remaining = await db.select(db.tracks).get();
      expect(remaining, hasLength(1));
      expect(remaining.single.sourceId, 'subsonic');
    });

    test('leaves the schema at the current version', () async {
      // Read from schemaVersion rather than a literal, so a later additive
      // migration does not fail this on its way past.
      db = await _openMigratedFromV3(<String>[]);
      await db.select(db.tracks).get();
      final result = await db.customSelect('PRAGMA user_version;').getSingle();
      expect(result.data.values.first, db.schemaVersion);
    });

    test(
        "the source-scoped delete's query plan actually uses the index, "
        'not just that the index exists', () async {
      // An unindexed lookup always needs a full SCAN; that half isn't worth
      // proving. What actually matters: after migration, the same delete
      // this issue is about (`_deleteSource` in
      // drift_music_library_repository.dart) really does SEARCH via the new
      // index instead, not just that CREATE INDEX succeeded somewhere.
      db = await _openMigratedFromV3(<String>[]);
      await db.select(db.tracks).get(); // force the migration to run
      final plan = await db
          .customSelect(
            "EXPLAIN QUERY PLAN DELETE FROM tracks WHERE source_id = 'x';",
          )
          .get();
      final String detail = plan.map((r) => r.data['detail']).join();
      expect(detail, isNot(contains('SCAN tracks')));
      expect(detail, contains('tracks_source_id'));
    });
  });

  group('fresh install', () {
    test('creates the v3 shape directly, with the new columns usable',
        () async {
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: 't1',
              sourceId: 'plex',
              title: 'One',
              uri: 'plex:t1',
              albumId: const Value('plex:201'),
              albumArtistName: const Value('Kavinsky'),
            ),
          );

      final TrackRow row = await db.select(db.tracks).getSingle();
      expect(row.albumId, 'plex:201');
      expect(row.albumArtistName, 'Kavinsky');
    });

    test('already has the source_id index, with no migration needed', () async {
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      // onCreate creates every entity declared on the table, the index
      // among them -- unlike an upgrade, which needs the explicit v3 -> v4
      // step because createTable alone does not.
      await db.select(db.tracks).get();
      expect(await _hasSourceIdIndex(db), isTrue);
    });
  });

  group('v4 → v5 migration', () {
    // Adds the nullable file_size_bytes / file_modified_at_ms columns an
    // incremental local scan compares a fresh stat against. Purely additive:
    // an upgraded catalog keeps every row, and a row with no stamp simply gets
    // re-parsed on the next scan, which is exactly the pre-v5 behavior.
    late LinthraDatabase db;

    tearDown(() async => db.close());

    test('every existing row survives, with null stamps', () async {
      db = await _openMigratedFromV4(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, duration_ms, track_number, artwork_uri) "
            "VALUES ('t1', 'local', 'One', '/music/one.mp3', 'A', 'B', "
            "1000, 1, NULL);",
        "INSERT INTO tracks (id, source_id, title, uri, artist_name, "
            "album_name, duration_ms, track_number, artwork_uri) "
            "VALUES ('t2', 'jellyfin', 'Two', 'jellyfin:t2', 'C', 'D', "
            "2000, 2, NULL);",
      ]);

      final List<TrackRow> rows = await db.select(db.tracks).get();

      expect(rows, hasLength(2));
      final TrackRow local =
          rows.firstWhere((TrackRow r) => r.uri == '/music/one.mp3');
      expect(local.title, 'One');
      expect(local.artistName, 'A');
      expect(local.durationMs, 1000);
      expect(local.fileSizeBytes, isNull);
      expect(local.fileModifiedAtMs, isNull);
    });

    test('the upgraded table accepts stamps afterwards', () async {
      db = await _openMigratedFromV4(const <String>[]);

      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: '/music/one.mp3',
              sourceId: 'local',
              title: 'One',
              uri: '/music/one.mp3',
              fileSizeBytes: const Value(4096),
              fileModifiedAtMs: const Value(1700000000000),
            ),
          );

      final TrackRow row = await db.select(db.tracks).getSingle();
      expect(row.fileSizeBytes, 4096);
      expect(row.fileModifiedAtMs, 1700000000000);
    });

    test('the source_id index the previous version added is still there',
        () async {
      db = await _openMigratedFromV4(const <String>[]);
      await db.select(db.tracks).get();

      expect(await _hasSourceIdIndex(db), isTrue);
    });

    test('a v2 database arrives at v5 in one go', () async {
      // The long way round: two column-adding steps and an index, on a file
      // that predates all of them.
      db = await _openMigratedFromV2(<String>[
        "INSERT INTO tracks (id, source_id, title, uri, duration_ms) "
            "VALUES ('t1', 'local', 'One', '/music/one.mp3', 1000);",
      ]);

      final TrackRow row = await db.select(db.tracks).getSingle();
      expect(row.title, 'One');
      expect(row.albumId, isNull);
      expect(row.fileSizeBytes, isNull);
      expect(await _hasSourceIdIndex(db), isTrue);
    });

    test('a fresh install already has the stamp columns', () async {
      db = LinthraDatabase.forTesting(NativeDatabase.memory());

      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: '/music/one.mp3',
              sourceId: 'local',
              title: 'One',
              uri: '/music/one.mp3',
              fileSizeBytes: const Value(1),
              fileModifiedAtMs: const Value(2),
            ),
          );

      expect((await db.select(db.tracks).getSingle()).fileSizeBytes, 1);
    });
  });

  group('a file an older release opened in between', () {
    // Going back to an older release and then forward again, say to step
    // around a regression. The older release reads the newer file fine, but
    // drift records its lower version on the way in, so the next upgrade
    // replays steps whose columns and index the file already has. An upgrade
    // killed after committing its columns but before drift wrote the new
    // version leaves the same file behind.
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('linthra_db_');
      file = File('${dir.path}/linthra.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    LinthraDatabase openWithThisRelease() {
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      return db;
    }

    /// This release creates the file and indexes one local track, stamps and
    /// album id included.
    Future<void> createWithOneTrack() async {
      final LinthraDatabase db =
          LinthraDatabase.forTesting(NativeDatabase(file));
      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: '/music/one.mp3',
              sourceId: 'local',
              title: 'One',
              uri: '/music/one.mp3',
              albumId: const Value('album-1'),
              fileSizeBytes: const Value(4096),
              fileModifiedAtMs: const Value(1700000000000),
            ),
          );
      await db.close();
    }

    Future<void> openWithOlderRelease(int version) async {
      final _OlderRelease older = _OlderRelease(NativeDatabase(file), version);
      final rows = await older.customSelect('SELECT title FROM tracks;').get();
      expect(rows.single.data['title'], 'One');
      expect(await _userVersion(older), version);
      await older.close();
    }

    test('coming back from a v4 release (0.2.3 to 0.2.6) keeps the library',
        () async {
      await createWithOneTrack();
      await openWithOlderRelease(4);

      final LinthraDatabase db = openWithThisRelease();
      final TrackRow row = await db.select(db.tracks).getSingle();

      expect(row.title, 'One');
      expect(row.albumId, 'album-1');
      expect(row.fileSizeBytes, 4096);
      expect(row.fileModifiedAtMs, 1700000000000);
      expect(await _userVersion(db), 5);
    });

    test('coming back from a v3 release (0.2.0 to 0.2.2) keeps the library',
        () async {
      await createWithOneTrack();
      await openWithOlderRelease(3);

      final LinthraDatabase db = openWithThisRelease();
      final TrackRow row = await db.select(db.tracks).getSingle();

      expect(row.title, 'One');
      expect(row.albumId, 'album-1');
      expect(row.fileSizeBytes, 4096);
      expect(await _hasSourceIdIndex(db), isTrue);
      expect(await _userVersion(db), 5);
    });

    test('the library still takes writes afterwards', () async {
      await createWithOneTrack();
      await openWithOlderRelease(4);

      final LinthraDatabase db = openWithThisRelease();
      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: '/music/two.mp3',
              sourceId: 'local',
              title: 'Two',
              uri: '/music/two.mp3',
              fileSizeBytes: const Value(8192),
            ),
          );

      expect(await db.select(db.tracks).get(), hasLength(2));
    });
  });

  group('a first launch cut off before its version was recorded', () {
    // Drift writes the schema version only after onCreate returns, and none
    // of it is one transaction. A first launch killed in between, or out of
    // disk, leaves schema in the file at user_version 0, so the next launch
    // runs onCreate again over it.
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('linthra_db_');
      file = File('${dir.path}/linthra.sqlite');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    /// The next launch, over the file as the cut left it: the schema created
    /// up to [indexCreated], and no version.
    Future<LinthraDatabase> relaunchAfterTheCut({
      required bool indexCreated,
    }) async {
      final LinthraDatabase first =
          LinthraDatabase.forTesting(NativeDatabase(file));
      await first.select(first.tracks).get();
      await first.close();

      final LinthraDatabase db = LinthraDatabase.forTesting(
        NativeDatabase(
          file,
          setup: (sqlite) {
            if (!indexCreated) sqlite.execute('DROP INDEX tracks_source_id;');
            sqlite.execute('PRAGMA user_version = 0;');
          },
        ),
      );
      addTearDown(db.close);
      return db;
    }

    Future<void> expectALibraryThatWorks(LinthraDatabase db) async {
      expect(await db.select(db.tracks).get(), isEmpty);
      await db.into(db.tracks).insert(
            TracksCompanion.insert(
              id: '/music/one.mp3',
              sourceId: 'local',
              title: 'One',
              uri: '/music/one.mp3',
              fileSizeBytes: const Value(4096),
            ),
          );
      expect(await db.select(db.tracks).get(), hasLength(1));
      expect(await _hasSourceIdIndex(db), isTrue);
      expect(await _userVersion(db), 5);
    }

    test('after the whole schema was created', () async {
      await expectALibraryThatWorks(
        await relaunchAfterTheCut(indexCreated: true),
      );
    });

    test('between the table and its index', () async {
      await expectALibraryThatWorks(
        await relaunchAfterTheCut(indexCreated: false),
      );
    });
  });
}
