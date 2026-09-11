#!/usr/bin/env python3
"""flatpak_bundle.py — name and inspect Linthra's standalone `.flatpak` (#618).

`flatpak-builder --repo=repo-ci` leaves an exported OSTree repository, which is
what CI installs from. A GitHub Release cannot serve a repository, so the
release path turns that same export into a single-file bundle
(`flatpak build-bundle`) that a user downloads and installs. This script is the
part of that step which has rules worth testing:

  * `name` — the artifact's file name, derived from the release tag and the
    architecture, so the workflow never spells a version itself.
  * `verify` — what the produced bundle has to contain before it is attached to
    a Release.

WHAT `verify` CHECKS, AND WHERE THE EXPECTATIONS COME FROM
---------------------------------------------------------
Every expectation is read from `flatpak/<app-id>.yml`, the manifest that built
the bundle, rather than restated here: the application id, the runtime it must
run on, the command it starts, and every path its `install -Dm644` lines put
into `/app`. A packaging change that moves the desktop entry, drops an icon
size or renames the metainfo is therefore caught without editing this file, and
this script can never disagree with the manifest about what a bundle holds.

On top of that it asserts the things the manifest cannot say:

  * the bundle carries exactly one ref, and it is `app/<app-id>/<arch>/<branch>`
    — the identity a software centre and the launcher will use;
  * `metadata` names that same application id, the manifest's runtime, and the
    manifest's command;
  * the Dart payload (`libapp.so`) is present, so the artifact is a real build
    rather than an empty shell;
  * a `libmpv` shared library is inside the bundle (#433). The Flatpak must play
    audio with its own packaged mpv; a bundle without one would fall back to
    whatever the host happens to have, which is the dependency this packaging
    exists to remove;
  * the desktop entry and at least one icon are in `export/`, which is the half
    that makes an installed app appear in GNOME/KDE at all.

WHAT IT IS NOT
--------------
It reads a bundle's contents. It does not run the application, and finding a
`libmpv` in the bundle is not the same as proving playback uses it — that is
what the packaged-sandbox audio smoke (#446, docs/flatpak-audio-smoke.md) and
the manual checklist in docs/linux-desktop.md are for. It also says nothing
about the Cast containment; `scripts/verify_release_containment.py` reads the
same bundle for that, using this script's extractor.

Extraction shells out to `ostree` and `flatpak build-import-bundle`, so a
missing tool is an error rather than a skipped check. Nothing here installs
anything, touches a Flatpak installation, or reaches the network.

Usage:

    python3 scripts/flatpak_bundle.py name --tag v0.2.7
    python3 scripts/flatpak_bundle.py verify Linthra-v0.2.7-x86_64.flatpak \\
        --tag v0.2.7 --json flatpak-bundle.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The single manifest Linthra maintains. `verify` reads its expectations from
# here; there is deliberately no second copy of the app id or the runtime.
DEFAULT_MANIFEST = REPO_ROOT / "flatpak" / "io.github.thezupzup.linthra.yml"

# `flatpak-builder` exports to this branch unless told otherwise, and neither
# manifest sets `branch:`.
DEFAULT_BRANCH = "master"

# The same tag grammar as scripts/release_preflight.sh and the release
# workflows: vMAJOR.MINOR.PATCH with an optional -alpha.N / -beta.N / -rc.N.
TAG_PATTERN = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$")

# Flatpak's own architecture names (x86_64, aarch64, …).
ARCH_PATTERN = re.compile(r"^[A-Za-z0-9_]+$")

# The compiled Dart snapshot, the same payload verify_release_containment.py
# reads out of every other release artifact.
AOT_PAYLOAD = "libapp.so"


class BundleError(Exception):
    """A reason this script cannot report success. Always fatal."""


# --- naming ----------------------------------------------------------------


def normalised_tag(tag: str) -> str:
    """`0.2.7` or `v0.2.7` -> `v0.2.7`. Anything else is an error.

    Release assets are named after the tag, so a malformed one must fail here
    rather than become a file name nobody can predict.
    """
    candidate = tag.strip()
    if TAG_PATTERN.match(candidate) is None:
        raise BundleError(
            f"malformed release tag {tag!r}; expected vMAJOR.MINOR.PATCH with an "
            "optional -alpha.N / -beta.N / -rc.N suffix, e.g. v0.2.7."
        )
    return candidate if candidate.startswith("v") else f"v{candidate}"


def bundle_name(tag: str, arch: str) -> str:
    """The Release asset name for a bundle, e.g. `Linthra-v0.2.7-x86_64.flatpak`.

    Deliberately shaped like the Linux tarball asset
    (`Linthra-v0.2.7-linux-x64.tar.gz`): same product name, same tag spelling,
    architecture, then the extension. The architecture is Flatpak's own name
    for it, because that is what `flatpak build-bundle --arch` and the ref
    inside the bundle use.
    """
    if not ARCH_PATTERN.match(arch or ""):
        raise BundleError(f"unexpected architecture {arch!r} for a Flatpak bundle.")
    return f"Linthra-{normalised_tag(tag)}-{arch}.flatpak"


# --- the manifest is the source of truth ------------------------------------


def _manifest_scalar(text: str, key: str, where: Path) -> str:
    match = re.search(rf"^{re.escape(key)}:[ \t]*(\S+)[ \t]*$", text, re.MULTILINE)
    if match is None:
        raise BundleError(f"{where}: no top-level `{key}:` to read.")
    return match.group(1).strip("'\"")


def manifest_expectations(manifest: Path) -> dict[str, object]:
    """Everything `verify` needs, read from the manifest that built the bundle."""
    try:
        text = manifest.read_text(encoding="utf-8")
    except OSError as error:
        raise BundleError(f"cannot read {manifest}: {error}") from error

    app_id = _manifest_scalar(text, "app-id", manifest)
    runtime = _manifest_scalar(text, "runtime", manifest)
    runtime_version = _manifest_scalar(text, "runtime-version", manifest)
    command = _manifest_scalar(text, "command", manifest)

    # `install -Dm644 <source> /app/<destination>` — the desktop entry, the
    # AppStream metainfo and every icon size. `install -d` (directory creation)
    # does not match: the flag is lowercase and this pattern is case-sensitive.
    installed = re.findall(r"install\s+-D\S*\s+\S+\s+(/app/\S+)", text)
    if not installed:
        raise BundleError(
            f"{manifest}: no `install -Dm644 ... /app/...` commands, so nothing "
            "says which files the package should contain."
        )

    return {
        "app_id": app_id,
        "runtime": runtime,
        "runtime_version": runtime_version,
        "command": command,
        "installed": sorted(set(installed)),
    }


# --- reading a bundle -------------------------------------------------------


def _run(command: list[str]) -> str:
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as error:
        raise BundleError(
            f"{command[0]} is not installed; it is needed to read a .flatpak bundle."
        ) from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise BundleError(
            "{} failed ({}): {}".format(" ".join(command), error.returncode, detail)
        ) from error
    return completed.stdout


def extract_bundle(bundle: Path, destination: Path) -> str:
    """Unpack a single-file bundle into `destination`; returns its ref.

    A `.flatpak` is an OSTree static delta, so it is imported into a scratch
    archive repository and checked out. Nothing is installed and no existing
    Flatpak installation is read or modified, which is what makes this safe to
    run on a release runner and in a contributor's shell alike.

    The checkout is the app ref's own tree: `metadata`, `files/` (what the
    manifest installed into /app) and `export/` (what makes it appear in a
    desktop launcher).
    """
    if not bundle.is_file():
        raise BundleError(f"{bundle}: not a file.")

    repo = destination.parent / f"{destination.name}.ostree-repo"
    _run(["ostree", "init", f"--repo={repo}", "--mode=archive-z2"])
    _run(["flatpak", "build-import-bundle", str(repo), str(bundle)])

    refs = [line.strip() for line in _run(["ostree", f"--repo={repo}", "refs"]).split()]
    refs = [ref for ref in refs if ref]
    if len(refs) != 1:
        raise BundleError(
            f"{bundle.name}: expected exactly one ref in the bundle, found "
            f"{len(refs)}: {', '.join(refs) or 'none'}."
        )

    _run(
        [
            "ostree",
            f"--repo={repo}",
            "checkout",
            "--user-mode",
            refs[0],
            str(destination),
        ]
    )
    return refs[0]


def metadata_value(metadata: str, key: str) -> str | None:
    match = re.search(rf"^{re.escape(key)}=(.*)$", metadata, re.MULTILINE)
    return match.group(1).strip() if match else None


def tree_problems(
    tree: Path,
    ref: str,
    expectations: dict[str, object],
    *,
    arch: str,
    branch: str = DEFAULT_BRANCH,
) -> list[str]:
    """Everything wrong with an extracted bundle, as user-readable lines."""
    app_id = str(expectations["app_id"])
    problems: list[str] = []

    expected_ref = f"app/{app_id}/{arch}/{branch}"
    if ref != expected_ref:
        problems.append(f"the bundle holds {ref}, expected {expected_ref}.")

    metadata_file = tree / "metadata"
    if not metadata_file.is_file():
        problems.append("metadata is missing, so the bundle declares no identity.")
    else:
        metadata = metadata_file.read_text(encoding="utf-8", errors="replace")
        expected_runtime = "{}/{}/{}".format(
            expectations["runtime"], arch, expectations["runtime_version"]
        )
        for key, expected in (
            ("name", app_id),
            ("runtime", expected_runtime),
            ("command", str(expectations["command"])),
        ):
            actual = metadata_value(metadata, key)
            if actual != expected:
                problems.append(f"metadata {key}={actual!r}, expected {expected!r}.")

    # Everything the manifest installs into /app has to be in files/.
    for installed in expectations["installed"]:  # type: ignore[union-attr]
        relative = str(installed)[len("/app/") :]
        if not (tree / "files" / relative).exists():
            problems.append(f"files/{relative} is missing (the manifest installs it).")

    if not (tree / "files" / "bin" / str(expectations["command"])).exists():
        problems.append(
            "files/bin/{} is missing, so `flatpak run` has nothing to start.".format(
                expectations["command"]
            )
        )

    payloads = (
        sorted((tree / "files").rglob(AOT_PAYLOAD)) if (tree / "files").is_dir() else []
    )
    if not payloads:
        problems.append(
            f"no {AOT_PAYLOAD} anywhere in files/, so the bundle carries no "
            "compiled Dart."
        )

    # #433: the packaged audio runtime. Without it the app would be back to
    # depending on whatever libmpv the host has, which is exactly what the
    # Flatpak removes.
    if not list((tree / "files" / "lib").glob("libmpv.so*")):
        problems.append(
            "files/lib carries no libmpv.so*, so the bundle would depend on a "
            "host-installed libmpv."
        )

    # export/ is what a desktop actually reads after `flatpak install`.
    if not (tree / "export" / "share" / "applications" / f"{app_id}.desktop").is_file():
        problems.append(
            f"export/share/applications/{app_id}.desktop is missing, so the "
            "installed app would not appear in the launcher."
        )
    icons = tree / "export" / "share" / "icons"
    if not icons.is_dir() or not any(icons.rglob(f"{app_id}.*")):
        problems.append(
            f"export/share/icons carries no {app_id} icon, so the launcher entry "
            "would fall back to a generic icon."
        )

    return problems


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_bundle(
    bundle: Path,
    *,
    tag: str,
    arch: str,
    manifest: Path,
    branch: str = DEFAULT_BRANCH,
    extract=extract_bundle,
) -> dict[str, object]:
    """Checks one bundle and returns its record. Raises on any failure."""
    expected_name = bundle_name(tag, arch)
    if bundle.name != expected_name:
        raise BundleError(
            f"{bundle.name}: expected the bundle for {normalised_tag(tag)} on "
            f"{arch} to be named {expected_name}."
        )

    expectations = manifest_expectations(manifest)
    with tempfile.TemporaryDirectory(prefix="linthra-flatpak-bundle-") as scratch:
        tree = Path(scratch) / "tree"
        ref = extract(bundle, tree)
        problems = tree_problems(tree, ref, expectations, arch=arch, branch=branch)

    if problems:
        raise BundleError(f"{bundle.name}:\n  - " + "\n  - ".join(problems))

    return {
        "artifact": bundle.name,
        "bytes": bundle.stat().st_size,
        "sha256": sha256_of(bundle),
        "ref": ref,
        "app_id": expectations["app_id"],
    }


# --- command line -----------------------------------------------------------


def default_arch() -> str:
    """Flatpak's name for this machine's architecture."""
    return _run(["flatpak", "--default-arch"]).strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Name and inspect Linthra's standalone Flatpak bundle."
    )
    subcommands = parser.add_subparsers(dest="command", required=True)

    naming = subcommands.add_parser("name", help="print the Release asset name")
    naming.add_argument("--tag", required=True, help="release tag, e.g. v0.2.7")
    naming.add_argument("--arch", default="", help="Flatpak architecture")

    checking = subcommands.add_parser("verify", help="check a built bundle")
    checking.add_argument("bundle", type=Path)
    checking.add_argument("--tag", required=True, help="release tag, e.g. v0.2.7")
    checking.add_argument("--arch", default="", help="Flatpak architecture")
    checking.add_argument("--branch", default=DEFAULT_BRANCH)
    checking.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    checking.add_argument(
        "--json", type=Path, help="write the record (name, size, SHA-256) here"
    )

    args = parser.parse_args(argv)

    try:
        arch = args.arch or default_arch()
        if args.command == "name":
            print(bundle_name(args.tag, arch))
            return 0

        record = verify_bundle(
            args.bundle,
            tag=args.tag,
            arch=arch,
            manifest=args.manifest,
            branch=args.branch,
        )
    except BundleError as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1

    if args.json:
        args.json.write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    print(f"OK   {record['artifact']}  sha256={record['sha256']}")
    print(f"       ref: {record['ref']}")
    print(f"       bytes: {record['bytes']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
