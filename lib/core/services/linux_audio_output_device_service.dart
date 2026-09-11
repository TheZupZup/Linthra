import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import '../models/audio_output_device.dart';
import 'audio_output_device_service.dart';

/// Reads the backend's raw output list as `(id, description)` records.
typedef LinuxAudioDeviceProbe = Future<List<({String id, String description})>>
    Function();

/// Writes a device name back to the backend.
typedef LinuxAudioDeviceApply = Future<void> Function(String deviceId);

/// Watches the backend's raw output list, re-attaching as players come and go.
///
/// A seam so the *policy* around hotplug (see `AudioOutputController`) can be
/// tested without libmpv, and so the attachment strategy underneath can change
/// without the policy noticing.
typedef LinuxAudioDeviceWatch = Stream<List<({String id, String description})>>
    Function();

/// Linux output-device routing, through media_kit/libmpv.
///
/// libmpv already models exactly what this feature needs, so nothing here goes
/// around the backend: the list is mpv's `audio-device-list` property and the
/// choice is its `audio-device` property. What just_audio does not model is any
/// of it — its platform interface has no notion of an output device — so the
/// live `Player` is reached through `JustAudioMediaKit.livePlayers`, the small
/// registry Linthra's vendored copy of that plugin keeps
/// (`third_party/just_audio_media_kit/PATCHES.md`).
///
/// A choice is applied in two places on purpose:
///
///  * every live player, so audio that is *already playing* moves to the new
///    output rather than waiting for the next track, and
///  * `JustAudioMediaKit.mpvProperties`, which media_kit applies to each player
///    it creates afterwards, so the choice survives the engine tearing a player
///    down and building a new one (stop, suspend/resume, a source switch).
///
/// Enumeration prefers a live player and only builds a throwaway one when
/// nothing is playing — libmpv reports `audio-device-list` on a fresh handle
/// without ever opening an output, so listing outputs from Settings never makes
/// a sound or grabs a device.
///
/// ## Watching for hotplug
///
/// [deviceChanges] is the same `audio-device-list` property, observed rather
/// than read once: libmpv republishes it when a headset is plugged in, a
/// Bluetooth sink connects or drops, an HDMI output appears, or the system
/// default moves. Three rules keep that from becoming a source of bugs of its
/// own:
///
///  * **One subscription per live player, ever.** The service keys them by the
///    just_audio player id, so re-attaching is idempotent and a device event
///    can never be delivered twice — which is what would turn one hotplug into
///    two recovery attempts, and one recovery into duplicate playback.
///  * **No player is created to watch.** Enumeration may build a throwaway
///    handle; watching never does. When nothing is playing there is no player,
///    so there are no events — and nothing to recover either, because no audio
///    is being interrupted.
///  * **It re-attaches on a signal, not on a timer.** The engine tears a player
///    down and builds a new one on a stop, on suspend/resume and on some source
///    switches, so a listener attached to one player has to follow. The
///    vendored plugin publishes `livePlayersChanged` for exactly this
///    (`third_party/just_audio_media_kit/PATCHES.md`), so nothing polls.
class LinuxAudioOutputDeviceService implements AudioOutputDeviceService {
  LinuxAudioOutputDeviceService({
    LinuxAudioDeviceProbe? probe,
    LinuxAudioDeviceApply? apply,
    LinuxAudioDeviceWatch? watch,
  })  : _probe = probe ?? _probeThroughMediaKit,
        _apply = apply ?? _applyThroughMediaKit,
        _watch = watch ?? _watchThroughMediaKit;

  final LinuxAudioDeviceProbe _probe;
  final LinuxAudioDeviceApply _apply;
  final LinuxAudioDeviceWatch _watch;

  Stream<List<AudioOutputDevice>>? _deviceChanges;

  /// How long libmpv gets to report its device list before Linthra gives up.
  ///
  /// The property is published during player initialization, so this is a
  /// safety net for a wedged backend, not a normal wait.
  static const Duration probeTimeout = Duration(seconds: 3);

  @override
  bool get isSupported => true;

  @override
  Future<List<AudioOutputDevice>> devices() async {
    try {
      return audioOutputDevicesFromBackend(await _probe());
    } catch (_) {
      // A backend that cannot be asked is reported as "nothing to show", never
      // as an error: Settings still renders, it just says it found no outputs.
      return const <AudioOutputDevice>[];
    }
  }

  /// The host's output list, re-emitted whenever the backend reports a change.
  ///
  /// Built once and shared: the underlying watch attaches to the backend on the
  /// first listen and detaches on the last, so a second listener costs nothing
  /// and a page nobody opened holds no subscription at all.
  ///
  /// A list that could not be read is dropped rather than emitted as empty —
  /// "the backend did not answer" is not the same as "this machine has no
  /// outputs", and a policy that acted on the difference would route playback
  /// away from a device the listener is still using.
  @override
  Stream<List<AudioOutputDevice>> get deviceChanges {
    return _deviceChanges ??= _watch()
        .map(audioOutputDevicesFromBackend)
        .handleError((Object _) {})
        .asBroadcastStream();
  }

  @override
  Future<bool> select(AudioOutputDevice device) async {
    try {
      await _apply(device.id);
      return true;
    } catch (_) {
      // A device that vanished between the list and the tap leaves playback
      // where it is rather than throwing into Settings — but the caller is told
      // it did not happen, so it does not go on to remember an output that
      // never started.
      return false;
    }
  }

  /// Follows libmpv's `audio-device-list` across the players the engine
  /// creates and destroys.
  ///
  /// The bookkeeping is deliberately boring: a map of player id → subscription,
  /// re-synced on every `livePlayersChanged` event and on the first listen.
  /// Attaching is idempotent (a player already in the map is skipped) and
  /// detaching is total (the last listener leaves nothing behind), which
  /// together are what keep one hotplug from being seen twice.
  static Stream<List<({String id, String description})>>
      _watchThroughMediaKit() {
    final Map<String, StreamSubscription<List<AudioDevice>>> attached =
        <String, StreamSubscription<List<AudioDevice>>>{};
    StreamSubscription<void>? registry;
    late StreamController<List<({String id, String description})>> controller;

    void sync() {
      final Map<String, Player> live = JustAudioMediaKit.livePlayers;
      for (final MapEntry<String, Player> entry in live.entries) {
        if (attached.containsKey(entry.key)) continue;
        attached[entry.key] = entry.value.stream.audioDevices.listen(
          (List<AudioDevice> devices) {
            if (_isUnpopulated(devices)) return;
            controller.add(<({String id, String description})>[
              for (final AudioDevice device in devices)
                (id: device.name, description: device.description),
            ]);
          },
          onError: (Object _) {},
        );
      }
      for (final String id in attached.keys.toList()) {
        if (live.containsKey(id)) continue;
        unawaited(attached.remove(id)?.cancel());
      }
    }

    controller = StreamController<List<({String id, String description})>>(
      onListen: () {
        registry = JustAudioMediaKit.livePlayersChanged.stream
            .listen((void _) => sync());
        sync();
      },
      onCancel: () async {
        await registry?.cancel();
        registry = null;
        for (final StreamSubscription<List<AudioDevice>> subscription
            in attached.values.toList()) {
          await subscription.cancel();
        }
        attached.clear();
      },
    );
    return controller.stream;
  }

  static Future<List<({String id, String description})>>
      _probeThroughMediaKit() async {
    final Iterable<Player> live = JustAudioMediaKit.livePlayers.values;
    if (live.isNotEmpty) return _readDevices(live.first);

    // Nothing is playing, so there is no player to ask. A bare libmpv handle
    // reports the device list without initializing an output device.
    final Player probe = Player();
    try {
      return await _readDevices(probe);
    } finally {
      await probe.dispose();
    }
  }

  static Future<List<({String id, String description})>> _readDevices(
    Player player,
  ) async {
    List<AudioDevice> devices = player.state.audioDevices;
    if (_isUnpopulated(devices)) {
      // media_kit seeds the state with a lone `auto` entry and replaces it when
      // libmpv publishes the real list, so an unpopulated state means "not
      // reported yet", not "this machine has one output".
      devices = await player.stream.audioDevices
          .firstWhere((List<AudioDevice> list) => !_isUnpopulated(list))
          .timeout(probeTimeout);
      // A timeout is deliberately *not* caught here. Falling back to the seeded
      // `[auto]` state would read as "this machine has exactly one output",
      // and a caller comparing a saved device against that list would conclude
      // it had been removed. A backend that did not answer in time is an
      // enumeration failure, and `devices()` reports it as one.
    }
    return <({String id, String description})>[
      for (final AudioDevice device in devices)
        (id: device.name, description: device.description),
    ];
  }

  static bool _isUnpopulated(List<AudioDevice> devices) =>
      devices.isEmpty ||
      (devices.length == 1 &&
          devices.single.name == AudioOutputDevice.systemDefaultId);

  static Future<void> _applyThroughMediaKit(String deviceId) async {
    // Live players first, the property last, and the order is the point: a
    // player that refuses the device throws out of here before the property is
    // written, so the *next* player the engine builds does not inherit an id
    // the backend has just rejected and start up unable to open audio.
    for (final Player player in JustAudioMediaKit.livePlayers.values.toList()) {
      await player.setAudioDevice(AudioDevice(deviceId, ''));
    }
    // Merged, not assigned: `cache-on-disk=no` (and the smoke's `ao`) live
    // in the same map and must survive an output change.
    JustAudioMediaKit.mpvProperties = <String, String>{
      ...JustAudioMediaKit.mpvProperties,
      'audio-device': deviceId,
    };
  }
}
