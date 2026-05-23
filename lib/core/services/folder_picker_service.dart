/// Opens the platform's native folder chooser so the user can pick a music
/// folder to scan.
///
/// This is the single seam between the app and whatever folder-picking plugin
/// runs underneath. Feature code depends only on this interface, so the UI
/// never imports `file_picker` (or any other plugin) directly and tests can
/// drive the flow with a fake.
abstract interface class FolderPickerService {
  /// Shows the folder chooser and returns the chosen folder's path or URI.
  ///
  /// Returns `null` when the user cancels, or when no picker is available on
  /// the current platform. The returned string is passed through verbatim to
  /// the scan flow; it may be a filesystem path (desktop) or a Storage Access
  /// Framework tree URI (Android).
  Future<String?> pickFolder();
}
