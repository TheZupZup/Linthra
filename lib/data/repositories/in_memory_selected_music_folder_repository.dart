import '../../core/repositories/selected_music_folder_repository.dart';

/// A non-persistent [SelectedMusicFolderRepository] for development and tests.
///
/// Holds the selection in a single field, so it is forgotten when the instance
/// is dropped. This is the default binding (mirroring how the catalog defaults
/// to the in-memory repository); the running app swaps in the
/// `shared_preferences` implementation so the choice survives restarts.
class InMemorySelectedMusicFolderRepository
    implements SelectedMusicFolderRepository {
  InMemorySelectedMusicFolderRepository({String? initialFolder})
      : _folder = initialFolder;

  String? _folder;

  @override
  Future<String?> getSelectedFolder() async => _folder;

  @override
  Future<void> setSelectedFolder(String pathOrUri) async {
    _folder = pathOrUri;
  }

  @override
  Future<void> clearSelectedFolder() async {
    _folder = null;
  }
}
