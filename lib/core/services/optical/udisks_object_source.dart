import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'udisks_drive_reading.dart';

/// Linthra's window onto UDisks2: read everything once, and be told when
/// something changed.
///
/// Deliberately the smallest surface that can answer #631's question, and
/// deliberately *stateless*. It hands back whole tables rather than deltas,
/// and its change stream carries no payload at all — it only says "ask again".
///
/// That shape is the point. A delta protocol would mean keeping a mirror of
/// UDisks2's object tree in Linthra and merging `InterfacesAdded`,
/// `InterfacesRemoved`, `PropertiesChanged` and invalidated-property
/// notifications into it correctly, forever, including while a read is already
/// in flight. Every hard case in this feature — a disc ejected mid-look, a USB
/// drive pulled out between two signals, a burst of events for one insertion —
/// is a cache-coherency bug waiting in that design and is simply not
/// expressible in this one: the next read is the truth, and a drive that
/// vanished is a drive that is not in it.
///
/// The cost is one IPC round trip per burst of change, which happens when
/// somebody physically touches the machine. At rest it costs nothing: no
/// timer, no poll, no open device.
///
/// Implementations may throw from [objects] — that is how a refusal is
/// reported, and [LinuxOpticalMediaService] is what classifies it.
abstract interface class UDisksObjectSource {
  /// Reads every UDisks2 object now.
  Future<UDisksObjectTable> objects();

  /// Fires when a UDisks2 drive or block device changed in any way: a disc
  /// inserted or ejected, a drive appearing or going away, a property moving
  /// as a disc finishes being identified.
  ///
  /// Carries nothing, on purpose — see the class docs. A broadcast stream, so
  /// several listeners are fine.
  Stream<void> get changes;

  /// Drops the connection and every subscription on it. Safe to call twice.
  Future<void> close();
}

/// Opens a connection to the system bus. Injectable so a test never touches
/// one.
typedef DBusSystemClientFactory = DBusClient Function();

/// The real [UDisksObjectSource]: UDisks2 on the system bus.
///
/// ## Why UDisks2 and not a device scan
///
/// Detecting an audio CD means answering "is there a CD-DA table of contents
/// in that drive", and the only things that can answer it are the kernel and
/// the drive. UDisks2 already asks them — it is the daemon GNOME Disks, GVfs
/// and every file manager on the machine use for exactly this — and it
/// publishes the answer as typed D-Bus properties, including
/// `OpticalNumAudioTracks`.
///
/// So Linthra asks the thing that already knows, rather than:
///
///  * **issuing `CDROM_*` ioctls itself**, which means opening `/dev/sr0`
///    (waking the drive, and failing outright without the right group
///    membership), and polling, because an ioctl cannot tell you a disc was
///    inserted;
///  * **linking libcdio or libdiscid**, a native dependency and a build-system
///    change on every target, to learn one integer that is already on the bus;
///  * **parsing `lsblk`, `udevadm` or `/proc/sys/dev/cdrom/info`**, which is
///    scraping human-readable output from a subprocess a music player should
///    not be spawning at all.
///
/// It also costs no new dependency: Linthra already speaks D-Bus through the
/// `dbus` package for MPRIS and desktop notifications, and UDisks2 ships with
/// every desktop Linux distribution Linthra targets.
///
/// ## What it is allowed to do
///
/// Reads, and nothing else. It calls exactly one method —
/// `GetManagedObjects` — and listens for signals. It never calls
/// `Drive.Eject`, `Filesystem.Mount`, `Block.Format` or anything else UDisks2
/// offers, so there is no path through this class that can move, mount or
/// erase anything on the user's machine. Nothing here needs root, and nothing
/// here asks polkit for an authorisation: reading drive properties is allowed
/// for a logged-in local user out of the box.
///
/// ## What it is not tested by
///
/// This class is the thin, untestable half on purpose: it holds the bus
/// connection and translates signals, and there is no way to exercise it
/// without a real system bus. Everything with a decision in it lives above
/// ([LinuxOpticalMediaService]) or beside it ([udisksOpticalDiscState]), both
/// of which are unit-tested against fixtures.
class DBusUDisksObjectSource implements UDisksObjectSource {
  DBusUDisksObjectSource({
    DBusSystemClientFactory clientFactory = DBusClient.system,
  }) : _clientFactory = clientFactory;

  final DBusSystemClientFactory _clientFactory;

  DBusClient? _client;
  DBusRemoteObjectManager? _manager;
  StreamSubscription<DBusSignal>? _signals;
  StreamController<void>? _controller;
  bool _closed = false;

  @override
  Future<UDisksObjectTable> objects() async {
    if (_closed) return <String, Map<String, Map<String, DBusValue>>>{};
    final Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects =
        await _remoteManager().getManagedObjects();
    return objects.map(
      (DBusObjectPath path, Map<String, Map<String, DBusValue>> interfaces) =>
          MapEntry<String, Map<String, Map<String, DBusValue>>>(
        path.value,
        interfaces,
      ),
    );
  }

  @override
  Stream<void> get changes {
    if (_closed) return const Stream<void>.empty();
    final StreamController<void>? existing = _controller;
    if (existing != null) return existing.stream;
    final StreamController<void> controller = StreamController<void>.broadcast(
      onListen: _attach,
    );
    _controller = controller;
    return controller.stream;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final StreamSubscription<DBusSignal>? signals = _signals;
    _signals = null;
    final DBusClient? client = _client;
    _client = null;
    _manager = null;
    try {
      await signals?.cancel();
    } catch (_) {
      // A subscription on a connection that already dropped. Nothing to undo.
    }
    try {
      await client?.close();
    } catch (_) {
      // Closing a client that never finished connecting can throw; a shutdown
      // must not.
    }
    await _controller?.close();
    _controller = null;
  }

  /// Subscribes on the first listener, not in the constructor: building this
  /// object must not put a match rule on the system bus for a feature nobody
  /// has asked about yet.
  void _attach() {
    if (_closed || _signals != null) return;
    try {
      _signals = _remoteManager().signals.listen(
            _onSignal,
            // A bus that goes away is "no more events", not a crash. The last
            // snapshot published stays on screen until something asks again.
            onError: (Object _) {},
          );
    } catch (_) {
      // No system bus on this machine. inspect() reports the same failure in
      // a form a caller can act on; there is nothing useful to do here.
    }
  }

  /// Passes on only the signals that can change Linthra's answer.
  ///
  /// UDisks2 is a busy object manager: every mount, unmount, format and
  /// `Job` progress update goes past this listener. Filtering here keeps one
  /// unrelated `udevadm trigger` from making Linthra re-read the whole object
  /// tree.
  void _onSignal(DBusSignal signal) {
    final StreamController<void>? controller = _controller;
    if (controller == null || controller.isClosed) return;
    if (isRelevantSignal(signal)) controller.add(null);
  }

  /// Whether [signal] can change Linthra's answer, and so is worth a re-read.
  ///
  /// The one decision in this otherwise mechanical class, so it is reachable
  /// from a test: a `DBusSignal` can be built by hand, which the rest of this
  /// class (a live bus connection) cannot.
  @visibleForTesting
  static bool isRelevantSignal(DBusSignal signal) {
    if (signal is DBusObjectManagerInterfacesAddedSignal) {
      return signal.interfacesAndProperties.keys.any(_isWatchedInterface);
    }
    if (signal is DBusObjectManagerInterfacesRemovedSignal) {
      return signal.interfaces.any(_isWatchedInterface);
    }
    if (signal is DBusPropertiesChangedSignal) {
      return _isWatchedInterface(signal.propertiesInterface);
    }
    return false;
  }

  /// The interfaces whose comings, goings and property changes can move a
  /// drive's reading.
  ///
  /// This list must stay in step with every interface [opticalSnapshotFrom]
  /// looks at, and `Partition` is here for exactly that reason: the decoder
  /// skips a block that is a partition, so a `Partition` interface arriving on
  /// or leaving an existing object changes which node names a drive. Watching
  /// only `Drive` and `Block` left that change unnoticed until some unrelated
  /// event happened to trigger the next read. An interface the decoder reads
  /// and the filter ignores is the shape of that bug, so the two belong
  /// together.
  static bool _isWatchedInterface(String interface) =>
      interface == UDisks.driveInterface ||
      interface == UDisks.blockInterface ||
      interface == UDisks.partitionInterface;

  DBusRemoteObjectManager _remoteManager() {
    final DBusRemoteObjectManager? existing = _manager;
    if (existing != null) return existing;
    final DBusClient client = _client ??= _clientFactory();
    return _manager = DBusRemoteObjectManager(
      client,
      name: UDisks.busName,
      path: DBusObjectPath(UDisks.managerPath),
    );
  }
}
