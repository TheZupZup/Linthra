import 'dart:async';

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

  static const EdgeInsets _pad = EdgeInsets.fromLTRB(
    AppSpacing.lg,
    AppSpacing.sm,
    AppSpacing.lg,
    AppSpacing.xl,
  );

  final CastState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!state.isAvailable) {
      return const Padding(
        padding: _pad,
        child: EmptyState(
          icon: Icons.cast,
          title: 'Casting isn\'t available here',
          message: 'Streaming to Chromecast needs Android or iOS. The control '
              'is here; pick a device on a supported platform to cast.',
        ),
      );
    }

    if (state.hasError) {
      final service = ref.read(castServiceProvider);
      return Padding(
        padding: _pad,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyState(
              icon: Icons.cast,
              title: 'No cast devices',
              message: state.message ??
                  'Make sure a cast device is on the same Wi-Fi network.',
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: service.startDiscovery,
              icon: const Icon(Icons.refresh),
              label: const Text('Search again'),
            ),
          ],
        ),
      );
    }

    if (state.isConnecting) {
      final String name = state.connectedDevice?.name ?? 'device';
      return Padding(
        padding: _pad,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.md),
            const CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Connecting to $name…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    final devices = state.devices;
    if (devices.isEmpty) {
      if (state.isDiscovering) {
        return const Padding(
          padding: _pad,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: AppSpacing.md),
              CircularProgressIndicator(),
              SizedBox(height: AppSpacing.md),
              Text('Searching for devices…', textAlign: TextAlign.center),
            ],
          ),
        );
      }
      return const Padding(
        padding: _pad,
        child: EmptyState(
          icon: Icons.cast,
          title: 'No devices found',
          message: 'Make sure a cast device is on the same Wi-Fi network.',
        ),
      );
    }

    final service = ref.read(castServiceProvider);
    return ListView(
      shrinkWrap: true,
      children: [
        // A non-fatal notice while connected (e.g. the current track is a local
        // file that can't be cast).
        if (state.isConnected && state.message != null)
          _Notice(message: state.message!),
        // Cast device volume — only while connected, since it controls the
        // receiver's own volume (not the phone's).
        if (state.isConnected)
          CastVolumeControls(state: state, service: service),
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

/// Cast device volume controls, shown in the sheet while connected.
///
/// Drives the receiver's *own* volume entirely through [CastService] — never a
/// cast SDK directly — so a command failure can't break playback (the service
/// swallows it and surfaces a calm notice). It follows live volume updates from
/// [CastState] (which the sheet watches) while tracking the in-progress drag
/// locally, mirroring the now-playing seek bar. When the device doesn't support
/// volume control ([CastState.supportsVolumeControl] false) the slider and mute
/// are disabled with an honest note rather than hidden, so the section stays
/// stable.
class CastVolumeControls extends StatefulWidget {
  const CastVolumeControls({
    required this.state,
    required this.service,
    super.key,
  });

  final CastState state;
  final CastService service;

  @override
  State<CastVolumeControls> createState() => _CastVolumeControlsState();
}

class _CastVolumeControlsState extends State<CastVolumeControls> {
  /// The in-progress drag level (0–1), or null when not dragging — so live
  /// device updates don't fight the user's finger.
  double? _dragValue;

  void _onChanged(double value) => setState(() => _dragValue = value);

  void _onChangeEnd(double value) {
    unawaited(widget.service.setVolume(value));
    setState(() => _dragValue = null);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool supported = widget.state.supportsVolumeControl;
    final bool muted = widget.state.muted;
    final double level = (widget.state.volume ?? 0.0).clamp(0.0, 1.0);
    // While muted, show the slider at zero so the visual matches what's heard.
    final double effective = muted ? 0.0 : level;
    final double sliderValue = _dragValue ?? effective;

    final Color muteColor = supported
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Cast volume',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: supported
                    ? () => unawaited(widget.service.setMuted(!muted))
                    : null,
                color: muteColor,
                icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
                tooltip: muted ? 'Unmute' : 'Mute',
              ),
              Expanded(
                child: Slider(
                  value: sliderValue,
                  onChanged: supported ? _onChanged : null,
                  onChangeEnd: supported ? _onChangeEnd : null,
                ),
              ),
            ],
          ),
          if (!supported)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: Text(
                "This device doesn't support volume control from Linthra.",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A calm inline banner for a non-fatal cast notice (e.g. the local-file
/// casting limitation) shown above the device list while connected.
class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
