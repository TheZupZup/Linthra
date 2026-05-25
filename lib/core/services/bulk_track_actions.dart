import '../models/track.dart';
import '../sources/music_provider.dart';

/// Which bulk actions are safe to offer for a given multi-track selection.
///
/// This is the single, pure place the "what can I safely do to these songs?"
/// rules live, so the selection UI can show exactly the safe actions and the
/// rules are trivially unit-testable. The destructive actions follow the safety
/// principle that "remove from Linthra" and "delete from source" are different:
/// a destructive *delete* is only offered when *every* selected track supports
/// it (and, for a server delete, they are all the same provider), so a
/// mixed-source selection automatically hides any unsafe delete.
class BulkActionAvailability {
  const BulkActionAvailability({
    required this.canAddToPlaylist,
    required this.canRemoveFromLibrary,
    required this.canRemoveOfflineCopy,
    required this.canRemoveFromPlaylist,
    required this.canDeleteLocalFiles,
    required this.canDeleteFromServer,
  });

  static const BulkActionAvailability none = BulkActionAvailability(
    canAddToPlaylist: false,
    canRemoveFromLibrary: false,
    canRemoveOfflineCopy: false,
    canRemoveFromPlaylist: false,
    canDeleteLocalFiles: false,
    canDeleteFromServer: false,
  );

  /// Add the selection to a playlist. Always available for a non-empty
  /// selection regardless of source.
  final bool canAddToPlaylist;

  /// Remove the selection from Linthra's library/index (safe, reversible).
  final bool canRemoveFromLibrary;

  /// Remove app-managed offline copies for the selection (at least one selected
  /// track's provider supports a managed offline copy).
  final bool canRemoveOfflineCopy;

  /// Remove the selection from the current playlist (only inside a playlist).
  final bool canRemoveFromPlaylist;

  /// Delete the underlying device files (every selected track supports it).
  final bool canDeleteLocalFiles;

  /// Delete the underlying server items (every selected track is the same
  /// provider and that provider supports a safe server delete).
  final bool canDeleteFromServer;
}

/// Computes the safe bulk actions for [tracks]. Pass [inPlaylist] when the
/// selection is shown inside a playlist (so "remove from playlist" applies).
BulkActionAvailability bulkActionsFor(
  List<Track> tracks, {
  required bool inPlaylist,
}) {
  if (tracks.isEmpty) return BulkActionAvailability.none;

  final List<MusicProviderCapabilities> caps = <MusicProviderCapabilities>[
    for (final Track track in tracks)
      MusicProviders.capabilitiesForTrackUri(track.uri),
  ];

  final Set<String> providerIds = <String>{
    for (final Track track in tracks)
      MusicProviders.forTrackUri(track.uri).sourceId,
  };
  final bool allSameProvider = providerIds.length == 1;

  return BulkActionAvailability(
    canAddToPlaylist: true,
    canRemoveFromLibrary:
        caps.every((MusicProviderCapabilities c) => c.canRemoveFromLibrary),
    canRemoveOfflineCopy:
        caps.any((MusicProviderCapabilities c) => c.canRemoveOfflineCopy),
    canRemoveFromPlaylist: inPlaylist,
    canDeleteLocalFiles:
        caps.every((MusicProviderCapabilities c) => c.canDeleteLocalFile),
    canDeleteFromServer: allSameProvider &&
        caps.every((MusicProviderCapabilities c) => c.canDeleteRemoteItem),
  );
}
