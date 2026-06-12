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

  test('reports a friendly "not connected" when no source is connected',
      () async {
    // A plex: track never resolves to a stream URL without a connected
    // source: the scheme is recognized, but resolution is gated on a session,
    // and the gate steers to the Settings connect flow (Plex has no sign-in —
    // a token is pasted there).
    final resolver = PlexPlayableUriResolver(() => null);
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>()
          .having(
              (e) => e.kind, 'kind', PlaybackResolutionErrorKind.notSignedIn)
          .having((e) => e.message, 'message', contains('Settings'))),
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

  test('maps a server-side error (5xx) to serverUnreachable', () async {
    final resolver = PlexPlayableUriResolver(
      () => _FakeStreamSource(resolveError: PlexException.serverError(503)),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having((e) => e.kind, 'kind',
          PlaybackResolutionErrorKind.serverUnreachable)),
    );
  });

  test('maps an unusable metadata response to invalidStream', () async {
    // The client reports a 2xx Plex envelope it couldn't use — e.g. a metadata
    // lookup whose MediaContainer carried no item ("missing metadata").
    final resolver = PlexPlayableUriResolver(
      () =>
          _FakeStreamSource(resolveError: PlexException.unsupportedResponse()),
    );
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>().having(
          (e) => e.kind, 'kind', PlaybackResolutionErrorKind.invalidStream)),
    );
  });

  test('a track with no playable part says so precisely', () async {
    // The source resolved the item, but it carried no Part to stream — a
    // data condition on the server, not a connection failure, so the message
    // must say that rather than a generic "couldn't stream".
    final resolver = PlexPlayableUriResolver(() => _FakeStreamSource());
    await expectLater(
      resolver.resolve(_track),
      throwsA(isA<PlaybackResolutionException>()
          .having((e) => e.kind, 'kind',
              PlaybackResolutionErrorKind.streamUnavailable)
          .having((e) => e.message, 'message',
              'This track has no playable file on your Plex server.')),
    );
  });

  test('every failure kind resolves to a token-free, URL-free message',
      () async {
    // A Plex stream URL carries X-Plex-Token in its query, so no error path —
    // whatever the failure kind — may echo a URL, a query fragment, or the
    // token parameter. Sweep every typed kind the client can throw, on both
    // the verify and the resolve step, plus the no-part and not-signed-in
    // paths.
    final List<PlexException> failures = <PlexException>[
      PlexException.notReachable(),
      PlexException.unauthorized(),
      PlexException.notPlex(),
      PlexException.serverError(503),
      PlexException.notFound(),
      PlexException.unsupportedResponse(),
      PlexException.unexpected(418),
      const PlexException.invalidUrl('bad address'),
    ];
    final List<PlexPlayableUriResolver> resolvers = <PlexPlayableUriResolver>[
      for (final PlexException failure
          in failures) ...<PlexPlayableUriResolver>[
        PlexPlayableUriResolver(() => _FakeStreamSource(verifyError: failure)),
        PlexPlayableUriResolver(() => _FakeStreamSource(resolveError: failure)),
      ],
      PlexPlayableUriResolver(() => _FakeStreamSource()), // no playable part
      PlexPlayableUriResolver(() => null), // not signed in
    ];
    for (final PlexPlayableUriResolver resolver in resolvers) {
      try {
        await resolver.resolve(_track);
        fail('expected a PlaybackResolutionException');
      } on PlaybackResolutionException catch (e) {
        expect(e.message, isNot(contains('X-Plex-Token')));
        expect(e.message, isNot(contains('=')));
        expect(e.message, isNot(contains('://')));
      }
    }
  });
}
