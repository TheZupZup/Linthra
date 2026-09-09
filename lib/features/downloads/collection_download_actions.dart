import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/models/bulk_download_summary.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_downloader.dart';
import '../../shared/widgets/confirm_dialog.dart';
import 'bulk_download_controller.dart';

/// A batch this size is worth a second sentence in the confirmation. Well above
/// any ordinary album, and around where a playlist stops being something a user
/// can picture the size of.
const int kLargeBulkDownloadCount = 50;

/// "Download all" for a collection the user is looking at: an album or a
/// playlist (#84).
///
/// Centralized here so the promise Linthra makes about downloads is made in one
/// place: a bulk download is always **explicit**. It is offered only where the
/// user has a specific album or playlist open, it always asks first with the
/// exact number of songs named, and it starts nothing until they say yes. There
/// is deliberately no "download everything" entry point anywhere, so the whole
/// library can never be pulled down by one stray tap.
///
/// The work itself is not done here: the shared controller runs the batch
/// through the existing download repository, which keeps the Wi-Fi/mobile-data
/// policy, the cache limit, pinned downloads and per-track progress exactly as
/// they are for a single track.
abstract final class CollectionDownloadActions {
  /// Confirms, then downloads every track in [tracks] for offline use.
  ///
  /// Returns whether a batch was started (false when the user cancelled, the
  /// collection is empty, or another batch is already running).
  static Future<bool> downloadAll(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required List<Track> tracks,
  }) async {
    // Count what will actually be requested, not the raw list: a playlist can
    // hold the same song twice, and the batch downloads it once. Confirming "3
    // songs" and then reporting on 2 would read as something having gone wrong.
    final List<Track> unique = BulkDownloader.uniqueTracks(tracks);
    if (unique.isEmpty) return false;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // Only to offer "View" on the started snackbar; a host without a router
    // (a test harness, or a screen shown outside the app shell) simply gets the
    // message without the shortcut rather than an error.
    final GoRouter? router = GoRouter.maybeOf(context);
    final BulkDownloadController controller =
        ref.read(bulkDownloadControllerProvider.notifier);

    if (controller.isRunning) {
      // Replace whatever is showing (usually the running batch's own "started"
      // line) so the answer to the tap the user just made is the one on screen.
      messenger
        ..removeCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text(_busyMessage)),
        );
      return false;
    }

    final bool confirmed = await showConfirmDialog(
      context,
      title: 'Download all',
      message: _confirmMessage(label, unique.length),
      confirmLabel: 'Download',
      // Nothing is destroyed by downloading, so the safe default focus is the
      // action rather than Cancel.
      destructive: false,
    );
    if (!confirmed) return false;

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          unique.length == 1
              ? 'Downloading 1 song from “$label”.'
              : 'Downloading ${unique.length} songs from “$label”.',
        ),
        action: router == null
            ? null
            : SnackBarAction(
                label: 'View',
                onPressed: () => router.push(AppRoutes.downloads),
              ),
      ),
    );

    // A batch that another screen started between the confirmation and here is
    // refused by the controller; say so rather than leaving the "downloading"
    // line up for work that never started.
    BulkDownloadSummary? summary;
    String message;
    try {
      summary = await controller.start(label: label, tracks: tracks);
      message = summary?.completionMessage ?? _busyMessage;
    } catch (_) {
      // Individual track failures are already handled inside the batch, so
      // reaching here means the batch itself could not run. Never surface the
      // raw error: it can carry a path or store detail.
      message = _failedMessage;
    }
    messenger
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    return summary != null;
  }

  static const String _failedMessage =
      "Couldn't start that download. Try again in a moment.";

  static const String _busyMessage =
      'Another download is still running. Wait for it to finish, or stop it on '
      'the Downloads screen.';

  static String _confirmMessage(String label, int count) {
    final String opening = count == 1
        ? 'Download 1 song from “$label” for offline listening?'
        : 'Download all $count songs from “$label” for offline listening?';
    final String policy = count == 1
        ? ' It downloads over Wi-Fi (or mobile data if you have allowed it) '
            'and counts towards your cache limit.'
        : ' They download over Wi-Fi (or mobile data if you have allowed it) '
            'and count towards your cache limit.';
    final String size = count >= kLargeBulkDownloadCount
        ? ' That is a lot of songs, so it may take a while and use a lot of '
            'storage.'
        : '';
    return '$opening$policy$size';
  }
}
