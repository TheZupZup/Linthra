// Numbers inside a quoted stream URL are not an HTTP status.
//
// classifyEngineError looked for '401'/'403' anywhere in the raw error text.
// When that text quotes the stream URL (libmpv's "Failed to open <url>.", or
// a ClientException's "uri=..."), numbers inside an item id, a Plex part
// timestamp or a token read as an HTTP status, and a dropped connection was
// reported as an expired session: no retry, and "Sign in again" for a session
// that is fine. Neither engine hands it URL-bearing text today, so this is
// defence in depth.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:linthra/core/services/stream_interruption.dart';

void main() {
  test('numbers inside a quoted stream URL are not an HTTP 401/403', () {
    final List<String> misclassified = <String>[
      for (final String url in <String>[
        // Jellyfin: hex item id and ApiKey that happen to contain 401 / 403.
        'https://h/Audio/ab401c/stream?static=true&ApiKey=f403e',
        // Plex: a part path carries a Unix timestamp; 1704031234 contains 403.
        'http://10.0.0.5:32400/library/parts/7/1704031234/file.flac'
            '?X-Plex-Token=t',
        // Subsonic: hex token and salt.
        'https://navi.example/rest/stream.view?id=1&u=a&t=9f4013&s=c403d',
      ])
        if (classifyEngineError(PlayerException(0, 'Failed to open $url.'))
                .kind ==
            StreamInterruptionKind.sessionExpired)
          url,
    ];

    expect(misclassified, isEmpty);
  });

  test('a status the engine reports beside the URL still reads as one', () {
    for (final String message in <String>[
      'Failed to open https://h/Audio/1/stream?ApiKey=k: 403 Forbidden',
      'HTTP 401 Unauthorized, uri=https://h/Audio/1/stream?ApiKey=k',
      'Response code: 403',
    ]) {
      expect(
        classifyEngineError(PlayerException(0, message)).kind,
        StreamInterruptionKind.sessionExpired,
        reason: message,
      );
    }
  });
}
