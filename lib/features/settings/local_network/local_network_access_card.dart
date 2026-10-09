import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/services/local_network/local_network_access.dart';
import '../../../core/services/local_network/local_network_permission.dart';
import 'local_network_providers.dart';

/// Offers Android 17's local network access on the Connections screen, but
/// only when it matters: the permission is missing and one of the servers the
/// user set up lives on their local network. Otherwise it takes no space.
///
/// It is the one place the permission can be turned on without first trying a
/// server, which is what someone needs whose Jellyfin library went unreachable
/// after the update. Nothing is asked until they press the button.
class LocalNetworkAccessCard extends ConsumerStatefulWidget {
  const LocalNetworkAccessCard({super.key});

  @override
  ConsumerState<LocalNetworkAccessCard> createState() =>
      _LocalNetworkAccessCardState();
}

class _LocalNetworkAccessCardState extends ConsumerState<LocalNetworkAccessCard>
    with WidgetsBindingObserver {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's settings page: the answer may have changed there.
    if (state != AppLifecycleState.resumed) return;
    ref.read(localNetworkAccessProvider).onAppShown();
    ref.invalidate(localNetworkAccessNeededProvider);
  }

  Future<void> _allow(LocalNetworkPermissionStatus status) async {
    final LocalNetworkAccess access = ref.read(localNetworkAccessProvider);
    if (status == LocalNetworkPermissionStatus.permanentlyDenied) {
      await access.openAppSettings();
      return;
    }
    setState(() => _busy = true);
    try {
      await access.request();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(localNetworkAccessNeededProvider);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final LocalNetworkPermissionStatus? status =
        ref.watch(localNetworkAccessNeededProvider).valueOrNull;
    if (status == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final bool settingsOnly =
        status == LocalNetworkPermissionStatus.permanentlyDenied;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.lan_outlined, color: theme.colorScheme.error),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Local network access',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                settingsOnly
                    ? 'One of your servers is on your local network, and '
                        'Android has local network access turned off for '
                        'Linthra. Turn it on under Permissions > Nearby '
                        'devices to reach that server again. Music on this '
                        'device keeps playing either way.'
                    : 'One of your servers is on your local network. Android '
                        'needs your OK before Linthra can reach it. Linthra '
                        'only uses this to talk to the servers you set up. '
                        'Music on this device keeps playing either way.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _busy ? null : () => _allow(status),
                  child: Text(settingsOnly ? 'Open Android settings' : 'Allow'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
