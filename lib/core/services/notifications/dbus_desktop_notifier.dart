import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import '../../app_info.dart';
import 'desktop_notifier.dart';

/// Which of the two D-Bus ways to show a notification is being used.
enum NotificationTransport {
  /// `org.freedesktop.portal.Notification` on the desktop portal. Tried first
  /// because it is the only route a Flatpak has: the sandbox may not talk to
  /// an arbitrary bus name, and Linthra deliberately asks for no
  /// `--talk-name` (see docs/flatpak-permissions.md).
  portal,

  /// `org.freedesktop.Notifications`, the freedesktop spec interface every
  /// notification daemon implements. The route on a host with no portal (a
  /// bare window manager with `dunst`, say), where the session bus is
  /// directly reachable.
  freedesktop,
}

/// Shows Linux desktop notifications over D-Bus (issue #400).
///
/// D-Bus is what a desktop notification *is*: a method call to the session's
/// notification service. Linthra already speaks it for MPRIS through the same
/// package, so this needs no new dependency, no native code, and, the part
/// that matters, no subprocess. Shelling out to `notify-send` would mean
/// spawning a binary found on `PATH` with strings built from track metadata,
/// from a music player, which is a worse idea than it first looks and is not
/// available inside the Flatpak anyway.
///
/// **Two routes, portal first.** The portal is what the sandbox can reach, and
/// asking for it costs no permission at all; the spec interface is the
/// fallback for a host that has no portal running. Whichever answers is
/// remembered, so the common case is one call per notification. Both are
/// best-effort: a refusal, a missing service or a bus that went away is
/// swallowed and the notifier simply re-probes next time.
///
/// **One notification, replaced.** The portal route reuses a fixed id and the
/// spec route passes the previous notification's id as `replaces_id`, so a
/// listener moving through an album ends up with one "now playing" entry that
/// updates, not a stack of them in the shell's tray.
///
/// **Artwork, when the route supports it safely.** The spec interface takes an
/// `image-path` hint, which is a local file the daemon opens itself. The
/// portal takes a serialized icon, and only accepted the `bytes` form from
/// version 2 of its interface, so the cover is attached there only when the
/// running portal says it is that new, and then as bytes read from Linthra's
/// own cache, bounded by [maxImageBytes], rather than as a path the sandbox
/// and the host would disagree about.
class DBusDesktopNotifier implements DesktopNotifier {
  DBusDesktopNotifier({
    DBusClient Function() clientFactory = DBusClient.session,
    Future<Uint8List?> Function(Uri image)? readImage,
    this.callDeadline = defaultCallDeadline,
  })  : _clientFactory = clientFactory,
        _readImage = readImage ?? _readImageFile;

  /// The installed desktop entry, minus its `.desktop` suffix. Also the name
  /// of the installed hicolor icon, which is what makes a daemon draw
  /// Linthra's icon beside the notification. Must stay the app id
  /// `linux/packaging/<app id>.desktop` is installed under, like
  /// `MprisPlayerObject.desktopEntry`.
  static const String desktopEntry = 'io.github.thezupzup.linthra';

  /// The id every "now playing" notification is filed under on the portal
  /// route. Fixed on purpose: the portal replaces a notification that reuses
  /// an id, which is exactly the behaviour wanted here.
  static const String notificationId = 'now-playing';

  /// The largest cover worth sending as bytes, in bytes.
  ///
  /// Covers in Linthra's caches are bounded already (the media-session copy is
  /// requested small, and embedded local art is capped at 1024 px), so this is
  /// the backstop for an unexpectedly large one rather than the normal case: a
  /// megabyte of image per track change does not belong on the session bus,
  /// and a notification without a cover is a much smaller loss than a stalled
  /// call.
  static const int maxImageBytes = 512 * 1024;

  /// How long the spec route asks the daemon to keep the notification up.
  ///
  /// Only a request: every daemon is free to ignore it, and several do. Long
  /// enough to read a title and an artist, short enough that it is gone before
  /// the next track.
  static const Duration expireAfter = Duration(seconds: 5);

  /// How long one notification may take before it is given up on.
  ///
  /// A notification service is local and answers in milliseconds, so a call
  /// still outstanding after this was never coming back. It is bounded because
  /// nothing awaits these: without a deadline a wedged daemon would leave a
  /// pending call behind for every track change of the session.
  static const Duration defaultCallDeadline = Duration(seconds: 5);

  static const String _portalDestination = 'org.freedesktop.portal.Desktop';
  static const String _portalInterface = 'org.freedesktop.portal.Notification';
  static const String _propertiesInterface = 'org.freedesktop.DBus.Properties';
  static const String _freedesktopName = 'org.freedesktop.Notifications';

  /// The deadline for one notification. Injectable so a test can assert the
  /// bound without waiting for it.
  final Duration callDeadline;

  final DBusClient Function() _clientFactory;
  final Future<Uint8List?> Function(Uri image) _readImage;

  DBusClient? _client;
  bool _disposed = false;

  /// The route that last worked, or null while it is still unknown (or has
  /// just stopped working).
  NotificationTransport? _transport;

  /// The portal's interface version, once read successfully. Cached only on
  /// success: a failed read must not pin the portal as unusable for the rest
  /// of the session.
  int? _portalVersion;

  /// The id the daemon gave the last notification, passed back as
  /// `replaces_id` so the next one takes its place instead of stacking.
  int _replacesId = 0;

  /// Which route was last used, for diagnostics and tests. Null until a
  /// notification has actually been delivered.
  NotificationTransport? get transport => _transport;

  @override
  bool get isSupported => true;

  @override
  Future<void> show(DesktopNotification notification) async {
    if (_disposed) return;
    final DBusClient? client = _connect();
    if (client == null) return;

    for (final NotificationTransport route in _routes) {
      if (await _send(client, route, notification)) {
        _transport = route;
        return;
      }
    }
    // Nothing answered. Forget the route rather than pinning one that is not
    // there, so a daemon that shows up later is found on the next track.
    _transport = null;
  }

  /// The routes to try, in order: whichever worked last, then the rest.
  Iterable<NotificationTransport> get _routes {
    final NotificationTransport? known = _transport;
    if (known == null) return NotificationTransport.values;
    return <NotificationTransport>[
      known,
      for (final NotificationTransport route in NotificationTransport.values)
        if (route != known) route,
    ];
  }

  /// The bus connection, opened on first use.
  ///
  /// Lazy so a listener who never turns notifications on never opens one, and
  /// guarded so a host with no session bus is "no notifications" rather than a
  /// thrown error. `DBusClient` connects on its first call, not here.
  DBusClient? _connect() {
    if (_client != null) return _client;
    try {
      return _client = _clientFactory();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _send(
    DBusClient client,
    NotificationTransport route,
    DesktopNotification notification,
  ) async {
    try {
      switch (route) {
        case NotificationTransport.portal:
          return await _sendPortal(client, notification).timeout(callDeadline);
        case NotificationTransport.freedesktop:
          return await _sendFreedesktop(client, notification)
              .timeout(callDeadline);
      }
    } catch (_) {
      // A service that is not on the bus, a refused call, a reply that never
      // came: all of them mean "try the other route", never an error the
      // caller has to handle.
      return false;
    }
  }

  Future<bool> _sendPortal(
    DBusClient client,
    DesktopNotification notification,
  ) async {
    final int version = await _readPortalVersion(client);
    // No readable version means no portal to talk to.
    if (version < 1) return false;

    final Map<String, DBusValue> body = <String, DBusValue>{
      'title': DBusString(notification.title),
      if (notification.body.isNotEmpty) 'body': DBusString(notification.body),
      // A now-playing toast is never urgent; "low" is what keeps it out of a
      // do-not-disturb break-through on the desktops that honour priorities.
      'priority': const DBusString('low'),
    };
    if (version >= 2) {
      final Uint8List? bytes = await _imageBytes(notification.image);
      if (bytes != null) {
        // The `g_icon_serialize` form for a GBytesIcon: ('bytes', <ay>).
        body['icon'] = DBusStruct(<DBusValue>[
          const DBusString('bytes'),
          DBusVariant(DBusArray.byte(bytes)),
        ]);
      }
    }

    await client.callMethod(
      destination: _portalDestination,
      path: DBusObjectPath('/org/freedesktop/portal/desktop'),
      interface: _portalInterface,
      name: 'AddNotification',
      values: <DBusValue>[
        const DBusString(notificationId),
        DBusDict.stringVariant(body),
      ],
    );
    return true;
  }

  /// The portal's `version` property, or 0 when there is no portal to ask.
  Future<int> _readPortalVersion(DBusClient client) async {
    final int? known = _portalVersion;
    if (known != null) return known;
    try {
      final DBusMethodSuccessResponse reply = await client.callMethod(
        destination: _portalDestination,
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
        interface: _propertiesInterface,
        name: 'Get',
        values: <DBusValue>[
          const DBusString(_portalInterface),
          const DBusString('version'),
        ],
      );
      final DBusValue? returned =
          reply.returnValues.isEmpty ? null : reply.returnValues.first;
      final DBusValue? value =
          returned is DBusVariant ? returned.value : returned;
      if (value is! DBusUint32) return 0;
      return _portalVersion = value.value;
    } catch (_) {
      // Not cached: a portal that is merely slow or restarting must still get
      // another chance on the next track.
      return 0;
    }
  }

  Future<bool> _sendFreedesktop(
    DBusClient client,
    DesktopNotification notification,
  ) async {
    final Map<String, DBusValue> hints = <String, DBusValue>{
      // Low urgency, and transient: a track change belongs on screen for a
      // moment, not in the shell's notification history for the evening.
      'urgency': const DBusByte(0),
      'transient': const DBusBoolean(true),
      'desktop-entry': const DBusString(desktopEntry),
    };
    final Uri? image = notification.image;
    if (image != null) hints['image-path'] = DBusString(image.toString());

    final DBusMethodSuccessResponse reply = await client.callMethod(
      destination: _freedesktopName,
      path: DBusObjectPath('/org/freedesktop/Notifications'),
      interface: _freedesktopName,
      name: 'Notify',
      values: <DBusValue>[
        const DBusString(AppInfo.name),
        DBusUint32(_replacesId),
        // An icon-theme name, not a path: the same one the installed desktop
        // entry's `Icon=` resolves through.
        const DBusString(desktopEntry),
        DBusString(notification.title),
        DBusString(notification.body),
        // No actions. A notification with buttons would be a second transport
        // control, and the shell already has the MPRIS one.
        DBusArray.string(const <String>[]),
        DBusDict.stringVariant(hints),
        DBusInt32(expireAfter.inMilliseconds),
      ],
    );
    final DBusValue? id =
        reply.returnValues.isEmpty ? null : reply.returnValues.first;
    if (id is DBusUint32) _replacesId = id.value;
    return true;
  }

  /// The cover's bytes, or null when there is no cover, it cannot be read, or
  /// it is larger than [maxImageBytes].
  Future<Uint8List?> _imageBytes(Uri? image) async {
    if (image == null || !image.isScheme('file')) return null;
    try {
      return await _readImage(image);
    } catch (_) {
      // A cover that has been evicted between being cached and being sent is
      // "no cover", not a failed notification.
      return null;
    }
  }

  static Future<Uint8List?> _readImageFile(Uri image) async {
    final File file = File(image.toFilePath());
    if (!await file.exists()) return null;
    if (await file.length() > maxImageBytes) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final DBusClient? client = _client;
    _client = null;
    if (client == null) return;
    try {
      await client.close();
    } catch (_) {
      // Closing a client that never connected can throw; teardown is
      // best-effort like every other step at shutdown.
    }
  }
}
