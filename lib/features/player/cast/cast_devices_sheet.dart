import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/models/cast_state.dart';
import '../../../core/services/cast/cast_service.dart';
import '../../../data/repositories/cast_receiver_pin_store_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import 'cast_providers.dart';

/// The cast target picker, opened from the now-playing [CastButton].
///
/// It renders honestly from [castStateProvider]: when casting is unavailable it
/// shows a calm explanation rather than an empty or fake device list — the
/// platform has no backend, or (with a [CastState.message]) casting is
/// temporarily withheld by the security containment.
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
      // A carried message means casting is off for a reason of its own (the
      // security containment) rather than unsupported by the platform, so it
      // replaces the platform copy: telling an Android user to "try a supported
      // platform" would be untrue and unhelpful.
      final String? reason = state.message;
      return Padding(
        padding: _pad,
        child: EmptyState(
          icon: Icons.cast,
          title: reason != null
              ? 'Casting is temporarily unavailable'
              : 'Casting isn\'t available here',
          message: reason ??
              'Streaming to Chromecast needs Android or iOS. The control '
                  'is here; pick a device on a supported platform to cast.',
        ),
      );
    }

    if (state.hasError) {
      // A failed connection keeps the list the device was picked from, because
      // the list is where the user acts next. It is the retry, and for
      // [CastTrustFailureKind.changedReceiver] it is also the recovery: that
      // refusal tells the user to forget the device "in the cast list", so
      // replacing the list with an empty state would take away the one place
      // the message points at. Discovery failing with nothing found still lands
      // on the empty state below.
      if (state.devices.isNotEmpty) {
        return const _DeviceList();
      }
      final CastService service = ref.read(castServiceProvider);
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

    return const _DeviceList();
  }
}

/// The discovered devices, plus whatever note the current state carries.
///
/// Shared by the ordinary listing and by the error state, which keeps its list
/// (see [_Body]) so a refusal can be acted on where it was caused.
class _DeviceList extends ConsumerWidget {
  const _DeviceList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CastService service = ref.watch(castServiceProvider);
    final CastState state =
        ref.watch(castStateProvider).valueOrNull ?? service.state;

    return ListView(
      shrinkWrap: true,
      children: [
        // Whatever the state has to say, above the list it is about: a
        // non-fatal notice while connected (the current track is a local file
        // that can't be cast), or the reason the last connection was refused.
        if (state.message != null) _Notice(message: state.message!),
        // Cast device volume, only while connected, since it controls the
        // receiver's own volume (not the phone's).
        if (state.isConnected)
          CastVolumeControls(state: state, service: service),
        for (final CastDevice device in state.devices)
          _DeviceTile(
            device: device,
            isConnected: state.connectedDevice == device,
            service: service,
          ),
      ],
    );
  }
}

/// One discovered device, and the two things that can be done to it: connect or
/// disconnect, and forget which receiver it is.
///
/// Stateful so the forget flow can check [mounted] after its confirmation
/// dialog and its store write, rather than touching a context or a ref that may
/// have gone away while the sheet was dismissed.
class _DeviceTile extends ConsumerStatefulWidget {
  const _DeviceTile({
    required this.device,
    required this.isConnected,
    required this.service,
  });

  final CastDevice device;
  final bool isConnected;
  final CastService service;

  @override
  ConsumerState<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends ConsumerState<_DeviceTile> {
  /// Clears what Linthra remembers about which receiver this device is.
  ///
  /// This is the only path that may drop a pin. It weakens a check the user
  /// cannot see (the next connection trusts whichever receiver answers, exactly
  /// as a first use does), so it is confirmed rather than done on a tap, and
  /// the dialog says what it costs. Nothing in the trust path calls this: see
  /// [CastReceiverPinStore.forget] and docs/cast-hardened-design.md.
  Future<void> _forget() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String name = widget.device.name;

    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Forget this device?'),
            content: Text(
              "Linthra will stop checking that $name is the same device it "
              'cast to before, and will trust whichever device answers to that '
              'name next time. Do this if you replaced it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Forget'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    try {
      await ref.read(castReceiverPinStoreProvider).forget(widget.device.id);
    } catch (_) {
      // A store that could not drop the pin has not dropped it, and the user
      // would otherwise reconnect into the same refusal with no idea why.
      messenger.showSnackBar(
        SnackBar(content: Text("Linthra couldn't forget $name.")),
      );
      return;
    }
    if (!mounted) return;

    ref.invalidate(castDeviceIsPinnedProvider(widget.device.id));
    messenger.showSnackBar(
      SnackBar(
          content: Text('Linthra will check $name again when it connects.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Only offered where there is something to forget, and only while
    // disconnected: dropping the pin for the receiver currently playing would
    // do nothing to the live session, which already proved itself, and would
    // read as if it had.
    final bool canForget = !widget.isConnected &&
        (ref.watch(castDeviceIsPinnedProvider(widget.device.id)).valueOrNull ??
            false);

    return ListTile(
      // The connected row is deliberately not tappable (there is nothing to
      // connect to twice). Marking it selected is what makes that read as
      // "this is the one you're on" rather than as an inert row, and the glyph
      // says the same thing for anyone who only hears the leading icon.
      selected: widget.isConnected,
      leading: Icon(
        widget.isConnected ? Icons.cast_connected : Icons.cast,
        semanticLabel: widget.isConnected ? 'Connected' : null,
      ),
      title: Text(widget.device.name),
      trailing: widget.isConnected
          ? TextButton(
              onPressed: widget.service.disconnect,
              child: const Text('Disconnect'),
            )
          : canForget
              ? PopupMenuButton<void>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'More options for ${widget.device.name}',
                  itemBuilder: (BuildContext context) => [
                    PopupMenuItem<void>(
                      onTap: () => unawaited(_forget()),
                      child: const Text('Forget this device'),
                    ),
                  ],
                )
              : null,
      onTap: widget.isConnected
          ? null
          : () => widget.service.connect(widget.device),
    );
  }
}

/// Cast device volume controls, shown in the sheet while connected.
///
/// Drives the receiver's *own* volume entirely through [CastService] — never a
/// cast SDK directly — so a command failure can't break playback (the service
/// swallows it and surfaces a calm notice). It follows live volume updates from
/// [CastState] (which the sheet watches) while tracking the in-progress drag
/// locally, mirroring [PlaybackProgressBar]. When the device doesn't support
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
                // Selected while muted, so mute reads as the toggle it is
                // rather than as two buttons that swap places.
                isSelected: muted,
                tooltip: muted ? 'Unmute' : 'Mute',
              ),
              Expanded(
                child: Slider(
                  value: sliderValue,
                  onChanged: supported ? _onChanged : null,
                  onChangeEnd: supported ? _onChangeEnd : null,
                  // Names the slider for anyone who lands on it directly
                  // instead of reading the heading above it first. Semantics
                  // only: the value indicator `label` can also drive is shown
                  // `onlyForDiscrete`, and this slider is continuous.
                  label: 'Cast volume',
                  semanticFormatterCallback: (double value) =>
                      '${(value * 100).round()}%',
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
