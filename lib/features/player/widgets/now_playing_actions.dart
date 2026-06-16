import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/playback_state.dart';
import '../../../core/models/repeat_mode.dart';
import '../../../core/models/track.dart';
import '../../../data/repositories/favorites_repository_provider.dart';
import '../../../ui_linthra/design_tokens.dart';
import '../../../ui_linthra/now_playing_actions_config.dart';
import '../../playlists/widgets/add_to_playlist_sheet.dart';
import '../favorites_providers.dart';
import '../player_providers.dart';
import '../sleep_timer_controller.dart';
import 'lyrics_view.dart';
import 'queue_sheet.dart';
import 'sleep_timer_sheet.dart';

/// Bottom action row on the now-playing screen: favorite · playlist · queue ·
/// lyrics · sleep timer.
///
/// The row's **order, which buttons appear, and each button's icon/label** are
/// declared in `lib/ui_linthra/now_playing_actions_config.dart` — edit that file
/// to retune the row. This widget owns only the *wiring* (what each button does):
/// favorite toggles a heart synced through the [FavoritesRepository] (to Jellyfin
/// for remote tracks, on-device for local ones), queue opens the up-next list,
/// lyrics fetches the track's lyrics from the source — falling back to an honest
/// "no lyrics" state when there are none (or for a local track / when signed out)
/// — and the sleep timer (a moon that lights up while a countdown is running)
/// opens the delay picker.
class NowPlayingActions extends ConsumerWidget {
  const NowPlayingActions({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool isFavorite = ref.watch(isFavoriteProvider(track.id));
    final bool sleepTimerActive = ref.watch(
      sleepTimerControllerProvider.select((s) => s.isActive),
    );

    // Shuffle and repeat normally live in the transport row, but the config may
    // place them here too. Only subscribe to their playback state when they are
    // actually in the row, so by default this row stays off the high-frequency
    // position ticks (it rebuilds only on a favorite or sleep-timer change).
    const List<NowPlayingAction> order = nowPlayingActionOrder;
    final bool needsTransport = order.contains(NowPlayingAction.shuffle) ||
        order.contains(NowPlayingAction.repeat);
    final (bool, RepeatMode)? transport = needsTransport
        ? ref.watch(playbackStateProvider.select((s) {
            final PlaybackState? state = s.valueOrNull;
            return (
              state?.shuffleEnabled ?? false,
              state?.repeatMode ?? RepeatMode.off,
            );
          }))
        : null;

    // A calm, uniform tint keeps this row reading as tertiary beneath the
    // transport controls; favorite and the sleep timer still light up when
    // active.
    final Color muted = theme.colorScheme.onSurface
        .withValues(alpha: NowPlayingOpacityTokens.action);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        for (final NowPlayingAction action in order)
          _actionButton(
            context,
            ref,
            theme,
            action,
            muted: muted,
            isFavorite: isFavorite,
            sleepTimerActive: sleepTimerActive,
            shuffleEnabled: transport?.$1 ?? false,
            repeatMode: transport?.$2 ?? RepeatMode.off,
          ),
      ],
    );
  }

  /// Builds one button from its config [NowPlayingActionStyle] plus the live
  /// state and wiring for that specific action. Keeping the look in the config
  /// and the behaviour here is what lets the maintainer reorder/hide/relabel the
  /// row without reading any playback code.
  Widget _actionButton(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    NowPlayingAction action, {
    required Color muted,
    required bool isFavorite,
    required bool sleepTimerActive,
    required bool shuffleEnabled,
    required RepeatMode repeatMode,
  }) {
    final NowPlayingActionStyle style = nowPlayingActionStyles[action]!;

    // Per-action live state (is it "on"?), what it does on tap, and any
    // mode-specific glyph/tooltip overrides (repeat is tri-state).
    bool active = false;
    VoidCallback? onPressed;
    IconData icon = style.icon;
    String tooltip = style.label;

    switch (action) {
      case NowPlayingAction.favorite:
        active = isFavorite;
        onPressed = () => ref
            .read(favoritesRepositoryProvider)
            .setFavorite(track, !isFavorite);
      case NowPlayingAction.addToPlaylist:
        onPressed = () => showAddToPlaylistSheet(context, <Track>[track]);
      case NowPlayingAction.queue:
        onPressed = () => _openQueue(context);
      case NowPlayingAction.lyrics:
        onPressed = () => _openLyrics(context);
      case NowPlayingAction.sleepTimer:
        active = sleepTimerActive;
        onPressed = () => showSleepTimerSheet(context);
      case NowPlayingAction.shuffle:
        active = shuffleEnabled;
        onPressed = () =>
            ref.read(playbackControllerProvider).setShuffleEnabled(!active);
      case NowPlayingAction.repeat:
        active = repeatMode != RepeatMode.off;
        icon = repeatMode == RepeatMode.one ? Icons.repeat_one : style.icon;
        tooltip = _repeatTooltip(repeatMode);
        onPressed = () =>
            ref.read(playbackControllerProvider).setRepeatMode(repeatMode.next);
    }

    // When "on", swap in the active glyph/word (if the action defines them) and
    // light up with the action's tint; otherwise stay the calm muted tint.
    if (active) {
      icon = action == NowPlayingAction.repeat
          ? icon // repeat picked its glyph above
          : (style.activeIcon ?? icon);
      tooltip = action == NowPlayingAction.repeat
          ? tooltip // repeat picked its tooltip above
          : (style.activeLabel ?? tooltip);
    }

    // Only toggleable actions (favorite, sleep, shuffle, repeat — the ones with
    // a tint) are toggle buttons; the momentary ones stay plain (isSelected
    // null), exactly as before.
    final bool toggleable = style.tint != NowPlayingActionTint.none;
    return IconButton(
      iconSize: NowPlayingButtonTokens.actionIconSize,
      onPressed: onPressed,
      icon: Icon(icon),
      color: active ? _tintColor(theme, style.tint) : muted,
      isSelected: toggleable ? active : null,
      tooltip: tooltip,
    );
  }

  /// Maps an action's [NowPlayingActionTint] to the theme colour it lights up
  /// with when active.
  Color _tintColor(ThemeData theme, NowPlayingActionTint tint) {
    switch (tint) {
      case NowPlayingActionTint.brand:
        return theme.colorScheme.primary;
      case NowPlayingActionTint.accent:
        return theme.colorScheme.secondary;
      case NowPlayingActionTint.none:
        return theme.colorScheme.primary;
    }
  }

  static String _repeatTooltip(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return 'Repeat';
      case RepeatMode.all:
        return 'Repeat all';
      case RepeatMode.one:
        return 'Repeat one';
    }
  }

  void _openQueue(BuildContext context) {
    showQueueSheet(context);
  }

  void _openLyrics(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _LyricsSheet(),
    );
  }
}

/// The lyrics sheet: a tall, premium synced-lyrics panel. It follows the
/// *currently playing* track rather than a captured one, so skipping updates the
/// lines in place; the heavy lifting (loading / empty / plain / synced
/// highlighting + auto-scroll) lives in [LyricsView]. Opening it only reads
/// playback state — it never starts or restarts playback.
class _LyricsSheet extends StatelessWidget {
  const _LyricsSheet();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.lyrics_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Lyrics', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const Expanded(child: LyricsView()),
            ],
          ),
        ),
      ),
    );
  }
}
