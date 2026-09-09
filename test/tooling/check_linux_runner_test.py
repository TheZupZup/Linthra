#!/usr/bin/env python3
"""Unit tests for scripts/check_linux_runner.py (#376, PR 1).

    python3 test/tooling/check_linux_runner_test.py

The checker's job is to notice when the committed Linux runner drifts from the
app's identity — most plausibly because someone re-ran
`flutter create --platforms=linux .` and the template overwrote it. So the tests
are mostly "take a good checkout, break exactly one thing, expect it to be
caught", built on a synthetic checkout rather than the real one: a fixture that
can be broken is the only way to prove the checker fails when it should, and it
keeps these tests from depending on Linthra's current version or app id.

The window identity calls (#554) are tested the same way as well: the runner is
what tells Wayland and X11 which application the window belongs to, so each case
takes a good runner and removes, duplicates, comments out, hardcodes or reorders
exactly one of those calls. All of them still compile and still launch, which is
why only a check like this notices.

The desktop entry (#434) is tested the same way, and for the same reason: a
`.desktop` file that names the wrong binary, the wrong icon or the wrong app id
is still a perfectly valid desktop file, so only a comparison against the app's
own identity catches it. The application icon (#436) is the other half of that
pair: `Icon=` is a theme name, so nothing but a comparison notices when the
installed file stops answering to it.

One test does run against the real repository, because "the checker passes on
the actual runner" is the thing the CI job cares about.

Everything is offline. No network, no git, no repository writes.
"""

from __future__ import annotations

import base64
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

sys.path.insert(0, str(SCRIPTS))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


checker = _load("check_linux_runner", "check_linux_runner.py")


APP_ID = "io.example.app"
BINARY = "exampleapp"
DISPLAY_NAME = "ExampleApp"

CMAKELISTS = """\
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

set(BINARY_NAME "{binary}")
set(APPLICATION_ID "{app_id}")

set(LINTHRA_SQLITE3_SOURCE_DIR "$ENV{{LINTHRA_SQLITE3_SOURCE_DIR}}" CACHE PATH "")
if(LINTHRA_SQLITE3_SOURCE_DIR)
  set(FETCHCONTENT_SOURCE_DIR_SQLITE3 "${{LINTHRA_SQLITE3_SOURCE_DIR}}"
    CACHE PATH "" FORCE)
endif()

include(flutter/generated_plugins.cmake)

if(TARGET flutter_secure_storage_linux_plugin AND
   CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  target_compile_options(flutter_secure_storage_linux_plugin PRIVATE
    -Wno-error=deprecated-literal-operator)
endif()
"""

# The runner, reduced to what the checker reads. The identity calls (#554) are
# part of the fixture rather than an optional extra: they are what makes the
# running window answer to the application id, and every WindowIdentityTest case
# below is this same text with exactly one of them broken.
MY_APPLICATION = """\
#include "my_application.h"

#include "folder_picker_channel.h"
#include "window_lifecycle_channel.h"

static constexpr const char* kApplicationName = "{display_name}";
static constexpr int kDefaultWindowWidth = 1180;
static constexpr int kDefaultWindowHeight = 780;
static constexpr int kMinimumWindowWidth = 420;
static constexpr int kMinimumWindowHeight = 600;

static void activate() {{
  if (window_lifecycle_channel_present(self->window_lifecycle)) {{
    return;
  }}
  self->folder_picker = folder_picker_channel_new(view, window);
  self->window_lifecycle = window_lifecycle_channel_new(view, window);
  if (self->window_state != nullptr) {{
    window_state_store_save(self->window_state);
  }}
  self->window_state =
      window_state_store_new(window, kMinimumWindowWidth, kMinimumWindowHeight,
                             kDefaultWindowWidth, kDefaultWindowHeight);
}}

static void my_application_shutdown(GApplication* application) {{
  window_state_store_save(self->window_state);
}}

static void my_application_startup(GApplication* application) {{
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  g_set_application_name(kApplicationName);
  gdk_set_program_class(APPLICATION_ID);
  gtk_window_set_default_icon_name(APPLICATION_ID);
}}

MyApplication* my_application_new() {{
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}}
"""

# The runner's own build file, which has to compile the folder-picker source
# (#438) for the channel to exist at all.
RUNNER_CMAKELISTS = """\
add_executable(${{BINARY_NAME}}
  "main.cc"
  "my_application.cc"
  "folder_picker_channel.cc"
  "window_lifecycle_channel.cc"
  "window_state_store.cc"
  "${{CMAKE_SOURCE_DIR}}/../native/linthra_desktop/src/window_state.cpp"
)

target_compile_features(${{BINARY_NAME}} PUBLIC cxx_std_17)
"""

# The two halves of the folder-picker channel, reduced to the strings the
# checker compares. A rename on either side is invisible at build time and
# turns every pick into a silent fallback, which inside the Flatpak means no
# chooser at all.
FOLDER_PICKER_CHANNEL = """\
static constexpr const char* kChannelName =
    "{channel}";
static constexpr const char* kPickFolderMethod = "{method}";
"""

FOLDER_PICKER_DART = """\
class MethodChannelLinuxFolderPicker implements FolderPickerService {{
  static const String channelName =
      '{channel}';
  static const String pickFolderMethod = '{method}';
}}
"""

FOLDER_PICKER_CHANNEL_NAME = f"{APP_ID}/linux_folder_picker"
FOLDER_PICKER_METHOD_NAME = "pickFolder"

# The two halves of the window-lifecycle channel (#401). Drift here is quieter
# than the folder picker's: the app still runs, every close still destroys the
# window, and the close-behaviour preference in Settings simply stops meaning
# anything.
WINDOW_LIFECYCLE_CHANNEL = """\
static constexpr const char* kChannelName =
    "{channel}";
static constexpr const char* kSetHideOnCloseMethod = "{set_hide_on_close}";
static constexpr const char* kShowWindowMethod = "showWindow";
static constexpr const char* kQuitMethod = "quit";
static constexpr const char* kWindowHiddenMethod = "windowHidden";
static constexpr const char* kWindowShownMethod = "windowShown";
static constexpr const char* kHideOnCloseArgument = "hideOnClose";
"""

WINDOW_LIFECYCLE_DART = """\
class MethodChannelLinuxWindow implements DesktopWindowController {{
  static const String channelName =
      '{channel}';
  static const String setHideOnCloseMethod = '{set_hide_on_close}';
  static const String showWindowMethod = 'showWindow';
  static const String quitMethod = 'quit';
  static const String windowHiddenMethod = 'windowHidden';
  static const String windowShownMethod = 'windowShown';
  static const String hideOnCloseArgument = 'hideOnClose';
}}
"""

WINDOW_LIFECYCLE_CHANNEL_NAME = f"{APP_ID}/linux_window_lifecycle"
WINDOW_LIFECYCLE_SET_METHOD = "setHideOnClose"

BUILD_GRADLE = """\
android {{
    namespace = "{app_id}"
    defaultConfig {{
        applicationId = "{app_id}"
    }}
}}
"""

PUBSPEC = """\
name: {binary}
description: An example.
version: 1.2.3+10203
"""

APP_INFO = """\
abstract final class AppInfo {{
  static const String name = '{display_name}';
  static const String tagline = 'Example.';
}}
"""

DESKTOP_ENTRY = """\
# A comment, which the reader has to skip rather than parse.
[Desktop Entry]
Type=Application
Name={display_name}
GenericName=Music Player
Comment=An example.
Exec={binary}
Icon={app_id}
Terminal=false
Categories=AudioVideo;Audio;Player;Music;
StartupNotify=true
StartupWMClass={app_id}
"""

# A minimal but structurally real SVG: a self-contained mark whose only
# references are internal fragments (`url(#g)`), which is what the icon check
# has to accept while rejecting anything reaching outside the file.
ICON_SVG = """\
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"
     viewBox="0 0 512 512">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#9C84FF" />
      <stop offset="1" stop-color="#FF9F43" />
    </linearGradient>
  </defs>
  <rect x="64" y="64" width="384" height="384" rx="96" fill="url(#g)" />
</svg>
"""

# Only the parts of a Flatpak manifest this checker reads. Both the
# hand-authored template and the file generated from it are written from this,
# because the check exists precisely to catch the two disagreeing.
FLATPAK_MANIFEST = """\
app-id: {app_id}
command: {binary}
finish-args:
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  - --device=dri
  - --socket=pulseaudio
  - --share=network
  - --own-name=org.mpris.MediaPlayer2.linthra
  - --own-name=org.mpris.MediaPlayer2.linthra.*
modules:
  - name: {binary}
    buildsystem: simple
    build-commands:
      - install -d /app/bin
      - install -Dm644 linux/packaging/{app_id}.desktop /app/share/applications/{app_id}.desktop
      - install -Dm644 tool/branding/linthra_icon.svg /app/share/icons/hicolor/scalable/apps/{app_id}.svg
      - install -Dm644 linux/packaging/icons/hicolor/48x48/apps/{app_id}.png /app/share/icons/hicolor/48x48/apps/{app_id}.png
      - install -Dm644 linux/packaging/icons/hicolor/64x64/apps/{app_id}.png /app/share/icons/hicolor/64x64/apps/{app_id}.png
      - install -Dm644 linux/packaging/icons/hicolor/128x128/apps/{app_id}.png /app/share/icons/hicolor/128x128/apps/{app_id}.png
      - install -Dm644 linux/packaging/icons/hicolor/256x256/apps/{app_id}.png /app/share/icons/hicolor/256x256/apps/{app_id}.png
      - install -Dm644 linux/packaging/{app_id}.metainfo.xml /app/share/metainfo/{app_id}.metainfo.xml
"""

# The install step the icon tests remove or rewrite, kept in one place so the
# fixture and the assertions cannot drift apart.
ICON_INSTALL_LINE = (
    "      - install -Dm644 tool/branding/linthra_icon.svg "
    "/app/share/icons/hicolor/scalable/apps/{app_id}.svg\n"
)

# The raster sizes the checker requires alongside the scalable icon, and the
# install step for one of them — the window icon's half of the same set.
RASTER_ICON_SIZES = (48, 64, 128, 256)
RASTER_ICON_INSTALL_LINE = (
    "      - install -Dm644 linux/packaging/icons/hicolor/{size}x{size}/apps/{app_id}.png "
    "/app/share/icons/hicolor/{size}x{size}/apps/{app_id}.png\n"
)

# A one-pixel PNG: the checker only asks whether each raster exists, so the
# fixture writes the smallest real file rather than rendering the brand mark.
ONE_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM"
    "IQAAAABJRU5ErkJggg=="
)

METAINFO_XML = """\
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>{app_id}</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>AGPL-3.0-or-later</project_license>
  <name>{display_name}</name>
  <summary>An example.</summary>
  <description>
    <p>An example music player for local files and a self-hosted server.</p>
  </description>
  <launchable type="desktop-id">{app_id}.desktop</launchable>
  <icon type="stock">{app_id}</icon>
</component>
"""

METAINFO_INSTALL_LINE = (
    "      - install -Dm644 linux/packaging/{app_id}.metainfo.xml "
    "/app/share/metainfo/{app_id}.metainfo.xml\n"
)


def build_checkout(
    directory: Path,
    *,
    cmakelists: str | None = None,
    my_application: str | None = None,
    build_gradle: str | None = None,
    pubspec: str | None = None,
    app_info: str | None = None,
    desktop_entry: str | None = None,
    desktop_entry_name: str | None = None,
    flatpak_manifest: str | None = None,
    icon_svg: str | None = None,
    write_icon: bool = True,
    write_raster_icons: bool = True,
    runner_cmakelists: str | None = None,
    folder_picker_channel: str | None = None,
    folder_picker_dart: str | None = None,
    window_lifecycle_channel: str | None = None,
    window_lifecycle_dart: str | None = None,
) -> Path:
    """Write a minimal, internally consistent checkout the checker can read."""
    (directory / "linux" / "runner").mkdir(parents=True, exist_ok=True)
    (directory / "linux" / "packaging").mkdir(parents=True, exist_ok=True)
    (directory / "flatpak").mkdir(parents=True, exist_ok=True)
    (directory / "tool" / "branding").mkdir(parents=True, exist_ok=True)
    (directory / "android" / "app").mkdir(parents=True, exist_ok=True)
    (directory / "lib" / "core").mkdir(parents=True, exist_ok=True)
    (directory / "lib" / "core" / "services").mkdir(parents=True, exist_ok=True)

    (directory / "linux" / "CMakeLists.txt").write_text(
        cmakelists
        if cmakelists is not None
        else CMAKELISTS.format(binary=BINARY, app_id=APP_ID),
        encoding="utf-8",
    )
    (directory / "linux" / "runner" / "my_application.cc").write_text(
        my_application
        if my_application is not None
        else MY_APPLICATION.format(display_name=DISPLAY_NAME),
        encoding="utf-8",
    )
    runner = directory / "linux" / "runner"
    (runner / "CMakeLists.txt").write_text(
        runner_cmakelists if runner_cmakelists is not None else RUNNER_CMAKELISTS,
        encoding="utf-8",
    )
    (runner / "folder_picker_channel.cc").write_text(
        folder_picker_channel
        if folder_picker_channel is not None
        else FOLDER_PICKER_CHANNEL.format(
            channel=FOLDER_PICKER_CHANNEL_NAME, method=FOLDER_PICKER_METHOD_NAME
        ),
        encoding="utf-8",
    )
    (
        directory
        / "lib"
        / "core"
        / "services"
        / "method_channel_linux_folder_picker.dart"
    ).write_text(
        folder_picker_dart
        if folder_picker_dart is not None
        else FOLDER_PICKER_DART.format(
            channel=FOLDER_PICKER_CHANNEL_NAME, method=FOLDER_PICKER_METHOD_NAME
        ),
        encoding="utf-8",
    )
    (runner / "window_lifecycle_channel.cc").write_text(
        window_lifecycle_channel
        if window_lifecycle_channel is not None
        else WINDOW_LIFECYCLE_CHANNEL.format(
            channel=WINDOW_LIFECYCLE_CHANNEL_NAME,
            set_hide_on_close=WINDOW_LIFECYCLE_SET_METHOD,
        ),
        encoding="utf-8",
    )
    (
        directory / "lib" / "core" / "services" / "method_channel_linux_window.dart"
    ).write_text(
        window_lifecycle_dart
        if window_lifecycle_dart is not None
        else WINDOW_LIFECYCLE_DART.format(
            channel=WINDOW_LIFECYCLE_CHANNEL_NAME,
            set_hide_on_close=WINDOW_LIFECYCLE_SET_METHOD,
        ),
        encoding="utf-8",
    )
    (directory / "android" / "app" / "build.gradle").write_text(
        build_gradle
        if build_gradle is not None
        else BUILD_GRADLE.format(app_id=APP_ID),
        encoding="utf-8",
    )
    (directory / "pubspec.yaml").write_text(
        pubspec if pubspec is not None else PUBSPEC.format(binary=BINARY),
        encoding="utf-8",
    )
    (directory / "lib" / "core" / "app_info.dart").write_text(
        app_info
        if app_info is not None
        else APP_INFO.format(display_name=DISPLAY_NAME),
        encoding="utf-8",
    )
    packaging = directory / "linux" / "packaging"
    (packaging / (desktop_entry_name or f"{APP_ID}.desktop")).write_text(
        desktop_entry
        if desktop_entry is not None
        else DESKTOP_ENTRY.format(
            display_name=DISPLAY_NAME, binary=BINARY, app_id=APP_ID
        ),
        encoding="utf-8",
    )
    manifest = (
        flatpak_manifest
        if flatpak_manifest is not None
        else FLATPAK_MANIFEST.format(app_id=APP_ID, binary=BINARY)
    )
    (directory / "flatpak" / "flatpak-flutter.yml").write_text(
        FLATPAK_MANIFEST.format(app_id=APP_ID, binary=BINARY), encoding="utf-8"
    )
    (directory / "flatpak" / f"{APP_ID}.yml").write_text(manifest, encoding="utf-8")
    if write_icon:
        (directory / "tool" / "branding" / "linthra_icon.svg").write_text(
            icon_svg if icon_svg is not None else ICON_SVG, encoding="utf-8"
        )
    if write_raster_icons:
        for size in RASTER_ICON_SIZES:
            raster = (
                directory
                / "linux"
                / "packaging"
                / "icons"
                / "hicolor"
                / f"{size}x{size}"
                / "apps"
                / f"{APP_ID}.png"
            )
            raster.parent.mkdir(parents=True, exist_ok=True)
            raster.write_bytes(ONE_PIXEL_PNG)
    (packaging / f"{APP_ID}.metainfo.xml").write_text(
        METAINFO_XML.format(app_id=APP_ID, display_name=DISPLAY_NAME),
        encoding="utf-8",
    )
    return directory


class CheckoutCase(unittest.TestCase):
    """Base class giving each test a fresh throwaway checkout."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)


class ConsistentCheckoutTest(CheckoutCase):
    def test_a_consistent_checkout_has_no_problems(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.check(self.root), [])

    def test_main_exits_zero(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.main(["--root", str(self.root)]), 0)


class IdentityDriftTest(CheckoutCase):
    def test_application_id_must_match_android(self) -> None:
        build_checkout(
            self.root,
            cmakelists=CMAKELISTS.format(binary=BINARY, app_id="com.example.other"),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("APPLICATION_ID", problems[0])
        self.assertIn("com.example.other", problems[0])

    def test_binary_name_must_match_the_package_name(self) -> None:
        build_checkout(
            self.root,
            cmakelists=CMAKELISTS.format(binary="renamed", app_id=APP_ID),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("BINARY_NAME", problems[0])

    def test_window_title_must_match_app_info(self) -> None:
        # The regression a template regeneration actually causes: the title
        # goes back to the lowercase package name.
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=BINARY),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("kApplicationName", problems[0])

    def test_a_wholly_regenerated_runner_is_caught(self) -> None:
        # The full template restoration: lowercase title, no size constants.
        build_checkout(
            self.root,
            my_application='  gtk_window_set_title(window, "exampleapp");\n',
        )
        with self.assertRaises(checker.CheckError):
            checker.check(self.root)

    def test_several_problems_are_all_reported(self) -> None:
        build_checkout(
            self.root,
            cmakelists=CMAKELISTS.format(binary="renamed", app_id="com.example.other"),
            my_application=MY_APPLICATION.format(display_name="Other"),
        )
        self.assertEqual(len(checker.check(self.root)), 3)


class WindowIdentityTest(CheckoutCase):
    """The calls that make the *running* window answer to the app id (#554).

    Everything the other tests cover is installed metadata; this is the window
    itself. Each case builds and launches perfectly, so the only symptom is a
    desktop that stops recognising Linthra: a generic icon, or a window that
    will not group with its own launcher.
    """

    def runner(self, *, replace: tuple[str, str] | None = None) -> str:
        text = MY_APPLICATION.format(display_name=DISPLAY_NAME)
        if replace is not None:
            old, new = replace
            assert old in text, old
            text = text.replace(old, new)
        return text

    def only_problem(self, runner: str) -> str:
        build_checkout(self.root, my_application=runner)
        problems = checker.runner_identity_problems(self.root)
        self.assertEqual(len(problems), 1, problems)
        return problems[0]

    def test_a_consistent_runner_has_no_identity_problems(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.runner_identity_problems(self.root), [])

    def test_losing_the_program_name_is_caught(self) -> None:
        # The Wayland half: GTK 3 sends xdg_toplevel.set_app_id() from
        # g_get_prgname(), so without this the app id GNOME and KDE match on is
        # the binary name.
        problem = self.only_problem(
            self.runner(replace=("  g_set_prgname(APPLICATION_ID);\n", ""))
        )
        self.assertIn("g_set_prgname", problem)

    def test_losing_the_program_class_is_caught(self) -> None:
        # The X11 half: without it WM_CLASS's class is the program name with
        # its first letter upper-cased, which no launcher indexes.
        problem = self.only_problem(
            self.runner(replace=("  gdk_set_program_class(APPLICATION_ID);\n", ""))
        )
        self.assertIn("gdk_set_program_class", problem)

    def test_losing_the_default_icon_name_is_caught(self) -> None:
        problem = self.only_problem(
            self.runner(
                replace=("  gtk_window_set_default_icon_name(APPLICATION_ID);\n", "")
            )
        )
        self.assertIn("gtk_window_set_default_icon_name", problem)
        self.assertIn("_NET_WM_ICON", problem)

    def test_losing_the_human_readable_name_is_caught(self) -> None:
        problem = self.only_problem(
            self.runner(replace=("  g_set_application_name(kApplicationName);\n", ""))
        )
        self.assertIn("g_set_application_name", problem)

    def test_the_program_class_may_not_run_before_the_chain_up(self) -> None:
        # gtk_init() resets GDK's program class unconditionally, and
        # GtkApplication::startup is what calls gtk_init(). Set before the chain
        # up, this call compiles, runs, and is thrown away.
        problem = self.only_problem(
            self.runner(
                replace=(
                    "  G_APPLICATION_CLASS(my_application_parent_class)"
                    "->startup(application);\n\n"
                    "  g_set_application_name(kApplicationName);\n"
                    "  gdk_set_program_class(APPLICATION_ID);\n",
                    "  gdk_set_program_class(APPLICATION_ID);\n"
                    "  G_APPLICATION_CLASS(my_application_parent_class)"
                    "->startup(application);\n\n"
                    "  g_set_application_name(kApplicationName);\n",
                )
            )
        )
        self.assertIn("gdk_set_program_class", problem)
        self.assertIn("before", problem)

    def test_the_icon_name_may_not_run_before_the_chain_up(self) -> None:
        problem = self.only_problem(
            self.runner(
                replace=(
                    "  G_APPLICATION_CLASS(my_application_parent_class)"
                    "->startup(application);\n",
                    "  gtk_window_set_default_icon_name(APPLICATION_ID);\n"
                    "  G_APPLICATION_CLASS(my_application_parent_class)"
                    "->startup(application);\n",
                )
            ).replace("  gtk_window_set_default_icon_name(APPLICATION_ID);\n}", "}")
        )
        self.assertIn("gtk_window_set_default_icon_name", problem)
        self.assertIn("before", problem)

    def test_the_program_name_must_be_set_before_gtk_init(self) -> None:
        # Moved into startup(), where GDK has already read the program name.
        problem = self.only_problem(
            self.runner(
                replace=("  g_set_prgname(APPLICATION_ID);\n\n  return", "\n  return")
            ).replace(
                "  g_set_application_name(kApplicationName);\n",
                "  g_set_application_name(kApplicationName);\n"
                "  g_set_prgname(APPLICATION_ID);\n",
            )
        )
        self.assertIn("g_set_prgname", problem)
        self.assertIn("my_application_new", problem)

    def test_a_hardcoded_application_id_is_rejected(self) -> None:
        # The id lives in linux/CMakeLists.txt and reaches the runner as the
        # APPLICATION_ID macro. A literal is a second copy that stops moving.
        build_checkout(
            self.root,
            my_application=self.runner(
                replace=(
                    "gdk_set_program_class(APPLICATION_ID)",
                    f'gdk_set_program_class("{APP_ID}")',
                )
            ),
        )
        problems = checker.runner_identity_problems(self.root)
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any("string literal" in problem for problem in problems))

    def test_a_call_named_only_in_a_comment_does_not_count(self) -> None:
        # A comment describing the call is not the call.
        problem = self.only_problem(
            self.runner(
                replace=(
                    "  gdk_set_program_class(APPLICATION_ID);\n",
                    "  // gdk_set_program_class(APPLICATION_ID);\n",
                )
            )
        )
        self.assertIn("gdk_set_program_class", problem)

    def test_a_duplicated_call_is_caught(self) -> None:
        problem = self.only_problem(
            self.runner(
                replace=(
                    "  gdk_set_program_class(APPLICATION_ID);\n",
                    "  gdk_set_program_class(APPLICATION_ID);\n"
                    "  gdk_set_program_class(APPLICATION_ID);\n",
                )
            )
        )
        self.assertIn("2 gdk_set_program_class", problem)

    def test_never_chaining_up_is_caught(self) -> None:
        # Without the chain up gtk_init() never runs at all, so the two
        # order-dependent calls have nothing to be ordered against.
        build_checkout(
            self.root,
            my_application=self.runner(
                replace=(
                    "  G_APPLICATION_CLASS(my_application_parent_class)"
                    "->startup(application);\n",
                    "",
                )
            ),
        )
        problems = checker.runner_identity_problems(self.root)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("chains up", problems[0])

    def test_a_runner_without_the_startup_handler_is_an_error(self) -> None:
        # A `flutter create` regeneration that drops the override entirely is a
        # read failure, not a silent pass.
        build_checkout(
            self.root,
            my_application=self.runner().replace(
                "static void my_application_startup(", "static void unrelated_thing("
            ),
        )
        with self.assertRaises(checker.CheckError):
            checker.runner_identity_problems(self.root)


class DesktopEntryTest(CheckoutCase):
    """The installed entry (#434) repeating the identity it launches.

    Every case here installs and validates fine as a desktop file; what breaks
    is the agreement with the app, which is exactly what nothing else notices.
    """

    def entry(self, **overrides: str) -> str:
        fields = {
            "display_name": DISPLAY_NAME,
            "binary": BINARY,
            "app_id": APP_ID,
            **overrides,
        }
        return DESKTOP_ENTRY.format(**fields)

    def test_the_name_must_match_app_info(self) -> None:
        build_checkout(self.root, desktop_entry=self.entry(display_name="Other"))
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("Name=", problems[0])

    def test_the_exec_must_be_the_binary_name(self) -> None:
        # The launcher entry pointing at something that is not the installed
        # binary: menu item present, click does nothing.
        build_checkout(self.root, desktop_entry=self.entry(binary="otherapp"))
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("Exec=", problems[0])

    def test_a_field_code_in_exec_is_rejected(self) -> None:
        # `%U` advertises a URI handler the app does not implement.
        build_checkout(self.root, desktop_entry=self.entry(binary=f"{BINARY} %U"))
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("Exec=", problems[0])

    def test_the_icon_must_be_the_app_id(self) -> None:
        # The icon file (#436) is installed under the app id; any other name
        # resolves to nothing and the entry shows a fallback icon forever.
        # Scoped to the entry's own problems: since #436 the icon check reports
        # this same rename from the other side (IconInstallTest), and this test
        # is about the entry disagreeing with the app's identity.
        build_checkout(
            self.root,
            desktop_entry=self.entry().replace(f"Icon={APP_ID}", "Icon=exampleapp"),
        )
        problems = checker.desktop_entry_problems(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("Icon=", problems[0])

    def test_the_startup_wm_class_must_be_the_app_id(self) -> None:
        # A shell trusts an exact StartupWMClass match ahead of every other
        # heuristic, so a value that is not the WM_CLASS the runner stamps sends
        # the window to the wrong entry, or to none at all.
        build_checkout(
            self.root,
            desktop_entry=self.entry().replace(
                f"StartupWMClass={APP_ID}", "StartupWMClass=ExampleApp"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("StartupWMClass=", problems[0])

    def test_a_missing_startup_wm_class_is_reported(self) -> None:
        build_checkout(
            self.root,
            desktop_entry=self.entry().replace(f"StartupWMClass={APP_ID}\n", ""),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no StartupWMClass=", problems[0])

    def test_a_missing_key_is_reported(self) -> None:
        build_checkout(
            self.root,
            desktop_entry=self.entry().replace(f"Icon={APP_ID}\n", ""),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no Icon=", problems[0])

    def test_audio_player_categories_are_required(self) -> None:
        build_checkout(
            self.root,
            desktop_entry=self.entry().replace(
                "Categories=AudioVideo;Audio;Player;Music;", "Categories=Utility;"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("Categories", problems[0])

    def test_extra_categories_are_allowed(self) -> None:
        build_checkout(
            self.root,
            desktop_entry=self.entry().replace(
                "Categories=AudioVideo;Audio;Player;Music;",
                "Categories=AudioVideo;Audio;Player;Music;Recorder;",
            ),
        )
        self.assertEqual(checker.check(self.root), [])

    def test_an_entry_not_named_for_the_app_id_is_not_found(self) -> None:
        # Flatpak exports `<app-id>.desktop` and nothing else, so a renamed
        # file is not a cosmetic difference — it is an entry that never ships.
        build_checkout(self.root, desktop_entry_name="exampleapp.desktop")
        with self.assertRaises(checker.CheckError):
            checker.check(self.root)

    def test_a_file_without_the_group_header_is_an_error(self) -> None:
        build_checkout(self.root, desktop_entry="Name=ExampleApp\n")
        with self.assertRaises(checker.CheckError):
            checker.check(self.root)


class DesktopEntryInstallTest(CheckoutCase):
    def test_a_generated_manifest_that_lost_the_install_step_is_caught(self) -> None:
        # The realistic failure: flatpak-flutter.yml gains the install step and
        # nobody re-runs scripts/regenerate_flatpak_sources.sh, so the manifest
        # flatpak-builder actually consumes still ships no desktop entry.
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace(
                f"      - install -Dm644 linux/packaging/{APP_ID}.desktop "
                f"/app/share/applications/{APP_ID}.desktop\n",
                "",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn(f"flatpak/{APP_ID}.yml", problems[0])
        self.assertIn("/app/share/applications", problems[0])

    def test_installing_somewhere_flatpak_does_not_export_is_caught(self) -> None:
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace("/app/share/applications/", "/app/share/"),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no desktop entry to export", problems[0])


class FlatpakPermissionTest(CheckoutCase):
    def test_generated_manifest_without_network_is_caught(self) -> None:
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace("  - --share=network\n", ""),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn(f"flatpak/{APP_ID}.yml", problems[0])
        self.assertIn("--share=network", problems[0])

    def test_unrelated_commented_filesystem_permission_is_caught(self) -> None:
        manifest = FLATPAK_MANIFEST.format(app_id=APP_ID, binary=BINARY).replace(
            "  - --share=network\n",
            "  - --share=network\n  - --filesystem=host # comment\n",
        )
        build_checkout(self.root, flatpak_manifest=manifest)
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("unrelated permission", problems[0])
        self.assertIn("--filesystem=host", problems[0])

    def test_unrelated_commented_dbus_permission_is_caught(self) -> None:
        manifest = FLATPAK_MANIFEST.format(app_id=APP_ID, binary=BINARY).replace(
            "  - --share=network\n",
            "  - --share=network\n  - --talk-name=org.example.Service # comment\n",
        )
        build_checkout(self.root, flatpak_manifest=manifest)
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("--talk-name=org.example.Service", problems[0])

    def test_the_secret_service_permission_is_not_granted(self) -> None:
        # #441 is served by the xdg-desktop-portal Secret portal, which needs
        # no finish-arg, so the direct Secret Service name is not shipped. If
        # someone adds it back, this list says so rather than absorbing it.
        self.assertNotIn(
            "--talk-name=org.freedesktop.secrets",
            checker.EXPECTED_FLATPAK_FINISH_ARGS,
        )
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace(
                "  - --share=network\n",
                "  - --share=network\n  - --talk-name=org.freedesktop.secrets\n",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("unrelated permission", problems[0])
        self.assertIn("--talk-name=org.freedesktop.secrets", problems[0])

    def test_broader_secret_service_permissions_are_caught(self) -> None:
        # Every broader way to reach the same service. One exact well-known
        # name on the session bus is what libsecret connects to; anything
        # wider is a bigger sandbox for no benefit.
        for permission in (
            "--socket=session-bus",
            "--talk-name=org.freedesktop.*",
            "--talk-name=org.freedesktop.secrets.*",
            "--own-name=org.freedesktop.secrets",
            "--system-talk-name=org.freedesktop.secrets",
            "--talk-name=org.freedesktop.impl.portal.Secret",
        ):
            with self.subTest(permission=permission):
                root = self.root / permission.replace("/", "_").replace(
                    "*", "star"
                )
                root.mkdir(parents=True, exist_ok=True)
                build_checkout(
                    root,
                    flatpak_manifest=FLATPAK_MANIFEST.format(
                        app_id=APP_ID, binary=BINARY
                    ).replace(
                        "  - --share=network\n",
                        f"  - --share=network\n  - {permission}\n",
                    ),
                )
                problems = checker.check(root)
                self.assertEqual(len(problems), 1)
                self.assertIn("unrelated permission", problems[0])
                self.assertIn(permission, problems[0])

    def test_filesystem_permissions_stay_rejected(self) -> None:
        # A keyring grant must not become a reason to hand out host files:
        # nothing in the credential path reads or writes a file.
        for permission in (
            "--filesystem=host",
            "--filesystem=home",
            "--filesystem=xdg-data/keyrings",
            "--persist=.local/share/keyrings",
        ):
            with self.subTest(permission=permission):
                root = self.root / permission.replace("/", "_").replace(
                    "=", "_"
                )
                root.mkdir(parents=True, exist_ok=True)
                build_checkout(
                    root,
                    flatpak_manifest=FLATPAK_MANIFEST.format(
                        app_id=APP_ID, binary=BINARY
                    ).replace(
                        "  - --share=network\n",
                        f"  - --share=network\n  - {permission}\n",
                    ),
                )
                problems = checker.check(root)
                self.assertEqual(len(problems), 1)
                self.assertIn("unrelated permission", problems[0])
                self.assertIn(permission, problems[0])

    def test_the_approved_surface_talks_to_nothing_on_the_bus(self) -> None:
        # #543's network grant stands; #441 adds nothing beside it. #397 adds
        # the two MPRIS names Linthra *owns* — and nothing it may talk to. That
        # asymmetry is the point: owning a name lets shells call Linthra and
        # gives Linthra no way to call anything, so the approved surface still
        # carries no --talk-name of any shape and no whole-bus socket.
        self.assertIn("--share=network", checker.EXPECTED_FLATPAK_FINISH_ARGS)
        self.assertEqual(
            [
                permission
                for permission in sorted(checker.EXPECTED_FLATPAK_FINISH_ARGS)
                if permission.startswith(
                    (
                        "--talk-name",
                        "--system-talk-name",
                        "--system-own-name",
                        "--socket=session-bus",
                        "--socket=system-bus",
                    )
                )
            ],
            [],
        )

    def test_the_only_owned_names_are_linthras_own_mpris_names(self) -> None:
        # A wildcard like org.mpris.MediaPlayer2.* would let Linthra take over
        # any other player's name on the bus. Every owned name must be under
        # Linthra's own.
        owned = sorted(
            permission
            for permission in checker.EXPECTED_FLATPAK_FINISH_ARGS
            if permission.startswith("--own-name=")
        )
        self.assertEqual(
            owned,
            [
                "--own-name=org.mpris.MediaPlayer2.linthra",
                "--own-name=org.mpris.MediaPlayer2.linthra.*",
            ],
        )

    def test_dropping_an_mpris_grant_is_caught(self) -> None:
        # Without it the Flatpak starts, plays audio, and is invisible to every
        # desktop shell — a silence only this check notices.
        for permission in (
            "--own-name=org.mpris.MediaPlayer2.linthra",
            "--own-name=org.mpris.MediaPlayer2.linthra.*",
        ):
            with self.subTest(permission=permission):
                root = self.root / permission.replace("*", "star").replace(
                    "=", "_"
                ).replace(".", "_")
                root.mkdir(parents=True, exist_ok=True)
                build_checkout(
                    root,
                    flatpak_manifest=FLATPAK_MANIFEST.format(
                        app_id=APP_ID, binary=BINARY
                    ).replace(f"  - {permission}\n", ""),
                )
                problems = checker.check(root)
                self.assertTrue(problems)
                self.assertIn(permission, problems[0])

    def test_allowed_permission_with_inline_comment_is_recognised(self) -> None:
        manifest = FLATPAK_MANIFEST.format(app_id=APP_ID, binary=BINARY).replace(
            "  - --share=network\n",
            "  - --share=network # configured providers\n",
        )
        build_checkout(self.root, flatpak_manifest=manifest)
        self.assertEqual(checker.check(self.root), [])


class IconInstallTest(CheckoutCase):
    """The desktop entry's `Icon=` and the installed icon file, held together.

    Nothing else connects them: `Icon=` is a theme name, the install step is a
    shell line in a manifest, and every mismatch here builds, installs and
    launches perfectly — it just shows a generic icon.
    """

    def test_a_consistent_checkout_installs_the_icon(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.check(self.root), [])

    def test_a_generated_manifest_that_lost_the_icon_is_caught(self) -> None:
        # The same drift the desktop entry has: the template gains the install
        # step, scripts/regenerate_flatpak_sources.sh is never re-run, and the
        # manifest flatpak-builder consumes ships no icon.
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace(ICON_INSTALL_LINE.format(app_id=APP_ID), ""),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn(f"flatpak/{APP_ID}.yml", problems[0])
        self.assertIn("/app/share/icons/hicolor/scalable/apps", problems[0])

    def test_renaming_the_installed_icon_is_caught(self) -> None:
        # The drift this check exists for: the icon is installed under a name
        # that is no longer the one `Icon=` looks up.
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace(f"apps/{APP_ID}.svg", "apps/exampleapp.svg"),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn(f"Icon={APP_ID}", problems[0])

    def test_renaming_the_entrys_icon_is_caught_on_both_sides(self) -> None:
        # The mirror image: `Icon=` changes and the install steps do not. The
        # entry check reports the identity break, and the icon check reports
        # that nothing installs a file answering to the new name — for the
        # scalable icon in both manifests, and for every raster size, which is
        # neither generated nor installed under the new name either.
        build_checkout(
            self.root,
            desktop_entry=DESKTOP_ENTRY.format(
                display_name=DISPLAY_NAME, binary=BINARY, app_id=APP_ID
            ).replace(f"Icon={APP_ID}", "Icon=exampleapp"),
        )
        problems = checker.check(self.root)
        self.assertTrue(any("Icon=" in problem for problem in problems))
        self.assertEqual(
            2,
            sum("apps/exampleapp.svg" in problem for problem in problems),
        )
        for size in RASTER_ICON_SIZES:
            # One missing source, plus one uninstalled step per manifest.
            self.assertEqual(
                3,
                sum(
                    f"{size}x{size}/apps/exampleapp.png" in problem
                    for problem in problems
                ),
                f"{size}x{size} raster not reported",
            )

    def test_a_missing_raster_icon_is_caught(self) -> None:
        # The rasters are what GTK actually decodes into _NET_WM_ICON, so a
        # brand change that regenerates the SVG but not the PNG set has to be
        # caught here rather than in a Flatpak smoke run.
        build_checkout(self.root, write_raster_icons=False)
        problems = checker.check(self.root)
        self.assertEqual(len(problems), len(RASTER_ICON_SIZES))
        for problem in problems:
            self.assertIn("generate_icons.py", problem)

    def test_a_generated_manifest_that_lost_a_raster_is_caught(self) -> None:
        # The same regenerate-and-forget drift as the desktop entry and the
        # scalable icon, one size at a time.
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace(RASTER_ICON_INSTALL_LINE.format(size=128, app_id=APP_ID), ""),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn(f"flatpak/{APP_ID}.yml", problems[0])
        self.assertIn("128x128", problems[0])
        self.assertIn("_NET_WM_ICON", problems[0])

    def test_installing_outside_the_icon_theme_is_caught(self) -> None:
        # /app/share/icons/<app-id>.svg is not in any theme, so no launcher
        # ever looks there — the same shape of mistake as installing the
        # desktop entry outside /app/share/applications.
        build_checkout(
            self.root,
            flatpak_manifest=FLATPAK_MANIFEST.format(
                app_id=APP_ID, binary=BINARY
            ).replace("/app/share/icons/hicolor/scalable/apps/", "/app/share/icons/"),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("hicolor/scalable/apps", problems[0])

    def test_a_missing_icon_source_is_caught(self) -> None:
        build_checkout(self.root, write_icon=False)
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("linthra_icon.svg is missing", problems[0])


class IconSourceTest(CheckoutCase):
    """What the icon file itself may contain.

    Both failures are invisible until the icon is rendered from inside the
    sandbox, where the developer's filesystem and the network are not there.
    """

    def test_internal_fragment_references_are_allowed(self) -> None:
        # `fill="url(#g)"` is how an SVG uses its own gradient. Flagging it
        # would make the check useless on Linthra's actual mark.
        build_checkout(self.root)
        self.assertEqual(checker.check(self.root), [])

    def test_an_external_image_reference_is_caught(self) -> None:
        build_checkout(
            self.root,
            icon_svg=ICON_SVG.replace(
                "</svg>",
                '  <image href="https://example.invalid/mark.png" />\n</svg>',
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("references something outside itself", problems[0])

    def test_an_imported_stylesheet_is_caught(self) -> None:
        build_checkout(
            self.root,
            icon_svg=ICON_SVG.replace(
                "<defs>", '<style>@import url("theme.css");</style>\n  <defs>'
            ),
        )
        problems = checker.check(self.root)
        self.assertTrue(problems)
        self.assertTrue(
            all("references something outside itself" in p for p in problems)
        )

    def test_a_root_element_pushed_out_of_the_sniff_window_is_caught(self) -> None:
        # The regression #554 actually hit: a descriptive comment between the XML
        # declaration and `<svg>`. The file still parses, still validates, still
        # renders in a browser, and gdk-pixbuf still refuses it, so GTK cannot
        # load it as a themed icon and every launcher shows a generic one.
        header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        body = ICON_SVG[len(header) :]
        comment = "<!-- " + ("a note about the mark. " * 20) + "-->\n"
        build_checkout(self.root, icon_svg=header + comment + body)
        problems = checker.icon_source_problems(self.root)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("root element starts", problems[0])

    def test_the_same_comment_inside_the_root_element_is_fine(self) -> None:
        # The fix, and the reason the check measures the offset rather than
        # banning comments: the note keeps its place in the file.
        marker = 'viewBox="0 0 512 512">'
        comment = "\n  <!-- " + ("a note about the mark. " * 20) + "-->"
        icon = ICON_SVG.replace(marker, marker + comment)
        self.assertIn("a note about the mark", icon)
        build_checkout(self.root, icon_svg=icon)
        self.assertEqual(checker.icon_source_problems(self.root), [])

    def test_a_malformed_svg_is_caught(self) -> None:
        # A broken SVG installs perfectly and then draws nothing.
        build_checkout(self.root, icon_svg=ICON_SVG.replace("</svg>", ""))
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("not well-formed XML", problems[0])

    def test_a_non_svg_root_element_is_caught(self) -> None:
        build_checkout(
            self.root, icon_svg='<?xml version="1.0"?>\n<html><body /></html>\n'
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("not an SVG", problems[0])

    def test_an_svg_without_a_viewbox_is_caught(self) -> None:
        # It would sit in scalable/ without actually being scalable: it renders
        # at its intrinsic size and every launcher resamples it.
        build_checkout(
            self.root, icon_svg=ICON_SVG.replace('\n     viewBox="0 0 512 512"', "")
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no viewBox", problems[0])

    def test_a_developer_machine_path_is_caught(self) -> None:
        # An editor that saved a linked bitmap leaves exactly this behind: the
        # icon renders on the machine it was exported from and nowhere else.
        build_checkout(
            self.root,
            icon_svg=ICON_SVG.replace(
                "</svg>",
                '  <image href="/home/dev/art/mark.png" />\n</svg>',
            ),
        )
        problems = checker.check(self.root)
        self.assertTrue(any("absolute host path" in problem for problem in problems))
        self.assertTrue(
            any("/home/dev/art/mark.png" in problem for problem in problems)
        )


class WindowMetricsTest(CheckoutCase):
    def test_minimum_may_not_exceed_the_default(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "kMinimumWindowWidth = 420", "kMinimumWindowWidth = 2000"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("minimum window size", problems[0])

    def test_a_zero_minimum_is_rejected(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "kMinimumWindowHeight = 600", "kMinimumWindowHeight = 0"
            ),
        )
        self.assertIn("must be positive", " ".join(checker.check(self.root)))

    def test_equal_minimum_and_default_is_allowed(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME)
            .replace("kMinimumWindowWidth = 420", "kMinimumWindowWidth = 1180")
            .replace("kMinimumWindowHeight = 600", "kMinimumWindowHeight = 780"),
        )
        self.assertEqual(checker.check(self.root), [])


class FolderPickerChannelTest(CheckoutCase):
    """The runner<->Dart folder-picker contract (#438).

    Every failure here is silent at build time: the app still compiles, the
    chooser just never answers and Dart falls back to `file_picker`, which
    inside the Flatpak has no zenity/kdialog to run. So the only thing that
    catches it before a user does is this comparison.
    """

    def test_a_renamed_channel_on_the_dart_side_is_caught(self) -> None:
        build_checkout(
            self.root,
            folder_picker_dart=FOLDER_PICKER_DART.format(
                channel="io.example.app/renamed",
                method=FOLDER_PICKER_METHOD_NAME,
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("channel name", problems[0])
        self.assertIn("io.example.app/renamed", problems[0])

    def test_a_renamed_method_on_the_native_side_is_caught(self) -> None:
        build_checkout(
            self.root,
            folder_picker_channel=FOLDER_PICKER_CHANNEL.format(
                channel=FOLDER_PICKER_CHANNEL_NAME, method="chooseFolder"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("method name", problems[0])
        self.assertIn("chooseFolder", problems[0])

    def test_dropping_the_source_from_the_runner_build_is_caught(self) -> None:
        # What a `flutter create` regeneration of linux/ would do: restore the
        # template's source list and leave the channel uncompiled.
        build_checkout(
            self.root,
            runner_cmakelists=RUNNER_CMAKELISTS.replace(
                '  "folder_picker_channel.cc"\n', ""
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("folder_picker_channel.cc", problems[0])

    def test_never_registering_the_channel_is_caught(self) -> None:
        # Compiled but never wired to the engine is the same silence.
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "self->folder_picker = folder_picker_channel_new(view, window);",
                "// no folder picker here",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("folder_picker_channel_new", problems[0])


class WindowLifecycleChannelTest(CheckoutCase):
    """The runner<->Dart close-behaviour contract (#401).

    The close behaviour is decided in Dart and applied in the runner, so the
    two halves only meet as strings. When they stop matching, nothing fails:
    the runner never hears what to do, every close destroys the window as it
    did before the preference existed, and Settings keeps offering a choice
    that no longer changes anything.
    """

    def test_a_renamed_channel_on_the_dart_side_is_caught(self) -> None:
        build_checkout(
            self.root,
            window_lifecycle_dart=WINDOW_LIFECYCLE_DART.format(
                channel="io.example.app/renamed",
                set_hide_on_close=WINDOW_LIFECYCLE_SET_METHOD,
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("channel name", problems[0])
        self.assertIn("io.example.app/renamed", problems[0])

    def test_a_renamed_method_on_the_native_side_is_caught(self) -> None:
        build_checkout(
            self.root,
            window_lifecycle_channel=WINDOW_LIFECYCLE_CHANNEL.format(
                channel=WINDOW_LIFECYCLE_CHANNEL_NAME,
                set_hide_on_close="setCloseBehaviour",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("setHideOnClose method", problems[0])
        self.assertIn("setCloseBehaviour", problems[0])

    def test_dropping_the_source_from_the_runner_build_is_caught(self) -> None:
        build_checkout(
            self.root,
            runner_cmakelists=RUNNER_CMAKELISTS.replace(
                '  "window_lifecycle_channel.cc"\n', ""
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_lifecycle_channel.cc", problems[0])

    def test_never_registering_the_channel_is_caught(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "  self->window_lifecycle = window_lifecycle_channel_new(view, window);\n",
                "",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_lifecycle_channel_new", problems[0])

    def test_never_presenting_the_existing_window_is_caught(self) -> None:
        # Without this, activating a running Linthra builds a second window on
        # top of the one it already has instead of showing it.
        runner = MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
            """  if (window_lifecycle_channel_present(self->window_lifecycle)) {
    return;
  }
""",
            "",
        )
        build_checkout(self.root, my_application=runner)
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_lifecycle_channel_present", problems[0])

    def test_a_non_unique_application_is_caught(self) -> None:
        # What a `flutter create` regeneration restores. A second launch would
        # then start a second process, with a second audio engine and a second
        # connection to the same catalog, instead of showing the hidden window.
        runner = MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
            "static_cast<GApplicationFlags>(0)", "G_APPLICATION_NON_UNIQUE"
        )
        build_checkout(self.root, my_application=runner)
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("G_APPLICATION_NON_UNIQUE", problems[0])

    def test_the_flag_named_only_in_a_comment_does_not_count(self) -> None:
        runner = MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
            "  g_set_prgname(APPLICATION_ID);",
            "  // Deliberately not G_APPLICATION_NON_UNIQUE.\n"
            "  g_set_prgname(APPLICATION_ID);",
        )
        build_checkout(self.root, my_application=runner)
        self.assertEqual(checker.check(self.root), [])


class OfflineBuildSeamTest(CheckoutCase):
    def test_losing_the_sqlite_seam_is_caught(self) -> None:
        # This is the check that matters for packaging: without the seam the
        # build still succeeds anywhere with a network, so nothing else notices.
        build_checkout(
            self.root,
            cmakelists='set(BINARY_NAME "exampleapp")\nset(APPLICATION_ID "io.example.app")\n',
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 2)
        self.assertIn("LINTHRA_SQLITE3_SOURCE_DIR", problems[0])

    def test_a_seam_that_is_never_forwarded_is_caught(self) -> None:
        # Declaring the variable and not wiring it to FetchContent would look
        # right in a diff and do nothing.
        build_checkout(
            self.root,
            cmakelists=(
                'set(BINARY_NAME "exampleapp")\n'
                'set(APPLICATION_ID "io.example.app")\n'
                'set(LINTHRA_SQLITE3_SOURCE_DIR "" CACHE PATH "")\n'
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 2)
        self.assertIn("never forwards it", problems[0])


class SecureStorageWarningScopeTest(CheckoutCase):
    def test_losing_the_plugin_exception_is_caught(self) -> None:
        cmakelists = CMAKELISTS.format(binary=BINARY, app_id=APP_ID).replace(
            """\
if(TARGET flutter_secure_storage_linux_plugin AND
   CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  target_compile_options(flutter_secure_storage_linux_plugin PRIVATE
    -Wno-error=deprecated-literal-operator)
endif()
""",
            "",
        )
        build_checkout(self.root, cmakelists=cmakelists)

        problems = checker.check(self.root)

        self.assertEqual(len(problems), 1)
        self.assertIn("deprecated-literal-operator", problems[0])

    def test_a_global_exception_is_rejected(self) -> None:
        cmakelists = CMAKELISTS.format(binary=BINARY, app_id=APP_ID).replace(
            """\
  target_compile_options(flutter_secure_storage_linux_plugin PRIVATE
    -Wno-error=deprecated-literal-operator)
""",
            "  add_compile_options(-Wno-error=deprecated-literal-operator)\n",
        )
        build_checkout(self.root, cmakelists=cmakelists)

        problems = checker.check(self.root)

        self.assertEqual(len(problems), 1)
        self.assertIn("PRIVATE", problems[0])


class AbsolutePathTest(CheckoutCase):
    def test_a_hardcoded_host_path_is_caught(self) -> None:
        build_checkout(self.root)
        (self.root / "linux" / "CMakeLists.txt").write_text(
            CMAKELISTS.format(binary=BINARY, app_id=APP_ID)
            + 'include_directories("/home/dev/sqlite")\n',
            encoding="utf-8",
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("absolute host path", problems[0])
        self.assertIn("/home/dev/sqlite", problems[0])

    def test_ordinary_cmake_variable_paths_are_not_flagged(self) -> None:
        build_checkout(self.root)
        (self.root / "linux" / "CMakeLists.txt").write_text(
            CMAKELISTS.format(binary=BINARY, app_id=APP_ID)
            + 'set(BUNDLE "${CMAKE_INSTALL_PREFIX}/data/flutter_assets")\n'
            + 'set(RPATH "$ORIGIN/lib")\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.check(self.root), [])

    def test_generated_ephemeral_files_are_ignored(self) -> None:
        # linux/flutter/ephemeral is per-build output full of machine paths and
        # is not in git; scanning it would fail on every developer's checkout.
        build_checkout(self.root)
        ephemeral = self.root / "linux" / "flutter" / "ephemeral"
        ephemeral.mkdir(parents=True)
        (ephemeral / "generated_config.cmake").write_text(
            'set(FLUTTER_ROOT "/home/dev/flutter")\n', encoding="utf-8"
        )
        self.assertEqual(checker.check(self.root), [])


class MissingFileTest(CheckoutCase):
    def test_a_missing_runner_is_an_error_not_a_pass(self) -> None:
        with self.assertRaises(checker.CheckError):
            checker.check(self.root)

    def test_main_reports_a_read_failure_as_exit_two(self) -> None:
        self.assertEqual(checker.main(["--root", str(self.root)]), 2)


class WindowStateWiringTest(CheckoutCase):
    """The window-state wiring (#383), which fails silently when it breaks.

    Every case below still compiles and still launches. The window simply stops
    remembering its size, which is exactly the kind of regression a template
    regeneration or a careless merge produces.
    """

    def test_a_consistent_checkout_is_accepted(self) -> None:
        build_checkout(self.root)
        self.assertEqual(checker.check(self.root), [])

    def test_dropping_the_store_from_the_runner_build_is_caught(self) -> None:
        build_checkout(
            self.root,
            runner_cmakelists=RUNNER_CMAKELISTS.replace(
                '  "window_state_store.cc"\n', ""
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_state_store.cc", problems[0])

    def test_dropping_the_policy_source_is_caught(self) -> None:
        build_checkout(
            self.root,
            runner_cmakelists=RUNNER_CMAKELISTS.replace(
                '  "${{CMAKE_SOURCE_DIR}}/../native/linthra_desktop/src/'
                'window_state.cpp"\n',
                "",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_state.cpp", problems[0])

    def test_dropping_cxx_std_17_is_caught(self) -> None:
        # The policy is C++17; without the explicit requirement the runner
        # compiles at whatever the host compiler defaults to, which is a build
        # that breaks somewhere else rather than here.
        build_checkout(
            self.root,
            runner_cmakelists=RUNNER_CMAKELISTS.replace(
                "target_compile_features(${{BINARY_NAME}} PUBLIC "
                "cxx_std_17)\n",
                "",
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("cxx_std_17", problems[0])

    def test_never_restoring_the_geometry_is_caught(self) -> None:
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "window_state_store_new", "no_window_state_here"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_state_store_new", problems[0])

    def test_never_saving_the_geometry_is_caught(self) -> None:
        # Restoring without saving is the worst of the three: it looks wired,
        # and every launch is a first launch.
        build_checkout(
            self.root,
            my_application=MY_APPLICATION.format(display_name=DISPLAY_NAME).replace(
                "window_state_store_save", "no_save_here"
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("window_state_store_save", problems[0])

    def test_dropping_only_the_shutdown_save_is_caught(self) -> None:
        # The one that matters: the runner keeps a save on the rare
        # window-recreation path in activate(), so a checker that only searched
        # the file would keep passing while every ordinary exit stopped
        # persisting anything.
        my_application = MY_APPLICATION.format(display_name=DISPLAY_NAME)
        shutdown = my_application.index("static void my_application_shutdown(")
        build_checkout(
            self.root,
            my_application=(
                my_application[:shutdown]
                + my_application[shutdown:].replace(
                    "  window_state_store_save(self->window_state);\n", "", 1
                )
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("my_application_shutdown()", problems[0])

    def test_a_save_only_in_a_comment_does_not_count(self) -> None:
        # Blanked comments are what stop a call that is merely *described* from
        # standing in for one that runs.
        my_application = MY_APPLICATION.format(display_name=DISPLAY_NAME)
        shutdown = my_application.index("static void my_application_shutdown(")
        build_checkout(
            self.root,
            my_application=(
                my_application[:shutdown]
                + my_application[shutdown:].replace(
                    "  window_state_store_save(self->window_state);\n",
                    "  // window_state_store_save(self->window_state);\n",
                    1,
                )
            ),
        )
        problems = checker.check(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("my_application_shutdown()", problems[0])


class RealRepositoryTest(unittest.TestCase):
    def test_the_committed_linux_runner_is_consistent(self) -> None:
        self.assertEqual(checker.check(ROOT), [])

    def test_the_runner_uses_the_android_application_id(self) -> None:
        # Stated explicitly because it is the decision that matters for
        # Flathub: one reverse-DNS id for the product on every platform.
        self.assertEqual(
            checker.application_id(ROOT), checker.android_application_id(ROOT)
        )

    def test_the_running_window_carries_the_application_id(self) -> None:
        # The committed runner really does make all four identity calls, in the
        # places where GTK still honours them (#554).
        self.assertEqual(checker.runner_identity_problems(ROOT), [])
        runner = (ROOT / "linux" / "runner" / "my_application.cc").read_text(
            encoding="utf-8"
        )
        for call in (
            "g_set_prgname(APPLICATION_ID)",
            "gdk_set_program_class(APPLICATION_ID)",
            "gtk_window_set_default_icon_name(APPLICATION_ID)",
        ):
            self.assertIn(call, runner)

    def test_the_desktop_entry_declares_the_runners_wm_class(self) -> None:
        entry = checker.desktop_entry(ROOT)
        self.assertEqual(
            entry["StartupWMClass"], checker.android_application_id(ROOT)
        )
        self.assertEqual(entry["StartupWMClass"], entry["Icon"])

    def test_the_window_title_is_the_product_name(self) -> None:
        self.assertEqual(checker.window_title(ROOT), checker.app_display_name(ROOT))

    def test_the_installed_icon_is_named_for_the_desktop_entrys_icon_key(self) -> None:
        # Stated explicitly because it is the whole point of #436: the file
        # the Flatpak installs answers to the name the launcher looks up.
        icon_name = checker.desktop_entry(ROOT)["Icon"]
        installed = f"{checker.ICON_INSTALL_DIR}/{icon_name}{checker.ICON_EXTENSION}"
        self.assertEqual(
            installed,
            "/app/share/icons/hicolor/scalable/apps/"
            f"{checker.android_application_id(ROOT)}.svg",
        )
        for manifest in (
            checker.FLATPAK_TEMPLATE,
            checker.FLATPAK_DIR / f"{checker.android_application_id(ROOT)}.yml",
        ):
            self.assertIn(installed, (ROOT / manifest).read_text(encoding="utf-8"))

    def test_the_metainfo_is_named_for_the_app_id_and_installed(self) -> None:
        app_id = checker.android_application_id(ROOT)
        path = ROOT / "linux" / "packaging" / f"{app_id}.metainfo.xml"
        self.assertTrue(path.is_file())
        listing = path.read_text(encoding="utf-8")
        self.assertIn(f"<id>{app_id}</id>", listing)
        self.assertIn(
            f'<launchable type="desktop-id">{app_id}.desktop</launchable>', listing
        )
        self.assertIn(f'<icon type="stock">{app_id}</icon>', listing)
        installed = f"/app/share/metainfo/{app_id}.metainfo.xml"
        for manifest in (
            checker.FLATPAK_TEMPLATE,
            checker.FLATPAK_DIR / f"{app_id}.yml",
        ):
            self.assertIn(installed, (ROOT / manifest).read_text(encoding="utf-8"))

    def test_the_icon_source_is_recognisable_as_an_svg(self) -> None:
        # Content sniffing is what stands between the installed file and a
        # generic icon, and it only looks at the start of the file.
        raw = (ROOT / "tool" / "branding" / "linthra_icon.svg").read_bytes()
        offset = raw.find(b"<svg")
        self.assertNotEqual(offset, -1)
        self.assertLessEqual(
            offset + len(b"<svg"), checker.SVG_SIGNATURE_WINDOW_BYTES
        )

    def test_the_icon_source_is_the_canonical_brand_mark(self) -> None:
        # Not a copy and not a redraw: the file Linux packaging installs is the
        # same vector source tool/branding/generate_icons.py renders from.
        self.assertTrue((ROOT / checker.ICON_SOURCE).is_file())
        self.assertIn(
            checker.ICON_SOURCE.name,
            (ROOT / "tool" / "branding" / "generate_icons.py").read_text(
                encoding="utf-8"
            ),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
