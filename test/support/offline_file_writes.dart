import 'package:linthra/core/repositories/offline_file_store.dart';

/// Writes a whole cache file at once, the way tests seed an offline store: a
/// draft added to once and published.
extension OfflineFileWrites on OfflineFileStore {
  Future<String> write(
    String trackId,
    List<int> bytes, {
    String? extension,
  }) async {
    final OfflineFileDraft draft = await createDraft(trackId);
    try {
      await draft.add(bytes);
      return await draft.publish(extension: extension);
    } finally {
      await draft.discard();
    }
  }
}
