import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import 'audiobookshelf_settings_controller.dart';
import 'audiobookshelf_settings_state.dart';

/// The Audiobookshelf connection card in Settings.
///
/// Owns the text fields (URL / username / password) but nothing else: every
/// action is forwarded to [AudiobookshelfSettingsController], and everything
/// rendered comes from [AudiobookshelfSettingsState]. The widget never touches
/// HTTP or storage directly, and the password is cleared from memory as soon as
/// it's used.
///
/// Unlike Subsonic, "Test connection" needs only the address: Audiobookshelf
/// answers `/status` without credentials, so the address can be checked before
/// a password is typed at all.
class AudiobookshelfSettingsSection extends ConsumerStatefulWidget {
  const AudiobookshelfSettingsSection({super.key});

  @override
  ConsumerState<AudiobookshelfSettingsSection> createState() =>
      _AudiobookshelfSettingsSectionState();
}

class _AudiobookshelfSettingsSectionState
    extends ConsumerState<AudiobookshelfSettingsSection> {
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
    // Opening the connection screen while already signed in is the natural
    // moment to list the libraries, so the card shows what the account can see
    // rather than just "connected".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_listLibrariesIfNeeded());
    });
  }

  /// Lists the libraries for a session restored from storage.
  ///
  /// It waits for that restore to finish first: on a cold open the controller
  /// is still reading the keyring, so a check made right now would see "not
  /// connected" and never list anything. A session that signed in on this
  /// screen already listed its libraries, hence the empty check.
  Future<void> _listLibrariesIfNeeded() async {
    final AudiobookshelfSettingsController controller =
        ref.read(audiobookshelfSettingsControllerProvider.notifier);
    await controller.ensureLoaded();
    if (!mounted) return;
    final AudiobookshelfSettingsState state =
        ref.read(audiobookshelfSettingsControllerProvider);
    if (state.isConnected &&
        state.libraries.isEmpty &&
        !state.isLoadingLibraries) {
      await controller.refreshLibraries();
    }
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// The address alone is enough to test; signing in also needs credentials.
  bool get _canTest => _urlController.text.trim().isNotEmpty;

  bool get _canSignIn =>
      _canTest &&
      _usernameController.text.trim().isNotEmpty &&
      _passwordController.text.isNotEmpty;

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    await ref
        .read(audiobookshelfSettingsControllerProvider.notifier)
        .testConnection(_urlController.text);
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    final bool ok = await ref
        .read(audiobookshelfSettingsControllerProvider.notifier)
        .signIn(
          url: _urlController.text,
          username: _usernameController.text,
          password: _passwordController.text,
        );
    // Don't keep the password in memory once it's been exchanged for tokens.
    if (ok) {
      _passwordController.clear();
    }
  }

  Future<void> _signOut() async {
    await ref.read(audiobookshelfSettingsControllerProvider.notifier).clear();
    _urlController.clear();
    _usernameController.clear();
    _passwordController.clear();
  }

  Future<void> _refreshLibraries() async {
    await ref
        .read(audiobookshelfSettingsControllerProvider.notifier)
        .refreshLibraries();
  }

  @override
  Widget build(BuildContext context) {
    final AudiobookshelfSettingsState state =
        ref.watch(audiobookshelfSettingsControllerProvider);
    final ThemeData theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.headphones_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Audiobookshelf', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Connect your self-hosted Audiobookshelf server to browse your '
              'audiobooks. Your password is never stored — only the sign-in '
              'token the server returns is kept, in encrypted storage. This '
              'connection is separate from your music sources.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (state.isConnected)
              _ConnectedView(
                state: state,
                onRefreshLibraries:
                    state.isLoadingLibraries ? null : _refreshLibraries,
                onSignOut: (state.isBusy || state.isLoadingLibraries)
                    ? null
                    : _signOut,
              )
            else
              _buildForm(state),
            if (state.errorMessage != null) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.errorMessage!, isError: true),
            ] else if (state.statusMessage != null) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              _StatusLine(message: state.statusMessage!, isError: false),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildForm(AudiobookshelfSettingsState state) {
    final bool busy = state.isBusy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _urlController,
          enabled: !busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://audiobooks.example.com',
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
          autocorrect: false,
          // Keep the password out of the keyboard's suggestion/learning store
          // even while it is revealed via the eye toggle.
          enableSuggestions: false,
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
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: (_canTest && !busy) ? _test : null,
                child: _ButtonLabel(
                  label: 'Test connection',
                  busy: state.phase == AudiobookshelfConnectionPhase.testing,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton(
                onPressed: (_canSignIn && !busy) ? _signIn : null,
                child: _ButtonLabel(
                  label: 'Sign in',
                  busy: state.phase == AudiobookshelfConnectionPhase.signingIn,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The summary shown once a session exists: which server/user, the libraries
/// this account can see, and sign-out.
class _ConnectedView extends StatelessWidget {
  const _ConnectedView({
    required this.state,
    required this.onRefreshLibraries,
    required this.onSignOut,
  });

  final AudiobookshelfSettingsState state;
  final VoidCallback? onRefreshLibraries;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Audiobookshelf', style: theme.textTheme.titleSmall),
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
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  if (state.serverVersion != null &&
                      state.serverVersion!.isNotEmpty)
                    Text(
                      'Server ${state.serverVersion}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _LibrariesView(state: state),
        const SizedBox(height: AppSpacing.sm),
        FilledButton.tonalIcon(
          onPressed: onRefreshLibraries,
          icon: state.isLoadingLibraries
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_outlined),
          label: Text(
            state.isLoadingLibraries
                ? 'Loading libraries…'
                : 'Refresh libraries',
          ),
        ),
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

/// The libraries this account can see, or a plain line saying there are none
/// (or none yet) rather than an ambiguous blank.
class _LibrariesView extends StatelessWidget {
  const _LibrariesView({required this.state});

  final AudiobookshelfSettingsState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    if (state.libraries.isEmpty) {
      return Text(
        state.isLoadingLibraries
            ? 'Loading your libraries…'
            : 'No libraries yet. Add one on your Audiobookshelf server, then '
                'refresh.',
        style: theme.textTheme.bodySmall?.copyWith(color: muted),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          state.libraries.length == 1
              ? '1 library'
              : '${state.libraries.length} libraries',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: <Widget>[
            for (final AudiobookshelfLibrarySummary library in state.libraries)
              Chip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: Icon(
                  library.mediaType == 'podcast'
                      ? Icons.podcasts_outlined
                      : Icons.menu_book_outlined,
                  size: 16,
                ),
                label: Text(library.name),
              ),
          ],
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
      children: <Widget>[
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
