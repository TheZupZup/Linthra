import 'dart:async';

import 'package:http/http.dart' as http;

import '../../models/track.dart';
import '../../services/remote_track_downloader.dart';
import '../audio_file_extension.dart';
import 'subsonic_stream_source.dart';
import 'subsonic_track_mapper.dart';

/// The [RemoteTrackDownloader] for Subsonic/Navidrome tracks.
///
/// Resolves the authenticated original-file download URL only at fetch time —
/// through the live signed-in [SubsonicStreamSource], read via a getter so
/// signing in or out is picked up without a rebuild — then streams the bytes
/// over HTTP. The URL, and the salt+token woven into it, never leave [open]: not
/// stored, not returned, and not placed in any thrown error (a transport failure
/// is re-raised as a generic message so a `ClientException` carrying the
/// credentialed URL can't escape).
class SubsonicTrackDownloader implements RemoteTrackDownloader {
  SubsonicTrackDownloader(this._source, {http.Client? httpClient})
      : _client = httpClient ?? http.Client();

  /// Supplies the current signed-in source, or `null` when not connected.
  final SubsonicStreamSource? Function() _source;

  final http.Client _client;

  static const Duration _timeout = Duration(minutes: 5);

  @override
  bool isRemote(Track track) =>
      track.uri.startsWith(SubsonicTrackMapper.uriScheme);

  @override
  Future<RemoteTrackDownload> open(Track track) async {
    final SubsonicStreamSource? source = _source();
    if (source == null) {
      throw StateError('Not signed in to Subsonic/Navidrome.');
    }

    await source.verifyReachable();

    final Uri? uri = await source.resolvePlayableUri(track);
    if (uri == null) {
      throw StateError('No download URL for this track.');
    }

    try {
      // The request carries the credential in its URL, but the URL never leaves
      // this method, is never logged, and any transport error below is replaced
      // with a generic message so it can't escape either. The body is returned as
      // a stream so the cache can write it to disk without buffering all bytes.
      final http.StreamedResponse response =
          await _client.send(http.Request('GET', uri)).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw StateError('Download failed (HTTP ${response.statusCode}).');
      }

      final int? total =
          (response.contentLength != null && response.contentLength! > 0)
              ? response.contentLength
              : null;
      return RemoteTrackDownload(
        chunks: _safeStream(response.stream),
        contentLength: total,
        fileExtension:
            AudioFileExtension.forContentType(response.headers['content-type']),
      );
    } on StateError {
      // Our own friendly, credential-free messages (bad status / not signed in):
      // surface them as-is.
      rethrow;
    } on Exception {
      // Never rethrow the original error: a ClientException/SocketException (or
      // a TimeoutException) can embed the credentialed URL in its message.
      throw StateError('Download failed.');
    }
  }

  Stream<List<int>> _safeStream(Stream<List<int>> stream) async* {
    try {
      await for (final List<int> chunk in stream.timeout(_timeout)) {
        yield chunk;
      }
    } on Exception {
      // A body-stream error can also carry transport detail. Keep it generic.
      throw StateError('Download failed.');
    }
  }
}
