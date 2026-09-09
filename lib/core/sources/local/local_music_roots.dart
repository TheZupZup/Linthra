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
/// Only real filesystem paths take part in the containment rules. Android's SAF
/// `content://` trees and the MediaStore sentinel are opaque strings with no
/// meaningful path arithmetic, so they are compared literally: Android keeps
/// exactly one local selection.
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

  /// A stable spelling of one selected folder: trimmed, and for filesystem
  /// paths normalized (`/music/../music/rock` and a trailing separator both
  /// collapse) so the same folder picked twice compares equal.
  static String canonicalize(String root) {
    final String trimmed = root.trim();
    if (trimmed.isEmpty) return '';
    if (!FolderLocation.parse(trimmed).isFilesystemPath) return trimmed;
    final String normalized = p.normalize(trimmed);
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

  /// Whether [outer] is [inner] or contains it. Only filesystem paths nest;
  /// opaque selections are compared literally.
  static bool _covers(String outer, String inner) {
    if (outer.isEmpty || inner.isEmpty) return false;
    if (outer == inner) return true;
    if (!FolderLocation.parse(outer).isFilesystemPath) return false;
    if (!FolderLocation.parse(inner).isFilesystemPath) return false;
    return p.isWithin(outer, inner);
  }
}
