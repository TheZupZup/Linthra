import 'dart:async';

import '../models/track.dart';

/// A remote track body opened for streaming into the offline cache.
///
/// The audio bytes are exposed as a chunk stream instead of a single in-memory
/// list so large FLACs/albums can be cached without temporarily holding the
/// whole file in Dart heap. [contentLength] is the server-reported byte length
/// when known; callers must still trust the actual number of bytes written as
/// authoritative because some servers omit or misreport it.
class RemoteTrackDownload {
  const RemoteTrackDownload({
    required this.chunks,
    this.contentLength,
    this.fileExtension,
  });

  /// Stream of audio byte chunks. The stream is single-subscription and must be
  /// consumed exactly once by the cache writer.
  final Stream<List<int>> chunks;

  /// Total byte length when the server reported one, otherwise `null`.
  final int? contentLength;

  /// A lowercase extension without the dot (e.g. `mp3`, `flac`), or `null` when
  /// the server didn't say. Used only to name the cache file.
  final String? fileExtension;
}

/// Fetches the bytes of a *remote* track for offline caching.
///
/// This is the seam the download repository uses to obtain a remote source's
/// audio without knowing anything about that source's protocol, URLs, or auth.
/// The Jellyfin/Subsonic implementations live behind it; the repository depends
/// only on this interface, so the offline-cache policy stays source-agnostic and
/// tests can drive downloads with a fake chunk stream.
///
/// Security invariant: an implementation resolves any authenticated URL only at
/// fetch time and must never return, log, or embed an access token — or that
/// URL — in [RemoteTrackDownload] or in a thrown error.
abstract interface class RemoteTrackDownloader {
  /// Whether [track] is a remote track whose bytes must be fetched over the
  /// network for offline use. On-device tracks return `false` — they are
  /// already local and need no download.
  bool isRemote(Track track);

  /// Opens [track]'s remote audio body for streaming into the offline cache,
  /// resolving the authenticated URL on demand. Throws when the track can't be
  /// downloaded (not signed in, server unreachable, …); the error never carries
  /// the URL or token.
  Future<RemoteTrackDownload> open(Track track);
}
