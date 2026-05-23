/// One audio document discovered by walking an Android SAF tree.
///
/// Carries the `content://` document [uri] the platform can open and the
/// display [name] (with extension). The name is kept because a bare content URI
/// does not reliably expose a real title or file type, and the catalog needs
/// both — a readable title and a way to recognise the audio format.
class SafAudioDocument {
  const SafAudioDocument({required this.uri, required this.name});

  /// The `content://` document URI, openable by the platform and stable enough
  /// to use as a track id.
  final String uri;

  /// The document's display name, including its extension (e.g. `Song.flac`).
  final String name;
}

/// Thrown when SAF document traversal is not available on this build/platform,
/// so the caller can fall back to the legacy path-resolution scanner instead of
/// surfacing an error. Deliberately distinct from a real traversal failure
/// (which is a `FolderScanException`).
class SafUnsupportedException implements Exception {
  const SafUnsupportedException();

  @override
  String toString() => 'SAF document traversal is not available here.';
}

/// Lists the audio documents under an Android SAF `content://` tree URI using
/// the platform content resolver — the scoped-storage-friendly way to read a
/// user-picked folder without any broad storage permission.
///
/// This is the seam that lets a content-URI folder actually be scanned. The
/// production binding is `MethodChannelSafDocumentLister` (Android only); tests
/// inject a fake. An implementation either:
///  - returns the audio documents under the tree (possibly empty), or
///  - throws [SafUnsupportedException] when traversal isn't available on this
///    build (the caller then falls back to filesystem path resolution), or
///  - throws a `FolderScanException` when traversal is available but fails.
abstract interface class SafDocumentLister {
  Future<List<SafAudioDocument>> listAudioDocuments(String treeUri);
}

/// The default [SafDocumentLister] for platforms without native SAF traversal
/// (desktop, tests): it always reports SAF traversal unavailable, so the caller
/// falls back to the existing filesystem path scanner and behaviour there is
/// unchanged.
class UnsupportedSafDocumentLister implements SafDocumentLister {
  const UnsupportedSafDocumentLister();

  @override
  Future<List<SafAudioDocument>> listAudioDocuments(String treeUri) async {
    throw const SafUnsupportedException();
  }
}
