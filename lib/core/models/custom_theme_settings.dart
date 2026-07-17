/// Persisted color choices for Linthra's optional custom palette.
///
/// Colors are stored as ARGB integers so this model stays independent from
/// Flutter widgets and can be serialized by lightweight key/value stores.
class CustomThemeSettings {
  const CustomThemeSettings({
    required this.enabled,
    required this.primaryColorValue,
    required this.accentColorValue,
  });

  static const int defaultPrimaryColorValue = 0xFF7C5CFF;
  static const int defaultAccentColorValue = 0xFFFF9F43;

  static const CustomThemeSettings defaults = CustomThemeSettings(
    enabled: false,
    primaryColorValue: defaultPrimaryColorValue,
    accentColorValue: defaultAccentColorValue,
  );

  final bool enabled;
  final int primaryColorValue;
  final int accentColorValue;

  CustomThemeSettings copyWith({
    bool? enabled,
    int? primaryColorValue,
    int? accentColorValue,
  }) {
    return CustomThemeSettings(
      enabled: enabled ?? this.enabled,
      primaryColorValue: primaryColorValue ?? this.primaryColorValue,
      accentColorValue: accentColorValue ?? this.accentColorValue,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CustomThemeSettings &&
        other.enabled == enabled &&
        other.primaryColorValue == primaryColorValue &&
        other.accentColorValue == accentColorValue;
  }

  @override
  int get hashCode => Object.hash(
        enabled,
        primaryColorValue,
        accentColorValue,
      );
}
