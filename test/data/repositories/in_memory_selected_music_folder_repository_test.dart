import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';

void main() {
  group('InMemorySelectedMusicFolderRepository', () {
    test('returns nothing when no folder has been selected', () async {
      final repository = InMemorySelectedMusicFolderRepository();

      expect(await repository.getSelectedFolders(), isEmpty);
    });

    test('exposes an initial folder when seeded', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');

      expect(await repository.getSelectedFolders(), <String>['/music']);
    });

    test('exposes several initial folders when seeded', () async {
      final repository = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );

      expect(
        await repository.getSelectedFolders(),
        <String>['/music', '/media/usb'],
      );
    });

    test('setSelectedFolders replaces the stored selection', () async {
      final repository = InMemorySelectedMusicFolderRepository();

      await repository.setSelectedFolders(<String>['/a']);
      await repository.setSelectedFolders(<String>['/b', '/c']);

      expect(await repository.getSelectedFolders(), <String>['/b', '/c']);
    });

    test('setSelectedFolders drops empty entries', () async {
      final repository = InMemorySelectedMusicFolderRepository();

      await repository.setSelectedFolders(<String>['/a', '']);

      expect(await repository.getSelectedFolders(), <String>['/a']);
    });

    test('clearSelectedFolders forgets every folder', () async {
      final repository = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );

      await repository.clearSelectedFolders();

      expect(await repository.getSelectedFolders(), isEmpty);
    });
  });
}
