import 'package:flutter/material.dart';

import '../../app/colors.dart';

/// Linthra's brand mark, rendered in-app: rounded equalizer bars under a single
/// vertical gradient, echoing a now-playing visualizer.
///
/// It is the Dart twin of the launcher/store icon (`tool/branding/`), drawn from
/// the same bar proportions and the same two-colour identity, so the brand reads
/// consistently from the home screen into the app. Sizes to a [size]×[size] box;
/// the dark squircle behind it is supplied by the surface it sits on.
///
/// The default mark is Linthra's classic violet→orange look. Callers can pass a
/// different [gradient] (top colour first) and [bars] pattern to render one of
/// the optional branding variants — the bar group always spans the same
/// footprint and keeps the same gap-to-bar proportions, so any bar count stays
/// centred and never overflows the box. This widget is purely presentational and
/// holds no state; `SelectedLinthraLogoMark` is the consumer that feeds it the
/// user's chosen variant.
class LinthraLogoMark extends StatelessWidget {
  const LinthraLogoMark({
    this.size = 40,
    this.gradient = classicGradient,
    this.bars = classicBars,
    super.key,
  });

  final double size;

  /// The mark's vertical gradient, top colour first.
  final List<Color> gradient;

  /// Bar heights as fractions of [size], left to right.
  final List<double> bars;

  /// The classic violet→orange gradient — the default mark and Linthra's
  /// primary identity.
  static const List<Color> classicGradient = <Color>[
    AppColors.brandBright,
    AppColors.accent,
  ];

  /// The classic four-bar pattern.
  static const List<double> classicBars = <double>[0.46, 0.70, 0.56, 0.34];

  /// The fraction of [size] the bar group spans, and the gap-to-bar-width ratio.
  /// Both come from the original four-bar mark (`4·0.15 + 3·0.085 = 0.855`,
  /// gap/bar `= 0.085/0.15`), so the classic four-bar look is byte-for-byte
  /// unchanged and any other bar count scales to the same footprint.
  static const double _footprint = 0.855;
  static const double _gapToBar = 0.085 / 0.15;

  @override
  Widget build(BuildContext context) {
    final int count = bars.length;
    final double barWidth =
        size * _footprint / (count + _gapToBar * (count - 1));
    final double gap = barWidth * _gapToBar;
    final double radius = barWidth / 2;
    return SizedBox(
      width: size,
      height: size,
      child: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (Rect rect) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: gradient,
        ).createShader(rect),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < count; i++) ...<Widget>[
              if (i > 0) SizedBox(width: gap),
              Container(
                width: barWidth,
                height: size * bars[i],
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
