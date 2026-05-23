import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';

/// A resolver that claims a fixed set of URI prefixes and returns a canned URI,
/// so routing can be asserted without any real source.
class _StubResolver implements PlayableUriResolver {
  _StubResolver(this.prefix, this.result);

  final String prefix;
  final Uri result;
  bool resolved = false;

  @override
  bool handles(Track track) => track.uri.startsWith(prefix);

  @override
  Future<Uri> resolve(Track track) async {
    resolved = true;
    return result;
  }
}

void main() {
  group('RoutingPlayableUriResolver', () {
    test('delegates to the first resolver that handles the track', () async {
      final jellyfin = _StubResolver('jellyfin:', Uri.parse('https://j/x'));
      final local = _StubResolver('/', Uri.file('/music/song.mp3'));
      final router = RoutingPlayableUriResolver(<PlayableUriResolver>[
        jellyfin,
        local,
      ]);

      final uri = await router.resolve(
        const Track(id: 't1', title: 'J', uri: 'jellyfin:t1'),
      );

      expect(uri, Uri.parse('https://j/x'));
      expect(jellyfin.resolved, isTrue);
      expect(local.resolved, isFalse);
    });

    test('falls through to a later resolver', () async {
      final jellyfin = _StubResolver('jellyfin:', Uri.parse('https://j/x'));
      final local = _StubResolver('/', Uri.file('/music/song.mp3'));
      final router = RoutingPlayableUriResolver(<PlayableUriResolver>[
        jellyfin,
        local,
      ]);

      final uri = await router.resolve(
        const Track(id: '1', title: 'L', uri: '/music/song.mp3'),
      );

      expect(uri, Uri.file('/music/song.mp3'));
      expect(local.resolved, isTrue);
      expect(jellyfin.resolved, isFalse);
    });

    test('throws when no resolver handles the track', () async {
      final router = RoutingPlayableUriResolver(<PlayableUriResolver>[
        _StubResolver('jellyfin:', Uri.parse('https://j/x')),
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
