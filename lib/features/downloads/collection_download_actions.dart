import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/models/bulk_download_summary.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_downloader.dart';
import '../../core/services/remote_track_downloader.dart';
import '../../data/repositories/download_repository_provider.dart';
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
    // Only the songs that actually stream from a server, deduplicated. A
    // playlist can hold the same song twice, and a mixed collection can hold
    // on-device files, whose rows deliberately offer no offline action: sending
    // those to the batch would list them as downloads for bytes already on
    // disk. Filtering here also means the number the user is shown is the
    // number the batch works on.
    final RemoteTrackDownloader downloader =
        ref.read(remoteTrackDownloaderProvider);
    final List<Track> unique = BulkDownloader.uniqueTracks(<Track>[
      for (final Track track in tracks)
        if (downloader.isRemote(track)) track,
    ]);
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
        // Deliberately without a number: some of the collection may already be
        // offline, so the batch works on fewer songs than the collection holds,
        // and a count here would disagree with the one on the Downloads screen.
        content: Text('Downloading “$label”.'),
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
      summary = await controller.start(label: label, tracks: unique);
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
    // "Make available offline" rather than "download all N", because songs you
    // already have offline are skipped: promising N downloads and then working
    // on fewer would read as something having gone wrong.
    final String opening = count == 1
        ? 'Make 1 song from “$label” available offline?'
        : 'Make all $count songs from “$label” available offline?';
    const String policy = ' Anything not already downloaded is fetched over '
        'Wi-Fi (or mobile data if you have allowed it) and counts towards your '
        'cache limit.';
    final String size = count >= kLargeBulkDownloadCount
        ? ' That is a lot of songs, so it may take a while and use a lot of '
            'storage.'
        : '';
    return '$opening$policy$size';
  }
}
