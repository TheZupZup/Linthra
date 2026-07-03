import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/sources/jellyfin/jellyfin_server_capabilities.dart';
import '../../library/remote_library_refresher.dart';
import 'jellyfin_settings_controller.dart';
import 'jellyfin_settings_state.dart';
import 'jellyfin_sync_controller.dart';
import 'jellyfin_sync_state.dart';

/// The Jellyfin connection card on the Settings screen.
///
/// Owns the text fields (URL / username / password) but nothing else: every
/// action is forwarded to [JellyfinSettingsController], and everything rendered
/// comes from [JellyfinSettingsState]. The widget never touches HTTP or storage
/// directly, and the password is cleared from memory as soon as it's used.
class JellyfinSettingsSection extends ConsumerStatefulWidget {
  const JellyfinSettingsSection({super.key});

  @override
  ConsumerState<JellyfinSettingsSection> createState() =>
      _JellyfinSettingsSectionState();
}

class _JellyfinSettingsSectionState
    extends ConsumerState<JellyfinSettingsSection> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    // Rebuild as the user types so the Test/Sign-in buttons can enable/disable.
    _urlController.addListener(_onFieldChanged);
    _usernameController.addListener(_onFieldChanged);
    // Opening the connection screen reconciles server playlists/favourites
    // (throttled, best-effort, shared with the other providers) so they're
    // current without a manual sync.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(remoteLibraryRefresherProvider).refresh();
    });
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _canTest => _urlController.text.trim().isNotEmpty;

  bool get _canSignIn =>
      _urlController.text.trim().isNotEmpty &&
      _usernameController.text.trim().isNotEmpty;

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(jellyfinSettingsControllerProvider.notifier)
        .testConnection(_urlController.text);
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    final bool ok =
        await ref.read(jellyfinSettingsControllerProvider.notifier).signIn(
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
    await ref.read(jellyfinSettingsControllerProvider.notifier).clear();
    _urlController.clear();
    _usernameController.clear();
    _passwordController.clear();
  }

  Future<void> _sync() async {
    await ref.read(jellyfinSyncControllerProvider.notifier).sync();
  }

  /// Copies a secret-free diagnostics report to the clipboard so the user can
  /// paste it into a bug report. The report is assembled by the controller and,
  /// by construction, carries no token, password, or full authenticated URL.
  Future<void> _copyDiagnostics() async {
    final String report = ref
        .read(jellyfinSettingsControllerProvider.notifier)
        .diagnosticsReport();
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Jellyfin diagnostics copied (no password or token).'),
      ),
    );
  }

  /// Show the diagnostics action once there's something worth reporting: a live
  /// connection, a successful test, or a failure the user might want to share.
  bool _showDiagnostics(JellyfinSettingsState state) =>
      state.isConnected ||
      state.phase == JellyfinConnectionPhase.tested ||
      state.errorMessage != null;

  @override
  Widget build(BuildContext context) {
    final JellyfinSettingsState state =
        ref.watch(jellyfinSettingsControllerProvider);
    final JellyfinSyncState syncState =
        ref.watch(jellyfinSyncControllerProvider);
    final ThemeData theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Jellyfin', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Stream from your own Jellyfin music server, including one behind '
              'an HTTPS Cloudflare domain.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
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
              _buildForm(theme, state),
            if (state.errorMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.errorMessage!, isError: true),
            ] else if (state.statusMessage != null) ...[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.statusMessage!, isError: false),
            ],
            if (_showDiagnostics(state)) ...[
              const SizedBox(height: AppSpacing.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _copyDiagnostics,
                  icon: const Icon(Icons.bug_report_outlined, size: 18),
                  label: const Text('Copy Jellyfin diagnostics'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildForm(ThemeData theme, JellyfinSettingsState state) {
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
          onSubmitted: (_canSignIn && !busy) ? (_) => _signIn() : null,
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
                onPressed: (_canTest && !busy) ? _test : null,
                child: _ButtonLabel(
                  label: 'Test connection',
                  busy: state.phase == JellyfinConnectionPhase.testing,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton(
                onPressed: (_canSignIn && !busy) ? _signIn : null,
                child: _ButtonLabel(
                  label: 'Sign in',
                  busy: state.phase == JellyfinConnectionPhase.signingIn,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The summary shown once a session exists: which server/user, plus the action
/// to sign out and clear the saved settings.
class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.state,
    required this.syncState,
    required this.onSync,
    required this.onSignOut,
  });

  final JellyfinSettingsState state;
  final JellyfinSyncState syncState;
  final VoidCallback? onSync;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String title =
        (state.serverName != null && state.serverName!.isNotEmpty)
            ? state.serverName!
            : 'Connected';
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
                  Text(title, style: theme.textTheme.titleSmall),
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
                      _serverVersionLine(state),
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
        if (state.serverVersion != null &&
            jellyfinServerSupportFor(state.serverVersion) ==
                JellyfinServerSupport.untested) ...[
          const SizedBox(height: AppSpacing.sm),
          const _StatusLine(
            message: 'This Jellyfin version is older than Linthra is tested '
                'against. Streaming should still work, but is untested.',
            isError: false,
          ),
        ],
        if (state.serverVersion != null &&
            jellyfinServerSupportFor(state.serverVersion) ==
                JellyfinServerSupport.newerUntested) ...[
          const SizedBox(height: AppSpacing.sm),
          const _StatusLine(
            message: 'This is a newer major version of Jellyfin than Linthra '
                'has been tested against. Streaming should still work — please '
                'report any issues.',
            isError: false,
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // The manual "Sync library" stays available at all times (disabled only
        // while a sync is running). After sign-in the first sync starts on its
        // own down the same path, so this button doubles as the on-demand
        // refresh — and, after a failure, the retry below points back to it.
        FilledButton.tonalIcon(
          onPressed: onSync,
          icon: syncState.isSyncing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync_outlined),
          label: Text(syncState.isSyncing ? 'Syncing…' : 'Sync library'),
        ),
        if (syncState.isError) ...[
          const SizedBox(height: AppSpacing.sm),
          // Keep the connection plainly intact ("you're still signed in"), then
          // the specific, secret-free reason from the sync controller. For a
          // rejected session we frame it as "needs refreshing" and point at
          // sign-in; when the server is reachable but the library sync failed we
          // reassure the existing library is intact; every other failure is
          // transient and offers Retry.
          _StatusLine(
            message: syncState.needsSignIn
                ? "You're still signed in, but your Jellyfin session needs "
                    'refreshing.'
                : syncState.connectionOkButSyncFailed
                    ? 'Connected — the library sync didn\'t finish, but your '
                        'existing music is still available.'
                    : "Connected, but the library sync didn't finish.",
            isError: true,
          ),
          if (syncState.message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            _StatusLine(message: syncState.message!, isError: true),
          ],
          const SizedBox(height: AppSpacing.sm),
          // A rejected session won't be fixed by re-running the same sync, so
          // point at the "Sign out & clear" action below instead of a Retry
          // that would just fail again. Every other failure is transient.
          if (!syncState.needsSignIn)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onSync,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry sync'),
              ),
            ),
        ] else if (syncState.message != null) ...[
          // Syncing ("Syncing your Jellyfin library…") or the success summary
          // ("Synced N tracks…", possibly "Some items could not be synced");
          // both read as friendly status, not an error.
          const SizedBox(height: AppSpacing.sm),
          _StatusLine(message: syncState.message!, isError: false),
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

/// `Jellyfin {version}` plus the product name when the server reported one.
String _serverVersionLine(JellyfinSettingsState state) {
  final StringBuffer line = StringBuffer('Jellyfin ${state.serverVersion}');
  final String? product = state.productName;
  if (product != null && product.isNotEmpty && product != 'Jellyfin Server') {
    line.write(' · $product');
  }
  return line.toString();
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
