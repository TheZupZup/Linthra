import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/local/folder_location.dart';
import '../../../core/sources/local/local_scan_report.dart';
import '../../library/local_scan_report_provider.dart';
import '../../library/selected_folder_controller.dart';
import '../jellyfin/jellyfin_settings_controller.dart';
import '../jellyfin/jellyfin_settings_section.dart';
import '../jellyfin/jellyfin_settings_state.dart';
import '../jellyfin/jellyfin_sync_controller.dart';
import '../jellyfin/jellyfin_sync_state.dart';
import '../plex/plex_settings_controller.dart';
import '../plex/plex_settings_section.dart';
import '../plex/plex_settings_state.dart';
import '../plex/plex_sync_controller.dart';
import '../plex/plex_sync_state.dart';
import '../subsonic/subsonic_settings_controller.dart';
import '../subsonic/subsonic_settings_section.dart';
import '../subsonic/subsonic_settings_state.dart';
import '../subsonic/subsonic_sync_controller.dart';
import '../subsonic/subsonic_sync_state.dart';
import 'local_music_controller.dart';
import 'local_music_settings_section.dart';

/// The compact "Music sources" overview on the Settings screen.
///
/// Each music source is shown as a small [ProviderSummaryCard] — name, a
/// one-word status, an optional detail line (the last sync result, the chosen
/// folder, …) and a short row of actions. The full, technical settings (edit
/// the server URL, change credentials, test the connection, disconnect) are no
/// longer always on screen; they open behind **Manage**, which presents the
/// *existing* provider settings widget in a bottom sheet. Nothing about how a
/// source connects or syncs changes — only how the screen is laid out.
///
/// These cards are presentation only: every action is forwarded to the same
/// controllers the detailed sections already use, so behaviour (and the
/// secret-handling guarantees those controllers make) is unchanged.

/// The visual tone of a provider's status line. It only ever maps to theme
/// tokens, so the brand palette stays the single source of truth for colour.
enum ProviderStatusTone { positive, neutral, error }

/// A compact, Material 3 summary card for one music source.
///
/// Tapping anywhere on the card opens [onManage]; callers pass the context
/// actions (Sync now, Rescan, Connect, …) to show as buttons. The card holds no
/// provider logic of its own — the provider-specific cards below build it.
class ProviderSummaryCard extends StatelessWidget {
  const ProviderSummaryCard({
    super.key,
    required this.icon,
    required this.title,
    required this.statusLabel,
    required this.onManage,
    this.statusTone = ProviderStatusTone.neutral,
    this.detail,
    this.detailIsError = false,
    this.badgeLabel,
    this.actions = const <Widget>[],
  });

  /// The provider's glyph, matching the icon its detailed section uses.
  final IconData icon;

  /// The provider's name (e.g. "Jellyfin").
  final String title;

  /// A short status word/phrase (e.g. "Connected", "Not connected").
  final String statusLabel;

  /// Drives the colour of the status dot and label.
  final ProviderStatusTone statusTone;

  /// A secondary line under the status — the last sync summary, the selected
  /// folder, or a short hint. Omitted when null.
  final String? detail;

  /// Renders [detail] in the error colour (e.g. a sync that didn't finish).
  final bool detailIsError;

  /// An optional status pill beside the title (e.g. "Beta"). No provider sets
  /// one right now; kept as a small, reusable affordance.
  final String? badgeLabel;

  /// The action buttons, laid out as equal-width columns. Manage is always
  /// reachable by tapping the card, so callers pass only the context actions
  /// plus, when useful, an explicit Manage button.
  final List<Widget> actions;

  /// The whole-card tap target opens the provider's full settings.
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: InkWell(
        onTap: onManage,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _LeadingIcon(icon: icon),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                title,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (badgeLabel != null) ...<Widget>[
                              const SizedBox(width: AppSpacing.sm),
                              _Badge(label: badgeLabel!),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        _StatusLine(label: statusLabel, tone: statusTone),
                        if (detail != null) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            detail!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: detailIsError
                                  ? theme.colorScheme.error
                                  : muted,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                _ActionRow(actions: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The rounded, tinted glyph at the start of a card.
class _LeadingIcon extends StatelessWidget {
  const _LeadingIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Icon(icon, color: theme.colorScheme.primary),
    );
  }
}

/// A small status dot plus its label, coloured by [tone].
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.tone});

  final String label;
  final ProviderStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = switch (tone) {
      ProviderStatusTone.positive => theme.colorScheme.primary,
      ProviderStatusTone.neutral =>
        theme.colorScheme.onSurface.withValues(alpha: 0.6),
      ProviderStatusTone.error => theme.colorScheme.error,
    };
    return Row(
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// A muted pill beside a card's title (e.g. "Beta") for an optional status tag.
class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Lays the action buttons out as equal-width columns (a single action fills
/// the width), matching the Rescan/Change row the local section already uses.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.length == 1) {
      return SizedBox(width: double.infinity, child: actions.single);
    }
    return Row(
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(child: actions[i]),
        ],
      ],
    );
  }
}

/// The trailing "Manage" button common to every connected card.
class _ManageButton extends StatelessWidget {
  const _ManageButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      child: const Text('Manage'),
    );
  }
}

/// A tonal action button that swaps its icon for a spinner while [busy].
class _BusyTonalButton extends StatelessWidget {
  const _BusyTonalButton({
    required this.icon,
    required this.label,
    required this.busyLabel,
    required this.busy,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String busyLabel;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon),
      label: Text(busy ? busyLabel : label),
    );
  }
}

/// Opens a provider's existing settings widget ([child]) in a Material 3 modal
/// bottom sheet. Reusing the unchanged section keeps every edit-URL / change-
/// credentials / test / disconnect affordance exactly as it was — only its
/// entry point moves behind Manage.
Future<void> showProviderSettingsSheet(
  BuildContext context, {
  required Widget child,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) {
      return Padding(
        // Lift the content above the keyboard when a field is focused.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: child,
          ),
        ),
      );
    },
  );
}

/// The Jellyfin source as a compact card.
class JellyfinProviderCard extends ConsumerWidget {
  const JellyfinProviderCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final JellyfinSettingsState state =
        ref.watch(jellyfinSettingsControllerProvider);
    final JellyfinSyncState sync = ref.watch(jellyfinSyncControllerProvider);
    final bool connected = state.isConnected;

    void manage() => showProviderSettingsSheet(
          context,
          child: const JellyfinSettingsSection(),
        );

    String? detail;
    bool detailIsError = false;
    if (!connected) {
      detail = 'Sign in to stream your Jellyfin library.';
    } else if (sync.isSyncing) {
      detail = 'Syncing your library…';
    } else if (sync.isError) {
      detail = sync.message;
      detailIsError = true;
    } else if (sync.message != null) {
      detail = sync.message;
    } else if (state.username != null && state.username!.isNotEmpty) {
      detail = 'Signed in as ${state.username}';
    } else {
      detail = state.serverName;
    }

    return ProviderSummaryCard(
      icon: Icons.cloud_outlined,
      title: 'Jellyfin',
      statusLabel: connected ? 'Connected' : 'Not connected',
      statusTone:
          connected ? ProviderStatusTone.positive : ProviderStatusTone.neutral,
      detail: detail,
      detailIsError: detailIsError,
      onManage: manage,
      actions: connected
          ? <Widget>[
              _BusyTonalButton(
                icon: Icons.sync_outlined,
                label: 'Sync now',
                busyLabel: 'Syncing…',
                busy: sync.isSyncing,
                onPressed: sync.isSyncing
                    ? null
                    : () => ref
                        .read(jellyfinSyncControllerProvider.notifier)
                        .sync(),
              ),
              _ManageButton(onPressed: manage),
            ]
          : <Widget>[
              FilledButton(onPressed: manage, child: const Text('Connect')),
            ],
    );
  }
}

/// The Navidrome / Subsonic source as a compact card.
class SubsonicProviderCard extends ConsumerWidget {
  const SubsonicProviderCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SubsonicSettingsState state =
        ref.watch(subsonicSettingsControllerProvider);
    final SubsonicSyncState sync = ref.watch(subsonicSyncControllerProvider);
    final bool connected = state.isConnected;

    void manage() => showProviderSettingsSheet(
          context,
          child: const SubsonicSettingsSection(),
        );

    String? detail;
    bool detailIsError = false;
    if (!connected) {
      detail = 'Sign in to stream your Navidrome / Subsonic library.';
    } else if (sync.isSyncing) {
      detail = 'Syncing your library…';
    } else if (sync.isError) {
      detail = sync.message;
      detailIsError = true;
    } else if (sync.message != null) {
      detail = sync.message;
    } else if (state.username != null && state.username!.isNotEmpty) {
      detail = 'Signed in as ${state.username}';
    } else {
      detail = state.productLabel;
    }

    return ProviderSummaryCard(
      icon: Icons.dns_outlined,
      title: 'Navidrome / Subsonic',
      statusLabel: connected ? 'Connected' : 'Not connected',
      statusTone:
          connected ? ProviderStatusTone.positive : ProviderStatusTone.neutral,
      detail: detail,
      detailIsError: detailIsError,
      onManage: manage,
      actions: connected
          ? <Widget>[
              _BusyTonalButton(
                icon: Icons.sync_outlined,
                label: 'Sync now',
                busyLabel: 'Syncing…',
                busy: sync.isSyncing,
                onPressed: sync.isSyncing
                    ? null
                    : () => ref
                        .read(subsonicSyncControllerProvider.notifier)
                        .sync(),
              ),
              _ManageButton(onPressed: manage),
            ]
          : <Widget>[
              FilledButton(onPressed: manage, child: const Text('Connect')),
            ],
    );
  }
}

/// The Plex source as a compact card, matching the detailed section. Plex is a
/// supported provider (streaming, lyrics, and offline caching); the advanced
/// features it doesn't support yet simply don't appear as actions.
class PlexProviderCard extends ConsumerWidget {
  const PlexProviderCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlexSettingsState state = ref.watch(plexSettingsControllerProvider);
    final PlexSyncState sync = ref.watch(plexSyncControllerProvider);
    final bool connected = state.isConnected;

    void manage() => showProviderSettingsSheet(
          context,
          child: const PlexSettingsSection(),
        );

    String? detail;
    bool detailIsError = false;
    if (!connected) {
      detail = 'Connect your Plex account to stream your music.';
    } else if (state.errorMessage != null) {
      detail = state.errorMessage;
      detailIsError = true;
    } else if (sync.isScanning) {
      detail = 'Scanning your libraries…';
    } else if (sync.isWriting) {
      detail = 'Saving your libraries…';
    } else if (sync.isError) {
      detail = sync.message;
      detailIsError = true;
    } else if (sync.message != null) {
      detail = sync.message;
    } else {
      detail = state.serverName ?? state.baseUrl;
    }

    return ProviderSummaryCard(
      icon: Icons.dns_outlined,
      title: 'Plex',
      statusLabel: connected ? 'Connected' : 'Not connected',
      statusTone:
          connected ? ProviderStatusTone.positive : ProviderStatusTone.neutral,
      detail: detail,
      detailIsError: detailIsError,
      onManage: manage,
      actions: connected
          ? <Widget>[
              _BusyTonalButton(
                icon: Icons.sync_outlined,
                label: 'Sync now',
                busyLabel: 'Syncing…',
                busy: sync.isSyncing,
                onPressed: sync.isSyncing
                    ? null
                    : () =>
                        ref.read(plexSyncControllerProvider.notifier).sync(),
              ),
              _ManageButton(onPressed: manage),
            ]
          : <Widget>[
              FilledButton(onPressed: manage, child: const Text('Connect')),
            ],
    );
  }
}

/// The on-device "Local music" source as a compact card.
class LocalMusicProviderCard extends ConsumerWidget {
  const LocalMusicProviderCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? folder =
        ref.watch(selectedFolderControllerProvider).valueOrNull;
    final LocalScanReport? report = ref.watch(localScanReportProvider);
    final LocalMusicActionState action =
        ref.watch(localMusicControllerProvider);
    final bool? persisted = ref.watch(localFolderAccessProvider).valueOrNull;
    final bool hasFolder = folder != null && folder.isNotEmpty;
    final LocalMusicController controller =
        ref.read(localMusicControllerProvider.notifier);

    void manage() => showProviderSettingsSheet(
          context,
          child: const LocalMusicSettingsSection(),
        );

    String status;
    ProviderStatusTone tone;
    String? detail;
    if (!hasFolder) {
      status = 'No folder selected';
      tone = ProviderStatusTone.neutral;
      detail = 'Pick a folder on this device to play your own music.';
    } else if (persisted == false) {
      status = 'Folder access lost';
      tone = ProviderStatusTone.error;
      detail = FolderLocation.parse(folder).displayLabel;
    } else {
      final int tracks = report?.importedTracks ?? 0;
      status = tracks > 0
          ? '$tracks ${tracks == 1 ? 'track' : 'tracks'}'
          : 'Folder selected';
      tone = ProviderStatusTone.positive;
      detail = FolderLocation.parse(folder).displayLabel;
    }

    return ProviderSummaryCard(
      icon: Icons.folder_special_outlined,
      title: 'Local music',
      statusLabel: status,
      statusTone: tone,
      detail: detail,
      onManage: manage,
      actions: hasFolder
          ? <Widget>[
              _BusyTonalButton(
                icon: Icons.refresh,
                label: 'Rescan',
                busyLabel: 'Rescanning…',
                busy: action.busy,
                onPressed: action.busy ? null : controller.rescan,
              ),
              _ManageButton(onPressed: manage),
            ]
          : <Widget>[
              FilledButton.icon(
                onPressed: action.busy ? null : controller.pickFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Select a folder'),
              ),
            ],
    );
  }
}
