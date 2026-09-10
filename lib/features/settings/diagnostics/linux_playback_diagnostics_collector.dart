import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../../../core/diagnostics/linux_playback_diagnostics.dart';
import '../../../core/diagnostics/safe_event_log.dart';
import '../../../core/models/audio_output_device.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/services/linux_mpv_probe.dart';
import '../../../data/repositories/audio_output_device_service_provider.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../../player/player_providers.dart';
import '../playback/audio_output_controller.dart';

/// Reads the libmpv properties Linthra has configured, for the collector.
///
/// A seam so the collector can be exercised without media_kit on the machine
/// running the tests; production reads the vendored plugin's own map.
typedef LinuxMpvPropertiesReader = Map<String, String> Function();

/// The libmpv probe used by [LinuxPlaybackDiagnosticsCollector].
///
/// Overridden in tests; the production binding is the real
/// [LinuxMpvProbe], which only ever reads a live player.
final linuxMpvProbeProvider = Provider<LinuxMpvProbe>((ref) {
  return const LinuxMpvProbe();
});

/// Where the collector reads the applied libmpv properties from.
final linuxMpvPropertiesProvider = Provider<LinuxMpvPropertiesReader>((ref) {
  return () => JustAudioMediaKit.mpvProperties;
});

/// Gathers the Linux playback stack into a [LinuxPlaybackDiagnosticsData].
///
/// It reads only values that are already display-safe — the audio-output
/// controller's *state* (which holds a device id, deliberately reduced here to
/// a driver and a kind), a playback status enum name, and [SafeEventLog]'s
/// structural breadcrumbs — so nothing sensitive can be assembled in the first
/// place. There is no sanitising pass over a raw blob, because no raw blob is
/// ever collected.
///
/// Linux-scoped on purpose: off Linux it reports the honest "no on-device
/// engine here" snapshot and asks the backend nothing. Android's own
/// diagnostics ([AppDiagnostics]) are untouched by this file.
class LinuxPlaybackDiagnosticsCollector {
  LinuxPlaybackDiagnosticsCollector(this._ref);

  final Ref _ref;

  /// Builds the copyable report text.
  Future<String> buildReport() async =>
      LinuxPlaybackDiagnostics.report(await collect());

  /// Gathers the snapshot.
  Future<LinuxPlaybackDiagnosticsData> collect() async {
    final HostPlatform host = _ref.read(hostPlatformProvider);
    if (host != HostPlatform.linux) {
      return const LinuxPlaybackDiagnosticsData(
        backend: LinuxPlaybackBackend.none,
      );
    }

    final LinuxMpvProbeResult probe =
        await _ref.read(linuxMpvProbeProvider).probe();
    final AudioOutputSettingsState output =
        _ref.read(audioOutputControllerProvider).valueOrNull ??
            const AudioOutputSettingsState();
    final AudioOutputDevice selected = output.selected;

    return LinuxPlaybackDiagnosticsData(
      backend: LinuxPlaybackBackend.mediaKitLibmpv,
      libmpv: probe.availability,
      libmpvVersion: LinuxPlaybackDiagnostics.sanitizeVersion(probe.version),
      mpvProperties: LinuxPlaybackDiagnostics.filterMpvProperties(
        _ref.read(linuxMpvPropertiesProvider)(),
      ),
      outputSelectionSupported:
          _ref.read(audioOutputDeviceServiceProvider).isSupported,
      // A count only when there is one to report. An enumeration that was
      // attempted and came back empty is a backend that did not answer (#402
      // reports it that way), so it is published as a failure rather than as
      // "this machine has zero outputs".
      outputsEnumerated:
          output.devices.isNotEmpty ? output.devices.length : null,
      outputEnumerationFailed: output.hasEnumerated && output.devices.isEmpty,
      selectedOutputDriver: AudioOutputDriver.fromDeviceId(selected.id),
      selectedOutputKind: AudioOutputKind.fromDeviceId(selected.id),
      selectedOutputIsSystemDefault: selected.isSystemDefault,
      selectedOutputRemembered: output.isRemembered,
      savedOutputUnavailable: output.savedDeviceUnavailable,
      lastSelectionFailed: output.selectionFailed,
      // Linux is the platform that arms the post-suspend reload; the controller
      // is constructed with it in `LinuxPlaybackController`.
      suspendRecoveryEnabled: true,
      playbackStatus: _ref.read(playbackControllerProvider).state.status.name,
      recentFailures: recentFailures(SafeEventLog.instance),
    );
  }

  /// Aggregates the safe event log's playback-error breadcrumbs into kinds and
  /// counts, most frequent first.
  ///
  /// [SafeEventLog] is already the bounded, secret-free record: an entry is a
  /// fixed category plus a structural detail, and there is no field on it for a
  /// raw error. Reading it rather than adding a second failure sink is what
  /// keeps this report safe by construction — the raw engine error, the one
  /// value that can carry a tokenized URL, is never collected anywhere.
  static List<LinuxPlaybackFailure> recentFailures(SafeEventLog log) {
    final Map<String, int> counts = <String, int>{};
    for (final SafeEvent event in log.events) {
      if (event.category != 'error') continue;
      counts[event.detail] = (counts[event.detail] ?? 0) + 1;
    }
    final List<MapEntry<String, int>> entries = counts.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
        final int byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return <LinuxPlaybackFailure>[
      for (final MapEntry<String, int> entry in entries)
        LinuxPlaybackFailure(kind: entry.key, count: entry.value),
    ];
  }
}

final linuxPlaybackDiagnosticsCollectorProvider =
    Provider<LinuxPlaybackDiagnosticsCollector>((ref) {
  return LinuxPlaybackDiagnosticsCollector(ref);
});

/// The report builder the Linux diagnostics card calls.
final linuxPlaybackDiagnosticsReportProvider =
    Provider<Future<String> Function()>((ref) {
  return ref.read(linuxPlaybackDiagnosticsCollectorProvider).buildReport;
});
