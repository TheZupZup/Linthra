import 'package:drift/drift.dart';

import '../../core/models/local_file_stamp.dart';
import '../../core/models/track.dart';
import '../database/linthra_database.dart';

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
    albumId: row.albumId,
    albumArtistName: row.albumArtistName,
    duration: Duration(milliseconds: row.durationMs),
    trackNumber: row.trackNumber,
    artworkUri: row.artworkUri == null ? null : Uri.tryParse(row.artworkUri!),
  );
}

/// Rebuilds the on-disk stamp a row was parsed with, or null when it carries
/// none: anything that is not a plain local file, and any row written before
/// schema v5. A null stamp reads as "parse this file again".
///
/// Both halves have to be present to mean anything, so a row with only one is
/// treated as having none rather than as a stamp with a zero in it.
LocalFileStamp? fileStampFromRow(TrackRow row) {
  final int? size = row.fileSizeBytes;
  final int? modified = row.fileModifiedAtMs;
  if (size == null || modified == null) return null;
  return LocalFileStamp(sizeBytes: size, modifiedAtMs: modified);
}

/// Rebuilds a stored row as the track plus the stamp it was parsed with.
StampedTrack stampedTrackFromRow(TrackRow row) => StampedTrack(
      track: trackFromRow(row),
      stamp: fileStampFromRow(row),
    );

/// Builds an insertable companion for [track], tagged with the [sourceId] it
/// belongs to. `durationMs`/`artworkUri` are flattened to primitives here.
///
/// [stamp] records what the source file looked like when its tags were parsed,
/// for the sources that have one (local files); omitting it stores nulls, which
/// simply means the next scan re-parses that file.
TracksCompanion trackToCompanion(
  Track track,
  String sourceId, {
  LocalFileStamp? stamp,
}) {
  return TracksCompanion(
    id: Value(track.id),
    sourceId: Value(sourceId),
    title: Value(track.title),
    uri: Value(track.uri),
    artistName: Value(track.artistName),
    albumName: Value(track.albumName),
    albumId: Value(track.albumId),
    albumArtistName: Value(track.albumArtistName),
    durationMs: Value(track.duration.inMilliseconds),
    trackNumber: Value(track.trackNumber),
    artworkUri: Value(track.artworkUri?.toString()),
    fileSizeBytes: Value(stamp?.sizeBytes),
    fileModifiedAtMs: Value(stamp?.modifiedAtMs),
  );
}
