import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';

/// A resolver that claims a fixed set of URI prefixes and returns a canned
/// result, so routing can be asserted without any real source.
class _StubResolver implements PlayableUriResolver {
  _StubResolver(this.prefix, this.result, this.source);

  final String prefix;
  final Uri result;
  final PlaybackSource source;
  bool resolved = false;

  @override
  bool handles(Track track) => track.uri.startsWith(prefix);

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolved = true;
    return ResolvedPlayable(result, source);
  }
}

void main() {
  group('RoutingPlayableUriResolver', () {
    test('delegates to the first resolver that handles the track', () async {
      final jellyfin = _StubResolver(
        'jellyfin:',
        Uri.parse('https://j/x'),
        PlaybackSource.streamingDirect,
      );
      final local = _StubResolver(
        '/',
        Uri.file('/music/song.mp3'),
        PlaybackSource.localFile,
      );
      final router = RoutingPlayableUriResolver(<PlayableUriResolver>[
        jellyfin,
        local,
      ]);

      final resolved = await router.resolve(
        const Track(id: 't1', title: 'J', uri: 'jellyfin:t1'),
      );

      expect(resolved.uri, Uri.parse('https://j/x'));
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(jellyfin.resolved, isTrue);
      expect(local.resolved, isFalse);
    });

    test('falls through to a later resolver', () async {
      final jellyfin = _StubResolver(
        'jellyfin:',
        Uri.parse('https://j/x'),
        PlaybackSource.streamingDirect,
      );
      final local = _StubResolver(
        '/',
        Uri.file('/music/song.mp3'),
        PlaybackSource.localFile,
      );
      final router = RoutingPlayableUriResolver(<PlayableUriResolver>[
        jellyfin,
        local,
      ]);

      final resolved = await router.resolve(
        const Track(id: '1', title: 'L', uri: '/music/song.mp3'),
      );

      expect(resolved.uri, Uri.file('/music/song.mp3'));
      expect(resolved.source, PlaybackSource.localFile);
      expect(local.resolved, isTrue);
      expect(jellyfin.resolved, isFalse);
    });

    test('throws when no resolver handles the track', () async {
      final router = RoutingPlayableUriResolver(<PlayableUriResolver>[
        _StubResolver(
          'jellyfin:',
          Uri.parse('https://j/x'),
          PlaybackSource.streamingDirect,
        ),
      ]);

      await expectLater(
        router.resolve(const Track(id: '1', title: 'L', uri: '/music/x.mp3')),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.streamUnavailable,
          ),
        ),
      );
    });
  });
}
