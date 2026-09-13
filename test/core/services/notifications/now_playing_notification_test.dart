import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
import 'package:linthra/core/services/notifications/desktop_notifier.dart';
import 'package:linthra/core/services/notifications/now_playing_notification.dart';

/// A [MediaArtworkSource] holding exactly the covers a test says are cached.
class _FakeArtwork implements MediaArtworkSource {
  _FakeArtwork({this.files = const <String, String>{}});

  /// Reference string -> cached file path.
  final Map<String, String> files;

  final List<Uri> asked = <Uri>[];

  @override
  Uri? cached(Uri reference) => throw UnimplementedError(
        'the notification path must ask for the file form, not the '
        'Android content:// form',
      );

  @override
  Uri? cachedFileUri(Uri reference) {
    asked.add(reference);
    final String? path = files[reference.toString()];
    return path == null ? null : Uri.file(path);
  }

  @override
  Stream<Uri> get coverReady => const Stream<Uri>.empty();
}

Track _track({
  String title = 'Trouble',
  String? artist = 'Cat Power',
  String? album = 'Moon Pix',
  String uri = 'jellyfin:track-7',
  Uri? artworkUri,
}) =>
    Track(
      id: 'track-7',
      title: title,
      uri: uri,
      artistName: artist,
      albumName: album,
      albumId: 'jellyfin:al-3',
      artworkUri: artworkUri,
    );

void main() {
  group('what is said', () {
    test('the title and the catalog subtitle, and nothing else', () {
      final DesktopNotification notification = nowPlayingNotification(_track());

      expect(notification.title, 'Trouble');
      expect(notification.body, 'Cat Power • Moon Pix');
      expect(notification.image, isNull);
    });

    test('an unknown artist and album leave the body empty', () {
      final DesktopNotification notification = nowPlayingNotification(
        _track(artist: null, album: null),
      );

      expect(notification.title, 'Trouble');
      expect(notification.body, isEmpty);
    });

    test('a track with no title reads as unknown, never as its path', () {
      final DesktopNotification notification = nowPlayingNotification(
        _track(title: '   ', uri: '/home/dana/Music/Secret Project/01.flac'),
      );

      expect(notification.title, kUnknownTrackNotificationTitle);
      expect(notification.body, 'Cat Power • Moon Pix');
    });

    test('nothing a server or a filesystem knows leaks into it', () {
      final DesktopNotification notification = nowPlayingNotification(
        _track(
          uri: 'https://music.example.com/stream?id=7&api_key=SECRET-TOKEN',
          artworkUri: Uri.parse(
            'https://music.example.com/art/7?api_key=SECRET-TOKEN',
          ),
        ),
      );

      final String everything =
          '${notification.title}|${notification.body}|${notification.image}';
      for (final String forbidden in <String>[
        'SECRET-TOKEN',
        'api_key',
        'music.example.com',
        'jellyfin:al-3',
        'track-7',
      ]) {
        expect(everything, isNot(contains(forbidden)));
      }
    });
  });

  group('artwork', () {
    test('a cover Linthra cached as a file passes through', () {
      final Uri cover = Uri.file('/home/dana/.cache/linthra/local/abc.img');

      expect(safeNotificationImage(cover), cover);
    });

    test('a credentialed or remote cover URL never goes out', () {
      expect(
        safeNotificationImage(
          Uri.parse('https://music.example.com/art/7?api_key=SECRET-TOKEN'),
        ),
        isNull,
      );
      expect(
        safeNotificationImage(Uri.parse('http://192.168.1.9/art/7')),
        isNull,
      );
    });

    test('an Android content:// cover never goes out', () {
      // Nothing on a Linux desktop can open one, and it is the platform's
      // FileProvider form rather than a file.
      expect(
        safeNotificationImage(
          Uri.parse('content://io.github.thezupzup.linthra.mediaartwork/a.img'),
        ),
        isNull,
      );
    });

    test('an app-internal reference goes out only once it is cached', () {
      final Uri reference = Uri.parse('subsonic-cover:al-27');
      final _FakeArtwork empty = _FakeArtwork();

      expect(safeNotificationImage(reference, artwork: empty), isNull);
      expect(empty.asked, <Uri>[reference]);

      final _FakeArtwork warmed = _FakeArtwork(
        files: <String, String>{
          'subsonic-cover:al-27': '/home/dana/.cache/linthra/media/9f.img',
        },
      );
      expect(
        safeNotificationImage(reference, artwork: warmed),
        Uri.file('/home/dana/.cache/linthra/media/9f.img'),
      );
    });

    test('a reference with no artwork cache at all is simply no cover', () {
      expect(safeNotificationImage(Uri.parse('plex-thumb:/library/1')), isNull);
      expect(safeNotificationImage(null), isNull);
    });

    test('the built notification carries the cached cover', () {
      final DesktopNotification notification = nowPlayingNotification(
        _track(artworkUri: Uri.parse('subsonic-cover:al-27')),
        artwork: _FakeArtwork(
          files: <String, String>{
            'subsonic-cover:al-27': '/home/dana/.cache/linthra/media/9f.img',
          },
        ),
      );

      expect(
        notification.image,
        Uri.file('/home/dana/.cache/linthra/media/9f.img'),
      );
    });
  });
}
