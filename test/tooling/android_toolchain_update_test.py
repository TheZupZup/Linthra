#!/usr/bin/env python3
"""Unit tests for the Android toolchain updater's Python internals (#362, PR 5).

    python3 test/tooling/android_toolchain_update_test.py

These sit one level below
test/tooling/android_toolchain_update_guardrails_test.dart, which drives the
same scripts end to end as subprocesses and also holds the workflow, CI and
documentation to their promises. This file pokes at the parts that are easiest
to get subtly wrong and hardest to see from outside:

  * the pin patterns, including that rewriting one leaves every other byte of
    the file alone — the property the whole AGP/Kotlin separation rests on;
  * the upstream parsers, including the prerelease and self-contradiction
    filters;
  * the classification, including that "newest on our major" and "newest
    overall" stay independent.

Everything is offline. No network, no git, no repository writes.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

# The scripts import each other by module name the way they do when run from
# scripts/, so that directory has to be importable here too.
sys.path.insert(0, str(SCRIPTS))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pins = _load("toolchain_pins", "toolchain_pins.py")
checker = _load("check_android_toolchain_update", "check_android_toolchain_update.py")
guard = _load("check_toolchain_pin_diff", "check_toolchain_pin_diff.py")
writer = _load("set_android_toolchain_pin", "set_android_toolchain_pin.py")

SETTINGS_GRADLE = (ROOT / "android" / "settings.gradle").read_text(encoding="utf-8")
WRAPPER_PROPERTIES = (
    ROOT / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties"
).read_text(encoding="utf-8")


def gradle_entry(version, **overrides):
    entry = {
        "version": version,
        "buildTime": "20260101000000+0000",
        "current": False,
        "snapshot": False,
        "nightly": False,
        "releaseNightly": False,
        "activeRc": False,
        "rcFor": "",
        "milestoneFor": "",
        "broken": False,
        "downloadUrl": (
            f"https://services.gradle.org/distributions/gradle-{version}-bin.zip"
        ),
        "final": True,
    }
    entry.update(overrides)
    return entry


def gradle_index(*entries):
    return json.dumps(list(entries))


def maven_metadata(group_id, artifact_id, versions, latest=None, release=None):
    body = "\n".join(f"      <version>{v}</version>" for v in versions)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<metadata>\n"
        f"  <groupId>{group_id}</groupId>\n"
        f"  <artifactId>{artifact_id}</artifactId>\n"
        "  <versioning>\n"
        f"    <latest>{latest or versions[-1]}</latest>\n"
        f"    <release>{release or versions[-1]}</release>\n"
        "    <versions>\n"
        f"{body}\n"
        "    </versions>\n"
        "  </versioning>\n"
        "</metadata>\n"
    )


class VersionParsing(unittest.TestCase):
    def test_bare_triples_parse(self):
        self.assertEqual(pins.parse_version("8.14.5", "x"), (8, 14, 5))
        self.assertEqual(pins.parse_version("  2.2.21 ", "x"), (2, 2, 21))
        self.assertEqual(pins.format_version((8, 14, 5)), "8.14.5")

    def test_anything_else_is_refused(self):
        for bad in [
            "",
            "   ",
            "8",
            "8.14",
            "8.14.5.1",
            "v8.14.5",
            "8.14.5-rc1",
            "latest",
            "8.14.x",
            None,
            8.14,
            ["8", "14", "5"],
        ]:
            with self.subTest(bad=bad):
                with self.assertRaises(pins.CheckError):
                    pins.parse_version(bad, "x")
                self.assertIsNone(pins.try_version(bad))

    def test_two_component_gradle_tags_are_not_pins(self):
        # `8.14` is a real Gradle release, but a pin file may only hold a bare
        # triple, so it is never a version an automatic update may write.
        self.assertIsNone(pins.try_version("8.14"))

    def test_prereleases_are_recognisable(self):
        for text in [
            "8.3.0-alpha01",
            "8.3.0-beta02",
            "8.3.0-rc01",
            "2.4.20-RC",
            "2.2.20-Beta1",
            "9.0.0-milestone-1",
            "9.7.1-20260814014720+0000-SNAPSHOT",
            "1.9.0-eap-1",
            "2.0.0-dev-123",
            "8.0.0-preview",
            "1.0.0-M1",
        ]:
            with self.subTest(text=text):
                self.assertTrue(pins.looks_like_prerelease(text))

    def test_final_versions_are_not_mistaken_for_prereleases(self):
        for text in ["8.14.5", "2.2.21", "9.0.0", "10.20.30"]:
            with self.subTest(text=text):
                self.assertFalse(pins.looks_like_prerelease(text))


class PinPatterns(unittest.TestCase):
    def test_each_pin_is_found_in_the_real_file(self):
        self.assertEqual(
            pins.find_pin(WRAPPER_PROPERTIES, "gradle"),
            pins.find_pin(WRAPPER_PROPERTIES, "gradle"),
        )
        for tool in ("agp", "kotlin"):
            version = pins.find_pin(SETTINGS_GRADLE, tool)
            self.assertRegex(version, r"^\d+\.\d+\.\d+$")

    def test_agp_and_kotlin_read_different_versions_from_one_file(self):
        self.assertNotEqual(
            pins.find_pin(SETTINGS_GRADLE, "agp"),
            pins.find_pin(SETTINGS_GRADLE, "kotlin"),
        )

    def test_replacing_a_pin_changes_only_that_pin(self):
        for tool, text in (
            ("gradle", WRAPPER_PROPERTIES),
            ("agp", SETTINGS_GRADLE),
            ("kotlin", SETTINGS_GRADLE),
        ):
            with self.subTest(tool=tool):
                original = pins.find_pin(text, tool)
                changed = pins.replace_pin(text, tool, "9999.888.777")
                self.assertEqual(pins.find_pin(changed, tool), "9999.888.777")
                # Everything else, including the other pin in the same file
                # and the file's trailing newline, must survive untouched.
                for other in pins.other_tools_in(tool):
                    self.assertEqual(
                        pins.find_pin(changed, other), pins.find_pin(text, other)
                    )
                self.assertEqual(pins.replace_pin(changed, tool, original), text)

    def test_replacing_a_pin_preserves_the_trailing_newline(self):
        # Regression: an ungrouped `\s*$` in the Gradle pattern used to swallow
        # the file's final newline, which is a real, invisible diff.
        changed = pins.replace_pin(WRAPPER_PROPERTIES, "gradle", "9.9.9")
        self.assertTrue(WRAPPER_PROPERTIES.endswith("\n"))
        self.assertTrue(changed.endswith("\n"))
        self.assertEqual(len(changed.splitlines()), len(WRAPPER_PROPERTIES.splitlines()))

    def test_a_missing_pin_is_refused_rather_than_guessed(self):
        with self.assertRaises(pins.CheckError):
            pins.find_pin("plugins {\n}\n", "agp")

    def test_an_ambiguous_pin_is_refused(self):
        doubled = SETTINGS_GRADLE + (
            '\nplugins {\n    id "com.android.application" version "1.0.0" apply false\n}\n'
        )
        with self.assertRaises(pins.CheckError):
            pins.find_pin(doubled, "agp")

    def test_the_gradle_pattern_ignores_the_other_wrapper_properties(self):
        for line in (
            "distributionBase=GRADLE_USER_HOME",
            "distributionPath=wrapper/dists",
            "zipStoreBase=GRADLE_USER_HOME",
            "zipStorePath=wrapper/dists",
        ):
            self.assertIn(line, pins.replace_pin(WRAPPER_PROPERTIES, "gradle", "9.9.9"))

    def test_only_agp_and_kotlin_share_a_file(self):
        self.assertEqual(pins.other_tools_in("agp"), ["kotlin"])
        self.assertEqual(pins.other_tools_in("kotlin"), ["agp"])
        self.assertEqual(pins.other_tools_in("gradle"), [])

    def test_an_unknown_tool_is_refused(self):
        with self.assertRaises(pins.CheckError):
            pins.tool("everything")


class GradleIndexParsing(unittest.TestCase):
    def parse(self, raw):
        return checker.parse_gradle_versions(raw, "fixture")

    def test_final_releases_are_candidates(self):
        found = self.parse(gradle_index(gradle_entry("8.14.5"), gradle_entry("9.0.0")))
        self.assertEqual(sorted(found.versions), [(8, 14, 5), (9, 0, 0)])

    def test_non_final_builds_are_skipped(self):
        found = self.parse(
            gradle_index(
                gradle_entry("8.14.5"),
                gradle_entry("9.1.0-rc-1", final=False, activeRc=True),
                gradle_entry(
                    "9.2.0-20260101000000+0000", final=False, releaseNightly=True
                ),
            )
        )
        self.assertEqual(found.versions, [(8, 14, 5)])
        self.assertEqual(found.prereleases, 2)

    def test_a_row_that_contradicts_its_own_final_flag_is_refused(self):
        for flag, value in [
            ("broken", True),
            ("snapshot", True),
            ("nightly", True),
            ("releaseNightly", True),
            ("activeRc", True),
            ("rcFor", "9.9.9"),
            ("milestoneFor", "9.9.9"),
        ]:
            with self.subTest(flag=flag):
                found = self.parse(
                    gradle_index(
                        gradle_entry("8.14.5"), gradle_entry("9.9.9", **{flag: value})
                    )
                )
                self.assertEqual(found.versions, [(8, 14, 5)])
                self.assertTrue(any("claims final" in n for n in found.notes))

    def test_a_release_from_an_unexpected_host_is_refused(self):
        found = self.parse(
            gradle_index(
                gradle_entry("8.14.5"),
                gradle_entry("9.9.9", downloadUrl="https://example.invalid/g.zip"),
                gradle_entry("9.9.8", downloadUrl=None),
            )
        )
        self.assertEqual(found.versions, [(8, 14, 5)])
        self.assertEqual(len(found.notes), 2)

    def test_structurally_wrong_payloads_raise(self):
        for raw in ["{{{", '{"releases": []}', "[]", '["8.14.5"]', "[null]"]:
            with self.subTest(raw=raw):
                with self.assertRaises(pins.CheckError):
                    self.parse(raw)


class MavenMetadataParsing(unittest.TestCase):
    def parse(self, raw, group="org.jetbrains.kotlin", artifact="kotlin-gradle-plugin"):
        return checker.parse_maven_metadata(raw, "fixture", group, artifact)

    def test_stable_versions_are_candidates(self):
        found = self.parse(
            maven_metadata(
                "org.jetbrains.kotlin",
                "kotlin-gradle-plugin",
                ["2.2.21", "2.3.0-RC", "2.3.0"],
            )
        )
        self.assertEqual(sorted(found.versions), [(2, 2, 21), (2, 3, 0)])
        self.assertEqual(found.prereleases, 1)

    def test_the_latest_and_release_pointers_are_ignored(self):
        # Kotlin's own metadata has pointed <release> at an -RC build.
        found = self.parse(
            maven_metadata(
                "org.jetbrains.kotlin",
                "kotlin-gradle-plugin",
                ["2.2.21", "2.3.0-RC"],
                latest="2.3.0-RC",
                release="2.3.0-RC",
            )
        )
        self.assertEqual(found.versions, [(2, 2, 21)])

    def test_metadata_for_another_artifact_is_refused(self):
        with self.assertRaises(pins.CheckError):
            self.parse(maven_metadata("com.example", "other", ["9.9.9"]))

    def test_entity_declarations_are_refused_before_parsing(self):
        raw = '<!DOCTYPE metadata [<!ENTITY a "b">]>\n' + maven_metadata(
            "org.jetbrains.kotlin", "kotlin-gradle-plugin", ["2.2.21"]
        )
        with self.assertRaises(pins.CheckError) as caught:
            self.parse(raw)
        self.assertIn("refusing to parse", str(caught.exception))

    def test_structurally_wrong_payloads_raise(self):
        for raw in [
            "not xml",
            "<html><body>nope</body></html>",
            "<metadata><groupId>org.jetbrains.kotlin</groupId>"
            "<artifactId>kotlin-gradle-plugin</artifactId></metadata>",
            "<metadata><groupId>org.jetbrains.kotlin</groupId>"
            "<artifactId>kotlin-gradle-plugin</artifactId>"
            "<versioning><versions></versions></versioning></metadata>",
        ]:
            with self.subTest(raw=raw[:40]):
                with self.assertRaises(pins.CheckError):
                    self.parse(raw)


class Classification(unittest.TestCase):
    def test_the_four_outcomes(self):
        self.assertEqual(checker.classify((8, 2, 3), (8, 2, 3)), "up-to-date")
        self.assertEqual(checker.classify((8, 2, 3), (8, 2, 4)), "patch")
        self.assertEqual(checker.classify((8, 2, 3), (8, 3, 0)), "minor")
        self.assertEqual(checker.classify((8, 2, 3), (9, 0, 0)), "major")

    def test_a_downgrade_is_never_classified(self):
        for older in [(8, 2, 2), (8, 1, 9), (7, 9, 9)]:
            with self.subTest(older=older):
                with self.assertRaises(pins.CheckError):
                    checker.classify((8, 2, 3), older)

    def evaluate(self, current, versions, tool="gradle"):
        found = checker.Candidates()
        found.versions = [pins.parse_version(v, "fixture") for v in versions]
        return checker.evaluate(
            tool, pins.parse_version(current, "current"), found, "fixture"
        )

    def test_the_two_answers_are_independent(self):
        result = self.evaluate("8.14.5", ["9.0.0", "8.15.0", "8.14.5"])
        self.assertEqual(result["status"], "minor")
        self.assertEqual(result["latest_in_current_major"], "8.15.0")
        self.assertEqual(result["major_status"], "available")
        self.assertEqual(result["major_latest"], "9.0.0")
        self.assertTrue(checker.needs_pr(result))
        self.assertTrue(checker.needs_issue(result))

    def test_a_newer_major_alone_asks_only_for_an_issue(self):
        result = self.evaluate("8.14.5", ["9.0.0", "8.14.5"])
        self.assertEqual(result["status"], "up-to-date")
        self.assertFalse(checker.needs_pr(result))
        self.assertTrue(checker.needs_issue(result))

    def test_nothing_new_asks_for_nothing(self):
        result = self.evaluate("8.14.5", ["8.14.5", "8.14.4"])
        self.assertFalse(checker.needs_pr(result))
        self.assertFalse(checker.needs_issue(result))

    def test_upstream_ordering_never_decides(self):
        for order in [
            ["8.2.9", "8.5.0", "8.4.0"],
            ["8.5.0", "8.4.0", "8.2.9"],
            ["8.4.0", "8.2.9", "8.5.0"],
        ]:
            with self.subTest(order=order):
                self.assertEqual(
                    self.evaluate("8.2.3", order)["latest_in_current_major"], "8.5.0"
                )

    def test_an_index_without_our_major_line_is_refused(self):
        with self.assertRaises(pins.CheckError) as caught:
            self.evaluate("8.14.5", ["9.0.0", "9.1.0"])
        self.assertIn("pinned major line", str(caught.exception))

    def test_an_index_behind_our_pin_is_refused(self):
        with self.assertRaises(pins.CheckError):
            self.evaluate("8.14.5", ["8.14.4", "8.13.0"])

    def test_a_pin_upstream_has_never_heard_of_is_noted_not_fatal(self):
        result = self.evaluate("8.14.5", ["8.15.0", "8.14.4"])
        self.assertEqual(result["status"], "minor")
        self.assertIn("not listed", result["notes"])


class ContentGuard(unittest.TestCase):
    def bump(self, text, tool, version):
        return pins.replace_pin(text, tool, version)

    def test_a_clean_single_pin_change_is_accepted(self):
        for tool, text in (
            ("gradle", WRAPPER_PROPERTIES),
            ("agp", SETTINGS_GRADLE),
            ("kotlin", SETTINGS_GRADLE),
        ):
            with self.subTest(tool=tool):
                current = pins.parse_version(pins.find_pin(text, tool), "pin")
                newer = pins.format_version((current[0], current[1], current[2] + 1))
                summary = guard.check_content(
                    tool, text, self.bump(text, tool, newer), "fixture"
                )
                self.assertIn("changes nothing else", summary)

    def test_agp_may_not_move_kotlin_and_kotlin_may_not_move_agp(self):
        for mover, victim in (("agp", "kotlin"), ("kotlin", "agp")):
            with self.subTest(mover=mover):
                after = self.bump(
                    self.bump(SETTINGS_GRADLE, mover, "8.99.99"), victim, "7.77.77"
                )
                with self.assertRaises(pins.CheckError) as caught:
                    guard.check_content(mover, SETTINGS_GRADLE, after, "fixture")
                self.assertIn(pins.tool(victim).label, str(caught.exception))

    def test_a_reworded_comment_is_rejected(self):
        current = pins.find_pin(SETTINGS_GRADLE, "agp")
        newer = pins.format_version(
            (
                pins.parse_version(current, "pin")[0],
                pins.parse_version(current, "pin")[1],
                pins.parse_version(current, "pin")[2] + 1,
            )
        )
        after = self.bump(SETTINGS_GRADLE, "agp", newer).replace(
            "// The two versions on the next lines", "// Whatever"
        )
        with self.assertRaises(pins.CheckError) as caught:
            guard.check_content("agp", SETTINGS_GRADLE, after, "fixture")
        self.assertIn("more than", str(caught.exception))

    def test_a_downgrade_and_a_major_are_both_rejected(self):
        for target, expected in (("9.0.0", "downgrade"), ("10.0.0", "major")):
            with self.subTest(target=target):
                after = self.bump(SETTINGS_GRADLE, "agp", target)
                with self.assertRaises(pins.CheckError) as caught:
                    guard.check_content("agp", SETTINGS_GRADLE, after, "fixture")
                self.assertIn(expected, str(caught.exception))

    def test_a_prerelease_target_is_rejected(self):
        after = self.bump(SETTINGS_GRADLE, "kotlin", "2.9.0-RC2")
        with self.assertRaises(pins.CheckError):
            guard.check_content("kotlin", SETTINGS_GRADLE, after, "fixture")

    def test_an_unchanged_file_is_not_an_error(self):
        summary = guard.check_content(
            "agp", SETTINGS_GRADLE, SETTINGS_GRADLE, "fixture"
        )
        self.assertIn("unchanged", summary)


class Writer(unittest.TestCase):
    def sandbox(self, tmp):
        """A throwaway copy of the repository's real pin files."""
        root = Path(tmp)
        (root / "android" / "gradle" / "wrapper").mkdir(parents=True)
        (root / "android" / "settings.gradle").write_text(
            SETTINGS_GRADLE, encoding="utf-8"
        )
        (root / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties").write_text(
            WRAPPER_PROPERTIES, encoding="utf-8"
        )
        return root

    def test_it_writes_one_pin_and_nothing_else(self):
        for tool in pins.TOOL_NAMES:
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as tmp:
                root = self.sandbox(tmp)
                before = pins.read_pin_file(root, tool)
                current = pins.parse_version(pins.find_pin(before, tool), "pin")
                newer = pins.format_version((current[0], current[1], current[2] + 1))

                writer.apply(root, tool, newer)

                after = pins.read_pin_file(root, tool)
                self.assertEqual(pins.find_pin(after, tool), newer)
                self.assertIn(
                    "changes nothing else",
                    guard.check_content(tool, before, after, "fixture"),
                )

    def test_it_refuses_a_rerun_a_downgrade_a_major_and_a_prerelease(self):
        for version, expected in (
            (pins.find_pin(SETTINGS_GRADLE, "agp"), "already pinned"),
            ("9.0.0", "downgrade"),
            ("10.0.0", "major"),
            ("9.99.0-rc1", "MAJOR.MINOR.PATCH"),
        ):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as tmp:
                root = self.sandbox(tmp)
                with self.assertRaises(pins.CheckError) as caught:
                    writer.apply(root, "agp", version)
                self.assertIn(expected, str(caught.exception))
                # A refusal must leave the file exactly as it was.
                self.assertEqual(pins.read_pin_file(root, "agp"), SETTINGS_GRADLE)


class NoNetworkInTheseTests(unittest.TestCase):
    def test_every_configured_source_is_https_and_first_party(self):
        allowed_hosts = (
            "https://services.gradle.org/",
            "https://dl.google.com/",
            "https://repo1.maven.org/",
        )
        for name, source in checker.SOURCES.items():
            with self.subTest(tool=name):
                self.assertTrue(
                    source["url"].startswith(allowed_hosts),
                    f"{name} reads from {source['url']}, which is not a "
                    "first-party release index.",
                )
                self.assertNotIn(".html", source["url"])

    def test_a_non_https_index_is_refused(self):
        with self.assertRaises(pins.CheckError):
            checker.load_index("http://example.invalid/index.json", None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
