import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../../core/models/track.dart';
import '../../player/player_providers.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';

/// What a right-click offers on something that *is* a set of songs: an album,
/// an artist, a playlist (#386).
///
/// Deliberately only what the domain layer already does. Every entry maps onto
/// a command the detail screens have used since before this menu existed —
/// [PlaybackController.playTracks], `playNext`, `addToQueue`, and the shared
/// add-to-playlist sheet with its duplicate and source safeguards — so the menu
/// carries no logic of its own to drift.
enum CollectionAction {
  play,
  shuffle,
  playNext,
  addToQueue,
  addToPlaylist,
}

/// The entries, in the order a listener reaches for them.
List<PopupMenuEntry<CollectionAction>> collectionMenuItems() {
  return <PopupMenuEntry<CollectionAction>>[
    _item(CollectionAction.play, Icons.play_arrow, 'Play'),
    _item(CollectionAction.shuffle, Icons.shuffle, 'Shuffle'),
    const PopupMenuDivider(),
    _item(CollectionAction.playNext, Icons.queue_music, 'Play next'),
    _item(CollectionAction.addToQueue, Icons.add_to_queue, 'Add to queue'),
    _item(
        CollectionAction.addToPlaylist, Icons.playlist_add, 'Add to playlist'),
  ];
}

PopupMenuItem<CollectionAction> _item(
  CollectionAction action,
  IconData icon,
  String label,
) {
  return PopupMenuItem<CollectionAction>(
    value: action,
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
    ),
  );
}

/// Runs [action] against [tracks].
///
/// [tracks] is read at the moment the action is chosen, not when the menu was
/// built, so a catalog that changed while the menu was open cannot act on a
/// stale list. An empty set does nothing rather than starting silence.
Future<void> runCollectionAction(
  BuildContext context,
  WidgetRef ref,
  CollectionAction action,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return;
  final controller = ref.read(playbackControllerProvider);
  switch (action) {
    case CollectionAction.play:
      unawaited(controller.playTracks(tracks));
      unawaited(context.push(AppRoutes.player));
    case CollectionAction.shuffle:
      controller.setShuffleEnabled(true);
      unawaited(controller.playTracks(tracks));
      unawaited(context.push(AppRoutes.player));
    case CollectionAction.playNext:
      if (controller.state.currentTrack == null) {
        // Nothing is playing, so there is no "next" to insert before. The
        // shared command starts the first track it is handed and queues the
        // rest behind it, which is what "play this next" means from silence.
        for (final Track track in tracks) {
          controller.addToQueue(track);
        }
      } else {
        // Each insert lands directly after the current track, so an album
        // queued front-to-back would play backwards. Reversing is the one
        // thing a set knows that a single track does not.
        for (final Track track in tracks.reversed) {
          controller.playNext(track);
        }
      }
    case CollectionAction.addToQueue:
      for (final Track track in tracks) {
        controller.addToQueue(track);
      }
    case CollectionAction.addToPlaylist:
      await showAddToPlaylistSheet(context, tracks);
  }
}
