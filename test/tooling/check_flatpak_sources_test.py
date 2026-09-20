#!/usr/bin/env python3
"""Unit tests for scripts/check_flatpak_sources.py (#443).

    python3 test/tooling/check_flatpak_sources_test.py

Each rule gets a fixture that breaks exactly one thing, because a pin check is
only worth having while it still fails. The fixture is a miniature checkout
built in a temporary directory: two manifests, a generated SDK module, a
generated pub source list, the patches they reference, a lockfile, a Flutter
pin and the documentation table. The real repository is read too, and only
read: the last test is the audit CI runs.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from typing import Iterator

import yaml

ROOT = Path(__file__).resolve().parents[2]


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


checker = _load("check_flatpak_sources", "check_flatpak_sources.py")

VERSION = "9.9.9"
FLUTTER_COMMIT = "a" * 40
ENGINE = "b" * 40
MPV_SHA = "c" * 64
PACKAGE_SHA = "d" * 64
SQLITE_SHA = "e" * 64
ENGINE_SHA = "f" * 64
TOOL_COMMIT = "1" * 40

SQLITE_URL = "https://sqlite.org/2026/sqlite-autoconf-3520000.tar.gz"

#: A plugin that downloads native code from its own CMake, at the version the
#: fixture lockfile pins. Both halves of its fix are in the fixture: the patch
#: that adds a URL_HASH, and the archive staged where CMake looks.
PLUGIN = "sqlite3_flutter_libs"
PLUGIN_VERSION = "0.5.42"

PATCH = """\
--- a/linux/CMakeLists.txt
+++ b/linux/CMakeLists.txt
@@ -14,6 +14,7 @@
   FetchContent_Declare(
     sqlite3
     URL {url}
+    URL_HASH SHA256={sha256}
   )
""".format(url=SQLITE_URL, sha256=SQLITE_SHA)


def _native_module() -> dict:
    return {
        "name": "mpv",
        "buildsystem": "meson",
        "sources": [
            {
                "type": "archive",
                "url": "https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz",
                "sha256": MPV_SHA,
            }
        ],
    }


def _template() -> dict:
    return {
        "app-id": "io.github.thezupzup.linthra",
        "runtime": "org.gnome.Platform",
        "runtime-version": "50",
        "sdk": "org.gnome.Sdk",
        "sdk-extensions": ["org.freedesktop.Sdk.Extension.llvm20"],
        "command": "linthra",
        "modules": [
            _native_module(),
            {
                "name": "linthra",
                "buildsystem": "simple",
                "sources": [
                    {"type": "dir", "path": ".."},
                    {
                        "type": "git",
                        "url": "https://github.com/flutter/flutter.git",
                        "tag": VERSION,
                        "commit": FLUTTER_COMMIT,
                        "dest": "flutter",
                    },
                ],
            },
        ],
    }


def _manifest() -> dict:
    return {
        "app-id": "io.github.thezupzup.linthra",
        "runtime": "org.gnome.Platform",
        "runtime-version": "50",
        "sdk": "org.gnome.Sdk",
        "sdk-extensions": ["org.freedesktop.Sdk.Extension.llvm20"],
        "command": "linthra",
        "modules": [
            _native_module(),
            {
                "name": "linthra",
                "buildsystem": "simple",
                "sources": [
                    {"type": "dir", "path": ".."},
                    "generated/sources/pubspec.json",
                ],
                "modules": ["generated/modules/flutter-sdk-{}.json".format(VERSION)],
            },
        ],
    }


def _sdk_module() -> dict:
    return {
        "name": "flutter",
        "buildsystem": "simple",
        "build-commands": ["mkdir -p /var/lib && cp -r flutter /var/lib"],
        "sources": [
            {
                "type": "git",
                "url": "https://github.com/flutter/flutter.git",
                "tag": VERSION,
                "commit": FLUTTER_COMMIT,
                "dest": "flutter",
            },
            {
                "type": "archive",
                "url": (
                    "https://storage.googleapis.com/flutter_infra_release/flutter/"
                    "{}/dart-sdk-linux-x64.zip".format(ENGINE)
                ),
                "sha256": ENGINE_SHA,
                "dest": "flutter/bin/cache",
            },
            {"type": "patch", "path": "../patches/flutter/shared.sh.patch"},
        ],
    }


def _pub_sources() -> list[dict]:
    return [
        {
            "type": "archive",
            "url": "https://pub.dev/api/archives/{}-{}.tar.gz".format(
                PLUGIN, PLUGIN_VERSION
            ),
            "sha256": PACKAGE_SHA,
            "dest": "{}/{}-{}".format(checker.PUB_HOSTED, PLUGIN, PLUGIN_VERSION),
        },
        {
            "type": "inline",
            "contents": PACKAGE_SHA,
            "dest": checker.PUB_HASHES,
            "dest-filename": "{}-{}.sha256".format(PLUGIN, PLUGIN_VERSION),
        },
        {
            "type": "file",
            "url": SQLITE_URL,
            "sha256": SQLITE_SHA,
            "dest": "./build/linux/x64/release/_deps/sqlite3-subbuild/"
            "sqlite3-populate-prefix/src",
        },
        {
            "type": "patch",
            "path": "generated/patches/{}/{}-CMakeLists.txt.patch".format(
                PLUGIN, PLUGIN_VERSION
            ),
            "dest": "{}/{}-{}".format(checker.PUB_HOSTED, PLUGIN, PLUGIN_VERSION),
        },
    ]


def _lockfile() -> str:
    return (
        "packages:\n"
        "  {name}:\n"
        "    dependency: direct main\n"
        "    description:\n"
        "      name: {name}\n"
        "      sha256: {sha}\n"
        '      url: "https://pub.dev"\n'
        "    source: hosted\n"
        '    version: "{version}"\n'
    ).format(name=PLUGIN, sha=PACKAGE_SHA, version=PLUGIN_VERSION)


def _pin_doc() -> str:
    rows = "\n".join(
        "| `{}` | because {} | bounded by {} |".format(key, key, key)
        for key in (
            "runtime:org.gnome.Platform",
            "sdk:org.gnome.Sdk",
            "sdk-extension:org.freedesktop.Sdk.Extension.llvm20",
            "dir:..",
        )
    )
    return (
        "# Flatpak source pinning\n\n"
        "## {}\n\n"
        "| Input | Why an immutable pin is impossible | What bounds the risk |\n"
        "| --- | --- | --- |\n"
        "{}\n\n"
        "## Something else\n\n"
        "| `not-a-key` | prose | prose |\n"
    ).format(checker.EXCEPTIONS_HEADING, rows)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _write_yaml(path: Path, data: object) -> None:
    _write(path, yaml.safe_dump(data, sort_keys=False))


def _write_json(path: Path, data: object) -> None:
    _write(path, json.dumps(data, indent=2) + "\n")


@contextlib.contextmanager
def fixture() -> Iterator[Path]:
    """A miniature checkout that passes every rule."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory).resolve()
        _write(root / checker.FLUTTER_PIN, VERSION + "\n")
        _write(root / checker.LOCKFILE, _lockfile())
        _write_yaml(root / checker.TEMPLATE, _template())
        _write_yaml(root / checker.MANIFEST, _manifest())
        _write_json(
            root / "flatpak/generated/modules/flutter-sdk-{}.json".format(VERSION),
            _sdk_module(),
        )
        _write_json(root / "flatpak/generated/sources/pubspec.json", _pub_sources())
        _write(root / "flatpak/generated/patches/flutter/shared.sh.patch", "patch\n")
        _write(
            root
            / "flatpak/generated/patches/{}/{}-CMakeLists.txt.patch".format(
                PLUGIN, PLUGIN_VERSION
            ),
            PATCH,
        )
        _write(root / checker.PIN_DOC, _pin_doc())
        _write(
            root / checker.GENERATOR,
            'TOOL_COMMIT="{}"\n'.format(TOOL_COMMIT),
        )
        yield root


def read_json(root: Path, relative: str) -> object:
    return json.loads((root / relative).read_text(encoding="utf-8"))


class FixtureTest(unittest.TestCase):
    """The fixture has to pass before a broken copy of it proves anything."""

    def test_the_fixture_is_clean(self) -> None:
        with fixture() as root:
            self.assertEqual(checker.check(root), [])

    def test_the_fixture_has_sources_to_audit(self) -> None:
        with fixture() as root:
            sources = list(checker.iter_sources(root, checker.MANIFEST))
        self.assertTrue(any(source.get("type") == "git" for _w, _b, source in sources))
        self.assertTrue(
            any(source.get("type") == "inline" for _w, _b, source in sources),
            msg="the included pub source list was not walked",
        )


class RemoteSourceTest(unittest.TestCase):
    def _problems(self, source: dict) -> list[str]:
        with fixture() as root:
            return checker.check_source(root, "fixture", root, source)

    def test_an_archive_without_a_digest_fails(self) -> None:
        problems = self._problems(
            {"type": "archive", "url": "https://example.invalid/a.tar.gz"}
        )
        self.assertTrue(any("has no sha256" in problem for problem in problems))

    def test_a_truncated_digest_fails(self) -> None:
        problems = self._problems(
            {
                "type": "archive",
                "url": "https://example.invalid/a.tar.gz",
                "sha256": "cafe",
            }
        )
        self.assertTrue(any("has no sha256" in problem for problem in problems))

    def test_md5_is_not_a_pin(self) -> None:
        problems = self._problems(
            {
                "type": "file",
                "url": "https://example.invalid/a.tar.gz",
                "md5": "0" * 32,
            }
        )
        self.assertTrue(any("collision-prone" in problem for problem in problems))

    def test_sha512_is_accepted(self) -> None:
        self.assertEqual(
            self._problems(
                {
                    "type": "archive",
                    "url": "https://example.invalid/a.tar.gz",
                    "sha512": "0" * 128,
                }
            ),
            [],
        )

    def test_plain_http_fails(self) -> None:
        problems = self._problems(
            {"type": "archive", "url": "http://example.invalid/a.tar.gz", "sha256": MPV_SHA}
        )
        self.assertTrue(any("not https" in problem for problem in problems))

    def test_a_git_source_needs_a_full_commit(self) -> None:
        problems = self._problems(
            {"type": "git", "url": "https://example.invalid/x.git", "tag": "1.0"}
        )
        self.assertTrue(any("full commit" in problem for problem in problems))

    def test_an_abbreviated_commit_is_not_a_pin(self) -> None:
        problems = self._problems(
            {"type": "git", "url": "https://example.invalid/x.git", "commit": "84fc5cbb22"}
        )
        self.assertTrue(any("full commit" in problem for problem in problems))

    def test_a_branch_fails_even_with_a_commit(self) -> None:
        problems = self._problems(
            {
                "type": "git",
                "url": "https://example.invalid/x.git",
                "branch": "main",
                "commit": FLUTTER_COMMIT,
            }
        )
        self.assertTrue(any("not a revision" in problem for problem in problems))

    # A digest next to a moving URL is not a pin: it turns the next upstream
    # push into a failed build, and says nothing about what was audited.
    def test_floating_urls_fail_even_when_hashed(self) -> None:
        for url in (
            "https://example.invalid/archive/refs/heads/main.tar.gz",
            "https://example.invalid/releases/latest/download/x.tar.gz",
            "https://example.invalid/archive/HEAD.tar.gz",
            "https://example.invalid/x.git/snapshot/master.tar.gz",
            "https://example.invalid/archive.tar.gz?branch=main",
        ):
            with self.subTest(url=url):
                problems = self._problems(
                    {"type": "archive", "url": url, "sha256": MPV_SHA}
                )
                self.assertTrue(
                    any("floating reference" in problem for problem in problems),
                    msg=problems,
                )

    def test_real_urls_are_not_mistaken_for_floating_ones(self) -> None:
        for url in (
            "https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz",
            "https://sqlite.org/2026/sqlite-autoconf-3520000.tar.gz",
            "https://code.videolan.org/videolan/libplacebo/-/archive/v7.360.1/"
            "libplacebo-v7.360.1.tar.gz",
            "https://storage.googleapis.com/flutter_infra_release/flutter/"
            "{}/linux-x64-release/linux-x64-flutter-gtk.zip".format(ENGINE),
            "https://github.com/microsoft/mimalloc/archive/refs/tags/v2.1.2.tar.gz",
        ):
            with self.subTest(url=url):
                self.assertEqual(
                    self._problems({"type": "archive", "url": url, "sha256": MPV_SHA}),
                    [],
                )

    def test_an_unpinnable_source_type_is_refused(self) -> None:
        for kind in ("svn", "bzr", "extra-data"):
            with self.subTest(kind=kind):
                problems = self._problems(
                    {"type": kind, "url": "https://example.invalid/x", "sha256": MPV_SHA}
                )
                self.assertTrue(any("refused" in problem for problem in problems))

    # A guard that cannot classify its input has to fail, not skip: a skipped
    # source is fetched and unaudited, which is a pass that means nothing.
    def test_an_unknown_source_type_fails(self) -> None:
        problems = self._problems({"type": "carthage", "url": "https://example.invalid/x"})
        self.assertTrue(any("unknown source type" in problem for problem in problems))

    def test_a_source_without_a_type_fails(self) -> None:
        problems = self._problems({"url": "https://example.invalid/x", "sha256": MPV_SHA})
        self.assertTrue(any("no type" in problem for problem in problems))


class LocalSourceTest(unittest.TestCase):
    def test_a_missing_patch_fails(self) -> None:
        with fixture() as root:
            (root / "flatpak/generated/patches/flutter/shared.sh.patch").unlink()
            problems = checker.check(root)
        self.assertTrue(any("does not exist" in problem for problem in problems))

    def test_an_absolute_path_fails(self) -> None:
        with fixture() as root:
            problems = checker.check_source(
                root, "fixture", root, {"type": "patch", "path": "/etc/fix.patch"}
            )
        self.assertTrue(any("absolute host path" in problem for problem in problems))

    def test_a_path_outside_the_checkout_fails(self) -> None:
        with fixture() as root:
            problems = checker.check_source(
                root,
                "fixture",
                root / "flatpak",
                {"type": "patch", "path": "../../elsewhere/fix.patch"},
            )
        self.assertTrue(any("outside the repository" in problem for problem in problems))

    # flatpak-builder resolves a module's relative paths against the file that
    # declared that module, so the generated SDK module's `../patches/...`
    # is inside flatpak/generated/. Resolving it anywhere else would make the
    # existence check meaningless.
    def test_a_generated_modules_patch_resolves_next_to_its_module(self) -> None:
        with fixture() as root:
            bases = {
                base
                for _where, base, source in checker.iter_sources(root, checker.MANIFEST)
                if str(source.get("path", "")).startswith("../patches/flutter/")
            }
        self.assertEqual(bases, {root / "flatpak/generated/modules"})


class ManifestAgreementTest(unittest.TestCase):
    def test_a_native_module_bumped_in_only_one_manifest_fails(self) -> None:
        with fixture() as root:
            manifest = yaml.safe_load((root / checker.MANIFEST).read_text())
            manifest["modules"][0]["sources"][0]["url"] = (
                "https://github.com/mpv-player/mpv/archive/refs/tags/v0.42.0.tar.gz"
            )
            _write_yaml(root / checker.MANIFEST, manifest)
            problems = checker.check(root)
        self.assertTrue(any("module mpv differs" in problem for problem in problems))

    def test_a_dropped_module_fails(self) -> None:
        with fixture() as root:
            manifest = yaml.safe_load((root / checker.MANIFEST).read_text())
            del manifest["modules"][0]
            _write_yaml(root / checker.MANIFEST, manifest)
            problems = checker.check(root)
        self.assertTrue(any("have drifted" in problem for problem in problems))

    def test_a_runtime_bumped_in_only_one_manifest_fails(self) -> None:
        with fixture() as root:
            manifest = yaml.safe_load((root / checker.MANIFEST).read_text())
            manifest["runtime-version"] = "51"
            _write_yaml(root / checker.MANIFEST, manifest)
            problems = checker.check(root)
        self.assertTrue(any("runtime-version" in problem for problem in problems))

    # Not the main guard on the sandbox (check_flatpak_permissions.py holds
    # both manifests to the rationale table), but a regeneration that dropped a
    # grant should be reported next to the module it came with.
    def test_finish_args_that_differ_fail(self) -> None:
        with fixture() as root:
            manifest = yaml.safe_load((root / checker.MANIFEST).read_text())
            manifest["finish-args"] = ["--share=network"]
            _write_yaml(root / checker.MANIFEST, manifest)
            problems = checker.check(root)
        self.assertTrue(any("finish-args" in problem for problem in problems))

    def test_a_named_runtime_channel_fails(self) -> None:
        with fixture() as root:
            for path in (checker.TEMPLATE, checker.MANIFEST):
                data = yaml.safe_load((root / path).read_text())
                data["runtime-version"] = "master"
                _write_yaml(root / path, data)
            problems = checker.check(root)
        self.assertTrue(any("released branch number" in problem for problem in problems))


class FlutterPinTest(unittest.TestCase):
    def test_a_bumped_pin_without_regeneration_fails(self) -> None:
        with fixture() as root:
            _write(root / checker.FLUTTER_PIN, "9.9.10\n")
            problems = checker.check(root)
        self.assertTrue(any("tagged" in problem for problem in problems))
        self.assertTrue(
            any("named for a different Flutter" in problem for problem in problems)
        )

    def test_a_template_commit_that_disagrees_with_the_module_fails(self) -> None:
        with fixture() as root:
            template = yaml.safe_load((root / checker.TEMPLATE).read_text())
            template["modules"][1]["sources"][1]["commit"] = "9" * 40
            _write_yaml(root / checker.TEMPLATE, template)
            problems = checker.check(root)
        self.assertTrue(any("pins Flutter commit" in problem for problem in problems))

    def test_mixed_engine_artifacts_fail(self) -> None:
        relative = "flatpak/generated/modules/flutter-sdk-{}.json".format(VERSION)
        with fixture() as root:
            module = read_json(root, relative)
            second = dict(module["sources"][1])
            second["url"] = second["url"].replace(ENGINE, "9" * 40)
            module["sources"].append(second)
            _write_json(root / relative, module)
            problems = checker.check(root)
        self.assertTrue(any("different engines" in problem for problem in problems))

    def test_an_sdk_module_with_no_engine_artifact_fails(self) -> None:
        relative = "flatpak/generated/modules/flutter-sdk-{}.json".format(VERSION)
        with fixture() as root:
            module = read_json(root, relative)
            module["sources"] = [
                source for source in module["sources"] if source["type"] != "archive"
            ]
            _write_json(root / relative, module)
            problems = checker.check(root)
        self.assertTrue(any("no Flutter engine artifact" in problem for problem in problems))


class DartPinTest(unittest.TestCase):
    def test_a_locked_package_with_no_generated_source_fails(self) -> None:
        with fixture() as root:
            _write(
                root / checker.LOCKFILE,
                _lockfile()
                + (
                    "  path_provider:\n"
                    "    dependency: direct main\n"
                    "    description:\n"
                    "      name: path_provider\n"
                    "      sha256: {}\n"
                    '      url: "https://pub.dev"\n'
                    "    source: hosted\n"
                    '    version: "2.1.5"\n'
                ).format("a" * 64),
            )
            problems = checker.check(root)
        self.assertTrue(
            any("has no generated pub.dev source" in problem for problem in problems)
        )

    def test_a_digest_that_drifted_from_the_lockfile_fails(self) -> None:
        with fixture() as root:
            sources = read_json(root, "flatpak/generated/sources/pubspec.json")
            sources[0]["sha256"] = "9" * 64
            _write_json(root / "flatpak/generated/sources/pubspec.json", sources)
            problems = checker.check(root)
        self.assertTrue(
            any("is not the one pubspec.lock resolved" in problem for problem in problems)
        )

    def test_a_missing_hosted_hash_fails(self) -> None:
        with fixture() as root:
            sources = [
                source
                for source in read_json(root, "flatpak/generated/sources/pubspec.json")
                if source["type"] != "inline"
            ]
            _write_json(root / "flatpak/generated/sources/pubspec.json", sources)
            problems = checker.check(root)
        self.assertTrue(any("staged hosted-hash" in problem for problem in problems))

    def test_a_url_that_disagrees_with_its_cache_directory_fails(self) -> None:
        with fixture() as root:
            sources = read_json(root, "flatpak/generated/sources/pubspec.json")
            sources[0]["url"] = "https://pub.dev/api/archives/{}-0.5.43.tar.gz".format(
                PLUGIN
            )
            _write_json(root / "flatpak/generated/sources/pubspec.json", sources)
            problems = checker.check(root)
        self.assertTrue(any("is staged as" in problem for problem in problems))


class NativePinTest(unittest.TestCase):
    """The drift flatpak-flutter's own version fallback produces.

    It keeps a fix per plugin version and picks the highest one that is not
    newer than the locked plugin, so bumping the plugin silently reapplies the
    previous version's patch and pre-fetched archive.
    """

    def test_a_patch_written_for_an_older_plugin_version_fails(self) -> None:
        with fixture() as root:
            lock = (root / checker.LOCKFILE).read_text(encoding="utf-8")
            _write(root / checker.LOCKFILE, lock.replace('"0.5.42"', '"0.5.43"'))
            sources = read_json(root, "flatpak/generated/sources/pubspec.json")
            for source in sources:
                for key in ("dest", "url"):
                    if key in source:
                        source[key] = source[key].replace("0.5.42", "0.5.43")
            _write_json(root / "flatpak/generated/sources/pubspec.json", sources)
            problems = checker.check(root)
        self.assertTrue(
            any("was written for" in problem for problem in problems), msg=problems
        )

    def test_a_patch_applied_to_a_version_the_lockfile_does_not_have_fails(self) -> None:
        with fixture() as root:
            lock = (root / checker.LOCKFILE).read_text(encoding="utf-8")
            _write(root / checker.LOCKFILE, lock.replace('"0.5.42"', '"0.5.43"'))
            problems = checker.check(root)
        self.assertTrue(any("but pubspec.lock locks" in problem for problem in problems))

    def test_a_fetchcontent_url_without_a_hash_fails(self) -> None:
        relative = "flatpak/generated/patches/{}/{}-CMakeLists.txt.patch".format(
            PLUGIN, PLUGIN_VERSION
        )
        with fixture() as root:
            _write(
                root / relative,
                PATCH.replace("+    URL_HASH SHA256={}\n".format(SQLITE_SHA), ""),
            )
            problems = checker.check(root)
        self.assertTrue(any("no URL_HASH" in problem for problem in problems))

    def test_a_pre_fetched_archive_with_a_different_digest_fails(self) -> None:
        with fixture() as root:
            sources = read_json(root, "flatpak/generated/sources/pubspec.json")
            for source in sources:
                if source.get("url") == SQLITE_URL:
                    source["sha256"] = "9" * 64
            _write_json(root / "flatpak/generated/sources/pubspec.json", sources)
            problems = checker.check(root)
        self.assertTrue(any("but the Flatpak source stages" in problem for problem in problems))

    def test_an_unstaged_fetchcontent_url_fails(self) -> None:
        with fixture() as root:
            sources = [
                source
                for source in read_json(root, "flatpak/generated/sources/pubspec.json")
                if source.get("url") != SQLITE_URL
            ]
            _write_json(root / "flatpak/generated/sources/pubspec.json", sources)
            problems = checker.check(root)
        self.assertTrue(any("no Flatpak source pre-fetches" in problem for problem in problems))


class GeneratorPinTest(unittest.TestCase):
    def test_a_generator_tracking_a_tag_fails(self) -> None:
        with fixture() as root:
            _write(root / checker.GENERATOR, 'TOOL_COMMIT="0.15.0"\n')
            problems = checker.check(root)
        self.assertTrue(any("not a full commit" in problem for problem in problems))

    def test_a_generator_with_no_pin_fails(self) -> None:
        with fixture() as root:
            _write(root / checker.GENERATOR, "echo hello\n")
            problems = checker.check(root)
        self.assertTrue(any("no TOOL_COMMIT pin" in problem for problem in problems))


class DocumentedExceptionTest(unittest.TestCase):
    def test_reads_only_the_table_under_its_heading(self) -> None:
        with fixture() as root:
            keys = checker.documented_exceptions(root / checker.PIN_DOC)
        self.assertIn("dir:..", keys)
        self.assertNotIn("not-a-key", keys)

    def test_a_row_with_an_empty_column_is_a_placeholder(self) -> None:
        with fixture() as root:
            _write(
                root / checker.PIN_DOC,
                _pin_doc().replace("| because dir:.. | bounded by dir:.. |", "|  |  |"),
            )
            with self.assertRaises(checker.ManifestError):
                checker.documented_exceptions(root / checker.PIN_DOC)

    def test_an_undocumented_unpinnable_input_fails(self) -> None:
        with fixture() as root:
            _write(
                root / checker.PIN_DOC,
                _pin_doc().replace("| `dir:..` | because dir:.. | bounded by dir:.. |\n", ""),
            )
            problems = checker.check(root)
        self.assertTrue(any("has no row in" in problem for problem in problems))

    def test_an_sdk_extension_bump_needs_its_row_updated(self) -> None:
        with fixture() as root:
            for path in (checker.TEMPLATE, checker.MANIFEST):
                data = yaml.safe_load((root / path).read_text())
                data["sdk-extensions"] = ["org.freedesktop.Sdk.Extension.llvm21"]
                _write_yaml(root / path, data)
            problems = checker.check(root)
        self.assertTrue(any("llvm21" in problem for problem in problems))

    # An explanation must not outlive the input it explains.
    def test_a_row_for_something_that_is_gone_fails(self) -> None:
        with fixture() as root:
            _write(
                root / checker.PIN_DOC,
                _pin_doc().replace(
                    "| `dir:..` |", "| `dir:..` | x | y |\n| `dir:../vendor` |", 1
                ),
            )
            problems = checker.check(root)
        self.assertTrue(
            any("no longer a build input" in problem for problem in problems)
        )

    def test_an_empty_table_is_a_broken_check(self) -> None:
        with fixture() as root:
            _write(root / checker.PIN_DOC, "# Flatpak source pinning\n")
            problems = checker.check(root)
        self.assertTrue(any("broken check" in problem for problem in problems))


class RealRepositoryTest(unittest.TestCase):
    """The audit itself, run the way CI runs it."""

    def test_the_committed_sources_are_pinned(self) -> None:
        self.assertEqual(checker.check(ROOT), [])

    def test_there_is_something_to_audit(self) -> None:
        sources = list(checker.iter_sources(ROOT, checker.MANIFEST))
        remote = [
            source
            for _where, _base, source in sources
            if str(source.get("url", "")).startswith("https://")
        ]
        self.assertGreater(len(remote), 100)

    def test_the_documented_exceptions_are_the_real_ones(self) -> None:
        self.assertEqual(
            sorted(checker.documented_exceptions(ROOT / checker.PIN_DOC)),
            sorted(checker.unpinnable_inputs(ROOT)),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
