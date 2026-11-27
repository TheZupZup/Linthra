import 'package:path/path.dart' as p;

import 'folder_location.dart';

/// The rules that turn the user's list of local music folders into the set of
/// roots a scan actually walks, and that decide which root owns a track.
///
/// Everything here is pure string/path reasoning so the multi-folder behavior
/// can be unit-tested without a disk, and so the scan, the retention logic and
/// the Settings UI all agree on what "the same folder" means.
///
/// Two rules do the real work:
///
///  * **Normalization.** Blank entries, duplicates and folders that already sit
///    inside another selected folder are dropped, keeping the outermost one.
///    That is what stops overlapping selections (`~/Music` and
///    `~/Music/Live sets`) from importing the same file twice — the file is
///    only ever visited once, under one root, so it also gets one stable set of
///    folder-derived artist/album names.
///  * **Ownership.** Every scanned file belongs to exactly one root: the
///    selected folder it lives under. Roots are disjoint after normalization,
///    so that mapping is unambiguous, and it is what lets Linthra keep the
///    tracks of a folder that is temporarily offline while still refreshing the
///    folders it can read.
///
/// Filesystem paths nest by their path. Android's SAF trees nest only on
/// shared storage (`com.android.externalstorage.documents`), whose tree ids
/// are `volume:path`: `primary:Music` holds `primary:Music/Rock`. Any other
/// provider's ids are opaque, so its trees, like the MediaStore sentinel, are
/// compared literally.
abstract final class LocalMusicRoots {
  /// The selected folders reduced to the roots a scan should walk, in the
  /// user's order.
  ///
  /// Drops blanks, exact duplicates, and any folder contained in another
  /// selected folder. When a newly added folder contains ones already in the
  /// list, the contained ones give way to it, so the outermost selection always
  /// wins regardless of the order they were added in.
  static List<String> normalize(Iterable<String> roots) {
    final List<String> kept = <String>[];
    for (final String raw in roots) {
      final String root = canonicalize(raw);
      if (root.isEmpty) continue;
      if (kept.any((String existing) => _covers(existing, root))) continue;
      kept.removeWhere((String existing) => _covers(root, existing));
      kept.add(root);
    }
    return kept;
  }

  /// A stable spelling of one selected folder: blank is no folder, and for
  /// filesystem paths normalized (`/music/../music/rock` and a trailing
  /// separator both collapse) so the same folder picked twice compares equal.
  ///
  /// A filesystem path keeps its trailing whitespace. On Linux it is part of
  /// the last folder's name (`Music ` and `Music` are two different folders),
  /// so trimming it pointed every scan, watch and probe at another folder, or
  /// at one that does not exist.
  static String canonicalize(String root) {
    final String trimmed = root.trim();
    if (trimmed.isEmpty) return '';
    if (!FolderLocation.parse(trimmed).isFilesystemPath) return trimmed;
    final String normalized = p.normalize(root.trimLeft());
    if (normalized.length > 1 && normalized.endsWith(p.separator)) {
      return normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Whether [root] is the folder [pathOrUri] was scanned from — the same
  /// folder, or an ancestor of it.
  static bool owns(String root, String pathOrUri) {
    final String canonicalRoot = canonicalize(root);
    if (canonicalRoot.isEmpty) return false;
    if (!FolderLocation.parse(canonicalRoot).isFilesystemPath) {
      // Opaque selections (SAF trees, the MediaStore sentinel) own only what
      // literally sits under them; there is no path arithmetic to do.
      return pathOrUri == canonicalRoot ||
          pathOrUri.startsWith('$canonicalRoot/');
    }
    if (!FolderLocation.parse(pathOrUri).isFilesystemPath) return false;
    final String path = p.normalize(pathOrUri);
    return path == canonicalRoot || p.isWithin(canonicalRoot, path);
  }

  /// The root [pathOrUri] belongs to, or null when no selected folder covers
  /// it — a track left over from a folder the user has since removed.
  ///
  /// Roots are expected to be [normalize]d and therefore disjoint; the deepest
  /// match is still preferred so an un-normalized list gives a deterministic
  /// answer rather than an order-dependent one.
  static String? ownerOf(String pathOrUri, Iterable<String> roots) {
    String? owner;
    for (final String root in roots) {
      final String canonical = canonicalize(root);
      if (!owns(canonical, pathOrUri)) continue;
      if (owner == null || canonical.length > owner.length) {
        owner = canonical;
      }
    }
    return owner;
  }

  /// Whether [root] would add anything to [roots], i.e. it is not already
  /// selected and not already covered by a selected folder. Lets the UI tell
  /// the user their pick changed nothing instead of silently doing nothing.
  static bool isCoveredBy(String root, Iterable<String> roots) {
    final String candidate = canonicalize(root);
    if (candidate.isEmpty) return true;
    return roots.any(
      (String existing) => _covers(canonicalize(existing), candidate),
    );
  }

  /// Whether [outer] is [inner] or contains it. Filesystem paths and shared
  /// storage SAF trees nest; other selections are compared literally.
  static bool _covers(String outer, String inner) {
    if (outer.isEmpty || inner.isEmpty) return false;
    if (outer == inner) return true;
    final String? outerTree = _sharedStorageTree(outer);
    final String? innerTree = _sharedStorageTree(inner);
    if (outerTree != null && innerTree != null) {
      // `primary:` is the volume's root; anything else is a folder whose
      // children are `<folder>/...`.
      return innerTree == outerTree ||
          (outerTree.endsWith(':')
              ? innerTree.startsWith(outerTree)
              : innerTree.startsWith('$outerTree/'));
    }
    if (!FolderLocation.parse(outer).isFilesystemPath) return false;
    if (!FolderLocation.parse(inner).isFilesystemPath) return false;
    return p.isWithin(outer, inner);
  }

  static const String _sharedStorageTrees =
      'content://com.android.externalstorage.documents/tree/';

  /// The tree id of a SAF tree on shared storage (`primary:Music`), or null
  /// for anything else, a document inside a tree included.
  static String? _sharedStorageTree(String uri) {
    if (!uri.startsWith(_sharedStorageTrees)) return null;
    final String encoded = uri.substring(_sharedStorageTrees.length);
    if (encoded.isEmpty || encoded.contains('/')) return null;
    try {
      return Uri.decodeComponent(encoded);
    } on ArgumentError {
      return null; // not valid percent-encoding
    } on FormatException {
      return null; // decodes to bytes that aren't UTF-8
    }
  }
}
