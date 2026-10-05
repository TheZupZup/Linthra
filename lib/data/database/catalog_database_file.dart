import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The library catalog's file name, the same in every place it has lived.
const String catalogFileName = 'linthra.sqlite';

/// The files SQLite keeps beside a catalog. A write cut off by a crash leaves
/// a journal that SQLite replays the next time the catalog opens, so the
/// catalog only ever moves together with whichever of these it has.
const List<String> _companionSuffixes = <String>['-journal', '-wal', '-shm'];

/// The catalog file for this platform.
///
/// Android keeps the app documents directory it has always used, which is
/// private to the app there. Everywhere else the catalog lives in the
/// application support directory, beside the offline audio, the remote cache
/// and the artwork. On Linux path_provider answers "documents" with the
/// user's own Documents folder: the catalog sat among the user's files, failed
/// to open at all without `xdg-user-dir`, and in the Flatpak, which cannot see
/// Documents, it landed in the sandbox's temporary home and was gone after
/// every exit.
///
/// A catalog an earlier Linux build left in Documents is moved over the first
/// time. If it cannot be moved it opens where it is, as before, rather than
/// starting the library over.
Future<File> resolveCatalogFile({
  bool? isAndroid,
  Future<Directory> Function() documentsDirectory =
      getApplicationDocumentsDirectory,
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory,
}) async {
  if (isAndroid ?? Platform.isAndroid) {
    final Directory documents = await documentsDirectory();
    return File(p.join(documents.path, catalogFileName));
  }
  final Directory support = await supportDirectory();
  await support.create(recursive: true);
  final File catalog = File(p.join(support.path, catalogFileName));
  if (await catalog.exists()) return catalog;
  final File? legacy = await _legacyCatalog(documentsDirectory);
  if (legacy == null) return catalog;
  return _adopt(legacy, catalog);
}

/// The catalog an earlier Linux build kept in the documents folder, if any.
/// No documents folder at all (no `xdg-user-dir`) just means there is nothing
/// to move.
Future<File?> _legacyCatalog(
  Future<Directory> Function() documentsDirectory,
) async {
  final Directory documents;
  try {
    documents = await documentsDirectory();
  } catch (_) {
    return null;
  }
  final File legacy = File(p.join(documents.path, catalogFileName));
  return await legacy.exists() ? legacy : null;
}

/// Copies [legacy] and its companions to [catalog], then removes the
/// originals. Returns the file to open: [catalog] once it is complete, or
/// [legacy] if the copy failed.
///
/// A copy rather than a rename, because Documents can sit on another disk
/// than the data directory, and because the original stays whole until the
/// new one is. The companions go first and the catalog last, under a
/// temporary name renamed into place, so the catalog existing is what says
/// the move finished. One cut off halfway simply runs again on the next
/// launch.
Future<File> _adopt(File legacy, File catalog) async {
  final File partial = File('${catalog.path}.partial');
  try {
    for (final String suffix in _companionSuffixes) {
      final File from = File('${legacy.path}$suffix');
      final File to = File('${catalog.path}$suffix');
      if (await from.exists()) {
        await from.copy(to.path);
      } else if (await to.exists()) {
        // Left by an earlier attempt for a journal the catalog no longer
        // has. Replayed into the copy, it would corrupt it.
        await to.delete();
      }
    }
    await legacy.copy(partial.path);
    await partial.rename(catalog.path);
  } catch (_) {
    await _deleteQuietly(<File>[
      partial,
      for (final String suffix in _companionSuffixes)
        File('${catalog.path}$suffix'),
    ]);
    return legacy;
  }
  // Companions before the catalog: a journal left behind without its catalog
  // could be replayed into whatever catalog an older build creates there next.
  await _deleteQuietly(<File>[
    for (final String suffix in _companionSuffixes)
      File('${legacy.path}$suffix'),
    legacy,
  ]);
  return catalog;
}

Future<void> _deleteQuietly(List<File> files) async {
  for (final File file in files) {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort: a leftover here is never opened in place of the catalog.
    }
  }
}
