import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/focus/focus_handoff.dart';

/// Closing a desktop pane must not cost the keyboard its place (#390). What the
/// framework does on its own is unwind to the enclosing scope, which leaves no
/// ring on screen and restarts the next Tab from the top of the page. It is the
/// kind of thing a mouse user never notices and a keyboard user hits every time
/// they resize a window.

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final FocusNode _toggle = FocusNode(debugLabel: 'toggle');
  bool _paneOpen = false;

  @override
  void dispose() {
    _toggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Row(
          children: <Widget>[
            TextButton(
              focusNode: _toggle,
              onPressed: () => setState(() => _paneOpen = !_paneOpen),
              child: const Text('toggle'),
            ),
            TextButton(onPressed: () {}, child: const Text('elsewhere')),
            if (_paneOpen)
              FocusHandoff(
                returnFocusTo: () => _toggle,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton(onPressed: () {}, child: const Text('in pane')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String? _focusedLabel() {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final Finder text = find.descendant(
    of: find.byWidget(context.widget),
    matching: find.byType(Text),
  );
  if (text.evaluate().isEmpty) return null;
  return (text.evaluate().first.widget as Text).data;
}

void main() {
  testWidgets('a pane holding the keyboard hands it back on close',
      (tester) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('in pane'))).requestFocus();
    await tester.pump();
    expect(_focusedLabel(), 'in pane');

    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();

    expect(find.text('in pane'), findsNothing);
    expect(_focusedLabel(), 'toggle');
  });

  testWidgets('a pane that was not holding it leaves focus alone',
      (tester) async {
    await tester.pumpWidget(const _Host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('elsewhere'))).requestFocus();
    await tester.pump();
    expect(_focusedLabel(), 'elsewhere');

    await tester.tap(find.text('toggle'));
    await tester.pumpAndSettle();

    // Someone typing in another pane must not have the keyboard pulled off
    // them because an unrelated column closed.
    expect(_focusedLabel(), 'elsewhere');
  });

  testWidgets('a target that went away with the pane is left alone',
      (tester) async {
    final FocusNode target = FocusNode(debugLabel: 'gone');
    addTearDown(target.dispose);
    bool mounted = true;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return Scaffold(
              body: Column(
                children: <Widget>[
                  TextButton(
                    onPressed: () => setState(() => mounted = false),
                    child: const Text('drop both'),
                  ),
                  if (mounted) ...<Widget>[
                    TextButton(
                      focusNode: target,
                      onPressed: () {},
                      child: const Text('target'),
                    ),
                    FocusHandoff(
                      returnFocusTo: () => target,
                      child: TextButton(
                        onPressed: () {},
                        child: const Text('in pane'),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('in pane'))).requestFocus();
    await tester.pump();

    await tester.tap(find.text('drop both'));
    await tester.pumpAndSettle();

    // No deferred request left armed on a node that is no longer on screen: it
    // would fire whenever that control came back, stealing focus long after.
    expect(tester.takeException(), isNull);
    expect(target.hasFocus, isFalse);
  });
}
