import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/in_memory_selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';

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

      expect(value, <String>['/music']);
    });

    test('loads every persisted folder on build', () async {
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: InMemorySelectedMusicFolderRepository(
          initialFolders: <String>['/music', '/media/usb'],
        ),
      );

      final value =
          await container.read(selectedFolderControllerProvider.future);

      expect(value, <String>['/music', '/media/usb']);
    });

    test('starts with no folder when none is persisted', () async {
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: InMemorySelectedMusicFolderRepository(),
      );

      final value =
          await container.read(selectedFolderControllerProvider.future);

      expect(value, isEmpty);
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
        <String>['/new/music'],
      );
      expect(await repository.getSelectedFolders(), <String>['/new/music']);
    });

    test('pickAndPersist replaces the whole selection', () async {
      final repository = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );
      final container = _container(
        picker: FakeFolderPickerService(folder: '/new/music'),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container
          .read(selectedFolderControllerProvider.notifier)
          .pickAndPersist();

      expect(await repository.getSelectedFolders(), <String>['/new/music']);
    });

    test('pickAndAdd keeps the folders already selected', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        picker: FakeFolderPickerService(folder: '/media/usb'),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      final picked = await container
          .read(selectedFolderControllerProvider.notifier)
          .pickAndAdd();

      expect(picked, '/media/usb');
      expect(
        container.read(selectedFolderControllerProvider).value,
        <String>['/music', '/media/usb'],
      );
      expect(
        await repository.getSelectedFolders(),
        <String>['/music', '/media/usb'],
      );
    });

    test('adding a folder inside a selected one changes nothing', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        picker: FakeFolderPickerService(folder: '/music/live sets'),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container
          .read(selectedFolderControllerProvider.notifier)
          .pickAndAdd();

      expect(await repository.getSelectedFolders(), <String>['/music']);
    });

    test('adding a folder that contains a selected one replaces it', () async {
      final repository = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music/live sets', '/media/usb'],
      );
      final container = _container(
        picker: FakeFolderPickerService(folder: '/music'),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container
          .read(selectedFolderControllerProvider.notifier)
          .pickAndAdd();

      expect(
        await repository.getSelectedFolders(),
        <String>['/media/usb', '/music'],
      );
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
      expect(
        container.read(selectedFolderControllerProvider).value,
        <String>['/music'],
      );
      expect(await repository.getSelectedFolders(), <String>['/music']);
    });

    test('removeAndPersist drops one folder and keeps the rest', () async {
      final repository = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container
          .read(selectedFolderControllerProvider.notifier)
          .removeAndPersist('/media/usb');

      expect(
        container.read(selectedFolderControllerProvider).value,
        <String>['/music'],
      );
      expect(await repository.getSelectedFolders(), <String>['/music']);
    });

    test('removeAndPersist ignores a folder that is not selected', () async {
      final repository =
          InMemorySelectedMusicFolderRepository(initialFolder: '/music');
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container
          .read(selectedFolderControllerProvider.notifier)
          .removeAndPersist('/media/usb');

      expect(await repository.getSelectedFolders(), <String>['/music']);
    });

    test('clear forgets every folder', () async {
      final repository = InMemorySelectedMusicFolderRepository(
        initialFolders: <String>['/music', '/media/usb'],
      );
      final container = _container(
        picker: FakeFolderPickerService(),
        repository: repository,
      );
      await container.read(selectedFolderControllerProvider.future);

      await container.read(selectedFolderControllerProvider.notifier).clear();

      expect(container.read(selectedFolderControllerProvider).value, isEmpty);
      expect(await repository.getSelectedFolders(), isEmpty);
    });
  });
}
