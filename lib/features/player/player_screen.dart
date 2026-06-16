import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import '../../ui_linthra/design_tokens.dart';
import '../../ui_linthra/now_playing_layout_config.dart';
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
    // Watch only the current track (id-distinct), so the ~5 Hz position ticks
    // never rebuild this whole screen — above all the full-screen *blurred*
    // artwork background, which is expensive to re-paint and was rebuilding on
    // every tick. The position/status pieces watch their own slice in
    // [_LiveControls], so they stay live without dragging the heavy widgets.
    final Track? streamed = ref.watch(
      playbackStateProvider.select((s) => s.valueOrNull?.currentTrack),
    );
    final Track? track =
        streamed ?? ref.read(playbackControllerProvider).state.currentTrack;

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
                      : _NowPlaying(track: track),
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
      padding: NowPlayingLayout.headerPadding,
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(NowPlayingLabels.closeIcon),
            tooltip: NowPlayingLabels.closeTooltip,
          ),
          Expanded(
            // A calm, tracked eyebrow rather than a heavy title, so the artwork
            // below is unmistakably the hero of the screen.
            child: Text(
              NowPlayingLabels.header,
              textAlign: TextAlign.center,
              style: NowPlayingTextStyles.header(theme),
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
      icon: NowPlayingLabels.emptyIcon,
      title: NowPlayingLabels.emptyTitle,
      message: NowPlayingLabels.emptyMessage,
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    // A tighter side margin lets the artwork breathe wider and gives the
    // transport controls more room to spread, while the generous gaps below
    // group the screen into three calm bands: artwork · metadata · controls.
    // All of these numbers live in lib/ui_linthra/ so they can be retuned there.
    final BorderRadius artworkRadius =
        BorderRadius.circular(NowPlayingArtworkTokens.cornerRadius);
    return Padding(
      padding: NowPlayingLayout.contentPadding,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                // Cap the hero on tablets/foldables so it stays a square cover,
                // not an oversized panel; phones use the full width.
                constraints: const BoxConstraints(
                  maxWidth: NowPlayingArtworkTokens.maxWidth,
                ),
                child: AspectRatio(
                  aspectRatio: NowPlayingArtworkTokens.aspectRatio,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: artworkRadius,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: NowPlayingArtworkTokens.shadowOpacity,
                          ),
                          blurRadius: NowPlayingArtworkTokens.shadowBlur,
                          spreadRadius: NowPlayingArtworkTokens.shadowSpread,
                          offset: NowPlayingArtworkTokens.shadowOffset,
                        ),
                      ],
                    ),
                    child: AlbumArtwork(
                      artworkUri: track.artworkUri,
                      borderRadius: artworkRadius,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: NowPlayingLayout.gapArtworkToMetadata),
          TrackMetadata(
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
          ),
          const SizedBox(height: NowPlayingLayout.gapMetadataToControls),
          // The only part of the screen that follows the live, high-frequency
          // playback state — kept separate so the artwork, metadata, and the
          // blurred background above never rebuild on a position tick.
          const _LiveControls(),
          const SizedBox(height: NowPlayingLayout.gapControlsToActions),
          NowPlayingActions(track: track),
        ],
      ),
    );
  }
}

/// The source/error line, seekable progress bar, and transport controls —
/// everything that must follow position/status. Isolated into its own consumer
/// so a position tick rebuilds only this slim column, not the screen.
class _LiveControls extends ConsumerWidget {
  const _LiveControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final PlaybackState state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SourceOrError(state: state),
        const SizedBox(height: NowPlayingLayout.gapSourceToProgress),
        PlaybackProgressBar(
          position: state.position,
          duration: state.duration,
          onSeek: (position) =>
              ref.read(playbackControllerProvider).seek(position),
        ),
        const SizedBox(height: NowPlayingLayout.gapProgressToTransport),
        PlaybackControls(state: state),
      ],
    );
  }
}

/// Under the metadata: while casting, a clear `Casting to …` indicator;
/// otherwise a friendly error message when playback failed, or the
/// playback-source badge ("Playing from Navidrome / Jellyfin / Local music /
/// Cache") once a track has resolved — naming the copy actually playing, not the
/// active/default provider. Shows nothing while a track is still loading locally.
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
        state.errorMessage ?? NowPlayingLabels.genericError,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.error,
        ),
        textAlign: TextAlign.center,
      );
    }
    // A mid-stream re-buffer: a calm "Buffering…" hint rather than the source
    // badge, so it's clear the stream is catching up (not stalled).
    if (state.status == PlaybackStatus.buffering) {
      return const _BufferingIndicator();
    }
    final source = state.source;
    if (source == null) {
      // Reserve the inline chip's height so the column doesn't shift when the
      // source resolves a beat after the track loads.
      return const SizedBox(
        height: NowPlayingProgressTokens.sourceLineReservedHeight,
      );
    }
    return PlaybackSourceChip(
      source: source,
      trackUri: state.currentTrack?.uri,
    );
  }
}

/// A small, calm "Buffering…" hint shown on Now Playing during a mid-stream
/// re-buffer, so the screen reads as catching-up rather than frozen.
class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          NowPlayingLabels.buffering,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
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
          NowPlayingLabels.castingIcon,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            NowPlayingLabels.casting(deviceName),
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
