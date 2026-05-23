/// Best-effort mapping from an Android SAF tree/document URI to a real
/// filesystem path.
///
/// When the system folder picker returns a `content://…/tree/…` URI, scanning
/// still needs *something* the `dart:io` scanner can walk. For the common
/// external-storage provider the document id encodes a volume and a relative
/// path (e.g. `primary:Music`), which maps deterministically onto the device's
/// storage layout — so we can resolve it to a path without any native plugin or
/// extra permission.
///
/// This is intentionally pure string logic with no `dart:io` import: it is the
/// whole reason content-URI scanning is unit-testable. It is *best effort* —
/// SAF providers that don't expose a filesystem layout (cloud/document
/// providers, the downloads/media providers) return `null`, and the caller
/// turns that into a clear [FolderScanException]. Resolving those, and reading
/// trees that scoped storage hides behind the content resolver, is the native
/// SAF follow-up documented in the README.
class SafTreeUriResolver {
  const SafTreeUriResolver();

  /// The authority whose document ids map onto the on-device storage layout.
  static const String _externalStorageAuthority =
      'com.android.externalstorage.documents';

  /// The mount point of the device's primary (built-in) shared storage.
  static const String _primaryStorageRoot = '/storage/emulated/0';

  /// Resolves [folderUri] to an absolute filesystem path, or returns `null`
  /// when no reliable path mapping exists for it.
  String? resolveToPath(String folderUri) {
    final Uri? uri = Uri.tryParse(folderUri);
    if (uri == null || uri.scheme.toLowerCase() != 'content') {
      return null;
    }
    if (uri.host != _externalStorageAuthority) {
      // Other SAF providers (downloads, media, cloud) don't expose a stable
      // filesystem path we can walk.
      return null;
    }

    final String? documentId = _documentId(uri.pathSegments);
    if (documentId == null) {
      return null;
    }

    final int separator = documentId.indexOf(':');
    if (separator < 0) {
      return null;
    }
    final String volume = documentId.substring(0, separator);
    final String relativePath = documentId.substring(separator + 1);

    // `raw:` ids already carry an absolute path.
    if (volume == 'raw') {
      return relativePath.isEmpty ? null : relativePath;
    }

    final String root =
        volume == 'primary' ? _primaryStorageRoot : '/storage/$volume';
    if (relativePath.isEmpty) {
      return root;
    }
    return '$root/$relativePath';
  }

  /// Picks the most specific document id from a SAF URI's path segments.
  ///
  /// A tree URI is `…/tree/<treeDocId>`; selecting a sub-folder yields
  /// `…/tree/<treeDocId>/document/<docId>`, where the `document` id is the
  /// folder actually chosen — so prefer it when present.
  String? _documentId(List<String> segments) {
    final int documentIndex = segments.indexOf('document');
    if (documentIndex >= 0 && documentIndex + 1 < segments.length) {
      return segments[documentIndex + 1];
    }
    final int treeIndex = segments.indexOf('tree');
    if (treeIndex >= 0 && treeIndex + 1 < segments.length) {
      return segments[treeIndex + 1];
    }
    return null;
  }
}
