import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/cached_track_locator.dart';
import 'package:linthra/core/services/offline_first_playable_uri_resolver.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// A locator that returns a canned cached path (or null for a miss).
class _FakeLocator implements CachedTrackLocator {
  _FakeLocator(this._path);

  final String? _path;
  int calls = 0;

  @override
  Future<String?> cachedFilePath(Track track) async {
    calls++;
    return _path;
  }
}

/// A fallback that records the track it was asked to resolve and returns a
/// canned (streaming) result.
class _RecordingResolver implements PlayableUriResolver {
  _RecordingResolver(this._uri);

  final Uri _uri;
  Track? resolved;

  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    resolved = track;
    return ResolvedPlayable(_uri, PlaybackSource.streamingDirect);
  }
}

/// A fallback that fails the way the Jellyfin resolver does when offline.
class _OfflineResolver implements PlayableUriResolver {
  @override
  bool handles(Track track) => true;

  @override
  Future<ResolvedPlayable> resolve(Track track) async {
    throw const PlaybackResolutionException(
      "Couldn't reach your Jellyfin server.",
      kind: PlaybackResolutionErrorKind.serverUnreachable,
    );
  }
}

const _track = Track(id: 't1', title: 'One', uri: 'jellyfin:t1');

void main() {
  group('OfflineFirstPlayableUriResolver', () {
    test('prefers the cached file and does not hit the fallback', () async {
      final locator = _FakeLocator('/offline_audio/t1.mp3');
      final fallback = _RecordingResolver(Uri.parse('https://stream/t1'));
      final resolver = OfflineFirstPlayableUriResolver(
        locator: locator,
        fallback: fallback,
      );

      final resolved = await resolver.resolve(_track);

      expect(resolved.uri.scheme, 'file');
      expect(resolved.uri.toFilePath(), '/offline_audio/t1.mp3');
      // A cache hit is reported as the offline-cache source.
      expect(resolved.source, PlaybackSource.offlineCache);
      expect(fallback.resolved, isNull);
    });

    test('notifies onCacheHit with the track id on a cache hit', () async {
      final hits = <String>[];
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator('/offline_audio/t1.mp3'),
        fallback: _RecordingResolver(Uri.parse('https://stream/t1')),
        onCacheHit: hits.add,
      );

      await resolver.resolve(_track);

      expect(hits, <String>['t1']);
    });

    test('does not notify onCacheHit on a cache miss', () async {
      final hits = <String>[];
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator(null),
        fallback: _RecordingResolver(Uri.parse('https://stream/t1')),
        onCacheHit: hits.add,
      );

      await resolver.resolve(_track);

      expect(hits, isEmpty);
    });

    test('streams via the fallback on a cache miss', () async {
      final fallback = _RecordingResolver(
        Uri.parse('https://music.example.com/Audio/t1/universal'),
      );
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator(null),
        fallback: fallback,
      );

      final resolved = await resolver.resolve(_track);

      expect(resolved.uri.host, 'music.example.com');
      // The fallback's source (a direct stream) is passed straight through.
      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(fallback.resolved, _track);
    });

    test('an uncached track offline surfaces the fallback offline error',
        () async {
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator(null),
        fallback: _OfflineResolver(),
      );

      await expectLater(
        resolver.resolve(_track),
        throwsA(
          isA<PlaybackResolutionException>().having(
            (PlaybackResolutionException e) => e.kind,
            'kind',
            PlaybackResolutionErrorKind.serverUnreachable,
          ),
        ),
      );
    });

    test('prefers a cached Plex file, reporting the offline-cache source',
        () async {
      // Provider-agnostic: a plex: track resolves to its cached file exactly
      // like a Jellyfin one — cached playback source selection.
      const plex = Track(id: '101', title: 'Nightcall', uri: 'plex:101');
      final fallback = _RecordingResolver(Uri.parse('https://plex/stream/101'));
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator('/offline_audio/101.flac'),
        fallback: fallback,
      );

      final resolved = await resolver.resolve(plex);

      expect(resolved.uri.toFilePath(), '/offline_audio/101.flac');
      expect(resolved.source, PlaybackSource.offlineCache);
      expect(fallback.resolved, isNull);
    });

    test('streams a Plex track when its cache file is gone (locator null)',
        () async {
      // The locator returns null once the bytes are gone, so playback falls
      // back to the Plex stream rather than opening a missing file.
      const plex = Track(id: '101', title: 'Nightcall', uri: 'plex:101');
      final fallback = _RecordingResolver(Uri.parse('https://plex/stream/101'));
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator(null),
        fallback: fallback,
      );

      final resolved = await resolver.resolve(plex);

      expect(resolved.source, PlaybackSource.streamingDirect);
      expect(fallback.resolved, plex);
    });

    test('handles delegates to the fallback', () {
      final resolver = OfflineFirstPlayableUriResolver(
        locator: _FakeLocator(null),
        fallback: _RecordingResolver(Uri.parse('https://stream/t1')),
      );

      expect(resolver.handles(_track), isTrue);
    });
  });
}
