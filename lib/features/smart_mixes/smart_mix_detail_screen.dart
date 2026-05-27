import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/smart_playlist.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import '../library/widgets/track_tile.dart';
import '../player/player_providers.dart';
import 'smart_mix_providers.dart';

/// One smart mix's tracks, with Play / Shuffle and tap-to-play.
///
/// Read-only by design: a smart mix is derived from on-device signals, not a
/// hand-curated list, so there's no reorder/rename/delete — reopening it simply
/// reflects the latest data. Reuses [TrackTile], so per-track actions and
/// download state look identical to the rest of the library.
class SmartMixDetailScreen extends ConsumerWidget {
  const SmartMixDetailScreen({required this.kindId, super.key});

  /// The routing id of the mix (`SmartPlaylistKind.id`).
  final String kindId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SmartPlaylistKind? kind = SmartPlaylistKind.fromId(kindId);
    if (kind == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.auto_awesome_outlined,
          title: 'Mix not found',
          message: 'This smart mix is no longer available.',
        ),
      );
    }

    final SmartPlaylist mix = SmartPlaylist.forKind(kind);
    final AsyncValue<List<Track>> tracksAsync =
        ref.watch(smartPlaylistTracksProvider(kind));

    return Scaffold(
      appBar: AppBar(
        title: Text(mix.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: tracksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const EmptyState(
          icon: Icons.error_outline,
          title: "Couldn't build this mix",
          message: 'Try again in a moment.',
        ),
        data: (List<Track> tracks) => _content(context, ref, mix, tracks),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    WidgetRef ref,
    SmartPlaylist mix,
    List<Track> tracks,
  ) {
    if (tracks.isEmpty) {
      return EmptyState(
        icon: Icons.auto_awesome_outlined,
        title: 'Nothing here yet',
        message: _emptyMessage(mix.kind),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Header(
          onPlay: () => _play(context, ref, tracks),
          onShuffle: () => _shuffle(context, ref, tracks),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: tracks.length,
            itemBuilder: (context, index) =>
                TrackTile(tracks: tracks, index: index),
          ),
        ),
      ],
    );
  }

  void _play(BuildContext context, WidgetRef ref, List<Track> tracks) {
    if (tracks.isEmpty) return;
    ref.read(playbackControllerProvider).playTracks(tracks);
    context.push(AppRoutes.player);
  }

  void _shuffle(BuildContext context, WidgetRef ref, List<Track> tracks) {
    if (tracks.isEmpty) return;
    final controller = ref.read(playbackControllerProvider);
    controller.setShuffleEnabled(true);
    controller.playTracks(tracks);
    context.push(AppRoutes.player);
  }

  /// A friendly, mix-specific hint for an empty mix, so the screen explains
  /// *why* it's empty rather than just looking broken.
  static String _emptyMessage(SmartPlaylistKind kind) {
    switch (kind) {
      case SmartPlaylistKind.recentlyAdded:
        return 'Add a music folder or sync a server to fill your library.';
      case SmartPlaylistKind.recentlyPlayed:
        return 'Play some music and it’ll show up here.';
      case SmartPlaylistKind.mostPlayed:
        return 'Your most-played tracks appear here as you listen.';
      case SmartPlaylistKind.favorites:
        return 'Tap the heart on a track to add it here.';
      case SmartPlaylistKind.downloaded:
        return 'Download tracks for offline and they’ll appear here.';
      case SmartPlaylistKind.random:
        return 'Add some music and Linthra will shuffle up a mix.';
      case SmartPlaylistKind.neverPlayed:
        return 'Once you’ve heard everything, this mix will be empty.';
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onPlay, required this.onShuffle});

  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: <Widget>[
          Expanded(
            child: FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: onShuffle,
              icon: const Icon(Icons.shuffle),
              label: const Text('Shuffle'),
            ),
          ),
        ],
      ),
    );
  }
}
