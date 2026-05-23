import 'package:drift/drift.dart';

/// The persisted shape of a [Track] in the local SQLite catalog.
///
/// The generated row class is named `TrackRow` (not `Track`) so it never
/// collides with the domain model in `core/models/track.dart`. Conversion
/// between the two lives in the explicit mappers under `data/mappers/`.
///
/// `sourceId` records which [MusicSource] a row came from so a re-scan of one
/// source can replace just its rows (see `upsertCatalog`) without touching the
/// others. `durationMs` and `artworkUri` are stored as primitives (SQLite has
/// no Duration/Uri types); the mappers rebuild the rich types on read.
@DataClassName('TrackRow')
class Tracks extends Table {
  TextColumn get id => text()();
  TextColumn get sourceId => text()();
  TextColumn get title => text()();
  TextColumn get uri => text()();
  TextColumn get artistName => text().nullable()();
  TextColumn get albumName => text().nullable()();
  IntColumn get durationMs => integer().withDefault(const Constant(0))();
  IntColumn get trackNumber => integer().nullable()();
  TextColumn get artworkUri => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
