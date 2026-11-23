# Google Play publishing

Linthra's GitHub release pipeline builds the Android release artifacts once in
`.github/workflows/android-release-build.yml`. The separate
`.github/workflows/google-play-closed-testing.yml` workflow reuses the
**release-signed AAB** from a successful tag build and uploads it to a Google
Play testing track.

The publisher never rebuilds the application and never publishes to production.
If Google Play is not configured yet, the workflow exits successfully with a
notice instead of breaking normal GitHub releases.

## What is already automated

For an `Android Release Build` that completes successfully for a release tag:

1. GitHub checks whether Google Play publishing is configured.
2. It looks for the `linthra-release-signed-aab` artifact from that exact run.
3. Debug-signed prereleases are skipped automatically.
4. The signed AAB is downloaded without rebuilding Linthra.
5. The bundle name is checked to confirm the build really was for a tag.
6. The tag named by that bundle is resolved, and must point at the very
   commit the build ran on.
7. The bundle is uploaded to the configured Google Play testing track with
   status `completed`.

Both release paths are covered: a directly pushed `v*` tag, and
`/publish-stable`, which dispatches `Android Release Build` with a
`release_tag` rather than pushing the tag itself. Ad-hoc manual
`workflow_dispatch` builds are never auto-published. The two are told apart by
the bundle name the build produces: a tag build writes
`linthra-<tag>-release-signed.aab`, while a manual build writes
`linthra-release-signed.aab`.

The bundle name records only what the build was told to target, so it is not
proof on its own: a manual dispatch can pass a `release_tag` that matches
`pubspec.yaml` but was never tagged. `Android Release Build` also checks out
its dispatch ref rather than the tag, so a build started while the branch had
moved past the tag would carry code the tag does not name. Before uploading,
the name is looked up as a tag ref specifically (`git/ref/tags/...`, not a
generic ref that a branch of the same name would also satisfy), annotated tags
are dereferenced to their commit, and that commit must equal the one the build
actually ran on. A missing tag and a mismatched commit fail separately.

If a stable release trips the commit check, the artifact genuinely is not the
tagged code: re-run the build against the tagged commit rather than relaxing
the check.

The workflow explicitly rejects `production` as a track, including as one entry
of a multi-track value such as `internal,production`, since the upload action
accepts a comma-separated list. All whitespace is stripped from the value
before it is split, so a newline cannot hide an entry from the check, and the
upload action is given that same normalized value rather than the raw variable.
Promotion to production stays a manual maintainer decision in Play Console.

## One-time Google Play setup

### 1. Create Linthra in Play Console

Create the app in Google Play Console with the existing permanent Android
package name:

```text
io.github.thezupzup.linthra
```

Do not create a second package name for Google Play. Android application IDs are
part of the update identity and must remain stable.

### 2. Upload the first AAB manually

The publishing action requires the package to already exist in the Play Console
account. Create the first testing release manually and upload a release-signed
Linthra AAB once through Play Console.

After that initial Play Console upload, later tagged releases can be delivered
by GitHub Actions.

### 3. Create the closed testing track and testers

In Play Console, create or select the closed testing track that Linthra will use.
Configure its tester list or Google Group and copy the track identifier used by
the Google Play Developer API.

The track title/identifier is what must be stored in the GitHub repository
variable described below.

### 4. Enable the Google Play Android Developer API

In a Google Cloud project, enable the **Google Play Android Developer API** and
create a service account dedicated to Linthra's GitHub release automation.

Use a narrow service-account identity rather than a personal Google credential.

### 5. Grant the service account Play Console access

In Play Console **Users and permissions**, invite the service account email and
grant access to Linthra only.

The required Play permission is:

- **Release apps to testing tracks**

Do not grant production-release permission to this automation account. The
workflow itself also rejects the `production` track as a second safety layer.

### 6. Add the GitHub secret

Create this repository Actions secret:

```text
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
```

Its value is the complete JSON service-account key.

Never commit the JSON key, a copied private key, or a generated credentials file
to the repository.

A future migration to Google Workload Identity Federation can remove the
long-lived JSON key without changing Linthra's release model.

### 7. Add the GitHub track variable

Create this repository Actions variable:

```text
GOOGLE_PLAY_TRACK
```

Set it to the closed testing track identifier from Play Console.

Do **not** set it to `production`; the workflow fails deliberately if production
is configured, including when it appears as one entry of a comma-separated list.

## Result

Once the secret and track variable are present, the normal Linthra release flow
becomes:

```text
version/tag
    ↓
Android Release Build
    ↓
release-signed AAB artifact
    ↓
Google Play Closed Testing
    ↓
testers receive the new Play Store build
```

There is no second Flutter build and no separate version source. The AAB sent to
Google Play is the same release artifact produced by the tagged GitHub build.

## Failure and skip behavior

The publisher is intentionally conservative:

- missing service-account secret → skip with a notice;
- missing track variable → skip with a notice;
- `production` track, alone or inside a multi-track value → fail;
- bundle names a tag that does not exist → fail;
- tag does not point at the commit the build ran on → fail;
- upstream Android release failed → publisher does not run;
- ad-hoc manual Android release build (no release tag) → skip with a notice;
- no release-signed AAB (for example, a debug-signed prerelease) → skip with a
  notice;
- multiple matching signed AAB artifacts → fail;
- downloaded artifact does not contain exactly one `.aab` → fail.

These checks keep an incomplete Google setup from breaking normal releases while
preventing an ambiguous or debug-signed artifact from reaching Google Play.

## Updating the upload action

The Google Play publisher pins `r0adkll/upload-google-play` to an exact commit
rather than a floating tag. When updating it:

1. review the upstream release notes;
2. replace the pinned SHA in
   `.github/workflows/google-play-closed-testing.yml`;
3. update the corresponding expected SHA in
   `test/tooling/google_play_publishing_guardrails_test.dart`;
4. run the tooling test and the normal Linthra CI suite.
