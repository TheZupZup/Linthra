import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/playable_uri_resolver.dart';

/// The session check and the stream minting of a remote resolve go out
/// together, so a remote track waits one round trip for its URL instead of two.
void main() {
  test('mints while the session check is still on its way', () async {
    final Completer<void> session = Completer<void>();
    bool minting = false;

    final Future<String> resolved = sessionCheckedWhileMinting<String>(
      () => session.future,
      () async {
        minting = true;
        return 'url';
      },
    );
    await pumpEventQueue();

    expect(minting, isTrue);
    session.complete();
    expect(await resolved, 'url');
  });

  test('waits for the session check before handing the URL over', () async {
    final Completer<void> session = Completer<void>();
    bool handedOver = false;

    unawaited(sessionCheckedWhileMinting<String>(
      () => session.future,
      () async => 'url',
    ).then((_) => handedOver = true));
    await pumpEventQueue();

    expect(handedOver, isFalse);
    session.complete();
    await pumpEventQueue();
    expect(handedOver, isTrue);
  });

  test('a failed session check wins over a failed mint', () async {
    final Completer<void> session = Completer<void>();

    final Future<String> resolved = sessionCheckedWhileMinting<String>(
      () => session.future,
      () async => throw StateError('probe'),
    );
    // The mint fails first, while nothing awaits it yet: not an unhandled
    // error, and not the one reported.
    await pumpEventQueue();
    session.completeError(ArgumentError('session'));

    await expectLater(resolved, throwsArgumentError);
  });

  test('a failed session check does not wait for a mint that hangs', () async {
    final Completer<String> mint = Completer<String>();

    await expectLater(
      sessionCheckedWhileMinting<String>(
        () async => throw ArgumentError('session'),
        () => mint.future,
      ),
      throwsArgumentError,
    );
  });

  test('a failed mint is reported once the session checks out', () async {
    await expectLater(
      sessionCheckedWhileMinting<String>(
        () async {},
        () async => throw StateError('probe'),
      ),
      throwsStateError,
    );
  });
}
