// Linux native audio lifecycle smoke.
//
// Drives Linthra's real Linux playback controller (the same
// media_kit/libmpv stack the shipped app uses) through a full transport
// lifecycle against a generated local fixture:
//
//   initialize -> load -> play -> pause -> seek -> stop -> dispose
//
// It runs in two places, from the same source (#446):
//
//   * the native Linux workflow, against the host's libmpv, and
//   * an installed Flatpak, against the libmpv built by the manifest
//     (scripts/flatpak_audio_smoke.sh).
//
// The Flatpak run is the one that catches packaging mistakes, and it only
// catches them if the library under test really is the packaged one. Set
// LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX and this smoke reads back the
// libmpv the process actually mapped and fails when it came from anywhere
// else, so a host install can never stand in for a broken package.
//
// Nothing here touches the network or any credential: the fixture is a few
// dozen kilobytes of PCM generated at startup into a private temp directory,
// so there is no fixture binary to license, host, or keep in sync.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';

/// How long the generated fixture plays for.
///
/// Long enough that a seek lands well inside it and playback can be observed
/// advancing both before and after that seek, short enough that three cycles
/// stay a smoke test. At 8 kHz mono 16-bit this is 80 KB of PCM.
const Duration _fixtureDuration = Duration(seconds: 5);

/// Where the seek step aims. Comfortably inside [_fixtureDuration] so the
/// track cannot complete while the assertion is still polling.
const Duration _seekTarget = Duration(seconds: 2);

/// Position reporting is coalesced onto a ~4 Hz flush by the controller
/// (`_positionFlushInterval`), and libmpv only reports whole audio frames, so
/// every position assertion below is a band, never an equality.
const Duration _positionTolerance = Duration(milliseconds: 600);

/// The most a paused position may drift over [_pauseObservation] before the
/// pause is considered not to have taken. One coalesced flush of a tick
/// sampled just before the pause is legitimate; a second one is playback.
const Duration _pauseDriftAllowance = Duration(milliseconds: 300);

/// How long a paused position is watched to prove it is actually held.
const Duration _pauseObservation = Duration(milliseconds: 1000);

/// Bound on every wait for the engine to reach a state.
const Duration _stepTimeout = Duration(seconds: 15);

const Duration _pollInterval = Duration(milliseconds: 50);

Future<void> main() async {
  final _SmokeConfig config = _SmokeConfig.fromEnvironment();

  // No CI runner has an audio device, so the default output is libmpv's own
  // `null` AO: it discards the samples but still paces them against the system
  // clock, which is what the position, pause and seek assertions below need.
  // ALSA's null PCM is not a substitute, since it accepts data as fast as the
  // decoder produces it, so a five-second fixture finishes in milliseconds and
  // there is no playback left to observe.
  //
  // Decode, timing, seeking and the transport are all real; the final hop to
  // hardware is not exercised, and stays a manual check
  // (docs/flatpak-audio-smoke.md). Set LINTHRA_AUDIO_SMOKE_AO=pulse to hear it.
  //
  // This is merged into Linthra's production libmpv properties rather than
  // replacing them (see resolveLinuxMpvProperties), so the smoke exercises the
  // same libmpv configuration users run, with only the output swapped.
  JustAudioMediaKit.mpvProperties = <String, String>{'ao': config.audioOutput};

  WidgetsFlutterBinding.ensureInitialized();

  final Directory directory =
      await Directory.systemTemp.createTemp('linthra_linux_audio_smoke_');
  final _Sanitizer sanitizer = _Sanitizer(fixtureDirectory: directory.path);
  final File audioFile = File('${directory.path}/fixture.wav');
  await audioFile.writeAsBytes(_fixtureWav(_fixtureDuration), flush: true);
  int result = 0;

  stdout.writeln(
    'Linux native audio lifecycle smoke: '
    '${config.cycles} cycle(s), ao=${config.audioOutput}.',
  );

  try {
    for (int cycle = 1; cycle <= config.cycles; cycle++) {
      stdout.writeln('--- cycle $cycle/${config.cycles} ---');
      await _exerciseLifecycle(config, audioFile.path);
    }
    stdout.writeln('PASS: Linux native audio lifecycle smoke passed.');
  } catch (error, stackTrace) {
    // Sanitized on the way out: a failure here is pasted into issues and CI
    // logs, and the raw text carries the host's home directory, login name and
    // XDG runtime path through libmpv's own error strings.
    stderr.writeln('FAIL: Linux native audio lifecycle smoke failed.');
    stderr.writeln(sanitizer.clean(error.toString()));
    stderr.writeln(sanitizer.clean(stackTrace.toString()));
    result = 1;
  } finally {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }
  exit(result);
}

/// One full pass: initialize, load, play, pause, seek, stop, dispose.
///
/// Each step asserts before moving on, so a failure names the transition that
/// broke rather than reporting that the whole lifecycle "did not work".
Future<void> _exerciseLifecycle(_SmokeConfig config, String path) async {
  // initialize: constructing the controller is what registers media_kit and
  // brings libmpv into the process.
  final LinuxPlaybackController controller = LinuxPlaybackController();
  try {
    // load: playTrack resolves the URI and starts the engine on it.
    await controller.playTrack(
      Track(id: 'smoke', title: 'Linthra audio smoke fixture', uri: path),
    );

    // The mapping only exists once the backend has really been brought up, so
    // this is checked after the first load rather than at construction.
    _checkLoadedLibmpv(config);

    _failOnError(controller, 'load');
    if (controller.state.source != PlaybackSource.localFile) {
      throw StateError(
        'load: the native backend did not load the local WAV '
        '(source=${controller.state.source}).',
      );
    }
    await _waitFor(
      controller,
      (PlaybackState state) => state.duration > Duration.zero,
      'load: libmpv never reported a duration for the fixture',
    );
    final Duration duration = controller.state.duration;
    if ((duration - _fixtureDuration).abs() >
        const Duration(milliseconds: 500)) {
      throw StateError(
        'load: libmpv reported ${_ms(duration)} for a '
        '${_ms(_fixtureDuration)} fixture, so it decoded something other than '
        'the file that was written.',
      );
    }

    // play, and prove the clock is really running, not just that a status
    // flipped.
    await controller.play();
    await _waitFor(
      controller,
      (PlaybackState state) => state.status == PlaybackStatus.playing,
      'play: the engine never reached the playing state',
    );
    await _waitFor(
      controller,
      (PlaybackState state) => state.position > Duration.zero,
      'play: the position never advanced past zero',
    );

    // pause: the position must stop moving, not merely report paused.
    await controller.pause();
    await _waitFor(
      controller,
      (PlaybackState state) => state.status == PlaybackStatus.paused,
      'pause: the engine never reported paused',
    );
    // Let one already-sampled position tick flush before taking the baseline.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final Duration pausedAt = controller.state.position;
    await Future<void>.delayed(_pauseObservation);
    final Duration afterPause = controller.state.position;
    if ((afterPause - pausedAt).abs() > _pauseDriftAllowance) {
      throw StateError(
        'pause: the position moved from ${_ms(pausedAt)} to '
        '${_ms(afterPause)} while paused.',
      );
    }

    // seek, while paused, which is the harder case: the position only moves
    // if the seek itself reports back.
    await controller.seek(_seekTarget);
    await _waitFor(
      controller,
      (PlaybackState state) =>
          (state.position - _seekTarget).abs() <= _positionTolerance,
      'seek: the position never landed within ${_ms(_positionTolerance)} of '
      '${_ms(_seekTarget)}',
    );
    _failOnError(controller, 'seek');

    // Playing on from the seek point proves the engine seeked the decoder and
    // not just its reported position.
    //
    // Measured from where the seek actually landed, not from the target. The
    // band above accepts a position slightly past ${_ms(_seekTarget)}, so
    // comparing against the target again would already be true before the
    // engine resumed, and would pass even if play() left it paused.
    final Duration landedAt = controller.state.position;
    await controller.play();
    await _waitFor(
      controller,
      (PlaybackState state) =>
          state.status == PlaybackStatus.playing && state.position > landedAt,
      'seek: playback did not resume past ${_ms(landedAt)}, where the seek '
      'landed',
    );

    // stop: a definitive stop clears the loaded source.
    await controller.stop();
    if (controller.state.source != null) {
      throw StateError(
        'stop: the loaded source survived stop '
        '(source=${controller.state.source}).',
      );
    }
    if (controller.state.status != PlaybackStatus.idle) {
      throw StateError(
        'stop: the engine settled on ${controller.state.status} rather than '
        'idle.',
      );
    }
  } finally {
    // dispose, always, so a failed cycle cannot leave libmpv holding the
    // audio device for the cycles after it.
    await controller.dispose();
  }
}

/// Fails when the controller is sitting in an error state, quoting the
/// engine's own message so the reason is in the output.
void _failOnError(LinuxPlaybackController controller, String step) {
  if (controller.state.status != PlaybackStatus.error) return;
  throw StateError(
    '$step: the native backend reported an error: '
    '${controller.state.errorMessage ?? 'no message'}',
  );
}

/// Polls [controller] until [predicate] holds, or fails with [describe].
Future<void> _waitFor(
  LinuxPlaybackController controller,
  bool Function(PlaybackState state) predicate,
  String describe,
) async {
  final DateTime deadline = DateTime.now().add(_stepTimeout);
  while (!predicate(controller.state)) {
    // An engine that has failed will never satisfy the predicate; report the
    // real reason instead of timing out on it.
    if (controller.state.status == PlaybackStatus.error) {
      throw StateError(
        '$describe, and the backend errored first: '
        '${controller.state.errorMessage ?? 'no message'}',
      );
    }
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        '$describe (after ${_ms(_stepTimeout)}; '
        'status=${controller.state.status}, '
        'position=${_ms(controller.state.position)}, '
        'duration=${_ms(controller.state.duration)}).',
      );
    }
    await Future<void>.delayed(_pollInterval);
  }
}

/// Reads back the libmpv this process actually mapped and, when the caller
/// declared where it must come from, holds it to that.
///
/// This is the check that makes the Flatpak run meaningful. Inside the sandbox
/// there is no host `/usr/lib` to fall back to, but that is a property of the
/// sandbox rather than something this test proves, and outside it, a host
/// libmpv is exactly what would let a package that ships no libmpv at all look
/// healthy. Reading `/proc/self/maps` names the file the loader really opened.
void _checkLoadedLibmpv(_SmokeConfig config) {
  final List<String> mapped = _mappedLibmpvPaths();
  if (mapped.isEmpty) {
    throw StateError(
      'initialize: no libmpv is mapped into this process, so the media_kit '
      'backend never loaded.',
    );
  }
  stdout.writeln('libmpv in use: ${mapped.join(', ')}');

  final String? required = config.requiredLibmpvPrefix;
  if (required == null) return;

  final List<String> foreign = mapped
      .where((String path) => !path.startsWith(required))
      .toList(growable: false);
  if (foreign.isNotEmpty) {
    throw StateError(
      'initialize: libmpv was loaded from ${foreign.join(', ')}, outside the '
      'required $required. A libmpv from elsewhere can hide a package that '
      'ships a broken or missing one.',
    );
  }
}

/// Distinct on-disk paths of every mapped libmpv, from `/proc/self/maps`.
List<String> _mappedLibmpvPaths() {
  final File maps = File('/proc/self/maps');
  if (!maps.existsSync()) {
    throw StateError(
      'initialize: /proc/self/maps is unavailable, so the loaded libmpv '
      'cannot be identified.',
    );
  }
  final Set<String> paths = <String>{};
  for (final String line in maps.readAsLinesSync()) {
    // Mapping lines end with the backing file's path, when they have one:
    //   7f...-7f... r-xp 00000000 fd:00 1234  /app/lib/libmpv.so.2.5.0
    final int start = line.indexOf('/');
    if (start < 0) continue;
    final String path = line.substring(start);
    if (path.contains('/libmpv.so')) paths.add(path);
  }
  return paths.toList(growable: false)..sort();
}

/// Runtime knobs, all optional so the default invocation stays the one the
/// native Linux workflow already used.
class _SmokeConfig {
  const _SmokeConfig({
    required this.audioOutput,
    required this.cycles,
    required this.requiredLibmpvPrefix,
  });

  factory _SmokeConfig.fromEnvironment() {
    final Map<String, String> env = Platform.environment;
    final String? prefix = env['LINTHRA_AUDIO_SMOKE_REQUIRE_LIBMPV_PREFIX'];
    return _SmokeConfig(
      audioOutput: _nonEmpty(env['LINTHRA_AUDIO_SMOKE_AO']) ?? 'null',
      cycles: int.tryParse(env['LINTHRA_AUDIO_SMOKE_CYCLES'] ?? '') ?? 3,
      requiredLibmpvPrefix: _nonEmpty(prefix),
    );
  }

  final String audioOutput;
  final int cycles;

  /// Directory prefix the loaded libmpv must sit under, or null to accept
  /// whichever one the host resolved.
  final String? requiredLibmpvPrefix;

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;
}

/// Rewrites host-identifying strings out of failure output.
///
/// libmpv quotes the file it failed on, Dart quotes the temp directory, and
/// both carry the login name on a developer machine. None of it helps anyone
/// read the failure, and all of it ends up pasted into issues.
class _Sanitizer {
  _Sanitizer({required String fixtureDirectory})
      : _replacements = <RegExp, String>{
          RegExp(RegExp.escape(fixtureDirectory)): '<fixture-dir>',
          // Home first: a login name is usually only visible as part of it.
          if (_home != null) RegExp(RegExp.escape(_home!)): '<home>',
          RegExp(r'''/home/[^/\s"']+'''): '/home/<user>',
          RegExp(r'/run/user/\d+'): '/run/user/<uid>',
          if (_user != null)
            RegExp(r'\b' + RegExp.escape(_user!) + r'\b'): '<user>',
        };

  static final String? _home = _nonEmptyEnv('HOME');
  static final String? _user = _nonEmptyEnv('USER') ?? _nonEmptyEnv('LOGNAME');

  final Map<RegExp, String> _replacements;

  String clean(String text) {
    String cleaned = text;
    _replacements.forEach((RegExp pattern, String replacement) {
      cleaned = cleaned.replaceAll(pattern, replacement);
    });
    return cleaned;
  }

  static String? _nonEmptyEnv(String name) {
    final String? value = Platform.environment[name];
    return (value == null || value.isEmpty) ? null : value;
  }
}

String _ms(Duration duration) => '${duration.inMilliseconds}ms';

/// A tiny mono 16-bit PCM WAV of [duration].
///
/// Generated rather than committed: there is no licence to track, nothing to
/// keep in sync with the test that reads it, and a reviewer can see exactly
/// what the decoder is being handed. It is a quiet tone rather than pure
/// silence so the decoder produces real sample values, and quiet enough that
/// a run against a real device on a developer machine is not startling.
Uint8List _fixtureWav(Duration duration) {
  const int sampleRate = 8000;
  const int channelCount = 1;
  const int bytesPerSample = 2;
  const int headerSize = 44;
  const double toneHz = 440;
  const double amplitude = 0.05;

  final int frameCount = (sampleRate * duration.inMilliseconds) ~/ 1000;
  final int dataSize = frameCount * channelCount * bytesPerSample;
  final ByteData bytes = ByteData(headerSize + dataSize);

  void writeAscii(int offset, String value) {
    for (int index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, channelCount, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(
    28,
    sampleRate * channelCount * bytesPerSample,
    Endian.little,
  );
  bytes.setUint16(32, channelCount * bytesPerSample, Endian.little);
  bytes.setUint16(34, bytesPerSample * 8, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);

  for (int frame = 0; frame < frameCount; frame++) {
    final double sample =
        amplitude * math.sin(2 * math.pi * toneHz * frame / sampleRate);
    bytes.setInt16(
      headerSize + frame * bytesPerSample,
      (sample * 32767).round(),
      Endian.little,
    );
  }

  return bytes.buffer.asUint8List();
}
