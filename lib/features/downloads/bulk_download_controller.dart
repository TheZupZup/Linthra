import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/bulk_download_summary.dart';
import '../../core/models/track.dart';
import '../../core/services/bulk_downloader.dart';
import '../../data/repositories/download_repository_provider.dart';

/// The service that turns a collection into per-track download requests. A
/// provider so a test can bound its outstanding requests (or swap it) without
/// reaching into the controller.
final bulkDownloaderProvider = Provider<BulkDownloader>((ref) {
  return const BulkDownloader();
});

/// The one "Download all" batch that may be running, and how far along it is.
///
/// Null when no batch has been started (or the last one was dismissed). Holds
/// only state and the stop flag: deciding what to request, what to skip and when
/// to stop is [BulkDownloader]'s job, and actually downloading is the download
/// repository's, so this stays a thin seam between the two and the UI.
///
/// One at a time, deliberately: a second "Download all" while one is running is
/// refused rather than queued, so the user always knows exactly what is being
/// downloaded and the progress line means one thing.
class BulkDownloadController extends Notifier<BulkDownloadSummary?> {
  bool _canceled = false;
  bool _disposed = false;

  /// Reserved synchronously by [start], before it awaits anything.
  ///
  /// The published state only turns "running" once the downloader has read the
  /// repository, which is an await away; two taps landing in that window would
  /// both pass a guard that only looked at the state, and run two batches over
  /// one banner and one stop flag.
  bool _starting = false;

  @override
  BulkDownloadSummary? build() {
    // A batch can outlive the widget that started it (the user navigates away
    // mid-album). Publishing into a disposed notifier would throw, so the
    // in-flight run stops publishing instead. The downloads themselves belong
    // to the repository and carry on regardless.
    ref.onDispose(() => _disposed = true);
    return null;
  }

  /// Whether a batch is working through its tracks right now.
  bool get isRunning => _starting || (state?.running ?? false);

  /// Starts a batch for [tracks], labelled with the collection's name.
  ///
  /// Returns the final summary, or null when a batch is already running (the
  /// caller tells the user rather than silently starting a second one) or the
  /// collection is empty.
  Future<BulkDownloadSummary?> start({
    required String label,
    required List<Track> tracks,
  }) async {
    if (isRunning || tracks.isEmpty) return null;
    // Claim the slot before the first await, so a second call in the same turn
    // is refused rather than racing this one.
    _starting = true;
    _canceled = false;
    try {
      final BulkDownloadSummary summary =
          await ref.read(bulkDownloaderProvider).run(
                repository: ref.read(downloadRepositoryProvider),
                label: label,
                tracks: tracks,
                isCanceled: () => _canceled,
                onProgress: _publish,
              );
      _publish(summary);
      return summary;
    } catch (_) {
      // Something below the batch failed outright (reading the durable cache,
      // say). Clear the running flag before rethrowing, or the controller would
      // stay "busy" forever and refuse every later download.
      final BulkDownloadSummary? current = state;
      if (current != null && current.running) {
        _publish(current.copyWith(running: false));
      }
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// Stops the running batch: nothing further is requested.
  ///
  /// Requests already handed to the repository finish and stay offline, since a
  /// stop never deletes what the user already has. To drop one of those, use the
  /// per-track cancel on the Downloads screen.
  void cancel() {
    if (isRunning) _canceled = true;
  }

  void _publish(BulkDownloadSummary summary) {
    if (_disposed) return;
    state = summary;
  }
}

final bulkDownloadControllerProvider =
    NotifierProvider<BulkDownloadController, BulkDownloadSummary?>(
  BulkDownloadController.new,
);
