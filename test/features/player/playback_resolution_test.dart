import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_stream_source.dart';
import 'package:linthra/data/repositories/in_memory_download_store.dart';
import 'package:linthra/data/repositories/in_memory_offline_file_store.dart';
import 'package:linthra/data/repositories/store_cached_track_locator.dart';

/// A signed-in Jellyfin stream source that mints a canned URL at play time and
/// records whether it was consulted, so a test can prove a cached track never
/// hits the network.
class _FakeStreamSource implements JellyfinStreamSource {
  _FakeStreamSource(this._uri);

  final Uri _uri;
  int verifyCount = 0;
  int resolveCount = 0;

  @override
  Future<void> verifyReachable() async => verifyCount++;

  @override
  Future<Uri?> resolvePlayableUri(Track track) async {
    resolveCount++;
    return _uri;
  }
}

const _jellyfinTrack = Track(id: 't1', title: 'Remote One', uri: 'jellyfin:t1');
const _localTrack = Track(id: 'l1', title: 'Local One', uri: '/music/one.mp3');

/// Builds the exact resolver `playableUriResolverProvider` composes: offline
/// first, then source routing (Jellyfin, then on-device).
OfflineFirstPlayableUriResolver _resolver({
  required StoreCachedTrackLocator locator,
  required JellyfinStreamSource source,
}) {
  return OfflineFirstPlayableUriResolver(
    locator: locator,
    fallback: RoutingPlayableUriResolver(<PlayableUriResolver>[
      JellyfinPlayableUriResolver(() => source),
      const LocalPlayableUriResolver(),
    ]),
  );
}

void main() {
  group('composed playback resolution', () {
    test('streams a Jellyfin track directly when it is not cached', () async {
      final source = _FakeStreamSource(
        Uri.parse('https://music.example.com/Audio/t1/universal'),
      );
      final resolver = _resolver(
        // Nothing cached: an empty download store.
        locator: StoreCachedTrackLocator(
          InMemoryDownloadStore(),
          InMemoryOfflineFileStore(),
        ),
        source: source,
      );

      final uri = await resolver.resolve(_jellyfinTrack);

      // It streamed (no download required) straight from Jellyfin.
      expect(uri.scheme, 'https');
      expect(uri.path, '/Audio/t1/universal');
      expect(source.verifyCount, 1);
      expect(source.resolveCount, 1);
    });

    test('prefers the cached file for a downloaded Jellyfin track', () async {
      final files = InMemoryOfflineFileStore();
      final fileName =
          await files.write('t1', <int>[1, 2, 3], extension: 'mp3');
      final source = _FakeStreamSource(Uri.parse('https://stream/t1'));
      final resolver = _resolver(
        locator: StoreCachedTrackLocator(
          InMemoryDownloadStore(
            initialDownloads: <CachedTrack>[
              CachedTrack(trackId: 't1', fileName: fileName),
            ],
          ),
          files,
        ),
        source: source,
      );

      final uri = await resolver.resolve(_jellyfinTrack);

      // Cache hit: a local file, and the network source was never touched.
      expect(uri.scheme, 'file');
      expect(uri.toFilePath(), '/offline_audio/t1.mp3');
      expect(source.verifyCount, 0);
      expect(source.resolveCount, 0);
    });

    test('plays a local track from its on-device path', () async {
      final source = _FakeStreamSource(Uri.parse('https://stream/x'));
      final resolver = _resolver(
        locator: StoreCachedTrackLocator(
          InMemoryDownloadStore(),
          InMemoryOfflineFileStore(),
        ),
        source: source,
      );

      final uri = await resolver.resolve(_localTrack);

      expect(uri.scheme, 'file');
      expect(uri.toFilePath(), '/music/one.mp3');
      // A local track never consults the Jellyfin source.
      expect(source.verifyCount, 0);
      expect(source.resolveCount, 0);
    });
  });
}
