import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/native/api/scan.dart';
import 'package:linthra/core/sources/local/folder_scan_exception.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/native_audio_file_scanner.dart';

/// The folder walk on real folders: every file found, nothing else, and a
/// folder that can't be walked failing instead of answering "no music".
///
/// Through the real Rust library hook/build.dart builds for the test host.
/// Folders that stop answering, fail mid-walk or go away before the walk
/// ends can't be staged on a real disk, so the Rust tests
/// (native/linthra_core/src/scan/walk.rs) cover them with a fake filesystem;
/// what the scan does with those failures is covered by
/// test/features/library/.
void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('linthra_walk_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('lists every file, at any depth, and nothing else', () async {
    final String root = temp.path;
    _file('$root/a.flac');
    _file('$root/sub/b.mp3');
    _file('$root/sub/deeper/c.ogg');
    // Deciding what is audio is the caller's job.
    _file('$root/sub/deeper/notes.txt');
    // A name that really holds U+FFFD is valid UTF-8 and opens fine.
    _file('$root/literal �.flac');
    Directory('$root/empty').createSync();
    // Links are neither walked nor listed, so a link loop can't trap the
    // walk and no song is indexed twice.
    Link('$root/link.flac').createSync('$root/a.flac');
    Link('$root/linkdir').createSync('$root/sub');
    Link('$root/dangling').createSync('$root/nowhere');
    // Neither a file nor a folder: listed as a file.
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress('$root/sock', type: InternetAddressType.unix),
      0,
    );
    addTearDown(socket.close);

    for (final String folder in <String>[root, '$root/']) {
      final _Run run = await _run(folder);
      expect(run.failure, isNull);
      expect(run.paths..sort(), <String>[
        '$root/a.flac',
        '$root/literal �.flac',
        '$root/sock',
        '$root/sub/b.mp3',
        '$root/sub/deeper/c.ogg',
        '$root/sub/deeper/notes.txt',
      ]);
      expect(run.unreadable, isEmpty);
      expect(run.unopenable, isEmpty);
    }
  });

  test(
      'names that are not valid UTF-8 are reported, never listed as files '
      "that can't open (#817)", () async {
    final String root = temp.path;
    _file('$root/fine.flac');
    // A Latin-1 é, the way an old Windows rip names it, and a lone
    // continuation byte.
    _rawFile(root, <int>[...'caf'.codeUnits, 0xE9, ...'.flac'.codeUnits]);
    _rawFile('$root/sub', <int>[...'odd'.codeUnits, 0x80, ...'.mp3'.codeUnits],
        createParent: true);
    // A folder: what is under it can't be reached as text either.
    final List<int> badDir = <int>[
      ...'bad'.codeUnits,
      0xFF,
      ...'dir'.codeUnits
    ];
    Directory.fromRawPath(_raw(root, badDir)).createSync();
    File.fromRawPath(_raw(root, <int>[...badDir, ...'/inside.flac'.codeUnits]))
        .createSync();

    final _Run run = await _run(root);

    expect(run.failure, isNull);
    expect(run.paths, <String>['$root/fine.flac']);
    expect(run.paths.every((String path) => File(path).existsSync()), isTrue);
    expect(run.unopenable..sort(), <String>[
      '$root/bad�dir',
      '$root/caf�.flac',
      '$root/sub/odd�.mp3',
    ]);
    // The folder isn't "unreadable": nothing under it was ever indexed to
    // keep.
    expect(run.unreadable, isEmpty);
  }, skip: Platform.isLinux ? false : 'raw byte names are a Linux case');

  test('a folder that is gone fails the walk instead of finding nothing',
      () async {
    // A selected folder that no longer resolves (an unmounted drive, a
    // deleted folder, a revoked portal document) must not look like an empty
    // one: that answer would be saved and wipe a catalog the user's files
    // are still behind.
    final String missing = '${temp.path}/missing';
    final _Run run = await _run(missing);

    expect(run.paths, isEmpty);
    expect(run.failure!.code, LocalRootFault.missing.code);
    expect(run.failure!.folder, missing);
    expect(run.failure!.message, contains("couldn't find the selected folder"));
  });

  test('a file picked as the folder fails the walk', () async {
    _file('${temp.path}/plain.flac');
    final _Run run = await _run('${temp.path}/plain.flac');

    expect(run.paths, isEmpty);
    expect(run.failure, isNotNull);
    expect(run.failure!.folder, '${temp.path}/plain.flac');
  });

  test('random trees: every file made, no link, nothing reported', () async {
    final Random random = Random(17);
    for (int i = 0; i < 40; i++) {
      final Directory tree = Directory('${temp.path}/t$i')..createSync();
      final List<String> files = _randomTree(random, tree.path, depth: 0);
      final _Run run = await _run(tree.path);
      expect(run.failure, isNull, reason: tree.path);
      expect(run.paths..sort(), files..sort(), reason: tree.path);
      expect(run.unreadable, isEmpty, reason: tree.path);
      expect(run.unopenable, isEmpty, reason: tree.path);
    }
  });

  group('a walk that failed is told to the user as', () {
    WalkFault fault({bool interrupted = false, bool stalled = false, int? e}) =>
        WalkFault(interrupted: interrupted, stalled: stalled, errno: e);

    test('the drive going away when the folder went away mid-walk (#415)', () {
      // The folder was there when the walk began, so it found *some* files,
      // and every folder still pending failed. Saving that half-walk would
      // conclude every file it never reached was deleted.
      final FolderScanException error =
          walkFailureException('/m', fault(interrupted: true, e: 2));
      expect(
          error.message, contains('disconnected while it was being scanned'));
      expect(error.message, contains('Reconnect it'));
      expect(error.code, LocalRootFault.missing.code);
      expect(error.folder, '/m');
    });

    test('unavailable storage when it stopped answering (#778)', () {
      expect(
        walkFailureException('/m', fault(stalled: true)).code,
        LocalRootFault.unavailable.code,
      );
      expect(
        walkFailureException('/m', fault(interrupted: true, stalled: true))
            .code,
        LocalRootFault.unavailable.code,
      );
    });

    test('the fault its errno names when the folder could not be opened', () {
      expect(
        walkFailureException('/m', fault(e: 2)).code,
        LocalRootFault.missing.code,
      );
      expect(
        walkFailureException('/m', fault(e: 13)).code,
        LocalRootFault.permissionDenied.code,
      );
      expect(
        walkFailureException('/m', fault(e: 2)).message,
        contains("couldn't find the selected folder"),
      );
    });
  });
}

class _Run {
  List<String> paths = <String>[];
  final List<String> unreadable = <String>[];
  final List<String> unopenable = <String>[];
  FolderScanException? failure;
}

Future<_Run> _run(String folder) async {
  final _Run run = _Run();
  try {
    run.paths = await const NativeAudioFileScanner().listFiles(
      folder,
      onUnreadableDirectory: run.unreadable.add,
      onUnopenableName: run.unopenable.add,
    );
  } on FolderScanException catch (e) {
    run.failure = e;
  }
  return run;
}

void _file(String path) => File(path)
  ..createSync(recursive: true)
  ..writeAsStringSync('x');

/// A random tree under [dir]: files, folders, links to either or to nothing.
/// The files it made, which are all a walk should find.
List<String> _randomTree(Random random, String dir, {required int depth}) {
  final List<String> files = <String>[];
  for (int i = 0; i < random.nextInt(6); i++) {
    final String name = <String>['a', 'b', 'Ä', 'z z', '.hidden', '中'][i % 6];
    switch (random.nextInt(depth < 3 ? 4 : 2)) {
      case 0:
      case 1:
        _file('$dir/$name$i.flac');
        files.add('$dir/$name$i.flac');
      case 2:
        Directory('$dir/$name$i').createSync();
        files.addAll(_randomTree(random, '$dir/$name$i', depth: depth + 1));
      default:
        Link('$dir/l$i').createSync(random.nextBool() ? dir : '$dir/x');
    }
  }
  return files;
}

/// [name]'s raw bytes under [dir].
Uint8List _raw(String dir, List<int> name) =>
    Uint8List.fromList(<int>[...utf8.encode('$dir/'), ...name]);

void _rawFile(String dir, List<int> name, {bool createParent = false}) {
  if (createParent) Directory(dir).createSync(recursive: true);
  File.fromRawPath(_raw(dir, name)).createSync();
}
