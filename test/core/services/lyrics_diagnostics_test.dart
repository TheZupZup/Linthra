import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/lyrics_diagnostics.dart';
import 'package:linthra/core/services/playback_diagnostics.dart';

/// An error whose message carries exactly the secrets a lyrics log must never
/// contain — so the type-only contract is provable, not assumed.
class _LeakyError implements Exception {
  @override
  String toString() =>
      'https://music.example.com/rest/getLyrics?u=alice&t=tok1&s=salt1';
}

void main() {
  group('LyricsDiagnostics.describe', () {
    test('carries the non-secret lookup fields', () {
      final line = LyricsDiagnostics.describe(
        source: 'subsonic',
        provider: 'SubsonicLyricsProvider',
        outcome: 'synced',
        trackId: 's-7',
      );

      expect(line, contains('source=subsonic'));
      expect(line, contains('provider=SubsonicLyricsProvider'));
      expect(line, contains('outcome=synced'));
    });

    test('redacts the track id rather than logging it raw', () {
      final line = LyricsDiagnostics.describe(
        source: 'jellyfin',
        provider: 'JellyfinLyricsProvider',
        outcome: 'none',
        trackId: 'super-distinctive-track-id',
      );

      expect(line, isNot(contains('super-distinctive-track-id')));
      expect(
        line,
        contains(
            'track=${PlaybackDiagnostics.redactId('super-distinctive-track-id')}'),
      );
    });

    test('omits the track field when no id was observed', () {
      final line = LyricsDiagnostics.describe(
        source: 'local',
        provider: 'LocalLyricsProvider',
        outcome: 'plain',
      );

      expect(line, isNot(contains('track=')));
    });
  });

  group('LyricsDiagnostics outcome tags', () {
    test('found distinguishes synced from plain lyrics', () {
      expect(LyricsDiagnostics.found(true), 'synced');
      expect(LyricsDiagnostics.found(false), 'plain');
    });

    test('a failure is recorded by type only — never its message, which can '
        'carry a URL with credentials', () {
      final outcome = LyricsDiagnostics.failed(_LeakyError());

      expect(outcome, 'error:_LeakyError');
      expect(outcome, isNot(contains('tok1')));
      expect(outcome, isNot(contains('salt1')));
      expect(outcome, isNot(contains('alice')));
      expect(outcome, isNot(contains('https://')));
    });
  });
}
