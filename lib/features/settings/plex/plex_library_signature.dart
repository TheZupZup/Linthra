import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/models/track.dart';

/// A credential-free fingerprint of a Plex sync's outcome: the selected
/// sections plus every scanned track's catalog fields. Two scans with the same
/// signature describe the same library, so the second can skip the rebuild.
///
/// It is persisted, and compared on the first sync after the next launch, so
/// it has to come out the same in every run. `Object.hash` does not: Dart
/// seeds it afresh each run, so a saved one never matched again and every
/// first sync after a launch rebuilt the whole Plex slice. This is a SHA-256
/// over a canonical form instead.
///
/// Order-independent over tracks (a server reordering its listing is not a
/// real change); the selection and track count are folded in so a changed
/// selection or a different count always re-syncs.
///
/// **Every field the catalog persists must be in here**, or a change confined
/// to a missing field would look like "nothing changed" and never reach the
/// database (#281).
String plexLibrarySignature(List<String> sectionKeys, List<Track> tracks) {
  final List<String> sortedSections = List<String>.of(sectionKeys)..sort();
  final List<String> rows = <String>[
    for (final Track track in tracks) _canonicalRow(track),
  ]..sort();
  final _DigestSink digest = _DigestSink();
  final ByteConversionSink input = sha256.startChunkedConversion(digest);
  for (final String row in rows) {
    input
      ..add(utf8.encode(row))
      ..add(const <int>[0x0a]);
  }
  input.close();
  return '${sortedSections.join(',')}|${tracks.length}|${digest.value}';
}

/// One track as a JSON array: unambiguous whatever its strings contain.
String _canonicalRow(Track track) => jsonEncode(<Object?>[
      track.id,
      track.title,
      track.artistName,
      track.albumName,
      track.albumId,
      track.albumArtistName,
      track.duration.inMilliseconds,
      track.trackNumber,
      track.artworkUri?.toString(),
    ]);

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
