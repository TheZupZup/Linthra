# F-Droid arm64-v8a / x86_64 reproducibility (and the F-Droid-signed fallback)

## Symptom

F-Droid's reproducible-build verification fails for the **64-bit** per-ABI
APKs while **armeabi-v7a** passes. The job log shows, for arm64-v8a:

```
…NOT verified - …/sigcp_io.github.thezupzup.linthra_<code>2.apk
ERROR: Could not build app io.github.thezupzup.linthra:
       compared built binary to supplied reference binary but failed
signature copying failed: APK Signing Block offset < central directory offset
```

This was first raised on the auto-update MR for v0.1.2 (versionCode 1029993)
and reproduces identically on v0.1.5 (the linked job 14938363064 actually
builds 1059991/1059992/1059993). **It is not version-specific and there is no
"clean" release to jump to — every release with the per-ABI `binary:` setup is
affected the same way.**

## Root cause (proven, not a bad artifact)

F-Droid's rebuilt arm64-v8a APK is *not byte-identical* to our uploaded
reference APK, so `apksigcopier` cannot transplant our signature onto it
(that's exactly what the error above means — see
[apksigcopier#89](https://github.com/obfusk/apksigcopier/issues/89)).

Diffing F-Droid's rebuild against our release asset entry-by-entry:

| Entry | Reference (GitHub) vs F-Droid rebuild |
| --- | --- |
| `resources.arsc` | **identical** |
| `classes.dex` | **identical** |
| every `lib/arm64-v8a/*.so` | **identical** |
| `assets/**` | **identical** |
| **`AndroidManifest.xml`** | **differs (same size, different bytes)** |
| `META-INF/MANIFEST.MF`, `CERT.SF`, `CERT.RSA` | differ — but only because they embed the manifest digest + signature |

Inside `AndroidManifest.xml` the **string pools are identical**. The only bytes
that differ are the **source line-number metadata** on each XML tag. Our
release runner emits the 64-bit split manifests with one extra source line
before `<application>`; F-Droid's clean build produces the 32-bit numbering for
every ABI:

| | armeabi-v7a | arm64-v8a | x86_64 |
| --- | --- | --- | --- |
| v0.1.2 last manifest line | 236 | **237** | **237** |
| v0.1.5 last manifest line | 265 | **266** | **266** |
| F-Droid rebuild (any ABI) | 265 | **265** | 265 |

The toolchains are otherwise **identical** on both sides — AGP `8.2.1`
(read from each APK's `app-metadata.properties`), Flutter `3.27.4`, the same
aapt2 (proven by the identical `resources.arsc`), the same NDK (proven by the
identical `.so` files). So **pinning tool versions changes nothing.**

The one behavioural difference is *how the build is invoked*. The F-Droid MR
([!40071](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/40071)) builds
each versionCode **on its own**:

* **F-Droid** builds each ABI alone, in a fresh checkout, with a single
  `flutter build apk --release --split-per-abi --target-platform=android-<arch>`
  (`android-arm` / `android-arm64` / `android-x64`).
* **Our release CI** built **all three ABIs together** in one
  `flutter build apk --release --split-per-abi` pass (after a universal build in
  the same workspace).

Building all ABIs in one pass gives the 64-bit (arm64-v8a / x86_64) split
manifests one extra `AndroidManifest.xml` source line versus F-Droid's
single-ABI build (last manifest line **266 vs 265**); armeabi-v7a lands on the
same number either way, which is why it reproduces. Proof: F-Droid's own arm64
rebuild — built with `--target-platform=android-arm64` — has manifest line
**265**, identical to what a single-target build on our side produces. The apps
are functionally byte-identical; the difference is cosmetic line metadata only.

Classification: **build/Gradle reproducibility issue** — *not* a bad/corrupt
APK, *not* bad metadata, *not* a wrong versionCode, *not* a signing-key problem.

## Primary fix (keep reproducible + upstream signature)

Build each per-ABI reference APK the **same way F-Droid builds it** — one ABI at
a time, in its own clean tree, with the matching `--target-platform`:

```
flutter build apk --release --split-per-abi --target-platform=android-arm     # armeabi-v7a
flutter build apk --release --split-per-abi --target-platform=android-arm64   # arm64-v8a
flutter build apk --release --split-per-abi --target-platform=android-x64     # x86_64
```

Implemented in `.github/workflows/android-release-build.yml`
("Build per-ABI release APKs (isolated, matching F-Droid)"). This is a stronger
fix than just cleaning before a single multi-ABI pass, because the trigger is
the multi-ABI pass itself, not merely a warm workspace.

**This must be validated on a release candidate before relying on it.** It is a
strong, mechanism-backed hypothesis, but reproducibility is only proven once an
`fdroid build` is green:

```bash
# In a fdroiddata checkout, after cutting the next release (e.g. v0.1.6):
fdroid build io.github.thezupzup.linthra:1069991   # armeabi-v7a
fdroid build io.github.thezupzup.linthra:1069992   # arm64-v8a  <- the one to watch
fdroid build io.github.thezupzup.linthra:1069993   # x86_64
```

Only merge/advance the fdroiddata MR once **all three** report
`…successfully verified`.

## Fallback (guaranteed): let F-Droid build *and sign* the per-ABI APKs

If the clean-build change does not make the 64-bit splits reproducible, stop
chasing cross-environment byte-identity and let F-Droid sign. The from-source
build already **succeeds** for every ABI (the failure is only the signature
*comparison*), so this always works.

Apply this to **`metadata/io.github.thezupzup.linthra.yml` in fdroiddata**
(do not change it blindly — propose it to the maintainer; this is the standard
F-Droid remedy when a build can't be byte-reproduced):

1. **Remove** the top-level upstream-signing pin:

   ```diff
   - AllowedAPKSigningKeys: 835189ae30df4d23588580e0a86e5e9b67ea2a2745fda510759f22a3d0a78b6c
   ```

2. **Remove the `binary:` line from every Build entry** (the per-ABI reference
   URLs). Keep everything else (`output:`, `versionCode`, `VercodeOperation`,
   the per-ABI split) unchanged — F-Droid still builds one APK per ABI, it just
   signs them with the F-Droid key:

   ```diff
   -    binary: https://github.com/TheZupZup/Linthra/releases/download/v%v/linthra-v%v-armeabi-v7a-release-signed.apk
   ```
   ```diff
   -    binary: https://github.com/TheZupZup/Linthra/releases/download/v%v/linthra-v%v-arm64-v8a-release-signed.apk
   ```
   ```diff
   -    binary: https://github.com/TheZupZup/Linthra/releases/download/v%v/linthra-v%v-x86_64-release-signed.apk
   ```

**Trade-off:** F-Droid then distributes **F-Droid-signed** APKs, whose
signature differs from the GitHub Release / direct-sideload APKs. Users cannot
cross-update between an F-Droid install and a GitHub-downloaded install without
uninstalling first, and the "Reproducible" status is dropped. Functionally the
app is identical.

## Why "just skip v0.1.2" does not work

The maintainer asked "armv7 is fine, but not armv8?" and skipping the affected
version was floated. It does not help: v0.1.5 (the latest release) fails the
same way, x86_64 is affected as well as arm64-v8a, and the cause is systemic to
the per-ABI reproducible-build setup — not a stale or corrupt v0.1.2 artifact.
