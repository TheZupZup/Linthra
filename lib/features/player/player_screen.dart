import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../shared/widgets/empty_state.dart';
import '../playlists/widgets/add_to_playlist_sheet.dart';
import 'cast/cast_button.dart';
import 'cast/cast_providers.dart';
import 'player_providers.dart';
import 'player_theme.dart';
import 'sleep_timer_controller.dart';
import 'widgets/album_artwork.dart';
import 'widgets/now_playing_actions.dart';
import 'widgets/now_playing_background.dart';
import 'widgets/playback_controls.dart';
import 'widgets/sleep_timer_sheet.dart';
import 'widgets/track_metadata.dart';
import 'widgets/waveform_seek_bar.dart';

/// Full-screen now-playing view. Renders from [playbackStateProvider] and drives
/// playback through the [PlaybackController]; it never touches the audio engine,
/// Jellyfin, or the cache directly.
///
/// These two screens (this and the lyrics page) deliberately use a soft-light,
/// "music-first" theme ([PlayerTheme]) scoped locally with a `Theme` wrapper, so
/// the dark app shell is untouched: a soft lavender brand with a warm orange
/// accent reserved for playback and progress. Layout is composed from small
/// widgets (background, artwork, metadata, waveform seek, controls, actions) so
/// this file stays a thin orchestrator. Pushed above the shell via
/// AppRoutes.player.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch only the current track (id-distinct), so the ~5 Hz position ticks
    // never rebuild this whole screen. The position/status pieces watch their
    // own slice in [_LiveControls], so they stay live without dragging the heavy
    // widgets (background, artwork, theme).
    final Track? streamed = ref.watch(
      playbackStateProvider.select((s) => s.valueOrNull?.currentTrack),
    );
    final Track? track =
        streamed ?? ref.read(playbackControllerProvider).state.currentTrack;

    return Theme(
      data: PlayerTheme.light,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: PlayerPalette.background,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: NowPlayingBackground()),
              SafeArea(
                child: Column(
                  children: [
                    _Header(track: track),
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
        ),
      ),
    );
  }
}

/// Top bar: a collapse affordance, a calm "Now Playing" caption, the cast
/// button, and an overflow menu (add to playlist · sleep timer). Transparent so
/// the soft backdrop shows through.
class _Header extends StatelessWidget {
  const _Header({required this.track});

  final Track? track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
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
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          const CastButton(),
          if (track != null)
            _OverflowMenu(track: track!)
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }
}

enum _PlayerMenuAction { addToPlaylist, sleepTimer }

/// The now-playing overflow: add-to-playlist and the sleep timer, kept out of
/// the on-screen rows so the player stays uncluttered. The trigger lights up in
/// the brand colour while a sleep countdown is running.
class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bool sleepActive = ref.watch(
      sleepTimerControllerProvider.select((s) => s.isActive),
    );
    final Color muted = theme.colorScheme.onSurfaceVariant;

    return PopupMenuButton<_PlayerMenuAction>(
      tooltip: 'More',
      icon: Icon(
        Icons.more_vert,
        color: sleepActive ? theme.colorScheme.primary : null,
      ),
      onSelected: (action) {
        switch (action) {
          case _PlayerMenuAction.addToPlaylist:
            showAddToPlaylistSheet(context, <Track>[track]);
          case _PlayerMenuAction.sleepTimer:
            showSleepTimerSheet(context);
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<_PlayerMenuAction>>[
        PopupMenuItem<_PlayerMenuAction>(
          value: _PlayerMenuAction.addToPlaylist,
          child: Row(
            children: [
              Icon(Icons.playlist_add, size: 20, color: muted),
              const SizedBox(width: AppSpacing.md),
              const Text('Add to playlist'),
            ],
          ),
        ),
        PopupMenuItem<_PlayerMenuAction>(
          value: _PlayerMenuAction.sleepTimer,
          child: Row(
            children: [
              Icon(
                sleepActive ? Icons.bedtime : Icons.bedtime_outlined,
                size: 20,
                color: sleepActive ? theme.colorScheme.primary : muted,
              ),
              const SizedBox(width: AppSpacing.md),
              const Text('Sleep timer'),
            ],
          ),
        ),
      ],
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

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    // Three calm bands — artwork · metadata + controls — with generous gaps.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                // Cap the hero on tablets/foldables so it stays a square cover;
                // phones use the full width.
                constraints: const BoxConstraints(maxWidth: 460),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadii.lg),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 32,
                          spreadRadius: -10,
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
          ),
          const SizedBox(height: AppSpacing.xl),
          TrackMetadata(
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
          ),
          const SizedBox(height: AppSpacing.lg),
          // The only part that follows the live, high-frequency playback state —
          // kept separate so the artwork and metadata above never rebuild on a
          // position tick.
          const _LiveControls(),
          const SizedBox(height: AppSpacing.md),
          NowPlayingActions(track: track),
        ],
      ),
    );
  }
}

/// The source/error line, waveform seek bar, and transport controls — everything
/// that must follow position/status. Isolated into its own consumer so a
/// position tick rebuilds only this slim column, not the screen.
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
        const SizedBox(height: AppSpacing.sm),
        WaveformSeekBar(
          position: state.position,
          duration: state.duration,
          onSeek: (pos) => controller.seek(pos),
        ),
        const SizedBox(height: AppSpacing.sm),
        PlaybackControls(state: state),
      ],
    );
  }
}

/// Under the metadata: while casting, a clear `Casting to …` indicator;
/// otherwise a friendly error message when playback failed, or the
/// playback-source badge once a track has resolved. Shows nothing while a track
/// is still loading locally.
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
    // A mid-stream re-buffer: a calm "Buffering…" hint rather than the source
    // badge, so it's clear the stream is catching up (not stalled).
    if (state.status == PlaybackStatus.buffering) {
      return const _BufferingIndicator();
    }
    final source = state.source;
    if (source == null) {
      // Reserve the inline chip's height so the column doesn't shift when the
      // source resolves a beat after the track loads.
      return const SizedBox(height: 22);
    }
    return PlaybackSourceChip(
      source: source,
      trackUri: state.currentTrack?.uri,
    );
  }
}

/// A small, calm "Buffering…" hint shown during a mid-stream re-buffer.
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
          'Buffering…',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

/// A small, on-brand `Casting to …` chip shown while a cast session is
/// connected, so it's obvious the phone is a remote.
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
        Icon(Icons.cast_connected, size: 16, color: theme.colorScheme.primary),
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
