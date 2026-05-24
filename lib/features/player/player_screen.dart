import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import 'cast/cast_button.dart';
import 'cast/cast_providers.dart';
import 'player_providers.dart';
import 'widgets/album_artwork.dart';
import 'widgets/now_playing_actions.dart';
import 'widgets/now_playing_background.dart';
import 'widgets/playback_controls.dart';
import 'widgets/playback_progress_bar.dart';
import 'widgets/track_metadata.dart';

/// Full-screen now-playing view. Renders from [playbackStateProvider] and drives
/// playback through the [PlaybackController]; it never touches the audio engine,
/// Jellyfin, or the cache directly. Layout is composed from small widgets
/// (background, artwork, metadata, progress, controls, actions) so this file
/// stays a thin orchestrator. Pushed above the shell via AppRoutes.player.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;
    final Track? track = state.currentTrack;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: NowPlayingBackground(artworkUri: track?.artworkUri),
          ),
          SafeArea(
            child: Column(
              children: [
                const _Header(),
                Expanded(
                  child: track == null
                      ? const _EmptyNowPlaying()
                      : _NowPlaying(state: state, track: track),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Top bar: a collapse affordance, a calm "Now Playing" caption, and the cast
/// button. Transparent so the blurred artwork shows through.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: 'Close',
          ),
          Expanded(
            child: Text(
              'Now Playing',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          // Trailing cast control; ~48dp wide, balancing the leading button so
          // the title stays centered.
          const CastButton(),
        ],
      ),
    );
  }
}

class _EmptyNowPlaying extends StatelessWidget {
  const _EmptyNowPlaying();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.music_note_outlined,
      title: 'Nothing playing',
      message: 'Pick a track to start listening.',
    );
  }
}

class _NowPlaying extends ConsumerWidget {
  const _NowPlaying({required this.state, required this.track});

  final PlaybackState state;
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 32,
                        spreadRadius: -8,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  child: AlbumArtwork(
                    artworkUri: track.artworkUri,
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          TrackMetadata(
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
          ),
          const SizedBox(height: AppSpacing.md),
          _SourceOrError(state: state),
          const SizedBox(height: AppSpacing.sm),
          PlaybackProgressBar(
            position: state.position,
            duration: state.duration,
            onSeek: (position) =>
                ref.read(playbackControllerProvider).seek(position),
          ),
          const SizedBox(height: AppSpacing.xs),
          PlaybackControls(state: state),
          const SizedBox(height: AppSpacing.sm),
          NowPlayingActions(track: track),
        ],
      ),
    );
  }
}

/// Under the metadata: while casting, a clear `Casting to …` indicator;
/// otherwise a friendly error message when playback failed, or the
/// playback-source badge (LOCAL FILE / STREAMING DIRECT / OFFLINE CACHE) once a
/// track has resolved. Shows nothing while a track is still loading locally.
class _SourceOrError extends ConsumerWidget {
  const _SourceOrError({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // While casting, the source badge would be misleading (the receiver, not
    // this device, is playing); show where the audio is going instead.
    final castState = ref.watch(
      castStateProvider.select((s) => s.valueOrNull),
    );
    final service = ref.watch(castServiceProvider);
    final cast = castState ?? service.state;
    if (cast.isConnected && cast.connectedDevice != null) {
      return _CastingIndicator(deviceName: cast.connectedDevice!.name);
    }

    if (state.status == PlaybackStatus.error) {
      return Text(
        state.errorMessage ?? "Couldn't play this track",
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
        textAlign: TextAlign.center,
      );
    }
    final source = state.source;
    if (source == null) {
      return const SizedBox(height: 28);
    }
    return PlaybackSourceChip(source: source);
  }
}

/// A small, on-brand `Casting to …` chip shown on Now Playing while a cast
/// session is connected, so it's obvious the phone is a remote.
class _CastingIndicator extends StatelessWidget {
  const _CastingIndicator({required this.deviceName});

  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cast_connected,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            'Casting to $deviceName',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}
