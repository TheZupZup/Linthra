import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/services/cast/cast_load_message.dart';

/// A token-bearing stream URL like the resolvers mint at cast time.
final _streamUrl = Uri.parse(
  'https://music.example.com/Audio/t1/stream?static=true&api_key=SECRET-TOKEN',
);

CastMedia _media({
  String? title = 'Midnight',
  String? artist = 'Kavinsky',
  String? album = 'OutRun',
  Duration? duration = const Duration(minutes: 3, seconds: 30),
  Uri? artworkUrl,
}) =>
    CastMedia(
      url: _streamUrl,
      contentType: 'audio/mpeg',
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      artworkUrl: artworkUrl,
    );

void main() {
  group('CastLoadMessage envelope', () {
    test('is a LOAD that autoplays from the start, tagged with the requestId',
        () {
      final msg = CastLoadMessage.build(_media(), requestId: 7);
      expect(msg['type'], 'LOAD');
      expect(msg['requestId'], 7);
      expect(msg['autoplay'], isTrue);
      expect(msg['currentTime'], 0);
      expect(msg['media'], isA<Map<String, dynamic>>());
    });

    test('the contentId is the reachable stream URL the receiver fetches', () {
      final info = CastLoadMessage.mediaInfo(_media());
      expect(info['contentId'], _streamUrl.toString());
      expect(info['contentType'], 'audio/mpeg');
      expect(info['streamType'], CastLoadMessage.bufferedStreamType);
    });
  });

  group('metadata', () {
    test('is tagged as a music track and includes the title', () {
      final meta = CastLoadMessage.metadata(_media(title: 'Midnight'));
      expect(meta['metadataType'], CastLoadMessage.musicTrackMetadataType);
      expect(meta['title'], 'Midnight');
    });

    test('includes artist and album when available', () {
      final meta =
          CastLoadMessage.metadata(_media(artist: 'Kavinsky', album: 'OutRun'));
      expect(meta['artist'], 'Kavinsky');
      expect(meta['albumName'], 'OutRun');
    });

    test('omits artist/album keys entirely when null', () {
      final meta = CastLoadMessage.metadata(_media(artist: null, album: null));
      expect(meta.containsKey('artist'), isFalse);
      expect(meta.containsKey('albumName'), isFalse);
    });

    test('includes artwork as an images list only when an URL is present', () {
      final withArt = CastLoadMessage.metadata(_media(
        artworkUrl:
            Uri.parse('https://music.example.com/Items/t1/Images/Primary'),
      ));
      expect(withArt['images'], <Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'https://music.example.com/Items/t1/Images/Primary',
        },
      ]);
    });

    test(
        'omits the images key entirely when there is no artwork (e.g. Subsonic)',
        () {
      final meta = CastLoadMessage.metadata(_media(artworkUrl: null));
      expect(meta.containsKey('images'), isFalse);
    });
  });

  group('duration', () {
    test('is sent in seconds when known', () {
      final info = CastLoadMessage.mediaInfo(
        _media(duration: const Duration(minutes: 3, seconds: 30)),
      );
      expect(info['duration'], 210.0);
    });

    test('is omitted when unknown (null)', () {
      final info = CastLoadMessage.mediaInfo(_media(duration: null));
      expect(info.containsKey('duration'), isFalse);
    });

    test('is omitted when zero', () {
      final info = CastLoadMessage.mediaInfo(_media(duration: Duration.zero));
      expect(info.containsKey('duration'), isFalse);
    });
  });

  group('security: the token rides only on the contentId, never the metadata',
      () {
    test('the displayed metadata block never carries the stream token', () {
      final meta = CastLoadMessage.metadata(_media(
        // Even an (incorrectly) token-bearing artwork URL would be the only
        // other place a token could appear — assert the safe path stays clean.
        artworkUrl:
            Uri.parse('https://music.example.com/Items/t1/Images/Primary'),
      ));
      expect(meta.toString(), isNot(contains('SECRET-TOKEN')));
      expect(meta.toString(), isNot(contains('api_key')));
    });

    test('only the contentId field contains the authenticated URL', () {
      final info = CastLoadMessage.mediaInfo(_media());
      // The contentId must carry the token (the receiver fetches it itself)...
      expect(info['contentId'], contains('api_key=SECRET-TOKEN'));
      // ...but nothing in the metadata does.
      expect(info['metadata'].toString(), isNot(contains('SECRET-TOKEN')));
    });
  });
}
