import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/stream_interruption.dart';

/// A stand-in for the audio engine's raw error whose [toString] carries text the
/// classifier branches on — including, deliberately, a tokenized URL, so we can
/// prove the friendly message never echoes it.
class _EngineError {
  _EngineError(this._text);
  final String _text;
  @override
  String toString() => _text;
}

void main() {
  group('classifyEngineError', () {
    test('a transient network drop is recoverable (retryable)', () {
      for (final String raw in <String>[
        'SocketException: Connection reset by peer',
        'Source error: connection closed',
        'java.net.SocketTimeoutException: timeout',
        'Network is unreachable while reading',
      ]) {
        final result = classifyEngineError(_EngineError(raw));
        expect(
          result.retryable,
          isTrue,
          reason: 'expected "$raw" to be retryable',
        );
        expect(
          result.kind,
          anyOf(
            StreamInterruptionKind.networkDropped,
            StreamInterruptionKind.serverUnreachable,
          ),
        );
      }
    });

    test('an expired session maps to a sign-in error and is not retried', () {
      final StreamInterruption result = classifyEngineError(
        _EngineError('PlayerException(0, Response 401 Unauthorized)'),
      );

      expect(result.kind, StreamInterruptionKind.sessionExpired);
      expect(result.retryable, isFalse);
      expect(result.message.toLowerCase(), contains('sign in'));
    });

    test('an unreachable server maps to a friendly, retryable error', () {
      final StreamInterruption result = classifyEngineError(
        _EngineError('Failed host lookup: music.example.com'),
      );

      expect(result.kind, StreamInterruptionKind.serverUnreachable);
      expect(result.retryable, isTrue);
      expect(result.message, contains("Couldn't reach your music server"));
    });

    test('an unsupported format is not retried', () {
      final result = classifyEngineError(
        _EngineError('PlayerException: unsupported codec'),
      );

      expect(result.kind, StreamInterruptionKind.formatUnsupported);
      expect(result.retryable, isFalse);
    });

    test('an unknown error defaults to a single retry', () {
      final StreamInterruption result =
          classifyEngineError(_EngineError('something inexplicable happened'));

      expect(result.kind, StreamInterruptionKind.unknown);
      expect(result.retryable, isTrue);
    });

    test('the friendly message never echoes the raw error (no token leak)', () {
      // A real ExoPlayer/HTTP error often echoes the failing request URL, which
      // for a stream carries the access token. The classifier must branch on it
      // without ever surfacing it.
      const String tokenized =
          'ClientException: Connection reset, uri=https://music.example.com/'
          'Audio/abc/stream?static=true&api_key=SUPERSECRETTOKEN';
      final StreamInterruption result =
          classifyEngineError(_EngineError(tokenized));

      expect(result.message, isNot(contains('api_key')));
      expect(result.message, isNot(contains('SUPERSECRETTOKEN')));
      expect(result.message, isNot(contains('music.example.com')));
      // It is still classified as a recoverable network drop.
      expect(result.retryable, isTrue);
    });
  });
}
