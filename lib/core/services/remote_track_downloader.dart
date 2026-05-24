import '../models/track.dart';

/// The bytes of a downloaded remote track, with an optional file-extension hint
/// (from the server's content type) so the cache can name the file sensibly.
class RemoteTrackData {
  const RemoteTrackData({required this.bytes, this.fileExtension});

  final List<int> bytes;

  /// A lowercase extension without the dot (e.g. `mp3`, `flac`), or `null` when
  /// the server didn't say. Used only to name the cache file.
  final String? fileExtension;
}

/// Fetches the bytes of a *remote* track for offline caching.
///
/// This is the seam the download repository uses to obtain a remote source's
/// audio without knowing anything about that source's protocol, URLs, or auth.
/// The Jellyfin implementation lives behind it; the repository depends only on
/// this interface, so the offline-cache policy stays source-agnostic and tests
/// can drive downloads with a fake that returns canned bytes.
///
/// Security invariant: an implementation resolves any authenticated URL only at
/// fetch time and must never return, log, or embed an access token — or that
/// URL — in [RemoteTrackData] or in a thrown error.
abstract interface class RemoteTrackDownloader {
  /// Whether [track] is a remote track whose bytes must be fetched over the
  /// network for offline use. On-device tracks return `false` — they are
  /// already local and need no download.
  bool isRemote(Track track);

  /// Fetches [track]'s bytes for offline caching, resolving the authenticated
  /// URL on demand. Throws when the track can't be downloaded (not signed in,
  /// server unreachable, …); the error never carries the URL or token.
  ///
  /// [onProgress] is invoked as bytes arrive, with the running [received] count
  /// and the [total] size when the server reported one (otherwise `null`,
  /// meaning indeterminate). It carries byte counts only — never a URL or
  /// token — so it is safe to surface in the UI. Implementations may omit it
  /// (a one-shot fetch simply never calls it).
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  });
}
