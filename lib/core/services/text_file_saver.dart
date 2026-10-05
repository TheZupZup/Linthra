import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// What became of a [TextFileSaver.save].
sealed class TextFileSaveResult {
  const TextFileSaveResult();
}

/// Written to [path]. Show only a redacted form of it: the directories leading
/// to it can be private.
final class TextFileSaved extends TextFileSaveResult {
  const TextFileSaved(this.path);

  final String path;
}

/// The listener closed the save dialog without choosing a place. Nothing to
/// report: they changed their mind.
final class TextFileSaveCancelled extends TextFileSaveResult {
  const TextFileSaveCancelled();
}

/// It could not be saved: no save dialog here, a place that can't be written,
/// a write that failed.
final class TextFileSaveFailed extends TextFileSaveResult {
  const TextFileSaveFailed();
}

/// Saves a text file the listener asked for (a bug report, a diagnostics
/// snapshot) where they can find it. Never throws.
abstract interface class TextFileSaver {
  /// Saves [contents], offering [suggestedName] as the file name and
  /// [dialogTitle] as the title of a save dialog, where there is one.
  Future<TextFileSaveResult> save({
    required String suggestedName,
    required String contents,
    required String dialogTitle,
  });
}

/// Writes straight into the app's documents directory, asking nothing: what
/// every platform did before Linux got a save dialog (#748), and what Android
/// still does.
class DocumentsDirectoryTextFileSaver implements TextFileSaver {
  const DocumentsDirectoryTextFileSaver({
    Future<Directory> Function() directory = getApplicationDocumentsDirectory,
  }) : _directory = directory;

  final Future<Directory> Function() _directory;

  @override
  Future<TextFileSaveResult> save({
    required String suggestedName,
    required String contents,
    required String dialogTitle,
  }) async {
    try {
      final Directory dir = await _directory();
      final File file = File('${dir.path}/$suggestedName');
      await file.writeAsString(contents, flush: true);
      return TextFileSaved(file.path);
    } catch (_) {
      return const TextFileSaveFailed();
    }
  }
}
