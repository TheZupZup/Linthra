import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/linthra_core.dart';
import 'package:linthra/core/sources/local/audio_file_scanner.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/native_audio_file_scanner.dart';

/// The Rust walk has to find exactly what the Dart walk finds, in the same
/// order, report the same skipped folders and unusable names, and fail with
/// the same exception. A drift either drops songs from the library or keeps
/// ones that are gone.
///
/// Real folders, through the real Rust library hook/build.dart builds for
/// the test host; skipped without it (CI sets LINTHRA_REQUIRE_RUST=1, which
/// fails linthra_core_test.dart instead). Stalled storage and unreadable
/// subfolders can't be staged here without running a process (chmod), so
/// the Rust tests (native/linthra_core/src/scan/walk.rs) cover them with a
/// fake filesystem.
void main() {
  final Object skip = LinthraCore.isAvailable
      ? false
      : 'Rust core not built (install Rust, or see native/linthra_core/README.md)';

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('linthra_walk_'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('native folder walk', skip: skip, () {
    test('matches Dart on a tree with every kind of entry', () async {
      final String root = temp.path;
      _file('$root/a.flac');
      _file('$root/sub/b.mp3');
      _file('$root/sub/deeper/c.ogg');
      _file('$root/sub/deeper/notes.txt');
      _file('$root/literal �.flac');
      Directory('$root/empty').createSync();
      Link('$root/link.flac').createSync('$root/a.flac');
      Link('$root/linkdir').createSync('$root/sub');
      Link('$root/dangling').createSync('$root/nowhere');
      // Neither a file nor a folder: listed as a file by both.
      final ServerSocket socket = await ServerSocket.bind(
        InternetAddress('$root/sock', type: InternetAddressType.unix),
        0,
      );
      addTearDown(socket.close);
      // Names that aren't UTF-8: a Latin-1 é, a lone continuation byte, and
      // a folder (whose file is then unreachable as text).
      _rawFile(root, <int>[...'caf'.codeUnits, 0xE9, ...'.flac'.codeUnits]);
      _rawFile(
          '$root/sub', <int>[...'odd'.codeUnits, 0x80, ...'.mp3'.codeUnits]);
      final List<int> badDir = <int>[
        ...'bad'.codeUnits,
        0xFF,
        ...'dir'.codeUnits
      ];
      Directory.fromRawPath(_raw(root, badDir)).createSync();
      File.fromRawPath(
              _raw(root, <int>[...badDir, ...'/inside.flac'.codeUnits]))
          .createSync();
      await _expectSame(root);
      await _expectSame('$root/');
    });

    test('matches Dart when the folder is missing or is a file', () async {
      await _expectSame('${temp.path}/missing');
      _file('${temp.path}/plain.flac');
      await _expectSame('${temp.path}/plain.flac');
    });

    test('matches Dart on random trees', () async {
      final Random random = Random(17);
      for (int i = 0; i < 40; i++) {
        final Directory tree = Directory('${temp.path}/t$i')..createSync();
        _randomTree(random, tree.path, depth: 0);
        await _expectSame(tree.path);
      }
    });
  });
}

/// Both walks of [folder]: their paths, reports and failure.
Future<void> _expectSame(String folder) async {
  final _Run dart = await _run(const IoAudioFileScanner(), folder);
  final _Run rust = await _run(const NativeAudioFileScanner(), folder);
  expect(rust.paths, dart.paths, reason: folder);
  expect(rust.unreadable, dart.unreadable, reason: folder);
  expect(rust.unopenable, dart.unopenable, reason: folder);
  expect(rust.failure, dart.failure, reason: folder);
}

class _Run {
  List<String> paths = <String>[];
  final List<String> unreadable = <String>[];
  final List<String> unopenable = <String>[];
  String? failure;
}

Future<_Run> _run(AudioFileScanner scanner, String folder) async {
  final _Run run = _Run();
  try {
    run.paths = await scanner.listFiles(
      folder,
      onUnreadableDirectory: run.unreadable.add,
      onUnopenableName: run.unopenable.add,
    );
  } on FolderScanException catch (e) {
    run.failure = '${e.code} ${e.folder} ${e.message}';
  }
  return run;
}

void _file(String path) => File(path)
  ..createSync(recursive: true)
  ..writeAsStringSync('x');

void _randomTree(Random random, String dir, {required int depth}) {
  for (int i = 0; i < random.nextInt(6); i++) {
    final String name = <String>['a', 'b', 'Ä', 'z z', '.hidden', '中'][i % 6];
    switch (random.nextInt(depth < 3 ? 4 : 2)) {
      case 0:
      case 1:
        _file('$dir/$name$i.flac');
      case 2:
        Directory('$dir/$name$i').createSync();
        _randomTree(random, '$dir/$name$i', depth: depth + 1);
      default:
        Link('$dir/l$i').createSync(random.nextBool() ? dir : '$dir/x');
    }
  }
}

/// [name]'s raw bytes under [dir].
Uint8List _raw(String dir, List<int> name) =>
    Uint8List.fromList(<int>[...utf8.encode('$dir/'), ...name]);

void _rawFile(String dir, List<int> name) =>
    File.fromRawPath(_raw(dir, name)).createSync();
