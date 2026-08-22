import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:linthra/core/models/playback_source.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';

Future<void> main() async {
  // Headless CI has no PipeWire/Pulse device. Force libmpv onto ALSA so the
  // workflow's ALSA_CONFIG_PATH null PCM can satisfy ao init without hardware.
  JustAudioMediaKit.mpvProperties = const {'ao': 'alsa'};

  WidgetsFlutterBinding.ensureInitialized();

  final directory =
      await Directory.systemTemp.createTemp('linthra_linux_audio_smoke_');
  final audioFile = File('${directory.path}/silence.wav');
  await audioFile.writeAsBytes(_silentWav(), flush: true);
  var result = 0;

  try {
    for (var cycle = 0; cycle < 3; cycle++) {
      await _exerciseLifecycle(audioFile.path);
    }
    stdout.writeln('Linux native audio lifecycle smoke passed.');
  } catch (error, stackTrace) {
    stderr.writeln('Linux native audio lifecycle smoke failed:');
    stderr.writeln(error);
    stderr.writeln(stackTrace);
    result = 1;
  } finally {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }
  exit(result);
}

Future<void> _exerciseLifecycle(String path) async {
  final controller = LinuxPlaybackController();
  try {
    await controller.playTrack(
      Track(id: 'smoke', title: 'Silent smoke sample', uri: path),
    );
    await controller.play();

    // Assert while the track is still loaded: stop() clears [PlaybackState.source]
    // by design, so checking afterward would always fail even when libmpv opened
    // the WAV successfully.
    if (controller.state.status == PlaybackStatus.error) {
      throw StateError(
        controller.state.errorMessage ?? 'The native backend rejected the WAV.',
      );
    }
    if (controller.state.source != PlaybackSource.localFile) {
      throw StateError('The native backend did not load the local WAV.');
    }

    await controller.stop();
  } finally {
    await controller.dispose();
  }
}

Uint8List _silentWav() {
  const sampleRate = 8000;
  const channelCount = 1;
  const bytesPerSample = 2;
  const frameCount = 800;
  const dataSize = frameCount * channelCount * bytesPerSample;
  const headerSize = 44;
  final bytes = ByteData(headerSize + dataSize);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
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

  return bytes.buffer.asUint8List();
}
