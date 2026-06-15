import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/music_provider.dart';
import '../../../core/sources/plex/plex_exception.dart';
import 'plex_settings_controller.dart';
import 'plex_settings_state.dart';
import 'plex_sync_controller.dart';
import 'plex_sync_state.dart';

/// The Plex connection card on the Settings screen (experimental).
///
/// The primary path is **Connect with Plex**: a plex.tv sign-in in the
/// browser, a server picker when the account has several servers, then the
/// music-library picker — no token hunting. Manually pasting a server URL +
/// `X-Plex-Token` remains available under "Manual setup (advanced)".
///
/// The widget owns only its text fields and the advanced-section toggle:
/// every action is forwarded to [PlexSettingsController], and everything
/// rendered comes from [PlexSettingsState]. It never touches HTTP or storage.
///
/// Token safety: nothing token-shaped is ever rendered. The sign-in flow's
/// tokens never reach this widget (the state exposes display-safe
/// [PlexServerChoice]s only), and a manually pasted token is obscured while
/// typed, forwarded once to the controller, and cleared from the field the
/// moment the connection is saved — after that it is never shown again
/// anywhere (the connected view renders only server metadata).
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
  bool _showManualSetup = false;

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

  /// Both manual fields are required: Plex verifies `/identity` with the
  /// token, so a successful test confirms connecting will work.
  bool get _canSubmit =>
      _urlController.text.trim().isNotEmpty &&
      _tokenController.text.trim().isNotEmpty;

  Future<void> _connectWithPlex() async {
    await ref.read(plexSettingsControllerProvider.notifier).connectWithPlex();
  }

  Future<void> _reopenSignIn() async {
    await ref.read(plexSettingsControllerProvider.notifier).reopenPlexSignIn();
  }

  void _cancelLink() {
    ref.read(plexSettingsControllerProvider.notifier).cancelPlexLink();
  }

  Future<void> _selectServer(String clientIdentifier) async {
    await ref
        .read(plexSettingsControllerProvider.notifier)
        .selectServer(clientIdentifier);
  }

  Future<void> _selectUser(String uuid, {String? pin}) async {
    await ref
        .read(plexSettingsControllerProvider.notifier)
        .selectUser(uuid, pin: pin);
  }

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
    if (mounted) {
      setState(() => _showManualSetup = false);
    }
  }

  Future<void> _refreshSections() async {
    await ref.read(plexSettingsControllerProvider.notifier).refreshSections();
  }

  Future<void> _sync() async {
    await ref.read(plexSyncControllerProvider.notifier).sync();
  }

  void _toggleSection(String key, bool included) {
    ref
        .read(plexSettingsControllerProvider.notifier)
        .toggleSection(key, included: included);
  }

  @override
  Widget build(BuildContext context) {
    final PlexSettingsState state = ref.watch(plexSettingsControllerProvider);
    final PlexSyncState syncState = ref.watch(plexSyncControllerProvider);
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

    // The sign-in-flow views present the status line themselves (next to
    // their spinner), so the shared line at the card foot would duplicate it.
    final bool statusShownByFlowView = state.isLinkFlowActive ||
        (state.phase == PlexConnectionPhase.connecting &&
            state.servers.isNotEmpty);

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
              'Stream from your own Plex Media Server. Connect with your '
              'Plex account, pick your server, and choose which music '
              'libraries to play.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const _CapabilityChips(),
            const SizedBox(height: AppSpacing.md),
            ..._buildBody(state, syncState),
            if (state.errorMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.errorMessage!, isError: true),
              // A rejected/expired session is fixed by signing in again, not
              // by hunting for a new token — offer that right at the error.
              if (state.isConnected &&
                  state.errorKind == PlexErrorKind.unauthorized) ...[
                const SizedBox(height: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: state.isBusy ? null : _connectWithPlex,
                  icon: const Icon(Icons.link_outlined),
                  label: const Text('Reconnect with Plex'),
                ),
              ],
            ] else if (state.statusMessage != null &&
                !statusShownByFlowView) ...[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.statusMessage!, isError: false),
            ],
          ],
        ),
      ),
    );
  }

  /// The phase-dependent middle of the card.
  List<Widget> _buildBody(PlexSettingsState state, PlexSyncState syncState) {
    switch (state.phase) {
      case PlexConnectionPhase.connected:
        return [
          _ConnectedView(
            state: state,
            syncState: syncState,
            onRefreshSections: (state.isBusy || state.isLoadingSections)
                ? null
                : _refreshSections,
            onToggleSection: state.isLoadingSections ? null : _toggleSection,
            onSync:
                (state.isBusy || state.isLoadingSections || syncState.isSyncing)
                    ? null
                    : _sync,
            onDisconnect:
                (state.isBusy || syncState.isSyncing) ? null : _disconnect,
          ),
        ];
      case PlexConnectionPhase.linking:
        return [
          _LinkingView(
            statusMessage: state.statusMessage,
            onReopen: _reopenSignIn,
            onCancel: _cancelLink,
          ),
        ];
      case PlexConnectionPhase.loadingUsers:
        return [
          _FlowBusyView(
            message: state.statusMessage ?? 'Finding your Plex users…',
            onCancel: _cancelLink,
          ),
        ];
      case PlexConnectionPhase.pickingUser:
        return [
          _UserPickerView(
            users: state.users,
            onSelect: _selectUser,
            onCancel: _cancelLink,
          ),
        ];
      case PlexConnectionPhase.loadingServers:
        return [
          _FlowBusyView(
            message: state.statusMessage ?? 'Finding your Plex Media Servers…',
            onCancel: _cancelLink,
          ),
        ];
      case PlexConnectionPhase.pickingServer:
        return [
          _ServerPickerView(
            servers: state.servers,
            onSelect: _selectServer,
            onCancel: _cancelLink,
          ),
        ];
      case PlexConnectionPhase.connecting when state.servers.isNotEmpty:
        // Connecting to a picked server (the manual form shows its own
        // in-button spinner for a form connect instead).
        return [
          _FlowBusyView(
            message: state.statusMessage ?? 'Connecting to your Plex server…',
            onCancel: null,
          ),
        ];
      case PlexConnectionPhase.disconnected:
      case PlexConnectionPhase.testing:
      case PlexConnectionPhase.tested:
      case PlexConnectionPhase.connecting:
        return _buildDisconnected(state);
    }
  }

  /// The signed-out view: the primary "Connect with Plex" action, with the
  /// manual URL + token form tucked behind an Advanced toggle.
  List<Widget> _buildDisconnected(PlexSettingsState state) {
    final ThemeData theme = Theme.of(context);
    final bool busy = state.isBusy;
    return [
      FilledButton.icon(
        onPressed: busy ? null : _connectWithPlex,
        icon: const Icon(Icons.link_outlined),
        label: const Text('Connect with Plex'),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(
        'Sign in with your Plex account in the browser — no token needed. '
        'Linthra never sees your password and stores only the access '
        'token Plex grants, encrypted on this device.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      const SizedBox(height: AppSpacing.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _showManualSetup = !_showManualSetup),
          icon: Icon(
            _showManualSetup
                ? Icons.expand_less_outlined
                : Icons.expand_more_outlined,
            size: 18,
          ),
          label: const Text('Manual setup (advanced)'),
        ),
      ),
      if (_showManualSetup) ...[
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Already have an X-Plex-Token? Paste the server address and the '
          'token — it is stored encrypted on this device and never shown '
          'again.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _buildManualForm(state),
      ],
    ];
  }

  Widget _buildManualForm(PlexSettingsState state) {
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
          // Keep the token out of the keyboard's suggestion/learning store
          // even while it is momentarily revealed via the eye toggle.
          enableSuggestions: false,
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

/// Marks the whole card as a work-in-progress, so nobody mistakes Plex for a
/// finished provider while caching/favorites/lyrics/cast are still follow-ups
/// (docs/plex.md → Out of scope).
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
/// simply don't appear rather than being offered and failing.
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

/// The "waiting for the browser sign-in" view: the poll runs while the user
/// approves Linthra on plex.tv; they can re-open the page or cancel — the
/// flow never traps them.
class _LinkingView extends StatelessWidget {
  const _LinkingView({
    required this.statusMessage,
    required this.onReopen,
    required this.onCancel,
  });

  final String? statusMessage;
  final VoidCallback? onReopen;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('Waiting for your Plex sign-in…',
                  style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          statusMessage ??
              'Approve Linthra on the Plex sign-in page in your browser, '
                  'then come back here.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onReopen,
            icon: const Icon(Icons.open_in_new_outlined, size: 18),
            label: const Text('Open the sign-in page again'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// A short busy step of the sign-in flow (finding servers / connecting to
/// the picked one), optionally cancellable.
class _FlowBusyView extends StatelessWidget {
  const _FlowBusyView({required this.message, required this.onCancel});

  final String message;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(message, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
        if (onCancel != null) ...[
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}

/// The user picker: one entry per Plex Home user (profile) on the signed-in
/// account, so the person chooses whose library to use before any sync — the
/// step that keeps onboarding fast. A protected profile reveals an inline PIN
/// entry on tap; an unprotected one is picked straight away. Shows display
/// names only — never tokens (the listing has none anyway).
class _UserPickerView extends StatefulWidget {
  const _UserPickerView({
    required this.users,
    required this.onSelect,
    required this.onCancel,
  });

  final List<PlexUserChoice> users;
  final void Function(String uuid, {String? pin})? onSelect;
  final VoidCallback? onCancel;

  @override
  State<_UserPickerView> createState() => _UserPickerViewState();
}

class _UserPickerViewState extends State<_UserPickerView> {
  final TextEditingController _pinController = TextEditingController();

  /// The uuid of the protected profile currently being asked for its PIN, or
  /// `null` while the plain profile list is shown.
  String? _pinForUuid;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  void _tap(PlexUserChoice user) {
    if (user.protected) {
      _pinController.clear();
      setState(() => _pinForUuid = user.uuid);
    } else {
      widget.onSelect?.call(user.uuid);
    }
  }

  void _submitPin(String uuid) {
    final String pin = _pinController.text.trim();
    widget.onSelect?.call(uuid, pin: pin.isEmpty ? null : pin);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    final String? pinUuid = _pinForUuid;
    if (pinUuid != null) {
      final PlexUserChoice user = widget.users.firstWhere(
        (PlexUserChoice u) => u.uuid == pinUuid,
        orElse: () => PlexUserChoice(uuid: pinUuid, title: 'Plex user'),
      );
      return _PinEntry(
        title: user.title,
        controller: _pinController,
        onSubmit: widget.onSelect == null ? null : () => _submitPin(pinUuid),
        onBack: () => setState(() => _pinForUuid = null),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Choose your Plex user', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Pick the profile to use on this device — only its library is '
          'synced, so onboarding stays fast.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final PlexUserChoice user in widget.users)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              user.admin ? Icons.person_outline : Icons.people_outline,
            ),
            title: Text(user.title),
            subtitle: Text(_subtitleFor(user)),
            trailing: Icon(
              user.protected
                  ? Icons.lock_outline
                  : Icons.chevron_right_outlined,
            ),
            onTap: widget.onSelect == null ? null : () => _tap(user),
          ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: widget.onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  String _subtitleFor(PlexUserChoice user) {
    final List<String> parts = <String>[
      if (user.admin) 'Account owner' else 'Managed profile',
      if (user.protected) 'PIN protected',
    ];
    return parts.join(' · ');
  }
}

/// The inline PIN entry shown when a protected Plex Home profile is picked —
/// part of the same card, never a dialog, matching the rest of the flow.
class _PinEntry extends StatelessWidget {
  const _PinEntry({
    required this.title,
    required this.controller,
    required this.onSubmit,
    required this.onBack,
  });

  final String title;
  final TextEditingController controller;
  final VoidCallback? onSubmit;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Enter the PIN for $title', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'This Plex profile is protected — enter its PIN to switch into it.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          autocorrect: false,
          // A profile PIN is not the account token, but keep it out of the
          // keyboard's learning store anyway.
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: onSubmit == null ? null : (_) => onSubmit!(),
          decoration: const InputDecoration(
            labelText: 'Profile PIN',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onBack,
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton(
                onPressed: onSubmit,
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The server picker: one entry per Plex Media Server on the signed-in
/// account (owned ones first), with a clean empty state when the account has
/// none. Shows names and versions only — never tokens.
class _ServerPickerView extends StatelessWidget {
  const _ServerPickerView({
    required this.servers,
    required this.onSelect,
    required this.onCancel,
  });

  final List<PlexServerChoice> servers;
  final void Function(String clientIdentifier)? onSelect;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    if (servers.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('No Plex Media Server found', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            "You're signed in, but this Plex account has no Plex Media "
            'Server linked to it yet. Set up your server (or ask its owner '
            'to share it with you), then connect again.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(
            onPressed: onCancel,
            child: const Text('Back'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Choose your Plex server', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Your account can reach more than one server — pick the one with '
          'your music.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final PlexServerChoice server in servers)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: Text(server.name),
            subtitle: Text(_subtitleFor(server)),
            trailing: const Icon(Icons.chevron_right_outlined),
            onTap: onSelect == null
                ? null
                : () => onSelect!(server.clientIdentifier),
          ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  String _subtitleFor(PlexServerChoice server) {
    final List<String> parts = <String>[
      if (server.productVersion != null && server.productVersion!.isNotEmpty)
        'Plex Media Server ${server.productVersion}'
      else
        'Plex Media Server',
      if (!server.owned) 'Shared with you',
    ];
    return parts.join(' · ');
  }
}

/// The connected view: which server, the music-library picker (with explicit
/// loading / failed / empty states), the sync action, and disconnect.
///
/// Shows only server metadata — never the token.
class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.state,
    required this.syncState,
    required this.onRefreshSections,
    required this.onToggleSection,
    required this.onSync,
    required this.onDisconnect,
  });

  final PlexSettingsState state;
  final PlexSyncState syncState;
  final VoidCallback? onRefreshSections;
  final void Function(String key, bool included)? onToggleSection;
  final VoidCallback? onSync;
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Loading music libraries…',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          )
        else if (!state.sectionsLoaded)
          // The list was never fetched successfully for this connection (the
          // specific reason, e.g. "couldn't reach", is in the error line
          // below) — offer a retry instead of a misleading "no libraries".
          _PickerNotice(
            message: "Your music libraries haven't loaded yet.",
            actionLabel: 'Try again',
            onAction: onRefreshSections,
          )
        else if (state.sections.isEmpty)
          _PickerNotice(
            message: 'No music libraries found on this server. Create a '
                'music library in Plex, then refresh.',
            actionLabel: 'Refresh',
            onAction: onRefreshSections,
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
        FilledButton.tonalIcon(
          onPressed: onSync,
          icon: syncState.isSyncing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync_outlined),
          label: Text(
            syncState.isScanning
                ? 'Scanning…'
                : syncState.isWriting
                    ? 'Saving…'
                    : 'Sync Plex library',
          ),
        ),
        if (syncState.message != null && !syncState.isSyncing) ...[
          const SizedBox(height: AppSpacing.sm),
          _StatusLine(message: syncState.message!, isError: syncState.isError),
        ],
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: onDisconnect,
          icon: const Icon(Icons.logout_outlined),
          label: const Text('Disconnect Plex'),
        ),
      ],
    );
  }
}

/// A short notice inside the library-picker area with one inline action
/// (retry a failed load, or refresh an empty list).
class _PickerNotice extends StatelessWidget {
  const _PickerNotice({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh_outlined, size: 18),
              label: Text(actionLabel),
            ),
          ),
        ],
      ),
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
