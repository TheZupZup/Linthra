import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Debug-only, secret-free diagnostics for playback resolution.
///
/// Surfaces *why* a track resolved the way it did — its source, the resolver
/// that handled it, and (for remote streams) the HTTP status and content type
/// observed when the stream URL was probed — so field failures are diagnosable
/// from a debug log. It is silent in release builds and, by construction, can
/// only emit non-secret metadata: the API has no parameter for a token,
/// password, full authenticated URL, or `Authorization` header, and the item id
/// is hashed before it is ever included.
abstract final class PlaybackDiagnostics {
  /// Logs a resolution attempt to the `playback` developer-log channel, but
  /// only in debug builds (this includes `flutter test`). A no-op in release.
  static void resolved({
    required String source,
    required String resolver,
    String? itemId,
    int? statusCode,
    String? contentType,
  }) {
    if (!kDebugMode) return;
    developer.log(
      describe(
        source: source,
        resolver: resolver,
        itemId: itemId,
        statusCode: statusCode,
        contentType: contentType,
      ),
      name: 'playback',
    );
  }

  /// Builds the one-line, secret-free description [resolved] logs. Pure and
  /// public so a test can assert it carries the diagnostic fields and leaks no
  /// secret (it cannot — there is no parameter for one, and the id is redacted).
  static String describe({
    required String source,
    required String resolver,
    String? itemId,
    int? statusCode,
    String? contentType,
  }) {
    return <String>[
      'source=$source',
      'resolver=$resolver',
      if (itemId != null) 'item=${redactId(itemId)}',
      if (statusCode != null) 'status=$statusCode',
      if (contentType != null) 'contentType=${_mimeOnly(contentType)}',
    ].join(' ');
  }

  /// A short, non-reversible tag for an item id so debug logs can correlate
  /// attempts for one track without exposing the real id.
  static String redactId(String id) =>
      'id#${(id.hashCode & 0x7fffffff).toRadixString(16)}';

  /// Strips any parameters (`; charset=…`) from a content type so the log shows
  /// just the MIME type.
  static String _mimeOnly(String contentType) =>
      contentType.split(';').first.trim();
}
