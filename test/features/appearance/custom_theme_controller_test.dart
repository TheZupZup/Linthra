import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/custom_theme_settings.dart';
import 'package:linthra/data/repositories/custom_theme_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_custom_theme_store.dart';
import 'package:linthra/features/appearance/custom_theme_controller.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  ProviderContainer createContainer({
    CustomThemeSettings? initial,
    SupporterEntitlement entitlement = SupporterEntitlement.included,
  }) {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        customThemeStoreProvider.overrideWithValue(
          InMemoryCustomThemeStore(initial),
        ),
        supporterEntitlementProvider.overrideWithValue(entitlement),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('starts with the disabled Linthra colors', () {
    final ProviderContainer container = createContainer();

    expect(
      container.read(customThemeControllerProvider),
      CustomThemeSettings.defaults,
    );
  });

  test('loads persisted settings', () async {
    const CustomThemeSettings stored = CustomThemeSettings(
      enabled: true,
      primaryColorValue: 0xFF34C5FF,
      accentColorValue: 0xFFFF5DA2,
    );
    final ProviderContainer container = createContainer(initial: stored);

    container.read(customThemeControllerProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(customThemeControllerProvider), stored);
  });

  test('updates colors when cosmetics are available', () async {
    final InMemoryCustomThemeStore store = InMemoryCustomThemeStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        customThemeStoreProvider.overrideWithValue(store),
        supporterEntitlementProvider.overrideWithValue(
          SupporterEntitlement.unlocked,
        ),
      ],
    );
    addTearDown(container.dispose);

    final CustomThemeController controller =
        container.read(customThemeControllerProvider.notifier);
    expect(await controller.setEnabled(true), isTrue);
    expect(await controller.setPrimaryColor(0xFF22C7A9), isTrue);
    expect(await controller.setAccentColor(0xFFF5C518), isTrue);

    const CustomThemeSettings expected = CustomThemeSettings(
      enabled: true,
      primaryColorValue: 0xFF22C7A9,
      accentColorValue: 0xFFF5C518,
    );
    expect(container.read(customThemeControllerProvider), expected);
    expect(await store.read(), expected);
  });

  test('locked Play state rejects every customization', () async {
    final InMemoryCustomThemeStore store = InMemoryCustomThemeStore();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        customThemeStoreProvider.overrideWithValue(store),
        supporterEntitlementProvider.overrideWithValue(
          SupporterEntitlement.locked,
        ),
      ],
    );
    addTearDown(container.dispose);

    final CustomThemeController controller =
        container.read(customThemeControllerProvider.notifier);

    expect(await controller.setEnabled(true), isFalse);
    expect(await controller.setPrimaryColor(0xFFFFFFFF), isFalse);
    expect(await controller.setAccentColor(0xFFFFFFFF), isFalse);
    expect(
      container.read(customThemeControllerProvider),
      CustomThemeSettings.defaults,
    );
    expect(await store.read(), isNull);
  });

  test('reset restores the disabled Linthra palette', () async {
    const CustomThemeSettings stored = CustomThemeSettings(
      enabled: true,
      primaryColorValue: 0xFF34C5FF,
      accentColorValue: 0xFFFF5DA2,
    );
    final InMemoryCustomThemeStore store = InMemoryCustomThemeStore(stored);
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        customThemeStoreProvider.overrideWithValue(store),
        supporterEntitlementProvider.overrideWithValue(
          SupporterEntitlement.included,
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(customThemeControllerProvider);
    await Future<void>.delayed(Duration.zero);
    expect(
      await container.read(customThemeControllerProvider.notifier).reset(),
      isTrue,
    );

    expect(
      container.read(customThemeControllerProvider),
      CustomThemeSettings.defaults,
    );
    expect(await store.read(), CustomThemeSettings.defaults);
  });
}
