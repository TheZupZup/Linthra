import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/remote_cache/remote_cache_index.dart';
import '../../core/services/remote_cache/remote_cache_store.dart';
import 'file_remote_cache_store.dart';

/// The durable, credential-free remote-cache index's on-disk store: a JSON
/// manifest under the app-support `remote_cache/` directory. It only ever holds
/// each warmed track's opaque key + timestamps — never a stream URL or token.
final remoteCacheStoreProvider = Provider<RemoteCacheStore>((ref) {
  return FileRemoteCacheStore();
});

/// The durable index that remembers (credential-free) which remote tracks the
/// prebufferer has warmed, so the cache's knowledge survives a restart.
///
/// Pinned for the session and shared across the app: the write side
/// (`remoteStreamPrebuffererProvider`) records into it, `main` loads it at
/// startup (pruning stale records as it loads), and each provider's
/// disconnect/sign-out flow calls [RemoteCacheIndex.removeSource] so a
/// disconnected account's prepared-track records don't linger. Lives in the data
/// layer (not the player feature) so both the player and the settings
/// controllers can depend on it without a cross-feature import cycle.
///
/// Best-effort throughout: it never persists a URL and never throws into
/// playback. It deliberately stores no stream URL, so a provider URL is always
/// re-resolved fresh after a restart rather than replayed stale.
final remoteCacheIndexProvider = Provider<RemoteCacheIndex>((ref) {
  return RemoteCacheIndex(store: ref.watch(remoteCacheStoreProvider));
});
