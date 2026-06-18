import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../app/external_link_launcher_provider.dart';
import '../../../core/app_info.dart';
import 'app_info_report.dart';
import 'bug_report_email.dart';

/// The "Support" card on the About page: a one-line description of what Linthra
/// is, a tester-friendly "Report a bug" action, a "Copy app info" action, the
/// support inbox, and a link to the privacy policy.
///
/// "Report a bug" and "Email support" open the user's mail app through a
/// `mailto:` link (the bug action prefills a recipient, subject, and a fill-in
/// body for Google Play closed testers); the privacy policy opens in the
/// browser. All go through the shared [externalLinkLauncherProvider] — the same
/// seam the rest of the About page and the diagnostics "Report a bug" flow use —
/// so every launch is an explicit tap and widget tests stay plugin-free.
///
/// "Copy app info" is kept separate from the email flow: it copies a short,
/// paste-ready app-info block (built by [AppInfoReport]) to the clipboard and
/// confirms with a snackbar. It sends nothing and collects no personal data —
/// only the app version and, on Android, the OS version, with blank prompts the
/// tester fills in.
class SupportSection extends ConsumerWidget {
  const SupportSection({super.key});

  /// One-line description of the app, shown above the support links.
  static const String _description =
      'Open-source music player for local and self-hosted libraries.';

  /// Where support and privacy questions go (also the contact in PRIVACY.md).
  static const String _supportEmail = 'support@linthra.ca';

  /// The privacy policy, served from the repository — the same `blob/main` form
  /// the License link on this page uses, so it tracks the released branch.
  static const String _privacyPolicyUrl =
      'https://github.com/thezupzup/linthra/blob/main/PRIVACY.md';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.support_agent_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text('Support', style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _description,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          const Divider(height: 0),
          _SupportRow(
            icon: Icons.bug_report_outlined,
            label: 'Report a bug',
            value: 'Email us a prefilled report',
            onTap: () => _open(context, ref, BugReportEmail.mailtoUri()),
          ),
          const Divider(height: 0),
          _SupportRow(
            icon: Icons.info_outline,
            label: 'Copy app info',
            value: 'Version & device details for a bug report',
            trailingIcon: Icons.copy_outlined,
            onTap: () => _copyAppInfo(context),
          ),
          const Divider(height: 0),
          _SupportRow(
            icon: Icons.mail_outline,
            label: 'Email support',
            value: _supportEmail,
            onTap: () => _open(
              context,
              ref,
              Uri(scheme: 'mailto', path: _supportEmail),
            ),
          ),
          const Divider(height: 0),
          _SupportRow(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy policy',
            onTap: () => _open(context, ref, Uri.parse(_privacyPolicyUrl)),
          ),
        ],
      ),
    );
  }

  /// Opens [url] through the shared launcher, falling back to a snackbar if the
  /// platform can't (the launcher never throws). The messenger is captured
  /// before the await so we don't touch [context] across an async gap — the same
  /// guard the About page's own link rows use.
  Future<void> _open(BuildContext context, WidgetRef ref, Uri url) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool launched =
        await ref.read(externalLinkLauncherProvider).open(url);
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the link.")),
      );
    }
  }

  /// Copies a short, paste-ready app-info block to the clipboard and confirms
  /// with a snackbar — the low-friction path for a tester to attach useful
  /// details to a bug report. The block is assembled by [AppInfoReport] from the
  /// app version and, on Android, the OS version; nothing is sent and no
  /// personal data, server URL, token, username, or path is included. The
  /// messenger is captured before the await so we don't touch [context] across
  /// an async gap — the same guard the link rows use.
  Future<void> _copyAppInfo(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String info = AppInfoReport.build(
      linthraVersion: AppInfo.version,
      androidVersion:
          Platform.isAndroid ? Platform.operatingSystemVersion : null,
    );
    await Clipboard.setData(ClipboardData(text: info));
    messenger.showSnackBar(
      const SnackBar(content: Text('App info copied to the clipboard.')),
    );
  }
}

/// A single tappable row in the support card: a leading icon, a label, and a
/// trailing affordance ([trailingIcon], the "opens externally" arrow by
/// default; the copy row overrides it with a copy glyph). An optional [value]
/// (e.g. the support address) is shown as a subtitle so the detail is visible
/// without tapping.
class _SupportRow extends StatelessWidget {
  const _SupportRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.trailingIcon = Icons.open_in_new,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? value;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label),
      subtitle: value == null ? null : Text(value!),
      trailing: trailingIcon == null
          ? null
          : Icon(trailingIcon, size: 18, color: muted),
      onTap: onTap,
    );
  }
}
