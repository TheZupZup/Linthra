import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/text_file_saver_provider.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/method_channel_linux_file_saver.dart';
import 'package:linthra/core/services/method_channel_linux_folder_picker.dart';
import 'package:linthra/core/services/text_file_saver.dart';
import 'package:linthra/data/repositories/host_platform_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The save dialog is the folder picker channel's second method (#748).
  const MethodChannel channel =
      MethodChannel(MethodChannelLinuxFolderPicker.channelName);

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linthra_save_dialog');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  /// Answers the runner's channel with [handler], recording what Dart sent.
  List<MethodCall> runnerAnswers(Future<Object?> Function(MethodCall) handler) {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return handler(call);
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    return calls;
  }

  Future<TextFileSaveResult> save() => const MethodChannelLinuxFileSaver().save(
        suggestedName: 'linthra-bug-report.md',
        contents: '# Linthra bug report\n',
        dialogTitle: 'Save bug report',
      );

  group('MethodChannelLinuxFileSaver (#748)', () {
    test('writes the file where the save dialog says, and nowhere else',
        () async {
      final String chosen = '${dir.path}/picked-name.md';
      final List<MethodCall> calls = runnerAnswers((_) async => chosen);

      final TextFileSaveResult result = await save();

      expect(calls.single.method, MethodChannelLinuxFileSaver.saveFileMethod);
      expect(calls.single.arguments, <String, Object?>{
        'title': 'Save bug report',
        'suggestedName': 'linthra-bug-report.md',
      });
      expect(result, isA<TextFileSaved>());
      expect((result as TextFileSaved).path, chosen);
      expect(await File(chosen).readAsString(), '# Linthra bug report\n');
      expect(dir.listSync(), hasLength(1));
    });

    test('a closed dialog is a cancel, and writes nothing', () async {
      runnerAnswers((_) async => null);

      expect(await save(), isA<TextFileSaveCancelled>());
      expect(dir.listSync(), isEmpty);
    });

    test('a dialog already open is not a failure either', () async {
      runnerAnswers(
        (_) async => throw PlatformException(
          code: MethodChannelLinuxFileSaver.chooserInProgressCode,
        ),
      );

      expect(await save(), isA<TextFileSaveCancelled>());
    });

    test('a place with no local path is a failure', () async {
      runnerAnswers(
        (_) async => throw PlatformException(code: 'unsupported_location'),
      );

      expect(await save(), isA<TextFileSaveFailed>());
    });

    test('no dialog at all is a failure, never a write somewhere else',
        () async {
      // No handler: what a runner without the channel answers.
      expect(await save(), isA<TextFileSaveFailed>());
    });

    test('a write that fails is a failure', () async {
      runnerAnswers((_) async => '${dir.path}/no/such/folder/report.md');

      expect(await save(), isA<TextFileSaveFailed>());
    });
  });

  group('DocumentsDirectoryTextFileSaver', () {
    test('writes the suggested name into the directory, as before', () async {
      final TextFileSaveResult result =
          await DocumentsDirectoryTextFileSaver(directory: () async => dir)
              .save(
        suggestedName: 'linthra-diagnostics.txt',
        contents: 'Linthra diagnostics',
        dialogTitle: 'Save diagnostics',
      );

      expect((result as TextFileSaved).path,
          '${dir.path}/linthra-diagnostics.txt');
      expect(await File(result.path).readAsString(), 'Linthra diagnostics');
    });

    test('a directory that cannot be had is a failure', () async {
      final TextFileSaveResult result = await DocumentsDirectoryTextFileSaver(
        directory: () async => throw const FileSystemException('no dir'),
      ).save(
        suggestedName: 'linthra-diagnostics.txt',
        contents: 'x',
        dialogTitle: 'Save diagnostics',
      );

      expect(result, isA<TextFileSaveFailed>());
    });
  });

  group('textFileSaverProvider', () {
    TextFileSaver on(HostPlatform host) {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[hostPlatformProvider.overrideWithValue(host)],
      );
      addTearDown(container.dispose);
      return container.read(textFileSaverProvider);
    }

    test('Linux asks through the save dialog', () {
      expect(on(HostPlatform.linux), isA<MethodChannelLinuxFileSaver>());
    });

    test('Android keeps writing into the documents directory', () {
      expect(on(HostPlatform.android), isA<DocumentsDirectoryTextFileSaver>());
    });
  });
}
