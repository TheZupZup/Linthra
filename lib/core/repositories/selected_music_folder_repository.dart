/// Remembers which folders the user chose to scan for music.
///
/// Kept deliberately separate from the picker (which only chooses a folder)
/// and from the scan logic (which only reads files): this contract owns just
/// the persistence of the selected folder paths/URIs, so the choice survives
/// app restarts without any layer reaching into another's concerns.
///
/// The selection is an ordered list because a desktop library is often spread
/// over several places — an internal music folder, an external drive, a NAS
/// mount. Android keeps exactly one entry: a SAF tree grant or the device
/// library sentinel, neither of which combines with anything else.
abstract interface class SelectedMusicFolderRepository {
  /// The persisted folder paths/URIs in the user's order, or an empty list if
  /// they have never chosen one (or have since cleared the selection).
  Future<List<String>> getSelectedFolders();

  /// Persists [pathsOrUris] as the selected music folders, replacing any
  /// previous choice. An empty list clears the selection.
  Future<void> setSelectedFolders(List<String> pathsOrUris);

  /// Forgets every selected folder.
  Future<void> clearSelectedFolders();
}
