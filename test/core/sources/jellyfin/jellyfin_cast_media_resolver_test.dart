import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cast/cast_media_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_cast_media_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_stream_source.dart';

/// A configurable [JellyfinStreamSource] driving each cast-resolution outcome
/// without a real server, mirroring the playback resolver's fake.
class _FakeStreamSource implements JellyfinStreamSource {
  _FakeStreamSource({this.verifyError, this.streamError, this.streamUri});

  final JellyfinException? verifyError;
  final JellyfinException? streamError;
  final Uri? streamUri;
  int verifyCount = 0;

  @override
  Future<void> verifyReachable() async {
    verifyCount++;
    final JellyfinException? error = verifyError;
    if (error != null) throw error;
  }

  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    final JellyfinException? error = streamError;
    if (error != null) throw error;
    return streamUri;
  }
}

final _jellyfinTrack = Track(
  id: 't1',
  title: 'One',
  uri: 'jellyfin:t1',
  artistName: 'Artist',
  albumName: 'Album',
  artworkUri: Uri.parse('https://music.example.com/Items/t1/Images/Primary'),
);

const _localTrack = Track(id: 'l1', title: 'Local', uri: '/music/local.mp3');

void main() {
  group('JellyfinCastMediaResolver', () {
    test('only Jellyfin tracks are castable; local files are not', () {
      final resolver = JellyfinCastMediaResolver(() => null);
      expect(resolver.canCast(_jellyfinTrack), isTrue);
      expect(resolver.canCast(_localTrack), isFalse);
    });

    test('mints a castable URL at cast time, carrying the token in the URL',
        () async {
      final source = _FakeStreamSource(
        streamUri: Uri.parse(
          'https://music.example.com/Audio/t1/stream?static=true&api_key=TOKEN123',
        ),
      );
      final resolver = JellyfinCastMediaResolver(() => source);

      final media = await resolver.resolve(_jellyfinTrack);

      // The receiver fetches this URL itself, so the token must be in it — that
      // is the whole point of resolving at cast time rather than storing a URL.
      expect(media.url.scheme, 'https');
      expect(media.url.queryParameters['api_key'], 'TOKEN123');
      expect(media.title, 'One');
      expect(media.artist, 'Artist');
      expect(media.album, 'Album');
      expect(media.artworkUrl, _jellyfinTrack.artworkUri);
      // The session is verified before a URL is minted.
      expect(source.verifyCount, 1);
    });

    test('the minted URL is never leaked by the media\'s toString', () async {
      final source = _FakeStreamSource(
        streamUri: Uri.parse(
          'https://music.example.com/Audio/t1/stream?static=true&api_key=TOKEN123',
        ),
      );
      final resolver = JellyfinCastMediaResolver(() => source);

      final media = await resolver.resolve(_jellyfinTrack);
      expect(media.toString(), isNot(contains('TOKEN123')));
      expect(media.toString(), isNot(contains('api_key')));
    });

    test('reports "not signed in" when no source is connected', () async {
      final resolver = JellyfinCastMediaResolver(() => null);
      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(isA<CastMediaException>().having(
          (e) => e.kind,
          'kind',
          CastMediaErrorKind.notSignedIn,
        )),
      );
    });

    test('maps an expired session to a "sign in again" notSignedIn error',
        () async {
      final source =
          _FakeStreamSource(verifyError: JellyfinException.unauthorized());
      final resolver = JellyfinCastMediaResolver(() => source);
      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(isA<CastMediaException>().having(
          (e) => e.kind,
          'kind',
          CastMediaErrorKind.notSignedIn,
        )),
      );
    });

    test('maps other server failures to a generic unavailable error', () async {
      final source =
          _FakeStreamSource(streamError: JellyfinException.webPage());
      final resolver = JellyfinCastMediaResolver(() => source);
      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(isA<CastMediaException>().having(
          (e) => e.kind,
          'kind',
          CastMediaErrorKind.unavailable,
        )),
      );
    });

    test('reports unavailable when no URL can be built', () async {
      final source = _FakeStreamSource(streamUri: null);
      final resolver = JellyfinCastMediaResolver(() => source);
      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(isA<CastMediaException>().having(
          (e) => e.kind,
          'kind',
          CastMediaErrorKind.unavailable,
        )),
      );
    });

    test('no error message exposes the token or api_key', () async {
      Future<String> messageFor(_FakeStreamSource source) async {
        try {
          await JellyfinCastMediaResolver(() => source).resolve(_jellyfinTrack);
          fail('expected a CastMediaException');
        } on CastMediaException catch (e) {
          return e.message;
        }
      }

      for (final source in <_FakeStreamSource>[
        _FakeStreamSource(verifyError: JellyfinException.unauthorized()),
        _FakeStreamSource(streamError: JellyfinException.webPage()),
        _FakeStreamSource(streamUri: null),
      ]) {
        final message = await messageFor(source);
        expect(message, isNot(contains('api_key')));
        expect(message, isNot(contains('Token')));
      }
    });
  });
}
