import 'package:drift/drift.dart';

import '../../core/models/track.dart';
import '../database/halcyon_database.dart';

/// Explicit, one-way conversions between the [Track] domain model and its
/// persisted form. Kept tiny and dumb on purpose: no IO, no defaults beyond
/// what the schema guarantees, so the domain and database shapes can drift
/// apart (pun intended) without leaking either into the other.

/// Rebuilds a domain [Track] from a stored row.
Track trackFromRow(TrackRow row) {
  return Track(
    id: row.id,
    title: row.title,
    uri: row.uri,
    artistName: row.artistName,
    albumName: row.albumName,
    duration: Duration(milliseconds: row.durationMs),
    trackNumber: row.trackNumber,
    artworkUri: row.artworkUri == null ? null : Uri.tryParse(row.artworkUri!),
  );
}

/// Builds an insertable companion for [track], tagged with the [sourceId] it
/// belongs to. `durationMs`/`artworkUri` are flattened to primitives here.
TracksCompanion trackToCompanion(Track track, String sourceId) {
  return TracksCompanion(
    id: Value(track.id),
    sourceId: Value(sourceId),
    title: Value(track.title),
    uri: Value(track.uri),
    artistName: Value(track.artistName),
    albumName: Value(track.albumName),
    durationMs: Value(track.duration.inMilliseconds),
    trackNumber: Value(track.trackNumber),
    artworkUri: Value(track.artworkUri?.toString()),
  );
}
