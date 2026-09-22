import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/platform/host_platform.dart';
import 'package:linthra/core/services/optical/cdrom_toc_source.dart';
import 'package:linthra/core/services/optical/method_channel_cdrom_toc_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel =
      MethodChannel(MethodChannelCdromTocSource.channelName);
  final List<MethodCall> calls = <MethodCall>[];

  void answerWith(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) {
      calls.add(call);
      return handler(call);
    });
  }

  MethodChannelCdromTocSource sourceFor() =>
      const MethodChannelCdromTocSource(host: HostPlatform.linux);

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<Object?, Object?> replyFor({
    int firstTrack = 1,
    int lastTrack = 2,
    int leadOut = 30000,
    List<Map<String, Object?>>? tracks,
    Uint8List? cdText,
  }) =>
      <Object?, Object?>{
        MethodChannelCdromTocSource.firstTrackKey: firstTrack,
        MethodChannelCdromTocSource.lastTrackKey: lastTrack,
        MethodChannelCdromTocSource.leadOutKey: leadOut,
        MethodChannelCdromTocSource.tracksKey: tracks ??
            <Map<String, Object?>>[
              <String, Object?>{
                MethodChannelCdromTocSource.trackNumberKey: 1,
                MethodChannelCdromTocSource.trackLbaKey: 0,
                MethodChannelCdromTocSource.trackControlKey: 0,
              },
              <String, Object?>{
                MethodChannelCdromTocSource.trackNumberKey: 2,
                MethodChannelCdromTocSource.trackLbaKey: 15000,
                MethodChannelCdromTocSource.trackControlKey: 4,
              },
            ],
        if (cdText != null) MethodChannelCdromTocSource.cdTextKey: cdText,
      };

  group('the call', () {
    test('asks the runner for the drive it was given', () async {
      answerWith((MethodCall call) async => replyFor());

      await sourceFor().readToc('/dev/sr1');

      expect(calls.single.method, MethodChannelCdromTocSource.readTocMethod);
      expect(
        (calls.single.arguments as Map<Object?, Object?>)[
            MethodChannelCdromTocSource.deviceArgument],
        '/dev/sr1',
      );
    });

    test('never reaches the channel off Linux', () async {
      answerWith((MethodCall call) async => replyFor());

      await expectLater(
        const MethodChannelCdromTocSource(host: HostPlatform.android)
            .readToc('/dev/sr0'),
        throwsA(
          isA<CdromTocException>().having(
            (CdromTocException error) => error.failure,
            'failure',
            CdromTocFailure.unsupported,
          ),
        ),
      );
      expect(calls, isEmpty);
    });

    test('never reaches the channel for a node that is not a drive', () async {
      answerWith((MethodCall call) async => replyFor());

      await expectLater(
        sourceFor().readToc('/dev/sda'),
        throwsA(
          isA<CdromTocException>().having(
            (CdromTocException error) => error.failure,
            'failure',
            CdromTocFailure.driveUnavailable,
          ),
        ),
      );
      expect(calls, isEmpty);
    });
  });

  group('the reply', () {
    test('is decoded into a table of contents', () async {
      answerWith((MethodCall call) async => replyFor());

      final RawCdToc toc = await sourceFor().readToc('/dev/sr0');

      expect(toc.firstTrack, 1);
      expect(toc.lastTrack, 2);
      expect(toc.leadOutLba, 30000);
      expect(toc.tracks, hasLength(2));
      expect(toc.tracks.first.startLba, 0);
      expect(toc.tracks.first.isData, isFalse);
      expect(toc.tracks.last.isData, isTrue);
      expect(toc.cdText, isNull);
    });

    test('carries CD-Text bytes through undecoded', () async {
      final Uint8List bytes = Uint8List.fromList(<int>[0, 2, 0, 0]);
      answerWith((MethodCall call) async => replyFor(cdText: bytes));

      expect((await sourceFor().readToc('/dev/sr0')).cdText, bytes);
    });

    test('the CD-Text bytes cannot be rewritten after the read', () async {
      // `RawCdToc` is `@immutable`, and the CD-Text buffer feeds both the
      // decoded metadata and the value's hashCode — so it is copied, exactly
      // as the track list is.
      final Uint8List bytes = Uint8List.fromList(<int>[0, 2, 0, 0]);
      answerWith((MethodCall call) async => replyFor(cdText: bytes));

      final RawCdToc toc = await sourceFor().readToc('/dev/sr0');
      final int before = toc.hashCode;
      bytes[0] = 0xff;

      expect(toc.cdText, isNot(same(bytes)));
      expect(toc.cdText!.first, 0);
      expect(toc.hashCode, before);

      // Copying the caller's list closes one hole; the getter hands out a
      // writable list unless it is also a view, which closes the other.
      expect(() => toc.cdText![0] = 0xff, throwsUnsupportedError);
      expect(toc.hashCode, before);
    });

    test('a missing field is refused rather than defaulted', () async {
      for (final String missing in <String>[
        MethodChannelCdromTocSource.firstTrackKey,
        MethodChannelCdromTocSource.lastTrackKey,
        MethodChannelCdromTocSource.leadOutKey,
        MethodChannelCdromTocSource.tracksKey,
      ]) {
        answerWith((MethodCall call) async => replyFor()..remove(missing));
        await expectLater(
          sourceFor().readToc('/dev/sr0'),
          throwsA(
            isA<CdromTocException>().having(
              (CdromTocException error) => error.failure,
              'failure',
              CdromTocFailure.unreadable,
            ),
          ),
          reason: missing,
        );
      }
    });

    test('a malformed track entry is refused', () async {
      answerWith(
        (MethodCall call) async => <Object?, Object?>{
          ...replyFor(),
          MethodChannelCdromTocSource.tracksKey: <Object?>['not a track'],
        },
      );

      await expectLater(
        sourceFor().readToc('/dev/sr0'),
        throwsA(isA<CdromTocException>()),
      );
    });

    test('an empty reply is refused', () async {
      answerWith((MethodCall call) async => null);

      await expectLater(
        sourceFor().readToc('/dev/sr0'),
        throwsA(isA<CdromTocException>()),
      );
    });
  });

  group('the runner\'s errors', () {
    Future<CdromTocFailure> failureFor(String code) async {
      answerWith(
        (MethodCall call) async =>
            throw PlatformException(code: code, message: 'test'),
      );
      try {
        await sourceFor().readToc('/dev/sr0');
      } on CdromTocException catch (error) {
        return error.failure;
      }
      fail('expected a CdromTocException for $code');
    }

    test('are mapped one for one', () async {
      expect(
        await failureFor(MethodChannelCdromTocSource.noDiscError),
        CdromTocFailure.noDisc,
      );
      expect(
        await failureFor(MethodChannelCdromTocSource.discChangedError),
        CdromTocFailure.discChanged,
      );
      expect(
        await failureFor(MethodChannelCdromTocSource.driveUnavailableError),
        CdromTocFailure.driveUnavailable,
      );
      expect(
        await failureFor(MethodChannelCdromTocSource.permissionDeniedError),
        CdromTocFailure.permissionDenied,
      );
      expect(
        await failureFor(MethodChannelCdromTocSource.unreadableError),
        CdromTocFailure.unreadable,
      );
    });

    test('a code this build has not heard of degrades to unreadable', () async {
      expect(await failureFor('something_new'), CdromTocFailure.unreadable);
      expect(await failureFor('invalid_arguments'), CdromTocFailure.unreadable);
    });

    test('a runner without the channel reports unsupported, not a bad disc',
        () async {
      // The default mock handler is absent, so the channel is missing.
      await expectLater(
        sourceFor().readToc('/dev/sr0'),
        throwsA(
          isA<CdromTocException>().having(
            (CdromTocException error) => error.failure,
            'failure',
            CdromTocFailure.unsupported,
          ),
        ),
      );
    });
  });

  group('isPlausibleOpticalDeviceNode', () {
    test('accepts the nodes UDisks2 reports for optical drives', () {
      expect(isPlausibleOpticalDeviceNode('/dev/sr0'), isTrue);
      expect(isPlausibleOpticalDeviceNode('/dev/sr12'), isTrue);
      expect(isPlausibleOpticalDeviceNode('/dev/scd0'), isTrue);
    });

    test('rejects everything else', () {
      for (final String node in <String>[
        '',
        'sr0',
        '/dev/sda',
        '/dev/sr',
        '/dev/sr0000',
        '/dev/sr0 ',
        '/dev/../dev/sr0',
        '/dev/sr0;reboot',
        '/dev/srx',
      ]) {
        expect(isPlausibleOpticalDeviceNode(node), isFalse, reason: node);
      }
    });
  });
}
