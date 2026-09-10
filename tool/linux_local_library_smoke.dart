// Local-library sandbox smoke (#447).
//
// Proves that a Flatpak user who explicitly hands Linthra one music folder can
// actually use it (scan it, read its tags and its embedded artwork, and play a
// track out of it) while the rest of the host stays where it was: outside.
//
// It runs from inside the installed Flatpak, driven by
// scripts/flatpak_local_library_smoke.sh, in three modes:
//
//   create   write a disposable fixture library into the selected folder
//   scan     the whole granted flow, plus the isolation assertions
//   revoked  the folder is gone: prove that is a recoverable error, not a wipe
//
// Everything below the folder grant is the production path: the same scanner,
// the same metadata reader, the same artwork cache and the same playback
// controller the app wires up. What this cannot do is press the button in the
// file chooser: that dialog, and the document-portal grant it mints, stay a
// manual step (docs/flatpak-local-library-smoke.md). The grant it stands in for
// is deliberately narrow: one folder, for one run.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/linux_playback_controller.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/filesystem_local_metadata_reader.dart';
import 'package:linthra/core/sources/local/local_library_scanner.dart';
import 'package:linthra/core/sources/local/local_music_source.dart';
import 'package:linthra/core/sources/local/local_scan_report.dart';

// Relative rather than a package: import on purpose. These are the byte-level
// tag builders the local-metadata unit tests already use, and a second copy of
// them would be a second chance to be wrong about the format. They are test
// support, so they must not move into lib/ and ship in the app.
import '../test/core/sources/local/audio_tag_fixtures.dart';

/// The fixture library, exactly as the assertions expect to read it back.
///
/// One tagged WAV that really decodes (so the playback step has something to
/// play), one MP3 carrying an embedded cover (WAV's RIFF INFO chunk has no
/// picture field), and one file that is not audio at all, so the scan can be
/// held to skipping it rather than to a track count that happens to match.
const String _artist = 'Fixture Artist';
const String _album = 'Fixture Album';
const String _wavTitle = 'Opening Tone';
const String _mp3Title = 'Cover Art';
const String _wavRelativePath = '$_artist/$_album/01 - Opening Tone.wav';
const String _mp3RelativePath = '$_artist/$_album/02 - Cover Art.mp3';
const String _textRelativePath = '$_artist/$_album/notes.txt';

/// 3 seconds at 8 kHz mono: long enough to watch playback start, small enough
/// to stay a fixture (48 KB).
const int _fixtureSampleRate = 8000;
const int _fixtureFrames = _fixtureSampleRate * 3;

const Duration _stepTimeout = Duration(seconds: 15);
const Duration _pollInterval = Duration(milliseconds: 50);

Future<void> main() async {
  final _SmokeConfig config = _SmokeConfig.fromEnvironment();
  final _Sanitizer sanitizer = _Sanitizer(root: config.root);

  // No audio device in CI. libmpv's own null output still paces samples against
  // the system clock, which is what "the track actually plays" needs to mean
  // anything (see tool/linux_audio_backend_smoke.dart).
  JustAudioMediaKit.mpvProperties = <String, String>{'ao': config.audioOutput};

  WidgetsFlutterBinding.ensureInitialized();

  int result = 0;
  try {
    switch (config.mode) {
      case _Mode.create:
        await _createFixture(config);
      case _Mode.scan:
        await _validateGrantedFolder(config);
      case _Mode.revoked:
        await _validateRevokedFolder(config);
    }
    stdout.writeln('PASS: local-library smoke (${config.mode.name}) passed.');
  } catch (error, stackTrace) {
    // A user's music paths are private data, and this output is what people
    // paste into issues. Redact before it leaves the process.
    stderr.writeln('FAIL: local-library smoke (${config.mode.name}) failed.');
    stderr.writeln(sanitizer.clean(error.toString()));
    stderr.writeln(sanitizer.clean(stackTrace.toString()));
    result = 1;
  }
  exit(result);
}

// --- create ---------------------------------------------------------------

/// Writes the disposable fixture library into the selected folder.
///
/// Generated rather than committed: no media licence to track, no binaries in
/// review diffs, and a reviewer can read exactly which tag each assertion is
/// about.
Future<void> _createFixture(_SmokeConfig config) async {
  final Directory root = Directory(config.root);
  if (!root.existsSync()) {
    throw StateError(
      'create: the selected folder is not visible in the sandbox. The run '
      'needs the folder grant that stands in for the portal selection.',
    );
  }

  await _write(
    config.root,
    _wavRelativePath,
    AudioTagFixtures.wav(
      title: _wavTitle,
      artist: _artist,
      album: _album,
      track: '1',
      sampleRate: _fixtureSampleRate,
      frames: _fixtureFrames,
    ),
  );
  await _write(
    config.root,
    _mp3RelativePath,
    AudioTagFixtures.mp3(
      title: _mp3Title,
      artist: _artist,
      albumArtist: _artist,
      album: _album,
      track: '2',
      coverImage: await _solidPng(64, 64),
    ),
  );
  await _write(
    config.root,
    _textRelativePath,
    Uint8List.fromList('not audio\n'.codeUnits),
  );

  stdout.writeln('Wrote the fixture library: 2 tracks and 1 non-audio file.');
}

Future<void> _write(String root, String relative, Uint8List bytes) async {
  final File file = File('$root/$relative');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

/// A real PNG, drawn through the same engine the artwork cache decodes with.
Future<Uint8List> _solidPng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw StateError('create: could not encode the cover PNG.');
  return data.buffer.asUint8List();
}

// --- scan -----------------------------------------------------------------

/// The whole granted flow: the folder scans, its tags and artwork come back,
/// a track plays, and nothing else on the host became readable.
Future<void> _validateGrantedFolder(_SmokeConfig config) async {
  if (!Directory(config.root).existsSync()) {
    throw StateError(
      'scan: the selected folder is not visible in the sandbox. Without the '
      'folder grant this run proves nothing about a user-selected library.',
    );
  }

  final LocalLibraryScan scan = await _scan(config.root);

  // The folder read cleanly.
  if (scan.roots.length != 1) {
    throw StateError('scan: expected one root, got ${scan.roots.length}.');
  }
  final LocalRootOutcome outcome = scan.roots.single;
  if (!outcome.available) {
    throw StateError(
      'scan: the selected folder was not readable (${outcome.error}): '
      '${outcome.message ?? 'no message'}',
    );
  }
  if (!scan.isWritable) {
    throw StateError('scan: a clean scan reported itself unsafe to persist.');
  }
  if (scan.report.error != null) {
    throw StateError('scan: the report carries ${scan.report.error}.');
  }

  // Two tracks, and the non-audio file skipped rather than counted.
  if (scan.tracks.length != 2) {
    throw StateError(
      'scan: expected 2 tracks, found ${scan.tracks.length} '
      '(${scan.tracks.map((Track t) => t.title).join(', ')}).',
    );
  }
  if (scan.report.skippedUnsupported < 1) {
    throw StateError(
      'scan: the non-audio fixture file was not skipped '
      '(filesVisited=${scan.report.filesVisited}, '
      'skippedUnsupported=${scan.report.skippedUnsupported}).',
    );
  }
  stdout.writeln(
    'PASS: scanned the selected folder, '
    '${scan.report.filesVisited} files visited, '
    '${scan.tracks.length} tracks imported, '
    '${scan.report.skippedUnsupported} skipped.',
  );

  // Metadata came from the tags, not from the filename.
  final Track wav = _trackEndingWith(scan.tracks, '.wav');
  _expect(wav.title, _wavTitle, 'the WAV title');
  _expect(wav.artistName, _artist, 'the WAV artist');
  _expect(wav.albumName, _album, 'the WAV album');
  _expect(wav.trackNumber, 1, 'the WAV track number');
  if (wav.duration <= Duration.zero) {
    throw StateError('scan: the WAV reported no duration.');
  }
  stdout.writeln('PASS: local metadata loaded from the file\'s own tags.');

  // Embedded artwork was extracted, cached inside the sandbox's private tree,
  // and is a real image.
  final Track mp3 = _trackEndingWith(scan.tracks, '.mp3');
  _expect(mp3.title, _mp3Title, 'the MP3 title');
  final Uri? artwork = mp3.artworkUri;
  if (artwork == null || !artwork.isScheme('file')) {
    throw StateError('scan: no embedded artwork was cached ($artwork).');
  }
  final File cover = File(artwork.toFilePath());
  if (!cover.existsSync() || cover.lengthSync() <= 0) {
    throw StateError('scan: the cached cover is missing or empty.');
  }
  // It belongs to Linthra, not to the user's folder: a scan must never write
  // into the library it was given.
  if (cover.path.startsWith(config.root)) {
    throw StateError(
      'scan: the cover was cached inside the user\'s music folder.',
    );
  }
  final ui.Size size = await _decodedSize(cover);
  if (size.width <= 0 || size.height <= 0) {
    throw StateError('scan: the cached cover does not decode.');
  }
  stdout.writeln(
    'PASS: embedded artwork extracted and cached '
    '(${size.width.toInt()}x${size.height.toInt()}), outside the music folder.',
  );

  // A track out of that folder actually plays.
  await _playFromLibrary(wav);

  // And nothing else on the host came with it.
  _checkIsolation(config);
}

/// Loads the scanned track through the production Linux controller and waits
/// for the clock to move, so "it plays" means playback rather than a status
/// flag.
Future<void> _playFromLibrary(Track track) async {
  final LinuxPlaybackController controller = LinuxPlaybackController();
  try {
    await controller.playTrack(track);
    await controller.play();
    await _waitFor(
      controller,
      (PlaybackState state) =>
          state.status == PlaybackStatus.playing &&
          state.position > Duration.zero,
      'play: the track from the selected folder never started playing',
    );
    stdout.writeln(
      'PASS: played a track from the selected folder '
      '(position ${controller.state.position.inMilliseconds}ms).',
    );
    await controller.stop();
  } finally {
    await controller.dispose();
  }
}

/// The other half of a scoped grant: what must *not* be reachable.
///
/// Both probes live in the host's home directory, next to the selected folder,
/// because that is the interesting case: granting one folder in `$HOME` must
/// not expose the rest of it. Inside the sandbox the host home path resolves to
/// Linthra's own private tree, so neither probe is there at all.
void _checkIsolation(_SmokeConfig config) {
  final String? file = config.forbiddenFile;
  if (file != null) {
    if (File(file).existsSync()) {
      throw StateError(
        'isolation: an unrelated host file is visible inside the sandbox.',
      );
    }
    Object? readError;
    try {
      File(file).readAsBytesSync();
    } catch (error) {
      readError = error;
    }
    if (readError == null) {
      throw StateError(
        'isolation: an unrelated host file could be read inside the sandbox.',
      );
    }
    stdout.writeln('PASS: an unrelated host file stayed unreadable.');
  }

  final String? directory = config.forbiddenDirectory;
  if (directory != null) {
    if (Directory(directory).existsSync()) {
      throw StateError(
        'isolation: a sibling host directory is visible inside the sandbox, '
        'so the folder grant was wider than the folder.',
      );
    }
    stdout.writeln('PASS: a sibling host directory stayed invisible.');
  }

  if (file == null && directory == null) {
    throw StateError(
      'isolation: no host probe was configured, so this run cannot claim the '
      'grant was scoped to the selected folder.',
    );
  }
}

// --- revoked --------------------------------------------------------------

/// The folder the user chose is gone: the drive was unplugged, or the
/// portal document was revoked. That has to be a recoverable error the
/// user can act on, and it must never be mistaken for "this folder is
/// empty now".
Future<void> _validateRevokedFolder(_SmokeConfig config) async {
  if (Directory(config.root).existsSync()) {
    throw StateError(
      'revoked: the folder is still visible in the sandbox, so this run is '
      'not testing revoked access.',
    );
  }

  // What the catalog would already hold for this folder.
  final Track indexed = Track(
    id: '${config.root}/$_wavRelativePath',
    uri: '${config.root}/$_wavRelativePath',
    title: _wavTitle,
    artistName: _artist,
    albumName: _album,
  );

  final LocalLibraryScan retained = await _scan(
    config.root,
    previousTracks: <Track>[indexed],
  );

  final LocalRootOutcome outcome = retained.roots.single;
  if (outcome.error != LocalScanError.folderUnavailable) {
    throw StateError(
      'revoked: the failure was classified ${outcome.error}, not '
      'folderUnavailable, so the user is pointed at the wrong recovery.',
    );
  }
  if (outcome.message == null || outcome.message!.isEmpty) {
    throw StateError('revoked: the failure carries no message for the user.');
  }
  if (!retained.hasUnavailableRoots || !retained.everyRootFailed) {
    throw StateError('revoked: the scan did not report the folder as lost.');
  }
  if (retained.isWritable) {
    throw StateError(
      'revoked: the scan considers itself safe to persist, which would '
      'overwrite the catalog with an empty library.',
    );
  }
  if (retained.tracks.length != 1 ||
      retained.tracks.single.uri != indexed.uri) {
    throw StateError(
      'revoked: the previously indexed track was dropped rather than kept '
      '(${retained.tracks.length} tracks).',
    );
  }
  stdout.writeln(
    'PASS: a revoked folder is a recoverable error: '
    '"${outcome.message}"',
  );
  stdout.writeln('PASS: previously indexed tracks were kept, not wiped.');

  // The same failure with nothing to retain must still refuse to write.
  final LocalLibraryScan bare = await _scan(config.root);
  if (!bare.retentionUnavailable || bare.isWritable) {
    throw StateError(
      'revoked: with no catalog to fall back on the scan must report '
      'retentionUnavailable and refuse to persist '
      '(retentionUnavailable=${bare.retentionUnavailable}, '
      'isWritable=${bare.isWritable}).',
    );
  }
  stdout.writeln(
    'PASS: with nothing to retain, the scan still refuses to persist.',
  );
}

// --- shared ---------------------------------------------------------------

/// The production scan wiring, as `LibraryController.scanFoldersWithReport`
/// assembles it on a desktop: the platform file scanner and the filesystem
/// metadata reader, with the Android-only seams left unsupported.
Future<LocalLibraryScan> _scan(
  String root, {
  List<Track>? previousTracks,
}) {
  final LocalLibraryScanner scanner = LocalLibraryScanner((String each) {
    return LocalMusicSource(
      folderPath: each,
      scanner: const PlatformAudioFileScanner(),
      metadataReader: FilesystemLocalMetadataReader(),
    ).scanTracks();
  });
  return scanner.scan(roots: <String>[root], previousTracks: previousTracks);
}

Track _trackEndingWith(List<Track> tracks, String suffix) {
  for (final Track track in tracks) {
    if (track.uri.endsWith(suffix)) return track;
  }
  throw StateError('scan: no scanned track ends with $suffix.');
}

void _expect(Object? actual, Object? expected, String what) {
  if (actual == expected) return;
  throw StateError('scan: $what is "$actual", expected "$expected".');
}

Future<ui.Size> _decodedSize(File file) async {
  final ui.ImmutableBuffer buffer =
      await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
  final ui.ImageDescriptor descriptor =
      await ui.ImageDescriptor.encoded(buffer);
  final ui.Size size = ui.Size(
    descriptor.width.toDouble(),
    descriptor.height.toDouble(),
  );
  descriptor.dispose();
  return size;
}

Future<void> _waitFor(
  LinuxPlaybackController controller,
  bool Function(PlaybackState state) predicate,
  String describe,
) async {
  final DateTime deadline = DateTime.now().add(_stepTimeout);
  while (!predicate(controller.state)) {
    if (controller.state.status == PlaybackStatus.error) {
      throw StateError(
        '$describe, and the backend errored first: '
        '${controller.state.errorMessage ?? 'no message'}',
      );
    }
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        '$describe (status=${controller.state.status}, '
        'position=${controller.state.position.inMilliseconds}ms).',
      );
    }
    await Future<void>.delayed(_pollInterval);
  }
}

enum _Mode { create, scan, revoked }

class _SmokeConfig {
  const _SmokeConfig({
    required this.mode,
    required this.root,
    required this.forbiddenFile,
    required this.forbiddenDirectory,
    required this.audioOutput,
  });

  factory _SmokeConfig.fromEnvironment() {
    final Map<String, String> env = Platform.environment;
    final String? root = _nonEmpty(env['LINTHRA_LOCAL_LIBRARY_SMOKE_ROOT']);
    if (root == null) {
      throw StateError(
        'LINTHRA_LOCAL_LIBRARY_SMOKE_ROOT is not set: this smoke needs the '
        'folder the user selected.',
      );
    }
    final String requested =
        _nonEmpty(env['LINTHRA_LOCAL_LIBRARY_SMOKE_MODE']) ?? 'scan';
    final _Mode mode = _Mode.values.firstWhere(
      (_Mode candidate) => candidate.name == requested,
      orElse: () => throw StateError(
        'LINTHRA_LOCAL_LIBRARY_SMOKE_MODE="$requested" is not one of '
        '${_Mode.values.map((_Mode m) => m.name).join(', ')}.',
      ),
    );
    return _SmokeConfig(
      mode: mode,
      root: root,
      forbiddenFile: _nonEmpty(env['LINTHRA_LOCAL_LIBRARY_SMOKE_FORBIDDEN']),
      forbiddenDirectory:
          _nonEmpty(env['LINTHRA_LOCAL_LIBRARY_SMOKE_FORBIDDEN_DIR']),
      audioOutput: _nonEmpty(env['LINTHRA_AUDIO_SMOKE_AO']) ?? 'null',
    );
  }

  final _Mode mode;

  /// The folder standing in for the user's chosen music folder.
  final String root;

  /// A host file that must not be readable, and a host directory that must not
  /// be visible. Both live beside [root], so together they say the grant
  /// covered the folder and nothing around it.
  final String? forbiddenFile;
  final String? forbiddenDirectory;

  final String audioOutput;

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;
}

/// Rewrites host identity out of failure output: music paths are private data,
/// and this text ends up in issues.
class _Sanitizer {
  _Sanitizer({required String root})
      : _replacements = <RegExp, String>{
          RegExp(RegExp.escape(root)): '<music-folder>',
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
