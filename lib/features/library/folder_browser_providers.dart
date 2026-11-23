import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/music_folder.dart';
import '../../core/services/folder_browsable_music_source.dart';
import '../../core/sources/jellyfin/jellyfin_folder_browser_source.dart';
import '../../core/sources/subsonic/subsonic_folder_browser_source.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';

/// Live Jellyfin folder browser, present only while a session is connected.
final jellyfinFolderBrowserSourceProvider =
    Provider<JellyfinFolderBrowserSource?>((ref) {
  final bool connected = ref.watch(
    jellyfinSettingsControllerProvider.select((state) => state.isConnected),
  );
  if (!connected) return null;
  final session = ref.read(jellyfinSettingsControllerProvider.notifier).session;
  if (session == null) return null;
  final JellyfinFolderBrowserSource source =
      JellyfinFolderBrowserSource(session: session);
  ref.onDispose(source.close);
  return source;
});

/// Live Navidrome/Subsonic folder browser, present only while connected.
final subsonicFolderBrowserSourceProvider =
    Provider<SubsonicFolderBrowserSource?>((ref) {
  final bool connected = ref.watch(
    subsonicSettingsControllerProvider.select((state) => state.isConnected),
  );
  if (!connected) return null;
  final session = ref.read(subsonicSettingsControllerProvider.notifier).session;
  if (session == null) return null;
  final SubsonicFolderBrowserSource source =
      SubsonicFolderBrowserSource(session: session);
  ref.onDispose(source.close);
  return source;
});

/// Every currently connected source that can expose a directory hierarchy.
final folderBrowsableSourcesProvider =
    Provider<List<FolderBrowsableMusicSource>>((ref) {
  final JellyfinFolderBrowserSource? jellyfin =
      ref.watch(jellyfinFolderBrowserSourceProvider);
  final SubsonicFolderBrowserSource? subsonic =
      ref.watch(subsonicFolderBrowserSourceProvider);
  return <FolderBrowsableMusicSource>[
    if (jellyfin != null) jellyfin,
    if (subsonic != null) subsonic,
  ];
});

/// How long a fetched directory level stays cached once nothing is watching it.
///
/// Browsing is a walk: you open a folder, look, and come back up. Without this
/// every step back re-asked the server for a level that was on screen seconds
/// earlier, which is slow on a remote library and rude to a self-hosted one.
/// Bounded rather than kept for the whole session so a long browse does
/// not hold every level it ever visited, and short enough that a folder changed
/// on the server shows up again quickly.
const Duration folderListingCacheDuration = Duration(minutes: 5);

/// Holds this provider's value for [folderListingCacheDuration] *after its last
/// listener leaves*, then lets it dispose as usual.
///
/// The window deliberately starts on [Ref.onCancel] rather than at fetch time.
/// Measuring from the fetch would expire the cache while the user is still
/// looking at the folder, so opening a child after reading a long track list and
/// coming straight back would re-fetch the level they never left — exactly the
/// walk this exists to make instant. Returning within the window cancels the
/// timer through [Ref.onResume], so the level is kept for as long as it stays in
/// use.
///
/// Applied only after a successful fetch: caching a failure would keep an error
/// on screen for minutes, and the retry path invalidates anyway.
void _cacheBriefly(Ref ref) {
  final KeepAliveLink link = ref.keepAlive();
  Timer? expiry;

  ref.onCancel(() {
    expiry?.cancel();
    expiry = Timer(folderListingCacheDuration, link.close);
  });
  ref.onResume(() {
    expiry?.cancel();
    expiry = null;
  });
  ref.onDispose(() => expiry?.cancel());
}

/// Loads the top-level folders for one connected provider.
final folderRootFoldersProvider = FutureProvider.autoDispose
    .family<List<MusicFolder>, String>((ref, sourceId) async {
  final List<MusicFolder> roots =
      await _source(ref, sourceId).fetchRootFolders();
  _cacheBriefly(ref);
  return roots;
});

/// Identifies one directory request without exposing provider credentials.
class FolderBrowseRequest {
  const FolderBrowseRequest({
    required this.sourceId,
    required this.folderId,
  });

  final String sourceId;
  final String folderId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderBrowseRequest &&
          other.sourceId == sourceId &&
          other.folderId == folderId;

  @override
  int get hashCode => Object.hash(sourceId, folderId);
}

/// Loads exactly one level of a provider's directory hierarchy.
///
/// Cached briefly (see [_cacheBriefly]) so walking back up a tree is instant
/// instead of re-fetching a level the user just left. A sign-out still clears
/// it: the source this watches disappears, which invalidates the value.
final folderListingProvider = FutureProvider.autoDispose
    .family<MusicFolderListing, FolderBrowseRequest>((ref, request) async {
  final MusicFolderListing listing =
      await _source(ref, request.sourceId).fetchFolder(request.folderId);
  _cacheBriefly(ref);
  return listing;
});

FolderBrowsableMusicSource _source(Ref ref, String sourceId) {
  final List<FolderBrowsableMusicSource> sources =
      ref.watch(folderBrowsableSourcesProvider);
  for (final FolderBrowsableMusicSource source in sources) {
    if (source.id == sourceId) return source;
  }
  throw StateError('The selected music source is no longer connected.');
}
