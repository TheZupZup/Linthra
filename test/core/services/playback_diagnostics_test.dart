import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/playback_diagnostics.dart';

void main() {
  group('PlaybackDiagnostics.describe', () {
    test('carries the non-secret resolution fields', () {
      final line = PlaybackDiagnostics.describe(
        source: 'jellyfin',
        resolver: 'JellyfinPlayableUriResolver',
        itemId: 'item-123',
        statusCode: 200,
        contentType: 'audio/mpeg',
      );

      expect(line, contains('source=jellyfin'));
      expect(line, contains('resolver=JellyfinPlayableUriResolver'));
      expect(line, contains('status=200'));
      expect(line, contains('contentType=audio/mpeg'));
    });

    test('redacts the item id rather than logging it raw', () {
      final line = PlaybackDiagnostics.describe(
        source: 'jellyfin',
        resolver: 'JellyfinPlayableUriResolver',
        itemId: 'super-distinctive-item-id',
      );

      expect(line, isNot(contains('super-distinctive-item-id')));
      expect(
          line,
          contains(
              'item=${PlaybackDiagnostics.redactId('super-distinctive-item-id')}'));
    });

    test('strips content-type parameters to the bare MIME type', () {
      final line = PlaybackDiagnostics.describe(
        source: 'jellyfin',
        resolver: 'r',
        contentType: 'text/html; charset=utf-8',
      );

      expect(line, contains('contentType=text/html'));
      expect(line, isNot(contains('charset')));
    });

    test('omits fields that were not observed', () {
      final line = PlaybackDiagnostics.describe(
        source: 'local',
        resolver: 'LocalPlayableUriResolver',
      );

      expect(line, isNot(contains('status=')));
      expect(line, isNot(contains('contentType=')));
      expect(line, isNot(contains('item=')));
    });

    test('redactId is stable and not the raw id', () {
      expect(PlaybackDiagnostics.redactId('abc'),
          PlaybackDiagnostics.redactId('abc'));
      expect(PlaybackDiagnostics.redactId('abc'), isNot('abc'));
      expect(PlaybackDiagnostics.redactId('abc'), startsWith('id#'));
    });
  });
}
