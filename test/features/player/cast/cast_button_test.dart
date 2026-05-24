import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/features/player/cast/cast_button.dart';
import 'package:linthra/features/player/cast/cast_providers.dart';

import 'fake_cast_service.dart';

Future<void> _pump(WidgetTester tester, FakeCastService service) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [castServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: CastButton())),
      ),
    ),
  );
}

IconButton _button(WidgetTester tester) =>
    tester.widget<IconButton>(find.byType(IconButton));

void main() {
  group('CastButton', () {
    testWidgets('renders a cast icon', (tester) async {
      await _pump(tester, FakeCastService());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.cast), findsOneWidget);
    });

    testWidgets('is shown but marked "coming soon" when unavailable', (
      tester,
    ) async {
      await _pump(tester, FakeCastService());
      await tester.pumpAndSettle();

      // Honest: the control is present but its tooltip signals it isn't live.
      expect(find.byTooltip('Cast (coming soon)'), findsOneWidget);
      expect(_button(tester).isSelected, isFalse);
    });

    testWidgets('opens the device sheet with an honest unavailable state', (
      tester,
    ) async {
      await _pump(tester, FakeCastService());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CastButton));
      await tester.pumpAndSettle();

      expect(find.text('Casting isn\'t available here'), findsOneWidget);
    });

    testWidgets('shows the connected glyph when connected', (tester) async {
      const device = CastDevice(id: 'd1', name: 'Living Room');
      await _pump(
        tester,
        FakeCastService(
          initial: const CastState(
            availability: CastAvailability.connected,
            devices: <CastDevice>[device],
            connectedDevice: device,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.cast_connected), findsOneWidget);
      expect(find.byTooltip('Cast'), findsOneWidget);
      expect(_button(tester).isSelected, isTrue);
    });

    testWidgets('lists discovered devices and connects on tap (the seam)', (
      tester,
    ) async {
      const device = CastDevice(id: 'd1', name: 'Living Room');
      final service = FakeCastService(
        initial: const CastState(
          availability: CastAvailability.idle,
          devices: <CastDevice>[device],
        ),
      );
      await _pump(tester, service);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CastButton));
      await tester.pumpAndSettle();

      // The sheet starts discovery while open and lists the device.
      expect(service.discoveryStarts, 1);
      expect(find.text('Living Room'), findsOneWidget);

      await tester.tap(find.text('Living Room'));
      expect(service.connectRequests, <CastDevice>[device]);
    });
  });
}
