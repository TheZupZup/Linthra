import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/track.dart';
import '../../services/remote_track_downloader.dart';
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
      // Stream the body so progress can be reported as bytes arrive. The
      // request carries the token in its URL, but the URL never leaves this
      // method, is never logged, and any transport error below is replaced
      // with a generic message so it can't escape either.
      final http.StreamedResponse response =
          await _client.send(http.Request('GET', uri)).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw StateError(
            'Jellyfin download failed (HTTP ${response.statusCode}).');
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
        fileExtension: _extensionFor(response.headers['content-type']),
      );
    } on StateError {
      // Our own friendly, token-free messages (bad status / not signed in):
      // surface them as-is.
      rethrow;
    } on Exception {
      // Never rethrow the original error: a ClientException/SocketException (or
      // a TimeoutException) can embed the tokenized URL in its message.
      throw StateError('Jellyfin download failed.');
    }
  }

  /// Maps a response content type to a cache-file extension. Returns `null` for
  /// unknown types; the player sniffs the container regardless, so the extension
  /// is only a convenience.
  static String? _extensionFor(String? contentType) {
    if (contentType == null) return null;
    final String type = contentType.split(';').first.trim().toLowerCase();
    switch (type) {
      case 'audio/mpeg':
      case 'audio/mp3':
        return 'mp3';
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
      case 'audio/mp4':
      case 'audio/m4a':
      case 'audio/x-m4a':
        return 'm4a';
      case 'audio/aac':
        return 'aac';
      case 'audio/ogg':
      case 'application/ogg':
        return 'ogg';
      case 'audio/opus':
        return 'opus';
      case 'audio/wav':
      case 'audio/x-wav':
      case 'audio/wave':
        return 'wav';
      default:
        return null;
    }
  }
}
