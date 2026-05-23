import 'package:flutter_test/flutter_test.dart';
import 'package:halcyon/data/repositories/in_memory_download_store.dart';

void main() {
  group('InMemoryDownloadStore', () {
    test('starts empty', () async {
      expect(await InMemoryDownloadStore().loadDownloadedIds(), isEmpty);
    });

    test('seeds from initial IDs', () async {
      final store = InMemoryDownloadStore(initialIds: <String>{'a', 'b'});
      expect(await store.loadDownloadedIds(), <String>{'a', 'b'});
    });

    test('save replaces the stored set', () async {
      final store = InMemoryDownloadStore(initialIds: <String>{'a'});
      await store.saveDownloadedIds(<String>{'b', 'c'});
      expect(await store.loadDownloadedIds(), <String>{'b', 'c'});
    });

    test('load returns a copy that callers cannot mutate', () async {
      final store = InMemoryDownloadStore(initialIds: <String>{'a'});
      (await store.loadDownloadedIds()).add('rogue');
      expect(await store.loadDownloadedIds(), <String>{'a'});
    });
  });
}
