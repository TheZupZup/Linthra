import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/repositories/song_origin_legacy_store.dart';
import '../../core/services/song_origins.dart';
import 'in_memory_song_origin_legacy_store.dart';
import 'shared_preferences_song_origin_legacy_store.dart';

/// Where the songs stored references name came from (#795). The data-layer
/// default binds nothing, so tests that don't care see every reference match;
/// the app overrides it with the signed-in sessions (see
/// `songOriginsOverride`).
final songOriginsProvider = Provider<SongOrigins>((ref) {
  return const UnboundSongOrigins();
});

/// Fires (with a running count) whenever [songOriginsProvider]'s answers may
/// have changed, for what resolves stored references on screen.
final songOriginChangesProvider = StreamProvider<int>((ref) async* {
  int changes = 0;
  yield changes;
  await for (final void _ in ref.watch(songOriginsProvider).changes) {
    yield ++changes;
  }
});

/// Where the settled origin of older references is kept. In-memory by
/// default; the app overrides it with the `shared_preferences` binding below.
final songOriginLegacyStoreProvider = Provider<SongOriginLegacyStore>((ref) {
  return InMemorySongOriginLegacyStore();
});

/// Production binding for [songOriginLegacyStoreProvider].
final sharedPreferencesSongOriginLegacyStoreOverride =
    songOriginLegacyStoreProvider.overrideWithValue(
  const SharedPreferencesSongOriginLegacyStore(),
);
