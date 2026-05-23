import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import 'player_providers.dart';

/// Full-screen now-playing view. Renders from [playbackStateProvider] and
/// drives playback through the [PlaybackController]; it never touches the audio
/// engine directly. Pushed above the shell via AppRoutes.player.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;

    return Scaffold(
      appBar: AppBar(title: const Text('Now Playing')),
      body: state.hasTrack ? _NowPlaying(state: state) : const _Nothing(),
    );
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.music_note_outlined,
      title: 'Nothing playing',
      message: 'Pick a track to start listening.',
    );
  }
}

/// Lays out the now-playing block above an optional "Up next" section. The
/// centered track info stays vertically centered when the queue is empty, and
/// shares the screen with the queue list when there are upcoming tracks.
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: _TrackInfo(state: state),
            ),
          ),
        ),
        if (state.hasNext) Expanded(child: _UpNext(tracks: state.upNext)),
      ],
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = state.currentTrack!;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.music_note, size: 96, color: theme.colorScheme.primary),
        const SizedBox(height: AppSpacing.xl),
        Text(
          track.title,
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (track.artistName != null && track.artistName!.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            track.artistName!,
            style: theme.textTheme.titleMedium?.copyWith(color: muted),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          _statusLabel(state.status),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _Controls(state: state),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playbackControllerProvider);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton.filled(
          iconSize: 48,
          onPressed: state.isPlaying ? controller.pause : controller.play,
          icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: state.isPlaying ? 'Pause' : 'Play',
        ),
        const SizedBox(width: AppSpacing.lg),
        IconButton.filledTonal(
          iconSize: 48,
          onPressed: state.hasNext ? controller.skipToNext : null,
          icon: const Icon(Icons.skip_next),
          tooltip: 'Next',
        ),
        const SizedBox(width: AppSpacing.lg),
        IconButton.filledTonal(
          iconSize: 48,
          onPressed: controller.stop,
          icon: const Icon(Icons.stop),
          tooltip: 'Stop',
        ),
      ],
    );
  }
}

/// The "Up next" section: a header with a Clear action and the upcoming tracks
/// in play order. Only built when the queue has upcoming tracks.
class _UpNext extends ConsumerWidget {
  const _UpNext({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(playbackControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Text('Up next', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton(
                onPressed: controller.clearQueue,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) => _UpNextTile(track: tracks[index]),
          ),
        ),
      ],
    );
  }
}

class _UpNextTile extends StatelessWidget {
  const _UpNextTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final artist = track.artistName;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.queue_music_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: artist == null || artist.isEmpty
          ? null
          : Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

String _statusLabel(PlaybackStatus status) {
  switch (status) {
    case PlaybackStatus.idle:
      return 'Stopped';
    case PlaybackStatus.loading:
      return 'Loading…';
    case PlaybackStatus.playing:
      return 'Playing';
    case PlaybackStatus.paused:
      return 'Paused';
    case PlaybackStatus.completed:
      return 'Finished';
    case PlaybackStatus.error:
      return "Couldn't play this track";
  }
}
