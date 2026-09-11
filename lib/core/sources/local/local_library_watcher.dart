import 'dart:async';

import 'audio_file_types.dart';
import 'local_directory_watch.dart';
import 'local_music_roots.dart';

/// Watches the user's selected music folders and asks for a refresh when
/// something under one of them changes.
///
/// It does not update the catalog itself. That matters: there is exactly one
/// way the local catalog is written, the incremental scan, and a watcher with
/// its own idea of how to apply a change would be a second one that could
/// disagree with the first. So this decides only *when* to scan, and hands the
/// scan the same entry point the Rescan button uses. The scan is what makes
/// that affordable, because it re-reads only the files whose size or mtime
/// moved.
///
/// **Coalescing is the whole design.** Copying one album produces a burst of
/// events (a create and several modifies per file, plus directory events), and
/// a rescan per event would be hundreds of scans of the whole library for one
/// user action. Instead:
///
///  * an event starts, or extends, a quiet period. The refresh happens once the
///    filesystem has been quiet for [quietPeriod], so a burst collapses into one
///    scan;
///  * a burst that never goes quiet, which is what a long copy over the network
///    looks like, is not allowed to postpone the refresh forever: once
///    [maxCoalesceWindow] has passed since the burst began, it refreshes anyway
///    and starts a fresh window. So a big copy shows up progressively rather
///    than only at the end;
///  * events that arrive *while* a refresh is running schedule exactly one more
///    refresh afterwards, not one per event.
///
/// **Failure is expected, not exceptional.** inotify has a per-user watch
/// limit, and a large library on a machine with a low `max_user_watches` can
/// exhaust it; a folder can also vanish, or live on a filesystem that cannot be
/// watched at all (many network mounts). Any of those marks that one folder
/// unwatched, leaves the others watching, and changes nothing about manual
/// refresh. [unwatchableRoots] is what the UI reads to say so honestly instead
/// of implying the library is live when it is not.
///
/// **Nothing here writes to the user's folders**, so there is no feedback loop
/// to guard against: Linthra never creates, moves or deletes a file under a
/// music folder, and the only thing a refresh does to disk is read.
class LocalLibraryWatcher {
  LocalLibraryWatcher({
    required DirectoryWatchFactory watchFactory,
    required Future<void> Function() onLibraryChanged,
    void Function(String root, Object error)? onWatchFailed,
    this.quietPeriod = const Duration(seconds: 2),
    this.maxCoalesceWindow = const Duration(seconds: 15),
  })  : _watchFactory = watchFactory,
        _onLibraryChanged = onLibraryChanged,
        _onWatchFailed = onWatchFailed;

  final DirectoryWatchFactory _watchFactory;
  final Future<void> Function() _onLibraryChanged;
  final void Function(String root, Object error)? _onWatchFailed;

  /// How long the filesystem has to stay quiet before a burst is refreshed.
  final Duration quietPeriod;

  /// The longest a continuous burst may postpone a refresh. A copy that keeps
  /// producing events still shows up while it is running.
  final Duration maxCoalesceWindow;

  final Map<String, StreamSubscription<LocalDirectoryChange>> _watches =
      <String, StreamSubscription<LocalDirectoryChange>>{};
  final Set<String> _unwatchable = <String>{};

  Timer? _pending;
  DateTime? _burstStartedAt;
  bool _refreshing = false;
  bool _changedDuringRefresh = false;
  bool _disposed = false;

  /// How many refreshes this watcher has actually asked for. The number that
  /// says whether coalescing works: copying an album must move it by one.
  int refreshCount = 0;

  /// The folders currently being watched.
  Set<String> get watchedRoots => _watches.keys.toSet();

  /// The selected folders that could not be watched, so the UI can say the
  /// library is not live for those rather than implying it is.
  Set<String> get unwatchableRoots => Set<String>.unmodifiable(_unwatchable);

  /// Whether some selected folder is not being watched. Manual refresh still
  /// works for all of them.
  bool get isDegraded => _unwatchable.isNotEmpty;

  /// Whether a refresh is scheduled but has not run yet.
  bool get hasPendingRefresh => _pending != null;

  /// Watches exactly [roots], opening watches for the ones that are new and
  /// releasing the ones that are no longer selected.
  ///
  /// Folders already being watched are left alone rather than torn down and
  /// re-opened: re-opening a recursive watch on a large tree costs a walk and a
  /// watch descriptor per directory, and adding a second music folder is no
  /// reason to pay it for the first one.
  ///
  /// A folder that previously failed is retried, because the reason it failed
  /// (a drive that was not mounted, a watch budget that was full) is usually
  /// temporary and re-selecting or rescanning is exactly when a user expects
  /// another attempt.
  Future<void> syncRoots(List<String> roots) async {
    if (_disposed) return;
    final List<String> wanted = LocalMusicRoots.normalize(roots);
    final Set<String> keep = wanted.toSet();

    for (final String root in _watches.keys.toList()) {
      if (keep.contains(root)) continue;
      await _watches.remove(root)?.cancel();
    }
    _unwatchable.removeWhere((String root) => !keep.contains(root));

    for (final String root in wanted) {
      if (_watches.containsKey(root)) continue;
      _open(root);
    }
  }

  void _open(String root) {
    try {
      _watches[root] = _watchFactory.watch(root).listen(
            _onChange,
            onError: (Object error, StackTrace _) => _failRoot(root, error),
            // A watch that ends on its own (the folder was deleted, the mount
            // went away) is a failure too: nothing under it will be reported
            // again, and pretending otherwise is how a library silently stops
            // updating.
            onDone: () => _failRoot(
              root,
              const _WatchEndedException(),
            ),
            cancelOnError: true,
          );
      _unwatchable.remove(root);
    } catch (error) {
      _failRoot(root, error);
    }
  }

  void _failRoot(String root, Object error) {
    if (_disposed) return;
    _watches.remove(root)?.cancel();
    if (_unwatchable.add(root)) _onWatchFailed?.call(root, error);
  }

  /// Whether a changed path is worth a rescan.
  ///
  /// A music folder is full of things that are not music and that change
  /// constantly while music is being added: a downloader's `.part` files, cover
  /// art, `.nfo` and `.log` and `.cue` sidecars, editor swap files. None of
  /// them can change the catalog, and each one that gets through is a scan of
  /// the whole library for nothing.
  ///
  /// So a path with an extension has to be one Linthra can actually import.
  /// A path *without* an extension is accepted, because that is what a
  /// directory looks like, and a directory event is how a new album folder or a
  /// renamed one is noticed.
  ///
  /// Hidden entries are dropped whatever their shape. `.DS_Store` and the
  /// bookkeeping folders sync tools scatter through a library (`.stfolder`,
  /// `.stversions`) change constantly and never carry music, and letting them
  /// through would rescan the library on somebody else's schedule. The cost is
  /// that music inside a hidden folder is not *watched*; a manual rescan still
  /// finds it, because the scan itself does not filter this way.
  static bool isRelevant(String path) {
    final int slash = path.lastIndexOf('/');
    final String name = slash < 0 ? path : path.substring(slash + 1);
    if (name.isEmpty || name.startsWith('.')) return false;
    if (!name.contains('.')) return true;
    return AudioFileTypes.isSupported(name);
  }

  void _onChange(LocalDirectoryChange change) {
    if (_disposed) return;
    if (!isRelevant(change.path)) return;
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_refreshing) {
      // One more pass after the current one, however many events land during
      // it. Re-running per event would turn a long copy into a scan queue.
      _changedDuringRefresh = true;
      return;
    }
    final DateTime now = DateTime.now();
    _burstStartedAt ??= now;
    if (now.difference(_burstStartedAt!) >= maxCoalesceWindow) {
      // This burst has been going long enough. Refresh now and let whatever
      // follows start a new window, so a long copy is visible while it runs.
      _pending?.cancel();
      _pending = null;
      unawaited(_runRefresh());
      return;
    }
    _pending?.cancel();
    _pending = Timer(quietPeriod, () {
      _pending = null;
      unawaited(_runRefresh());
    });
  }

  Future<void> _runRefresh() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    _burstStartedAt = null;
    refreshCount++;
    try {
      await _onLibraryChanged();
    } catch (_) {
      // A failed scan reports itself through the normal scan-report path; it
      // must not take the watcher down with it, or one bad refresh would end
      // live updates until the app restarts.
    } finally {
      _refreshing = false;
    }
    if (_changedDuringRefresh && !_disposed) {
      _changedDuringRefresh = false;
      _scheduleRefresh();
    }
  }

  /// Releases every watch and cancels any scheduled refresh. Idempotent, and
  /// after it nothing this watcher owns can fire again.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pending?.cancel();
    _pending = null;
    final List<StreamSubscription<LocalDirectoryChange>> open =
        _watches.values.toList();
    _watches.clear();
    for (final StreamSubscription<LocalDirectoryChange> subscription in open) {
      await subscription.cancel();
    }
  }
}

/// The watch stream closed by itself, which means this folder is no longer
/// being reported on.
class _WatchEndedException implements Exception {
  const _WatchEndedException();

  @override
  String toString() => 'the filesystem watch ended';
}
