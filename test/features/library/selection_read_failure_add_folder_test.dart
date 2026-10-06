// Adding a folder after the stored folder selection failed to load.
//
// When the selection can't be read at launch (an I/O error on the
// preferences file, a value of the wrong type in it), the app reads it as no
// folders, and Folders ▸ Add folder stays live on purpose
// (folders_add_folder_test.dart). But `addAndPersist` merged the pick into
// that unread selection: the new folder was saved alone over every folder
// still stored, and the scan after it dropped their music from the library.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/album.dart';
import 'package:linthra/core/models/artist.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/repositories/selected_music_folder_repository.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';
import 'package:linthra/data/repositories/in_memory_music_library_repository.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/selected_music_folder_repository_provider.dart';
import 'package:linthra/features/library/library_providers.dart';
import 'package:linthra/features/library/selected_folder_controller.dart';
import 'package:linthra/features/settings/source/local_music_controller.dart';

import 'fake_audio_file_scanner.dart';
import 'fake_folder_picker_service.dart';

/// The stored selection on storage whose first read fails, the way the
/// preferences file answers one read with an I/O error, and then answers.
class _FirstReadFails implements SelectedMusicFolderRepository {
  _FirstReadFails(this.folders);

  List<String> folders;
  int failures = 1;

  @override
  Future<List<String>> getSelectedFolders() async {
    if (failures > 0) {
      failures--;
      throw const FileSystemException(
        'Cannot read file',
        'shared_preferences.json',
        OSError('Input/output error', 5),
      );
    }
    return List<String>.of(folders);
  }

  @override
  Future<void> setSelectedFolders(List<String> pathsOrUris) async {
    folders = List<String>.of(pathsOrUris);
  }

  @override
  Future<void> clearSelectedFolders() async {
    folders = <String>[];
  }
}

Track _song(String path) => Track(id: path, title: path, uri: path);

void main() {
  test('the folders already stored, and their music, are kept', () async {
    final _FirstReadFails folderRepo =
        _FirstReadFails(<String>['/music', '/media/usb']);
    final InMemoryMusicLibraryRepository libraryRepo =
        InMemoryMusicLibraryRepository();
    // The library as the last launch left it.
    await libraryRepo.upsertCatalog(
      sourceId: 'local',
      tracks: <Track>[_song('/music/a.mp3'), _song('/media/usb/b.mp3')],
      albums: const <Album>[],
      artists: const <Artist>[],
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService(folder: '/srv/nas')),
        selectedMusicFolderRepositoryProvider.overrideWithValue(folderRepo),
        musicLibraryRepositoryProvider.overrideWithValue(libraryRepo),
        audioFileScannerProvider.overrideWithValue(
          FakeAudioFileScanner(
            filesByFolder: <String, List<String>>{
              '/music': <String>['/music/a.mp3'],
              '/media/usb': <String>['/media/usb/b.mp3'],
              '/srv/nas': <String>['/srv/nas/c.mp3'],
            },
          ),
        ),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(container.dispose);

    // This launch's read of the selection fails.
    await expectLater(
      container.read(selectedFolderControllerProvider.future),
      throwsA(isA<FileSystemException>()),
    );

    // Folders ▸ Add folder.
    await container.read(localMusicControllerProvider.notifier).addFolder();

    expect(folderRepo.folders, <String>['/music', '/media/usb', '/srv/nas']);
    expect(
      (await libraryRepo.getAllTracks()).map((Track t) => t.uri).toSet(),
      <String>{'/music/a.mp3', '/media/usb/b.mp3', '/srv/nas/c.mp3'},
    );
  });

  test('a pick the stored selection already covers changes nothing', () async {
    final _FirstReadFails folderRepo =
        _FirstReadFails(<String>['/music', '/media/usb']);
    final InMemoryMusicLibraryRepository libraryRepo =
        InMemoryMusicLibraryRepository();
    await libraryRepo.upsertCatalog(
      sourceId: 'local',
      tracks: <Track>[_song('/music/a.mp3'), _song('/media/usb/b.mp3')],
      albums: const <Album>[],
      artists: const <Artist>[],
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        folderPickerServiceProvider
            .overrideWithValue(FakeFolderPickerService(folder: '/music/live')),
        selectedMusicFolderRepositoryProvider.overrideWithValue(folderRepo),
        musicLibraryRepositoryProvider.overrideWithValue(libraryRepo),
        audioFileScannerProvider.overrideWithValue(
          FakeAudioFileScanner(
            filesByFolder: <String, List<String>>{
              '/music': <String>['/music/a.mp3'],
              '/media/usb': <String>['/media/usb/b.mp3'],
            },
          ),
        ),
        hostPlatformProvider.overrideWithValue(HostPlatform.linux),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(selectedFolderControllerProvider.future),
      throwsA(isA<FileSystemException>()),
    );

    await container.read(localMusicControllerProvider.notifier).addFolder();

    expect(folderRepo.folders, <String>['/music', '/media/usb']);
    expect(
      (await libraryRepo.getAllTracks()).map((Track t) => t.uri).toSet(),
      <String>{'/music/a.mp3', '/media/usb/b.mp3'},
    );
  });
}
