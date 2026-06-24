# Supporting Linthra

Linthra is **free and open source, and stays that way.** This document explains
the voluntary supporter model, the in-app "Support Linthra" screen, and the
build-safe structure that lets a future Play Store build add supporter purchases
**without** ever touching the F-Droid build.

> **TL;DR for reviewers / packagers:** this is a screen with copy and a few
> external links. There is **no billing SDK, no Google Play Billing, no ads, no
> tracking, and no feature gating** in this code path. An ordinary
> `flutter build` (CI and F-Droid alike) compiles the F-Droid action set only.

## 1. The supporter model

- **Linthra is free.** Every feature is available to everyone at no cost.
- **Support is optional.** Nothing in the app is locked, time-limited, or
  degraded if you don't contribute. The Support screen is an invitation, not a
  paywall.
- **No ads, no tracking.** Supporting the project does not change that, and the
  Support screen adds neither.
- **Where support goes.** Voluntary contributions help fund development, testing
  devices, app-store/distribution costs, and long-term maintenance.
- **Core features stay free — always.** Support never gates a feature. If a
  future build offers a "supporter" purchase, it buys goodwill (and a thank-you),
  not functionality.

A small, deliberately **secondary and playful** "lonely maintainer" aside sits
at the bottom of the screen. It is tone only: rendered inline (never a popup),
below the serious explanation (never the headline), it keeps "No pressure"
visible, blocks no navigation, and unlocks/changes nothing. It is not a paywall
or upsell, and is F-Droid/Play-safe.

## 2. Reaching the screen

In the app: **Settings → About → Support Linthra**.

The About page carries a "Support Linthra" card (distinct from the existing
"Support" help/contact card) that opens the screen at the route
`/settings/support` (`AppRoutes.settingsSupport`). The screen states the model
above and lists a few ways to help.

## 3. What the screen offers today

The actions are **data**, assembled per build (see §4). The default
(F-Droid / dev / GitHub-Release) set is external links only:

| Action | Opens | Notes |
| ------ | ----- | ----- |
| **GitHub Sponsors** | `https://github.com/sponsors/thezupzup` | Placeholder handle — replace/confirm when Sponsors is enabled on the account. |
| **Funding & supporter model** | this document on GitHub | The authoritative explanation of the model. |
| **View source code** | the repository | Reading, building, starring, and contributing are always free. |

Links open through the shared `externalLinkLauncherProvider` — the same browser
seam the About page and "Report a bug" flow use — so every launch is an explicit
user tap, nothing opens on its own, and widget tests stay plugin-free.

> **Placeholder URLs.** The donation handle above is a placeholder. The screen
> and tests only assert each link is well-formed (`https`, non-empty host),
> never that an account exists, so a maintainer can update
> `SupportLinks` in
> [`lib/features/support/support_actions_provider.dart`](../lib/features/support/support_actions_provider.dart)
> in one place when the real accounts are live.

## 4. Architecture — a small, extensible module

Everything lives under [`lib/features/support/`](../lib/features/support/):

| File | Responsibility |
| ---- | -------------- |
| `support_action.dart` | `SupportAction` — one way to support, as plain data (id, title, description, icon, `kind`, optional `url`). `SupportActionKind` is a small closed set: `externalLink` or `comingSoon`. |
| `support_actions_provider.dart` | The build seam: `SupportDistribution` (the channel), `supportActionsFor(distribution)` (a pure catalog), `SupportLinks` (the URLs in one place), `supportLinksEnabled` (the per-channel kill switch), and `supportActionsProvider` / `supportLinksEnabledProvider` (what the screen and About page read). |
| `support_screen.dart` | `SupportScreen` — renders the copy and whatever actions the provider yields. It owns **no** donation or payment logic. |

Two deliberate properties:

1. **The screen never hard-codes platform-specific donation/payment behavior.**
   It renders by the generic `SupportActionKind` only — an `externalLink` opens
   through the shared launcher; a `comingSoon` row is shown disabled. Which
   actions exist, and for which build, is decided by the provider, not the
   screen.

2. **The action set is chosen per build, behind one seam.**
   `SupportDistribution.current` reads `--dart-define=LINTHRA_DISTRIBUTION=...`
   and **defaults to `fdroid`** (mirroring how `AppInfo` reads its optional
   `LINTHRA_VERSION_NAME` override). The default is the safe one: a plain
   `flutter build` gets external links only.

3. **A per-channel kill switch can drop support entirely.**
   `supportLinksEnabled` reads `--dart-define=LINTHRA_SUPPORT_LINKS=...` and
   **defaults to enabled**. Build with `LINTHRA_SUPPORT_LINKS=off` (also
   `false`, `0`, `no`, `disabled`) and the in-app entry point disappears (the
   About page hides its "Support Linthra" card) and `supportActionsProvider`
   yields an empty list, so the screen — if reached directly — degrades to a
   purely informational "free & open source" page with no links. This is the
   lever for a distribution channel whose policy forbids in-app donation links,
   or a fork that wants none. Like the distribution flag it is **support-only**:
   it never affects playback, caching, providers, Android Auto, Cast,
   Backup/Restore, or any other app behavior.

The launcher path is also guarded: the screen only ever opens an `http`/`https`
web link (`isLaunchableHttpUrl`). Every shipped link is an `https` constant, so
this always passes today; the guard is defense in depth so a future mis-edited
link with a non-web scheme (a `tel:`, `mailto:`, `file:`, or custom app intent)
fails safe instead of being handed to the OS.

## 5. F-Droid safety

- The default `SupportDistribution` is `fdroid`, so an ordinary `flutter build`
  — local, CI, and the F-Droid build server — compiles the **external-links-only**
  set. No billing row is even listed.
- **No dependency changes.** This feature adds no packages to `pubspec.yaml`; it
  reuses the existing `url_launcher`-backed `externalLinkLauncher` seam. There is
  no Google Play Billing dependency, no proprietary SDK, and no GMS anywhere in
  the path.
- **No permission, playback, cache, or provider changes.**
- F-Droid builds **must remain free of any proprietary billing dependency.** The
  Play supporter purchase (below) must therefore be added in a way that ships
  **only** in the Play flavor — never as a shared/default dependency.

## 6. The future Play Store build (not in this PR)

> **Store-policy note — external donation/payment links.** F-Droid and GitHub
> builds may link out to donations freely. **A Play Store build may not.**
> Google Play's payments policy can restrict apps from linking out to external
> donations/payments unless the developer is a registered charity (and outright
> requires Google Play Billing for in-app purchases of digital goods). So a Play
> build may need to **change or remove** the external donation links — not just
> add billing. Two levers already exist and need **no screen change**:
>
> - `--dart-define=LINTHRA_DISTRIBUTION=play` — keep the links but adjust the set
>   per policy (e.g. swap GitHub Sponsors for a Play-Billing supporter action).
> - `--dart-define=LINTHRA_SUPPORT_LINKS=off` — drop the external links and the
>   entry point entirely for a channel that forbids them.
>
> Confirm the current Play policy before shipping a Play build; this is a policy
> question, not a code one, and the levers above are how the code adapts to the
> answer.

Play Store billing will be implemented **only in Play builds, later.** The
structure is already in place:

- `SupportDistribution.play` exists, and `supportActionsFor` already appends a
  single **disabled `comingSoon` placeholder** ("Become a supporter") for that
  channel. The placeholder carries no `url` and no billing code, so even if it is
  ever shown it does nothing.
- That placeholder is the reserved seat for a Google Play Billing supporter
  purchase.

When the Play build is implemented in a separate, Play-only PR, the intended
shape is:

1. Add the billing dependency and the purchase code **behind the Play flavor
   only** (e.g. a Play-only source set / conditional import / overridden
   provider), so it never enters the F-Droid build or `pubspec.yaml`'s default
   dependencies.
2. Add a new `SupportActionKind` (e.g. `purchase`) or override
   `supportActionsProvider` in the Play flavor to replace the `comingSoon`
   placeholder with a real purchase action.
3. Keep the supporter purchase **non-gating** — it must not unlock any feature.

Because the screen renders by `kind` and reads actions from the provider, adding
the purchase action requires **no change to `SupportScreen`** and **no change to
the F-Droid build.**

## 7. Tests

- `test/features/support/support_action_test.dart` — the data model (URL
  parsing, the `externalLink`-needs-a-`url` assertion) and the
  `isLaunchableHttpUrl` launch guard (accepts http/https, rejects null, non-web
  schemes, and host-less URLs).
- `test/features/support/support_actions_provider_test.dart` — the distribution
  parser, the `LINTHRA_SUPPORT_LINKS` kill-switch parser, and that F-Droid
  offers links only while Play adds the disabled placeholder; every external
  link is a well-formed `https` URL that passes the runtime launch guard.
- `test/features/support/support_screen_test.dart` — the copy (including the
  "donating does not unlock features" line), link taps (via a fake launcher),
  the disabled placeholder, the snackbar fallback, refusal to open a non-web
  link, and the links-disabled informational page (no actions card, no aside).
- `test/features/settings/hub/about_screen_test.dart` — the About entry, that it
  navigates to the support route, and that it hides when support links are
  disabled (while the help/contact card stays).
