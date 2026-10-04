import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/app/external_link_launcher_provider.dart';
import 'package:linthra/core/models/custom_theme_settings.dart';
import 'package:linthra/core/models/github_device_authorization.dart';
import 'package:linthra/core/models/github_sponsor_status.dart';
import 'package:linthra/core/models/github_sponsor_verification.dart';
import 'package:linthra/core/models/theme_mode_preference.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/core/services/github_sponsor_client.dart';
import 'package:linthra/data/repositories/app_icon_variant_store_provider.dart';
import 'package:linthra/data/repositories/custom_theme_store_provider.dart';
import 'package:linthra/data/repositories/github_sponsor_token_store_provider.dart';
import 'package:linthra/data/repositories/in_memory_app_icon_variant_store.dart';
import 'package:linthra/data/repositories/in_memory_custom_theme_store.dart';
import 'package:linthra/data/repositories/in_memory_github_sponsor_token_store.dart';
import 'package:linthra/data/repositories/in_memory_theme_mode_store.dart';
import 'package:linthra/data/repositories/theme_mode_store_provider.dart';
import 'package:linthra/data/services/github_sponsor_client_provider.dart';
import 'package:linthra/features/appearance/app_icon_controller.dart';
import 'package:linthra/features/appearance/app_icon_variant.dart';
import 'package:linthra/features/appearance/appearance_settings_screen.dart';
import 'package:linthra/features/appearance/custom_theme_controller.dart';
import 'package:linthra/features/appearance/linthra_logo_mark.dart';
import 'package:linthra/features/appearance/theme_mode_controller.dart';
import 'package:linthra/features/settings/hub/about_screen.dart';
import 'package:linthra/features/support/github_sponsor_controller.dart';
import 'package:linthra/features/support/support_actions_provider.dart';
import 'package:linthra/features/support/supporter_entitlement.dart';

void main() {
  group('AppearanceSettingsScreen', () {
    late InMemoryAppIconVariantStore iconStore;
    late InMemoryCustomThemeStore themeStore;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      String? initialIcon,
      SupporterEntitlement entitlement = SupporterEntitlement.locked,
      SupportDistribution distribution = SupportDistribution.fdroid,
      List<Override> extraOverrides = const <Override>[],
      bool settle = true,
    }) async {
      iconStore = InMemoryAppIconVariantStore(initialIcon);
      themeStore = InMemoryCustomThemeStore();
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          appIconVariantStoreProvider.overrideWithValue(iconStore),
          customThemeStoreProvider.overrideWithValue(themeStore),
          supporterEntitlementProvider.overrideWithValue(entitlement),
          supportDistributionProvider.overrideWithValue(distribution),
          ...extraOverrides,
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppearanceSettingsScreen()),
        ),
      );
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
      return container;
    }

    testWidgets('lists every free built-in icon theme', (tester) async {
      await pump(tester);

      for (final AppIconVariant variant in AppIconVariants.all) {
        expect(find.text(variant.label), findsOneWidget);
      }
      expect(find.text('Preview'), findsNothing);
    });

    testWidgets('F-Droid does not render the supporter palette',
        (tester) async {
      await pump(
        tester,
        entitlement: SupporterEntitlement.unlocked,
        distribution: SupportDistribution.fdroid,
      );

      expect(find.text('Custom color palette'), findsNothing);
      expect(find.byKey(const Key('custom-theme-enabled')), findsNothing);
      expect(find.textContaining('optional custom palette'), findsNothing);
    });

    testWidgets('tapping Gold selects and persists it for free',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      await tester.tap(find.text('Gold'));
      await tester.pumpAndSettle();

      expect(container.read(appIconControllerProvider), AppIconVariants.gold);
      expect(await iconStore.read(), 'gold');
    });

    testWidgets('unlocked GitHub build can enable and recolor the palette',
        (tester) async {
      final ProviderContainer container = await pump(
        tester,
        entitlement: SupporterEntitlement.unlocked,
        distribution: SupportDistribution.githubRelease,
      );

      expect(find.text('Custom color palette'), findsOneWidget);
      expect(find.text('GitHub Sponsor'), findsOneWidget);

      await tester.tap(find.byKey(const Key('custom-theme-primary-cyan')));
      await tester.tap(find.byKey(const Key('custom-theme-enabled')));
      await tester.pumpAndSettle();

      const CustomThemeSettings expected = CustomThemeSettings(
        enabled: true,
        primaryColorValue: 0xFF34C5FF,
        accentColorValue: CustomThemeSettings.defaultAccentColorValue,
      );
      expect(container.read(customThemeControllerProvider), expected);
      expect(await themeStore.read(), expected);
    });

    testWidgets('Play hides the palette until billing exists', (tester) async {
      final ProviderContainer container = await pump(
        tester,
        entitlement: SupporterEntitlement.unlocked,
        distribution: SupportDistribution.play,
      );

      expect(find.text('Custom color palette'), findsNothing);
      expect(find.byKey(const Key('custom-theme-enabled')), findsNothing);

      await tester.tap(find.text('Black & White'));
      await tester.pumpAndSettle();
      expect(
        container.read(appIconControllerProvider),
        AppIconVariants.blackWhite,
      );
      expect(await iconStore.read(), 'blackwhite');
    });

    testWidgets('GitHub APK asks for a monthly sponsorship', (tester) async {
      await pump(
        tester,
        entitlement: SupporterEntitlement.locked,
        distribution: SupportDistribution.githubRelease,
      );

      expect(find.text('Monthly sponsor'), findsOneWidget);
      expect(
        find.byKey(const Key('custom-theme-github-sponsors')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('custom-theme-connect-github')),
        findsOneWidget,
      );
      expect(find.textContaining('active monthly GitHub Sponsors'),
          findsOneWidget);
      expect(find.byKey(const Key('custom-theme-enabled')), findsNothing);
    });

    testWidgets('GitHub APK lets a connected non-sponsor disconnect',
        (tester) async {
      // The token is checked again at every launch, so it has to be removable
      // even when the account turned out not to be an active sponsor.
      final InMemoryGitHubSponsorTokenStore tokenStore =
          InMemoryGitHubSponsorTokenStore('saved-token');
      await pump(
        tester,
        entitlement: SupporterEntitlement.locked,
        distribution: SupportDistribution.githubRelease,
        extraOverrides: <Override>[
          githubSponsorTokenStoreProvider.overrideWithValue(tokenStore),
          githubSponsorClientProvider.overrideWithValue(
            const _InactiveGitHubSponsorClient(),
          ),
        ],
      );

      final Finder disconnect =
          find.byKey(const Key('custom-theme-disconnect-github'));
      expect(disconnect, findsOneWidget);
      expect(
        find.byKey(const Key('custom-theme-refresh-sponsorship')),
        findsOneWidget,
      );

      await tester.ensureVisible(disconnect);
      await tester.tap(disconnect);
      await tester.pumpAndSettle();

      expect(await tokenStore.read(), isNull);
      expect(disconnect, findsNothing);
    });

    testWidgets('cancelling GitHub connect does not stay stuck checking',
        (tester) async {
      final ProviderContainer container = await pump(
        tester,
        entitlement: SupporterEntitlement.locked,
        distribution: SupportDistribution.githubRelease,
        extraOverrides: <Override>[
          githubSponsorTokenStoreProvider.overrideWithValue(
            InMemoryGitHubSponsorTokenStore(),
          ),
          githubSponsorClientProvider.overrideWithValue(
            const _InactiveGitHubSponsorClient(),
          ),
        ],
      );

      final Finder connect =
          find.byKey(const Key('custom-theme-connect-github'));
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      // While checking, the card spins an indeterminate progress indicator,
      // so the screen never settles: wait for the dialog itself instead.
      await _pumpUntil(tester, () => _userCode.evaluate().isNotEmpty);

      expect(find.text('Connect GitHub'), findsWidgets);
      expect(_access(container), GitHubSponsorAccess.checking);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _pumpUntil(tester, () => _userCode.evaluate().isEmpty);

      expect(_access(container), GitHubSponsorAccess.signedOut);
      final FilledButton button = tester.widget<FilledButton>(connect);
      expect(button.onPressed, isNotNull);
    });

    testWidgets(
        'closing an inactive Sponsor result keeps the connected authorization',
        (tester) async {
      final InMemoryGitHubSponsorTokenStore tokenStore =
          InMemoryGitHubSponsorTokenStore();
      final ProviderContainer container = await pump(
        tester,
        entitlement: SupporterEntitlement.locked,
        distribution: SupportDistribution.githubRelease,
        extraOverrides: <Override>[
          githubSponsorTokenStoreProvider.overrideWithValue(tokenStore),
          githubSponsorClientProvider.overrideWithValue(
            const _InactiveGitHubSponsorClient(),
          ),
          externalLinkLauncherProvider.overrideWithValue(
            const _SuccessfulExternalLinkLauncher(),
          ),
        ],
      );

      final Finder connect =
          find.byKey(const Key('custom-theme-connect-github'));
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await _pumpUntil(tester, () => _userCode.evaluate().isNotEmpty);

      await tester.tap(
        find.byKey(const Key('github-sponsor-open-and-verify')),
      );
      // The dialog shows an indeterminate progress bar until GitHub answers.
      final Finder result =
          find.byKey(const Key('github-sponsor-dialog-message'));
      await _pumpUntil(tester, () => result.evaluate().isNotEmpty);

      expect(_access(container), GitHubSponsorAccess.inactive);
      expect(await tokenStore.read(), 'new-token');

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _pumpUntil(tester, () => _userCode.evaluate().isEmpty);

      expect(_access(container), GitHubSponsorAccess.inactive);
      expect(await tokenStore.read(), 'new-token');
      expect(
        find.byKey(const Key('custom-theme-disconnect-github')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('custom-theme-refresh-sponsorship')),
        findsOneWidget,
      );
    });

    testWidgets('leaving before GitHub sends a code does not stay checking',
        (tester) async {
      final _HeldGitHubSponsorClient client = _HeldGitHubSponsorClient();
      final ProviderContainer container = await pump(
        tester,
        entitlement: SupporterEntitlement.locked,
        distribution: SupportDistribution.githubRelease,
        extraOverrides: <Override>[
          githubSponsorTokenStoreProvider.overrideWithValue(
            InMemoryGitHubSponsorTokenStore(),
          ),
          githubSponsorClientProvider.overrideWithValue(client),
        ],
      );

      final Finder connect =
          find.byKey(const Key('custom-theme-connect-github'));
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await _pumpUntil(tester, () => client.deviceCodeRequests > 0);
      expect(_access(container), GitHubSponsorAccess.checking);

      // The user backs out of the screen while GitHub is still answering.
      await tester.pumpWidget(const SizedBox());
      client.deviceCode.complete();
      await _pumpUntil(
        tester,
        () => _access(container) != GitHubSponsorAccess.checking,
      );

      expect(_access(container), GitHubSponsorAccess.signedOut);
      expect(_userCode, findsNothing);
    });

    testWidgets('a saved account still being checked cannot connect again',
        (tester) async {
      // The launch check is a check too. Offering Connect GitHub while it
      // runs would start a second sign-in beside it.
      final _HeldGitHubSponsorClient client = _HeldGitHubSponsorClient();
      final ProviderContainer container = await pump(
        tester,
        settle: false,
        entitlement: SupporterEntitlement.locked,
        distribution: SupportDistribution.githubRelease,
        extraOverrides: <Override>[
          githubSponsorTokenStoreProvider.overrideWithValue(
            InMemoryGitHubSponsorTokenStore('saved-token'),
          ),
          githubSponsorClientProvider.overrideWithValue(client),
        ],
      );
      await _pumpUntil(tester, () => client.verifications > 0);

      final Finder connect =
          find.byKey(const Key('custom-theme-connect-github'));
      expect(container.read(githubSponsorControllerProvider).isLoading, isTrue);
      expect(find.text('Checking GitHub…'), findsOneWidget);
      expect(tester.widget<FilledButton>(connect).onPressed, isNull);

      client.verification.complete(
        const GitHubSponsorVerification(
          login: 'music-fan',
          hasActiveMonthlySponsorship: false,
        ),
      );
      await _pumpUntil(
        tester,
        () => _access(container) == GitHubSponsorAccess.inactive,
      );
      await tester.pump();

      expect(find.text('Connect GitHub'), findsOneWidget);
      expect(tester.widget<FilledButton>(connect).onPressed, isNotNull);
      expect(
        find.byKey(const Key('custom-theme-disconnect-github')),
        findsOneWidget,
      );
    });

    testWidgets('offers System, Light, and Dark, starting on System',
        (tester) async {
      final ProviderContainer container = await pump(tester);

      for (final ThemeModePreference preference in ThemeModePreference.values) {
        expect(
          find.text(preference.label),
          findsOneWidget,
          reason: '${preference.label} must be offered',
        );
      }
      expect(
        container.read(themeModeControllerProvider),
        ThemeModePreference.system,
      );
      expect(find.textContaining('follows your device'), findsOneWidget);
    });

    testWidgets('picking Light selects and persists it', (tester) async {
      final ProviderContainer container = await pump(tester);

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();

      expect(
        container.read(themeModeControllerProvider),
        ThemeModePreference.light,
      );
      expect(
        container.read(themeModeStoreProvider),
        isA<InMemoryThemeModeStore>().having(
          (InMemoryThemeModeStore store) => store.preference,
          'persisted preference',
          ThemeModePreference.light,
        ),
      );
      // The blurb switches away from the "follows your device" wording once a
      // mode is pinned, so the card always states what is actually happening.
      expect(find.textContaining('follows your device'), findsNothing);
      expect(
          find.textContaining('always uses the light theme'), findsOneWidget);
    });
  });

  group('Selected branding in About', () {
    testWidgets('About renders the mark in the selected variant',
        (tester) async {
      final InMemoryAppIconVariantStore store =
          InMemoryAppIconVariantStore('neon');
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appIconVariantStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: AboutScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final LinthraLogoMark mark =
          tester.widget<LinthraLogoMark>(find.byType(LinthraLogoMark));
      expect(mark.gradient, AppIconVariants.neon.gradient);
      expect(mark.bars, AppIconVariants.neon.bars);
    });
  });
}

final Finder _userCode = find.byKey(const Key('github-sponsor-user-code'));

GitHubSponsorAccess? _access(ProviderContainer container) =>
    container.read(githubSponsorControllerProvider).valueOrNull?.access;

/// Pumps frame by frame until [condition] holds.
///
/// For screens that never settle: the Sponsor card and the sign-in dialog
/// show indeterminate progress indicators while GitHub is checked, and
/// pumpAndSettle would wait on that animation until it times out.
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (int frame = 0; frame < 50 && !condition(); frame++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: 'Not reached within 50 frames.');
}

/// Holds GitHub's answers until the test gives them.
class _HeldGitHubSponsorClient extends _InactiveGitHubSponsorClient {
  _HeldGitHubSponsorClient();

  final Completer<void> deviceCode = Completer<void>();
  int deviceCodeRequests = 0;

  final Completer<GitHubSponsorVerification> verification =
      Completer<GitHubSponsorVerification>();
  int verifications = 0;

  @override
  Future<GitHubDeviceAuthorization> requestDeviceAuthorization() async {
    deviceCodeRequests++;
    await deviceCode.future;
    return super.requestDeviceAuthorization();
  }

  @override
  Future<GitHubSponsorVerification> verifySponsorship(String accessToken) {
    verifications++;
    return verification.future;
  }
}

class _SuccessfulExternalLinkLauncher implements ExternalLinkLauncher {
  const _SuccessfulExternalLinkLauncher();

  @override
  Future<bool> open(Uri url) async => true;
}

class _InactiveGitHubSponsorClient implements GitHubSponsorClient {
  const _InactiveGitHubSponsorClient();

  @override
  bool get isConfigured => true;

  @override
  Future<GitHubDeviceAuthorization> requestDeviceAuthorization() async {
    return GitHubDeviceAuthorization(
      deviceCode: 'device-code',
      userCode: 'ABCD-EFGH',
      verificationUri: Uri.parse('https://github.com/login/device'),
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      pollInterval: Duration.zero,
    );
  }

  @override
  Future<String> pollForAccessToken(
    GitHubDeviceAuthorization authorization,
  ) async {
    return 'new-token';
  }

  @override
  Future<GitHubSponsorVerification> verifySponsorship(
    String accessToken,
  ) async {
    return const GitHubSponsorVerification(
      login: 'music-fan',
      hasActiveMonthlySponsorship: false,
    );
  }
}
