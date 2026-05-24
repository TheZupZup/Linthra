import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cast_devices_sheet.dart';
import 'cast_providers.dart';

/// The now-playing cast affordance. Renders from [castStateProvider] and opens
/// the [CastDevicesSheet]; it never talks to a cast SDK directly.
///
/// Honest by design: with the shipped [UnavailableCastService] the button is
/// visible but muted, signalling casting is a foundation rather than live. When
/// connected it switches to the filled cast-connected glyph. Tapping always
/// opens the sheet, which states the real status for the current backend.
class CastButton extends ConsumerWidget {
  const CastButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final service = ref.watch(castServiceProvider);
    final state = ref.watch(castStateProvider).valueOrNull ?? service.state;

    final Color color;
    if (state.isConnected) {
      color = theme.colorScheme.primary;
    } else if (state.isAvailable) {
      color = theme.colorScheme.onSurface.withValues(alpha: 0.85);
    } else {
      // Unavailable: present but visibly inactive, so it never implies casting
      // works today.
      color = theme.colorScheme.onSurface.withValues(alpha: 0.38);
    }

    return IconButton(
      onPressed: () => _openSheet(context),
      icon: Icon(state.isConnected ? Icons.cast_connected : Icons.cast),
      color: color,
      isSelected: state.isConnected,
      tooltip: state.isAvailable ? 'Cast' : 'Cast (coming soon)',
    );
  }

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const CastDevicesSheet(),
    );
  }
}
