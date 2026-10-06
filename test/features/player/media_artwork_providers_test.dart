import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/plex_session.dart';
import 'package:linthra/core/models/subsonic_session.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/media_artwork_cache.dart';
import 'package:linthra/core/sources/plex/plex_track_mapper.dart';
import 'package:linthra/core/sources/subsonic/subsonic_artwork.dart';
import 'package:linthra/features/player/media_artwork_providers.dart';
import 'package:linthra/features/player/player_providers.dart';

import 'fake_playback_controller.dart';

const _subsonic = SubsonicSession(
  baseUrl: 'https://music.example.com',
  username: 'alice',
  salt: 'the-salt',
  token: 'subsonic-secret-token',
);

const _plex = PlexSession(
  baseUrl: 'https://plex.example.com:32400',
  token: 'plex-secret-token',
  machineIdentifier: 'machine-1',
);

/// A credential-free Plex cover reference built exactly as `PlexTrackMapper`
/// builds `Track.artworkUri` (literal `%` pre-escaped), so the test exercises
/// the same value the catalog persists for a Plex track.
Uri _plexThumb(String thumbPath) => Uri(
      scheme: PlexTrackMapper.artworkScheme,
      path: thumbPath.replaceAll('%', '%25'),
    );

/// The real cache, with every resolve it is asked for kept, so a test can wait
/// for the prewarm's fetches to land instead of guessing how long they take.
class _ObservedCache extends MediaArtworkCache {
  _ObservedCache({
    required super.resolveUrl,
    super.serverOf,
    super.fetch,
    super.directory,
  });

  final List<Future<Uri?>> resolves = <Future<Uri?>>[];

  @override
  Future<Uri?> resolve(Uri reference) {
    final Future<Uri?> resolved = super.resolve(reference);
    resolves.add(resolved);
    return resolved;
  }
}

void main() {
  group('resolveMediaSessionArtworkUrl', () {
    // The regression this fixes: a Plex track's plex-thumb: cover reaching the
    // media session (lock screen / Android Auto). Before the fix the resolver
    // only knew Subsonic, so a Plex reference resolved to null, was never
    // fetched/cached, and the now-playing card showed no art.
    test('resolves a Plex reference at the media-session size', () {
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        _plexThumb('/library/metadata/123/thumb/1670000000'),
        plex: _plex,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'plex.example.com');
      expect(resolved.port, 32400);
      // Like Subsonic, the media-session path asks PMS for a small, fast-to-
      // decode cover (via the photo transcoder) rather than the full-resolution
      // thumb — so the now-playing card stays crisp without a huge bitmap
      // crossing the process boundary, and the shared cache holds a modest file.
      expect(resolved.path, '/photo/:/transcode');
      expect(resolved.queryParameters['url'],
          '/library/metadata/123/thumb/1670000000');
      expect(resolved.queryParameters['width'], '$kMediaSessionArtworkSize');
      // The token rides in the query (the image layer can't set headers) — and
      // it is the live session's token, woven in on demand.
      expect(resolved.queryParameters['X-Plex-Token'], 'plex-secret-token');
    });

    test(
        'a Plex reference resolves even when a Subsonic session is also present',
        () {
      // Proves the providers chain: Subsonic returns null for a plex-thumb:
      // reference (it isn't a subsonic-cover:), so resolution falls through to
      // Plex rather than stopping at the first provider. This is exactly the
      // path that was missing before the fix.
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        _plexThumb('/library/metadata/123/thumb/1'),
        subsonic: _subsonic,
        plex: _plex,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'plex.example.com');
      expect(resolved.queryParameters['X-Plex-Token'], 'plex-secret-token');
    });

    test('a Plex reference does not resolve when signed out of Plex', () {
      expect(
        resolveMediaSessionArtworkUrl(
          _plexThumb('/library/metadata/123/thumb/1'),
        ),
        isNull,
      );
    });

    test('resolves a Subsonic reference at the media-session size', () {
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        SubsonicArtwork.reference('al-123'),
        subsonic: _subsonic,
      );

      expect(resolved, isNotNull);
      expect(resolved!.path, contains('getCoverArt'));
      expect(resolved.queryParameters['id'], 'al-123');
      // The media-session path asks the server for a small, fast-to-decode
      // cover (unlike the in-app full-size render), so the card stays crisp
      // without crossing the process boundary as a huge bitmap.
      expect(resolved.queryParameters['size'], '$kMediaSessionArtworkSize');
      expect(resolved.queryParameters['t'], 'subsonic-secret-token');
    });

    test('a Subsonic reference resolves to Subsonic even with a Plex session',
        () {
      // Subsonic owns its scheme and is tried first, so the Plex session is not
      // consulted for a subsonic-cover: reference.
      final Uri? resolved = resolveMediaSessionArtworkUrl(
        SubsonicArtwork.reference('al-123'),
        subsonic: _subsonic,
        plex: _plex,
      );

      expect(resolved, isNotNull);
      expect(resolved!.host, 'music.example.com');
      expect(resolved.toString(), isNot(contains('plex-secret-token')));
    });

    test('an already-loadable Jellyfin/local cover is left for direct loading',
        () {
      // A token-free http(s) image and a local file: cover are platform-
      // loadable and never reach this cache, so neither provider claims them.
      for (final Uri loadable in <Uri>[
        Uri.parse('https://server.example/Items/1/Images/Primary'),
        Uri.parse('file:///cache/art/abc.img'),
      ]) {
        expect(
          resolveMediaSessionArtworkUrl(
            loadable,
            subsonic: _subsonic,
            plex: _plex,
          ),
          isNull,
          reason: '$loadable must not be rewritten by a reference resolver',
        );
      }
    });

    test('no signed-in providers means no media-session artwork', () {
      expect(
        resolveMediaSessionArtworkUrl(
            _plexThumb('/library/metadata/1/thumb/1')),
        isNull,
      );
      expect(
        resolveMediaSessionArtworkUrl(SubsonicArtwork.reference('al-1')),
        isNull,
      );
    });
  });

  group('mediaArtworkPrewarmServiceProvider', () {
    // A Subsonic cover id names a cover on whichever server is signed in, and
    // servers that number their albums hand out the same ids. The cache keeps
    // each server's cover apart (#739); the prewarm, the only thing that ever
    // fills it, has to fetch the new server's cover too. Otherwise the lock
    // screen, MPRIS and the desktop notification show no cover for that album
    // until the app is restarted.
    test("warms another server's cover of the same name after a switch",
        () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('linthra_prewarm_switch');
      addTearDown(() => dir.delete(recursive: true));
      String? server = 'server-a';
      final List<String> fetchedFrom = <String>[];
      final _ObservedCache cache = _ObservedCache(
        resolveUrl: (Uri reference) =>
            Uri.parse('https://$server.example/cover/${reference.path}'),
        serverOf: (Uri reference) => server,
        fetch: (Uri url) async {
          fetchedFrom.add(url.host);
          return const <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
        },
        directory: () async => dir,
      );
      addTearDown(cache.dispose);
      final FakePlaybackController controller = FakePlaybackController();
      addTearDown(controller.dispose);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          mediaArtworkCacheProvider.overrideWithValue(cache),
          playbackControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);
      container.read(mediaArtworkPrewarmServiceProvider);
      final Uri cover = SubsonicArtwork.reference('al-12');

      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: Track(
          id: 'a',
          title: 'Server A song',
          uri: 'subsonic:a',
          artworkUri: cover,
        ),
      ));
      await pumpEventQueue();
      await Future.wait(cache.resolves);
      expect(cache.cachedFileUri(cover), isNotNull);

      // Signed in to another server, and its album numbered the same plays.
      server = 'server-b';
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: Track(
          id: 'b',
          title: 'Server B song',
          uri: 'subsonic:b',
          artworkUri: cover,
        ),
      ));
      await pumpEventQueue();
      await Future.wait(cache.resolves);

      expect(cache.cachedFileUri(cover), isNotNull,
          reason: "server B's album needs its own cover on the media session");
      expect(fetchedFrom, <String>['server-a.example', 'server-b.example']);
    });
  });
}
