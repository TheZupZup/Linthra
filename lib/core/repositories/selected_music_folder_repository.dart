/// Remembers which folder the user chose to scan for music.
///
/// Kept deliberately separate from the picker (which only chooses a folder)
/// and from the scan logic (which only reads files): this contract owns just
/// the persistence of the single selected folder path/URI, so the choice
/// survives app restarts without any layer reaching into another's concerns.
abstract interface class SelectedMusicFolderRepository {
  /// The persisted folder path/URI, or `null` if the user has never chosen one
  /// (or has since cleared it).
  Future<String?> getSelectedFolder();

  /// Persists [pathOrUri] as the selected music folder, replacing any previous
  /// choice.
  Future<void> setSelectedFolder(String pathOrUri);

  /// Forgets the current selection.
  Future<void> clearSelectedFolder();
}
