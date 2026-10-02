import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_media_kit/mediakit_player.dart';

// libmpv's error lines go to stdout, which a desktop session writes to the
// system journal. They name the source, and a stream URL carries the
// account's credentials in its query, so no URL may survive into one.
void main() {
  group('MediaKitPlayer.redactLogText', () {
    test('takes a Jellyfin stream URL and its ApiKey out of an open failure',
        () {
      final String line = MediaKitPlayer.redactLogText(
        'Failed to open https://music.example.com/Audio/abc/stream'
        '?static=true&ApiKey=SECRET&UserId=u1&DeviceId=d1.',
      );

      expect(line, 'Failed to open <url>');
      expect(line, isNot(contains('SECRET')));
      expect(line, isNot(contains('music.example.com')));
    });

    test('takes Subsonic and Plex tokens out too', () {
      for (final String url in <String>[
        'https://navi.example/rest/stream.view?id=1&u=alice&t=TOKEN&s=SALT',
        'http://10.0.0.5:32400/library/parts/7/1704031234/file.flac'
            '?X-Plex-Token=PLEXTOKEN',
      ]) {
        final String line =
            MediaKitPlayer.redactLogText('Failed to open $url.');
        expect(line, 'Failed to open <url>');
      }
    });

    test('takes a server address out of a connection error', () {
      expect(
        MediaKitPlayer.redactLogText(
          'tcp: Connection to tcp://192.168.1.20:8096 failed: '
          'Connection refused',
        ),
        'tcp: Connection to <url> failed: Connection refused',
      );
    });

    test('leaves a line with no URL as it was', () {
      const String line = 'Failed to recognize file format.';
      expect(MediaKitPlayer.redactLogText(line), line);
    });
  });
}
