import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import 'jellyfin_settings_controller.dart';
import 'jellyfin_settings_state.dart';

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

  @override
  Widget build(BuildContext context) {
    final JellyfinSettingsState state =
        ref.watch(jellyfinSettingsControllerProvider);
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
                onSignOut: state.isBusy ? null : _signOut,
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
            border: OutlineInputBorder(),
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
            border: OutlineInputBorder(),
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
            border: const OutlineInputBorder(),
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
  const _ConnectedView({required this.state, required this.onSignOut});

  final JellyfinSettingsState state;
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
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
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
