import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_playable_uri_resolver.dart';
import 'package:linthra/core/sources/plex/plex_stream_source.dart';

/// A configurable [PlexStreamSource] for resolver tests.
class _FakeStreamSource implements PlexStreamSource {
  _FakeStreamSource({this.uri, this.verifyError, this.resolveError});

  Uri? uri;
  PlexException? verifyError;
  PlexException? resolveError;

  @override
  Future<void> verifyReachable() async {
    if (verifyError != null) throw verifyError!;
  }

  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    if (resolveError != null) throw resolveError!;
    return uri;
  }
}

const _track = Track(id: '101', title: 'One', uri: 'plex:101');

void main() {
  test('handles only plex: tracks', () {
    final resolver = PlexPlayableUriResolver(() => _FakeStreamSource());
    expect(resolver.handles(_track), isTrue);
    expect(
      resolver.handles(const Track(id: 'j', title: 'x', uri: 'jellyfin:j')),
      isFalse,
    );
    expect(
      resolver.handles(const Track(id: 's', title: 'x', uri: 'subsonic:s')),
      isFalse,
    );
    expect(
      resolver.handles(const Track(id: 'l', title: 'x', uri: '/music/a.mp3')),
      isFalse,
    );
  });

  test('resolves to a streaming-direct playable', () async {
    final source = _FakeStreamSource(
      uri: Uri.parse(
          'https://plex.example.com/library/parts/9/file.flac?X-Plex-Token=tok'),
    );
    final resolver = PlexPlayableUriResolver(() => source);

    final resolved = await resolver.resolve(_track);

    expect(resolved.source, PlaybackSource.streamingDirect);
    expect(resolved.uri.path, '/library/parts/9/file.flac');
  });

  test('reports a friendly "not signed in" when no source is connected',
      () async {
    // The only state reachable in production until the Plex connection UI
    // ships: the scheme is recognized, but resolution is gated on a session.
    final resolver = PlexPlayableUriResolver(() => null);
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having(
          (e) => e.kind, 'kind', PlaybackResolutionErrorKind.notSignedIn)),
    );
  });

  test('maps an unauthorized failure to sessionExpired', () async {
    final resolver = PlexPlayableUriResolver(
      () => _FakeStreamSource(verifyError: PlexException.unauthorized()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having(
          (e) => e.kind, 'kind', PlaybackResolutionErrorKind.sessionExpired)),
    );
  });

  test('maps an HTML/proxy page to serverReturnedWebPage', () async {
    final resolver = PlexPlayableUriResolver(
      () => _FakeStreamSource(resolveError: PlexException.notPlex()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having((e) => e.kind, 'kind',
          PlaybackResolutionErrorKind.serverReturnedWebPage)),
    );
  });

  test('maps a vanished item (404) to streamUnavailable', () async {
    final resolver = PlexPlayableUriResolver(
      () => _FakeStreamSource(resolveError: PlexException.notFound()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having((e) => e.kind, 'kind',
          PlaybackResolutionErrorKind.streamUnavailable)),
    );
  });

  test('maps an offline server to serverUnreachable', () async {
    final resolver = PlexPlayableUriResolver(
      () => _FakeStreamSource(verifyError: PlexException.notReachable()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having((e) => e.kind, 'kind',
          PlaybackResolutionErrorKind.serverUnreachable)),
    );
  });

  test('a track with no playable part is streamUnavailable', () async {
    // The source resolved the item, but it carried no Part to stream.
    final resolver = PlexPlayableUriResolver(() => _FakeStreamSource());
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having((e) => e.kind, 'kind',
          PlaybackResolutionErrorKind.streamUnavailable)),
    );
  });

  test('no resolution error message leaks a token', () async {
    // A Plex stream URL carries X-Plex-Token in its query, so the error path
    // must never echo a URL or token fragment.
    for (final source in <_FakeStreamSource>[
      _FakeStreamSource(verifyError: PlexException.unauthorized()),
      _FakeStreamSource(resolveError: PlexException.notFound()),
      _FakeStreamSource(verifyError: PlexException.notReachable()),
    ]) {
      final resolver = PlexPlayableUriResolver(() => source);
      try {
        await resolver.resolve(_track);
        fail('expected a PlaybackResolutionException');
      } on PlaybackResolutionException catch (e) {
        expect(e.message, isNot(contains('tok')));
        expect(e.message, isNot(contains('X-Plex-Token')));
        expect(e.message, isNot(contains('=')));
      }
    }
  });
}
