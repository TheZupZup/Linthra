/// How a selected music folder is addressed on the current platform.
///
/// The folder picker hands back a single opaque string (see
/// [FolderPickerService]). On desktop that is a real filesystem path; on
/// Android the Storage Access Framework returns a `content://…/tree/…` URI.
/// Scanning has to treat those two cases differently, so this classifies a raw
/// selection without anyone downstream having to re-parse the string.
enum FolderLocationKind {
  /// A real filesystem path the `dart:io` scanner can walk directly.
  filesystemPath,

  /// An Android SAF `content://` tree/document URI.
  contentUri,
}

/// A parsed view of a selected folder string and how to reach it.
class FolderLocation {
  const FolderLocation({required this.kind, required this.raw});

  /// Classifies [raw]. Anything using the `content` URI scheme is treated as a
  /// SAF selection; everything else is treated as a filesystem path. The check
  /// is scheme-based and case-insensitive, so `CONTENT://…` is still a content
  /// URI while `/home/me/Music` and `C:\Music` are paths.
  factory FolderLocation.parse(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    final bool isContent = uri != null && uri.scheme.toLowerCase() == 'content';
    return FolderLocation(
      kind: isContent
          ? FolderLocationKind.contentUri
          : FolderLocationKind.filesystemPath,
      raw: raw,
    );
  }

  final FolderLocationKind kind;
  final String raw;

  bool get isContentUri => kind == FolderLocationKind.contentUri;
  bool get isFilesystemPath => kind == FolderLocationKind.filesystemPath;

  /// A human-readable label for showing the user *their own* chosen folder in
  /// the app (never a public bug report). A SAF `content://` tree URI is reduced
  /// to its document id — e.g. `content://…/tree/primary%3AMusic%2Fmusi5`
  /// becomes `primary:Music/musi5` — so the user sees a recognizable folder
  /// instead of an opaque URI. A filesystem path is returned unchanged.
  String get displayLabel {
    if (!isContentUri) {
      return raw;
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) {
      return raw;
    }
    final List<String> segments = uri.pathSegments;
    final int treeIndex = segments.indexOf('tree');
    if (treeIndex >= 0 && treeIndex + 1 < segments.length) {
      // pathSegments are percent-decoded, so this is already e.g.
      // `primary:Music/musi5` rather than `primary%3AMusic%2Fmusi5`.
      return segments[treeIndex + 1];
    }
    return raw;
  }
}
