import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon/core/sources/local/saf_tree_uri_resolver.dart';

void main() {
  const resolver = SafTreeUriResolver();

  group('SafTreeUriResolver', () {
    test('resolves a primary-volume tree URI to a path', () {
      final path = resolver.resolveToPath(
        'content://com.android.externalstorage.documents/tree/primary%3AMusic',
      );
      expect(path, '/storage/emulated/0/Music');
    });

    test('resolves a nested primary-volume folder', () {
      final path = resolver.resolveToPath(
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic%2FAlbums',
      );
      expect(path, '/storage/emulated/0/Music/Albums');
    });

    test('resolves the primary volume root', () {
      final path = resolver.resolveToPath(
        'content://com.android.externalstorage.documents/tree/primary%3A',
      );
      expect(path, '/storage/emulated/0');
    });

    test('resolves a named (SD card) volume', () {
      final path = resolver.resolveToPath(
        'content://com.android.externalstorage.documents/tree/'
        '1234-5678%3AMusic',
      );
      expect(path, '/storage/1234-5678/Music');
    });

    test('uses the document id when the URI selects a sub-folder', () {
      final path = resolver.resolveToPath(
        'content://com.android.externalstorage.documents/tree/'
        'primary%3AMusic/document/primary%3AMusic%2FLive',
      );
      expect(path, '/storage/emulated/0/Music/Live');
    });

    test('passes through a raw absolute path', () {
      final path = resolver.resolveToPath(
        'content://com.android.externalstorage.documents/tree/'
        'raw%3A%2Fstorage%2Femulated%2F0%2FMusic',
      );
      expect(path, '/storage/emulated/0/Music');
    });

    test('returns null for a non-external-storage provider', () {
      final path = resolver.resolveToPath(
        'content://com.android.providers.downloads.documents/tree/raw%3A',
      );
      expect(path, isNull);
    });

    test('returns null for a non-content URI', () {
      expect(resolver.resolveToPath('/home/me/Music'), isNull);
    });
  });
}
