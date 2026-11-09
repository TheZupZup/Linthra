#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_repository_integrity.py"

spec = importlib.util.spec_from_file_location("integrity", SCRIPT)
integrity = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = integrity
spec.loader.exec_module(integrity)

SELF_TEST_PATH = "test/tooling/check_repository_integrity_test.py"

# A real attack string, kept literal so the tests below exercise the production
# pattern rather than a sanitised stand-in. The trailing marker is what keeps
# the repository-wide scan of this very file from flagging it; the string
# written into a fixture repository carries no marker, so it stays detectable.
ASSET_EXECUTION_PAYLOAD = "node ./public/fonts/looks-safe.woff2\n"  # integrity-guard-fixture

# Built at runtime so this source line holds neither the payload nor the marker.
MARKED_PAYLOAD_LINE = f"{ASSET_EXECUTION_PAYLOAD.strip()}  # {integrity.FIXTURE_EXEMPTION_MARKER}"

# Script body used as a disguised-asset payload. Contains no asset extension, so
# it is inert to the text scan and needs no fixture marker of its own.
PREFIXED_SCRIPT_PAYLOAD = b"=0;\nglobal.p=require('child_process');p.exec('id');\n"


def asset_command(*parts: str) -> str:
    """Assemble attack fixtures without making this source self-match."""
    return "".join(parts)


def gif_blob() -> bytes:
    """A minimal but structurally complete 1x1 GIF, trailer included."""
    header = b"GIF89a" + (1).to_bytes(2, "little") + (1).to_bytes(2, "little") + bytes([0x80, 0, 0])
    global_color_table = b"\x00\x00\x00\xff\xff\xff"
    descriptor = b"\x2c" + bytes(8) + b"\x00"
    image = b"\x02" + b"\x02\x4c\x01" + b"\x00"
    return header + global_color_table + descriptor + image + b"\x3b"


def webp_blob() -> bytes:
    """A minimal RIFF/WEBP container: declared length exact, real VP8 keyframe
    start code in the payload."""
    payload = b"\x00\x00\x00" + b"\x9d\x01\x2a" + bytes(10)
    body = b"WEBP" + b"VP8 " + len(payload).to_bytes(4, "little") + payload
    return b"RIFF" + len(body).to_bytes(4, "little") + body


def script_webp_blob() -> bytes:
    """Honest RIFF and chunk lengths, JavaScript in the image payload."""
    payload = b'*/=0;console.log("EXEC")/*' + b"A" * 40 + b"*/"
    body = b"WEBP" + b"VP8 " + len(payload).to_bytes(4, "little") + payload
    return b"RIFF" + len(body).to_bytes(4, "little") + body


def png_blob() -> bytes:
    return b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR" + bytes(20)


def pdf_blob() -> bytes:
    """Entirely ASCII, as a standards-compliant PDF is allowed to be."""
    return (
        b"%PDF-1.4\n"
        b"1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
        b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
        b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n"
        b"xref\n0 4\n0000000000 65535 f \n"
        b"trailer<</Size 4/Root 1 0 R>>\nstartxref\n0\n%%EOF\n"
    )


def ico_blob() -> bytes:
    """One directory entry pointing at real image bytes."""
    image = bytes(40)
    entry = (
        b"\x10\x10\x00\x00"
        + (1).to_bytes(2, "little")
        + (32).to_bytes(2, "little")
        + len(image).to_bytes(4, "little")
        + (22).to_bytes(4, "little")
    )
    return b"\x00\x00\x01\x00" + (1).to_bytes(2, "little") + entry + image


def vp8x_only_webp_blob() -> bytes:
    """Extended header with no image frame — well-formed, but not an image."""
    payload = b"*/" + bytes(8) + b'console.log("EXEC")/*' + b"A" * 21 + b"*/"
    body = b"WEBP" + b"VP8X" + len(payload).to_bytes(4, "little") + payload
    return b"RIFF" + len(body).to_bytes(4, "little") + body


def animated_webp_blob() -> bytes:
    """ANMF wrapping a real VP8 frame: the frame is nested, not top level."""
    frame = b"\x00\x00\x00" + b"\x9d\x01\x2a" + bytes(10)
    inner = b"VP8 " + len(frame).to_bytes(4, "little") + frame
    anmf = bytes(16) + inner
    vp8x = b"VP8X" + (10).to_bytes(4, "little") + bytes(10)
    body = b"WEBP" + vp8x + b"ANMF" + len(anmf).to_bytes(4, "little") + anmf
    return b"RIFF" + len(body).to_bytes(4, "little") + body


def woff2_blob(num_tables: int = 1) -> bytes:
    """A structurally valid WOFF2 header padded out to its declared length."""
    body = bytes(64)
    total = 48 + len(body)
    return (
        b"wOF2"
        + b"\x00\x01\x00\x00"
        + total.to_bytes(4, "big")
        + num_tables.to_bytes(2, "big")
        + b"\x00\x00"
        + bytes(32)
        + body
    )


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


class RepositoryIntegrityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-b", "main")
        git(self.repo, "config", "user.name", "Test")
        git(self.repo, "config", "user.email", "test@example.invalid")
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n", encoding="utf-8")
        (self.repo / "lib").mkdir()
        (self.repo / "lib" / "main.dart").write_text("void main() {}\n", encoding="utf-8")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-m", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def commit(self, message: str = "change") -> str:
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-m", message)
        return git(self.repo, "rev-parse", "HEAD")

    def scan(self, head: str, author: str = "external") -> list:
        old = Path.cwd()
        os.chdir(self.repo)
        try:
            return integrity.scan(self.base, head, author, "TheZupZup")
        finally:
            os.chdir(old)

    def test_clean_code_change_passes(self) -> None:
        (self.repo / "lib" / "main.dart").write_text("void main() { print('ok'); }\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_external_linux_audio_smoke_is_allowed(self) -> None:
        path = self.repo / "tool" / "linux_audio_backend_smoke.dart"
        path.parent.mkdir(parents=True)
        path.write_text("void main() {}\n", encoding="utf-8")

        self.assertEqual(self.scan(self.commit()), [])

    def test_other_tool_scripts_remain_blocked(self) -> None:
        path = self.repo / "tool" / "version_from_tag.dart"
        path.parent.mkdir(parents=True)
        path.write_text("void main() {}\n", encoding="utf-8")

        findings = self.scan(self.commit())
        self.assertTrue(any(f.path == "tool/version_from_tag.dart" for f in findings))

    def test_dangerous_smoke_content_remains_blocked(self) -> None:
        path = self.repo / "tool" / "linux_audio_backend_smoke.dart"
        path.parent.mkdir(parents=True)
        path.write_text(ASSET_EXECUTION_PAYLOAD, encoding="utf-8")

        findings = self.scan(self.commit())
        self.assertTrue(
            any("asset file as executable" in f.reason for f in findings)
        )

    def test_external_vscode_change_is_blocked(self) -> None:
        path = self.repo / ".vscode" / "tasks.json"
        path.parent.mkdir()
        path.write_text('{"version":"2.0.0"}\n', encoding="utf-8")
        git(self.repo, "add", "-f", ".vscode/tasks.json")
        git(self.repo, "commit", "-m", "workspace")
        head = git(self.repo, "rev-parse", "HEAD")
        findings = self.scan(head)
        self.assertTrue(any(f.path == ".vscode/tasks.json" for f in findings))

    def test_removed_prohibited_path_still_reports_historical_commit(self) -> None:
        path = self.repo / ".vscode" / "tasks.json"
        path.parent.mkdir()
        path.write_text('{}\n', encoding="utf-8")
        git(self.repo, "add", "-f", ".vscode/tasks.json")
        introduced = self.commit("introduce prohibited path")
        path.unlink()
        head = self.commit("remove prohibited path")
        findings = self.scan(head)
        # The introducing commit stays attributable even though the final tree
        # no longer carries the path. The cleanup commit is reported too, and
        # deliberately so: removing a maintainer-controlled path is itself a
        # repository-control change an external PR may not make.
        attributed = {f.commit for f in findings if f.path == ".vscode/tasks.json"}
        self.assertIn(introduced, attributed)
        match = next(f for f in findings if f.commit == introduced)
        self.assertEqual(match.rule, "external-maintainer-controlled-path")
        self.assertEqual(match.severity, "blocked")

    def test_rename_away_from_protected_path_is_blocked(self) -> None:
        """Rename detection must never hide a removed maintainer-controlled path.

        `git log --name-only` would report only the unprotected destination, so
        every history query here uses --no-renames and sees the deleted source.
        """
        workflow = self.repo / ".github" / "workflows"
        workflow.mkdir(parents=True)
        (workflow / "a.yml").write_text("name: CI\non: push\njobs: {}\n", encoding="utf-8")
        self.base = self.commit("trusted workflow")
        docs = self.repo / "docs"
        docs.mkdir(exist_ok=True)
        git(self.repo, "mv", ".github/workflows/a.yml", "docs/a.txt")
        head = self.commit("rename protected workflow away")
        findings = self.scan(head)
        self.assertTrue(
            any(f.path == ".github/workflows/a.yml" for f in findings),
            f"rename hid the protected source: {[f.path for f in findings]}",
        )

    def test_case_variant_ide_paths_are_blocked(self) -> None:
        for relative in (".VSCODE/tasks.json", ".Idea/workspace.xml"):
            with self.subTest(relative):
                path = self.repo / relative
                path.parent.mkdir()
                path.write_text("{}\n", encoding="utf-8")
                findings = self.scan(self.commit(relative))
                self.assertTrue(any(f.path == relative for f in findings))
                self.base = git(self.repo, "rev-parse", "HEAD")

    def test_similarly_named_ide_path_is_allowed(self) -> None:
        path = self.repo / ".vscode-notes" / "readme.txt"
        path.parent.mkdir()
        path.write_text("notes\n", encoding="utf-8")
        self.assertEqual(self.scan(self.commit()), [])

    def test_owner_can_change_maintainer_controlled_path(self) -> None:
        path = self.repo / ".vscode" / "extensions.json"
        path.parent.mkdir()
        path.write_text('{"recommendations":[]}\n', encoding="utf-8")
        git(self.repo, "add", "-f", ".vscode/extensions.json")
        git(self.repo, "commit", "-m", "owner workspace")
        head = git(self.repo, "rev-parse", "HEAD")
        findings = self.scan(head, author="TheZupZup")
        self.assertEqual(findings, [])

    def test_fake_woff2_is_blocked(self) -> None:
        path = self.repo / "public" / "fonts" / "bad.woff2"
        path.parent.mkdir(parents=True)
        path.write_text("global.r=require; console.log('not a font');\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any(f.path.endswith("bad.woff2") for f in findings))

    def test_valid_woff2_passes_structural_check(self) -> None:
        path = self.repo / "public" / "fonts" / "ok.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(woff2_blob())
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_woff2_magic_prefix_alone_is_not_enough(self) -> None:
        """A valid `wOF2` prefix in front of script is the incident's attack."""
        path = self.repo / "public" / "fonts" / "sneaky.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"wOF2" + PREFIXED_SCRIPT_PAYLOAD)
        findings = self.scan(self.commit())
        self.assertTrue(any(f.path.endswith("sneaky.woff2") for f in findings))

    def test_script_appended_to_a_real_font_is_blocked(self) -> None:
        path = self.repo / "public" / "fonts" / "trailer.woff2"
        path.parent.mkdir(parents=True)
        path.write_bytes(woff2_blob() + PREFIXED_SCRIPT_PAYLOAD)
        findings = self.scan(self.commit())
        self.assertTrue(any("not a valid WOFF2" in f.reason for f in findings))

    def test_png_signature_without_ihdr_is_blocked(self) -> None:
        path = self.repo / "assets" / "bad.png"
        path.parent.mkdir()
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + PREFIXED_SCRIPT_PAYLOAD)
        findings = self.scan(self.commit())
        self.assertTrue(any(f.path.endswith("bad.png") for f in findings))

    def test_valid_gif_and_webp_pass(self) -> None:
        (self.repo / "assets").mkdir()
        (self.repo / "assets" / "ok.gif").write_bytes(gif_blob())
        (self.repo / "assets" / "ok.webp").write_bytes(webp_blob())
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_webp_with_honest_lengths_but_script_payload_is_blocked(self) -> None:
        """Self-consistent chunk lengths are not proof of an image."""
        path = self.repo / "assets" / "sizes.webp"
        path.parent.mkdir()
        path.write_bytes(script_webp_blob())
        findings = self.scan(self.commit())
        self.assertTrue(any("sizes.webp" in f.path for f in findings))

    def test_vp8x_without_an_image_frame_is_blocked(self) -> None:
        """VP8X is the extended header, not image data."""
        path = self.repo / "assets" / "hdr.webp"
        path.parent.mkdir()
        path.write_bytes(vp8x_only_webp_blob())
        findings = self.scan(self.commit())
        self.assertTrue(any("hdr.webp" in f.path for f in findings))

    def test_animated_webp_with_nested_frame_passes(self) -> None:
        """A real animation carries its frame inside ANMF, not at top level."""
        path = self.repo / "assets" / "anim.webp"
        path.parent.mkdir()
        path.write_bytes(animated_webp_blob())
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_ico_with_empty_directory_entry_is_blocked(self) -> None:
        path = self.repo / "assets" / "hollow.ico"
        path.parent.mkdir()
        path.write_bytes(b"\x00\x00\x01\x00\x01\x00" + bytes(16))
        findings = self.scan(self.commit())
        self.assertTrue(any("hollow.ico" in f.path for f in findings))

    def test_valid_pdf_and_ico_pass(self) -> None:
        (self.repo / "docs").mkdir()
        (self.repo / "docs" / "ok.pdf").write_bytes(pdf_blob())
        (self.repo / "docs" / "ok.ico").write_bytes(ico_blob())
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_ascii_only_pdf_is_not_flagged_as_text(self) -> None:
        """A valid PDF may contain no binary at all; the backstop must not fire."""
        path = self.repo / "docs" / "ascii.pdf"
        path.parent.mkdir()
        blob = pdf_blob()
        self.assertNotIn(b"\x00", blob, "fixture must be genuinely ASCII-only")
        path.write_bytes(blob)
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_shell_script_named_pdf_is_blocked(self) -> None:
        # A benign script body on purpose: what is under test is that the file
        # is not a PDF, not what the script does. A real download-and-execute
        # string here would be flagged by the PR security surface scanner, which
        # reads this file too.
        path = self.repo / "docs" / "payload.pdf"
        path.parent.mkdir()
        path.write_text("#!/bin/sh\necho hello\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("payload.pdf" in f.path for f in findings))

    def test_executable_asset_is_blocked(self) -> None:
        """The executable bit runs a payload without any invocation in text."""
        path = self.repo / "assets" / "run.png"
        path.parent.mkdir()
        path.write_bytes(png_blob())
        os.chmod(path, 0o755)
        findings = self.scan(self.commit())
        self.assertTrue(any("executable bit" in f.reason for f in findings))

    def test_ordinary_asset_mode_passes(self) -> None:
        path = self.repo / "assets" / "plain.png"
        path.parent.mkdir()
        path.write_bytes(png_blob())
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_gif_javascript_polyglot_is_blocked(self) -> None:
        """`GIF89a=0;` is both a plausible header and executable JavaScript."""
        path = self.repo / "assets" / "poly.gif"
        path.parent.mkdir()
        path.write_bytes(b"GIF89a=0;console.log('EXEC')")
        findings = self.scan(self.commit())
        self.assertTrue(any("poly.gif" in f.path for f in findings))

    def test_webp_javascript_polyglot_is_blocked(self) -> None:
        """The fourcc can be parked inside a JavaScript comment."""
        path = self.repo / "assets" / "poly.webp"
        path.parent.mkdir()
        path.write_bytes(b"RIFF/*xxWEBPVP8 */=0;console.log('EXEC')")
        findings = self.scan(self.commit())
        self.assertTrue(any("poly.webp" in f.path for f in findings))

    def test_text_only_asset_is_blocked(self) -> None:
        """Backstop: real assets in these formats always carry binary content."""
        path = self.repo / "assets" / "text.png"
        path.parent.mkdir()
        path.write_bytes(b"just plain text pretending to be an image\n")
        findings = self.scan(self.commit())
        self.assertTrue(any("entirely text" in f.reason for f in findings))

    def test_truncated_webp_is_blocked(self) -> None:
        path = self.repo / "assets" / "short.webp"
        path.parent.mkdir()
        path.write_bytes(b"RIFF" + (9999).to_bytes(4, "little") + b"WEBPVP8 " + bytes(32))
        findings = self.scan(self.commit())
        self.assertTrue(any("short.webp" in f.path for f in findings))

    def test_asset_execution_command_is_blocked(self) -> None:
        path = self.repo / "docs" / "note.txt"
        path.parent.mkdir()
        path.write_text(ASSET_EXECUTION_PAYLOAD, encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("asset file as executable" in f.reason for f in findings))

    def test_asset_execution_payload_is_blocked_inside_the_self_test_path(self) -> None:
        """The fixture exemption is per line, not per file."""
        path = self.repo / SELF_TEST_PATH
        path.parent.mkdir(parents=True)
        path.write_text(ASSET_EXECUTION_PAYLOAD, encoding="utf-8")
        findings = self.scan(self.commit(), author="TheZupZup")
        self.assertTrue(
            any(
                f.path == SELF_TEST_PATH and "asset file as executable" in f.reason
                for f in findings
            )
        )

    def test_external_change_to_the_guard_self_test_is_blocked(self) -> None:
        path = self.repo / SELF_TEST_PATH
        path.parent.mkdir(parents=True)
        path.write_text("import unittest\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(
            any(
                f.path == SELF_TEST_PATH and "maintainer-controlled" in f.reason
                for f in findings
            )
        )

    def test_external_composite_action_change_is_blocked(self) -> None:
        """Composite actions run from the PR head in privileged workflows."""
        path = self.repo / ".github" / "actions" / "setup-flutter" / "action.yml"
        path.parent.mkdir(parents=True)
        path.write_text("runs:\n  using: composite\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(
            any(
                f.path == ".github/actions/setup-flutter/action.yml"
                and "maintainer-controlled" in f.reason
                for f in findings
            )
        )

    def test_owner_can_change_a_composite_action(self) -> None:
        path = self.repo / ".github" / "actions" / "setup-flutter" / "action.yml"
        path.parent.mkdir(parents=True)
        path.write_text("runs:\n  using: composite\n", encoding="utf-8")
        findings = self.scan(self.commit(), author="TheZupZup")
        self.assertEqual(findings, [])

    def test_negated_vscode_ignore_is_blocked(self) -> None:
        """Git applies the last matching rule, so a later `!` undoes the entry."""
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n!.vscode/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("re-enabled by" in f.reason for f in findings))

    def test_glob_negation_of_a_protected_ignore_is_blocked(self) -> None:
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n!.vs*\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("re-enabled by" in f.reason for f in findings))

    def test_recursive_glob_negation_is_blocked(self) -> None:
        """Git applies `**/` at every depth, including the repository root."""
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n!**/.vscode/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("re-enabled by" in f.reason for f in findings))

    def test_catch_all_negation_is_blocked(self) -> None:
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n!*\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("re-enabled by" in f.reason for f in findings))

    def test_negation_before_the_entry_is_harmless(self) -> None:
        """Order matters: the positive entry comes last, so it wins."""
        (self.repo / ".gitignore").write_text(".idea/\n!.vscode/\n.vscode/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_unrelated_negation_is_allowed(self) -> None:
        (self.repo / ".gitignore").write_text(
            ".idea/\n.vscode/\nbuild/\n!build/keep.txt\n", encoding="utf-8"
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_removing_vscode_ignore_is_blocked(self) -> None:
        (self.repo / ".gitignore").write_text(".idea/\n", encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("`.vscode/` was removed" in f.reason for f in findings))

    def test_external_symlink_is_blocked(self) -> None:
        os.symlink("lib/main.dart", self.repo / "shortcut")
        findings = self.scan(self.commit())
        self.assertTrue(any("Git symlink" in f.reason for f in findings))

    def test_svg_animation_event_handler_is_blocked(self) -> None:
        """Handlers outside the old five-name allowlist still execute."""
        path = self.repo / "assets" / "anim.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg"><animate onbegin="alert(1)"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_entity_encoded_javascript_url_is_blocked(self) -> None:
        """An XML parser resolves `java&#x73;cript:` before the link is used."""
        path = self.repo / "assets" / "entity.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<a href="java&#x73;cript:alert(1)"><rect width="1" height="1"/></a></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_decimal_entity_encoded_javascript_url_is_blocked(self) -> None:
        path = self.repo / "assets" / "decimal.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<a href="java&#115;cript:alert(1)"><rect width="1" height="1"/></a></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_tab_encoded_javascript_scheme_is_blocked(self) -> None:
        """URL parsing discards embedded tabs before resolving the scheme."""
        path = self.repo / "assets" / "tab.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<a href="java&#x09;script:alert(1)"><rect width="1" height="1"/></a></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_newline_encoded_javascript_scheme_is_blocked(self) -> None:
        path = self.repo / "assets" / "nl.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<a href="java&#x0a;script:alert(1)"><rect width="1" height="1"/></a></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_svg_text_node_mentioning_a_scheme_is_not_flagged(self) -> None:
        """Prose is not a URL: the normalised pass is anchored to href."""
        path = self.repo / "assets" / "prose.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<text>Use java&#x09;script: for this</text>'
            '<text>java&#x0a;script:</text><rect width="1" height="1"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_svg_text_split_across_lines_is_not_flagged(self) -> None:
        """Control stripping must not join unrelated tokens into a false match."""
        path = self.repo / "assets" / "split.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">\n'
            '<desc>java</desc>\n<desc>script: release notes</desc>\n'
            '<rect width="1" height="1"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_svg_with_harmless_entities_passes(self) -> None:
        """Decoding must not turn ordinary escaped text into a false positive."""
        path = self.repo / "assets" / "amp.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg">'
            '<title>Tools &amp; Settings &#8212; v1</title><rect width="1" height="1"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_inert_svg_passes(self) -> None:
        path = self.repo / "assets" / "ok.svg"
        path.parent.mkdir()
        path.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" version="1.1">'
            '<rect width="10" height="10" fill="#0088cc"/></svg>',
            encoding="utf-8",
        )
        findings = self.scan(self.commit())
        self.assertEqual(findings, [])

    def test_active_svg_is_blocked(self) -> None:
        path = self.repo / "assets" / "bad.svg"
        path.parent.mkdir()
        path.write_text('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>', encoding="utf-8")
        findings = self.scan(self.commit())
        self.assertTrue(any("SVG contains active" in f.reason for f in findings))

    def test_prohibited_history_survives_cleanup_and_update_branch_merge(self) -> None:
        """Regression for #513: an empty final diff must not erase PR history."""
        git(self.repo, "switch", "-c", "pr")
        payload = self.repo / "assets" / "payload.png"
        payload.parent.mkdir()
        payload.write_text("#!/bin/sh\necho payload\n", encoding="utf-8")
        prohibited = self.commit("A: introduce prohibited payload")
        payload.unlink()
        self.commit("B: clean payload")

        git(self.repo, "switch", "main")
        (self.repo / "README.md").write_text("trusted update\n", encoding="utf-8")
        self.base = self.commit("trusted main update")
        git(self.repo, "switch", "pr")
        git(self.repo, "merge", "--no-ff", "main", "-m", "C: Update branch")
        merge = git(self.repo, "rev-parse", "HEAD")

        self.assertEqual(git(self.repo, "diff", "--name-only", f"{self.base}...{merge}"), "")
        findings = self.scan(merge)
        historical = [finding for finding in findings if finding.commit == prohibited]
        self.assertTrue(any(f.path == "assets/payload.png" for f in historical))
        self.assertFalse(any(f.commit == merge for f in findings))

    def test_pr_513_contamination_survives_a_fully_clean_final_diff(self) -> None:
        """The #513/#514/#515 incident, reproduced with its real finding shapes.

        External PR #513 attributed every violation to bd48e57df55ed0cde25170e4
        baa53314bd2187e8 while its final diff against main was empty. The
        commit SHA differs here because the fixture history is built fresh, but
        the property that matters is the same one: attribution survives cleanup
        plus an Update-branch merge, so a zero-file diff still blocks.
        """
        git(self.repo, "switch", "-c", "pr")
        workspace = self.repo / ".vscode"
        workspace.mkdir()
        # The .gitignore change is what let the workspace files be committed.
        (self.repo / ".gitignore").write_text(".idea/\n", encoding="utf-8")
        for name in ("extensions.json", "launch.json", "settings.json", "spellright.dict"):
            (workspace / name).write_text("{}\n", encoding="utf-8")
        (workspace / "tasks.json").write_text(ASSET_EXECUTION_PAYLOAD, encoding="utf-8")
        font = self.repo / "public" / "fonts" / "fa-solid-400.woff2"
        font.parent.mkdir(parents=True)
        font.write_text("this is not a font\n", encoding="utf-8")
        contaminated = self.commit("A: import IDE workspace and vendored assets")

        # Cleanup: every prohibited path removed and the ignore rule restored.
        for entry in sorted(workspace.iterdir()):
            entry.unlink()
        workspace.rmdir()
        font.unlink()
        (self.repo / ".gitignore").write_text(".idea/\n.vscode/\n", encoding="utf-8")
        self.commit("B: revert the workspace import")

        git(self.repo, "switch", "main")
        (self.repo / "README.md").write_text("trusted update\n", encoding="utf-8")
        self.base = self.commit("trusted main update")
        git(self.repo, "switch", "pr")
        git(self.repo, "merge", "--no-ff", "main", "-m", "C: Update branch")
        head = git(self.repo, "rev-parse", "HEAD")

        # The state the reporter has to explain: zero changed files, still blocked.
        self.assertEqual(git(self.repo, "diff", "--name-only", f"{self.base}...{head}"), "")
        findings = self.scan(head)
        self.assertTrue(findings)
        attributed = {f.path for f in findings if f.commit == contaminated}
        for path in (".gitignore", ".vscode/extensions.json", ".vscode/launch.json",
                     ".vscode/settings.json", ".vscode/spellright.dict",
                     ".vscode/tasks.json", "public/fonts/fa-solid-400.woff2"):
            self.assertIn(path, attributed)
        reasons = {f.reason for f in findings if f.commit == contaminated}
        self.assertTrue(any("asset file as executable" in reason for reason in reasons))
        self.assertTrue(any("file extension claims" in reason for reason in reasons))
        self.assertTrue(all(f.severity == "blocked" for f in findings))
        # The Update-branch merge copies content unchanged, so it is not blamed.
        self.assertNotIn(head, {f.commit for f in findings})

    def test_ordinary_multi_commit_pr_passes(self) -> None:
        (self.repo / "lib" / "first.dart").write_text("const first = 1;\n", encoding="utf-8")
        self.commit("first")
        (self.repo / "lib" / "second.dart").write_text("const second = 2;\n", encoding="utf-8")
        self.assertEqual(self.scan(self.commit("second")), [])

    def test_legitimate_commit_followed_by_cleanup_passes(self) -> None:
        note = self.repo / "notes.txt"
        note.write_text("temporary note\n", encoding="utf-8")
        self.commit("add note")
        note.unlink()
        self.assertEqual(self.scan(self.commit("remove note")), [])

    def test_update_branch_merge_from_trusted_main_passes(self) -> None:
        git(self.repo, "switch", "-c", "pr")
        (self.repo / "lib" / "feature.dart").write_text("const feature = true;\n", encoding="utf-8")
        self.commit("feature")
        git(self.repo, "switch", "main")
        (self.repo / "README.md").write_text("trusted update\n", encoding="utf-8")
        self.base = self.commit("trusted main update")
        git(self.repo, "switch", "pr")
        git(self.repo, "merge", "--no-ff", "main", "-m", "Update branch")
        self.assertEqual(self.scan(git(self.repo, "rev-parse", "HEAD")), [])

    def test_prohibited_commit_in_trusted_base_does_not_poison_pr(self) -> None:
        payload = self.repo / "assets" / "legacy.png"
        payload.parent.mkdir()
        payload.write_text("legacy text payload\n", encoding="utf-8")
        self.base = self.commit("trusted legacy state")
        (self.repo / "lib" / "feature.dart").write_text("const feature = true;\n", encoding="utf-8")
        self.assertEqual(self.scan(self.commit("unrelated feature")), [])

    def test_linear_prohibited_then_cleaned_history_fails(self) -> None:
        payload = self.repo / "assets" / "linear.png"
        payload.parent.mkdir()
        payload.write_text("not really an image\n", encoding="utf-8")
        prohibited = self.commit("prohibited")
        payload.unlink()
        findings = self.scan(self.commit("cleanup"))
        self.assertTrue(any(f.commit == prohibited and f.path == "assets/linear.png" for f in findings))

    def test_squashed_clean_history_passes(self) -> None:
        """A clean squash introduces no prohibited commit object to main."""
        (self.repo / "lib" / "squashed.dart").write_text("const clean = true;\n", encoding="utf-8")
        self.assertEqual(self.scan(self.commit("squashed clean feature")), [])

    def test_pr_side_merge_reports_unique_offender_once_not_merge(self) -> None:
        git(self.repo, "switch", "-c", "side")
        payload = self.repo / "assets" / "side.png"
        payload.parent.mkdir()
        payload.write_text("not really an image\n", encoding="utf-8")
        prohibited = self.commit("side payload")
        git(self.repo, "switch", "-c", "pr", self.base)
        (self.repo / "lib" / "feature.dart").write_text("const feature = true;\n", encoding="utf-8")
        self.commit("feature")
        git(self.repo, "merge", "--no-ff", "side", "-m", "merge side")
        merge = git(self.repo, "rev-parse", "HEAD")
        findings = self.scan(merge)
        matches = [f for f in findings if f.path == "assets/side.png"]
        self.assertEqual([f.commit for f in matches], [prohibited])
        self.assertNotIn(merge, [f.commit for f in findings])

    def test_novel_prohibited_merge_resolution_is_scanned(self) -> None:
        git(self.repo, "switch", "-c", "side")
        (self.repo / "lib" / "side.dart").write_text("const side = true;\n", encoding="utf-8")
        self.commit("side")
        git(self.repo, "switch", "-c", "pr", self.base)
        (self.repo / "lib" / "feature.dart").write_text("const feature = true;\n", encoding="utf-8")
        self.commit("feature")
        git(self.repo, "merge", "--no-ff", "--no-commit", "side")
        payload = self.repo / "assets" / "resolution.png"
        payload.parent.mkdir()
        payload.write_text("not really an image\n", encoding="utf-8")
        merge = self.commit("merge with novel resolution")
        findings = self.scan(merge)
        self.assertTrue(
            any(f.commit == merge and f.path == "assets/resolution.png" for f in findings)
        )

    def test_over_long_paths_stay_within_the_reporter_field_bound(self) -> None:
        """Git accepts paths longer than the reporter's per-field limit.

        Emitting one unclamped sinks the whole artifact, so the reporter fails
        and an earlier CLEAN comment can survive a blocking revision.
        """
        deep = self.repo / "scripts"
        for i in range(9):
            deep = deep / (f"d{i}" + "x" * 247)
        deep.mkdir(parents=True)
        (deep / "s.sh").write_text("echo hi\n", encoding="utf-8")
        commit = self.commit("deep protected path")
        findings = self.scan(commit)
        raw = next(f for f in findings if f.path.endswith("/s.sh"))
        self.assertGreater(len(raw.path), integrity.MAX_REPORT_FIELD_CHARS)
        emitted = raw.as_dict()
        self.assertLessEqual(len(emitted["path"]), integrity.MAX_REPORT_FIELD_CHARS)
        # The tail identifies the offender, so it must survive the clamp.
        self.assertTrue(emitted["path"].endswith("/s.sh"))
        self.assertTrue(emitted["path"].startswith("...[truncated]"))

    def test_report_names_commit_path_and_reason(self) -> None:
        path = self.repo / "assets" / "report.png"
        path.parent.mkdir()
        path.write_text("not really an image\n", encoding="utf-8")
        commit = self.commit("report payload")
        findings = self.scan(commit)
        report = self.repo / "report.md"
        integrity.write_report(report, findings)
        text = report.read_text(encoding="utf-8")
        self.assertIn(commit, text)
        self.assertIn("assets/report.png", text)
        self.assertIn("file extension claims PNG", text)


class FixtureExemptionTest(unittest.TestCase):
    """The narrow carve-out that lets this module hold literal attack strings."""

    def test_payload_is_detected_at_an_ordinary_path(self) -> None:
        finding = integrity.asset_execution_finding("docs/note.txt", ASSET_EXECUTION_PAYLOAD)
        self.assertIsNotNone(finding)

    def test_shell_source_commands_for_assets_are_detected(self) -> None:
        for command in (
            asset_command("source assets/payload.", "png"),
            asset_command(". assets/payload.", "woff2"),
        ):
            with self.subTest(command):
                self.assertIsNotNone(
                    integrity.asset_execution_finding("docs/note.txt", command)
                )

    def test_dot_used_as_an_argument_is_not_asset_execution(self) -> None:
        self.assertIsNone(
            integrity.asset_execution_finding(
                "docs/note.txt", asset_command("jq . assets/data.", "png")
            )
        )

        self.assertIsNone(
            integrity.asset_execution_finding(
                "docs/note.txt", asset_command("source config.", "env")
            )
        )

    def test_numeric_chmod_that_grants_execute_is_detected(self) -> None:
        for mode in ("755", "775", "700", "0755", "0711"):
            with self.subTest(mode):
                command = asset_command("chmod ", mode, " assets/payload.", "png")
                self.assertIsNotNone(
                    integrity.asset_execution_finding("docs/note.txt", command)
                )

    def test_numeric_chmod_without_execute_is_allowed(self) -> None:
        for mode in ("644", "664", "600", "0444", "0000"):
            with self.subTest(mode):
                command = asset_command("chmod ", mode, " assets/image.", "png")
                self.assertIsNone(
                    integrity.asset_execution_finding("docs/note.txt", command)
                )

    def test_backslash_newline_cannot_split_asset_extension_or_path(self) -> None:
        for command in (
            asset_command("node assets/payload.wo", "\\\n", "ff2"),
            asset_command("source assets/pa", "\\\n", "yload.png"),
            asset_command("chmod 7", "\\\n", "55 assets/payload.png"),
        ):
            with self.subTest(command):
                self.assertIsNotNone(
                    integrity.asset_execution_finding("docs/note.txt", command)
                )

    def test_ordinary_multiline_content_stays_allowed(self) -> None:
        text = asset_command("printf '%s\\n' assets/image.", "png", "\necho done\n")
        self.assertIsNone(integrity.asset_execution_finding("docs/note.txt", text))

    def test_marker_does_not_exempt_an_ordinary_path(self) -> None:
        finding = integrity.asset_execution_finding("docs/note.txt", MARKED_PAYLOAD_LINE)
        self.assertIsNotNone(finding)

    def test_marker_exempts_only_the_line_that_carries_it(self) -> None:
        text = f"{MARKED_PAYLOAD_LINE}\n{ASSET_EXECUTION_PAYLOAD}"
        self.assertIsNone(integrity.asset_execution_finding(SELF_TEST_PATH, MARKED_PAYLOAD_LINE))
        self.assertIsNotNone(integrity.asset_execution_finding(SELF_TEST_PATH, text))

    def test_marker_cannot_be_smuggled_across_a_line_break(self) -> None:
        text = f"{integrity.FIXTURE_EXEMPTION_MARKER}\n{ASSET_EXECUTION_PAYLOAD}"
        self.assertIsNotNone(integrity.asset_execution_finding(SELF_TEST_PATH, text))

    def test_this_module_does_not_trip_the_repository_wide_scan(self) -> None:
        source = (ROOT / SELF_TEST_PATH).read_text(encoding="utf-8")
        self.assertIn(ASSET_EXECUTION_PAYLOAD.strip(), source, "fixture literal went missing")
        self.assertIsNone(integrity.asset_execution_finding(SELF_TEST_PATH, source))
        self.assertIsNotNone(integrity.asset_execution_finding("docs/note.txt", source))

    def test_checker_source_does_not_trip_the_repository_wide_scan(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIsNone(
            integrity.asset_execution_finding("scripts/check_repository_integrity.py", source)
        )


if __name__ == "__main__":
    unittest.main()
