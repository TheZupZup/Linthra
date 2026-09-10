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
class LinuxAudioOutputDeviceService implements AudioOutputDeviceService {
  LinuxAudioOutputDeviceService({
    LinuxAudioDeviceProbe? probe,
    LinuxAudioDeviceApply? apply,
  })  : _probe = probe ?? _probeThroughMediaKit,
        _apply = apply ?? _applyThroughMediaKit;

  final LinuxAudioDeviceProbe _probe;
  final LinuxAudioDeviceApply _apply;

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
