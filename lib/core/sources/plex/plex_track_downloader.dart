import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/track.dart';
import '../../services/remote_track_downloader.dart';
import '../audio_file_extension.dart';
import 'plex_download_source.dart';
import 'plex_track_mapper.dart';

/// The [RemoteTrackDownloader] for Plex tracks.
///
/// Resolves the authenticated download URL only at fetch time — through the live
/// signed-in [PlexDownloadSource], read via a getter so signing in or out is
/// picked up without a rebuild — then fetches the bytes over HTTP. The URL, and
/// the `X-Plex-Token` woven into its query, never leave [fetch]: not stored, not
/// returned, and not placed in any thrown error (a transport failure is
/// re-raised as a generic message so a `ClientException` carrying the tokenized
/// URL can't escape).
///
/// The session check and URL resolution run *before* the transport try-block, so
/// a typed, token-free `PlexException` from them (expired token, unreachable
/// server, a vanished item) surfaces as-is — exactly as the play path surfaces
/// it — rather than being flattened to the generic transport message.
class PlexTrackDownloader implements RemoteTrackDownloader {
  PlexTrackDownloader(this._source, {http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  /// Supplies the current signed-in source, or `null` when not connected.
  final PlexDownloadSource? Function() _source;

  final http.Client _client;

  static const Duration _timeout = Duration(minutes: 5);

  @override
  bool isRemote(Track track) => track.uri.startsWith(PlexTrackMapper.uriScheme);

  @override
  Future<RemoteTrackData> fetch(
    Track track, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final PlexDownloadSource? source = _source();
    if (source == null) {
      throw StateError('Not signed in to your Plex server.');
    }

    // Confirm the session still works before fetching; the PlexException this
    // may throw is friendly and token-free by design.
    await source.verifyReachable();

    final Uri? uri = await source.resolveDownloadUri(track);
    if (uri == null) {
      throw StateError('No Plex download URL for this track.');
    }

    try {
      // Stream the body so progress can be reported as bytes arrive. The request
      // carries the token in its URL, but the URL never leaves this method, is
      // never logged, and any transport error below is replaced with a generic
      // message so it can't escape either.
      final http.StreamedResponse response =
          await _client.send(http.Request('GET', uri)).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw StateError('Plex download failed (HTTP ${response.statusCode}).');
      }

      final int? total =
          (response.contentLength != null && response.contentLength! > 0)
              ? response.contentLength
              : null;
      final BytesBuilder builder = BytesBuilder(copy: false);
      int received = 0;
      onProgress?.call(received, total);
      await for (final List<int> chunk in response.stream.timeout(_timeout)) {
        builder.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      return RemoteTrackData(
        bytes: builder.takeBytes(),
        fileExtension:
            AudioFileExtension.forContentType(response.headers['content-type']),
      );
    } on StateError {
      // Our own friendly, token-free messages (bad status / not signed in):
      // surface them as-is.
      rethrow;
    } on Exception {
      // Never rethrow the original error: a ClientException/SocketException (or
      // a TimeoutException) can embed the tokenized URL in its message.
      throw StateError('Plex download failed.');
    }
  }
}
