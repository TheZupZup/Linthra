import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/audio_output_device.dart';
import '../../../core/services/audio_output_device_service.dart';
import '../../../data/repositories/audio_output_device_service_provider.dart';
import '../../../data/repositories/playback_preferences_provider.dart';

/// What the "Audio output" card shows.
class AudioOutputSettingsState {
  const AudioOutputSettingsState({
    this.devices = const <AudioOutputDevice>[],
    this.selected = AudioOutputDevice.systemDefault,
    this.hasEnumerated = false,
    this.savedDeviceUnavailable = false,
    this.selectionFailed = false,
    this.outputRecoveryFailed = false,
  });

  /// The outputs the host offers, system default first. Empty either because
  /// nothing has been enumerated yet ([hasEnumerated] false) or because the
  /// backend reported none.
  final List<AudioOutputDevice> devices;

  /// The output playback is currently routed to.
  final AudioOutputDevice selected;

  /// Whether the device list has been asked for at least once.
  final bool hasEnumerated;

  /// Whether a previously chosen output was missing at startup, so playback
  /// fell back to the system default. Surfaced once, then cleared on the next
  /// choice.
  final bool savedDeviceUnavailable;

  /// Whether the last attempt to route audio was refused by the backend, so
  /// playback is still on [selected]. Cleared by the next successful choice.
  final bool selectionFailed;

  /// Whether an output disappeared *and* the fall back to the system default
  /// was refused too, so audio may not be coming out anywhere.
  ///
  /// This is the "recovery is impossible" state the hotplug work has to surface
  /// rather than leave silently muted (#403). It is recoverable, not terminal:
  /// the card offers a retry, and the next device change or refresh clears it
  /// on its own if the backend comes back.
  final bool outputRecoveryFailed;

  /// Whether playback is currently somewhere other than the output the
  /// listener asked for. What the card shows a "your output is not available"
  /// note for.
  bool get isUsingFallback => savedDeviceUnavailable;

  /// Whether [selected] will still be in effect after a restart. False for the
  /// system default (there is nothing to remember) and for devices named by an
  /// unstable handle, which Linthra deliberately does not store.
  bool get isRemembered => AudioOutputDevice.isPersistableId(selected.id);

  AudioOutputSettingsState copyWith({
    List<AudioOutputDevice>? devices,
    AudioOutputDevice? selected,
    bool? hasEnumerated,
    bool? savedDeviceUnavailable,
    bool? selectionFailed,
    bool? outputRecoveryFailed,
  }) {
    return AudioOutputSettingsState(
      devices: devices ?? this.devices,
      selected: selected ?? this.selected,
      hasEnumerated: hasEnumerated ?? this.hasEnumerated,
      savedDeviceUnavailable:
          savedDeviceUnavailable ?? this.savedDeviceUnavailable,
      selectionFailed: selectionFailed ?? this.selectionFailed,
      outputRecoveryFailed: outputRecoveryFailed ?? this.outputRecoveryFailed,
    );
  }
}

/// Owns the "Audio output" choice: which device playback is routed to, and
/// whether that choice is remembered.
///
/// The routing itself lives in [AudioOutputDeviceService]; this notifier holds
/// the policy around it, which is the part worth testing:
///
///  * a stored device is re-applied on launch, so the choice survives a restart
///    without the user re-picking it;
///  * a stored device that is *not* in the list any more (unplugged headset,
///    another machine, a renamed sink) is dropped rather than pushed at the
///    backend, and playback stays on the system default;
///  * a device whose id will not survive a reboot is applied but not stored,
///    so nothing silently routes to a different card next boot;
///  * a backend that could not be enumerated, or that refused a switch, changes
///    nothing — neither what is stored nor what is shown as playing.
///
/// [build] is deliberately cheap when nothing is stored: it does not enumerate,
/// so launching the app never probes the audio backend just to confirm the
/// default. The Settings card calls [refresh] when it is opened.
///
/// ## Hotplug (#403)
///
/// It also owns what happens when the *host* changes an output underneath
/// playback — a headset unplugged, a Bluetooth speaker dropping and coming
/// back, an HDMI sink appearing when a monitor wakes, the system default
/// moving. [AudioOutputDeviceService.deviceChanges] reports those; the rules
/// for reacting live here, next to the ones above, because they are the same
/// decision seen from the other side.
///
/// The rules, in the order [onDevicesChanged] applies them:
///
///  * **The chosen output is still listed → do nothing.** libmpv keeps playing
///    through a sink that is still there, including across a default-sink
///    change, and re-routing to a device audio is already on would be an
///    audible interruption caused entirely by the recovery code.
///  * **It is listed again after being lost → take it back.** This is the
///    Bluetooth reconnect case, and it is why a hotplug loss deliberately does
///    *not* forget the stored preference.
///  * **It is gone → fall back to the system default and say so.** Playback
///    keeps going somewhere audible, and the card explains why it moved. The
///    preference is kept, so the device coming back restores it.
///  * **The fall back was refused too → surface it.**
///    [AudioOutputSettingsState.outputRecoveryFailed] with a retry, rather than
///    leaving playback silently pointed at a sink that is not there.
///
/// Nothing here starts, stops or reloads playback: recovery is a *routing*
/// decision, so a device event can never produce a second stream. And the
/// device-change subscription is a single one, opened in [build] and closed
/// with the notifier, so a rebuild cannot leave two of them reacting to one
/// unplug.
class AudioOutputController extends AsyncNotifier<AudioOutputSettingsState> {
  /// The output currently pushed at the backend. It starts as the system
  /// default because that is what a fresh process is already on, and it is what
  /// keeps a refresh from re-routing audio it has not been asked to move. It
  /// only ever advances on a switch the backend accepted, so a refused one is
  /// retried rather than assumed done.
  String _appliedId = AudioOutputDevice.systemDefaultId;

  /// The output the listener actually wants, remembered for the session even
  /// while it is unplugged.
  ///
  /// Deliberately separate from the *stored* preference. Disk forgets a device
  /// that was not there at startup — that is the "saved on another machine"
  /// rule from #402 and it stays — but a device that has been seen working this
  /// session and then vanished is a hotplug, not a stale preference, so memory
  /// keeps it and [onDevicesChanged] can hand playback back when it returns.
  String? _desiredId;

  /// Whether [_desiredId] has been observed present since launch. What tells a
  /// hotplug loss apart from a preference that never applied here.
  bool _desiredSeen = false;

  /// The live device-change subscription, or null when nothing is being
  /// watched. Exactly one is ever held.
  StreamSubscription<List<AudioOutputDevice>>? _deviceChanges;

  /// Serializes [select] and [refresh].
  ///
  /// Both route audio, write the preference and publish state. Two of them in
  /// flight at once can finish in the opposite order and leave playback on the
  /// output the listener picked *first*, so they queue instead: the last
  /// gesture is the last one applied.
  Future<void> _operations = Future<void>.value();

  @override
  Future<AudioOutputSettingsState> build() async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return const AudioOutputSettingsState();

    _watchDevices(service);

    final String? storedId =
        await ref.read(playbackPreferencesProvider).audioOutputDeviceId();
    if (storedId == null) return const AudioOutputSettingsState();

    // Nothing has been routed yet, so the system default is what is playing.
    return _resolve(storedId, AudioOutputDevice.systemDefault);
  }

  /// Opens the one device-change subscription, closing it with the notifier.
  ///
  /// Idempotent by construction — it is called once, from [build], and a
  /// rebuild disposes the previous notifier first — but the null check makes
  /// that explicit: two subscriptions would mean one unplug handled twice.
  void _watchDevices(AudioOutputDeviceService service) {
    if (_deviceChanges != null) return;
    _deviceChanges = service.deviceChanges.listen(
      onDevicesChanged,
      // A backend that errors out of its own watch is not a reason to take
      // playback anywhere; the list simply stops updating until a refresh.
      onError: (Object _) {},
    );
    ref.onDispose(() {
      final StreamSubscription<List<AudioOutputDevice>>? subscription =
          _deviceChanges;
      _deviceChanges = null;
      subscription?.cancel();
    });
  }

  /// Applies the hotplug rules to a fresh device list from the backend.
  ///
  /// See the class doc for the rules and why each one is what it is. Queued
  /// behind any in-flight select/refresh for the same reason those queue behind
  /// each other: two routing decisions in flight can complete in the wrong
  /// order and leave playback on the one that was decided first.
  ///
  /// Visible for the tests that drive the lifecycle directly; the running app
  /// reaches it only through [_watchDevices].
  @visibleForTesting
  Future<void> onDevicesChanged(List<AudioOutputDevice> devices) {
    return _enqueue(() async {
      if (devices.isEmpty) return;
      final AudioOutputSettingsState current =
          state.valueOrNull ?? const AudioOutputSettingsState();
      final String desired = _desiredId ?? AudioOutputDevice.systemDefaultId;

      AudioOutputDevice? present;
      for (final AudioOutputDevice device in devices) {
        if (device.id == desired) present = device;
      }

      if (desired == AudioOutputDevice.systemDefaultId) {
        // Nothing was chosen, so the system default is the choice and it
        // follows the host by itself — including when the host moves it.
        // Refresh the list and leave playback exactly where it is.
        state = AsyncData<AudioOutputSettingsState>(
          current.copyWith(devices: devices, hasEnumerated: true),
        );
        return;
      }

      if (present != null) {
        _desiredSeen = true;
        if (_appliedId == present.id) {
          // Still on it: the backend carried playback through the change with
          // no gap, which is the outcome worth protecting. Nothing to re-route.
          state = AsyncData<AudioOutputSettingsState>(
            current.copyWith(
              devices: devices,
              hasEnumerated: true,
              savedDeviceUnavailable: false,
              outputRecoveryFailed: false,
            ),
          );
          return;
        }
        // It is back after being lost — a Bluetooth speaker reconnecting, a
        // monitor waking its HDMI sink. Hand playback back to it.
        final bool routed = await _apply(present);
        state = AsyncData<AudioOutputSettingsState>(
          current.copyWith(
            devices: devices,
            hasEnumerated: true,
            selected: routed ? present : current.selected,
            savedDeviceUnavailable: !routed,
            outputRecoveryFailed: false,
            selectionFailed: false,
          ),
        );
        if (routed) await _rememberIfStable(present);
        return;
      }

      // The chosen output is gone. Keep audio audible on the system default and
      // explain the move; the preference is deliberately kept so the device
      // coming back restores it.
      final bool recovered = await _apply(AudioOutputDevice.systemDefault);
      state = AsyncData<AudioOutputSettingsState>(
        current.copyWith(
          devices: devices,
          hasEnumerated: true,
          selected:
              recovered ? AudioOutputDevice.systemDefault : current.selected,
          savedDeviceUnavailable: true,
          outputRecoveryFailed: !recovered,
        ),
      );
    });
  }

  /// Re-reads the host's output list and re-applies the current choice.
  ///
  /// Called when the Settings card is opened and by its refresh action, so a
  /// device plugged in while the app was running shows up. Also the retry
  /// behind [AudioOutputSettingsState.outputRecoveryFailed]: it re-enumerates
  /// and re-applies, which is exactly what a failed recovery needs.
  Future<void> refresh() async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return;

    return _enqueue(() async {
      // Let an in-flight build settle first: Riverpod publishes its result when
      // it completes, which would land on top of everything below.
      try {
        await future;
      } catch (_) {
        // A failed build is not this refresh's problem; it re-enumerates below.
      }

      final AudioOutputSettingsState current =
          state.valueOrNull ?? const AudioOutputSettingsState();
      state = const AsyncValue<AudioOutputSettingsState>.loading()
          .copyWithPrevious(state);
      state = await AsyncValue.guard(() async {
        final String? storedId =
            await ref.read(playbackPreferencesProvider).audioOutputDeviceId();
        // Fall back to the live selection when nothing is stored: a device
        // picked by an unstable id is session-only, and refreshing the list
        // must not look like the user reset it to the system default.
        final AudioOutputSettingsState resolved =
            await _resolve(storedId ?? current.selected.id, current.selected);
        // Carry the "your saved output is gone" notice across a refresh. By
        // the time the card is opened the stored id has already been dropped,
        // so re-deriving the flag here would always come back false and quietly
        // erase the one explanation the listener has for why playback moved.
        // The next explicit choice clears it.
        return resolved.copyWith(
          savedDeviceUnavailable:
              resolved.savedDeviceUnavailable || current.savedDeviceUnavailable,
        );
      });
    });
  }

  /// Routes playback to [device] and remembers it when its id is stable.
  Future<void> select(AudioOutputDevice device) async {
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    if (!service.isSupported) return;

    return _enqueue(() async {
      state = const AsyncValue<AudioOutputSettingsState>.loading()
          .copyWithPrevious(state);
      final AudioOutputSettingsState current =
          state.valueOrNull ?? const AudioOutputSettingsState();

      if (!await _apply(device)) {
        // The backend refused — the device disappeared between the list and the
        // tap. Playback is still where it was, so nothing is stored and nothing
        // is shown as switched; the card says the switch did not happen.
        state = AsyncData<AudioOutputSettingsState>(
          current.copyWith(selectionFailed: true),
        );
        return;
      }

      // The listener has said what they want. Remembered for the session even
      // if the device later disappears, so a reconnect can hand playback back.
      _desiredId = device.id;
      _desiredSeen = true;
      await _rememberIfStable(device);
      state = AsyncData<AudioOutputSettingsState>(
        current.copyWith(
          selected: device,
          savedDeviceUnavailable: false,
          selectionFailed: false,
          outputRecoveryFailed: false,
        ),
      );
    });
  }

  /// Persists [device] when its id will still mean the same sink after a
  /// reboot, and clears the stored value when it will not.
  Future<void> _rememberIfStable(AudioOutputDevice device) {
    return ref.read(playbackPreferencesProvider).setAudioOutputDeviceId(
          AudioOutputDevice.isPersistableId(device.id) ? device.id : null,
        );
  }

  /// Runs [operation] after every operation already queued.
  Future<void> _enqueue(Future<void> Function() operation) {
    final Future<void> queued = _operations.then((_) => operation());
    // The chain swallows failures so one refused switch cannot wedge every
    // later choice; the caller still sees the original future.
    _operations = queued.then((_) {}, onError: (Object _) {});
    return queued;
  }

  /// Routes to [device] unless the backend is already on it, reporting whether
  /// the backend is on it afterwards.
  ///
  /// Re-asking for the output already in use would make every refresh (and
  /// every launch on a machine that never changed its output) a routing call
  /// into libmpv for no reason.
  Future<bool> _apply(AudioOutputDevice device) async {
    if (device.id == _appliedId) return true;
    if (!await ref.read(audioOutputDeviceServiceProvider).select(device)) {
      return false;
    }
    _appliedId = device.id;
    return true;
  }

  Future<AudioOutputSettingsState> _resolve(
    String desiredId,
    AudioOutputDevice currentSelection,
  ) async {
    if (desiredId != AudioOutputDevice.systemDefaultId) {
      _desiredId = desiredId;
    }
    final AudioOutputDeviceService service =
        ref.read(audioOutputDeviceServiceProvider);
    final List<AudioOutputDevice> devices = await service.devices();

    if (devices.isEmpty) {
      // The backend could not be asked. That is not evidence the chosen device
      // is gone, so nothing is cleared, nothing is re-routed, and the live
      // selection is kept — dropping it here would make the *next* refresh
      // route away from an output the listener is still using. The card just
      // reports that it found no outputs.
      return AudioOutputSettingsState(
        selected: currentSelection,
        hasEnumerated: true,
      );
    }

    for (final AudioOutputDevice device in devices) {
      if (device.id != desiredId) continue;
      _desiredSeen = true;
      final bool routed = await _apply(device);
      return AudioOutputSettingsState(
        devices: devices,
        selected: routed ? device : currentSelection,
        hasEnumerated: true,
        selectionFailed: !routed,
      );
    }

    // The chosen output is not on this machine any more. Fall back to the
    // system default, and forget it *unless* it has been working this session:
    // an id that was never seen here is a preference saved on another machine
    // and the next launch should not keep trying it, but one that played five
    // minutes ago is an unplugged headset, and forgetting it would mean a
    // refresh during a Bluetooth dropout quietly loses the listener's choice.
    final bool wasStored = desiredId != AudioOutputDevice.systemDefaultId;
    if (wasStored) {
      if (!_desiredSeen) {
        await ref
            .read(playbackPreferencesProvider)
            .setAudioOutputDeviceId(null);
      }
      await _apply(AudioOutputDevice.systemDefault);
    }
    return AudioOutputSettingsState(
      devices: devices,
      hasEnumerated: true,
      savedDeviceUnavailable: wasStored,
    );
  }
}

final audioOutputControllerProvider =
    AsyncNotifierProvider<AudioOutputController, AudioOutputSettingsState>(
  AudioOutputController.new,
);
