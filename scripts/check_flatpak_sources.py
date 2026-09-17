#!/usr/bin/env python3
"""Hold every external Flatpak build input to an immutable pin (#443).

`flatpak-builder` fetches sources before it enters the sandbox, and a build is
only reproducible if each of those fetches can resolve to exactly one set of
bytes forever. This check reads the committed manifests and refuses anything
that resolves at download time instead: an archive with no digest, a `git`
source with only a tag, a branch or `latest` URL, a plain-HTTP URL, a source
type that carries no content pin at all.

It is deliberately the *static* half of the Flatpak source guarantees, and it
is not the only half. `test/tooling/flatpak_offline_build_test.dart` (#442)
proves the complementary property (that every declared source lands where the
offline build actually reads it) and covers the generated files in depth. The
two overlap on "a remote source carries its own digest", on purpose: that is
the rule whose silent loss would cost the most, and this copy runs offline,
with no Flutter toolchain, which is what lets `regenerate_flatpak_sources.sh`
check its own output the moment it is produced.

What only this check covers:

1. **The hand-authored template.** `flatpak/flatpak-flutter.yml` is where a
   human adds or bumps a native module, so it is where a floating source gets
   introduced. Auditing only the generated manifest would catch it one
   regeneration later, if at all.

2. **Template and generated manifest agree.** Every module the generator does
   not rewrite has to be source-for-source identical in both files. Otherwise
   a bumped archive in the template (or a hand-edit of the generated manifest,
   which is not allowed but is possible) builds something other than what the
   committed source of truth says.

3. **The Flutter pin is one number.** `.flutter-version`, the template's
   `flutter.git` tag, the generated SDK module's tag and commit, and that
   module's filename all have to say the same thing. Nothing else tied the
   Flatpak's Flutter to the pin the rest of the project builds with, so an
   SDK bump could leave the package on the old toolchain.

4. **The engine artifacts belong to one engine.** Every Flutter engine
   artifact URL in the generated module carries the engine hash in its path;
   more than one distinct hash means a half-regenerated module.

5. **The derived native pins still match the lockfile.** flatpak-flutter picks
   its per-plugin fixes by "highest entry not newer than the locked version",
   so a plugin bump silently reuses the previous version's pins. The committed
   patch names the version it was written for, so that drift is visible here.

6. **What cannot be pinned is written down.** The runtime, the SDK, the SDK
   extension and the app's own checkout are not content-addressed, and cannot
   be; each needs a row in docs/flatpak-source-pinning.md, and a row cannot
   outlive the input it explains.

Usage:
    python3 scripts/check_flatpak_sources.py
    python3 scripts/check_flatpak_sources.py --root /path/to/checkout

Read-only, no network, no Flatpak. Local twin of the CI step of the same name.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterator

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

#: The hand-authored input, and the manifest flatpak-builder consumes.
TEMPLATE = Path("flatpak/flatpak-flutter.yml")
MANIFEST = Path("flatpak/io.github.thezupzup.linthra.yml")
#: Where an input that cannot be pinned has to be explained.
PIN_DOC = Path("docs/flatpak-source-pinning.md")
#: The project-wide Flutter pin, and the Dart dependency set.
FLUTTER_PIN = Path(".flutter-version")
LOCKFILE = Path("pubspec.lock")
#: The generator, which carries its own pin for the tool that writes the pins.
GENERATOR = Path("scripts/regenerate_flatpak_sources.sh")

#: The module the generator rewrites: its Flutter `git` source becomes a
#: generated module and its build commands become the offline ones. Every
#: other module has to survive generation untouched.
APP_MODULE = "linthra"

#: pub's cache layout inside the build, as `flutter pub get --offline` reads it.
PUB_HOSTED = ".pub-cache/hosted/pub.dev"
PUB_HASHES = ".pub-cache/hosted-hashes/pub.dev"
PUB_ARCHIVE = "https://pub.dev/api/archives/{}-{}.tar.gz"

#: The heading above the table of inputs that cannot be pinned.
EXCEPTIONS_HEADING = "Inputs that cannot be pinned"

#: Source types that fetch bytes from somewhere else, and therefore need a pin.
REMOTE_TYPES = frozenset({"archive", "file", "git", "svn", "bzr", "extra-data"})
#: Source types that read something already committed to this repository.
LOCAL_TYPES = frozenset({"dir", "file", "patch", "inline", "script", "shell"})

#: Types refused outright, with the reason. `svn`/`bzr` have no content
#: address at all in a flatpak-builder source, and `extra-data` is fetched on
#: the *user's* machine at install time, which is the opposite of a build input
#: this repository can pin.
REFUSED_TYPES = {
    "svn": "an svn source has no content address; mirror the tree as a hashed archive",
    "bzr": "a bzr source has no content address; mirror the tree as a hashed archive",
    "extra-data": (
        "extra-data is downloaded on the user's machine at install time, so the "
        "build cannot vouch for it"
    ),
}

#: A full Git object name, SHA-1 or SHA-256. An abbreviation is not a pin: it
#: is a prefix search, and prefixes can collide or become ambiguous.
GIT_COMMIT = re.compile(r"^([0-9a-f]{40}|[0-9a-f]{64})$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SHA512 = re.compile(r"^[0-9a-f]{128}$")
#: The engine hash in a storage.googleapis.com artifact path.
ENGINE_URL = re.compile(
    r"^https://storage\.googleapis\.com/flutter_infra_release/flutter/"
    r"(?P<hash>[0-9a-f]{40})/"
)
#: `TOOL_COMMIT="<sha>"` in the generator.
TOOL_COMMIT = re.compile(r'^TOOL_COMMIT="([^"]*)"', re.MULTILINE)
#: `<name>-<version>` as pub spells a cache directory, and as the committed
#: per-plugin patches are named.
PUB_DIRECTORY = re.compile(r"^(?P<name>[a-z0-9_]+)-(?P<version>[0-9][^/]*)$")
PATCH_VERSION = re.compile(r"^(?P<version>[0-9][0-9A-Za-z.+-]*?)-[^/]*\.patch$")

#: URL shapes that resolve to different bytes depending on when they are
#: fetched. A digest alongside one of these is not a pin, it is a tripwire that
#: turns the next upstream push into a failed build, and when the source type
#: takes no digest, it is not even that.
FLOATING_URL = (
    (
        re.compile(r"(^|[/=])HEAD([/?&.]|$)"),
        "HEAD is whatever the default branch is today",
    ),
    (re.compile(r"refs/heads/"), "a branch ref moves with every push"),
    (
        re.compile(r"(?i)/(latest|current|nightly|edge|snapshot)([/?&.]|$)"),
        "this path resolves at download time",
    ),
    (
        re.compile(r"(?i)[?&](branch|ref|rev|version)="),
        "a branch/ref query is not a fixed revision",
    ),
    (
        re.compile(r"(?i)/(master|main|trunk|tip)([/.]|$)"),
        "a default-branch snapshot moves",
    ),
)


class ManifestError(ValueError):
    """A manifest could not be read the way this check needs to read it."""


def load(path: Path) -> Any:
    """One manifest, module or source file, as data.

    Fails rather than guessing: a file this check cannot parse has to stop the
    run, because "nothing was audited" must never look like "nothing was
    wrong".
    """
    text = path.read_text(encoding="utf-8")
    try:
        if path.suffix == ".json":
            return json.loads(text)
        return yaml.safe_load(text)
    except (json.JSONDecodeError, yaml.YAMLError) as error:
        raise ManifestError("{} cannot be parsed: {}".format(path, error)) from error


def iter_sources(root: Path, manifest: Path) -> Iterator[tuple[str, Path, dict]]:
    """Every source `flatpak-builder` would fetch for [manifest].

    Yields `(where, base, source)`: a label for messages, the directory the
    source's relative paths resolve against, and the source itself.

    The base directory matters and is not uniform. flatpak-builder resolves a
    module's relative source paths against the directory of the file that
    declared *that module*, so a module pulled in from
    `generated/modules/x.json` resolves `../patches/...` inside its own
    directory, while a `sources:` file included into an inline module is
    spliced into that module's list and keeps the top manifest's directory.
    Getting this wrong would make the "the file exists" check meaningless.
    """

    def walk(module: Any, base: Path, label: str) -> Iterator[tuple[str, Path, dict]]:
        if isinstance(module, str):
            included = (base / module).resolve()
            yield from walk(load(included), included.parent, _rel(root, included))
            return
        if not isinstance(module, dict):
            raise ManifestError(
                "{}: a module must be a mapping or a file path".format(label)
            )

        name = module.get("name")
        where = "{} ({})".format(label, name) if name else label

        for source in module.get("sources", []) or []:
            if isinstance(source, str):
                included = (base / source).resolve()
                data = load(included)
                if not isinstance(data, list):
                    raise ManifestError(
                        "{}: an included sources file must hold a list".format(
                            _rel(root, included)
                        )
                    )
                for entry in data:
                    if not isinstance(entry, dict):
                        raise ManifestError(
                            "{}: a source must be a mapping".format(
                                _rel(root, included)
                            )
                        )
                    # Spliced into this module, so the base directory is this
                    # module's, not the included file's.
                    yield (_rel(root, included), base, entry)
                continue
            if not isinstance(source, dict):
                raise ManifestError(
                    "{}: a source must be a mapping or a file path".format(where)
                )
            yield (where, base, source)

        for child in module.get("modules", []) or []:
            yield from walk(child, base, label)

    data = load(root / manifest)
    if not isinstance(data, dict):
        raise ManifestError("{} is not a manifest".format(manifest))
    base = (root / manifest).parent
    label = manifest.as_posix()
    for module in data.get("modules", []) or []:
        yield from walk(module, base, label)


def _rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def check_source(root: Path, where: str, base: Path, source: dict) -> list[str]:
    """Problems with one source, as messages."""
    problems: list[str] = []
    kind = source.get("type")
    if not isinstance(kind, str):
        return ["{}: a source with no type cannot be audited: {}".format(where, source)]
    if kind in REFUSED_TYPES:
        return [
            "{}: source type {} is refused: {}.".format(
                where, kind, REFUSED_TYPES[kind]
            )
        ]
    if kind not in REMOTE_TYPES | LOCAL_TYPES:
        return [
            "{}: unknown source type {}. Teach this check what pins it before "
            "using it.".format(where, kind)
        ]

    url = source.get("url")
    if url is not None and not isinstance(url, str):
        return ["{}: url must be a string, got {!r}".format(where, url)]

    if url is None:
        # A local source. Its content is pinned by the commit being built, so
        # all that is left to check is that it really is local, and present.
        if kind not in LOCAL_TYPES:
            return ["{}: {} source without a url".format(where, kind)]
        for key in ("path", "paths"):
            declared = source.get(key)
            if declared is None:
                continue
            for entry in [declared] if isinstance(declared, str) else declared:
                problems.extend(check_local_path(root, where, base, str(entry)))
        return problems

    if not url.startswith("https://"):
        problems.append(
            "{}: {} is not https, so the bytes are not authenticated in "
            "transit.".format(where, url)
        )
    for pattern, why in FLOATING_URL:
        if pattern.search(url):
            problems.append(
                "{}: {} is a floating reference: {}.".format(where, url, why)
            )

    if kind == "git":
        commit = source.get("commit")
        if not isinstance(commit, str) or not GIT_COMMIT.match(commit):
            problems.append(
                "{}: git source {} is not pinned to a full commit (got {!r}). A "
                "tag can be repointed upstream.".format(where, url, commit)
            )
        if "branch" in source:
            problems.append(
                "{}: git source {} tracks branch {!r}. A branch is not a "
                "revision.".format(where, url, source["branch"])
            )
        return problems

    digest = source.get("sha256")
    if isinstance(digest, str) and SHA256.match(digest):
        return problems
    alternative = source.get("sha512")
    if isinstance(alternative, str) and SHA512.match(alternative):
        return problems
    weak = [name for name in ("md5", "sha1") if name in source]
    if weak:
        problems.append(
            "{}: {} is pinned with {} only. A collision-prone digest is not an "
            "audit trail; use sha256.".format(where, url, "/".join(weak))
        )
    else:
        problems.append(
            "{}: {} {} has no sha256, so flatpak-builder would accept whatever "
            "it downloads.".format(where, kind, url)
        )
    return problems


def check_local_path(root: Path, where: str, base: Path, declared: str) -> list[str]:
    """Problems with a source that reads a path in this repository."""
    if declared.startswith("/"):
        return [
            "{}: {} is an absolute host path. Nothing outside the checkout is "
            "reproducible.".format(where, declared)
        ]
    resolved = (base / declared).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return [
            "{}: {} resolves outside the repository ({}).".format(
                where, declared, resolved
            )
        ]
    if not resolved.exists():
        return [
            "{}: {} does not exist ({}).".format(where, declared, _rel(root, resolved))
        ]
    return []


def modules_by_name(manifest: Any, label: str) -> dict[str, dict]:
    """The top-level modules of a manifest, keyed by name."""
    if not isinstance(manifest, dict):
        raise ManifestError("{} is not a manifest".format(label))
    result: dict[str, dict] = {}
    for module in manifest.get("modules", []) or []:
        if not isinstance(module, dict) or "name" not in module:
            raise ManifestError(
                "{}: every top-level module needs a name for the two manifests "
                "to be comparable".format(label)
            )
        result[str(module["name"])] = module
    return result


def check_manifests_agree(root: Path) -> list[str]:
    """Problems with what generation changed between template and manifest.

    The template is the source of truth for the native chain; generation is
    only allowed to touch the app module. Anything else that differs means one
    of the two files was edited on its own.
    """
    problems: list[str] = []
    template = load(root / TEMPLATE)
    manifest = load(root / MANIFEST)

    # finish-args is in here for completeness rather than as the main guard:
    # scripts/check_flatpak_permissions.py holds both manifests' grants to the
    # rationale table, which already keeps them equal. Comparing them here as
    # well means a regeneration that dropped or reordered one is reported next
    # to the module it came with.
    for key in (
        "app-id",
        "runtime",
        "runtime-version",
        "sdk",
        "sdk-extensions",
        "command",
        "finish-args",
    ):
        if template.get(key) != manifest.get(key):
            problems.append(
                "{} and {} disagree about {}: {!r} vs {!r}. Regenerate rather "
                "than editing either by hand.".format(
                    TEMPLATE.name,
                    MANIFEST.name,
                    key,
                    template.get(key),
                    manifest.get(key),
                )
            )

    version = manifest.get("runtime-version")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9][0-9.]*", version):
        problems.append(
            "{}: runtime-version {!r} is not a released branch number. A named "
            "channel moves under the build.".format(MANIFEST.name, version)
        )

    left = modules_by_name(template, TEMPLATE.name)
    right = modules_by_name(manifest, MANIFEST.name)
    if list(left) != list(right):
        problems.append(
            "{} builds {} and {} builds {}. The generator does not add or "
            "reorder modules, so these have drifted.".format(
                TEMPLATE.name, list(left), MANIFEST.name, list(right)
            )
        )
        return problems

    for name in left:
        if name == APP_MODULE:
            continue
        if left[name] != right[name]:
            problems.append(
                "module {} differs between {} and {}. The committed manifest no "
                "longer matches the source of truth. Rerun "
                "scripts/regenerate_flatpak_sources.sh.".format(
                    name, TEMPLATE.name, MANIFEST.name
                )
            )

    # The app module is rewritten, but only in known ways: its non-Flutter
    # sources are carried over verbatim.
    def carried(module: dict) -> list[dict]:
        return [
            source
            for source in module.get("sources", []) or []
            if isinstance(source, dict) and source.get("type") != "git"
        ]

    if APP_MODULE in left and carried(left[APP_MODULE]) != carried(right[APP_MODULE]):
        problems.append(
            "the {} module's own sources differ between {} and {}.".format(
                APP_MODULE, TEMPLATE.name, MANIFEST.name
            )
        )
    return problems


def flutter_git_source(module: dict) -> dict | None:
    for source in module.get("sources", []) or []:
        if isinstance(source, dict) and source.get("type") == "git":
            if "flutter/flutter" in str(source.get("url", "")):
                return source
    return None


def check_flutter_pin(root: Path) -> list[str]:
    """Problems with the one Flutter version the package must build with."""
    problems: list[str] = []
    pinned = (root / FLUTTER_PIN).read_text(encoding="utf-8").strip()

    template = modules_by_name(load(root / TEMPLATE), TEMPLATE.name)
    app = template.get(APP_MODULE)
    if app is None:
        return [
            "{}: no {} module to read the Flutter source from".format(
                TEMPLATE.name, APP_MODULE
            )
        ]

    declared = flutter_git_source(app)
    if declared is None:
        return [
            "{}: the {} module declares no flutter/flutter git source, so "
            "nothing ties the package to {}.".format(
                TEMPLATE.name, APP_MODULE, FLUTTER_PIN.name
            )
        ]
    if str(declared.get("tag")) != pinned:
        problems.append(
            "{}: the Flutter source is tagged {!r} but {} says {!r}.".format(
                TEMPLATE.name, declared.get("tag"), FLUTTER_PIN.name, pinned
            )
        )

    modules = [
        path
        for path in sorted((root / "flatpak" / "generated" / "modules").glob("*.json"))
        if path.name.startswith("flutter-sdk-")
    ]
    if len(modules) != 1:
        return problems + [
            "expected exactly one generated flutter-sdk module, found {}.".format(
                [path.name for path in modules]
            )
        ]
    sdk_path = modules[0]
    if sdk_path.name != "flutter-sdk-{}.json".format(pinned):
        problems.append(
            "{} is named for a different Flutter than {} ({}). The module "
            "filename is part of the pin: the manifest includes it by "
            "name.".format(sdk_path.name, FLUTTER_PIN.name, pinned)
        )

    sdk = load(sdk_path)
    generated = flutter_git_source(sdk)
    if generated is None:
        return problems + [
            "{}: no flutter/flutter git source in the generated SDK module".format(
                sdk_path.name
            )
        ]
    if str(generated.get("tag")) != pinned:
        problems.append(
            "{}: the generated SDK checks out tag {!r}, not {} ({!r}).".format(
                sdk_path.name, generated.get("tag"), FLUTTER_PIN.name, pinned
            )
        )
    if declared.get("commit") != generated.get("commit"):
        problems.append(
            "{} pins Flutter commit {!r} but {} resolved {!r}. One of the two "
            "was edited without the other; rerun "
            "scripts/regenerate_flatpak_sources.sh.".format(
                TEMPLATE.name,
                declared.get("commit"),
                sdk_path.name,
                generated.get("commit"),
            )
        )

    engines = set()
    for source in sdk.get("sources", []) or []:
        if not isinstance(source, dict):
            continue
        match = ENGINE_URL.match(str(source.get("url", "")))
        if match:
            engines.add(match.group("hash"))
    if len(engines) > 1:
        problems.append(
            "{} mixes Flutter engine artifacts from {} different engines "
            "({}). A half-regenerated module builds against a toolchain no "
            "release ever shipped.".format(sdk_path.name, len(engines), sorted(engines))
        )
    elif not engines:
        problems.append(
            "{} declares no Flutter engine artifact, so the build would fetch "
            "the engine itself.".format(sdk_path.name)
        )
    return problems


def hosted_packages(root: Path) -> dict[str, tuple[str, str]]:
    """Every hosted package in the lockfile: name -> (version, sha256)."""
    lock = load(root / LOCKFILE)
    if not isinstance(lock, dict) or "packages" not in lock:
        raise ManifestError("{} has no packages section".format(LOCKFILE))
    result: dict[str, tuple[str, str]] = {}
    for name, info in (lock["packages"] or {}).items():
        if not isinstance(info, dict) or info.get("source") != "hosted":
            continue
        description = info.get("description") or {}
        result[str(name)] = (str(info.get("version")), str(description.get("sha256")))
    if not result:
        raise ManifestError("{} lists no hosted packages".format(LOCKFILE))
    return result


def check_dart_pins(root: Path, sources: list[tuple[str, Path, dict]]) -> list[str]:
    """Problems with the generated Dart pins against the committed lockfile.

    The lockfile is what the F-Droid and Linux builds resolve from, so it is
    the source of truth here too: the Flatpak's pub cache has to be the same
    set of packages, at the same versions, with the same digests.
    """
    problems: list[str] = []
    archives: dict[str, dict] = {}
    for _where, _base, source in sources:
        if source.get("type") != "archive":
            continue
        url = str(source.get("url", ""))
        if not url.startswith("https://pub.dev/api/archives/"):
            continue
        dest = str(source.get("dest", ""))
        basename = dest.rsplit("/", 1)[-1]
        if not dest.startswith(PUB_HOSTED + "/"):
            problems.append(
                "{} is staged at {!r}, not under {}, so pub cannot resolve it "
                "offline.".format(url, dest, PUB_HOSTED)
            )
            continue
        expected = url.rsplit("/", 1)[-1].removesuffix(".tar.gz")
        if basename != expected:
            problems.append(
                "{} is staged as {!r}. The cache directory name is what pub "
                "reads as the package version.".format(url, basename)
            )
        archives[basename] = source

    hashes = {
        str(source.get("dest-filename")): str(source.get("contents", "")).strip()
        for _where, _base, source in sources
        if source.get("type") == "inline" and str(source.get("dest", "")) == PUB_HASHES
    }

    for name, (version, digest) in sorted(hosted_packages(root).items()):
        basename = "{}-{}".format(name, version)
        source = archives.get(basename)
        if source is None:
            problems.append(
                "{} is in {} but has no generated pub.dev source. Rerun "
                "scripts/regenerate_flatpak_sources.sh.".format(basename, LOCKFILE.name)
            )
            continue
        if str(source.get("url")) != PUB_ARCHIVE.format(name, version):
            problems.append(
                "{} is fetched from {!r} rather than its own pub.dev archive.".format(
                    basename, source.get("url")
                )
            )
        if str(source.get("sha256")) != digest:
            problems.append(
                "{}: the generated sha256 {!r} is not the one {} resolved "
                "({!r}).".format(basename, source.get("sha256"), LOCKFILE.name, digest)
            )
        staged = hashes.get("{}.sha256".format(basename))
        if staged != digest:
            problems.append(
                "{}: the staged hosted-hash is {!r}, not {!r}. pub validates "
                "the cached package against that file.".format(basename, staged, digest)
            )
    return problems


def check_native_pins(root: Path, sources: list[tuple[str, Path, dict]]) -> list[str]:
    """Problems with the per-plugin native pins flatpak-flutter derives.

    flatpak-flutter keeps a fix per plugin *version* and picks the highest
    entry that is not newer than the locked one, so a plugin bump silently
    reuses the previous version's patch and pre-fetched archive. The patch
    filename records the version it was written against, which is what makes
    that mismatch visible without a network or a pub cache.
    """
    problems: list[str] = []
    locked = hosted_packages(root)

    for where, base, source in sources:
        if source.get("type") != "patch":
            continue
        dest = str(source.get("dest", ""))
        if not dest.startswith(PUB_HOSTED + "/"):
            continue
        target = PUB_DIRECTORY.match(dest.rsplit("/", 1)[-1])
        if target is None:
            problems.append(
                "{}: cannot read a package version out of {!r}".format(where, dest)
            )
            continue
        name, applied_to = target.group("name"), target.group("version")

        if name not in locked:
            problems.append(
                "{}: patches {}, which {} does not lock.".format(
                    where, name, LOCKFILE.name
                )
            )
        elif locked[name][0] != applied_to:
            problems.append(
                "{}: patches {}-{} but {} locks {}. Rerun "
                "scripts/regenerate_flatpak_sources.sh.".format(
                    where, name, applied_to, LOCKFILE.name, locked[name][0]
                )
            )

        path = str(source.get("path", ""))
        written_for = PATCH_VERSION.match(path.rsplit("/", 1)[-1])
        if written_for is None:
            problems.append(
                "{}: the patch filename {!r} does not say which {} version it "
                "was written for.".format(where, path, name)
            )
        elif written_for.group("version") != applied_to:
            problems.append(
                "{}: {} was written for {} {} but is applied to {}. "
                "flatpak-flutter reuses the newest fix that is not newer than "
                "the locked version, so this pin is stale rather than "
                "absent.".format(
                    where, path, name, written_for.group("version"), applied_to
                )
            )

        problems.extend(check_patch_pins(root, where, base, path, sources))
    return problems


def check_patch_pins(
    root: Path,
    where: str,
    base: Path,
    path: str,
    sources: list[tuple[str, Path, dict]],
) -> list[str]:
    """Problems with the downloads a committed CMake patch leaves in place.

    A patch that redirects a plugin's `FetchContent` is only a pin if it names
    a digest, and only offline if the same archive is pre-fetched with the same
    digest. Both halves are checked, for every declaration in the patch.
    """
    problems: list[str] = []
    patch = (base / path).resolve()
    if not patch.exists():
        return []

    declared: dict[str, str | None] = {}
    current_url: str | None = None
    for line in patch.read_text(encoding="utf-8").splitlines():
        body = line[1:].strip() if line[:1] in {"+", "-", " "} else line.strip()
        if body.startswith("URL "):
            current_url = body[len("URL ") :].strip()
            declared.setdefault(current_url, None)
        elif body.startswith("URL_HASH SHA256=") and current_url is not None:
            declared[current_url] = body[len("URL_HASH SHA256=") :].strip()

    staged = {
        str(source.get("url")): str(source.get("sha256"))
        for _where, _base, source in sources
        if source.get("type") in {"archive", "file"}
    }

    for url, digest in declared.items():
        if digest is None or not SHA256.match(digest):
            problems.append(
                "{}: {} declares {} with no URL_HASH, so CMake would accept "
                "whatever it downloads.".format(where, _rel(root, patch), url)
            )
            continue
        if url not in staged:
            problems.append(
                "{}: {} builds from {}, which no Flatpak source pre-fetches.".format(
                    where, _rel(root, patch), url
                )
            )
        elif staged[url] != digest:
            problems.append(
                "{}: {} pins {} to {} but the Flatpak source stages {}.".format(
                    where, _rel(root, patch), url, digest, staged[url]
                )
            )
    return problems


def check_generator(root: Path) -> list[str]:
    """Problems with the pin on the tool that writes every other pin."""
    text = (root / GENERATOR).read_text(encoding="utf-8")
    match = TOOL_COMMIT.search(text)
    if match is None:
        return [
            "{}: no TOOL_COMMIT pin. The generator decides every hash in "
            "flatpak/generated/, so which generator ran has to be written "
            "down.".format(GENERATOR.name)
        ]
    if not GIT_COMMIT.match(match.group(1)):
        return [
            "{}: TOOL_COMMIT is {!r}, not a full commit. A tag or branch can "
            "be repointed.".format(GENERATOR.name, match.group(1))
        ]
    return []


def unpinnable_inputs(root: Path) -> dict[str, str]:
    """Every build input that has no content pin, keyed the way the doc keys it.

    These are the honest exceptions: a Flatpak runtime is a signed OSTree ref
    that is *meant* to receive security updates, and the app's own checkout is
    pinned by the commit being built rather than by a digest. Each still has to
    be written down, so "not pinned" is always a decision somebody made.
    """
    manifest = load(root / MANIFEST)
    inputs = {
        "runtime:{}".format(manifest.get("runtime")): "the runtime branch",
        "sdk:{}".format(manifest.get("sdk")): "the SDK branch",
    }
    for extension in manifest.get("sdk-extensions", []) or []:
        inputs["sdk-extension:{}".format(extension)] = "an SDK extension branch"
    for where, _base, source in iter_sources(root, MANIFEST):
        if source.get("type") == "dir":
            inputs["dir:{}".format(source.get("path"))] = where
    return inputs


def documented_exceptions(path: Path) -> list[str]:
    """The keys in the doc's table of inputs that cannot be pinned."""
    keys: list[str] = []
    inside = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            inside = line.lstrip("# ").strip() == EXCEPTIONS_HEADING
            continue
        if not inside or not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells or set(cells[0]) <= {"-", ":"}:
            continue
        match = re.fullmatch(r"`([^`]+)`", cells[0])
        if match is None:
            continue
        if any(not cell for cell in cells):
            raise ManifestError(
                "{}: the row for {} has an empty column. A blank reason is a "
                "placeholder, not a decision.".format(path.name, cells[0])
            )
        keys.append(match.group(1))
    return keys


def check_exceptions(root: Path) -> list[str]:
    """Problems with the written record of what cannot be pinned."""
    problems: list[str] = []
    actual = unpinnable_inputs(root)
    documented = documented_exceptions(root / PIN_DOC)
    if not documented:
        return [
            "{} lists nothing under '{}'. That table is this check's source of "
            "truth, so an empty one is a broken check rather than a clean "
            "manifest.".format(PIN_DOC.name, EXCEPTIONS_HEADING)
        ]
    for key in sorted(set(actual) - set(documented)):
        problems.append(
            "{} is not content-addressed and has no row in {}. Say why it "
            "cannot be pinned and what bounds the risk.".format(key, PIN_DOC.name)
        )
    for key in sorted(set(documented) - set(actual)):
        problems.append(
            "{} has a row in {} but is no longer a build input. Remove the row "
            "rather than leaving an explanation for something that is "
            "gone.".format(key, PIN_DOC.name)
        )
    return problems


def check(root: Path) -> list[str]:
    """Every problem with the committed Flatpak sources, as messages."""
    problems: list[str] = []
    audited: list[tuple[str, Path, dict]] = []

    for manifest in (TEMPLATE, MANIFEST):
        if not (root / manifest).exists():
            problems.append("{} is missing.".format(manifest))
            continue
        sources = list(iter_sources(root, manifest))
        if not sources:
            problems.append("{} declares no sources at all.".format(manifest))
        for where, base, source in sources:
            problems.extend(check_source(root, where, base, source))
        if manifest == MANIFEST:
            audited = sources

    if not audited:
        return problems

    problems.extend(check_manifests_agree(root))
    problems.extend(check_flutter_pin(root))
    problems.extend(check_dart_pins(root, audited))
    problems.extend(check_native_pins(root, audited))
    problems.extend(check_generator(root))
    problems.extend(check_exceptions(root))
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="repository to check (default: this checkout)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()

    try:
        problems = check(root)
    except (ManifestError, OSError) as error:
        print("ERROR: {}".format(error), file=sys.stderr)
        print(
            "Nothing was audited, so this is not a pass.",
            file=sys.stderr,
        )
        return 2

    if problems:
        for problem in problems:
            print("FAIL: {}".format(problem), file=sys.stderr)
        print(
            "\n{} problem(s). See docs/flatpak-source-pinning.md for how the "
            "pins are produced and refreshed.".format(len(problems)),
            file=sys.stderr,
        )
        return 1

    remote = [
        source
        for _where, _base, source in iter_sources(root, MANIFEST)
        if str(source.get("url", "")).startswith("https://")
    ]
    print(
        "OK: {} remote Flatpak build source(s), each pinned by commit or "
        "sha256.".format(len(remote))
    )
    for key in sorted(unpinnable_inputs(root)):
        print("  not content-addressed, documented in {}: {}".format(PIN_DOC.name, key))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
