import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/repositories/favorites_store.dart';
import 'package:linthra/data/repositories/shared_preferences_favorites_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SharedPreferencesFavoritesStore', () {
    const SharedPreferencesFavoritesStore store =
        SharedPreferencesFavoritesStore();

    test('round-trips local and remote uri sets', () async {
      await store.save(const FavoritesData(
        localIds: <String>{'file:///a.mp3'},
        remoteIds: <String>{'jellyfin:101'},
      ));
      final FavoritesData loaded = await store.load();
      expect(loaded.localIds, <String>{'file:///a.mp3'});
      expect(loaded.remoteIds, <String>{'jellyfin:101'});
    });

    test('returns empty when nothing is stored', () async {
      expect((await store.load()).localIds, isEmpty);
      expect((await store.load()).remoteIds, isEmpty);
    });

    test('save writes the v2 key', () async {
      await store.save(const FavoritesData(remoteIds: <String>{'jellyfin:1'}));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('favorites_v2'), isNotNull);
    });

    group('v1 → v2 migration', () {
      test('namespaces bare Jellyfin remote ids and keeps local paths',
          () async {
        // A pre-uri store: local ids were already paths, remote ids were bare
        // Jellyfin item ids (only Jellyfin could favourite).
        SharedPreferences.setMockInitialValues(<String, Object>{
          'favorites_v1': jsonEncode(<String, dynamic>{
            'local': <String>['file:///a.mp3'],
            'remote': <String>['101', '202'],
          }),
        });

        final FavoritesData loaded = await store.load();

        expect(loaded.localIds, <String>{'file:///a.mp3'});
        expect(loaded.remoteIds, <String>{'jellyfin:101', 'jellyfin:202'});
      });

      test('prefers v2 over a leftover v1', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'favorites_v1': jsonEncode(<String, dynamic>{
            'local': <String>[],
            'remote': <String>['legacy'],
          }),
          'favorites_v2': jsonEncode(<String, dynamic>{
            'local': <String>[],
            'remote': <String>['jellyfin:current'],
          }),
        });

        final FavoritesData loaded = await store.load();

        expect(loaded.remoteIds, <String>{'jellyfin:current'});
      });

      test('does not double-namespace an already-namespaced id', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'favorites_v1': jsonEncode(<String, dynamic>{
            'local': <String>[],
            'remote': <String>['jellyfin:101'],
          }),
        });

        final FavoritesData loaded = await store.load();

        expect(loaded.remoteIds, <String>{'jellyfin:101'});
      });

      test('a corrupt v1 reads as no favourites', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'favorites_v1': 'not json {',
        });
        final FavoritesData loaded = await store.load();
        expect(loaded.localIds, isEmpty);
        expect(loaded.remoteIds, isEmpty);
      });
    });
  });
}
