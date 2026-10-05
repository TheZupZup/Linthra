import 'dart:async';

import 'package:http/http.dart' as http;

import '../../models/track.dart';
import '../../services/remote_track_downloader.dart';
import '../download_response_body.dart';
import '../media_content_type.dart';
import 'jellyfin_download_source.dart';
import 'jellyfin_track_mapper.dart';

/// The [RemoteTrackDownloader] for Jellyfin tracks.
///
/// Resolves the authenticated download URL only at fetch time — through the live
/// signed-in [JellyfinDownloadSource], read via a getter so signing in or out is
/// picked up without a rebuild — then fetches the bytes over HTTP. The URL, and
/// the token woven into it, never leaves [fetch]: it is not stored, not
/// returned, and not placed in any thrown error (a transport failure is
/// re-raised as a generic message so a `ClientException` carrying the tokenized
/// URL can't escape).
///
/// The body is handed back while it is still arriving (see
/// [downloadResponseBody]), so the offline cache can write it to disk a
/// chunk at a time, and an error while it is read is just as generic.
class JellyfinTrackDownloader implements RemoteTrackDownloader {
  JellyfinTrackDownloader(this._source, {http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  /// Supplies the current signed-in source, or `null` when not connected.
  final JellyfinDownloadSource? Function() _source;

  final http.Client _client;

  static const Duration _timeout = Duration(minutes: 5);

  @override
  bool isRemote(Track track) =>
      track.uri.startsWith(JellyfinTrackMapper.uriScheme);

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final JellyfinDownloadSource? source = _source();
    if (source == null) {
      throw StateError('Not signed in to Jellyfin.');
    }

    // Confirm the session still works before fetching; the JellyfinException
    // this may throw is friendly and token-free by design.
    await source.verifyReachable();

    final Uri? uri = await source.resolveDownloadUri(track);
    if (uri == null) {
      throw StateError('No Jellyfin download URL for this track.');
    }

    try {
      // The request carries the token in its URL, but the URL never leaves this
      // method, is never logged, and any transport error below is replaced
      // with a generic message so it can't escape either.
      final http.StreamedResponse response =
          await _client.send(http.Request('GET', uri)).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Cancel the body rather than read it to the end: a server that
        // stalls, or keeps a chunked body open, would otherwise hold this
        // download and its slot for good. Same for the refusal below.
        await response.stream.listen(null).cancel();
        throw StateError(
            'Jellyfin download failed (HTTP ${response.statusCode}).');
      }
      // A reverse-proxy/SSO login page answers 200 with HTML. Cached as the
      // track, it would be served ahead of the stream and fail every play, so
      // refuse it on the header, before buffering any of the body.
      if (MediaContentType.isDocument(response.headers['content-type'])) {
        await response.stream.listen(null).cancel();
        throw StateError(
            'Jellyfin download failed (the server did not send audio).');
      }

      // Handed back as it arrives: the cache writes it to disk a chunk at a
      // time, so a big file is never held in memory whole.
      return downloadResponseBody(
        response,
        failure: 'Jellyfin download failed.',
        stallTimeout: _timeout,
      );
    } on StateError {
      // Our own friendly, token-free messages (bad status / not audio / not
      // signed in): surface them as-is.
      rethrow;
    } on Exception {
      // Never rethrow the original error: a ClientException/SocketException (or
      // a TimeoutException) can embed the tokenized URL in its message.
      throw StateError('Jellyfin download failed.');
    }
  }
}
