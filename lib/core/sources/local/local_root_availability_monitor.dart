import 'dart:async';

import 'local_music_roots.dart';
import 'local_root_availability.dart';
import 'local_root_probe.dart';

/// Tracks whether each configured local music folder is reachable, and notices
/// when one that was away comes back.
///
/// This is the state half of "music on a removable drive" (#415). It owns no
/// catalog logic at all: unplugging a drive moves an enum, and plugging it back
/// in asks for the ordinary incremental scan, the same one the Rescan button
/// runs. Nothing it can do removes a track, a folder from the selection, or a
/// row from the database, which is exactly what makes a disconnect safe.
///
/// Three rules describe all of it:
///
///  * **A folder that stops answering becomes
///    [LocalRootAvailability.unavailable], never "removed".** It keeps its place
///    in the user's selection and its tracks stay indexed. Only the user
///    removing the folder removes anything.
///  * **Roots are independent.** Each is probed and remembered on its own, so an
///    unplugged USB disk says nothing about the internal music folder beside it,
///    and nothing at all about a server source.
///  * **Coming back is detected by the configured path answering again.** No
///    mount-point scanning, no device identity, no "did this drive turn up
///    somewhere else" (see [LocalRootProbe]). A root that returns at a
///    *different* path stays unavailable, because the folder the user chose is
///    still not there.
///
/// **Polling exists only for the return trip.** Going away is reported by
/// whatever touched the folder (a scan that failed, a filesystem watch that
/// died), and those arrive immediately: see [recheck] and [noteScanOutcome].
/// Coming back has no such signal: nothing tells an app that a drive was plugged
/// in, so the only honest way to notice is to ask again. So the timer runs
/// **only while some root is unavailable**, and each tick probes only those
/// roots. A library whose folders are all present carries no timer and never
/// touches the disk on a schedule, which also keeps Linthra from waking a drive
/// that was allowed to spin down.
class LocalRootAvailabilityMonitor {
  LocalRootAvailabilityMonitor({
    required LocalRootProbe probe,
    Future<void> Function(List<String> roots)? onRootsReturned,
    void Function(LocalLibraryAvailability availability)? onChanged,
    this.pollInterval,
    DateTime Function() now = DateTime.now,
  })  : _probe = probe,
        _onRootsReturned = onRootsReturned,
        _onChanged = onChanged,
        _now = now;

  final LocalRootProbe _probe;

  /// Called with the roots that just went from unavailable to available, so the
  /// app can refresh them. Never called for a root's *first* answer: a folder
  /// that is simply there at startup has not reconnected, and a scan nobody
  /// asked for is not free.
  final Future<void> Function(List<String> roots)? _onRootsReturned;

  final void Function(LocalLibraryAvailability availability)? _onChanged;

  /// How often an unavailable root is re-probed, or null for no polling at all.
  ///
  /// Null is the default so a bare container (every widget and unit test) never
  /// carries a live timer and only probes when something asks. The running app
  /// supplies a real interval.
  final Duration? pollInterval;

  final DateTime Function() _now;

  /// Per-root state, keyed by the canonical configured root. The key is the
  /// user's own path, always: nothing here ever stores a substitute for it.
  final Map<String, LocalRootState> _roots = <String, LocalRootState>{};

  /// Roots asked about while a probe round was running. Drained by that round
  /// rather than dropped, so a watch that dies during a poll is still noticed.
  final Set<String> _requeued = <String>{};

  Timer? _poll;
  bool _pollingEnabled = true;
  bool _probing = false;
  bool _disposed = false;

  /// How many probe rounds have run. The number a test reads to assert that a
  /// library whose folders are all present polls nothing.
  int probeRounds = 0;

  LocalLibraryAvailability get availability => LocalLibraryAvailability(
        Map<String, LocalRootState>.unmodifiable(_roots),
      );

  /// The folders currently tracked, in the user's order.
  List<String> get trackedRoots => _roots.keys.toList(growable: false);

  /// Whether the return-trip timer is armed right now.
  bool get isPolling => _poll != null;

  /// Tracks exactly [roots], and probes the ones nothing is known about.
  ///
  /// A folder already tracked keeps the state it has: adding a second music
  /// folder must not reset what is known about the first, or the next probe
  /// would look like a reconnect and rescan for nothing. A folder that is no
  /// longer selected is dropped entirely: that is the *explicit removal* path,
  /// and it clears only that root.
  Future<void> syncRoots(List<String> roots) async {
    if (_disposed) return;
    final List<String> wanted = LocalMusicRoots.normalize(roots);
    final Set<String> keep = wanted.toSet();
    final int before = _roots.length;
    _roots.removeWhere((String root, _) => !keep.contains(root));
    _requeued.removeWhere((String root) => !keep.contains(root));
    final List<String> fresh = <String>[];
    for (final String root in wanted) {
      if (_roots.containsKey(root)) continue;
      _roots[root] = LocalRootState.checking(root);
      fresh.add(root);
    }
    if (fresh.isNotEmpty || _roots.length != before) _publish();
    await _probeRoots(fresh);
  }

  /// Re-probes every tracked root now.
  ///
  /// The answer to the moments a folder's state can have changed without
  /// Linthra touching it: the app coming back on screen, or the user asking.
  Future<void> refresh() => _probeRoots(_roots.keys.toList(growable: false));

  /// Re-probes one root now, because something just failed on it.
  ///
  /// This is how a disconnect is noticed *immediately* rather than at the next
  /// poll: the filesystem watch on an unmounted folder dies, and that knows
  /// which folder it was watching. An untracked root is ignored.
  Future<void> recheck(String root) {
    final String canonical = LocalMusicRoots.canonicalize(root);
    if (!_roots.containsKey(canonical)) return Future<void>.value();
    return _probeRoots(<String>[canonical]);
  }

  /// Adopts what a scan just learned: which folders it could read, and which it
  /// could not.
  ///
  /// The scan walked those folders, so this is stronger evidence than any probe
  /// and arrives without a second syscall. It deliberately announces no
  /// reconnect: a scan is what a returning folder would be refreshed *by*, and
  /// asking for another one on the strength of the first's report would scan the
  /// same folder twice.
  void noteScanOutcome({
    required Iterable<String> readRoots,
    required Iterable<String> unreadableRoots,
  }) {
    if (_disposed) return;
    bool changed = false;
    for (final String root in readRoots) {
      changed |= _settle(root, available: true);
    }
    for (final String root in unreadableRoots) {
      changed |= _settle(root, available: false);
    }
    if (!changed) return;
    _publish();
    _syncPoll();
  }

  /// Starts or stops the return-trip poll for the app's visibility.
  ///
  /// Only ever touches the timer. Nothing about a pocketed phone or a minimized
  /// window may move a folder's state on its own.
  void setPollingEnabled(bool enabled) {
    if (_disposed) return;
    _pollingEnabled = enabled;
    _syncPoll();
  }

  /// Probes [roots], one at a time, and announces the ones that came back.
  ///
  /// Answers are keyed by root, so an answer that lands after the user changed
  /// their selection simply has nowhere to go ([_settle] ignores a root that is
  /// no longer tracked) rather than being attributed to the wrong folder.
  Future<void> _probeRoots(List<String> roots) async {
    if (_disposed || roots.isEmpty) return;
    if (_probing) {
      _requeued.addAll(roots);
      return;
    }
    _probing = true;
    try {
      List<String> batch = roots;
      while (batch.isNotEmpty && !_disposed) {
        final List<String> returned = await _probeBatch(batch);
        if (_disposed) return;
        if (returned.isNotEmpty) await _announceReturned(returned);
        batch = _requeued.toList(growable: false);
        _requeued.clear();
      }
    } finally {
      _probing = false;
      if (!_disposed) _syncPoll();
    }
  }

  /// One pass over [roots]. Returns the ones that went from away to present.
  Future<List<String>> _probeBatch(List<String> roots) async {
    probeRounds++;
    final List<String> returned = <String>[];
    bool changed = false;
    for (final String root in roots) {
      final bool? answer = await _probe.isAvailable(root);
      if (_disposed) return const <String>[];
      if (answer == null) {
        // This platform cannot speak for this root. Forget it rather than
        // keeping a state nothing can ever refresh.
        changed |= _roots.remove(root) != null;
        continue;
      }
      final bool wasUnavailable = _roots[root]?.isUnavailable ?? false;
      final bool settled = _settle(root, available: answer);
      changed |= settled;
      if (settled && answer && wasUnavailable) returned.add(root);
    }
    if (changed) _publish();
    return returned;
  }

  Future<void> _announceReturned(List<String> returned) async {
    final Future<void> Function(List<String> roots)? handler = _onRootsReturned;
    if (handler == null) return;
    try {
      await handler(returned);
    } catch (_) {
      // A refresh that failed reports itself through the normal scan-report
      // path. It must not take availability tracking down with it, or one bad
      // reconnect would stop every later one from being noticed.
    }
  }

  /// Records one probe answer for [root]. Returns whether anything changed.
  bool _settle(String root, {required bool available}) {
    final String canonical = LocalMusicRoots.canonicalize(root);
    final LocalRootState? current = _roots[canonical];
    if (current == null) return false;
    final LocalRootState next =
        current.settled(available: available, at: _now());
    if (next == current) return false;
    _roots[canonical] = next;
    return true;
  }

  void _publish() {
    if (_disposed) return;
    _onChanged?.call(availability);
  }

  void _syncPoll() {
    final Duration? interval = pollInterval;
    final bool shouldPoll = !_disposed &&
        _pollingEnabled &&
        interval != null &&
        interval > Duration.zero &&
        _roots.values.any((LocalRootState state) => state.isUnavailable);
    if (!shouldPoll) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(interval, (_) => unawaited(_pollOnce()));
  }

  /// One poll tick: ask only about the folders that are away. The ones that are
  /// present are not touched, so a schedule never wakes a healthy drive.
  Future<void> _pollOnce() {
    final List<String> away = <String>[
      for (final LocalRootState state in _roots.values)
        if (state.isUnavailable) state.root,
    ];
    if (away.isEmpty) {
      _syncPoll();
      return Future<void>.value();
    }
    return _probeRoots(away);
  }

  /// Cancels the poll and stops every callback. Idempotent, and after it nothing
  /// this monitor owns can fire again.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    _poll = null;
  }
}
