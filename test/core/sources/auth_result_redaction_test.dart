import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/audiobookshelf/audiobookshelf_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';

// A sign-in result is the first object in each provider's flow to hold the
// freshly granted token, and the one most likely to be interpolated into a
// debug print or an error while sign-in is being diagnosed. Its toString must
// never render a token. Jellyfin's redacts on purpose; Audiobookshelf's (access
// and refresh token) must stay just as quiet, whether by redaction or by not
// rendering fields at all.

const String _jellyfinToken = 'jellyfin-access-token-do-not-leak';
const String _absAccessToken = 'abs-access-token-do-not-leak';
const String _absRefreshToken = 'abs-refresh-token-do-not-leak';

void main() {
  group('JellyfinAuthResult.toString', () {
    test('redacts the token but keeps the non-secret identity', () {
      const JellyfinAuthResult result = JellyfinAuthResult(
        accessToken: _jellyfinToken,
        userId: 'user-1',
        userName: 'alice',
        serverId: 'server-1',
      );

      final String text = result.toString();

      expect(text, isNot(contains(_jellyfinToken)));
      expect(text, contains('accessToken: <redacted>'));
      expect(text, contains('user-1'));
      expect(text, contains('alice'));
      expect(text, contains('server-1'));
    });

    test('a result parsed from the server response redacts it too', () {
      final JellyfinAuthResult result = JellyfinAuthResult.fromJson(
        <String, dynamic>{
          'AccessToken': _jellyfinToken,
          'ServerId': 'server-1',
          'User': <String, dynamic>{'Id': 'user-1', 'Name': 'alice'},
        },
      )!;

      expect(result.accessToken, _jellyfinToken);
      expect('$result', isNot(contains(_jellyfinToken)));
      expect('$result', contains('<redacted>'));
    });
  });

  group('AudiobookshelfAuthResult.toString', () {
    test('renders neither the access nor the refresh token', () {
      const AudiobookshelfAuthResult result = AudiobookshelfAuthResult(
        userId: 'user-1',
        accessToken: _absAccessToken,
        refreshToken: _absRefreshToken,
        userName: 'alice',
        defaultLibraryId: 'lib-1',
      );

      final String text = result.toString();

      expect(text, isNot(contains(_absAccessToken)));
      expect(text, isNot(contains(_absRefreshToken)));
    });

    test('a legacy server token, parsed as the access token, stays hidden', () {
      // Servers before 2.26.0 send only `token`, which never expires.
      final AudiobookshelfAuthResult result = AudiobookshelfAuthResult.fromJson(
        <String, dynamic>{
          'user': <String, dynamic>{
            'id': 'user-1',
            'username': 'alice',
            'token': _absAccessToken,
          },
        },
      )!;

      expect(result.accessToken, _absAccessToken);
      expect('$result', isNot(contains(_absAccessToken)));
    });
  });
}
