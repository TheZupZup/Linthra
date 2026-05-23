import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';

void main() {
  group('InMemorySelectedMusicFolderRepository', () {
    test('returns null when nothing has been selected', () async {
      final repository = InMemorySelectedMusicFolderRepository();

      expect(await repository.getSelectedFolder(), isNull);
    });

    test('exposes an initial folder when seeded', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');

      expect(await repository.getSelectedFolder(), '/music');
    });

    test('setSelectedFolder replaces the stored value', () async {
      final repository = InMemorySelectedMusicFolderRepository();

      await repository.setSelectedFolder('/a');
      await repository.setSelectedFolder('/b');

      expect(await repository.getSelectedFolder(), '/b');
    });

    test('clearSelectedFolder forgets the selection', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');

      await repository.clearSelectedFolder();

      expect(await repository.getSelectedFolder(), isNull);
    });
  });
}
