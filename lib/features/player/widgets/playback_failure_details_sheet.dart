import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../core/diagnostics/playback_failure_report.dart';
import '../../../core/models/playback_failure.dart';
import '../../../core/models/track.dart';
import '../playback_failure_details_providers.dart';
import 'playback_error_notice.dart';

/// What the error panel's Details opens: the problem in a few more words than
/// the panel has room for, what the source's last check found, what Linthra
/// already tried, what to do next, and a report to copy into a bug report.
///
/// A sheet rather than a dialog, so it is dismissed like any other and the app
/// behind it stays what it was. It only reads: every recovery stays on the
/// panel, run by the playback controller, so opening this changes nothing
/// about playback.
class PlaybackFailureDetailsSheet extends ConsumerStatefulWidget {
  const PlaybackFailureDetailsSheet({
    required this.details,
    this.track,
    super.key,
  });

  final PlaybackFailureDetails details;

  /// The track that failed, for the report's hashed track id.
  final Track? track;

  static const ValueKey<String> sheetKey =
      ValueKey<String>('playback-failure-details');
  static const ValueKey<String> copyKey =
      ValueKey<String>('playback-failure-copy-diagnostics');

  /// Opens the details of [failure] on [track], worked out as of now.
  static Future<void> show(
    BuildContext context,
    WidgetRef ref,
    PlaybackFailure failure,
    Track? track,
  ) {
    final PlaybackFailureDetails details =
        ref.read(playbackFailureDetailsBuilderProvider)(failure, track);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (BuildContext context) =>
          PlaybackFailureDetailsSheet(details: details, track: track),
    );
  }

  @override
  ConsumerState<PlaybackFailureDetailsSheet> createState() =>
      _PlaybackFailureDetailsSheetState();
}

enum _CopyOutcome { copied, failed }

class _PlaybackFailureDetailsSheetState
    extends ConsumerState<PlaybackFailureDetailsSheet> {
  bool _copying = false;
  _CopyOutcome? _outcome;

  Future<void> _copy() async {
    if (_copying) return;
    setState(() => _copying = true);
    _CopyOutcome outcome;
    try {
      final String report = await ref.read(
          playbackFailureReportBuilderProvider)(widget.details, widget.track);
      await Clipboard.setData(ClipboardData(text: report));
      outcome = _CopyOutcome.copied;
    } catch (_) {
      outcome = _CopyOutcome.failed;
    }
    if (!mounted) return;
    setState(() {
      _copying = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PlaybackFailureDetails details = widget.details;
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final String? source = details.sourceName;
    final _CopyOutcome? outcome = _outcome;

    return SingleChildScrollView(
      key: PlaybackFailureDetailsSheet.sheetKey,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(PlaybackErrorNotice.iconFor(details.failure.kind),
                  color: theme.colorScheme.error),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(details.title, style: theme.textTheme.titleLarge),
                ),
              ),
            ],
          ),
          if (source != null) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text('Source: $source',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(details.explanation, style: theme.textTheme.bodyMedium),
          for (final String? line in <String?>[
            details.sourceState,
            details.attempted,
          ])
            if (line != null) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              Text(line, style: theme.textTheme.bodyMedium),
            ],
          const SizedBox(height: AppSpacing.md),
          Semantics(
            header: true,
            child: Text('What you can do', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(details.nextStep, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.tonalIcon(
            key: PlaybackFailureDetailsSheet.copyKey,
            onPressed: _copying ? null : _copy,
            icon: Icon(outcome == _CopyOutcome.copied
                ? Icons.check
                : Icons.copy_outlined),
            label: const Text('Copy diagnostics'),
          ),
          const SizedBox(height: AppSpacing.xs),
          // Said where the button is rather than in a snack bar, which would
          // sit behind this sheet; and as a live region, so a screen reader
          // hears the outcome of the tap.
          Semantics(
            liveRegion: true,
            child: Text(
              switch (outcome) {
                _CopyOutcome.copied => 'Copied. Paste it into a bug report.',
                _CopyOutcome.failed => "Couldn't copy the diagnostics.",
                null => 'For a bug report: versions, what failed and the '
                    "source's state. Never passwords, tokens, server "
                    'addresses or file paths.',
              },
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
