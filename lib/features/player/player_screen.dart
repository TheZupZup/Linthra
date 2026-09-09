import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../../shared/layout/adaptive_layout.dart';
import '../../shared/widgets/empty_state.dart';
import 'cast/cast_button.dart';
import 'cast/cast_providers.dart';
import 'player_providers.dart';
import 'widgets/album_artwork.dart';
import 'widgets/lyrics/lyrics_backdrop.dart';
import 'widgets/lyrics_view.dart';
import 'widgets/now_playing_actions.dart';
import 'widgets/now_playing_background.dart';
import 'widgets/playback_controls.dart';
import 'widgets/playback_progress_bar.dart';
import 'widgets/queue_sheet.dart';
import 'widgets/track_metadata.dart';
import 'widgets/volume_controls.dart';

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
            // A calm, tracked eyebrow rather than a heavy title, so the artwork
            // below is unmistakably the hero of the screen.
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

class _NowPlaying extends StatefulWidget {
  const _NowPlaying({required this.track});

  final Track track;

  @override
  State<_NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<_NowPlaying> {
  /// How wide a queue pane is drawn. Wide enough for a title, a duration and a
  /// drag handle without the title truncating on most songs.
  static const double _queuePaneWidth = 340;

  /// The narrowest the screen may be and still host the queue as a third
  /// column: the pane's own width, plus enough left over that the cover and the
  /// controls beside it are no tighter than they are at the bottom of the
  /// two-column layout.
  static const double _queuePaneMinWidth =
      expandedWindowWidth + _queuePaneWidth + AppSpacing.lg;

  /// Whether the stage is showing lyrics instead of the cover.
  ///
  /// Deliberately kept across track changes: someone reading along wants the
  /// next song's lyrics too, not the artwork back. It is a plain toggle rather
  /// than a gesture, so it can't collide with the existing swipe-to-dismiss or
  /// with dragging the seek bar.
  bool _showLyrics = false;

  /// Whether the queue is open as a pane beside the cover.
  ///
  /// Remembered even while the window is too narrow to draw it, so dragging a
  /// window down to a phone width and back finds the queue where it was left
  /// rather than closed.
  bool _showQueue = false;

  @override
  Widget build(BuildContext context) {
    return AdaptiveLayoutBuilder(
      builder: (
        BuildContext context,
        BoxConstraints constraints,
        WindowSizeClass sizeClass,
      ) {
        // Width alone decides, so the same window is laid out the same way on
        // any platform — and the side-by-side layout is the *more* forgiving of
        // the two vertically, since the cover shrinks beside the controls
        // instead of stacking on top of them.
        final bool wide = sizeClass.isAtLeast(WindowSizeClass.expanded);
        // A third column has to earn its place: at the low end of `expanded`
        // the cover and the controls are already using the width, and a queue
        // squeezed in beside them would shrink both to make room for a list
        // that is one tap away as a sheet.
        final bool canHostQueue =
            wide && constraints.maxWidth >= _queuePaneMinWidth;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          child:
              wide ? _wideLayout(canHostQueue: canHostQueue) : _stackedLayout(),
        );
      },
    );
  }

  /// Desktop-width Now Playing: the cover holds one side while metadata,
  /// transport and actions sit on the other — and lyrics open *beside* the
  /// cover instead of replacing it, which is the whole point of the extra
  /// width. Same widgets, same `_showLyrics`, same playback state as the
  /// stacked layout; only the arrangement differs.
  ///
  /// Wider still ([canHostQueue]) the queue joins them as a third column rather
  /// than as a sheet over the top, so lyrics and up-next are readable at the
  /// same time — which is the other thing the width is for. It is the same
  /// [QueueSheet] the sheet shows, so a reorder or a jump behaves identically
  /// whichever shape it is wearing.
  Widget _wideLayout({required bool canHostQueue}) {
    final Track track = widget.track;
    final bool queueOpen = canHostQueue && _showQueue;
    return Center(
      child: ConstrainedBox(
        // Ultrawide windows stop stretching the columns apart here.
        constraints: const BoxConstraints(maxWidth: maxPaneLayoutWidth),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 5,
              child: Center(child: _ArtworkHero(artworkUri: track.artworkUri)),
            ),
            const SizedBox(width: AppSpacing.xl),
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (_showLyrics) ...<Widget>[
                    const Expanded(
                      child: LyricsBackdrop(child: LyricsView()),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  TrackMetadata(
                    title: track.title,
                    artistName: track.artistName,
                    albumName: track.albumName,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  const _LiveControls(),
                  const SizedBox(height: AppSpacing.md),
                  _ActionsBar(
                    track: track,
                    lyricsVisible: _showLyrics,
                    onToggleLyrics: _toggleLyrics,
                    // Below the pane width the button keeps opening the sheet,
                    // so the queue is never unreachable at any window size.
                    queueVisible: queueOpen,
                    onToggleQueue: canHostQueue ? _toggleQueue : null,
                  ),
                ],
              ),
            ),
            if (queueOpen) ...<Widget>[
              const SizedBox(width: AppSpacing.lg),
              // A fixed width, not a flex share: the queue is a list of song
              // rows, and rows have a width that reads well. Letting it grow
              // with the window would only pull each title away from its
              // handle, and would take the space from the cover.
              const SizedBox(
                width: _queuePaneWidth,
                child: QueueSheet(embedded: true),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _toggleLyrics() => setState(() => _showLyrics = !_showLyrics);

  void _toggleQueue() => setState(() => _showQueue = !_showQueue);

  /// Phones, and any window without the width (or height) for two columns.
  ///
  /// A tighter side margin lets the artwork breathe wider and gives the
  /// transport controls more room to spread, while the generous gaps below
  /// group the screen into three calm bands: stage · metadata · controls.
  Widget _stackedLayout() {
    final Track track = widget.track;
    return Column(
      children: [
        Expanded(child: _Stage(track: track, showLyrics: _showLyrics)),
        // Lyrics need the height more than the gap does; the artwork keeps
        // its generous breathing room.
        SizedBox(height: _showLyrics ? AppSpacing.md : AppSpacing.xl),
        // In lyrics mode the three-line metadata block collapses to a single
        // quiet line, handing the difference to the lyrics above without
        // losing track of what is playing.
        if (_showLyrics)
          _CompactTrackLine(
            title: track.title,
            artistName: track.artistName,
          )
        else
          TrackMetadata(
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
          ),
        SizedBox(height: _showLyrics ? AppSpacing.md : AppSpacing.lg),
        // The only part of the screen that follows the live, high-frequency
        // playback state — kept separate so the stage, metadata, and the
        // blurred background above never rebuild on a position tick. It stays
        // exactly where it is in both modes, so play/pause, skip, and seek are
        // never further away for reading lyrics.
        const _LiveControls(),
        const SizedBox(height: AppSpacing.md),
        _ActionsBar(
          track: track,
          lyricsVisible: _showLyrics,
          onToggleLyrics: _toggleLyrics,
        ),
      ],
    );
  }
}

/// The action row, plus the desktop volume control beside it.
///
/// They share one band on purpose: volume is a secondary control here (the
/// transport above it is what the screen is for), and giving it a row of its own
/// would take height from the artwork and the lyrics — which a short window at a
/// large text scale does not have to spare.
///
/// The control is desktop-only: a phone's volume is the system's, set with its
/// hardware keys, so mobile keeps exactly the row it had. It also steps aside
/// while casting, where the level that matters belongs to the receiver and the
/// cast sheet already owns it, and on a desktop window too narrow to hold both
/// it and the five actions — a slider squeezing the queue button off the edge
/// is worse than no slider.
class _ActionsBar extends ConsumerWidget {
  /// The narrowest band that holds the five actions and the volume control
  /// without squeezing either. Measured against the band itself, not the
  /// window: in the two-column layout this row lives in the narrower half.
  static const double _volumeBandMinWidth = 460;

  const _ActionsBar({
    required this.track,
    required this.lyricsVisible,
    required this.onToggleLyrics,
    this.queueVisible = false,
    this.onToggleQueue,
  });

  final Track track;
  final bool lyricsVisible;
  final VoidCallback onToggleLyrics;

  /// Whether the screen is hosting the queue as a pane, and how to toggle it.
  /// Null on the layouts that have no room for one, which leaves the queue
  /// button opening its sheet.
  final bool queueVisible;
  final VoidCallback? onToggleQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget actions = NowPlayingActions(
      track: track,
      lyricsVisible: lyricsVisible,
      onToggleLyrics: onToggleLyrics,
      queueVisible: queueVisible,
      onToggleQueue: onToggleQueue,
    );
    // Falls back to the service's own state until the first stream event, the
    // same way the source/casting line does.
    final bool casting = ref.watch(
          castStateProvider.select((s) => s.valueOrNull?.isConnected),
        ) ??
        ref.watch(castServiceProvider).state.isConnected;
    if (casting || !ref.watch(hostPlatformProvider).isDesktop) return actions;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < _volumeBandMinWidth) return actions;
        return Row(
          children: <Widget>[
            Expanded(child: actions),
            const VolumeControls(),
          ],
        );
      },
    );
  }
}

/// The hero area of Now Playing: the album cover, or the lyrics in its place.
///
/// Both fill the same box, so switching modes moves nothing below it. The
/// crossfade is a single one-shot transition — the only motion here — and is
/// skipped outright under reduced motion.
class _Stage extends StatelessWidget {
  const _Stage({required this.track, required this.showLyrics});

  final Track track;
  final bool showLyrics;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      child: showLyrics
          // SizedBox.expand so the lyrics panel takes the whole stage rather
          // than sizing itself to its (unbounded) scrolling content.
          ? const SizedBox.expand(
              key: ValueKey<String>('lyrics-stage'),
              child: LyricsBackdrop(child: LyricsView()),
            )
          : SizedBox.expand(
              key: const ValueKey<String>('artwork-stage'),
              child: _ArtworkHero(artworkUri: track.artworkUri),
            ),
    );
  }
}

/// The album cover, capped and lifted off the backdrop by a soft shadow.
class _ArtworkHero extends StatelessWidget {
  const _ArtworkHero({required this.artworkUri});

  final Uri? artworkUri;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        // Cap the hero on tablets/foldables so it stays a square cover, not an
        // oversized panel; phones use the full width.
        constraints: const BoxConstraints(maxWidth: 480),
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.lg),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 40,
                  spreadRadius: -12,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: AlbumArtwork(
              artworkUri: artworkUri,
              borderRadius: BorderRadius.circular(AppRadii.lg),
            ),
          ),
        ),
      ),
    );
  }
}

/// Title and artist on one quiet line, shown in place of the full metadata
/// block while the lyrics have the stage.
class _CompactTrackLine extends StatelessWidget {
  const _CompactTrackLine({required this.title, this.artistName});

  final String title;
  final String? artistName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? artist = artistName;
    final bool hasArtist = artist != null && artist.isNotEmpty;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasArtist) ...[
          Text(
            ' · ',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          Flexible(
            child: Text(
              artist,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
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
        _StatusSlot(child: _SourceOrError(state: state)),
        const SizedBox(height: AppSpacing.md),
        PlaybackProgressBar(
          // Identity is the track, so a track change disposes the bar's state
          // — including a seek it is still holding optimistically — rather than
          // carrying it onto the new song. Duration alone can't do that: two
          // tracks can be exactly as long as each other. The uri is what Track
          // itself calls identity (see its == ): bare ids collide across
          // providers, the provider-namespaced uri does not.
          key: ValueKey<String?>(state.currentTrack?.uri),
          position: state.position,
          duration: state.duration,
          // Drives the wave's slow drift: it flows while playing and holds
          // still when paused, so a paused screen schedules no frames.
          playing: state.isPlaying,
          onSeek: (position) =>
              ref.read(playbackControllerProvider).seek(position),
        ),
        const SizedBox(height: AppSpacing.sm),
        PlaybackControls(state: state),
      ],
    );
  }
}

/// A stable status area that still grows enough for the user's text scale.
/// Every source/buffering/casting/error state uses the same computed height, so
/// switching states cannot move the artwork or metadata above the controls.
class _StatusSlot extends StatelessWidget {
  const _StatusSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labelStyle = theme.textTheme.labelLarge;
    final bodyStyle = theme.textTheme.bodyMedium;
    final labelFontSize = labelStyle?.fontSize ?? 14.0;
    final bodyFontSize = bodyStyle?.fontSize ?? 14.0;
    final labelLineHeight = labelStyle?.height ?? 1.2;
    final bodyLineHeight = bodyStyle?.height ?? 1.2;
    final labelHeight = scaler.scale(labelFontSize) * labelLineHeight;
    final bodyHeight = scaler.scale(bodyFontSize) * bodyLineHeight;
    final textHeight = labelHeight > bodyHeight ? labelHeight : bodyHeight;
    final preferredHeight = textHeight + AppSpacing.xs;
    final slotHeight = preferredHeight > 24 ? preferredHeight : 24.0;

    return SizedBox(
      key: const ValueKey('player-status-slot'),
      height: slotHeight,
      child: Center(child: child),
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
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              state.errorMessage ?? "Couldn't play this track",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (state.currentTrack != null) ...[
            const SizedBox(width: AppSpacing.xs),
            TextButton(
              onPressed: () =>
                  unawaited(ref.read(playbackControllerProvider).play()),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Retry',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        ],
      );
    }
    // A mid-stream network reconnect: distinct from plain "Buffering…" and from
    // a permanent error + Retry, so the listener knows recovery is in flight.
    if (state.status == PlaybackStatus.reconnecting) {
      return const _ReconnectingIndicator();
    }
    // A mid-stream re-buffer: a calm "Buffering…" hint rather than the source
    // badge, so it's clear the stream is catching up (not stalled).
    if (state.status == PlaybackStatus.buffering) {
      return const _BufferingIndicator();
    }
    final source = state.source;
    if (source == null) {
      return const SizedBox.shrink();
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
    return const _BusyStatusIndicator(label: 'Buffering…');
  }
}

/// Shown while a bounded mid-stream network recovery re-resolves a fresh URL.
/// Deliberately distinct from [_BufferingIndicator] and from the permanent
/// error + Retry row.
class _ReconnectingIndicator extends StatelessWidget {
  const _ReconnectingIndicator();

  @override
  Widget build(BuildContext context) {
    return const _BusyStatusIndicator(label: 'Reconnecting…');
  }
}

class _BusyStatusIndicator extends StatelessWidget {
  const _BusyStatusIndicator({required this.label});

  final String label;

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
          label,
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
