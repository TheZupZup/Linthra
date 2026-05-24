import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_exception.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_stream_source.dart';

/// A configurable [JellyfinStreamSource] that drives each playback outcome
/// without a real server: verification can throw, minting can throw (as it does
/// when the play-time stream probe rejects the response), and the minted URI can
/// be canned or absent.
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
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    final JellyfinException? error = streamError;
    if (error != null) {
      throw error;
    }
    return streamUri;
  }
}

const _jellyfinTrack = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

void main() {
  group('JellyfinPlayableUriResolver', () {
    test('handles only Jellyfin tracks', () {
      final resolver = JellyfinPlayableUriResolver(() => null);

      expect(resolver.handles(_jellyfinTrack), isTrue);
      expect(
        resolver.handles(const Track(id: '1', title: 'L', uri: '/m/x.mp3')),
        isFalse,
      );
    });

    test('mints the stream URL when the session verifies', () async {
      final source = _FakeStreamSource(
        streamUri: Uri.parse('https://music.example.com/Audio/t1/stream'),
      );
      final resolver = JellyfinPlayableUriResolver(() => source);

      final resolved = await resolver.resolve(_jellyfinTrack);

      expect(resolved.uri.path, '/Audio/t1/stream');
      // The URI handed to the engine is a real https URL, never `jellyfin:<id>`.
      expect(resolved.uri.scheme, 'https');
      expect(resolved.uri.toString(), isNot(startsWith('jellyfin:')));
      // A minted Jellyfin URL is reported as a direct stream.
      expect(resolved.source, PlaybackSource.streamingDirect);
      // The session is verified before the URL is handed to the engine.
      expect(source.verifyCount, 1);
    });

    test('reports "not signed in" when no source is connected', () async {
      final resolver = JellyfinPlayableUriResolver(() => null);

      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.notSignedIn,
          ),
        ),
      );
    });

    test('reports an expired session on a 401', () async {
      final source = _FakeStreamSource(
        verifyError: JellyfinException.unauthorized(),
      );
      final resolver = JellyfinPlayableUriResolver(() => source);

      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.sessionExpired,
          ),
        ),
      );
    });

    test('reports an unreachable server on a transport failure', () async {
      final source = _FakeStreamSource(
        verifyError: JellyfinException.notReachable(),
      );
      final resolver = JellyfinPlayableUriResolver(() => source);

      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.serverUnreachable,
          ),
        ),
      );
    });

    test('reports an unavailable stream when no URL can be built', () async {
      final source = _FakeStreamSource(streamUri: null);
      final resolver = JellyfinPlayableUriResolver(() => source);

      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.streamUnavailable,
          ),
        ),
      );
    });

    test('reports a web-page error when the probe sees HTML (Cloudflare)',
        () async {
      final source =
          _FakeStreamSource(streamError: JellyfinException.webPage());
      final resolver = JellyfinPlayableUriResolver(() => source);

      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.serverReturnedWebPage,
          ),
        ),
      );
    });

    test('reports an invalid stream when the probe sees a non-audio response',
        () async {
      final source =
          _FakeStreamSource(streamError: JellyfinException.notAudioStream());
      final resolver = JellyfinPlayableUriResolver(() => source);

      await expectLater(
        resolver.resolve(_jellyfinTrack),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.invalidStream,
          ),
        ),
      );
    });

    test('error messages match the friendly, secret-free wording', () async {
      Future<String> messageFor(JellyfinException verifyError) async {
        final resolver = JellyfinPlayableUriResolver(
          () => _FakeStreamSource(verifyError: verifyError),
        );
        try {
          await resolver.resolve(_jellyfinTrack);
          fail('expected a PlaybackResolutionException');
        } on PlaybackResolutionException catch (e) {
          return e.message;
        }
      }

      expect(
        await messageFor(JellyfinException.unauthorized()),
        'Your Jellyfin session expired. Sign in again.',
      );
      expect(
        await messageFor(JellyfinException.notReachable()),
        "Couldn't reach your Jellyfin server.",
      );
      expect(
        await messageFor(JellyfinException.notAudioStream()),
        'Jellyfin did not return an audio stream.',
      );
      expect(
        await messageFor(JellyfinException.webPage()),
        'Your server returned a web page instead of audio. Check '
        'Cloudflare/Jellyfin access.',
      );

      final notSignedIn = JellyfinPlayableUriResolver(() => null);
      try {
        await notSignedIn.resolve(_jellyfinTrack);
        fail('expected a PlaybackResolutionException');
      } on PlaybackResolutionException catch (e) {
        expect(e.message, 'Sign in to Jellyfin before streaming this track.');
      }
    });

    test('no error message exposes the token', () async {
      final source = _FakeStreamSource(
        verifyError: JellyfinException.unauthorized(),
      );
      final resolver = JellyfinPlayableUriResolver(() => source);

      try {
        await resolver.resolve(_jellyfinTrack);
        fail('expected a PlaybackResolutionException');
      } on PlaybackResolutionException catch (e) {
        expect(e.message, isNot(contains('api_key')));
        expect(e.message, isNot(contains('Token')));
      }
    });
  });
}
