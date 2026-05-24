import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/cast_state.dart';
import '../../../core/services/cast/cast_service.dart';
import '../../../shared/widgets/empty_state.dart';
import 'cast_providers.dart';

/// The cast target picker, opened from the now-playing [CastButton].
///
/// It renders honestly from [castStateProvider]: when casting is unavailable
/// (the shipped default — no cast backend wired yet) it shows a calm
/// foundation/"coming soon" state rather than an empty or fake device list.
/// When a real backend lands, the same sheet lists discovered devices and lets
/// the user connect/disconnect — no UI changes needed. Discovery is started
/// while the sheet is open and stopped when it closes.
class CastDevicesSheet extends ConsumerStatefulWidget {
  const CastDevicesSheet({super.key});

  @override
  ConsumerState<CastDevicesSheet> createState() => _CastDevicesSheetState();
}

class _CastDevicesSheetState extends ConsumerState<CastDevicesSheet> {
  // Captured in initState because `ref` can't be used from dispose().
  late final CastService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(castServiceProvider);
    // Only meaningful once a real backend exists; the default service no-ops.
    if (_service.state.isAvailable) {
      // Defer so we don't kick off async work during the first build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _service.startDiscovery();
      });
    }
  }

  @override
  void dispose() {
    _service.stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = ref.watch(castServiceProvider);
    final state = ref.watch(castStateProvider).valueOrNull ?? service.state;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.cast, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Cast', style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            Flexible(child: _Body(state: state)),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.state});

  final CastState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!state.isAvailable) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        child: EmptyState(
          icon: Icons.cast,
          title: 'Casting isn\'t available yet',
          message: 'Streaming to Chromecast and other cast devices is on the '
              'roadmap. The control is here; the device handoff lands in a '
              'future update.',
        ),
      );
    }

    final service = ref.read(castServiceProvider);
    final devices = state.devices;
    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        child: EmptyState(
          icon: Icons.cast,
          title: state.isDiscovering
              ? 'Searching for devices…'
              : 'No devices found',
          message: state.isDiscovering
              ? 'Looking for cast devices on your network.'
              : 'Make sure a cast device is on the same network.',
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      children: [
        for (final device in devices)
          ListTile(
            leading: Icon(
              state.connectedDevice == device
                  ? Icons.cast_connected
                  : Icons.cast,
            ),
            title: Text(device.name),
            trailing: state.connectedDevice == device
                ? TextButton(
                    onPressed: service.disconnect,
                    child: const Text('Disconnect'),
                  )
                : null,
            onTap: state.connectedDevice == device
                ? null
                : () => service.connect(device),
          ),
      ],
    );
  }
}
