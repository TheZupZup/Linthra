import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dimens.dart';
import '../../app/external_link_launcher_provider.dart';
import '../../core/models/github_device_authorization.dart';
import '../../core/models/github_sponsor_status.dart';
import 'github_sponsor_controller.dart';

class GitHubSponsorUnlockDialog extends ConsumerStatefulWidget {
  const GitHubSponsorUnlockDialog({
    super.key,
    required this.authorization,
  });

  final GitHubDeviceAuthorization authorization;

  @override
  ConsumerState<GitHubSponsorUnlockDialog> createState() =>
      _GitHubSponsorUnlockDialogState();
}

class _GitHubSponsorUnlockDialogState
    extends ConsumerState<GitHubSponsorUnlockDialog> {
  bool _checking = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect GitHub'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Open GitHub, enter this code, and approve Linthra. The app will '
              'then verify your active monthly sponsorship.',
            ),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: SelectableText(
                widget.authorization.userCode,
                key: const Key('github-sponsor-user-code'),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
              ),
            ),
            if (_checking) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              const LinearProgressIndicator(),
              const SizedBox(height: AppSpacing.sm),
              const Text('Waiting for GitHub authorization…'),
            ],
            if (_message != null) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              Text(
                _message!,
                key: const Key('github-sponsor-dialog-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _checking ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('github-sponsor-open-and-verify'),
          onPressed: _checking ? null : _openAndVerify,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open GitHub and verify'),
        ),
      ],
    );
  }

  Future<void> _openAndVerify() async {
    setState(() {
      _checking = true;
      _message = null;
    });

    final bool launched = await ref
        .read(externalLinkLauncherProvider)
        .open(widget.authorization.verificationUri);
    if (!launched) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _message =
            'Could not open GitHub. Open github.com/login/device manually.';
      });
      return;
    }

    final GitHubSponsorStatus status = await ref
        .read(githubSponsorControllerProvider.notifier)
        .completeAuthorization(widget.authorization);
    if (!mounted) return;

    if (status.hasActiveMonthlySponsorship) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _checking = false;
      _message = status.message ??
          'No active monthly GitHub sponsorship was found for this account.';
    });
  }
}
