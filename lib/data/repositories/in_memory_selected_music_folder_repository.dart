import '../../core/repositories/selected_music_folder_repository.dart';

/// A non-persistent [SelectedMusicFolderRepository] for development and tests.
///
/// Holds the selection in a single field, so it is forgotten when the instance
/// is dropped. This is the default binding (mirroring how the catalog defaults
/// to the in-memory repository); the running app swaps in the
/// `shared_preferences` implementation so the choice survives restarts.
class InMemorySelectedMusicFolderRepository
    implements SelectedMusicFolderRepository {
  InMemorySelectedMusicFolderRepository({
    String? initialFolder,
    List<String>? initialFolders,
  }) : _folders = <String>[
          if (initialFolder != null && initialFolder.isNotEmpty) initialFolder,
          ...?initialFolders,
        ];

  List<String> _folders;

  @override
  Future<List<String>> getSelectedFolders() async => List<String>.of(_folders);

  @override
  Future<void> setSelectedFolders(List<String> pathsOrUris) async {
    _folders = <String>[
      for (final String folder in pathsOrUris)
        if (folder.isNotEmpty) folder,
    ];
  }

  @override
  Future<void> clearSelectedFolders() async {
    _folders = <String>[];
  }
}
