import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/track.dart';
import '../../data/repositories/download_repository_provider.dart';
import '../../data/repositories/music_library_repository_provider.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../player/player_providers.dart';
import '../playlists/playlist_providers.dart';
import 'library_controller.dart';
import 'unified_library_providers.dart';

/// The shared, safe song remove/delete actions used by the Library and playlist
/// screens. Centralized so the confirmation wording, the currently-playing
/// guard, and the success/failure summaries stay identical everywhere.
///
/// The two enabled actions are the safe, reversible ones the spec prefers:
///  - "Remove from Linthra library" — forgets the catalog rows only; the
///    original file / server item is untouched (a re-scan can bring it back).
///  - "Remove offline copy" — deletes only Linthra's app-managed cached file;
///    the source remains streamable.
///
/// Deleting the real device file or the server item is intentionally not wired
/// here (see the provider capability model and docs/playlists-and-delete.md).
abstract final class SongActions {
  /// Confirms (count-aware) and removes [tracks] from Linthra's library index,
  /// then refreshes the views. Returns whether the removal ran (false on
  /// cancel). Never deletes a file or a server item.
  static Future<bool> removeFromLibrary(
    BuildContext context,
    WidgetRef ref,
    List<Track> tracks, {
    String? playlistId,
    bool expandLogicalSources = false,
  }) async {
    if (tracks.isEmpty) return false;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Remove from Linthra',
      message: tracks.length == 1
          ? 'Remove “${tracks.first.title}” from Linthra? This will not delete '
              'the original file or server item.'
          : 'Remove ${tracks.length} songs from Linthra? This will not delete '
              'the original files or server items.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return false;

    await ref
        .read(musicLibraryRepositoryProvider)
        .removeTracks(_removalIds(ref, tracks, expandLogicalSources));
    // Refresh the library view; if we're inside a playlist, re-resolve its
    // tracks so a now-removed item is reflected.
    await ref.read(libraryControllerProvider.notifier).refresh();
    if (playlistId != null) {
      ref.invalidate(playlistTracksProvider(playlistId));
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          tracks.length == 1
              ? 'Removed “${tracks.first.title}” from Linthra.'
              : 'Removed ${tracks.length} songs from Linthra.',
        ),
      ),
    );
    return true;
  }

  /// Confirms (count-aware) and removes app-managed offline copies for [tracks].
  /// The currently-playing track is skipped (its cached file must not be deleted
  /// out from under playback) and reported in the summary. Returns whether the
  /// action ran (false on cancel).
  static Future<bool> removeOfflineCopies(
    BuildContext context,
    WidgetRef ref,
    List<Track> tracks,
  ) async {
    if (tracks.isEmpty) return false;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Remove offline copy',
      message: tracks.length == 1
          ? 'Remove offline copy of “${tracks.first.title}”? You can still '
              'stream it if your server is available.'
          : 'Remove offline copies for ${tracks.length} songs?',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return false;

    final String? playingId =
        ref.read(playbackControllerProvider).state.currentTrack?.id;
    final repository = ref.read(downloadRepositoryProvider);
    int removed = 0;
    int failed = 0;
    int skipped = 0;
    for (final Track track in tracks) {
      // Never delete the cached file backing what's playing right now.
      if (track.id == playingId) {
        skipped++;
        continue;
      }
      try {
        await repository.removeDownload(track);
        removed++;
      } catch (_) {
        failed++;
      }
    }

    messenger.showSnackBar(
      SnackBar(content: Text(_offlineSummary(removed, failed, skipped))),
    );
    return true;
  }

  /// The track uris to forget for [tracks] (the catalog is keyed by [Track.uri]).
  /// When [expandLogicalSources] is set (library/album/artist surfaces, where
  /// each row is a logical track), a row's uri is expanded to every provider
  /// copy's uri via [logicalSourceIdsProvider] so removing the row can't leave a
  /// hidden duplicate behind. Elsewhere (a playlist's specific tracks) the uris
  /// are taken verbatim.
  static List<String> _removalIds(
    WidgetRef ref,
    List<Track> tracks,
    bool expandLogicalSources,
  ) {
    if (!expandLogicalSources) {
      return <String>[for (final Track track in tracks) track.uri];
    }
    final Map<String, List<String>> bySource =
        ref.read(logicalSourceIdsProvider);
    final List<String> uris = <String>[];
    for (final Track track in tracks) {
      uris.addAll(bySource[track.uri] ?? <String>[track.uri]);
    }
    return uris;
  }

  static String _offlineSummary(int removed, int failed, int skipped) {
    final StringBuffer buffer = StringBuffer()
      ..write(
        removed == 1
            ? 'Removed offline copy for 1 song.'
            : 'Removed offline copies for $removed songs.',
      );
    if (failed > 0) buffer.write(' $failed failed.');
    if (skipped > 0) buffer.write(' $skipped skipped (currently playing).');
    return buffer.toString();
  }
}
