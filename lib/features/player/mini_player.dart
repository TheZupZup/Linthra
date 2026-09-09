import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/playback_source.dart';
import '../../core/models/playback_state.dart';
import '../../core/models/track.dart';
import '../../core/services/playback_source_label.dart';
import '../../data/repositories/favorites_repository_provider.dart';
import '../../data/repositories/host_platform_provider.dart';
import '../../shared/widgets/wavy_progress_indicator.dart';
import 'cast/cast_providers.dart';
import 'favorites_providers.dart';
import 'player_providers.dart';
import 'widgets/album_artwork.dart';
import 'widgets/playback_progress_bar.dart';
import 'widgets/queue_sheet.dart';
import 'widgets/volume_controls.dart';
import 'widgets/wavy_seek_bar.dart';

/// A compact, persistent now-playing bar shown above the bottom navigation on
/// every main screen (Library / Folders / Playlists / Downloads / Settings).
///
/// It renders from [playbackStateProvider] — the same single
/// [PlaybackController] the full [PlayerScreen] and the media session use — so
/// it never owns playback state of its own and never disappears when switching
/// tabs. When nothing is loaded it collapses to zero height. Tapping it opens
/// the full now-playing screen; the transport buttons delegate straight to the
/// controller. A thin accent progress line rides its top edge, doubling as the
/// separator from the content above.
///
/// How much transport the bar carries depends on how much room it has. A phone
/// in portrait gets play/pause alone, as it always has; a desktop window gets
/// the full row — favorite · previous · play/pause · next — centred between the
/// metadata and the queue button, so skipping a track or liking one never means
/// opening the full player first.
///
/// On a desktop host the progress line along the top edge is a seek control
/// rather than a readout: a pointer is precise enough to aim at a slim line, and
/// jumping 30 seconds back is the one thing a listener does often enough that
/// opening the full player for it grates. On a touch host it stays exactly the
/// decorative line it has always been — a 14 px strip is not a touch target, and
/// it sits right where a thumb reaches for the bar itself.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  // Both thresholds are measured against the bar's content width (the row
  // inside its horizontal padding), not the window, so they hold wherever the
  // bar is hosted.

  /// Below this the bar has room for play/pause and nothing else, so it looks
  /// and behaves exactly as it did before the transport row existed.
  static const double _favoriteBreakpoint = 360;

  /// At this width — a tablet in landscape, any desktop window — the metadata
  /// can give up the space the previous/next buttons and the queue button need.
  static const double _transportBreakpoint = 600;

  /// The volume control asks for another ~140px beside the queue button, so it
  /// waits for a bar wide enough to give it without squeezing the title.
  static const double _volumeBreakpoint = 840;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch only the current track (id-distinct) and its resolved source, so the
    // ~5 Hz position ticks rebuild just the thin progress line and the transport
    // buttons below — not the whole bar (artwork, text) on every screen, every
    // tick. The source changes only when the track does, so including it adds no
    // tick rebuilds. Falls back to the controller's latest state until the first
    // stream event arrives.
    final (Track?, PlaybackSource?) streamed = ref.watch(
      playbackStateProvider.select(
        (s) => (s.valueOrNull?.currentTrack, s.valueOrNull?.source),
      ),
    );
    final PlaybackState fallback = ref.read(playbackControllerProvider).state;
    final Track? track = streamed.$1 ?? fallback.currentTrack;
    final PlaybackSource? source = streamed.$2 ?? fallback.source;

    // Collapse entirely when there is nothing to show, so screens without a
    // loaded track look exactly as they did before.
    if (track == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final bool isCasting = ref.watch(
      castStateProvider.select((s) => s.valueOrNull?.isConnected ?? false),
    );
    final bool isDesktop = ref.watch(hostPlatformProvider).isDesktop;
    final subtitle = _subtitle(track);
    // The copy actually playing (Navidrome / Jellyfin / Local music / Cache),
    // shown as a faint tag beside the metadata. Hidden while casting, where the
    // cast indicator already says where the audio is going.
    final String? sourceName = (!isCasting && source != null)
        ? PlaybackSourceLabel.of(trackUri: track.uri, source: source)
        : null;

    final double miniPlayerHeight = math.max(
      64,
      MediaQuery.textScalerOf(context).scale(48),
    );

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push(AppRoutes.player),
        child: SizedBox(
          height: miniPlayerHeight,
          child: Column(
            children: [
              _MiniProgressBar(seekable: isDesktop),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                  ),
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                      final Widget metadata = _NowPlayingMetadata(
                        track: track,
                        subtitle: subtitle,
                        sourceName: sourceName,
                        isCasting: isCasting,
                      );

                      // Desktop bars wide enough for the full transport also
                      // get the volume control, where a desktop listener looks
                      // for it first. Hidden while casting: the level that
                      // matters then is the receiver's, which the cast sheet
                      // owns.
                      final bool showVolume = isDesktop &&
                          !isCasting &&
                          constraints.maxWidth >= _volumeBreakpoint;

                      if (constraints.maxWidth >= _transportBreakpoint) {
                        // Two equally weighted side columns, so the transport
                        // sits on the window's centre line rather than
                        // drifting with the length of the track title.
                        return Row(
                          children: <Widget>[
                            Expanded(child: metadata),
                            _Transport(
                              track: track,
                              showFavorite: true,
                              showSkip: true,
                            ),
                            Expanded(
                              child: Align(
                                alignment: AlignmentDirectional.centerEnd,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    if (showVolume) const VolumeControls(),
                                    const _QueueButton(),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      }

                      return Row(
                        children: <Widget>[
                          Expanded(child: metadata),
                          const SizedBox(width: AppSpacing.sm),
                          _Transport(
                            track: track,
                            showFavorite:
                                constraints.maxWidth >= _favoriteBreakpoint,
                            showSkip: false,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Artist • album when present; falls back to artist or album alone, and to
  /// nothing when the track carries no metadata.
  static String? _subtitle(Track track) {
    final String label = track.artistAlbumLabel;
    return label.isEmpty ? null : label;
  }
}

/// The bar's left column: cover, title, subtitle, and the cast indicator.
class _NowPlayingMetadata extends StatelessWidget {
  const _NowPlayingMetadata({
    required this.track,
    required this.subtitle,
    required this.sourceName,
    required this.isCasting,
  });

  final Track track;
  final String? subtitle;
  final String? sourceName;
  final bool isCasting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        // The cover carries no information the lines beside it don't already
        // say, so it stays out of the reading order rather than announcing an
        // image before them.
        ExcludeSemantics(
          child: SizedBox.square(
            dimension: 44,
            child: AlbumArtwork(
              artworkUri: track.artworkUri,
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          // One node for the whole metadata block, so the bar announces
          // "<title>, <artist> • <source>" once instead of three fragments in
          // a row. The transport buttons stay outside it and keep their own.
          child: MergeSemantics(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null || sourceName != null)
                  _MiniSubtitle(subtitle: subtitle, sourceName: sourceName),
              ],
            ),
          ),
        ),
        if (isCasting) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          // Icon-only, and the only thing on the bar that says the audio is
          // going somewhere else — so it is named.
          Icon(
            Icons.cast_connected,
            size: 18,
            color: theme.colorScheme.primary,
            semanticLabel: 'Casting',
          ),
        ],
      ],
    );
  }
}

/// The bar's transport cluster, sized to the room available:
/// favorite · previous · play/pause · next when the window allows it, and
/// play/pause alone on a narrow phone.
class _Transport extends StatelessWidget {
  const _Transport({
    required this.track,
    required this.showFavorite,
    required this.showSkip,
  });

  final Track track;
  final bool showFavorite;
  final bool showSkip;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showFavorite) _FavoriteButton(track: track),
        if (showSkip) const _SkipButton(previous: true),
        const _PlayPauseButton(),
        if (showSkip) const _SkipButton(previous: false),
      ],
    );
  }
}

/// The mini-player's second line: the artist • album metadata and, when known, a
/// faint trailing tag for the copy actually playing (Navidrome / Jellyfin /
/// Local music / Cache). Both halves shrink and ellipsize so a long title or a
/// narrow screen never overflows the bar.
class _MiniSubtitle extends StatelessWidget {
  const _MiniSubtitle({required this.subtitle, required this.sourceName});

  final String? subtitle;
  final String? sourceName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final TextStyle? metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );
    final TextStyle? sourceStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (subtitle != null)
          Flexible(
            child: Text(
              subtitle!,
              style: metaStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (subtitle != null && sourceName != null)
          Text('  •  ', style: sourceStyle),
        if (sourceName != null)
          Flexible(
            child: Text(
              sourceName!,
              style: sourceStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// A slim accent line tracking playback progress across the mini-player's top
/// edge, drawn as the same gentle wave the now-playing screen uses so the two
/// surfaces read as one design. Sits at 0 (an empty track) when the duration is
/// still unknown, so it never animates indeterminately or jumps.
///
/// Where a pointer is the input — [seekable], set on desktop hosts — it is the
/// same [PlaybackProgressBar] the full player uses, at its compact density and
/// without the elapsed/total caption there is no room for. That buys the drag
/// preview, the optimistic hold until playback acknowledges a seek, the slider
/// semantics and the arrow-key handling for free, and keeps the two surfaces
/// seeking identically rather than approximately.
///
/// On a touch host it stays what it always was: marker-less, pinned at the full
/// wave rather than following the play/pause swell the full player uses. At that
/// size the wave is texture rather than a control, and this bar is on screen on
/// every main tab — so it stays a plain repaint per position tick and adds no
/// animation frames anywhere in the app.
///
/// It watches the position/duration itself, so a position tick rebuilds only
/// this thin line — not the artwork and text above it.
class _MiniProgressBar extends ConsumerWidget {
  const _MiniProgressBar({required this.seekable});

  /// Whether the line takes clicks, drags and arrow keys as seeks.
  final bool seekable;

  /// Enough room for the wave's peaks and stroke without meaningfully eating
  /// into the 64dp bar's content row.
  static const double _height = 6.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;

    if (seekable) {
      return PlaybackProgressBar(
        // Same reasoning as the full player's bar: identity is the track, so a
        // track change disposes an optimistically held seek instead of carrying
        // it onto the next song.
        key: ValueKey<String?>(state.currentTrack?.uri),
        position: state.position,
        duration: state.duration,
        playing: state.isPlaying,
        density: WavySeekBarDensity.compact,
        showTimeLabels: false,
        onSeek: controller.seek,
      );
    }

    final theme = Theme.of(context);
    final int total = state.duration.inMilliseconds;
    final double value = total > 0
        ? (state.position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      height: _height,
      child: WavyProgressIndicator(
        value: value,
        activeColor: theme.colorScheme.secondary,
        inactiveColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        amplitude: 1.4,
        wavelength: 26,
        strokeWidth: 2,
      ),
    );
  }
}

/// Likes or un-likes whatever is playing, without a trip through the full
/// player.
///
/// The track handed here is the one the controller is actually playing, so it
/// is already the provider-specific copy a favourite write has to target — no
/// resolution step is needed the way it is on the now-playing screen, where the
/// displayed track can come from the unified library instead.
class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Keyed by the provider-namespaced uri, so `jellyfin:101` and
    // `subsonic:101` each reflect their own heart.
    final bool isFavorite = ref.watch(isFavoriteProvider(track.uri));
    return IconButton(
      onPressed: () =>
          ref.read(favoritesRepositoryProvider).setFavorite(track, !isFavorite),
      icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border),
      iconSize: 22,
      // The same violet the now-playing screen's heart uses, so a liked track
      // reads the same on both surfaces.
      color: isFavorite
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurface.withValues(alpha: 0.7),
      isSelected: isFavorite,
      tooltip: isFavorite ? 'Remove from favorites' : 'Favorite',
    );
  }
}

/// Previous / next, mirroring the full player's transport: they follow the live
/// queue and grey out at its ends rather than disappearing, so the bar's layout
/// doesn't shift as a queue plays out.
class _SkipButton extends ConsumerWidget {
  const _SkipButton({required this.previous});

  final bool previous;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    // Only the one flag this button cares about, so a position tick (or the
    // other end of the queue changing) doesn't rebuild it.
    final bool enabled = ref.watch(
          playbackStateProvider.select(
            (s) => switch (s.valueOrNull) {
              null => null,
              final PlaybackState state =>
                previous ? state.hasPrevious : state.hasNext,
            },
          ),
        ) ??
        (previous ? controller.state.hasPrevious : controller.state.hasNext);

    return IconButton(
      onPressed: enabled
          ? (previous ? controller.skipToPrevious : controller.skipToNext)
          : null,
      icon: Icon(previous ? Icons.skip_previous : Icons.skip_next),
      iconSize: 26,
      tooltip: previous ? 'Previous' : 'Next',
    );
  }
}

/// Opens the up-next list. Desktop windows only: it is the one control here
/// that has somewhere better to live on a phone (the full player's action row).
class _QueueButton extends StatelessWidget {
  const _QueueButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => showQueueSheet(context),
      icon: const Icon(Icons.queue_music_outlined),
      iconSize: 22,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
      tooltip: 'Queue',
    );
  }
}

/// The mini-player's central transport control: a spinner while a track loads,
/// then a play/pause toggle (tinted with the warm accent) that forwards to the
/// controller. Watches the playback status itself so it stays live even though
/// the bar around it only rebuilds when the track changes.
class _PlayPauseButton extends ConsumerWidget {
  const _PlayPauseButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(playbackControllerProvider);
    final state =
        ref.watch(playbackStateProvider).valueOrNull ?? controller.state;
    // A spinner for both preparing and mid-stream buffering, so the mini-player
    // shows activity (never looks frozen) while the stream catches up.
    if (state.isBusy) {
      // The spinner stands where play/pause normally is: without a name it
      // reads as the transport control having simply vanished.
      return Semantics(
        label: 'Buffering',
        child: const SizedBox.square(
          dimension: 24,
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xs),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final playing = state.isPlaying;
    return IconButton(
      onPressed: playing ? controller.pause : controller.play,
      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
      iconSize: 30,
      color: Theme.of(context).colorScheme.secondary,
      tooltip: playing ? 'Pause' : 'Play',
    );
  }
}
