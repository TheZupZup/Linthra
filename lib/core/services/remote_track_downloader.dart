import '../models/track.dart';

/// The body of a downloaded remote track, with an optional file-extension hint
/// (from the server's content type) so the cache can name the file sensibly.
///
/// A real download hands its body back while it is still arriving
/// ([RemoteTrackData.streamed]), and the offline cache writes it to disk a
/// chunk at a time: a hi-res file can be a gigabyte, and several download at
/// once (#745).
class RemoteTrackData {
  /// A body already in memory as [bytes].
  const RemoteTrackData({required List<int> bytes, this.fileExtension})
      : _bytes = bytes,
        _body = null,
        _length = null;

  /// A body still arriving: [body] can be listened to once, and whoever caches
  /// it either reads it or cancels it, so the connection is closed either
  /// way. [length] is the size the server announced, when it did.
  const RemoteTrackData.streamed({
    required Stream<List<int>> body,
    int? length,
    this.fileExtension,
  })  : _bytes = null,
        _body = body,
        _length = length;

  final List<int>? _bytes;
  final Stream<List<int>>? _body;
  final int? _length;

  /// The body, a chunk at a time.
  Stream<List<int>> get body => _body ?? Stream<List<int>>.value(_bytes!);

  /// The body's size in bytes, or null when the server didn't announce one.
  int? get length => _bytes?.length ?? _length;

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

  /// Fetches [track] for offline caching, resolving the authenticated URL on
  /// demand. Throws when the track can't be downloaded (not signed in, server
  /// unreachable, a response that isn't audio, …); the error never carries the
  /// URL or token.
  ///
  /// Returns once the response has been checked, with its body still
  /// arriving: the caller reads it. The body's errors are just as free of the
  /// URL and token as the ones thrown here.
  ///
  /// [onProgress] is for a source that already has bytes on the way before it
  /// returns, with the running [received] count and the [total] size when
  /// known (otherwise `null`, meaning indeterminate). It carries byte counts
  /// only, never a URL or token, so it is safe to surface in the UI. A
  /// source that hands its body back as it arrives never calls it: the body
  /// is counted by whoever reads it. If [onProgress] throws, the fetch stops
  /// there and fails: that is how a caller abandons bytes it already knows it
  /// can't use.
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  });
}
