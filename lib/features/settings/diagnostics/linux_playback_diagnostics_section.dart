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
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _copy,
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('Copy playback report'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _build,
                    icon: const Icon(Icons.refresh),
                    label: Text(report == null ? 'Show report' : 'Refresh'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
