import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/platform/host_platform.dart';
import '../../../data/repositories/host_platform_provider.dart';
import 'linux_playback_diagnostics_collector.dart';

/// The "Linux playback" card on Settings ▸ Diagnostics & support.
///
/// Shows what a contributor needs to debug native audio on a machine they do
/// not have — which backend is playing, whether libmpv answered and at what
/// version, which output subsystem is selected, and what has been failing —
/// and lets the listener copy it straight into a GitHub issue.
///
/// Linux only. Off Linux it renders nothing rather than a card full of "not
/// applicable", exactly like the Audio output card, and the Android
/// diagnostics card beside it is unchanged.
///
/// Nothing here can leak: the text is assembled by
/// [LinuxPlaybackDiagnosticsCollector] from a snapshot whose every field is an
/// enum, a bool, an int or a sanitised version string. There is no field for a
/// stream URL, a token, a header, a device node name or a raw backend error.
class LinuxPlaybackDiagnosticsSection extends ConsumerStatefulWidget {
  const LinuxPlaybackDiagnosticsSection({super.key});

  @override
  ConsumerState<LinuxPlaybackDiagnosticsSection> createState() =>
      _LinuxPlaybackDiagnosticsSectionState();
}

class _LinuxPlaybackDiagnosticsSectionState
    extends ConsumerState<LinuxPlaybackDiagnosticsSection> {
  bool _busy = false;
  String? _report;

  Future<String?> _build() async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final String report =
          await ref.read(linuxPlaybackDiagnosticsReportProvider)();
      if (mounted) setState(() => _report = report);
      return report;
    } catch (_) {
      // A backend that will not answer must not leave the user staring at an
      // error: the collector already degrades to "not probed", so anything
      // reaching here is unexpected and still not worth a dialog.
      if (mounted) {
        setState(() => _report = null);
        _showSnack("Couldn't read the playback backend just now.");
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final String? report = _report ?? await _build();
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report));
    _showSnack(
        'Playback diagnostics copied (no URLs, tokens or device names).');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(hostPlatformProvider) != HostPlatform.linux) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String? report = _report;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.speaker_notes_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Linux playback',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'What Linthra is playing through on this machine: the backend, '
              'libmpv, the selected output and anything that has been failing. '
              'It carries no stream URLs, tokens, headers or device names — '
              'only the audio subsystem and the kind of output.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.md),
            if (report != null) ...<Widget>[
              _ReportBox(report: report),
              const SizedBox(height: AppSpacing.md),
            ],
            _Actions(
              copy: FilledButton.tonalIcon(
                onPressed: _busy ? null : _copy,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy playback report'),
              ),
              show: OutlinedButton.icon(
                onPressed: _busy ? null : _build,
                icon: const Icon(Icons.refresh),
                label: Text(report == null ? 'Show report' : 'Refresh'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The card's two actions, side by side when there is room and stacked when
/// there is not.
///
/// Side by side, each button gets half of a card that can be as narrow as the
/// Linux window's 420 px minimum — about 170 px. "Copy playback report" does
/// not fit that at a large text scale: it wraps onto four lines and the button
/// grows to several times its normal height. Nothing overflows, but a listener
/// who needs 2× text is exactly the listener who should not be given the worst
/// version of the layout. Below [_stackBelow] the buttons take the full width
/// one above the other instead, where the label fits on one or two lines.
class _Actions extends StatelessWidget {
  const _Actions({required this.copy, required this.show});

  final Widget copy;
  final Widget show;

  /// Narrower than this and two buttons in a row stop being readable. Measured
  /// against the longest label at the largest supported text scale, not picked
  /// from a breakpoint table: it is a property of these two buttons.
  static const double _stackBelow = 420;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Scaled text needs proportionally more room, so the threshold moves
        // with it: at 2x, a 500 px card is as tight as a 250 px one at 1x.
        final double scaled =
            MediaQuery.textScalerOf(context).scale(_stackBelow);
        if (constraints.maxWidth >= scaled) {
          return Row(
            children: <Widget>[
              Expanded(child: copy),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: show),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            copy,
            const SizedBox(height: AppSpacing.sm),
            show,
          ],
        );
      },
    );
  }
}

/// The report itself, selectable so a listener can grab one line of it as well
/// as copy the whole thing.
class _ReportBox extends StatelessWidget {
  const _ReportBox({required this.report});

  final String report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SelectableText(
        report,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }
}
