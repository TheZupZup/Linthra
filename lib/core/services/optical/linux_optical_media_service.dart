import 'dart:async';

import 'package:dbus/dbus.dart';

import '../../models/optical_media.dart';
import '../../platform/flatpak_sandbox.dart';
import 'optical_media_service.dart';
import 'udisks_drive_reading.dart';
import 'udisks_object_source.dart';

/// Linux optical-drive and audio-CD detection, through UDisks2.
///
/// The state machine of the feature: [UDisksObjectSource] holds the bus and
/// [opticalSnapshotFrom] does the decoding, and this decides *when* to look
/// and *what to say* about a look that did not work. It is the piece with the
/// rules in it, so it is the piece with the tests — none of which need a bus,
/// a drive or a disc.
///
/// ## Nothing polls
///
/// UDisks2 already watches the hardware, so Linthra does not have to. A disc
/// going in or coming out, a USB drive plugged in or pulled, a disc finishing
/// its identification: each one is a D-Bus signal, and a signal is what makes
/// this class read again. At rest — which is all the time, for a machine
/// nobody is touching — there is no timer armed, no device open and no
/// syscall being made on a schedule. That also means Linthra never spins up a
/// drive the user let go quiet.
///
/// The one timer in the class is a *settle* delay, and it only ever exists
/// between an event and the read it triggered: inserting a disc produces a
/// short burst of signals as the kernel and UDisks2 work out what it is, and
/// reading once after the burst is both cheaper and less flickery than reading
/// once per signal. It is armed by an event and never by a clock.
///
/// ## Every failure is a value
///
/// [inspect] cannot throw. A machine with no system bus, a UDisks2 that is not
/// installed, one that refuses, one that stops answering — each comes back as
/// an [OpticalMediaSnapshot] whose [OpticalMediaAvailability] says which, so a
/// caller can tell "you have no CD drive" from "Linthra was not allowed to
/// look", which are very different things to put in front of somebody.
///
/// ## Removal is never destructive
///
/// This class publishes readings. It owns no tracks, no queue and no catalog
/// rows, and there is no code path here that can remove one. A disc that
/// leaves the machine moves an enum, exactly as an unplugged music folder does
/// in [LocalRootAvailabilityMonitor] — the policy for what a *playing* disc
/// track should do when that happens belongs with the queue, and lands with
/// playback in a later PR.
class LinuxOpticalMediaService implements OpticalMediaService {
  LinuxOpticalMediaService({
    UDisksObjectSource? source,
    bool? sandboxed,
    this.settleDelay = defaultSettleDelay,
    this.callDeadline = defaultCallDeadline,
  })  : _source = source ?? DBusUDisksObjectSource(),
        _sandboxed = sandboxed ?? isFlatpakSandbox;

  /// How long the burst of signals from one physical event is allowed to run
  /// before the machine is read again.
  ///
  /// Long enough that inserting a disc is one read rather than half a dozen,
  /// short enough that nobody notices it between closing the tray and seeing
  /// the disc appear.
  static const Duration defaultSettleDelay = Duration(milliseconds: 250);

  /// How long UDisks2 gets to answer one read before it is given up on.
  ///
  /// A local daemon answers in milliseconds, so a call still outstanding after
  /// this was not coming back. Without a bound, one wedged read would leave
  /// this class believing a read is in flight for the rest of the session and
  /// silently stop reacting to every later event — a failure that looks
  /// exactly like a broken drive.
  static const Duration defaultCallDeadline = Duration(seconds: 5);

  final Duration settleDelay;
  final Duration callDeadline;

  final UDisksObjectSource _source;

  /// Whether this process is inside the Flatpak sandbox, where the system bus
  /// is deliberately out of reach. See [isSupported].
  final bool _sandboxed;

  StreamController<OpticalMediaSnapshot>? _controller;
  StreamSubscription<void>? _events;
  Timer? _settle;

  /// The last snapshot published, so an event that changes nothing publishes
  /// nothing.
  OpticalMediaSnapshot? _published;

  /// How many looks have been *started*, ever. Stamped onto each read so a
  /// result that has been overtaken can be recognised — see [_publish].
  int _looks = 0;

  /// The generation of the newest look that has reached [_publish].
  int _publishedLook = 0;

  bool _reading = false;

  /// An event that arrived while a read was in flight. Drained by that read
  /// rather than dropped, so a disc pulled out during the read for the disc
  /// going in is still noticed.
  bool _changedDuringRead = false;

  bool _disposed = false;

  /// Whether this build can look at all.
  ///
  /// False inside the Flatpak, and that is a packaging fact rather than a
  /// runtime failure. UDisks2 lives on the **system** bus, Linthra's sandbox
  /// grants no system-bus reach of any kind, and `docs/flatpak-permissions.md`
  /// refuses `--system-talk-name=` outright — so a Flatpak build cannot ask,
  /// and saying so up front is more honest than opening a connection that is
  /// certain to be denied and reporting it as an error the user could fix.
  /// Whether that grant is worth making is #631's Flatpak PR; see
  /// `docs/optical-media.md`.
  @override
  bool get isSupported => !_sandboxed;

  @override
  Future<OpticalMediaSnapshot> inspect() async {
    if (_disposed) return const OpticalMediaSnapshot.unsupported();
    // Deliberately *not* queued behind a read already in flight: a caller
    // asking "look now" is owed an answer about the machine as it is when
    // they asked, not the answer to a question asked before them. It is the
    // publishing that is ordered, not the looking — see [_publish].
    final int look = ++_looks;
    final OpticalMediaSnapshot snapshot = await _read();
    // Published through the same path as an event-driven read, so a listener
    // sees a change a manual refresh discovered instead of only the ones a
    // signal happened to announce.
    _publish(snapshot, look);
    return snapshot;
  }

  @override
  Stream<OpticalMediaSnapshot> get changes {
    // A build that cannot look has nothing to announce, and a listener must
    // not be left waiting on events that can never come.
    if (_disposed || !isSupported) {
      return const Stream<OpticalMediaSnapshot>.empty();
    }
    final StreamController<OpticalMediaSnapshot>? existing = _controller;
    if (existing != null) return existing.stream;
    final StreamController<OpticalMediaSnapshot> controller =
        StreamController<OpticalMediaSnapshot>.broadcast(onListen: _watch);
    _controller = controller;
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _settle?.cancel();
    _settle = null;
    final StreamSubscription<void>? events = _events;
    _events = null;
    await events?.cancel();
    await _source.close();
    await _controller?.close();
    _controller = null;
  }

  /// Starts listening to the host on the first listener, never before.
  ///
  /// Constructing this service must not open a bus connection: it is built
  /// wherever the platform bindings are assembled, long before anything asks
  /// it a question, and a music player that connects to the system bus at
  /// startup for a feature nobody opened is exactly the kind of thing this
  /// codebase does not do.
  void _watch() {
    if (_disposed || _events != null || !isSupported) return;
    _events = _source.changes.listen(
      (_) => _scheduleRead(),
      // A dead event stream stops the updates and nothing else. The last
      // reading stands, and an explicit inspect() still works.
      onError: (Object _) {},
    );
  }

  /// Collapses one physical event's burst of signals into a single read.
  void _scheduleRead() {
    if (_disposed) return;
    _settle?.cancel();
    _settle = Timer(settleDelay, () {
      _settle = null;
      unawaited(_readAndPublish());
    });
  }

  Future<void> _readAndPublish() async {
    if (_disposed) return;
    if (_reading) {
      // Something moved again mid-read. Whatever this read is about to
      // return describes a machine that has already changed, so the read in
      // flight owes one more.
      _changedDuringRead = true;
      return;
    }
    _reading = true;
    try {
      final int look = ++_looks;
      _publish(await _read(), look);
    } finally {
      _reading = false;
    }
    if (_changedDuringRead && !_disposed) {
      _changedDuringRead = false;
      await _readAndPublish();
    }
  }

  /// One look at the machine, with every failure turned into a value.
  Future<OpticalMediaSnapshot> _read() async {
    if (!isSupported) return const OpticalMediaSnapshot.unsupported();
    try {
      final UDisksObjectTable objects =
          await _source.objects().timeout(callDeadline);
      return opticalSnapshotFrom(objects);
    } catch (error) {
      return _snapshotForFailure(error);
    }
  }

  /// Publishes what [look] found, unless a later look has already answered.
  ///
  /// The ordering guard matters because two looks can genuinely be in flight
  /// at once: [inspect] does not queue behind an event-driven read, by design.
  /// Requests are issued in order, but nothing guarantees the *answers* come
  /// back in that order, and without this an older look landing last would
  /// overwrite a newer reading with a stale one — and, because nothing would
  /// then be owed, leave every listener stale until the next time somebody
  /// physically touched the machine.
  ///
  /// So a look that has been overtaken is dropped rather than published. It is
  /// never the only answer: the look that overtook it is newer by definition
  /// and has already been published, or is about to be.
  void _publish(OpticalMediaSnapshot snapshot, int look) {
    if (_disposed || look < _publishedLook) return;
    _publishedLook = look;
    if (snapshot == _published) return;
    _published = snapshot;
    final StreamController<OpticalMediaSnapshot>? controller = _controller;
    if (controller == null || controller.isClosed) return;
    controller.add(snapshot);
  }

  /// Which kind of "we could not tell" this failure is.
  ///
  /// Three outcomes, and the distinction between them is the whole reason this
  /// function exists rather than a bare `catch`:
  ///
  ///  * **A host with no UDisks2 at all** — a minimal or embedded install, a
  ///    container — is [OpticalMediaAvailability.unsupported]. Nothing is
  ///    broken and there is nothing for the user to fix; this machine simply
  ///    cannot answer, the same as Android.
  ///  * **A refusal** is [OpticalMediaAvailability.permissionDenied], because
  ///    the one thing a user can act on is a permission. UDisks2 allows a
  ///    local logged-in session to read drive properties without any polkit
  ///    prompt, so this is rare — a hardened polkit policy, or a session the
  ///    host does not consider local.
  ///  * **Anything else** — a timeout, a dropped connection, a reply that
  ///    does not parse — is [OpticalMediaAvailability.error].
  static OpticalMediaSnapshot _snapshotForFailure(Object error) {
    if (error is DBusServiceUnknownException) {
      return const OpticalMediaSnapshot.unsupported();
    }
    if (error is DBusAccessDeniedException ||
        error is DBusAuthFailedException) {
      return const OpticalMediaSnapshot.permissionDenied();
    }
    if (error is DBusMethodResponseException && _isRefusal(error.errorName)) {
      return const OpticalMediaSnapshot.permissionDenied();
    }
    return const OpticalMediaSnapshot.error();
  }

  /// Whether a D-Bus error name means "you may not", in any of the spellings
  /// the bus, polkit and UDisks2 use for it
  /// (`org.freedesktop.DBus.Error.AccessDenied`,
  /// `org.freedesktop.UDisks2.Error.NotAuthorized`,
  /// `…NotAuthorizedCanObtain`, `…NotAuthorizedDismissed`).
  static bool _isRefusal(String errorName) =>
      errorName.contains('AccessDenied') ||
      errorName.contains('NotAuthorized') ||
      errorName.contains('AuthFailed') ||
      errorName.contains('NotPermitted');
}
