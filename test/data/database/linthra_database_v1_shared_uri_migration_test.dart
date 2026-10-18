// A v1 catalog holding two rows for one uri must still upgrade.
//
// Schema v1 keyed `tracks` on the bare server-side id, so nothing stopped two
// rows with different ids from carrying the same provider-namespaced uri. v2
// re-keys the table on that uri. The rebuild copies the old rows across with
// `INSERT OR REPLACE` so such a pair collapses to one row; a plain copy would
// hit the new primary key, roll the whole upgrade back, and leave the catalog
// failing to open on every launch.
//
// Builds a genuine v1 file by hand, then lets the database's own migration run
// over it all the way to the current version.

// Named imports only: drift also exports an `isNull` that would collide with
// matcher's.
import 'package:drift/drift.dart' show QueryRow;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/database/linthra_database.dart';
import 'package:linthra/data/repositories/drift_music_library_repository.dart';

/// The `tracks` DDL as of schema v1: primary key on the bare `id`.
const String _v1CreateTracks = '''
CREATE TABLE tracks (
  id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  title TEXT NOT NULL,
  uri TEXT NOT NULL,
  artist_name TEXT,
  album_name TEXT,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  track_number INTEGER,
  artwork_uri TEXT,
  PRIMARY KEY (id)
);
''';

/// Two Jellyfin rows that share `jellyfin:101` under different ids, beside
/// one ordinary local row.
const List<String> _v1Rows = <String>[
  "INSERT INTO tracks (id, source_id, title, uri, artist_name, duration_ms) "
      "VALUES ('101', 'jellyfin', 'First copy', 'jellyfin:101', 'Adele', "
      "1000);",
  "INSERT INTO tracks (id, source_id, title, uri, artist_name, duration_ms) "
      "VALUES ('legacy-101', 'jellyfin', 'Second copy', 'jellyfin:101', "
      "'Adele', 2000);",
  "INSERT INTO tracks (id, source_id, title, uri, duration_ms) "
      "VALUES ('7', 'local', 'Local song', 'file:///7.flac', 0);",
];

/// A database whose file is at schema v1 with [_v1Rows], upgraded by the
/// real migration on first use.
LinthraDatabase _openFromV1() {
  final LinthraDatabase db = LinthraDatabase.forTesting(
    NativeDatabase.memory(
      setup: (sqlite) {
        sqlite.execute(_v1CreateTracks);
        _v1Rows.forEach(sqlite.execute);
        sqlite.execute('PRAGMA user_version = 1;');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

Future<int> _userVersion(LinthraDatabase db) async {
  final QueryRow row =
      await db.customSelect('PRAGMA user_version;').getSingle();
  return row.data['user_version'] as int;
}

/// Whether SQLite's own catalog reports an index on `tracks.source_id`.
Future<bool> _hasSourceIdIndex(LinthraDatabase db) async {
  final QueryRow row = await db
      .customSelect(
        "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'index' "
        "AND tbl_name = 'tracks' AND sql LIKE '%source_id%';",
      )
      .getSingle();
  return (row.data['c'] as int) > 0;
}

Future<List<String>> _tableNames(LinthraDatabase db) async => <String>[
      for (final QueryRow row in await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table';")
          .get())
        row.data['name'] as String,
    ];

void main() {
  group('a v1 catalog with two rows for one uri', () {
    test('upgrades to one row per uri, keeping every other row', () async {
      final LinthraDatabase db = _openFromV1();

      final List<TrackRow> rows = await db.select(db.tracks).get();

      expect(
        rows.map((TrackRow r) => r.uri),
        unorderedEquals(<String>['jellyfin:101', 'file:///7.flac']),
      );
      // Either copy is the same song; what matters is that one of them, whole,
      // is what is left.
      final TrackRow shared =
          rows.singleWhere((TrackRow r) => r.uri == 'jellyfin:101');
      expect(
        '${shared.id} / ${shared.title}',
        isIn(<String>['101 / First copy', 'legacy-101 / Second copy']),
      );
      expect(shared.sourceId, 'jellyfin');
      expect(shared.artistName, 'Adele');
      final TrackRow local =
          rows.singleWhere((TrackRow r) => r.uri == 'file:///7.flac');
      expect(local.title, 'Local song');
      expect(local.fileSizeBytes, isNull);
    });

    test(
        'lands on the current version, with the source_id index and without '
        'the legacy table', () async {
      final LinthraDatabase db = _openFromV1();
      await db.select(db.tracks).get();

      expect(await _userVersion(db), db.schemaVersion);
      expect(await _hasSourceIdIndex(db), isTrue);
      expect(await _tableNames(db), isNot(contains('tracks_legacy_v1')));
    });

    test('takes a source re-sync afterwards', () async {
      final LinthraDatabase db = _openFromV1();
      final DriftMusicLibraryRepository repository =
          DriftMusicLibraryRepository(db);

      await repository.upsertCatalog(
        sourceId: 'jellyfin',
        tracks: const <Track>[
          Track(id: '101', title: 'Synced', uri: 'jellyfin:101'),
          Track(id: '202', title: 'New', uri: 'jellyfin:202'),
        ],
        albums: const <Album>[],
        artists: const <Artist>[],
      );

      expect(
        (await repository.getTracksForSource('jellyfin'))
            .map((Track t) => '${t.uri} ${t.title}'),
        unorderedEquals(<String>['jellyfin:101 Synced', 'jellyfin:202 New']),
      );
      expect(
        (await repository.getTracksForSource('local')).map((Track t) => t.uri),
        <String>['file:///7.flac'],
      );
    });
  });
}
