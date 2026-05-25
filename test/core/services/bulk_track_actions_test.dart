import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/bulk_track_actions.dart';

Track _local(String id) => Track(id: id, title: id, uri: 'file:///$id.mp3');

Track _jellyfin(String id) => Track(id: id, title: id, uri: 'jellyfin:$id');

Track _subsonic(String id) => Track(id: id, title: id, uri: 'subsonic:$id');

void main() {
  group('bulkActionsFor', () {
    test('empty selection offers nothing', () {
      final BulkActionAvailability a =
          bulkActionsFor(const <Track>[], inPlaylist: false);
      expect(a.canAddToPlaylist, isFalse);
      expect(a.canRemoveFromLibrary, isFalse);
      expect(a.canRemoveOfflineCopy, isFalse);
      expect(a.canDeleteLocalFiles, isFalse);
      expect(a.canDeleteFromServer, isFalse);
    });

    test('a single local track: add + remove-from-library, no offline', () {
      final BulkActionAvailability a =
          bulkActionsFor(<Track>[_local('1')], inPlaylist: false);
      expect(a.canAddToPlaylist, isTrue);
      expect(a.canRemoveFromLibrary, isTrue);
      // Local tracks have no app-managed offline copy.
      expect(a.canRemoveOfflineCopy, isFalse);
      // Destructive deletes are not enabled in this release.
      expect(a.canDeleteLocalFiles, isFalse);
      expect(a.canDeleteFromServer, isFalse);
    });

    test('Jellyfin tracks expose remove-offline', () {
      final BulkActionAvailability a =
          bulkActionsFor(<Track>[_jellyfin('1')], inPlaylist: false);
      expect(a.canRemoveOfflineCopy, isTrue);
      expect(a.canRemoveFromLibrary, isTrue);
      // Server delete stays off (capability disabled in this release).
      expect(a.canDeleteFromServer, isFalse);
    });

    test('remove-from-playlist only inside a playlist', () {
      expect(
        bulkActionsFor(<Track>[_local('1')], inPlaylist: true)
            .canRemoveFromPlaylist,
        isTrue,
      );
      expect(
        bulkActionsFor(<Track>[_local('1')], inPlaylist: false)
            .canRemoveFromPlaylist,
        isFalse,
      );
    });

    test('a mixed-source selection still allows the safe actions', () {
      final BulkActionAvailability a = bulkActionsFor(
        <Track>[_local('1'), _jellyfin('2'), _subsonic('3')],
        inPlaylist: false,
      );
      // Safe, reversible actions are available for every source.
      expect(a.canAddToPlaylist, isTrue);
      expect(a.canRemoveFromLibrary, isTrue);
      // At least one of them can have an offline copy.
      expect(a.canRemoveOfflineCopy, isTrue);
      // But destructive deletes are hidden for a mixed selection.
      expect(a.canDeleteLocalFiles, isFalse);
      expect(a.canDeleteFromServer, isFalse);
    });
  });
}
