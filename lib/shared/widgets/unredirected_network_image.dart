import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A network image that is never fetched through a redirect, for a cover URL
/// carrying a password (legacy Subsonic sign-in).
///
/// [NetworkImage] follows redirects and has no way to stop, so a server or
/// proxy redirecting `getCoverArt` would have the password sent on to wherever
/// it points, http included. This asks the exact URL only. A redirect, like any
/// answer but a 200, fails the load and the caller shows its placeholder.
///
/// It never says the URL: not in [toString], which reaches Flutter's error
/// reports through the image cache key, and not in the error a failed load
/// throws.
@immutable
class UnredirectedNetworkImage extends ImageProvider<UnredirectedNetworkImage> {
  const UnredirectedNetworkImage(this.url);

  final Uri url;

  static final HttpClient _sharedClient = HttpClient()..autoUncompress = false;

  @override
  Future<UnredirectedNetworkImage> obtainKey(
    ImageConfiguration configuration,
  ) =>
      SynchronousFuture<UnredirectedNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(
    UnredirectedNetworkImage key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key.url, decode),
        scale: 1.0,
        debugLabel: 'UnredirectedNetworkImage',
      );

  static Future<ui.Codec> _load(Uri url, ImageDecoderCallback decode) async {
    final Uint8List bytes = await fetch(url);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  /// The bytes at [url], asked for once with redirects off. Throws an
  /// [UnredirectedImageException], which never names the URL, for anything
  /// but a 200 with a body.
  @visibleForTesting
  static Future<Uint8List> fetch(Uri url, {HttpClient? client}) async {
    try {
      final HttpClientRequest request =
          await (client ?? _sharedClient).getUrl(url);
      request.followRedirects = false;
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.listen(null).cancel();
        throw UnredirectedImageException(response.statusCode);
      }
      final Uint8List bytes =
          await consolidateHttpClientResponseBytes(response);
      if (bytes.isEmpty) throw const UnredirectedImageException(null);
      return bytes;
    } on UnredirectedImageException {
      rethrow;
    } catch (_) {
      // A socket or HTTP error can carry the URL in its message.
      throw const UnredirectedImageException(null);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is UnredirectedNetworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'UnredirectedNetworkImage(<redacted>)';
}

/// Why an [UnredirectedNetworkImage] didn't load. Never carries the URL.
class UnredirectedImageException implements Exception {
  const UnredirectedImageException(this.statusCode);

  /// The HTTP status the server answered with, when it answered.
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? "Couldn't load the cover."
      : "Couldn't load the cover (HTTP $statusCode).";
}
