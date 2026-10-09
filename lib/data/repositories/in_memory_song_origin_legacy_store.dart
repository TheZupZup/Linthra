import '../../core/repositories/song_origin_legacy_store.dart';

/// A [SongOriginLegacyStore] that lives as long as the instance, for tests.
class InMemorySongOriginLegacyStore implements SongOriginLegacyStore {
  InMemorySongOriginLegacyStore([Map<String, String>? settled])
      : settled = <String, String>{...?settled};

  Map<String, String> settled;

  @override
  Future<Map<String, String>> read() async => <String, String>{...settled};

  @override
  Future<void> write(Map<String, String> settled) async {
    this.settled = <String, String>{...settled};
  }
}
