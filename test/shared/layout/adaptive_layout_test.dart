import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/layout/adaptive_layout.dart';

void main() {
  group('windowSizeClassFor', () {
    test('phone widths are compact', () {
      expect(windowSizeClassFor(360), WindowSizeClass.compact);
      expect(windowSizeClassFor(390), WindowSizeClass.compact);
      expect(windowSizeClassFor(599), WindowSizeClass.compact);
    });

    test('a narrow desktop window is medium, not expanded', () {
      // Linthra's Linux window can be resized down to 420 px, and 800 px is the
      // narrow-window case the issue asks about: wide enough for denser lists,
      // not for a second pane.
      expect(windowSizeClassFor(600), WindowSizeClass.medium);
      expect(windowSizeClassFor(800), WindowSizeClass.medium);
      expect(windowSizeClassFor(999), WindowSizeClass.medium);
    });

    test('common desktop windows are expanded or large', () {
      expect(windowSizeClassFor(1000), WindowSizeClass.expanded);
      expect(windowSizeClassFor(1280), WindowSizeClass.expanded);
      expect(windowSizeClassFor(1599), WindowSizeClass.expanded);
      expect(windowSizeClassFor(1600), WindowSizeClass.large);
      expect(windowSizeClassFor(1920), WindowSizeClass.large);
      expect(windowSizeClassFor(3440), WindowSizeClass.large);
    });

    test('an unmeasured or unbounded box falls back to compact', () {
      expect(windowSizeClassFor(0), WindowSizeClass.compact);
      expect(windowSizeClassFor(-1), WindowSizeClass.compact);
      expect(windowSizeClassFor(double.infinity), WindowSizeClass.compact);
      expect(windowSizeClassFor(double.nan), WindowSizeClass.compact);
    });
  });

  group('WindowSizeClass.isAtLeast', () {
    test('orders the classes by width', () {
      expect(
        WindowSizeClass.large.isAtLeast(WindowSizeClass.expanded),
        isTrue,
      );
      expect(
        WindowSizeClass.expanded.isAtLeast(WindowSizeClass.expanded),
        isTrue,
      );
      expect(
        WindowSizeClass.medium.isAtLeast(WindowSizeClass.expanded),
        isFalse,
      );
      expect(
        WindowSizeClass.compact.isAtLeast(WindowSizeClass.medium),
        isFalse,
      );
    });
  });

  group('AdaptiveLayoutBuilder', () {
    testWidgets('resolves the class from its own box, not the window',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.reset);

      late WindowSizeClass outer;
      late WindowSizeClass inner;

      await tester.pumpWidget(
        MaterialApp(
          home: AdaptiveLayoutBuilder(
            builder: (BuildContext context, BoxConstraints _,
                WindowSizeClass sizeClass) {
              outer = sizeClass;
              // A pane inside the window: the rail and a split make a feature
              // widget narrower than the monitor, and it has to lay itself out
              // for the width it actually got.
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 420,
                  child: AdaptiveLayoutBuilder(
                    builder: (BuildContext context, BoxConstraints __,
                        WindowSizeClass paneClass) {
                      inner = paneClass;
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );

      expect(outer, WindowSizeClass.large);
      expect(inner, WindowSizeClass.compact);
    });
  });

  group('AdaptiveContentWidth', () {
    testWidgets('leaves a phone-width column alone',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AdaptiveContentWidth(
              child: SizedBox.expand(
                key: Key('content'),
                child: ColoredBox(color: Colors.red),
              ),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('content'))).width, 390);
    });

    testWidgets('caps and centres a column on a wide window',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(2560, 1440);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AdaptiveContentWidth(
              child: SizedBox.expand(
                key: Key('content'),
                child: ColoredBox(color: Colors.red),
              ),
            ),
          ),
        ),
      );

      final Rect box = tester.getRect(find.byKey(const Key('content')));
      expect(box.width, maxContentWidth);
      // Centred, so the column doesn't hug one edge of the monitor.
      expect(box.center.dx, closeTo(1280, 0.5));
    });

    for (final TextDirection direction in TextDirection.values) {
      testWidgets(
          'a start-aligned column keeps to the leading edge ($direction)',
          (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(2560, 1440);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: direction,
              child: const Scaffold(
                body: AdaptiveContentWidth(
                  alignment: AlignmentDirectional.topStart,
                  child: SizedBox.expand(
                    key: Key('content'),
                    child: ColoredBox(color: Colors.red),
                  ),
                ),
              ),
            ),
          ),
        );

        final Rect box = tester.getRect(find.byKey(const Key('content')));
        expect(box.width, maxContentWidth);
        if (direction == TextDirection.ltr) {
          expect(box.left, 0);
        } else {
          expect(box.right, 2560);
        }
      });
    }
  });
}
