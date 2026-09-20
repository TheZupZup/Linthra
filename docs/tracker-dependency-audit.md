# Tracker dependency audit

Linthra's [privacy policy](../PRIVACY.md) says the app carries no third-party
advertising trackers and reports nothing home. That is a promise. This page is
about the part of it you can re-run yourself.

```bash
python3 scripts/check_tracker_dependencies.py
```

No network, no Flutter, no Android SDK, no Rust toolchain. Everything it reads
is committed, so the result you get is the result CI gets.

It runs on every pull request as the **Check for known tracker dependencies**
step of the "Secret & privacy scan" job in [`ci.yml`](../.github/workflows/ci.yml), and
`./scripts/verify_android.sh` runs it locally alongside the other guardrails.

This is one part of [#504](https://github.com/TheZupZup/Linthra/issues/504),
which asks for several independent kinds of evidence. The others (fixed network
destinations, the Android manifest surface, a report tied to the release APK's
SHA-256, and a runtime outbound-network smoke test) are separate work. **Nothing
on this page substitutes for them** — see [Limits](#limits).

## What it proves

A narrow, dependency-level property:

> None of the advertising, analytics, attribution, telemetry or third-party
> crash-reporting SDKs on Linthra's reviewed list is present in the dependency
> files Linthra ships from.

Today, and expected to stay this way:

```text
Advertising SDKs: none
Analytics SDKs: none
Attribution / install-tracking SDKs: none
Automatic third-party crash reporting: none
Telemetry, session-replay and APM SDKs: none
```

## What it reads

Every file below is committed, and the check fails if one of them is missing
rather than quietly reporting "none" about a file nobody read.

| File | What is extracted | Why it is in scope |
| --- | --- | --- |
| [`pubspec.lock`](../pubspec.lock) | Package name and dependency kind for every resolved package | The exact Dart/Flutter set every build resolves, the closest thing the app has to a bill of materials |
| [`flatpak/generated/sources/pubspec.json`](../flatpak/generated/sources/pubspec.json) | Pub package names of the archives fetched at build time | What the Linux/Flatpak package is actually built from |
| [`linux/flutter/generated_plugins.cmake`](../linux/flutter/generated_plugins.cmake) | Flutter plugin names | What gets linked into the Linux binary |
| `android/**/*.gradle`, `*.gradle.kts` | Maven `group:artifact` coordinates and Gradle plugin ids | Where an Android-side SDK would be added. Linthra declares no Maven dependencies of its own today; the point is the line that adds the first one |
| `native/**/Cargo.lock` | Crate names | The Rust core's resolved crates |

### The one scope caveat worth knowing

A pub lockfile records that a package is `transitive`, not *whose* transitive
dependency it is. So a package pulled in only by a dev dependency cannot be told
apart from one that ships. The check treats the whole locked graph as in scope
and fails closed, and prints the dependency kind (`direct main`, `direct dev`,
`transitive`) next to each finding, so a reviewer can see the distinction the
file itself cannot make.

## How matching works

Matching is on **exact identifiers**, never on substrings.

- A Dart entry has to equal a pub package name.
- A Maven entry has to equal a whole `group:artifact` coordinate, or — with
  `"match": "group"` — the coordinate's group, compared whole.
- A Gradle plugin entry has to equal a plugin id.
- A Cargo entry has to equal a crate name.

That is the difference between a check people keep and a check people switch
off. `grep -i amplitude` across a *music player's* dependency graph is a machine
for generating false alarms, and `com.google.firebaseui` is not Firebase. There
is deliberately no prefix rule and no regex rule.

The reviewed data lives in
[`scripts/tracker_policy.json`](../scripts/tracker_policy.json). Each entry
carries its ecosystem, match kind, identifier, category, vendor and the reason it
is on the list, so a reviewer can disagree with a specific line rather than with
the list as a whole. The loader is strict — an unknown key, a blank rationale, a
duplicate or an out-of-order list is an error, not something to skip past,
because an entry that is silently ignored is a rule that quietly stopped
applying.

## Limits

Read this part before quoting the check anywhere.

**It does not prove Linthra cannot track users.** It proves that no *named* SDK
is in the dependency graph. Those are very different claims, and the difference
is exactly the limitation the
[independent APK analysis](https://apptizo.com/app/linthra/) pointed out: not
finding a known tracking SDK says nothing about what an app's own network code
does.

Specifically, this check:

- **says nothing about Linthra's own code.** The app could send anything
  anywhere with `package:http` alone, and this check would still pass. Fixed
  network destinations and runtime network behaviour are separate parts of #504.
- **cannot name a tracker nobody has named yet.** The list covers systems that
  are widely deployed enough to be worth naming. A new one, or an in-house one,
  is not on it.
- **does not audit the built artifact.** It reads source-tree dependency files.
  Auditing the APK users actually install is its own part of #504.
- **does not look inside a dependency.** A package that is clean today can add a
  telemetry call in a patch release. The version bump is visible in
  `pubspec.lock`, and CI enforces the lockfile, but this check reads names, not
  behaviour.
- **does not judge self-hosted analytics.** Several listed SDKs (Matomo,
  Countly, PostHog) can point at a server you run. The endpoint is
  configuration, not a property of the package, which is exactly why they are
  flagged for a human rather than assumed either way.
- **does not cover Play Services in general.** Only the tracking-relevant
  `com.google.android.gms` artifacts are listed, so this check stays about
  tracking. Keeping Google Play Services out of the build altogether is
  F-Droid's rule, tracked in
  [fdroid-readiness.md](./fdroid-readiness.md).

## Reviewing a finding

A failure means a human has to decide. It does not mean someone did something
wrong — a new tracking dependency is usually transitive, arriving through a
package update nobody read line by line.

The output names everything you need:

```text
FAIL: 1 policy entry matches Linthra's dependency graph (1 occurrence).

  firebase_analytics  [Analytics SDKs]
      ecosystem: dart
      vendor:    Google (Firebase)
      matched:   dart exact policy entry "firebase_analytics"
      found in:  pubspec.lock (transitive)
      why it is flagged: Reports app events and a per-install identifier to
                         Google. Named explicitly in #504.
```

Work through it in this order.

**1. Find out how it got in.** `found in:` says which file, and for
`pubspec.lock` the dependency kind says whether somebody added it directly or it
arrived underneath something else. For a transitive package:

```bash
flutter pub deps --style=compact | grep -B2 firebase_analytics
```

**2. Decide whether Linthra needs it at all.** Nearly always the answer is no,
and the fix is to drop or replace whatever pulled it in, or to pin that package
back to a version that did not. If the dependency is genuinely optional to the
feature that brought it, that is the cheapest fix and the best outcome.

**3. If it cannot be removed, say so in public.** Add an entry to the
`exceptions` list in `scripts/tracker_policy.json`:

```json
{
  "ecosystem": "dart",
  "identifier": "some_package",
  "sources": ["pubspec.lock"],
  "reason": "Why Linthra ships this anyway, in a sentence someone can argue with.",
  "reviewed_in": "https://github.com/TheZupZup/Linthra/issues/504"
}
```

An exception is a claim that a human looked and decided, not a way to make the
check green. It is scoped to the files it names, and the check **fails when an
exception matches nothing**, so a reason can never outlive the dependency it
explains. If you add one, update [`PRIVACY.md`](../PRIVACY.md) and the status
block above in the same pull request: the whole point is that the public
statement and the check agree.

**4. If the finding is wrong, fix the policy, not the symptom.** If an entry
matches something innocent, that is a bug in
[`scripts/tracker_policy.json`](../scripts/tracker_policy.json) — correct the
identifier and add a regression test in
[`test/tooling/check_tracker_dependencies_test.py`](../test/tooling/check_tracker_dependencies_test.py)
so it stays fixed.

## Adding to the policy

New entries are welcome, especially for systems that are widely deployed and not
yet listed. Keep to the same bar:

- **An exact identifier**, as the ecosystem spells it. Not a family, not a
  keyword.
- **A rationale that says what the SDK does**, so a reviewer can disagree with
  the specific line.
- **A declared category**, one of the five in the `categories` block.
- **Sorted by `(ecosystem, identifier)` and unique.** The checker enforces both.

Then run the tests:

```bash
python3 test/tooling/check_tracker_dependencies_test.py
ruff check scripts tool tools && ruff format --check scripts tool tools
```

## Machine-readable output

`--json` prints the same report with fixed key order, for the release privacy
report that is still to come:

```bash
python3 scripts/check_tracker_dependencies.py --json
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | No reviewed tracker dependency matched (exceptions in force are printed) |
| `1` | A dependency matched, or a reviewed exception matched nothing |
| `2` | The check could not run: a source file is missing, or the policy file is unreadable |

## See also

- [`PRIVACY.md`](../PRIVACY.md) — the policy this check backs up
- [dependency-license-audit.md](./dependency-license-audit.md) — the other audit
  of the same dependency set, for licensing
- [dependency-updates.md](./dependency-updates.md) — how dependency bumps reach
  the repository in the first place
- [pr-security-guard.md](./pr-security-guard.md) — the security-surface guard on
  pull requests
- [fdroid-readiness.md](./fdroid-readiness.md) — why Linthra ships no Google Play
  Services at all
