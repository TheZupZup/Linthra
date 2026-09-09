import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/data/repositories/shared_preferences_cast_receiver_pin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The persistent half of receiver pinning (docs/cast-hardened-design.md,
/// layer 3). What is being pinned down here is not "a value round-trips" but
/// the two ways this store is allowed to be wrong: it may refuse, and it may
/// not quietly forget. Every case below is one of the rules the design states,
/// because [TrustGatedCastTransport] leans on all of them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const SharedPreferencesCastReceiverPinStore store =
      SharedPreferencesCastReceiverPinStore();

  group('SharedPreferencesCastReceiverPinStore', () {
    test('a device that has never been cast to has no pin', () async {
      expect(await store.pinFor('device-1'), isNull);
    });

    test('a pin survives a new store instance, which is the whole point',
        () async {
      await store.remember('device-1', 'sha256aabb');

      expect(
        await const SharedPreferencesCastReceiverPinStore().pinFor('device-1'),
        'sha256aabb',
      );
    });

    test('pins are per device', () async {
      await store.remember('device-1', 'sha256aabb');
      await store.remember('device-2', 'sha256ccdd');

      expect(await store.pinFor('device-1'), 'sha256aabb');
      expect(await store.pinFor('device-2'), 'sha256ccdd');
    });

    test('device ids that are not tidy strings still get their own pin',
        () async {
      // Discovery hands back whatever a receiver advertises. Nothing about a
      // device id may decide which preference key gets written.
      const String awkward = 'living room/tv#1 ::v2';
      await store.remember(awkward, 'sha256aabb');
      await store.remember('other', 'sha256ccdd');

      expect(await store.pinFor(awkward), 'sha256aabb');
      expect(await store.pinFor('other'), 'sha256ccdd');
    });

    test('remember never replaces a pin that is already there', () async {
      await store.remember('device-1', 'sha256aabb');
      await store.remember('device-1', 'sha256ccdd');

      // A second connection racing the first must lose rather than re-pin: the
      // caller reads back and finds out.
      expect(await store.pinFor('device-1'), 'sha256aabb');
    });

    test('forget clears the pin so the next connection pins afresh', () async {
      await store.remember('device-1', 'sha256aabb');
      await store.forget('device-1');

      expect(await store.pinFor('device-1'), isNull);

      await store.remember('device-1', 'sha256ccdd');
      expect(await store.pinFor('device-1'), 'sha256ccdd');
    });

    test('forgetting a device that was never pinned is not an error', () async {
      // The sheet offers this recovery from a refusal; it must not throw at a
      // user whose pin was already gone.
      await expectLater(store.forget('device-1'), completes);
    });

    test('forget leaves every other device pinned', () async {
      await store.remember('device-1', 'sha256aabb');
      await store.remember('device-2', 'sha256ccdd');

      await store.forget('device-1');

      expect(await store.pinFor('device-2'), 'sha256ccdd');
    });

    test('an unreadable pin throws rather than reading as a first use',
        () async {
      // The failure this exists to stop: a damaged entry resolving to null
      // would re-pin whichever receiver answered next, so breaking the store
      // would be the way to erase the check.
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesCastReceiverPinStore.keyFor('device-1'): '   ',
      });

      await expectLater(store.pinFor('device-1'), throwsStateError);
    });

    test('an unreadable pin is replaced rather than kept forever', () async {
      // The other half of the rule above: refusing is right, but the user has
      // to be able to get out of it, and forget is the deliberate act that
      // does it.
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesCastReceiverPinStore.keyFor('device-1'): '',
      });

      await store.forget('device-1');
      await store.remember('device-1', 'sha256aabb');

      expect(await store.pinFor('device-1'), 'sha256aabb');
    });

    test('an unreadable pin does not count as one for remember either',
        () async {
      // Otherwise a blank entry would be a pin that can never be recorded over
      // and never matches anything.
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPreferencesCastReceiverPinStore.keyFor('device-1'): '',
      });

      await store.remember('device-1', 'sha256aabb');

      expect(await store.pinFor('device-1'), 'sha256aabb');
    });

    test('keys are namespaced so nothing else in preferences is touched',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme_mode_v1': 'dark',
      });

      await store.remember('device-1', 'sha256aabb');
      await store.forget('device-1');

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode_v1'), 'dark');
      expect(
        prefs.getKeys().where(
              (String key) => key.startsWith(
                SharedPreferencesCastReceiverPinStore.keyPrefix,
              ),
            ),
        isEmpty,
      );
    });
  });
}
