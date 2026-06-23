import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/linthra_logo_mark.dart';
import 'app_icon_controller.dart';
import 'app_icon_variant.dart';

/// The Linthra mark rendered in the user's currently selected branding variant.
///
/// A thin consumer over [LinthraLogoMark]: it watches [appIconControllerProvider]
/// and feeds the chosen variant's gradient and bar pattern to the pure mark, so
/// the brand reflects the Appearance choice anywhere this is dropped in (About,
/// the Settings header, …) without those screens knowing about variants. The
/// presentational [LinthraLogoMark] stays free of Riverpod.
class SelectedLinthraLogoMark extends ConsumerWidget {
  const SelectedLinthraLogoMark({this.size = 40, super.key});

  /// The mark's width and height, in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppIconVariant variant = ref.watch(appIconControllerProvider);
    return LinthraLogoMark(
      size: size,
      gradient: variant.gradient,
      bars: variant.bars,
    );
  }
}
