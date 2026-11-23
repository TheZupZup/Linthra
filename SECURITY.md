# Security policy

Thanks for taking the time to look at Linthra's security. Linthra is early alpha,
built by a small group, and reports are genuinely useful.

## Reporting a vulnerability

**Use GitHub Private Vulnerability Reporting:**
[report a vulnerability](https://github.com/TheZupZup/Linthra/security/advisories/new).

It is enabled on this repository and is the channel to prefer. The report stays
private between you and the maintainers until an advisory is published, and it
gives us a place to discuss details and share fixes before anything is public.

Please **do not** open a public issue for a suspected vulnerability, and do not
put technical details in one. A public issue asking for a private channel is
fine, but the report itself belongs in the private advisory.

If Private Vulnerability Reporting is unavailable to you for some reason, email
**support@linthra.ca**, which reaches the maintainer directly. Either channel is
fine; the advisory form is easier to coordinate a fix in.

## What to include

The more of this you can give, the faster a fix lands:

- what the issue is and what an attacker gets out of it
- affected version or commit, and platform (Android or Linux)
- steps to reproduce, ideally minimal
- any proof-of-concept, logs, or screenshots

Please redact your own secrets first: no tokens, passwords, authenticated stream
URLs, or full private server addresses. A version number and a description are
usually enough.

## What to expect

Linthra is maintained by volunteers, so these are honest intentions rather than
a contractual SLA:

- an acknowledgement within about a week
- an assessment of severity and scope after that
- a fix in a normal release for most issues, faster for anything actively
  exploitable
- credit in the advisory and release notes if you want it, or none if you prefer

We will keep you in the loop while a fix is prepared, and we would appreciate
the report staying private until the fix ships.

## Supported versions

Linthra is pre-1.0 and moves quickly. Only the **latest release** gets security
fixes. Older tags, forks, and sideloaded modified builds are out of scope.

## In scope

Anything that breaks Linthra's own promises:

- credential handling: stored server credentials, encrypted-at-rest storage, the
  GitHub sponsor OAuth device flow
- leaking secrets into logs, diagnostics, bug reports, or the backup file
  (see [docs/features/backup-restore-format.md](docs/features/backup-restore-format.md))
- authenticated stream URLs escaping where they should not
- the Flatpak sandbox: escapes, or permissions broader than the app needs
  (see [docs/audits/flatpak-filesystem.md](docs/audits/flatpak-filesystem.md))
- Android platform surfaces: exported components, SAF and filesystem access,
  intent handling
- the repository and release supply chain: workflows, signing, published
  artifacts (see [docs/audits/repository-hardening.md](docs/audits/repository-hardening.md))
- anything that contradicts [PRIVACY.md](./PRIVACY.md), including unexpected
  network traffic

## Out of scope

- vulnerabilities in your own Jellyfin, Navidrome, Subsonic, or Plex server
- issues that need an already-compromised device, a rooted attacker with
  physical access, or a modified build
- missing hardening with no demonstrated impact, and automated scanner output
  with no working reproduction
- denial of service against your own device
- the deliberate design choices in [PRIVACY.md](./PRIVACY.md) and
  [docs/roadmap.md](./docs/roadmap.md), such as Linthra having no backend and no
  account system

## Other contact

Same address, support@linthra.ca, for privacy questions that are not
vulnerabilities (also listed in [PRIVACY.md](./PRIVACY.md)). For ordinary bugs,
use [Settings → Report a bug](./docs/reporting-bugs.md) and the normal issue
templates.
