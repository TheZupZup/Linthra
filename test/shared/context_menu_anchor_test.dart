import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/context_menu_region.dart';

/// A context menu has to open where it was asked for (#386).
///
/// `showMenu` reads its position in the coordinate space of the nearest
/// [Overlay], not in screen coordinates — and inside the desktop shell that
/// overlay is the branch navigator's, which starts after the navigation rail.
/// Handing it a raw global position therefore slides every menu across by the
/// rail's width, and clamps it against the wrong bounds near the right edge.
///
/// This pumps the same shape the shell has: a fixed-width column, then a
/// [Navigator] (which brings its own Overlay) holding the row.
const double _railWidth = 200;

Future<void> _pump(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 600);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(
          children: <Widget>[
            const SizedBox(
                width: _railWidth,
                child: ColoredBox(
                  color: Color(0xFF202020),
                )),
            Expanded(
              child: Navigator(
                onGenerateRoute: (RouteSettings settings) {
                  return MaterialPageRoute<void>(
                    builder: (BuildContext context) =>
                        ContextMenuRegion<String>(
                      itemBuilder: (BuildContext context) =>
                          const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'a',
                          child: Text('Play next'),
                        ),
                      ],
                      onSelected: (_) {},
                      child: const Focus(
                        autofocus: true,
                        child: SizedBox.expand(
                          child: Center(child: Text('row')),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _rightClickAt(WidgetTester tester, Offset where) async {
  final TestGesture gesture = await tester.startGesture(
    where,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  group('ContextMenuRegion anchoring', () {
    testWidgets('opens at the pointer, not shifted by the rail beside it',
        (tester) async {
      await _pump(tester);

      const Offset click = Offset(400, 300);
      await _rightClickAt(tester, click);

      expect(find.text('Play next'), findsOneWidget);
      final Rect menu = tester.getRect(find.text('Play next'));
      // Menus get padding and can be nudged to fit, but they open *at* the
      // pointer: anything near the rail's width away is the overlay offset
      // leaking into the anchor.
      expect((menu.left - click.dx).abs(), lessThan(_railWidth / 2));
    });

    testWidgets('a keyboard-opened menu lands on its row too', (tester) async {
      await _pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      // The row fills everything right of the rail, so the menu key opens the
      // menu at the middle of that remaining space — measured the same way.
      final double rowCentreX = tester.getCenter(find.text('row')).dx;
      expect(find.text('Play next'), findsOneWidget);
      final Rect menu = tester.getRect(find.text('Play next'));
      expect((menu.left - rowCentreX).abs(), lessThan(_railWidth / 2));
    });

    testWidgets('a click near the right edge stays on screen', (tester) async {
      await _pump(tester);

      await _rightClickAt(tester, const Offset(980, 300));

      expect(find.text('Play next'), findsOneWidget);
      final Rect menu = tester.getRect(find.byType(PopupMenuItem<String>));
      expect(menu.right, lessThanOrEqualTo(1000));
      expect(menu.left, greaterThanOrEqualTo(0));
    });
  });
}
