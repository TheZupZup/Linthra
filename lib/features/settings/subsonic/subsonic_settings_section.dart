import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/music_provider.dart';
import 'subsonic_settings_controller.dart';
import 'subsonic_settings_state.dart';
import 'subsonic_sync_controller.dart';
import 'subsonic_sync_state.dart';

/// The Navidrome/Subsonic connection card on the Settings screen.
///
/// Owns the text fields (URL / username / password) but nothing else: every
/// action is forwarded to [SubsonicSettingsController], and everything rendered
/// comes from [SubsonicSettingsState]. The widget never touches HTTP or storage
/// directly, and the password is cleared from memory as soon as it's used.
///
/// Subsonic's `ping` requires credentials, so both "Test connection" and "Sign
/// in" need all three fields — a successful test confirms sign-in will work.
class SubsonicSettingsSection extends ConsumerStatefulWidget {
  const SubsonicSettingsSection({super.key});

  @override
  ConsumerState<SubsonicSettingsSection> createState() =>
      _SubsonicSettingsSectionState();
}

class _SubsonicSettingsSectionState
    extends ConsumerState<SubsonicSettingsSection> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_onFieldChanged);
    _usernameController.addListener(_onFieldChanged);
    _passwordController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// All three fields are required because Subsonic authenticates `ping` itself.
  bool get _canSubmit =>
      _urlController.text.trim().isNotEmpty &&
      _usernameController.text.trim().isNotEmpty &&
      _passwordController.text.isNotEmpty;

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    await ref.read(subsonicSettingsControllerProvider.notifier).testConnection(
          url: _urlController.text,
          username: _usernameController.text,
          password: _passwordController.text,
        );
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    final bool ok =
        await ref.read(subsonicSettingsControllerProvider.notifier).signIn(
              url: _urlController.text,
              username: _usernameController.text,
              password: _passwordController.text,
            );
    // Don't keep the password in memory once it's been exchanged for a token.
    if (ok) {
      _passwordController.clear();
    }
  }

  Future<void> _signOut() async {
    await ref.read(subsonicSettingsControllerProvider.notifier).clear();
    _urlController.clear();
    _usernameController.clear();
    _passwordController.clear();
  }

  Future<void> _sync() async {
    await ref.read(subsonicSyncControllerProvider.notifier).sync();
  }

  @override
  Widget build(BuildContext context) {
    final SubsonicSettingsState state =
        ref.watch(subsonicSettingsControllerProvider);
    final SubsonicSyncState syncState =
        ref.watch(subsonicSyncControllerProvider);
    final ThemeData theme = Theme.of(context);

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
                Text('Navidrome / Subsonic',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Stream from your own Navidrome or other Subsonic-compatible '
              'server, including one behind an HTTPS reverse proxy. Your '
              'password is never stored — only a derived token is kept.',
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
                syncState: syncState,
                onSync: (state.isBusy || syncState.isSyncing) ? null : _sync,
                onSignOut:
                    (state.isBusy || syncState.isSyncing) ? null : _signOut,
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

  Widget _buildForm(SubsonicSettingsState state) {
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
            hintText: 'https://music.example.com',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _usernameController,
          enabled: !busy,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _passwordController,
          enabled: !busy,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_canSubmit && !busy) ? (_) => _signIn() : null,
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
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
                  busy: state.phase == SubsonicConnectionPhase.testing,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton(
                onPressed: (_canSubmit && !busy) ? _signIn : null,
                child: _ButtonLabel(
                  label: 'Sign in',
                  busy: state.phase == SubsonicConnectionPhase.signingIn,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Capability-based action chips: one per ability the Subsonic provider
/// actually supports, so unimplemented actions (favorites, lyrics) simply don't
/// appear rather than being offered and failing.
class _CapabilityChips extends StatelessWidget {
  const _CapabilityChips();

  @override
  Widget build(BuildContext context) {
    final MusicProviderCapabilities caps = MusicProviders.subsonic.capabilities;
    final List<({IconData icon, String label})> supported = [
      if (caps.canStream) (icon: Icons.play_circle_outline, label: 'Streaming'),
      if (caps.canCache)
        (icon: Icons.download_for_offline_outlined, label: 'Offline'),
      if (caps.canCast) (icon: Icons.cast, label: 'Cast'),
      if (caps.canFavorite) (icon: Icons.favorite_border, label: 'Favorites'),
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

/// The summary shown once a session exists: which server/user, plus the sync
/// action and sign-out.
class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.state,
    required this.syncState,
    required this.onSync,
    required this.onSignOut,
  });

  final SubsonicSettingsState state;
  final SubsonicSyncState syncState;
  final VoidCallback? onSync;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
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
                  Text(state.productLabel, style: theme.textTheme.titleSmall),
                  if (state.username != null && state.username!.isNotEmpty)
                    Text(
                      'Signed in as ${state.username}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (state.baseUrl != null)
                    Text(
                      state.baseUrl!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  if (state.serverVersion != null &&
                      state.serverVersion!.isNotEmpty)
                    Text(
                      '${state.productLabel} ${state.serverVersion}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.tonalIcon(
          onPressed: onSync,
          icon: syncState.isSyncing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync_outlined),
          label:
              Text(syncState.isSyncing ? 'Syncing…' : 'Sync Navidrome library'),
        ),
        if (syncState.message != null && !syncState.isSyncing) ...[
          const SizedBox(height: AppSpacing.sm),
          _StatusLine(message: syncState.message!, isError: syncState.isError),
        ],
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: onSignOut,
          icon: const Icon(Icons.logout_outlined),
          label: const Text('Sign out & clear'),
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
