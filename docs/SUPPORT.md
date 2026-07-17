# Supporting Linthra

Linthra is **free and open source, and stays that way.** Support is optional and
helps fund development, testing devices, distribution costs, and long-term
maintenance.

> **Packager summary:** core music features and every built-in icon theme remain
> free. F-Droid includes the custom palette. A separate APK attached to GitHub
> Releases can require an active GitHub sponsorship of at least **$3 USD per
> month** to unlock that one cosmetic palette.

## Principles

- **Core features stay free.** Playback, offline listening, Jellyfin, Navidrome,
  Plex, local files, Cast, Android Auto, downloads, backup/restore, and storage
  behaviour never depend on supporter status.
- **Built-in appearance stays free.** Classic, Neon, Gold, and Black & White are
  available to everyone, including their in-app and Android launcher icons.
- **The paid reward is cosmetic only.** The GitHub Release APK may lock the custom
  two-color palette until an active GitHub sponsorship of at least $3 USD per
  month is verified.
- **No ads or tracking.** Support does not introduce either.
- **F-Droid remains complete.** F-Droid includes the custom palette and does not
  require a GitHub account.
- **The lock is not DRM.** Linthra is open source; this is a respectful supporter
  benefit, not an attempt to prevent modified builds.

## Distribution seam

`SupportDistribution.current` reads:

```text
--dart-define=LINTHRA_DISTRIBUTION=fdroid
--dart-define=LINTHRA_DISTRIBUTION=github
--dart-define=LINTHRA_DISTRIBUTION=play
```

The default is `fdroid`.

| Distribution | Custom palette |
| --- | --- |
| `fdroid` | Included |
| `github` | Requires an active GitHub sponsorship of at least $3 USD/month |
| `play` | Included until a separate Play Billing integration exists |

The support-link kill switch remains available:

```text
--dart-define=LINTHRA_SUPPORT_LINKS=off
```

## GitHub Sponsor verification

The GitHub APK uses GitHub's OAuth device flow:

1. Linthra requests a temporary device and user code.
2. The user opens `https://github.com/login/device` and authorizes Linthra.
3. Linthra receives an OAuth token without embedding a client secret.
4. The token is stored with `flutter_secure_storage`.
5. Linthra queries GitHub GraphQL for
   `sponsorshipForViewerAsSponsor(activeOnly: true)` on `TheZupZup`.
6. The palette unlocks only when the sponsorship exists,
   `isOneTimePayment` is `false`, and the selected tier reports
   `monthlyPriceInCents >= 300`.

A one-time sponsorship or a recurring sponsorship below $3 USD per month does
not unlock this benefit. After starting or upgrading a monthly sponsorship, the
user can tap **Check again** without reconnecting.

The application requests only the `read:user` OAuth scope. It never receives or
stores the user's GitHub password.

## Required GitHub OAuth app setup

Create a GitHub OAuth app owned by the maintainer account:

1. Open GitHub **Settings → Developer settings → OAuth Apps**.
2. Register a new OAuth app named `Linthra`.
3. Use the Linthra repository or project page as the homepage and callback URL.
4. Enable **Device Flow**.
5. Copy the public OAuth client ID.
6. Add it as the repository Actions variable
   `LINTHRA_GITHUB_OAUTH_CLIENT_ID`.

The client ID is public by design. Never add or compile an OAuth client secret
into the APK; the device flow does not need one.

The sponsorable login defaults to `TheZupZup`. A fork may override it with:

```text
--dart-define=LINTHRA_GITHUB_SPONSOR_LOGIN=another-account
```

## GitHub Release APK

The release workflow keeps the existing APKs unchanged because their per-ABI
files are reproducible-build references for F-Droid. When
`LINTHRA_GITHUB_OAUTH_CLIENT_ID` is configured, it additionally builds:

```text
linthra-<tag>-github-sponsor.apk
```

That separate universal APK is compiled with:

```text
--dart-define=LINTHRA_DISTRIBUTION=github
--dart-define=LINTHRA_GITHUB_OAUTH_CLIENT_ID=<public client id>
```

The existing canonical APK, AAB, and per-ABI APK names remain untouched.

## Custom palette architecture

The Appearance screen keeps the free icon-theme picker and adds a separate
**Custom color palette** card.

The palette stores three non-secret preferences:

- whether the custom palette is enabled;
- the identity color;
- the playback-accent color.

`CustomThemeController` owns loading, editing, resetting, and persistence.
`customBrandPalette` derives accessible foreground, bright, deep, and container
tones from the two selected colors.

`GitHubSponsorController` separately owns OAuth authorization, encrypted token
storage, sponsorship verification, refresh, and disconnect. The theme controller
never sees the OAuth token.

## Internal testing

The pure entitlement parser still supports a forced value for non-production UI
tests:

```text
--dart-define=LINTHRA_DISTRIBUTION=github \
--dart-define=LINTHRA_SUPPORTER_COSMETICS=unlocked
```

Runtime GitHub builds use the verified controller state instead of trusting this
flag.

## Future Play Billing integration

Google Play Billing is not implemented here. A later Play-only integration must
remain separate from F-Droid and affect the custom palette only.

## Tests

Relevant coverage lives in:

- `test/data/services/http_github_sponsor_client_test.dart`
- `test/features/support/github_sponsor_controller_test.dart`
- `test/features/support/supporter_entitlement_test.dart`
- `test/features/support/support_actions_provider_test.dart`
- `test/features/support/support_screen_test.dart`
- `test/features/appearance/appearance_settings_screen_test.dart`
- `test/features/appearance/custom_theme_controller_test.dart`

The central contract is enforced throughout: sponsorship may unlock one optional
color palette in the direct APK, but never restricts Linthra's music features or
its built-in icon themes.
