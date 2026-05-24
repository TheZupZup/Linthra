import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';

void main() {
  group('LocalPlayableUriResolver', () {
    const resolver = LocalPlayableUriResolver();

    test('resolves a filesystem path to a local-file source', () async {
      const track = Track(id: '1', title: 'One', uri: '/music/song.mp3');

      final resolved = await resolver.resolve(track);

      expect(resolved.uri, Uri.file('/music/song.mp3'));
      expect(resolved.uri.scheme, 'file');
      expect(resolved.source, PlaybackSource.localFile);
    });

    test('passes a content:// URI through unchanged', () async {
      const raw = 'content://com.android.externalstorage.documents/'
          'tree/primary%3AMusic/document/primary%3AMusic%2FOne.mp3';
      const track = Track(id: raw, title: 'One', uri: raw);

      final resolved = await resolver.resolve(track);

      expect(resolved.uri.scheme, 'content');
      // Compare parsed URIs (not strings) so the assertion doesn't depend on
      // Dart's percent-encoding normalization of the content URI.
      expect(resolved.uri, Uri.parse(raw));
      expect(resolved.source, PlaybackSource.localFile);
    });

    test('handles on-device tracks but not Jellyfin tracks', () {
      const file = Track(id: '1', title: 'One', uri: '/music/song.mp3');
      const content = Track(id: '2', title: 'Two', uri: 'content://x/y');
      const jellyfin = Track(id: 't1', title: 'J', uri: 'jellyfin:t1');

      expect(resolver.handles(file), isTrue);
      expect(resolver.handles(content), isTrue);
      expect(resolver.handles(jellyfin), isFalse);
    });
  });
}
