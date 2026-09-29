# Fixed network destinations

Linthra talks to the servers you configure. Those addresses are yours, typed in
at run time, and nothing here tries to list them. This page is about the other
kind: every host name or IP address written into the code Linthra ships, and
what each one is for.

```bash
python3 scripts/check_network_destinations.py
```

No network, no Flutter, no Android SDK. Everything it reads is committed, so
the result you get is the result CI gets.

It runs on every pull request as the **Check fixed network destinations** step
of the "Secret & privacy scan" job in [`ci.yml`](../.github/workflows/ci.yml),
and `./scripts/verify_android.sh` runs it locally with the other guardrails.

This is one part of [#504](https://github.com/TheZupZup/Linthra/issues/504).
The [tracker dependency audit](./tracker-dependency-audit.md) covers the
dependency graph; this covers Linthra's own code. The overall status, including
what is not automated yet, is in [PRIVACY_AUDIT.md](../PRIVACY_AUDIT.md).

## What it shows today

Hosts Linthra's own code connects to:

| Host | When | Builds |
| --- | --- | --- |
| `plex.tv` | Only during **Connect with Plex**: create a sign-in PIN, poll it until you approve, list your servers and Plex Home users | all |
| `github.com` | Only after you tap **Connect GitHub**: GitHub's device sign-in | GitHub Sponsor APK only |
| `api.github.com` | Checks whether your GitHub account sponsors the project. After you have connected GitHub, this runs again at each launch until you disconnect | GitHub Sponsor APK only |

Hosts that are only handed to your browser or mail app when you tap a link
(Linthra never contacts them itself): `github.com` (project, releases, privacy
policy, sponsors, prefilled bug report), `app.plex.tv` (Plex's sign-in page),
`reddit.com` (community link) and `linthra.ca` (the support address the
Contact and Report a bug actions open a mail draft to).

Everything else the check finds is a **reference**: an issue link in a doc
comment, an example address in hint text, a licence header in vendored code, an
Android XML namespace. None of them is ever contacted. The full list, with a
reason for each, is
[`scripts/network_destinations.json`](../scripts/network_destinations.json).

The summary the check prints is:

```text
Contacted with no user action in any build: none
Contacted on its own only after the user opted in: api.github.com (github-sponsor build)
```

Two things are deliberately **not** in the inventory, because they are not
written in the code:

- **Your servers.** Jellyfin, Navidrome/Subsonic, Plex and Audiobookshelf
  addresses come from what you type in.
- **Plex's `*.plex.direct` and relay addresses.** plex.tv returns them during
  Connect with Plex, and Linthra saves the one that works as your server
  address.

## What it reads

The source that ends up in a shipped build:

| Root | What it is |
| --- | --- |
| `lib/` | The Dart app |
| `android/app/src/` | The Android app module: Kotlin, manifests, resources |
| `linux/runner/` | The Linux runner |
| `linux/packaging/` | The desktop entry and AppStream metadata |
| `native/` | The Rust and C++ libraries |
| `third_party/` | Vendored packages (just_audio, just_audio_media_kit, libFLAC, the Media3 FLAC decoder) |
| declared assets | Files `pubspec.yaml` lists under `flutter: assets:`, and anything under an Android source set's `assets/` or `res/raw*/`, in the app module or a vendored Android module |
| build inputs | `android/*.gradle(.kts)`, `android/app/*.gradle(.kts)`, `android/gradle.properties` and the vendored modules' `build.gradle(.kts)`: they can put values into the app (`buildConfigField`, `resValue`, manifest placeholders) |

In the source roots, only source file types are read (`.dart`, `.kt`, `.java`,
`.xml`, `.c`, `.cc`, `.cpp`, `.h`, `.hpp`, `.rs`, `.desktop`). Packaged assets
are read whatever their type (JSON, text, config), because the app can load a
URL from one at run time. Text is decoded as UTF-8, or UTF-16/32 (with or
without a byte-order mark). Known binary types like images and audio are
skipped; any other asset that isn't readable text fails the check, as does an
asset `pubspec.yaml` declares but that doesn't exist. There are no packaged
assets today. `pubspec.yaml` asset lists are read in block form (`- path`,
`- path: path`) or one-line flow form (`[a, b]`); any other shape fails the
check.

Directories that never ship are skipped by where they sit, not by name alone,
so shipped code in a `lib/build/` or `lib/test/` is still read:

- directly under a vendored or native package (`third_party/<pkg>/test`,
  `native/<pkg>/tests`): `test`, `tests`, `example`, `build`, and the Apple
  platforms (`darwin`, `ios`, `macos`);
- Android test source sets (`src/test`, `src/androidTest`) inside an Android
  module: the app module or a vendored one. A `src/test` anywhere else is read.

Other build files are out of scope on purpose. The Flatpak manifests and
CMake files describe what the build downloads, not what the app contacts, and
they are pinned by their own checks
([flatpak-source-pinning.md](./flatpak-source-pinning.md)).

Every root has to exist and contain source files. A root that moved or emptied
fails the check rather than quietly passing.

## How it matches

It looks for four shapes, never for keywords:

- **URLs**: `scheme://host` for http, https, ws, wss, ftp and ftps, plus the
  network schemes the Linux player (mpv) accepts (rtp, rtsp, rtmp, udp, tcp,
  tls, mms, srt), including `scheme://user:pass@host`. The whole host has to be a literal.
  `http://$host:4533`, `https://${server}` or `https://api.${domain}` is a
  configured address and is skipped by construction. A fixed host followed by
  an interpolated path (`https://collector.example.io$path`) is still read, and
  an IP address in a URL's path or query is data, not a second destination.
- **IP literals** outside a URL, like `InternetAddress('203.0.113.9')` or
  `TcpStream::connect("[2001:db8::1]:443")`. An IPv6 candidate has to parse as
  an address. Written as a string literal it always counts, even letter-only
  like `'dead:beef::cafe'`. Outside a string it also needs a digit, so code
  paths like `std::vector` or `a::b` don't count.
- **Mail recipients**: a `mailto:` link (its domain can be a single label, like
  `ops@metrics`) or an address written as a whole string literal
  (`'support@example.org'`). The domain is what gets reviewed; an interpolated
  domain (`ops@api.${domain}`) is skipped as configured.
- **A host passed as a bare string** to the common APIs that take one, in each
  language the scan reads. These are matched across line breaks, so a call
  formatted over several lines is still seen:
  - Dart: `Uri.https('host', ...)`, `host: '...'`, `Socket.connect('host', ...)`
    and other `.connect(...)` calls, `InternetAddress.lookup('host')`, and
    `HttpClient`'s host-and-port methods (`get('host', port, path)` and the
    other verbs, with a literal or computed path, and
    `open('GET', 'host', port, path)`)
  - Kotlin/Java: `InetAddress.getByName("host")`, `getAllByName`,
    `InetSocketAddress("host", ...)`, `Socket("host", ...)`, `SSLSocket(...)`
  - C/C++: `getaddrinfo("host", ...)`, `gethostbyname("host")`
  - Rust: `TcpStream::connect("host:443")` and other `::connect(...)` calls,
    `"host:443".to_socket_addrs()`
  - Android XML: a network security config `<domain>`, a manifest
    `android:host`, and a string resource whose whole value is a host name

Host names may contain underscores (`api_v2.internal`): they aren't valid DNS
names, but private resolvers answer for them.

Reserved names are recognised and never need an entry: names under the example
domains (`music.example.com`, `plex.example.org`), the
`.test`, `.example`, `.invalid` and `.localhost` top-level domains, `localhost`,
loopback, and the documentation address ranges (`192.0.2.0/24`,
`198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`).

Three things are deliberately **not** reserved:

- **The example domains themselves.** `example.com`, `example.net` and
  `example.org` resolve and accept connections, so `https://example.com/collect`
  needs an entry. Only names under them are reserved.
- **A private LAN address.** A hard-coded `192.168.1.1` could be a real
  destination on somebody's network, so it gets reviewed like anything else.
  That is why the two example LAN addresses in hint text and comments have
  entries.
- **A dotless name.** `https://metrics/upload` can resolve through a search
  domain, so `metrics` is a destination, not a placeholder. That is why the
  `http://host:4533/rest` example in a Subsonic doc comment has an entry. (A
  bare word in a `host:` named argument or a `lookup(...)` call is the
  exception: those shapes are too common outside networking code to read as a
  destination.)

Every entry lists the files allowed to mention its host. That is the part that
makes the check useful for review: `github.com` is fine as a browser link on the
About screen, but the same host showing up in a sync client is a new
destination, and it fails until someone looks.

The check also fails when an entry, or one of its paths, no longer matches
anything. A reason can't outlive what it explains.

## Limits

Read this before quoting the check anywhere.

**It does not prove Linthra cannot contact anything else.** It lists hosts that
are written down in source. Specifically, it:

- **only knows the APIs listed above.** A host handed to some other networking
  call as a bare string, without a scheme, is not seen. Raw and triple-quoted
  string literals (`r'host'`, `r#"host"#`, `R"(host)"`, `'''host'''`,
  `"""host"""`) are handled for those APIs.
- **doesn't see values passed at build time.** A value given to
  `flutter build --dart-define` lives in the workflow, not the source. None of
  Linthra's dart-defines carries a host today; a new one that does would need
  a reviewer to spot it.
- **can't see a host built at run time.** A host assembled from pieces, decoded
  from base64, read from a file or returned by a server (like Plex's
  `*.plex.direct` addresses) is invisible to it.
- **doesn't read pub packages that aren't vendored.** A dependency that
  contacts a fixed host of its own is not in this repository's source. The
  [tracker dependency audit](./tracker-dependency-audit.md) covers known
  tracking SDKs by name. Scanning the compiled app for host strings is a
  separate, later part of #504.
- **doesn't know what code does.** A path scope stops a reviewed host from
  quietly spreading to new files, but inside a reviewed file it can't tell a
  comment from a request. A new network call in a file that already mentions
  the host passes this check. The
  [PR security guard](./pr-security-guard.md) separately flags new
  network-capable code for review.
- **doesn't observe traffic.** What the app actually does on the network is the
  runtime part of #504, which is not automated yet.

## Reviewing a failure

A failure means a person has to decide. It doesn't mean somebody did something
wrong: most of the time it will be a doc link or an example.

```text
FAIL: collect.example-analytics.io is not in the reviewed inventory.
      lib/core/services/usage_reporter.dart:14  (https URL)
```

1. **Look at the line.** Is Linthra going to connect to this host, open it in
   the browser, or just mention it?
2. **If it is an example**, prefer a reserved name (`music.example.com`,
   `192.0.2.10`). Those never need an entry.
3. **If it is real**, add an entry to
   [`scripts/network_destinations.json`](../scripts/network_destinations.json):

   ```json
   {
     "host": "plex.tv",
     "kind": "app-request",
     "trigger": "user-action",
     "builds": "all",
     "paths": [
       "lib/core/sources/plex/plex_tv_endpoints.dart"
     ],
     "rationale": "What it is, when it is contacted, and what is sent."
   }
   ```

   - `kind` is `app-request` (Linthra's code connects to it), `browser-link`
     (handed to the browser or mail client) or `reference` (never contacted).
   - `trigger` is only for `app-request`: `user-action` (only after the user
     starts something), `automatic-after-opt-in` (runs on its own once the user
     has opted in) or `automatic` (no user action at all).
   - `builds` is `all` or `github-sponsor`.
   - `paths` are files or globs (`**` crosses directories, `*` does not).
     Prefer exact files.

4. **If it is an `app-request`, update [`PRIVACY.md`](../PRIVACY.md) in the same
   pull request.** A test fails when an `app-request` host is not mentioned
   there. An `automatic` trigger fails another test, because PRIVACY.md says
   nothing is contacted without a user action. If that ever genuinely has to
   change, the policy text changes with it.

Entries are sorted by `(host, kind)` and paths are sorted within an entry. The
loader enforces both, so review diffs stay readable. Then run the tests:

```bash
python3 test/tooling/check_network_destinations_test.py
ruff check scripts tool tools && ruff format --check scripts tool tools
```

## Machine-readable output

`--json` prints the same report with fixed key order, including the files each
entry was found in. It's meant for the release privacy report that comes later
in #504:

```bash
python3 scripts/check_network_destinations.py --json
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every host literal in shipped source is reviewed, in a reviewed file |
| `1` | A new host, a host outside its reviewed files, or an entry or path that matches nothing |
| `2` | The check could not run: a root is missing or empty, a file is not UTF-8, or the inventory is unreadable |

## See also

- [PRIVACY_AUDIT.md](../PRIVACY_AUDIT.md): every privacy check, what is still
  checked by hand, and the limits
- [PRIVACY.md](../PRIVACY.md): the policy this backs up
- [tracker-dependency-audit.md](./tracker-dependency-audit.md): the dependency
  side of the same question
- [pr-security-guard.md](./pr-security-guard.md): owner review for new
  network-capable code
