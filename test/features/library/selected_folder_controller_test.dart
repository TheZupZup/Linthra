import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:sonara/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:sonara/features/library/library_providers.dart';
import 'package:sonara/features/library/selected_folder_controller.dart';

import 'fake_folder_picker_service.dart';

ProviderContainer _container({
  required FakeFolderPickerService picker,
  required InMemorySelectedMusicFolderRepository repository,
}) {
  final container = ProviderContainer(
    overrides: [
      folderPickerServiceProvider.overrideWithValue(picker),
      selectedMusicFolderRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('SelectedFolderController', () {
    test('loads the persisted folder on build', () async {
      final container = _container(
        picker: FakeFolderPickerService(),
        repository:
            InMemorySelectedMusicFolderRepository(initialFolder: '/music'),
      );

      final value =
          await container.read(selectedFolderControllerProvider.future);

      expect(value, '/music');
    });

    test('starts with no folder when none is persisted', () async {
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: InMemorySelectedMusicFolderRepository(),
      );

      final value =
          await container.read(selectedFolderControllerProvider.future);

      expect(value, isNull);
    });

    test('pickAndPersist stores the chosen folder and updates state', () async {
      final repository = InMemorySelectedMusicFolderRepository();
      final container = _container(
        picker: FakeFolderPickerService(folder: '/new/music'),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      final picked = await container
          .read(selectedFolderControllerProvider.notifier)
          .pickAndPersist();

      expect(picked, '/new/music');
      expect(
        container.read(selectedFolderControllerProvider).value,
        '/new/music',
      );
      expect(await repository.getSelectedFolder(), '/new/music');
    });

    test('pickAndPersist leaves state unchanged when cancelled', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        picker: FakeFolderPickerService(folder: null),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      final picked = await container
          .read(selectedFolderControllerProvider.notifier)
          .pickAndPersist();

      expect(picked, isNull);
      expect(container.read(selectedFolderControllerProvider).value, '/music');
      expect(await repository.getSelectedFolder(), '/music');
    });

    test('clear forgets the selection', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(selectedFolderControllerProvider.notifier).clear();

      expect(container.read(selectedFolderControllerProvider).value, isNull);
      expect(await repository.getSelectedFolder(), isNull);
    });
  });
}
