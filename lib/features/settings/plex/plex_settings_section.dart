import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/music_provider.dart';
import 'plex_settings_controller.dart';
import 'plex_settings_state.dart';

/// The Plex connection card on the Settings screen (phase 1, experimental).
///
/// Owns the text fields (server URL / token) but nothing else: every action is
/// forwarded to [PlexSettingsController], and everything rendered comes from
/// [PlexSettingsState]. The widget never touches HTTP or storage directly.
///
/// Token safety: the pasted token is obscured while typed, forwarded once to
/// the controller, and cleared from the field the moment the connection is
/// saved — after that it is never shown again anywhere (the connected view
/// renders only server metadata, and the state holds no token).
///
/// Unlike Jellyfin/Subsonic (which sync the whole server), the connected view
/// hosts the **library picker**: Plex asks the user to choose which music
/// libraries to include, and the selection is persisted into the session.
class PlexSettingsSection extends ConsumerStatefulWidget {
  const PlexSettingsSection({super.key});

  @override
  ConsumerState<PlexSettingsSection> createState() =>
      _PlexSettingsSectionState();
}

class _PlexSettingsSectionState extends ConsumerState<PlexSettingsSection> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_onFieldChanged);
    _tokenController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// Both fields are required: Plex verifies `/identity` with the token, so a
  /// successful test confirms connecting will work.
  bool get _canSubmit =>
      _urlController.text.trim().isNotEmpty &&
      _tokenController.text.trim().isNotEmpty;

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    await ref.read(plexSettingsControllerProvider.notifier).testConnection(
          url: _urlController.text,
          token: _tokenController.text,
        );
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    final bool ok =
        await ref.read(plexSettingsControllerProvider.notifier).connect(
              url: _urlController.text,
              token: _tokenController.text,
            );
    // Never keep the token in the field (or memory) once it's been saved to
    // the encrypted store — it is never shown again.
    if (ok) {
      _tokenController.clear();
    }
  }

  Future<void> _disconnect() async {
    await ref.read(plexSettingsControllerProvider.notifier).disconnect();
    _urlController.clear();
    _tokenController.clear();
  }

  Future<void> _refreshSections() async {
    await ref.read(plexSettingsControllerProvider.notifier).refreshSections();
  }

  void _toggleSection(String key, bool included) {
    ref
        .read(plexSettingsControllerProvider.notifier)
        .toggleSection(key, included: included);
  }

  @override
  Widget build(BuildContext context) {
    final PlexSettingsState state = ref.watch(plexSettingsControllerProvider);
    final ThemeData theme = Theme.of(context);

    // After a restart restored the session, the picker still needs the
    // library list; ask for it once the frame is built (idempotent — the
    // controller only fetches when it hasn't tried for this connection).
    if (state.isConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(plexSettingsControllerProvider.notifier)
            .loadSectionsIfNeeded();
      });
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.dns_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text(state.isConnected ? state.displayName : 'Plex',
                    style: theme.textTheme.titleMedium),
                const SizedBox(width: AppSpacing.sm),
                const _ExperimentalBadge(),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Stream from your own Plex Media Server. Paste the server '
              'address and a Plex token — the token is stored encrypted on '
              'this device and never shown again.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _CapabilityChips(),
            const SizedBox(height: AppSpacing.md),
            if (state.isConnected)
              _ConnectedView(
                state: state,
                onRefreshSections: (state.isBusy || state.isLoadingSections)
                    ? null
                    : _refreshSections,
                onToggleSection:
                    state.isLoadingSections ? null : _toggleSection,
                onDisconnect: state.isBusy ? null : _disconnect,
              )
            else
              _buildForm(state),
            if (state.errorMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.errorMessage!, isError: true),
            ] else if (state.statusMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.statusMessage!, isError: false),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildForm(PlexSettingsState state) {
    final bool busy = state.isBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _urlController,
          enabled: !busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'http://192.168.1.10:32400',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _tokenController,
          enabled: !busy,
          obscureText: _obscureToken,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_canSubmit && !busy) ? (_) => _connect() : null,
          decoration: InputDecoration(
            labelText: 'Plex token',
            prefixIcon: const Icon(Icons.key_outlined),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureToken
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              tooltip: _obscureToken ? 'Show token' : 'Hide token',
              onPressed: () => setState(() => _obscureToken = !_obscureToken),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: (_canSubmit && !busy) ? _test : null,
                child: _ButtonLabel(
                  label: 'Test connection',
                  busy: state.phase == PlexConnectionPhase.testing,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton(
                onPressed: (_canSubmit && !busy) ? _connect : null,
                child: _ButtonLabel(
                  label: 'Connect',
                  busy: state.phase == PlexConnectionPhase.connecting,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Marks the whole card as a phase-1 work-in-progress, so nobody mistakes
/// Plex for a finished provider while caching/favorites/lyrics/cast are still
/// follow-ups (docs/plex.md → Out of scope).
class _ExperimentalBadge extends StatelessWidget {
  const _ExperimentalBadge();

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
        'Experimental',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// Capability-based action chips: one per ability the Plex provider actually
/// supports, so unimplemented actions (offline, favorites, lyrics, cast)
/// simply don't appear rather than being offered and failing. Phase 1 shows
/// only Streaming.
class _CapabilityChips extends StatelessWidget {
  const _CapabilityChips();

  @override
  Widget build(BuildContext context) {
    final MusicProviderCapabilities caps = MusicProviders.plex.capabilities;
    final List<({IconData icon, String label})> supported = [
      if (caps.canStream) (icon: Icons.play_circle_outline, label: 'Streaming'),
      if (caps.canCache)
        (icon: Icons.download_for_offline_outlined, label: 'Offline'),
      if (caps.canCast) (icon: Icons.cast, label: 'Cast'),
      if (caps.canFavoriteTracks)
        (icon: Icons.favorite_border, label: 'Favorites'),
      if (caps.canLyrics) (icon: Icons.lyrics_outlined, label: 'Lyrics'),
    ];
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        for (final cap in supported)
          Chip(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            avatar: Icon(cap.icon, size: 16),
            label: Text(cap.label),
          ),
      ],
    );
  }
}

/// The connected view: which server, the music-library picker, and disconnect.
///
/// Shows only server metadata — never the token.
class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.state,
    required this.onRefreshSections,
    required this.onToggleSection,
    required this.onDisconnect,
  });

  final PlexSettingsState state;
  final VoidCallback? onRefreshSections;
  final void Function(String key, bool included)? onToggleSection;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state.displayName, style: theme.textTheme.titleSmall),
                  if (state.baseUrl != null)
                    Text(
                      state.baseUrl!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  if (state.serverVersion != null &&
                      state.serverVersion!.isNotEmpty)
                    Text(
                      'Plex Media Server ${state.serverVersion}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: Text('Music libraries', style: theme.textTheme.titleSmall),
            ),
            IconButton(
              onPressed: onRefreshSections,
              tooltip: 'Refresh libraries',
              icon: const Icon(Icons.refresh_outlined),
            ),
          ],
        ),
        Text(
          'Choose which Plex music libraries Linthra plays from.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (state.isLoadingSections)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (state.sections.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(
              'No music libraries found on this server.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          )
        else ...[
          for (final PlexLibrarySection section in state.sections)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(section.title),
              value: state.selectedSectionKeys.contains(section.key),
              onChanged: onToggleSection == null
                  ? null
                  : (bool? included) =>
                      onToggleSection!(section.key, included ?? false),
            ),
          if (state.selectedSectionKeys.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'No libraries selected yet — select at least one to play '
                'its music.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: onDisconnect,
          icon: const Icon(Icons.logout_outlined),
          label: const Text('Disconnect Plex'),
        ),
      ],
    );
  }
}

/// A button label that swaps to a small spinner while its action runs.
class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel({required this.label, required this.busy});

  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (!busy) {
      return Text(label);
    }
    return const SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

/// A friendly one-line status or error message under the form.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color =
        isError ? theme.colorScheme.error : theme.colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isError ? Icons.error_outline : Icons.info_outline,
          size: 18,
          color: color,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
