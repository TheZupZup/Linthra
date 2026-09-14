import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The one scroll policy every surface in Linthra inherits.
///
/// Installed once, on the app's `MaterialApp`, so it reaches every list, grid,
/// sheet, pane and dialog at the same time — including the ones pushed as
/// routes, which sit inside the app's `ScrollConfiguration`. That is the whole
/// point: the desktop rules below are written once here rather than as a
/// platform check per scrolling widget, which is what "make it feel like a
/// desktop app" usually decays into.
///
/// Two of the three answers below are the same ones Material gives today. They
/// are stated anyway, because "Flutter happens to do the right thing on Linux"
/// is not a guarantee: a stray `ThemeData.platform`, a widget that reaches for
/// `BouncingScrollPhysics` because it looked nicer on a phone, or a future
/// default can all move them, and the tests that pin this class would then
/// fail instead of a listener noticing the app bouncing like a phone.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  /// Which devices may *drag* a surface to scroll it.
  ///
  /// The mouse is deliberately absent. Grabbing a list with the left button
  /// and flinging it is a touch idiom; on a desktop, press-and-move over a
  /// list means selecting, drawing a rubber band, or dragging a row to a
  /// playlist, and a list that scrolled out from under that would make all
  /// three unusable. A mouse scrolls with its wheel, which is a pointer signal
  /// and needs no drag device at all.
  ///
  /// Everything a finger-like input can be is in: touch and both stylus kinds
  /// keep Android exactly as it was, `unknown` is what accessibility services
  /// send, and `trackpad` is what makes a two-finger pan a smooth drag rather
  /// than a stream of jumps.
  @override
  Set<PointerDeviceKind> get dragDevices => _dragDevices;

  static const Set<PointerDeviceKind> _dragDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };

  /// Whether a platform's own idiom is to rubber-band at the ends of a list.
  ///
  /// Apple's platforms do, and there it is native rather than a mobile import,
  /// so Linthra leaves them to Material. Everywhere else a scroll surface
  /// stops dead where its content stops.
  static bool bouncesNatively(TargetPlatform platform) => switch (platform) {
        TargetPlatform.iOS || TargetPlatform.macOS => true,
        TargetPlatform.android ||
        TargetPlatform.fuchsia ||
        TargetPlatform.linux ||
        TargetPlatform.windows =>
          false,
      };

  /// Whether a platform is driven by a pointer rather than by a thumb.
  ///
  /// Used only for decoration below. Layout never asks this question — it
  /// adapts on the width a widget is given (`shared/layout`) — and neither do
  /// the scroll *input* widgets in this directory, which key on the signal.
  static bool isPointerFirst(TargetPlatform platform) => switch (platform) {
        TargetPlatform.linux ||
        TargetPlatform.macOS ||
        TargetPlatform.windows =>
          true,
        TargetPlatform.android ||
        TargetPlatform.fuchsia ||
        TargetPlatform.iOS =>
          false,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (bouncesNatively(getPlatform(context))) {
      return super.getScrollPhysics(context);
    }
    // Android already gets this from Material; naming it here means a desktop
    // window cannot inherit a bounce from anywhere else either.
    return const ClampingScrollPhysics();
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // A glow or a stretch at the end of a list is a touch affordance: it
    // answers "your finger is still dragging, the list is not". A wheel notch
    // asks no such question, so on a pointer host the list simply stops.
    if (isPointerFirst(getPlatform(context))) return child;
    return super.buildOverscrollIndicator(context, child, details);
  }
}
