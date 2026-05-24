# Release signing

How Linthra's Android release builds are signed, what secrets the CI workflow
needs, how to generate a keystore locally, how to rotate it, and how all of
this relates to F-Droid.

> **No signing keys or secrets live in this repository.** Keystores
> (`*.keystore`, `*.jks`) and `android/key.properties` are git-ignored. Never
> commit them, never paste a real password into code, CI YAML, or a commit
> message.

## 1. How signing is wired

`android/app/build.gradle` resolves the release signing config at build time
from one of two sources, in this order of precedence:

1. **Environment variables** — used by CI. The release workflow decodes a
   keystore from a secret and exports its path.
2. **`android/key.properties`** — a git-ignored file for local release builds.

| Purpose          | Environment variable        | `key.properties` key |
| ---------------- | --------------------------- | -------------------- |
| Keystore file    | `LINTHRA_KEYSTORE_PATH`     | `storeFile`          |
| Keystore password| `LINTHRA_KEYSTORE_PASSWORD` | `storePassword`      |
| Key alias        | `LINTHRA_KEY_ALIAS`         | `keyAlias`           |
| Key password     | `LINTHRA_KEY_PASSWORD`      | `keyPassword`        |

If — and only if — all four values are present **and** the keystore file
exists, the release build is signed with that key. Otherwise the build falls
back to the **debug** key so `flutter run --release` still works. Debug-signed
release builds are **not** real releases and must never be distributed as such.

## 2. Required GitHub Secrets (CI)

Configure these under **Settings → Secrets and variables → Actions** before
running the release workflow with `signed = true`:

| Secret                      | Contents                                              |
| --------------------------- | ----------------------------------------------------- |
| `LINTHRA_KEYSTORE_BASE64`   | The keystore file, base64-encoded (see below).        |
| `LINTHRA_KEYSTORE_PASSWORD` | The keystore (store) password.                        |
| `LINTHRA_KEY_ALIAS`         | The key alias inside the keystore.                    |
| `LINTHRA_KEY_PASSWORD`      | The password for that key.                            |

The workflow only reads these when triggered with `signed = true`. If any are
missing in that case, the run **fails fast** with a clear error rather than
silently producing a debug-signed build.

Encode the keystore for the `LINTHRA_KEYSTORE_BASE64` secret:

```sh
base64 -w0 linthra-release.keystore   # Linux
base64 linthra-release.keystore       # macOS (no -w flag)
```

Copy the output into the secret value. The CI job decodes it to a temporary
file at runtime and never writes it into the repository.

## 3. Running the release workflow

The **Android Release Build** workflow runs **manually** (`workflow_dispatch`)
for test builds and **automatically on `v*` tags** for release builds. It does
not publish to any store, submit to F-Droid, or write production release notes.

Artifacts are named with the version (tag) and signing label, e.g.
`linthra-v0.1.0-alpha.1-debug-signed.apk` or
`linthra-v0.1.0-alpha.1-release-signed.aab`, so a debug-signed build can never
be confused with a production release. They are uploaded as workflow artifacts
(`linthra-<signing>-apk` / `linthra-<signing>-aab`).

- **Manual unsigned preview (default):** run with `signed = false` →
  debug-signed artifacts. Manual runs never touch any GitHub Release.
- **Manual release-signed build:** run with `signed = true` (requires the
  secrets above; the run **fails fast** if any are missing) → release-signed
  artifacts.
- **Automatic tag build (`v*` push):** attempts release signing, with behavior
  that depends on whether the tag is a pre-release:
  - **Alpha/beta/rc tags** (containing `alpha`, `beta`, or `rc`): attach the
    APK/AAB to a GitHub **pre-release**, creating one if it does not exist. If
    the secrets are present the artifacts are **release-signed**; if any secret
    is missing the run logs a warning and attaches clearly-labeled
    **debug-signed** (testing-only) artifacts instead of faking a release.
  - **Stable tags** (e.g. `v1.0.0`): **require release signing**. If any secret
    is missing the run **fails fast**. Release-signed assets are uploaded only
    to a Release that already exists; stable Releases are never auto-created.

> **Minimal permissions.** The build job runs with `contents: read`. Only the
> separate Release-attachment job is granted `contents: write`, and only to
> create a pre-release (alpha/beta/rc) or upload/replace Release assets. It
> never writes production release notes for you.

## 4. Generating a keystore locally

A release keystore is a long-lived secret. Generate it once, back it up
securely (a password manager or offline encrypted storage), and reuse it for
every release — Android will reject an update signed by a different key.

```sh
keytool -genkey -v \
  -keystore linthra-release.keystore \
  -alias linthra \
  -keyalg RSA -keysize 4096 \
  -validity 10000 \
  -storetype PKCS12
```

`keytool` will prompt for the keystore password, the key password, and your
distinguished-name details. Record the alias and both passwords in your
password manager.

For a **local** release build, create `android/key.properties` (git-ignored):

```properties
storeFile=/absolute/path/to/linthra-release.keystore
storePassword=…
keyAlias=linthra
keyPassword=…
```

Then build:

```sh
flutter build apk --release
flutter build appbundle --release
```

Do not commit `android/key.properties` or the keystore. Both are already
covered by `android/.gitignore` (`key.properties`, `**/*.keystore`,
`**/*.jks`).

## 5. Rotating the key

Rotate if the key may be compromised, or as routine hygiene. Note that for a
given app **identity on a store**, the signing key generally cannot be changed
freely once published — plan rotation carefully.

1. Generate a **new** keystore with the steps in §4 (use a fresh file name,
   alias, and passwords; keep the old one until rotation is verified).
2. Update the GitHub Secrets:
   - re-encode the new keystore and replace `LINTHRA_KEYSTORE_BASE64`;
   - update `LINTHRA_KEYSTORE_PASSWORD`, `LINTHRA_KEY_ALIAS`, and
     `LINTHRA_KEY_PASSWORD`.
3. Update any local `android/key.properties` to point at the new keystore.
4. Run the release workflow with `signed = true` and verify the artifact is
   signed by the new key (`apksigner verify --print-certs app-release.apk` or
   `keytool -printcert -jarfile app-release.apk`).
5. Securely archive or destroy the old keystore once the new one is confirmed.
6. If the app is published anywhere, follow that channel's key-rotation
   procedure:
   - **Play Store:** if Play App Signing is enabled, rotate the *upload* key via
     the Play Console; the app signing key is managed by Google.
   - **F-Droid:** F-Droid signs with its own key (see §6) — rotating our key
     does not change F-Droid-distributed artifacts.

## 6. F-Droid signing considerations

- **F-Droid signs builds itself.** When an app is distributed through the main
  F-Droid repository, F-Droid builds from source on its own infrastructure and
  signs the APK with **F-Droid's** signing key, not ours. Our release keystore
  is therefore not used by, and not given to, F-Droid.
- **GitHub Releases signing is separate.** A **release-signed** APK/AAB attached
  to a GitHub Release (built on a `v*` tag) is signed with *our* release key.
  That means the F-Droid build and a release-signed GitHub-Release build of the
  same version have **different signatures** and cannot be cross-installed as
  updates of each other. This is expected; document it clearly for users.
  (Debug-signed artifacts attached to an alpha/beta/rc pre-release are signed
  with the Android **debug** key and are for testing only — never for F-Droid or
  any store.)
- **Reproducible builds (optional, advanced).** F-Droid supports verifying that
  a developer-signed binary matches what it builds from source, but that
  requires a reproducible build setup and is explicitly out of scope here.
- **Never ship debug-signed artifacts as releases.** Debug-key builds exist
  only for previews/smoke tests. The CI workflow labels them `-debug-signed`
  precisely so they are never mistaken for a real release.

## 7. What is intentionally out of scope

- Writing production release notes automatically. For alpha/beta/rc tags the
  workflow may *create* a GitHub **pre-release** with placeholder notes and
  attach artifacts; for stable tags it only attaches to a Release you created.
  Building the artifacts on a `v*` tag *is* automated.
- Publishing to the Play Store.
- Submitting to F-Droid.
- Committing any keystore, password, or `key.properties`.

See [docs/fdroid-readiness.md](./fdroid-readiness.md) for the broader
distribution checklist.
