import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/remote_cache/remote_cache_key.dart';

Track _track(String uri, {String id = 'id'}) =>
    Track(id: id, title: 't', uri: uri);

void main() {
  group('RemoteCacheKey routing', () {
    test('keys Jellyfin, Subsonic, and Plex tracks by their opaque uri', () {
      final RemoteCacheKey? jellyfin =
          RemoteCacheKey.forTrack(_track('jellyfin:abc'));
      final RemoteCacheKey? subsonic =
          RemoteCacheKey.forTrack(_track('subsonic:def'));
      final RemoteCacheKey? plex = RemoteCacheKey.forTrack(_track('plex:101'));

      expect(jellyfin, isNotNull);
      expect(jellyfin!.sourceId, 'jellyfin');
      expect(jellyfin.value, 'jellyfin:abc');

      expect(subsonic!.sourceId, 'subsonic');
      expect(subsonic.value, 'subsonic:def');

      expect(plex!.sourceId, 'plex');
      expect(plex.value, 'plex:101');
    });

    test('a local file path is not cacheable (no scheme)', () {
      expect(RemoteCacheKey.forTrack(_track('/music/one.mp3')), isNull);
      expect(RemoteCacheKey.isRemote(_track('/music/one.mp3')), isFalse);
    });

    test('a file:// uri is not cacheable', () {
      expect(RemoteCacheKey.forTrack(_track('file:///music/one.mp3')), isNull);
    });

    test('a content:// (SAF) document is not cacheable', () {
      expect(
        RemoteCacheKey.forTrack(
          _track('content://media/external/audio/media/42'),
        ),
        isNull,
      );
      expect(
        RemoteCacheKey.isRemote(
          _track('content://media/external/audio/media/42'),
        ),
        isFalse,
      );
    });

    test('an unknown scheme is not cacheable', () {
      expect(RemoteCacheKey.forTrack(_track('webdav:thing')), isNull);
    });
  });

  group('RemoteCacheKey credential safety', () {
    test('refuses to key anything that looks tokenized', () {
      // Defence in depth: a well-formed remote uri never carries a query/token,
      // but if one ever did it must not become a (persistable) key.
      expect(
        RemoteCacheKey.forUri('jellyfin:abc?api_key=SECRET'),
        isNull,
      );
      // The PascalCase ApiKey (Jellyfin's canonical token query key) is caught
      // too — the denylist is matched case-insensitively.
      expect(
        RemoteCacheKey.forUri('jellyfin:abc?ApiKey=SECRET'),
        isNull,
      );
      expect(
        RemoteCacheKey.forUri('plex:101?X-Plex-Token=SECRET'),
        isNull,
      );
      expect(
        RemoteCacheKey.forUri('subsonic:def?t=hash&s=salt'),
        isNull,
      );
      expect(
        RemoteCacheKey.forUri('jellyfin:abc?access_token=SECRET'),
        isNull,
      );
    });

    test('value, fileSafeName and toString carry no secret', () {
      final RemoteCacheKey key = RemoteCacheKey.forTrack(_track('plex:101'))!;
      for (final String s in <String>[
        key.value,
        key.fileSafeName,
        key.toString(),
      ]) {
        expect(s.toLowerCase(), isNot(contains('token')));
        expect(s.toLowerCase(), isNot(contains('secret')));
        expect(s, isNot(contains('?')));
      }
    });

    test('fileSafeName is filesystem-safe and stable', () {
      final RemoteCacheKey key =
          RemoteCacheKey.forTrack(_track('jellyfin:a/b c:d'))!;
      // No path separators, spaces, or colons survive into a filename.
      expect(key.fileSafeName, isNot(contains('/')));
      expect(key.fileSafeName, isNot(contains(' ')));
      expect(key.fileSafeName, isNot(contains(':')));
      expect(key.fileSafeName,
          RemoteCacheKey.forUri('jellyfin:a/b c:d')!.fileSafeName);
      expect(key.fileSafeName, startsWith('jellyfin_'));
    });
  });

  group('RemoteCacheKey identity', () {
    test('keys are equal iff their credential-free value matches', () {
      // Identity is the uri, not the catalog id — two Track objects for the same
      // remote item map to one cache slot.
      final RemoteCacheKey a =
          RemoteCacheKey.forTrack(_track('plex:101', id: 'x'))!;
      final RemoteCacheKey b =
          RemoteCacheKey.forTrack(_track('plex:101', id: 'y'))!;
      final RemoteCacheKey c = RemoteCacheKey.forTrack(_track('plex:202'))!;

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
