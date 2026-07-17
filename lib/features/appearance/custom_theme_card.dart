import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/dimens.dart';
import '../../app/routes.dart';
import '../../core/models/custom_theme_settings.dart';
import '../support/supporter_entitlement.dart';
import 'custom_theme_controller.dart';

/// Appearance controls for Linthra's optional two-color custom palette.
class CustomThemeCard extends ConsumerWidget {
  const CustomThemeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CustomThemeSettings settings =
        ref.watch(customThemeControllerProvider);
    final SupporterEntitlement entitlement =
        ref.watch(supporterEntitlementProvider);
    final CustomThemeController controller =
        ref.read(customThemeControllerProvider.notifier);
    final bool canCustomize = entitlement.allowsCosmetics;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Header(entitlement: entitlement),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Choose separate colors for Linthra’s identity and playback '
              'accent. This changes appearance only — never music features.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.65),
                  ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (!canCustomize)
              const _LockedContent()
            else ...<Widget>[
              SwitchListTile(
                key: const Key('custom-theme-enabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Use custom palette'),
                subtitle: const Text(
                  'Override the colors selected by the app icon theme.',
                ),
                value: settings.enabled,
                onChanged: (bool enabled) {
                  controller.setEnabled(enabled);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              _ColorSelector(
                label: 'Identity color',
                roleKey: 'primary',
                selectedValue: settings.primaryColorValue,
                onSelected: (int value) {
                  controller.setPrimaryColor(value);
                },
              ),
              const SizedBox(height: AppSpacing.md),
              _ColorSelector(
                label: 'Playback accent',
                roleKey: 'accent',
                selectedValue: settings.accentColorValue,
                onSelected: (int value) {
                  controller.setAccentColor(value);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('custom-theme-reset'),
                  onPressed: settings == CustomThemeSettings.defaults
                      ? null
                      : () {
                          controller.reset();
                        },
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset colors'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entitlement});

  final SupporterEntitlement entitlement;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Icon(Icons.color_lens_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Custom color palette',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Text(
            entitlement == SupporterEntitlement.included
                ? 'Included'
                : 'Supporter',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _LockedContent extends StatelessWidget {
  const _LockedContent();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _PalettePreview(),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.lock_outline,
              size: 20,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'Custom palettes are an optional visual thank-you in the Play '
                'edition. Every built-in icon theme and every core music '
                'feature remain free.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('custom-theme-support-options'),
            onPressed: () => context.push(AppRoutes.settingsSupport),
            icon: const Icon(Icons.favorite_outline),
            label: const Text('View supporter options'),
          ),
        ),
      ],
    );
  }
}

class _PalettePreview extends StatelessWidget {
  const _PalettePreview();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: _choices
          .take(6)
          .map(
            (_ColorChoice choice) => Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: choice.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _ColorSelector extends StatelessWidget {
  const _ColorSelector({
    required this.label,
    required this.roleKey,
    required this.selectedValue,
    required this.onSelected,
  });

  final String label;
  final String roleKey;
  final int selectedValue;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: <Widget>[
            for (final _ColorChoice choice in _choices)
              _ColorSwatch(
                key: Key('custom-theme-$roleKey-${choice.id}'),
                choice: choice,
                selected: selectedValue == choice.value,
                onTap: () => onSelected(choice.value),
              ),
          ],
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    super.key,
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final _ColorChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: choice.label,
      child: Tooltip(
        message: choice.label,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: choice.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.outline,
                width: selected ? 3 : 1,
              ),
              boxShadow: selected
                  ? <BoxShadow>[
                      BoxShadow(
                        color: choice.color.withValues(alpha: 0.35),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 20,
                    color: ThemeData.estimateBrightnessForColor(choice.color) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _ColorChoice {
  const _ColorChoice(this.id, this.label, this.value);

  final String id;
  final String label;
  final int value;

  Color get color => Color(value);
}

const List<_ColorChoice> _choices = <_ColorChoice>[
  _ColorChoice('violet', 'Violet', 0xFF7C5CFF),
  _ColorChoice('orange', 'Orange', 0xFFFF9F43),
  _ColorChoice('cyan', 'Cyan', 0xFF34C5FF),
  _ColorChoice('blue', 'Blue', 0xFF4D7CFE),
  _ColorChoice('teal', 'Teal', 0xFF22C7A9),
  _ColorChoice('green', 'Green', 0xFF54C46F),
  _ColorChoice('gold', 'Gold', 0xFFF5C518),
  _ColorChoice('pink', 'Pink', 0xFFFF5DA2),
  _ColorChoice('red', 'Red', 0xFFE85D68),
  _ColorChoice('white', 'White', 0xFFFFFFFF),
];
