import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/repositories/download_store.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';
import 'package:linthra/core/services/routing_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_playable_uri_resolver.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_stream_source.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_track_mapper.dart';
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

      final resolved = await resolver.resolve(_jellyfinTrack);

      // It streamed (no download required) straight from Jellyfin.
      expect(resolved.uri.scheme, 'https');
      expect(resolved.uri.path, '/Audio/t1/universal');
      expect(resolved.source, PlaybackSource.streamingDirect);
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

      final resolved = await resolver.resolve(_jellyfinTrack);

      // Cache hit: a local file, and the network source was never touched.
      expect(resolved.uri.scheme, 'file');
      expect(resolved.uri.toFilePath(), '/offline_audio/t1.mp3');
      expect(resolved.source, PlaybackSource.offlineCache);
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

      final resolved = await resolver.resolve(_localTrack);

      expect(resolved.uri.scheme, 'file');
      expect(resolved.uri.toFilePath(), '/music/one.mp3');
      expect(resolved.source, PlaybackSource.localFile);
      // A local track never consults the Jellyfin source.
      expect(source.verifyCount, 0);
      expect(source.resolveCount, 0);
    });
  });

  group('Jellyfin token safety', () {
    const baseUrl = 'https://music.example.com';
    const token = 'super-secret-token';

    test('no token leaks into the track uri, artwork, source label, or cache '
        'filename', () async {
      // The mapped track is the persisted identity the UI and database see.
      final track = JellyfinTrackMapper.toTrack(
        const JellyfinItemDto(id: 't1', name: 'One', hasPrimaryImage: true),
        baseUrl: baseUrl,
      );
      expect(track.uri, 'jellyfin:t1');
      expect(track.uri, isNot(contains(token)));
      expect(track.artworkUri.toString(), isNot(contains(token)));
      expect(track.artworkUri.toString(), isNot(contains('api_key')));

      // The tokenized stream URL is minted only at play time; the source the UI
      // renders is a plain enum label with no secret in it.
      final source = _FakeStreamSource(
        Uri.parse('$baseUrl/Audio/t1/universal?api_key=$token'),
      );
      final resolver = _resolver(
        locator: StoreCachedTrackLocator(
          InMemoryDownloadStore(),
          InMemoryOfflineFileStore(),
        ),
        source: source,
      );
      final resolved = await resolver.resolve(track);
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(resolved.source.label, isNot(contains(token)));

      // A downloaded copy is named from the track id, never the tokenized URL.
      final files = InMemoryOfflineFileStore();
      final fileName =
          await files.write(track.id, <int>[1, 2, 3], extension: 'mp3');
      expect(fileName, isNot(contains(token)));
      expect(fileName, isNot(contains('api_key')));
    });
  });
}
