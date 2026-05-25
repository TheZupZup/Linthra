import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/sources/subsonic/subsonic_exception.dart';
import 'package:linthra/core/sources/subsonic/subsonic_playable_uri_resolver.dart';
import 'package:linthra/core/sources/subsonic/subsonic_stream_source.dart';

/// A configurable [SubsonicStreamSource] for resolver tests.
class _FakeStreamSource implements SubsonicStreamSource {
  _FakeStreamSource({this.uri, this.verifyError, this.resolveError});

  Uri? uri;
  SubsonicException? verifyError;
  SubsonicException? resolveError;

  @override
  Future<void> verifyReachable() async {
    if (verifyError != null) throw verifyError!;
  }

  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    if (resolveError != null) throw resolveError!;
    return uri;
  }

  @override
  Future<Uri?> resolveDownloadUri(Track track) async => uri;
}

const _track = Track(id: 's1', title: 'One', uri: 'subsonic:s1');

void main() {
  test('handles only subsonic: tracks', () {
    final resolver = SubsonicPlayableUriResolver(() => _FakeStreamSource());
    expect(resolver.handles(_track), isTrue);
    expect(
      resolver.handles(const Track(id: 'j', title: 'x', uri: 'jellyfin:j')),
      isFalse,
    );
    expect(
      resolver.handles(const Track(id: 'l', title: 'x', uri: '/music/a.mp3')),
      isFalse,
    );
  });

  test('resolves to a streaming-direct playable', () async {
    final source = _FakeStreamSource(
      uri: Uri.parse('https://music.example.com/rest/stream.view?id=s1&t=tok'),
    );
    final resolver = SubsonicPlayableUriResolver(() => source);

    final resolved = await resolver.resolve(_track);

    expect(resolved.source, PlaybackSource.streamingDirect);
    expect(resolved.uri.queryParameters['id'], 's1');
  });

  test('reports a friendly "not signed in" when no source is connected',
      () async {
    final resolver = SubsonicPlayableUriResolver(() => null);
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having(
          (e) => e.kind, 'kind', PlaybackResolutionErrorKind.notSignedIn)),
    );
  });

  test('maps an unauthorized failure to sessionExpired', () async {
    final resolver = SubsonicPlayableUriResolver(
      () => _FakeStreamSource(verifyError: SubsonicException.unauthorized()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having(
          (e) => e.kind, 'kind', PlaybackResolutionErrorKind.sessionExpired)),
    );
  });

  test('maps an HTML/proxy page to serverReturnedWebPage', () async {
    final resolver = SubsonicPlayableUriResolver(
      () => _FakeStreamSource(resolveError: SubsonicException.notSubsonic()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having((e) => e.kind, 'kind',
          PlaybackResolutionErrorKind.serverReturnedWebPage)),
    );
  });

  test('no resolution error message leaks a token', () async {
    final resolver = SubsonicPlayableUriResolver(
      () => _FakeStreamSource(verifyError: SubsonicException.unauthorized()),
    );
    try {
      await resolver.resolve(_track);
      fail('expected a PlaybackResolutionException');
    } on PlaybackResolutionException catch (e) {
      expect(e.message, isNot(contains('tok')));
      expect(e.message, isNot(contains('=')));
    }
  });
}
