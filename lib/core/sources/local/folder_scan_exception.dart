/// Raised when a selected folder cannot be scanned for audio.
///
/// This is the single, typed error the scanning layer throws so the controller
/// can surface a clear message to the user instead of leaking a raw plugin or
/// `dart:io` failure. The most common case today is an Android SAF
/// `content://` tree URI that cannot be reached as a filesystem path on this
/// device (see [SafTreeUriResolver]).
class FolderScanException implements Exception {
  const FolderScanException(this.message, {this.folder});

  /// A user-facing explanation of why the scan could not run.
  final String message;

  /// The folder path or URI that could not be scanned, when known.
  final String? folder;

  @override
  String toString() => message;
}
