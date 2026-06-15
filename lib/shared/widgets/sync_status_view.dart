import 'package:flutter/material.dart';

import '../../app/dimens.dart';

/// Where a music source's library sync is in its lifecycle, unified across every
/// provider so the UI can present one consistent status regardless of which
/// backend produced it.
///
/// Each provider (Navidrome/Subsonic, Jellyfin, …) tracks its own sync in its
/// own controller; this small, display-only vocabulary is what they map into so
/// [SyncStatusView] can render them all identically.
enum SyncState {
  /// A sync is running right now.
  syncing,

  /// The last sync finished successfully.
  synced,

  /// The last sync attempt failed.
  failed,

  /// This source has never been synced (a fresh connection).
  neverSynced,

  /// The device is offline, so a sync can't run.
  offline,
}

/// An immutable, display-safe snapshot of a source's sync status.
///
/// It carries only what the UI shows — the [state], when the last *successful*
/// sync landed ([lastSyncedAt]), and a friendly [lastError] for a failure. Like
/// the per-provider state objects it unifies, it never holds a token, password,
/// or streaming URL.
@immutable
class SyncStatusData {
  const SyncStatusData({
    required this.state,
    this.lastSyncedAt,
    this.lastError,
  });

  /// A source that has never been synced (no time, no error).
  const SyncStatusData.neverSynced() : this(state: SyncState.neverSynced);

  /// A sync in progress; [lastSyncedAt] is the previous success, if any.
  const SyncStatusData.syncing({DateTime? lastSyncedAt})
      : this(state: SyncState.syncing, lastSyncedAt: lastSyncedAt);

  /// A sync that completed successfully at [lastSyncedAt].
  const SyncStatusData.synced(DateTime lastSyncedAt)
      : this(state: SyncState.synced, lastSyncedAt: lastSyncedAt);

  /// A failed sync, optionally with a friendly [error] and the previous success
  /// time ([lastSyncedAt]) so the UI can still say when it last worked.
  const SyncStatusData.failed({String? error, DateTime? lastSyncedAt})
      : this(
          state: SyncState.failed,
          lastError: error,
          lastSyncedAt: lastSyncedAt,
        );

  /// Offline, with the previous success time ([lastSyncedAt]) if known.
  const SyncStatusData.offline({DateTime? lastSyncedAt})
      : this(state: SyncState.offline, lastSyncedAt: lastSyncedAt);

  final SyncState state;

  /// When the last *successful* sync completed, or null if it never has.
  final DateTime? lastSyncedAt;

  /// A friendly, secret-free reason the last sync failed — shown only when
  /// [state] is [SyncState.failed] and one is available.
  final String? lastError;

  @override
  bool operator ==(Object other) =>
      other is SyncStatusData &&
      other.state == state &&
      other.lastSyncedAt == lastSyncedAt &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(state, lastSyncedAt, lastError);
}

/// Formats how long ago [time] was, in the short, friendly style the sync
/// status uses ("just now", "2 minutes ago", "yesterday", "3 days ago").
///
/// [now] is injectable so the relative phrasing is deterministic in tests; it
/// defaults to the wall clock. A [time] in the (near) future — clock skew, or a
/// just-stamped value — clamps to "just now" rather than reading as negative.
String syncTimeAgo(DateTime time, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  final Duration diff = reference.difference(time);

  if (diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60) {
    final int minutes = diff.inMinutes < 1 ? 1 : diff.inMinutes;
    return minutes == 1 ? '1 minute ago' : '$minutes minutes ago';
  }
  if (diff.inHours < 24) {
    final int hours = diff.inHours;
    return hours == 1 ? '1 hour ago' : '$hours hours ago';
  }
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  if (diff.inDays < 30) {
    final int weeks = (diff.inDays / 7).floor();
    return weeks == 1 ? '1 week ago' : '$weeks weeks ago';
  }
  if (diff.inDays < 365) {
    final int months = (diff.inDays / 30).floor();
    return months == 1 ? '1 month ago' : '$months months ago';
  }
  final int years = (diff.inDays / 365).floor();
  return years == 1 ? '1 year ago' : '$years years ago';
}

/// A reusable, Material 3 sync-status block that makes a source's sync state
/// obvious at a glance — identically for every provider.
///
/// It renders, straight from a [SyncStatusData]:
///   * a status line — "Syncing…", "Synced 2 minutes ago", "Last sync failed",
///     "Never synced", or "Offline" — with a matching icon and colour;
///   * the last *successful* sync time (in the line for [SyncState.synced], or
///     as a quiet "Last synced …" sub-line once a later attempt fails / goes
///     offline);
///   * the last error, when a failure carries one; and
///   * an [onSync] button (a spinner labelled "Syncing…" while a sync runs).
///
/// Drop it into any provider's settings card; the provider only has to map its
/// own sync state into a [SyncStatusData]. For example:
///
/// ```dart
/// SyncStatusView(
///   status: SyncStatusData.synced(lastSyncedAt),
///   syncLabel: 'Sync library',
///   onSync: controller.sync,
/// )
/// ```
class SyncStatusView extends StatelessWidget {
  const SyncStatusView({
    required this.status,
    this.onSync,
    this.syncLabel = 'Sync now',
    this.now,
    super.key,
  });

  /// The status to render.
  final SyncStatusData status;

  /// Invoked when the sync button is tapped. When null, no button is shown; the
  /// button is always disabled while a sync is already running.
  final VoidCallback? onSync;

  /// The idle sync button label (e.g. "Sync library"). While a sync runs the
  /// button always reads "Syncing…".
  final String syncLabel;

  /// Injectable clock for the relative "… ago" phrasing; defaults to the wall
  /// clock. Exists so widget tests can render a deterministic time.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool syncing = status.state == SyncState.syncing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _statusLine(theme),
        if (onSync != null) ...[
          const SizedBox(height: AppSpacing.md),
          FilledButton.tonalIcon(
            onPressed: syncing ? null : onSync,
            icon: syncing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_outlined),
            label: Text(syncing ? 'Syncing…' : syncLabel),
          ),
        ],
      ],
    );
  }

  Widget _statusLine(ThemeData theme) {
    final Color color = _color(theme);
    final String? subline = _subline();
    final bool showError = status.state == SyncState.failed &&
        status.lastError != null &&
        status.lastError!.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The icon/spinner only mirrors the text line, so keep it out of the
        // semantics tree — the headline and sub-lines already read the state.
        ExcludeSemantics(child: _leading(theme, color)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _headline(),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subline != null) ...[
                const SizedBox(height: 2),
                Text(
                  subline,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (showError) ...[
                const SizedBox(height: 2),
                Text(
                  status.lastError!,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _leading(ThemeData theme, Color color) {
    if (status.state == SyncState.syncing) {
      return const SizedBox.square(
        dimension: 20,
        child: Padding(
          padding: EdgeInsets.all(1),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Icon(_icon(), size: 20, color: color);
  }

  String _headline() {
    switch (status.state) {
      case SyncState.syncing:
        return 'Syncing…';
      case SyncState.synced:
        final DateTime? at = status.lastSyncedAt;
        return at == null ? 'Synced' : 'Synced ${syncTimeAgo(at, now: now)}';
      case SyncState.failed:
        return 'Last sync failed';
      case SyncState.neverSynced:
        return 'Never synced';
      case SyncState.offline:
        return 'Offline';
    }
  }

  /// A quiet "Last synced …" line for states whose headline isn't already the
  /// time but that have synced successfully before (a later failure, or going
  /// offline). [SyncState.synced] shows the time in its headline instead.
  String? _subline() {
    final DateTime? at = status.lastSyncedAt;
    if (at == null) return null;
    if (status.state == SyncState.failed || status.state == SyncState.offline) {
      return 'Last synced ${syncTimeAgo(at, now: now)}';
    }
    return null;
  }

  IconData _icon() {
    switch (status.state) {
      // A spinner stands in for syncing (see [_leading]); this keeps the switch
      // exhaustive and is otherwise unused.
      case SyncState.syncing:
        return Icons.sync_outlined;
      case SyncState.synced:
        return Icons.cloud_done_outlined;
      case SyncState.failed:
        return Icons.error_outline;
      case SyncState.neverSynced:
        return Icons.cloud_outlined;
      case SyncState.offline:
        return Icons.cloud_off_outlined;
    }
  }

  Color _color(ThemeData theme) {
    switch (status.state) {
      case SyncState.syncing:
      case SyncState.synced:
        return theme.colorScheme.primary;
      case SyncState.failed:
        return theme.colorScheme.error;
      case SyncState.neverSynced:
      case SyncState.offline:
        return theme.colorScheme.onSurfaceVariant;
    }
  }
}
