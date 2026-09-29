#!/usr/bin/env python3
"""Unit tests for scripts/check_network_destinations.py (#504).

    python3 test/tooling/check_network_destinations_test.py

The check is only worth running if it stays switched on, so both directions it
can be wrong in are tested: letting a new fixed host through, and crying wolf
over something that is not a destination at all (an interpolated server
address, a reserved example name, a version number). The inventory loader is
tested too: the reviewed data is the claim the check makes, so a file it would
silently half-read is a failure of its own.

The real repository is read, never written. Everything else is built in
temporary directories, and nothing here touches the network.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # Registered before exec: @dataclass resolves annotations through
    # sys.modules, so a module loaded this way but never registered blows up on
    # its first dataclass rather than on anything the tests are about.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


checker = _load("check_network_destinations", "check_network_destinations.py")

INVENTORY_PATH = SCRIPTS / "network_destinations.json"

KINDS = {
    "app-request": "Linthra connects to it",
    "browser-link": "Opened in the browser",
    "reference": "Only mentioned",
}

# An inventory small enough to read in full, shaped exactly like the real one.
MINIMAL_INVENTORY = {
    "version": 1,
    "kinds": KINDS,
    "destinations": [
        {
            "host": "github.com",
            "kind": "browser-link",
            "builds": "all",
            "paths": ["lib/about.dart"],
            "rationale": "Project link.",
        },
        {
            "host": "plex.tv",
            "kind": "app-request",
            "trigger": "user-action",
            "builds": "all",
            "paths": ["lib/plex/endpoints.dart"],
            "rationale": "Connect with Plex.",
        },
    ],
}

# A shipped tree that satisfies MINIMAL_INVENTORY exactly. Every scan root has
# at least one source file, because an empty root fails closed.
MINIMAL_TREE = {
    "lib/about.dart": "const repo = 'https://github.com/thezupzup/linthra';\n",
    "lib/plex/endpoints.dart": "const base = 'https://plex.tv';\n",
    "android/app/src/main/kotlin/Main.kt": "class Main\n",
    "linux/runner/main.cc": "int main() { return 0; }\n",
    "linux/packaging/app.desktop": "[Desktop Entry]\n",
    "native/core/src/lib.rs": "pub fn f() {}\n",
    "third_party/pkg/lib/pkg.dart": "void f() {}\n",
}


class Fixture:
    """A throwaway repository root plus an inventory file."""

    def __init__(self, tree: dict[str, str], inventory: dict) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for relative, text in tree.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.inventory_path = self.root / "inventory.json"
        self.inventory_path.write_text(json.dumps(inventory), encoding="utf-8")

    def close(self) -> None:
        self._tmp.cleanup()

    def audit(self):
        inventory = checker.load_inventory(self.inventory_path)
        return checker.audit(self.root, inventory)

    def run(self, *extra: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = checker.main(
                [
                    "--root",
                    str(self.root),
                    "--inventory",
                    str(self.inventory_path),
                    *extra,
                ]
            )
        return code, out.getvalue(), err.getvalue()


def fixture(
    extra: dict[str, str] | None = None, inventory: dict | None = None
) -> Fixture:
    tree = dict(MINIMAL_TREE)
    tree.update(extra or {})
    return Fixture(tree, copy.deepcopy(inventory or MINIMAL_INVENTORY))


class RealRepositoryTest(unittest.TestCase):
    """The committed inventory against the committed tree."""

    def test_the_repository_passes(self) -> None:
        inventory = checker.load_inventory(INVENTORY_PATH)
        report = checker.audit(ROOT, inventory)
        self.assertTrue(report.ok, checker.render_text(report))

    def test_nothing_is_contacted_without_a_user_action(self) -> None:
        # PRIVACY.md says so. If this ever has to change, the policy text and
        # docs/network-destinations.md change in the same pull request.
        inventory = checker.load_inventory(INVENTORY_PATH)
        self.assertEqual(checker.automatic_hosts(inventory), [])

    def test_every_app_request_is_documented_in_the_privacy_policy(self) -> None:
        privacy = (ROOT / "PRIVACY.md").read_text(encoding="utf-8")
        inventory = checker.load_inventory(INVENTORY_PATH)
        for entry in inventory.entries:
            if entry.kind == "app-request":
                self.assertTrue(
                    entry.host in privacy,
                    f"PRIVACY.md does not mention {entry.host}, which Linthra "
                    "contacts itself",
                )

    def test_the_repository_json_report_is_well_formed(self) -> None:
        inventory = checker.load_inventory(INVENTORY_PATH)
        report = checker.audit(ROOT, inventory)
        data = json.loads(checker.render_json(report))
        self.assertEqual(data["check"], "network-destinations")
        self.assertTrue(data["ok"])
        self.assertEqual(data["automatic"], [])
        hosts = {(d["host"], d["kind"]) for d in data["destinations"]}
        self.assertIn(("plex.tv", "app-request"), hosts)
        for destination in data["destinations"]:
            self.assertTrue(destination["files"], destination["host"])


class ScanTest(unittest.TestCase):
    """What counts as a host literal, and what does not."""

    def hosts(self, text: str) -> list[str]:
        return [o.host for o in checker.scan_text(text, "lib/x.dart")]

    def test_url_hosts_are_found_with_their_line(self) -> None:
        found = checker.scan_text(
            "a\nfinal u = Uri.parse('https://api.example.io/v1');\n", "lib/x.dart"
        )
        self.assertEqual([(o.host, o.line) for o in found], [("api.example.io", 2)])

    def test_every_scheme_the_app_could_use_is_read(self) -> None:
        text = "http://a.io wss://b.io ws://c.io ftp://d.io HTTPS://E.IO"
        self.assertEqual(self.hosts(text), ["a.io", "b.io", "c.io", "d.io", "e.io"])

    def test_an_interpolated_host_is_a_configured_address(self) -> None:
        text = "'http://$host:4533' \"https://${server.host}/x\" 'https://' + h"
        self.assertEqual(self.hosts(text), [])

    def test_an_ip_inside_a_url_is_counted_once(self) -> None:
        self.assertEqual(self.hosts("'http://10.1.2.3:8096/x'"), ["10.1.2.3"])

    def test_a_bare_ip_literal_is_found(self) -> None:
        self.assertEqual(self.hosts("InternetAddress('8.8.8.8')"), ["8.8.8.8"])

    def test_version_numbers_are_not_ip_addresses(self) -> None:
        self.assertEqual(self.hosts("version 1.2.3 and 1.2.3.4.5 and 999.1.1.1"), [])

    def test_a_bracketed_ipv6_host_is_read(self) -> None:
        self.assertEqual(self.hosts("http://[2001:4860::8888]:80/"), ["2001:4860::8888"])

    def test_a_host_passed_as_a_bare_string_is_found(self) -> None:
        text = (
            "Uri.https('tracker.io', '/e');\n"
            "Uri(scheme: 'https', host: 'beacon.io');\n"
            "Socket.connect('collector.io', 443);\n"
            'InetAddress.getByName("metrics.io");\n'
        )
        self.assertEqual(
            self.hosts(text), ["tracker.io", "beacon.io", "collector.io", "metrics.io"]
        )

    def test_a_bare_string_that_is_not_a_host_is_ignored(self) -> None:
        text = "Uri.http('$loopback:$port', '/id'); host: 'unknown'"
        self.assertEqual(self.hosts(text), [])


class ReservedTest(unittest.TestCase):
    def test_reserved_names_are_recognised(self) -> None:
        for host in (
            "example.com",
            "music.example.com",
            "plex.example.org",
            "server.test",
            "a.invalid",
            "localhost",
            "host",
            "127.0.0.1",
            "0.0.0.0",
            "::1",
            "192.0.2.10",
            "198.51.100.1",
            "203.0.113.9",
            "2001:db8::1",
        ):
            self.assertIsNotNone(checker.reserved_reason(host), host)

    def test_real_and_lan_addresses_are_not_reserved(self) -> None:
        # A hard-coded LAN address could be a real destination on somebody's
        # network, so it is reviewed like any other host.
        for host in (
            "example.co",
            "notexample.com",
            "plex.tv",
            "192.168.1.1",
            "10.0.0.1",
            "224.0.0.251",
            "8.8.8.8",
        ):
            self.assertIsNone(checker.reserved_reason(host), host)


class GlobTest(unittest.TestCase):
    def test_globs(self) -> None:
        cases = [
            ("lib/a.dart", "lib/a.dart", True),
            ("lib/*.dart", "lib/a.dart", True),
            ("lib/*.dart", "lib/sub/a.dart", False),
            ("lib/**/*.dart", "lib/a.dart", True),
            ("lib/**/*.dart", "lib/x/y/a.dart", True),
            ("lib/**", "lib/x/y/a.dart", True),
            ("lib/a.dart", "lib/a.dartx", False),
            ("lib/a?dart", "lib/a.dart", True),
        ]
        for pattern, path, expected in cases:
            self.assertEqual(
                checker.glob_matches(pattern, path), expected, (pattern, path)
            )


class AuditTest(unittest.TestCase):
    def test_a_clean_tree_passes(self) -> None:
        f = fixture()
        try:
            code, out, _ = f.run()
            self.assertEqual(code, 0, out)
            self.assertIn("Contacted with no user action in any build: none", out)
        finally:
            f.close()

    def test_a_new_host_fails(self) -> None:
        f = fixture({"lib/telemetry.dart": "const u = 'https://collect.tracker.io/e';\n"})
        try:
            code, out, _ = f.run()
            self.assertEqual(code, 1)
            self.assertIn("collect.tracker.io is not in the reviewed inventory", out)
            self.assertIn("lib/telemetry.dart:1", out)
        finally:
            f.close()

    def test_a_reviewed_host_in_a_new_file_fails(self) -> None:
        # github.com is reviewed as a browser link in lib/about.dart. The same
        # host turning up in a network client is exactly what must be seen.
        f = fixture({"lib/sync.dart": "post('https://github.com/upload');\n"})
        try:
            report = f.audit()
            self.assertFalse(report.ok)
            self.assertEqual(sorted(report.outside_paths), ["github.com"])
            code, out, _ = f.run()
            self.assertEqual(code, 1)
            self.assertIn("github.com is reviewed (browser-link)", out)
        finally:
            f.close()

    def test_a_private_lan_address_needs_review(self) -> None:
        f = fixture({"lib/probe.dart": "get('http://192.168.1.1/status');\n"})
        try:
            report = f.audit()
            self.assertEqual(sorted(report.unreviewed_hosts), ["192.168.1.1"])
        finally:
            f.close()

    def test_reserved_names_pass_without_an_entry(self) -> None:
        f = fixture(
            {
                "lib/hint.dart": (
                    "hint: 'https://music.example.com', 'http://localhost:4533',\n"
                    "'http://127.0.0.1:8096', 'http://host:4533/rest'\n"
                )
            }
        )
        try:
            report = f.audit()
            self.assertTrue(report.ok, checker.render_text(report))
            self.assertEqual(len(report.reserved), 4)
        finally:
            f.close()

    def test_a_stale_path_fails(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["destinations"][0]["paths"] = ["lib/about.dart", "lib/old.dart"]
        f = fixture(inventory=inventory)
        try:
            code, out, _ = f.run()
            self.assertEqual(code, 1)
            self.assertIn("lists lib/old.dart, which no longer mentions it", out)
        finally:
            f.close()

    def test_an_entry_whose_host_is_gone_fails(self) -> None:
        f = fixture({"lib/plex/endpoints.dart": "const base = '';\n"})
        try:
            report = f.audit()
            self.assertEqual(
                [(e.host, p) for e, p in report.stale_paths],
                [("plex.tv", "lib/plex/endpoints.dart")],
            )
        finally:
            f.close()

    def test_tests_examples_and_unshipped_platforms_are_not_read(self) -> None:
        f = fixture(
            {
                "third_party/pkg/test/fake.dart": "'https://foo.foo/a'\n",
                "third_party/pkg/example/lib/main.dart": "'https://bar.bar/b'\n",
                "third_party/pkg/darwin/Plugin.swift": "'https://baz.baz/c'\n",
                "third_party/pkg/darwin/Plugin.m": "'https://baz.baz/c'\n",
                "native/core/tests/t.cc": "'https://qux.qux/d'\n",
                "lib/README.md": "https://docs.docs/e\n",
            }
        )
        try:
            report = f.audit()
            self.assertTrue(report.ok, checker.render_text(report))
        finally:
            f.close()

    def test_a_missing_root_fails_closed(self) -> None:
        tree = dict(MINIMAL_TREE)
        del tree["linux/runner/main.cc"]
        f = Fixture(tree, copy.deepcopy(MINIMAL_INVENTORY))
        try:
            code, _, err = f.run()
            self.assertEqual(code, 2)
            self.assertIn("linux/runner/", err)
        finally:
            f.close()

    def test_json_output(self) -> None:
        f = fixture({"lib/telemetry.dart": "'https://collect.tracker.io/e'\n"})
        try:
            code, out, _ = f.run("--json")
            self.assertEqual(code, 1)
            data = json.loads(out)
            self.assertFalse(data["ok"])
            self.assertEqual(data["unreviewed"][0]["host"], "collect.tracker.io")
            self.assertEqual(
                data["unreviewed"][0]["found_in"], ["lib/telemetry.dart:1"]
            )
        finally:
            f.close()

    def test_an_automatic_destination_is_named_in_the_summary(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["destinations"][1]["trigger"] = "automatic"
        f = fixture(inventory=inventory)
        try:
            code, out, _ = f.run()
            self.assertEqual(code, 0)
            self.assertIn("Contacted with no user action in any build: plex.tv", out)
        finally:
            f.close()


class InventoryLoaderTest(unittest.TestCase):
    def load(self, inventory: dict):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "inventory.json"
            path.write_text(json.dumps(inventory), encoding="utf-8")
            return checker.load_inventory(path)

    def assert_rejected(self, inventory: dict, message: str) -> None:
        with self.assertRaises(checker.InventoryError) as raised:
            self.load(inventory)
        self.assertIn(message, str(raised.exception))

    def mutated(self, **changes) -> dict:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["destinations"][1].update(changes)
        return inventory

    def test_the_minimal_inventory_loads(self) -> None:
        self.assertEqual(len(self.load(MINIMAL_INVENTORY).entries), 2)

    def test_an_unknown_key_is_rejected(self) -> None:
        self.assert_rejected(self.mutated(owner="me"), "unknown key(s) owner")

    def test_an_unknown_top_level_key_is_rejected(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["allow"] = []
        self.assert_rejected(inventory, "unknown top-level key(s) allow")

    def test_a_blank_rationale_is_rejected(self) -> None:
        self.assert_rejected(self.mutated(rationale="  "), "must not be empty")

    def test_an_app_request_needs_a_trigger(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        del inventory["destinations"][1]["trigger"]
        self.assert_rejected(inventory, "trigger must be a string")

    def test_an_unknown_trigger_is_rejected(self) -> None:
        self.assert_rejected(self.mutated(trigger="sometimes"), "unknown trigger")

    def test_a_link_cannot_carry_a_trigger(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["destinations"][0]["trigger"] = "user-action"
        self.assert_rejected(inventory, 'only an "app-request" entry has a trigger')

    def test_an_unknown_kind_or_build_is_rejected(self) -> None:
        self.assert_rejected(self.mutated(kind="beacon"), "unknown kind")
        self.assert_rejected(self.mutated(builds="play"), "unknown builds")

    def test_a_reserved_host_is_rejected(self) -> None:
        self.assert_rejected(
            self.mutated(host="music.example.com"), "reserved names never need"
        )

    def test_a_host_must_be_normalised(self) -> None:
        self.assert_rejected(self.mutated(host="Plex.tv"), "lower case")

    def test_unsorted_or_duplicate_paths_are_rejected(self) -> None:
        self.assert_rejected(self.mutated(paths=["lib/b", "lib/a"]), "sorted and unique")
        self.assert_rejected(self.mutated(paths=["lib/a", "lib/a"]), "sorted and unique")

    def test_empty_paths_are_rejected(self) -> None:
        self.assert_rejected(self.mutated(paths=[]), "non-empty list")

    def test_destinations_must_be_sorted(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["destinations"].reverse()
        self.assert_rejected(inventory, "must be sorted by (host, kind)")

    def test_duplicates_are_rejected(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        inventory["destinations"].append(copy.deepcopy(inventory["destinations"][1]))
        self.assert_rejected(inventory, "duplicate destinations: plex.tv (app-request)")

    def test_kinds_must_be_described_exactly(self) -> None:
        inventory = copy.deepcopy(MINIMAL_INVENTORY)
        del inventory["kinds"]["reference"]
        self.assert_rejected(inventory, '"kinds" must describe exactly')

    def test_an_unreadable_inventory_is_an_error_not_a_pass(self) -> None:
        f = fixture()
        try:
            f.inventory_path.write_text("{not json", encoding="utf-8")
            code, _, err = f.run()
            self.assertEqual(code, 2)
            self.assertIn("not valid JSON", err)
        finally:
            f.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
