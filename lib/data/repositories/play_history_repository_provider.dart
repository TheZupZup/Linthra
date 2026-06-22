import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/play_history_repository.dart';
import '../../core/repositories/play_history_store.dart';
import 'default_play_history_repository.dart';
import 'in_memory_play_history_store.dart';
import 'music_library_repository_provider.dart';
import 'shared_preferences_play_history_store.dart';

/// Durable store of the user's play history. Defaults to in-memory so tests and
/// dev runs need no plugins; the app overrides it with the `shared_preferences`
/// binding below so counts and last-played times survive a restart.
final playHistoryStoreProvider = Provider<PlayHistoryStore>((ref) {
  return InMemoryPlayHistoryStore();
});

/// The app's [PlayHistoryRepository]. Pinned for the session (the player records
/// completions into it and the smart-mix UI reads its stream) and disposed with
/// the scope.
final playHistoryRepositoryProvider = Provider<PlayHistoryRepository>((ref) {
  final DefaultPlayHistoryRepository repository = DefaultPlayHistoryRepository(
    store: ref.watch(playHistoryStoreProvider),
    // Resolve legacy bare-id history onto provider uris against the live catalog
    // (unambiguous ids only); see DefaultPlayHistoryRepository for the rules.
    catalogForMigration: () =>
        ref.read(musicLibraryRepositoryProvider).getAllTracks(),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

/// Production binding: persist play history via `shared_preferences` so it
/// survives a restart. Applied in `main`; tests keep the in-memory default.
final sharedPreferencesPlayHistoryStoreOverride =
    playHistoryStoreProvider.overrideWithValue(
  const SharedPreferencesPlayHistoryStore(),
);
