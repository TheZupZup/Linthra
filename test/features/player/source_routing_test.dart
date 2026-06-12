import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_music_source.dart';
import 'package:linthra/core/sources/plex/plex_playable_uri_resolver.dart';
import 'package:linthra/core/sources/plex/plex_stream_source.dart';
import 'package:linthra/core/sources/subsonic/subsonic_playable_uri_resolver.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/settings/plex/plex_settings_controller.dart';

import '../../core/sources/plex/fake_plex_client.dart';

/// A signed-in Plex stream source minting a canned URL, for routing tests that
/// don't need the full client round trip.
class _FakePlexStreamSource implements PlexStreamSource {
  _FakePlexStreamSource(this._uri);

  final Uri _uri;
  int resolveCount = 0;

  @override
  Future<void> verifyReachable() async {}

  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    resolveCount++;
    return _uri;
  }
}

const _jellyfinTrack = Track(id: 'j1', title: 'J', uri: 'jellyfin:j1');
const _subsonicTrack = Track(id: 's1', title: 'S', uri: 'subsonic:s1');
const _plexTrack = Track(id: '101', title: 'P', uri: 'plex:101');
const _localTrack = Track(id: 'l1', title: 'L', uri: '/music/one.mp3');
const _safTrack = Track(
  id: 'c1',
  title: 'C',
  uri: 'content://media/external/audio/media/42',
);

/// The exact source-router composition `streamPreloadingResolverProvider`
/// builds: Jellyfin, Subsonic, Plex, then the on-device catch-all.
RoutingPlayableUriResolver _router({
  PlexStreamSource? Function()? plex,
}) {
  return RoutingPlayableUriResolver(<PlayableUriResolver>[
    JellyfinPlayableUriResolver(() => null),
    SubsonicPlayableUriResolver(() => null),
    PlexPlayableUriResolver(plex ?? () => null),
    const LocalPlayableUriResolver(),
  ]);
}

Matcher _failsAs(PlaybackResolutionErrorKind kind) => throwsA(
    isA<PlaybackResolutionException>().having((e) => e.kind, 'kind', kind));

void main() {
  group('source routing with Plex registered — no regression', () {
    test('a local path still plays from its on-device file', () async {
      final resolved = await _router().resolve(_localTrack);
      expect(resolved.uri.scheme, 'file');
      expect(resolved.uri.toFilePath(), '/music/one.mp3');
      expect(resolved.source, PlaybackSource.localFile);
    });

    test('a content:// (SAF) document still plays as a local track', () async {
      final resolved = await _router().resolve(_safTrack);
      expect(resolved.uri, Uri.parse(_safTrack.uri));
      expect(resolved.source, PlaybackSource.localFile);
    });

    test(
        'jellyfin: and subsonic: still reach their own resolvers '
        '(a precise "not signed in", never an unrecognized-track fallthrough)',
        () async {
      // streamUnavailable is what the router throws for a URI *no* resolver
      // claims, so notSignedIn proves each scheme is still owned by its own
      // provider's resolver after Plex was added to the list.
      await expectLater(
        _router().resolve(_jellyfinTrack),
        _failsAs(PlaybackResolutionErrorKind.notSignedIn),
      );
      await expectLater(
        _router().resolve(_subsonicTrack),
        _failsAs(PlaybackResolutionErrorKind.notSignedIn),
      );
    });

    test('a connected Plex source never captures other providers\' tracks',
        () async {
      final plex = _FakePlexStreamSource(
        Uri.parse(
            'https://plex.example.com/library/parts/9/f.flac?X-Plex-Token=t'),
      );
      final router = _router(plex: () => plex);

      await expectLater(
        router.resolve(_jellyfinTrack),
        _failsAs(PlaybackResolutionErrorKind.notSignedIn),
      );
      await expectLater(
        router.resolve(_subsonicTrack),
        _failsAs(PlaybackResolutionErrorKind.notSignedIn),
      );
      final local = await router.resolve(_localTrack);
      expect(local.source, PlaybackSource.localFile);
      expect(plex.resolveCount, 0);
    });
  });

  group('plex: routes only when a Plex session/source is available', () {
    test('signed out (the only production state today): a friendly gate',
        () async {
      // Recognized — the Plex resolver claims the scheme — but unavailable,
      // because no source is connected. Without registration this would be the
      // router's streamUnavailable instead.
      await expectLater(
        _router().resolve(_plexTrack),
        _failsAs(PlaybackResolutionErrorKind.notSignedIn),
      );
    });

    test('with a connected source the same track streams directly', () async {
      final plex = _FakePlexStreamSource(
        Uri.parse(
            'https://plex.example.com/library/parts/9/f.flac?X-Plex-Token=t'),
      );
      final resolved = await _router(plex: () => plex).resolve(_plexTrack);
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(resolved.uri.path, '/library/parts/9/f.flac');
      expect(plex.resolveCount, 1);
    });
  });

  group('the real Riverpod wiring (streamPreloadingResolverProvider)', () {
    test('by default the Plex source is null, so a plex: track is gated',
        () async {
      // No overrides: exactly what a production install runs before anyone
      // connects. The jellyfin/subsonic/plex session stores default to
      // in-memory (empty), so plexMusicSourceProvider serves null.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final resolver = container.read(streamPreloadingResolverProvider);

      await expectLater(
        resolver.resolve(_plexTrack),
        _failsAs(PlaybackResolutionErrorKind.notSignedIn),
      );
      // And the existing local path is untouched by the wiring.
      final local = await resolver.resolve(_localTrack);
      expect(local.source, PlaybackSource.localFile);
    });

    test(
        'overriding plexMusicSourceProvider (a connected install) '
        'streams a plex: track end to end, minting the tokenized URL on demand',
        () async {
      const session = PlexSession(
        baseUrl: 'https://plex.example.com:32400',
        token: 'secret-token',
        machineIdentifier: 'machine-1',
        selectedSectionKeys: <String>['5'],
      );
      final client = FakePlexClient(
        metadataByRatingKey: <String, PlexMetadata>{
          '101': const PlexMetadata(
            ratingKey: '101',
            type: 'track',
            title: 'One',
            media: <PlexMedia>[
              PlexMedia(parts: <PlexPart>[
                PlexPart(key: '/library/parts/9/1670000000/file.flac'),
              ]),
            ],
          ),
        },
      );
      final container = ProviderContainer(overrides: [
        plexMusicSourceProvider.overrideWithValue(
          PlexMusicSource(session: session, client: client),
        ),
      ]);
      addTearDown(container.dispose);
      final resolver = container.read(streamPreloadingResolverProvider);

      final resolved = await resolver.resolve(_plexTrack);

      // The two-step resolution ran (metadata lookup → Part key → stream URL)
      // and the token was woven in only now, in the query — never in the
      // track's opaque uri.
      expect(client.requestedRatingKeys, <String>['101']);
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(resolved.uri.path, '/library/parts/9/1670000000/file.flac');
      expect(resolved.uri.queryParameters['X-Plex-Token'], 'secret-token');
      expect(_plexTrack.uri, 'plex:101');
      expect(_plexTrack.uri, isNot(contains('secret-token')));
    });
  });
}
