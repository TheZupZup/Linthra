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
///
/// The primary key is [uri], not [id]. `id` is the *bare* server-side id
/// (Jellyfin item id, Subsonic/Plex `ratingKey`, or a local path), which is only
/// unique *within* a provider — two providers can hand us the same `id` (e.g.
/// Plex `101` and Subsonic `101`). `uri` is the provider-namespaced identity the
/// rest of the app already keys off (`jellyfin:101`, `plex:101`, a local path),
/// so keying the row on it lets the same server-side id from different providers
/// coexist instead of silently overwriting each other under `insertOrReplace`.
/// `id` is kept as a column because the per-provider server APIs (e.g. Jellyfin
/// favourites/playlists) still address items by it.
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
  Set<Column> get primaryKey => {uri};
}
