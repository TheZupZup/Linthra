import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';

void main() {
  group('CastMedia', () {
    test('keeps the full URL (token and all) for the receiver to fetch', () {
      final media = CastMedia(
        url: Uri.parse(
          'https://music.example.com/Audio/t1/stream?static=true&api_key=SECRET-TOKEN',
        ),
        contentType: 'audio/mpeg',
        title: 'Song',
      );
      // The receiver needs the real, authenticated URL — it is only ever held
      // here and handed straight to the cast session, never persisted.
      expect(media.url.queryParameters['api_key'], 'SECRET-TOKEN');
    });

    test('toString redacts the token-bearing query so it can never leak', () {
      final media = CastMedia(
        url: Uri.parse(
          'https://music.example.com/Audio/t1/stream?static=true&api_key=SECRET-TOKEN',
        ),
        contentType: 'audio/mpeg',
        title: 'Song',
      );

      final text = media.toString();
      expect(text, isNot(contains('SECRET-TOKEN')));
      expect(text, isNot(contains('api_key')));
      expect(text, isNot(contains('static=true')));
      // The non-secret parts survive so a log is still useful.
      expect(text, contains('music.example.com'));
      expect(text, contains('/Audio/t1/stream'));
      expect(text, contains('audio/mpeg'));
    });

    test('toString redacts any userinfo too', () {
      final media = CastMedia(
        url: Uri.parse(
          'https://myuser:mypass@host.example/Audio/x/stream?api_key=ZZZTOKEN',
        ),
        contentType: 'audio/mpeg',
      );
      final text = media.toString();
      expect(text, isNot(contains('myuser')));
      expect(text, isNot(contains('mypass')));
      expect(text, isNot(contains('ZZZTOKEN')));
    });

    test('carries the optional duration and artwork when given', () {
      final media = CastMedia(
        url: Uri.parse('https://music.example.com/Audio/t1/stream'),
        contentType: 'audio/mpeg',
        title: 'Song',
        duration: const Duration(minutes: 4),
        artworkUrl:
            Uri.parse('https://music.example.com/Items/t1/Images/Primary'),
      );
      expect(media.duration, const Duration(minutes: 4));
      expect(media.artworkUrl,
          Uri.parse('https://music.example.com/Items/t1/Images/Primary'));
    });

    test('duration and artwork are null when omitted', () {
      final media = CastMedia(
        url: Uri.parse('https://music.example.com/Audio/t1/stream'),
        contentType: 'audio/mpeg',
      );
      expect(media.duration, isNull);
      expect(media.artworkUrl, isNull);
    });
  });
}
