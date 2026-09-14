import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/scroll/app_scroll_behavior.dart';
import 'package:linthra/shared/scroll/horizontal_wheel_scroll.dart';

/// The one place a vertical wheel is allowed to mean "sideways" (#396).
///
/// Everywhere else the rule is the strict one Flutter already applies — a
/// surface reads only the axis it scrolls along — because guessing is what
/// makes a sideways trackpad flick scroll a library list. A shelf that is the
/// only thing under the pointer is the exception every desktop toolkit makes:
/// without it a one-wheel mouse simply cannot reach the far end of the row.

const Key _shelf = Key('shelf');
const Key _page = Key('page');

Future<void> _scrollOver(
  WidgetTester tester,
  Finder target,
  Offset delta, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) async {
  final TestPointer pointer = TestPointer(1, kind);
  pointer.hover(tester.getCenter(target));
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pump();
}

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final ScrollController page = ScrollController();
  ScrollController? shelf;

  @override
  void dispose() {
    page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        key: _page,
        controller: page,
        children: <Widget>[
          // Deep enough that the shelf is still on screen once the page has
          // been scrolled, which is what the chaining cases need.
          const SizedBox(height: 300, child: Text('header')),
          SizedBox(
            height: 60,
            child: HorizontalWheelScroll(
              builder: (BuildContext context, ScrollController controller) {
                shelf = controller;
                return SingleChildScrollView(
                  key: _shelf,
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < 20; i++)
                        SizedBox(width: 200, child: Text('chip $i')),
                    ],
                  ),
                );
              },
            ),
          ),
          for (int i = 0; i < 30; i++)
            SizedBox(height: 100, child: Text('row $i')),
        ],
      ),
    );
  }
}

Future<_HarnessState> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      scrollBehavior: AppScrollBehavior(),
      home: _Harness(),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HarnessState>(find.byType(_Harness));
}

void main() {
  testWidgets('a plain wheel moves the shelf along, not the page',
      (tester) async {
    final _HarnessState state = await _pump(tester);

    await _scrollOver(tester, find.byKey(_shelf), const Offset(0, 53));

    expect(state.shelf!.offset, 53);
    expect(
      state.page.offset,
      0,
      reason: 'the page must not move as well — that is the double effect',
    );
  });

  testWidgets('a device that scrolls sideways itself still does',
      (tester) async {
    final _HarnessState state = await _pump(tester);
    await _scrollOver(
      tester,
      find.byKey(_shelf),
      const Offset(53, 0),
      kind: PointerDeviceKind.trackpad,
    );
    expect(state.shelf!.offset, 53);
    expect(state.page.offset, 0);
  });

  testWidgets('at the end of the row the page takes the wheel back',
      (tester) async {
    final _HarnessState state = await _pump(tester);

    state.shelf!.jumpTo(state.shelf!.position.maxScrollExtent);
    await tester.pump();
    await _scrollOver(tester, find.byKey(_shelf), const Offset(0, 53));

    expect(
      state.page.offset,
      53,
      reason: 'a shelf with nowhere left to go must not swallow the wheel',
    );
  });

  testWidgets('scrolling back up past the start chains the same way',
      (tester) async {
    final _HarnessState state = await _pump(tester);
    state.page.jumpTo(200);
    await tester.pump();

    await _scrollOver(tester, find.byKey(_shelf), const Offset(0, -53));

    expect(state.shelf!.offset, 0, reason: 'the shelf was already at zero');
    expect(state.page.offset, 147);
  });

  testWidgets('the page still scrolls from anywhere else on it',
      (tester) async {
    final _HarnessState state = await _pump(tester);
    await _scrollOver(tester, find.text('header'), const Offset(0, 53));
    expect(state.page.offset, 53);
    expect(state.shelf!.offset, 0);
  });

  group('a shelf that is a sibling of its list', () {
    testWidgets('hands a notch at the end of the row to the list',
        (tester) async {
      // The audiobook browser's shape: the chip row and the list are siblings
      // in a column, so an unclaimed signal has no ancestor to fall through
      // to — the list is simply not on the pointer's hit-test path.
      final _SiblingHarnessState state = await _pumpSiblings(tester);

      state.shelf!.jumpTo(state.shelf!.position.maxScrollExtent);
      await tester.pump();

      await _scrollOver(tester, find.byKey(_shelf), const Offset(0, 53));

      expect(state.list.offset, 53);
    });

    testWidgets('leaves the row alone while it still has room', (tester) async {
      final _SiblingHarnessState state = await _pumpSiblings(tester);

      await _scrollOver(tester, find.byKey(_shelf), const Offset(0, 53));

      expect(state.shelf!.offset, 53);
      expect(state.list.offset, 0, reason: 'the row had somewhere to go');
    });

    testWidgets('a row with nothing to scroll passes it straight on',
        (tester) async {
      final _SiblingHarnessState state = await _pumpSiblings(tester, chips: 1);

      await _scrollOver(tester, find.byKey(_shelf), const Offset(0, 53));

      expect(state.list.offset, 53);
    });
  });

  testWidgets('a touch drag along the shelf is unchanged', (tester) async {
    final _HarnessState state = await _pump(tester);

    await tester.drag(find.byKey(_shelf), const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(state.shelf!.offset, greaterThan(0));
    expect(state.page.offset, 0);
  });
}

/// The sibling shape: a chip row above a list, not inside one.
class _SiblingHarness extends StatefulWidget {
  const _SiblingHarness({required this.chips});

  final int chips;

  @override
  State<_SiblingHarness> createState() => _SiblingHarnessState();
}

class _SiblingHarnessState extends State<_SiblingHarness> {
  final ScrollController list = ScrollController();
  ScrollController? shelf;

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          SizedBox(
            height: 60,
            child: HorizontalWheelScroll(
              chainTo: list,
              builder: (BuildContext context, ScrollController controller) {
                shelf = controller;
                return SingleChildScrollView(
                  key: _shelf,
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < widget.chips; i++)
                        SizedBox(width: 200, child: Text('chip $i')),
                    ],
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: ListView(
              controller: list,
              children: <Widget>[
                for (int i = 0; i < 30; i++)
                  SizedBox(height: 100, child: Text('book $i')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<_SiblingHarnessState> _pumpSiblings(
  WidgetTester tester, {
  int chips = 20,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      home: _SiblingHarness(chips: chips),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_SiblingHarnessState>(find.byType(_SiblingHarness));
}
