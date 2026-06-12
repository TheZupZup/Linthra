import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'playback_diagnostics.dart';

/// Debug-only, secret-free diagnostics for lyrics lookups.
///
/// Mirrors [PlaybackDiagnostics]: surfaces *which provider* answered a lookup
/// and how it ended (synced/plain lyrics, none, or a typed failure) so a field
/// report like "no lyrics on Navidrome" is diagnosable from a debug log. It is
/// silent in release builds and, by construction, can only emit non-secret
/// metadata: the API has no parameter for a token, credential, URL, or error
/// *message* (a raw transport error can embed a host or query string) — a
/// failure is recorded as the error's runtime type only, and the track id is
/// hashed before it is ever included.
abstract final class LyricsDiagnostics {
  /// Logs one lookup to the `lyrics` developer-log channel, but only in debug
  /// builds (this includes `flutter test`). A no-op in release.
  static void lookedUp({
    required String source,
    required String provider,
    required String outcome,
    String? trackId,
  }) {
    if (!kDebugMode) return;
    developer.log(
      describe(
        source: source,
        provider: provider,
        outcome: outcome,
        trackId: trackId,
      ),
      name: 'lyrics',
    );
  }

  /// The outcome tag for a successful lookup: what shape of lyrics came back.
  static String found(bool synced) => synced ? 'synced' : 'plain';

  /// The outcome tag for a lookup that yielded no lyrics (the calm empty
  /// state, not a failure).
  static const String none = 'none';

  /// The outcome tag for a failed lookup. Deliberately the error's *type*
  /// only: an arbitrary error's message may carry a URL or host, and this API
  /// must stay incapable of leaking one.
  static String failed(Object error) => 'error:${error.runtimeType}';

  /// Builds the one-line, secret-free description [lookedUp] logs. Pure and
  /// public so a test can assert it carries the diagnostic fields and leaks no
  /// secret (it cannot — there is no parameter for one, and the id is
  /// redacted).
  static String describe({
    required String source,
    required String provider,
    required String outcome,
    String? trackId,
  }) {
    return <String>[
      'source=$source',
      'provider=$provider',
      'outcome=$outcome',
      if (trackId != null) 'track=${PlaybackDiagnostics.redactId(trackId)}',
    ].join(' ');
  }
}
