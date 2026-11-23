#!/usr/bin/env python3
"""A source-pattern tripwire for the Cast security containment.

Casting is withheld from production builds while a reported security issue is
resolved (see lib/core/services/cast/cast_containment.dart and docs/features/cast.md).
This script greps four files for the markers of the three layers that hold that
in place: the `isActive` constant, the production override binding, the absence
of a live backend in the cast provider wiring, and the transport's own guards.

WHAT THIS IS NOT
----------------
This is NOT proof that casting cannot be reached, and it must not be described
as one. It is a set of regexes over four known files, so it catches the obvious
regression — someone flips the constant, drops the override, reverts the
provider, deletes a guard — and nothing subtler. It cannot see:

  * a bypass that keeps every marker in place, such as a new CastService
    implementation, a second override applied after this one, a live transport
    constructed somewhere other than cast_providers.dart, or a guard left intact
    while the code path around it moves;
  * anything in a file this script does not read, including new files;
  * a guard that is present but no longer reachable, or a constant read through
    an indirection this script does not resolve;
  * the actual runtime behaviour of any of it, since nothing here executes the
    app.

WHAT IS THE EVIDENCE
--------------------
The tests are. test/app/production_cast_containment_test.dart builds the real
production override list per platform and drives the resulting service;
test/core/services/cast/cast_containment_test.dart calls the transport directly.
Those exercise behaviour rather than text. Treat a green run of this script as
"the markers we know to look for are still there", and treat a red one as a
question that needs answering before merge.

Ambiguity fails closed: a missing file, an unreadable file, or a pattern this
script no longer recognises exits non-zero rather than reporting success. That
is a property of this script's own inputs, not a guarantee about the app.

When the reviewed restoration lands, this script is updated in the same pull
request — that edit is one of the signals a reviewer looks for.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

CONTAINMENT = Path("lib/core/services/cast/cast_containment.dart")
CONTAINER = Path("lib/app/application_container.dart")
PROVIDERS = Path("lib/features/player/cast/cast_providers.dart")
TRANSPORT = Path("lib/core/services/cast/chromecast_cast_transport.dart")

# Constructing either of these is what puts a live cast backend into the app, so
# neither may appear in the production wiring while containment holds.
LIVE_BACKEND = (
    ("DefaultCastService", re.compile(r"\bDefaultCastService\s*\(")),
    ("ChromecastCastTransport", re.compile(r"\bChromecastCastTransport\s*\(")),
)

# The transport's own fail-closed guards, one per entry point that can reach a
# receiver. Matched loosely enough to survive reformatting, strictly enough that
# deleting a guard is caught.
TRANSPORT_GUARDS = (
    ("discovery", re.compile(r"CastContainment\.isActive.*discovery", re.S)),
    ("connecting", re.compile(r"CastContainment\.isActive.*connecting", re.S)),
    ("media handoff", re.compile(r"CastContainment\.isActive.*media handoff", re.S)),
)


def read(path: Path) -> str:
    full = REPO_ROOT / path
    try:
        return full.read_text(encoding="utf-8")
    except OSError as error:
        sys.exit(f"ERROR: cannot read {path}: {error}")


def main() -> int:
    failures: list[str] = []

    containment = read(CONTAINMENT)
    if not re.search(r"static\s+const\s+bool\s+isActive\s*=\s*true\s*;", containment):
        failures.append(
            f"{CONTAINMENT}: CastContainment.isActive is not `true`. Casting may "
            "only be restored by a reviewed change that also authenticates the "
            "receiver before any media handoff."
        )

    container = read(CONTAINER)
    if "containedCastServiceOverride" not in container:
        failures.append(
            f"{CONTAINER}: the production override list no longer applies "
            "containedCastServiceOverride, so production would fall back to an "
            "unreviewed cast binding."
        )

    providers = read(PROVIDERS)
    for name, pattern in LIVE_BACKEND:
        if pattern.search(providers):
            failures.append(
                f"{PROVIDERS}: constructs {name} — production must build no live "
                "cast backend while contained."
            )

    transport = read(TRANSPORT)
    for name, pattern in TRANSPORT_GUARDS:
        if not pattern.search(transport):
            failures.append(
                f"{TRANSPORT}: the fail-closed guard for {name} is missing. The "
                "transport must refuse independently of the provider wiring."
            )

    if failures:
        print("Cast containment marker check FAILED:\n", file=sys.stderr)
        for failure in failures:
            print(f"  * {failure}\n", file=sys.stderr)
        print(
            "If this is the reviewed restoration of casting, update this script "
            "in the same pull request and say so in the description.",
            file=sys.stderr,
        )
        return 1

    print(
        "Cast containment markers present (constant, production wiring, "
        "transport guards). This is a pattern check, not proof: the runtime "
        "evidence is test/app/production_cast_containment_test.dart and "
        "test/core/services/cast/cast_containment_test.dart."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
