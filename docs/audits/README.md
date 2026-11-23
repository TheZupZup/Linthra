# Audits

Reviews of what Linthra does with your privacy, its licences, its sandbox
and its repository, each with the evidence behind it. Several are backed by a
script you can re-run yourself.

## Privacy

| Document | What it covers |
| --- | --- |
| [Tracker dependencies](tracker-dependencies.md) | No advertising, analytics or crash-reporting SDKs, checked against every lockfile |
| [Network destinations](network-destinations.md) | Every host name written into the code, and when it is contacted |

## Licensing

| Document | What it covers |
| --- | --- |
| [Dependency licences](dependency-licenses.md) | Every dependency's licence, for stores and redistribution |
| [License transition](license-transition.md) | The move from MPL-2.0 to AGPL-3.0-or-later |
| [Relicensing consent](relicensing-consent.md) | The public record of the permissions behind that move |

## Linux sandbox

| Document | What it covers |
| --- | --- |
| [Flatpak permissions](flatpak-permissions.md) | Every permission the Flatpak asks for, and the feature that needs it |
| [Flatpak filesystem](flatpak-filesystem.md) | Which files and folders the sandbox can reach |

## Performance and power

| Document | What it covers |
| --- | --- |
| [Battery during playback](battery-playback.md) | What runs while music plays, and its cost |
| [Bluetooth and CPU](bluetooth-and-cpu.md) | Bluetooth / LE compatibility and CPU efficiency |

## Repository security

| Document | What it covers |
| --- | --- |
| [Repository hardening](repository-hardening.md) | The two pull-request security gates and the settings behind them |
| [PR security guard](pr-security-guard.md) | What the security surface scanner flags or blocks, and why |
