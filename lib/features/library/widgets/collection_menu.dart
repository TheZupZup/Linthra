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
/// [PlaybackController.playTracks], `playNextAll`, `addAllToQueue`, and the
/// shared add-to-playlist sheet with its duplicate and source safeguards, so
/// the menu carries no logic of its own to drift.
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
    ...queueMenuItems(),
    _item(
        CollectionAction.addToPlaylist, Icons.playlist_add, 'Add to playlist'),
  ];
}

/// Just the two entries that *extend* a queue rather than replace it.
///
/// For surfaces that already show Play and Shuffle as their own controls (the
/// album page's header buttons), so the menu beside them offers what is missing
/// instead of repeating what is already a tap away. Same values, same commands
/// behind [runCollectionAction], so a menu built from these behaves exactly
/// like the same entries in [collectionMenuItems].
List<PopupMenuEntry<CollectionAction>> queueMenuItems() {
  return <PopupMenuEntry<CollectionAction>>[
    _item(CollectionAction.playNext, Icons.queue_music, 'Play next'),
    _item(CollectionAction.addToQueue, Icons.add_to_queue, 'Add to queue'),
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
      // One insert for the whole set, in the order it was handed over: it lands
      // after the current track and keeps everything already upcoming behind
      // it. From silence the set becomes the queue and starts from its first
      // track, which is what "play this next" means with nothing playing.
      controller.playNextAll(tracks);
    case CollectionAction.addToQueue:
      controller.addAllToQueue(tracks);
    case CollectionAction.addToPlaylist:
      await showAddToPlaylistSheet(context, tracks);
  }
}
