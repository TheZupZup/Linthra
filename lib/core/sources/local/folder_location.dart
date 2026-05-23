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
}
