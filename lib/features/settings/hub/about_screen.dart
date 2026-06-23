import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dimens.dart';
import '../../../app/external_link_launcher_provider.dart';
import '../../../app/routes.dart';
import '../../../core/app_info.dart';
import '../../../shared/widgets/linthra_logo_mark.dart';
import '../about/support_section.dart';
import '../about/whats_new_section.dart';
import 'settings_detail_scaffold.dart';

/// The "About" page of the Settings hub.
///
/// A calm brand panel (the Linthra mark, name, and tagline), the version/build
/// the app is running, and a short list of project links. The links open in the
/// browser through the shared [externalLinkLauncherProvider] — the same seam the
/// "Report a bug" flow uses — so every launch is an explicit tap and tests stay
/// plugin-free.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  static const String _repoUrl = 'https://github.com/thezupzup/linthra';
  static const String _releasesUrl =
      'https://github.com/thezupzup/linthra/releases';
  static const String _licenseUrl =
      'https://github.com/thezupzup/linthra/blob/main/LICENSE';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsDetailScaffold(
      title: 'About',
      children: <Widget>[
        const _BrandPanel(),
        const SizedBox(height: AppSpacing.md),
        const _BuildInfoCard(),
        const SizedBox(height: AppSpacing.md),
        const WhatsNewSection(),
        const SizedBox(height: AppSpacing.md),
        _SupportLinthraCard(
          onTap: () => context.push(AppRoutes.settingsSupport),
        ),
        const SizedBox(height: AppSpacing.md),
        const SupportSection(),
        const SizedBox(height: AppSpacing.md),
        _LinksCard(
          onOpenRepo: () => _open(context, ref, _repoUrl),
          onOpenReleases: () => _open(context, ref, _releasesUrl),
          onOpenLicense: () => _open(context, ref, _licenseUrl),
        ),
      ],
    );
  }

  /// Opens [url] in the browser, falling back to a snackbar if the platform
  /// can't (the launcher never throws). The messenger is captured before the
  /// await so we don't touch [context] across an async gap.
  Future<void> _open(BuildContext context, WidgetRef ref, String url) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool launched =
        await ref.read(externalLinkLauncherProvider).open(Uri.parse(url));
    if (!launched) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the link.")),
      );
    }
  }
}

/// The Linthra mark, name, and tagline — the same calm brand footer the old
/// settings screen carried, promoted to the top of the About page.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: <Widget>[
            const LinthraLogoMark(size: 48),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    AppInfo.name,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    AppInfo.tagline,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Version and build details, read from [AppInfo] (the single in-app source of
/// truth, kept in lockstep with `pubspec.yaml`).
class _BuildInfoCard extends StatelessWidget {
  const _BuildInfoCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: <Widget>[
          // AppInfo.version is a runtime getter, so this row can't be const.
          _InfoRow(
            icon: Icons.info_outline,
            label: 'Version',
            value: AppInfo.version,
          ),
          const Divider(height: 0),
          const _InfoRow(
            icon: Icons.flag_outlined,
            label: 'Release channel',
            value: 'Alpha',
          ),
        ],
      ),
    );
  }
}

/// A read-only label/value row inside the build-info card.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label),
      trailing: Text(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(color: muted),
      ),
    );
  }
}

/// A call-to-action that opens the "Support Linthra" screen.
///
/// Linthra is free and open source; supporting it is optional, so this is an
/// invitation, not a gate — every core feature works without it. It is distinct
/// from the "Support" (help/contact) card below: this one is about supporting
/// the project, that one is about getting help.
class _SupportLinthraCard extends StatelessWidget {
  const _SupportLinthraCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.favorite_outline,
          color: theme.colorScheme.primary,
        ),
        title: const Text('Support Linthra'),
        subtitle: Text(
          'Free and open source — support is optional',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        trailing: Icon(Icons.chevron_right, color: muted),
        onTap: onTap,
      ),
    );
  }
}

/// External project links, each opening in the browser.
class _LinksCard extends StatelessWidget {
  const _LinksCard({
    required this.onOpenRepo,
    required this.onOpenReleases,
    required this.onOpenLicense,
  });

  final VoidCallback onOpenRepo;
  final VoidCallback onOpenReleases;
  final VoidCallback onOpenLicense;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: <Widget>[
          _LinkRow(
            icon: Icons.code_outlined,
            label: 'Source code',
            onTap: onOpenRepo,
          ),
          const Divider(height: 0),
          _LinkRow(
            icon: Icons.new_releases_outlined,
            label: 'Releases',
            onTap: onOpenReleases,
          ),
          const Divider(height: 0),
          _LinkRow(
            icon: Icons.gavel_outlined,
            label: 'License (MPL-2.0)',
            onTap: onOpenLicense,
          ),
        ],
      ),
    );
  }
}

/// A single tappable link row inside the links card.
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label),
      trailing: Icon(Icons.open_in_new, size: 18, color: muted),
      onTap: onTap,
    );
  }
}
