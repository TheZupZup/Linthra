import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/layout/pane_layout.dart';

/// Tab walks one pane of a two-pane layout whole before the other (#460).
///
/// Left to the page's reading order, Tab weaves between the panes wherever
/// their rows line up: the first row of one, then the first of the other,
/// then the second of the first. The rows here sit at the same heights on
/// both sides on purpose, which is what an album's tracks beside its Play
/// and Shuffle buttons look like.
List<Widget> _rows(String pane, int count) => <Widget>[
      for (int i = 0; i < count; i++)
        SizedBox(
          height: 48,
          child: TextButton(onPressed: () {}, child: Text('$pane $i')),
        ),
    ];

/// The label of the button holding focus.
String? _focused() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  String? label;
  context.visitChildElements((Element element) {
    void find(Element e) {
      if (label != null) return;
      final Widget widget = e.widget;
      if (widget is Text) {
        label = widget.data;
        return;
      }
      e.visitChildElements(find);
    }

    find(element);
  });
  return label;
}

Future<List<String?>> _tabThrough(WidgetTester tester, int presses) async {
  final List<String?> order = <String?>[];
  for (int i = 0; i < presses; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    order.add(_focused());
  }
  return order;
}

void main() {
  setUp(() {
    // Keyboard-driven traversal, as on a desktop.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  testWidgets('SplitPanes: the fixed pane first, whole, then the other',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SplitPanes(
          fixed: Column(children: _rows('side', 2)),
          fixedWidth: 300,
          flexible: Column(children: _rows('list', 3)),
        ),
      ),
    ));

    expect(await _tabThrough(tester, 5), <String>[
      'side 0',
      'side 1',
      'list 0',
      'list 1',
      'list 2',
    ]);
  });

  testWidgets('SplitPanes: and the other way round when it comes second',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SplitPanes(
          fixed: Column(children: _rows('detail', 2)),
          fixedWidth: 300,
          flexible: Column(children: _rows('grid', 3)),
          fixedFirst: false,
        ),
      ),
    ));

    expect(await _tabThrough(tester, 5), <String>[
      'grid 0',
      'grid 1',
      'grid 2',
      'detail 0',
      'detail 1',
    ]);
  });

  testWidgets('ListDetailPanes: the list whole, then the open detail',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListDetailPanes(
          listBuilder: (BuildContext context, bool paneVisible) =>
              Column(children: _rows('album', 3)),
          detailBuilder: (BuildContext context) =>
              Column(children: _rows('track', 3)),
          placeholderBuilder: (BuildContext context) => const SizedBox(),
        ),
      ),
    ));

    expect(await _tabThrough(tester, 6), <String>[
      'album 0',
      'album 1',
      'album 2',
      'track 0',
      'track 1',
      'track 2',
    ]);
  });
}
