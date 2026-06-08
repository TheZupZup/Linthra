import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_capability.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';

Track _track(
  String id,
  String uri, {
  Duration duration = const Duration(minutes: 3),
}) =>
    Track(id: id, title: 'Hello', uri: uri, duration: duration);

void main() {
  group('PlaybackSourceCapability.fromTrack — provider type', () {
    test('a Jellyfin candidate gets provider type Jellyfin', () {
      final cap = PlaybackSourceCapability.fromTrack(_track('j', 'jellyfin:j'));
      expect(cap.providerType, SourceProviderType.jellyfin);
      expect(cap.sourceId, 'jellyfin');
      expect(cap.isRemoteStream, isTrue);
      expect(cap.isLocalFile, isFalse);
    });

    test('a Navidrome/Subsonic candidate gets provider type subsonic', () {
      final cap = PlaybackSourceCapability.fromTrack(_track('s', 'subsonic:s'));
      expect(cap.providerType, SourceProviderType.subsonic);
      expect(cap.providerType.displayName, 'Navidrome / Subsonic');
      expect(cap.isRemoteStream, isTrue);
    });

    test('a local-file candidate is marked local', () {
      final cap =
          PlaybackSourceCapability.fromTrack(_track('l', '/music/one.mp3'));
      expect(cap.providerType, SourceProviderType.local);
      expect(cap.isLocalFile, isTrue);
      expect(cap.delivery, SourceDelivery.localFile);
      expect(cap.isRemoteStream, isFalse);
      expect(cap.isCachedOffline, isFalse);
    });

    test('a content:// (SAF) candidate is local', () {
      final cap = PlaybackSourceCapability.fromTrack(
        _track('c', 'content://media/external/audio/media/42'),
      );
      expect(cap.providerType, SourceProviderType.local);
      expect(cap.isLocalFile, isTrue);
    });
  });

  group('PlaybackSourceCapability — delivery & cache detection', () {
    test('a resolved offline-cache copy is marked cache/offline', () {
      // The existing resolver reports PlaybackSource.offlineCache (a safe, no-
      // network signal); the profile reflects it while keeping the owning
      // provider.
      final cap = PlaybackSourceCapability.fromResolvedSource(
        _track('j', 'jellyfin:j'),
        PlaybackSource.offlineCache,
      );
      expect(cap.isCachedOffline, isTrue);
      expect(cap.delivery, SourceDelivery.cache);
      // Still owned by Jellyfin, even though it plays from cache.
      expect(cap.providerType, SourceProviderType.jellyfin);
    });

    test('a resolved direct stream is a remote stream', () {
      final cap = PlaybackSourceCapability.fromResolvedSource(
        _track('s', 'subsonic:s'),
        PlaybackSource.streamingDirect,
      );
      expect(cap.isRemoteStream, isTrue);
      expect(cap.delivery, SourceDelivery.remoteStream);
    });

    test('a resolved local file is a local delivery', () {
      final cap = PlaybackSourceCapability.fromResolvedSource(
        _track('l', '/music/one.mp3'),
        PlaybackSource.localFile,
      );
      expect(cap.isLocalFile, isTrue);
      expect(cap.delivery, SourceDelivery.localFile);
    });
  });

  group('PlaybackSourceCapability — unknown is never faked', () {
    test('bitrate, codec, and file size are unknown (null), not invented', () {
      final cap = PlaybackSourceCapability.fromTrack(_track('j', 'jellyfin:j'));
      expect(cap.codec, isNull);
      expect(cap.bitrateKbps, isNull);
      expect(cap.fileSizeBytes, isNull);
      expect(cap.qualityKnown, isFalse);
      expect(cap.dataCostKnown, isFalse);
    });

    test('transcoding and LAN-vs-remote are unknown, not guessed', () {
      final cap = PlaybackSourceCapability.fromTrack(_track('j', 'jellyfin:j'));
      expect(cap.transcoded, isNull);
      expect(cap.transcodingKnown, isFalse);
      expect(cap.isLikelyLan, isNull);
    });

    test('duration is captured when present and null when unknown (zero)', () {
      final known = PlaybackSourceCapability.fromTrack(
        _track('j', 'jellyfin:j', duration: const Duration(minutes: 4)),
      );
      expect(known.duration, const Duration(minutes: 4));

      final unknown = PlaybackSourceCapability.fromTrack(
        _track('u', 'jellyfin:u', duration: Duration.zero),
      );
      expect(unknown.duration, isNull);
    });

    test('a known signal flips the *known* getters', () {
      const cap = PlaybackSourceCapability(
        sourceId: 'jellyfin',
        providerType: SourceProviderType.jellyfin,
        delivery: SourceDelivery.remoteStream,
        codec: 'flac',
        bitrateKbps: 1024,
        fileSizeBytes: 30000000,
        transcoded: false,
      );
      expect(cap.qualityKnown, isTrue);
      expect(cap.dataCostKnown, isTrue);
      expect(cap.transcodingKnown, isTrue);
    });
  });

  group('PlaybackSourceCapability — no private data leaks', () {
    test('toString never exposes a local path', () {
      final cap = PlaybackSourceCapability.fromTrack(
        _track('l', '/Users/alice/Music/Secret Album/01 song.mp3'),
      );
      final String text = cap.toString();
      expect(text, isNot(contains('alice')));
      expect(text, isNot(contains('Secret')));
      expect(text, isNot(contains('.mp3')));
      expect(text, isNot(contains('/')));
    });

    test('toString never exposes the opaque remote uri/item id', () {
      final cap = PlaybackSourceCapability.fromTrack(
          _track('item-42', 'jellyfin:item-42'));
      final String text = cap.toString();
      expect(text, isNot(contains('item-42')));
      expect(text, isNot(contains('jellyfin:')));
      // The safe provider id is fine to show.
      expect(text, contains('jellyfin'));
    });
  });

  group('PlaybackSourceCapability — value semantics', () {
    test('equal field sets are equal', () {
      final a = PlaybackSourceCapability.fromTrack(_track('j', 'jellyfin:j'));
      final b = PlaybackSourceCapability.fromTrack(_track('j', 'jellyfin:j'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a different delivery is not equal', () {
      final stream =
          PlaybackSourceCapability.fromTrack(_track('j', 'jellyfin:j'));
      final cached = PlaybackSourceCapability.fromResolvedSource(
        _track('j', 'jellyfin:j'),
        PlaybackSource.offlineCache,
      );
      expect(stream, isNot(cached));
    });
  });
}
