import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/local_playable_uri_resolver.dart';

void main() {
  group('LocalPlayableUriResolver', () {
    const resolver = LocalPlayableUriResolver();

    test('resolves a filesystem path to a file URI', () async {
      const track = Track(id: '1', title: 'One', uri: '/music/song.mp3');

      final uri = await resolver.resolve(track);

      expect(uri, Uri.file('/music/song.mp3'));
      expect(uri.scheme, 'file');
    });

    test('passes a content:// URI through unchanged', () async {
      const raw = 'content://com.android.externalstorage.documents/'
          'tree/primary%3AMusic/document/primary%3AMusic%2FOne.mp3';
      const track = Track(id: raw, title: 'One', uri: raw);

      final uri = await resolver.resolve(track);

      expect(uri.scheme, 'content');
      expect(uri.toString(), raw);
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
