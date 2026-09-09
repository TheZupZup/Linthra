#!/usr/bin/env python3
"""check_linux_runner.py — hold the committed Linux runner to Linthra's identity.

The `linux/` directory is Flutter template code that Linthra has edited. That
combination rots quietly: `flutter create --platforms=linux .` regenerates those
files from the template, and a regeneration silently restores the template's
lowercase `"linthra"` window title, drops the window-size constants, and — the
expensive one — drops the SQLite pre-fetch seam that lets the app build with no
network. Nothing fails; the app still compiles. It just stops being Linthra, or
stops building offline, and nobody notices until packaging.

So the identity is asserted against its real sources of truth instead of being
duplicated here:

    application id  <- android/app/build.gradle (applicationId)
    binary name     <- pubspec.yaml (name)
    window title    <- lib/core/app_info.dart (AppInfo.name)

Those three are what a desktop and, later, a Flathub listing key off. An app id
that disagrees with Android's would mean two different identities for one
product; a window title that disagrees with `AppInfo.name` would mean the title
bar and the About screen disagree.

The same three answers are what the installed desktop entry
(`linux/packaging/<app-id>.desktop`, #434) has to repeat — its filename, its
`Icon=`, its `Name=` and its `Exec=` — so it is checked against those sources
of truth too, rather than against the runner's copy of them. A desktop entry
that disagrees is not a build failure either: it installs, it just launches
nothing, shows the wrong name, or (with a filename that is not the app id)
never gets exported by flatpak-builder at all. The Flatpak manifests are
checked for the install step that puts it in `/app/share/applications`, since
an entry nothing installs is the same silence.

The application icon (#436) is that same silence one step further out. `Icon=`
is an icon-theme *name*, not a path, so it only resolves if a file of exactly
that basename lands in the icon theme; install it one directory too high, or
rename either side, and every launcher quietly falls back to a generic icon
with nothing logged anywhere. The same silence swallows an SVG whose `<svg` root
element starts more than 256 bytes in (#554): content sniffing never finds the
one signature an SVG has, so gdk-pixbuf refuses the file and GTK cannot load it
as an icon at all, however valid the XML is. So the manifests are checked for the install step
that puts Linthra's canonical vector source into `hicolor/scalable/apps` under
precisely the name `Icon=` asks for, and that source is itself checked for the
two things that would make it unusable inside a sandbox: an absolute host path,
or a reference to a file it does not carry.

The *running window* (#554) is the last link in that chain, and the one a
desktop actually looks at. Nothing installed above matters if the GTK window
introduces itself under a different name, so the runner is checked for the calls
that set it: `g_set_prgname()` for the Wayland `xdg_toplevel` app id,
`gdk_set_program_class()` for the class half of X11's `WM_CLASS` (GDK's default
is the program name with the first letter upper-cased, which is not the app id),
`gtk_window_set_default_icon_name()` for the window's own icon, and
`g_set_application_name()` for the human-readable name. Two of those are undone
by `gtk_init()` if they run too early, so where they appear is checked as well
as that they appear. The desktop entry's `StartupWMClass=` is held to the same
value from the other side.

It also checks the one runner<->Dart contract that is a pair of strings and
nothing else: the folder-picker method channel (#438). The runner answers on
`linux/runner/folder_picker_channel.cc`'s channel name and Dart calls
`MethodChannelLinuxFolderPicker.channelName`; if those drift, or the source
file stops being compiled into the runner, nothing fails to build — every pick
just reports "no chooser here" and silently falls back to `file_picker`, which
inside the Flatpak has no `zenity`/`kdialog` to run.

It also checks two things that are about *how* the runner builds rather than
what it is called:

  * the temporary Clang exception for flutter_secure_storage_linux stays
    PRIVATE to that plugin target, so the legacy bundled header builds without
    weakening -Werror for Linthra or any other plugin;
  * the SQLite pre-fetch seam (LINTHRA_SQLITE3_SOURCE_DIR) is still there, so a
    network-isolated build — flatpak-builder included — stays possible;
  * nothing under linux/ hardcodes an absolute host path, which would make the
    build depend on one machine's filesystem.

Usage
-----

    python3 scripts/check_linux_runner.py            # check this repository
    python3 scripts/check_linux_runner.py --root DIR # check another checkout

Read-only, offline, no dependencies beyond the standard library. Exit status: 0
if the runner agrees with the app, 2 if it does not.
"""

from __future__ import annotations

import argparse
import re
import shlex
import sys
from pathlib import Path
from xml.etree import ElementTree

# Paths this script reads, all relative to the repository root.
CMAKELISTS = Path("linux") / "CMakeLists.txt"
MY_APPLICATION = Path("linux") / "runner" / "my_application.cc"
RUNNER_CMAKELISTS = Path("linux") / "runner" / "CMakeLists.txt"
FOLDER_PICKER_CHANNEL_SOURCE = Path("linux") / "runner" / "folder_picker_channel.cc"
WINDOW_STATE_STORE_SOURCE = Path("linux") / "runner" / "window_state_store.cc"
WINDOW_STATE_POLICY_SOURCE = (
    Path("native") / "linthra_desktop" / "src" / "window_state.cpp"
)
FOLDER_PICKER_DART = (
    Path("lib") / "core" / "services" / "method_channel_linux_folder_picker.dart"
)
WINDOW_LIFECYCLE_CHANNEL_SOURCE = (
    Path("linux") / "runner" / "window_lifecycle_channel.cc"
)
WINDOW_LIFECYCLE_DART = (
    Path("lib") / "core" / "services" / "method_channel_linux_window.dart"
)
PUBSPEC = Path("pubspec.yaml")
APP_INFO = Path("lib") / "core" / "app_info.dart"
BUILD_GRADLE = Path("android") / "app" / "build.gradle"
# The installed desktop entry and the two Flatpak manifests that install it.
# All three are named after the application id, so their real paths are built
# from it at check time rather than hardcoded here.
PACKAGING_DIR = Path("linux") / "packaging"
FLATPAK_DIR = Path("flatpak")
FLATPAK_TEMPLATE = FLATPAK_DIR / "flatpak-flutter.yml"

# The complete sandbox surface approved for the current Flatpak. Keeping an
# exact allow-list (rather than checking only for --share=network) makes this a
# regression guard against solving provider access with a filesystem or D-Bus
# grant. Both the authoritative template and generated manifest are checked.
#
# The only D-Bus entries are the two MPRIS names Linthra itself owns (#397).
# Owning a name is not talking to one: neither grant lets Linthra call any
# other service, and both are scoped to its own player names, so no other
# player's MPRIS interface is reachable through them. The base name plus its
# `.*` form is what the spec's `.instance<pid>` fallback needs for a second
# window.
#
# Everything broader stays rejected by this exact list rather than quietly
# accepted: --socket=session-bus, an org.mpris.MediaPlayer2.* wildcard that
# would cover other players, any --talk-name, and the same names on the system
# bus. In particular secure credential storage (#441) still needs no grant —
# it reaches the platform keyring through the xdg-desktop-portal Secret
# portal, which every Flatpak may talk to without a finish-arg, so
# --talk-name=org.freedesktop.secrets is still not here. See
# flatpak/flatpak-flutter.yml's finish-args comments.
EXPECTED_FLATPAK_FINISH_ARGS = {
    "--socket=wayland",
    "--socket=fallback-x11",
    "--share=ipc",
    "--device=dri",
    "--socket=pulseaudio",
    "--share=network",
    "--own-name=org.mpris.MediaPlayer2.linthra",
    "--own-name=org.mpris.MediaPlayer2.linthra.*",
}

# Where a Flatpak's desktop entry has to land: flatpak-builder exports what it
# finds in this directory at `finish` time and nothing from anywhere else.
DESKTOP_ENTRY_INSTALL_DIR = "/app/share/applications"

# Linthra's canonical vector app icon: the source design that
# tool/branding/generate_icons.py rasterises into the Android launcher mipmaps
# and the store graphics. Linux packaging installs this file itself rather than
# a copy of it, so there is no second brand mark that can drift from the first.
ICON_SOURCE = Path("tool") / "branding" / "linthra_icon.svg"

# `hicolor` is the fallback theme every icon theme inherits from, and
# `scalable/apps` is where an application's own resolution-independent icon
# belongs. The basename, minus the extension, is the icon-theme name the desktop
# entry's `Icon=` looks up.
ICON_INSTALL_DIR = "/app/share/icons/hicolor/scalable/apps"
ICON_EXTENSION = ".svg"

# The raster half of the same icon set. A launcher can resolve the SVG at any
# size, but a *window* icon cannot: GTK builds X11's `_NET_WM_ICON` by asking
# gdk-pixbuf to decode whatever the icon theme hands it, and gdk-pixbuf carries
# no SVG loader — librsvg's pixbuf module is obsolete and glycin, its
# replacement, is not wired into GTK 3's icon-theme path in org.gnome.Platform.
# A scalable-only install therefore resolves to nothing, GTK sets no icon list,
# and the packaged window ships with no `_NET_WM_ICON` at all — the failure
# scripts/flatpak_launch_smoke.sh checks for on every launch. These PNGs are
# rasterised from the same source design by tool/branding/generate_icons.py, so
# they are a second encoding of the one brand mark rather than a second mark.
RASTER_ICON_SIZES = (48, 64, 128, 256)
RASTER_ICON_SOURCE_DIR = Path("linux") / "packaging" / "icons" / "hicolor"
RASTER_ICON_INSTALL_DIR = "/app/share/icons/hicolor"
RASTER_ICON_EXTENSION = ".png"

SVG_ROOT_TAG = "{http://www.w3.org/2000/svg}svg"

# An SVG has no magic number, so content sniffing looks for the literal `<svg`
# and gives up after this many bytes. An icon whose root element starts later is
# simply not recognised as an image: gdk-pixbuf refuses to decode it, GTK cannot
# load it as a themed icon, and every launcher that resolves icons through that
# stack falls back to a generic one, with nothing logged. A licence header, a
# DOCTYPE or (as in #554) a descriptive comment between the XML declaration and
# the root tag is all it takes, and the file still parses, still validates and
# still renders in a browser, which is why only a check like this catches it.
# Comments belong inside the root element instead.
SVG_SIGNATURE_WINDOW_BYTES = 256

# An SVG that pulls in something it does not carry — an <image href=...>, an
# external stylesheet or font, a `file://` or `https://` reference — renders
# differently or not at all inside the sandbox, where none of that is
# reachable. Internal fragment references (`fill="url(#bars)"`, the gradients
# the mark is built from) are exactly what an SVG is supposed to do, so they
# are not matched.
EXTERNAL_REFERENCE_PATTERN = re.compile(
    r"(?:href|src|xlink:href)\s*=\s*[\"']?(?!#)"
    r"|url\(\s*[\"']?(?!#)"
    r"|@import\b",
    re.IGNORECASE,
)

# freedesktop's main categories for an audio player. `Audio` is only valid
# alongside `AudioVideo`, and `Player` alone would leave the entry ungrouped in
# menus that split media by kind. Extra categories (Music, …) are fine.
REQUIRED_CATEGORIES = ("AudioVideo", "Audio", "Player")

DESKTOP_ENTRY_GROUP = "Desktop Entry"

# The CMake variable linux/CMakeLists.txt uses to accept an already-unpacked
# SQLite amalgamation instead of downloading one. See docs/linux-desktop.md.
SQLITE_SOURCE_VARIABLE = "LINTHRA_SQLITE3_SOURCE_DIR"

# The folder-picker channel (#438): one name on each side of the same wire,
# plus the method the two agree on.
FOLDER_PICKER_NATIVE_CHANNEL = r'kChannelName\s*=\s*\n?\s*"([^"]+)"'
FOLDER_PICKER_NATIVE_METHOD = r'kPickFolderMethod\s*=\s*"([^"]+)"'
FOLDER_PICKER_DART_CHANNEL = r"String channelName\s*=\s*\n?\s*'([^']+)'"
FOLDER_PICKER_DART_METHOD = r"String pickFolderMethod\s*=\s*'([^']+)'"

# The window-lifecycle channel (#401), checked the same way and for the same
# reason. This one is worse when it drifts than the folder picker: nothing
# fails, no dialog is missing, the app simply goes back to quitting on every
# close while Settings still offers a choice that no longer does anything. Each
# name below is one string on each side of the same wire.
WINDOW_LIFECYCLE_NAMES = (
    ("channel name", "kChannelName", "channelName"),
    ("setHideOnClose method", "kSetHideOnCloseMethod", "setHideOnCloseMethod"),
    ("showWindow method", "kShowWindowMethod", "showWindowMethod"),
    ("quit method", "kQuitMethod", "quitMethod"),
    ("windowHidden method", "kWindowHiddenMethod", "windowHiddenMethod"),
    ("windowShown method", "kWindowShownMethod", "windowShownMethod"),
    ("hideOnClose argument", "kHideOnCloseArgument", "hideOnCloseArgument"),
)

# GApplication's uniqueness, which the close behaviour depends on (#401). The
# Flutter template runner is NON_UNIQUE, so a `flutter create` regeneration
# would restore it, and the failure would be silent in the worst way: launching
# Linthra while it is playing in the background with a hidden window would
# start a *second* process, with a second audio engine, a second MPRIS name and
# a second connection to the same SQLite catalog, instead of showing the window
# that already exists.
NON_UNIQUE_FLAG = "G_APPLICATION_NON_UNIQUE"

# === Window identity (#554) ===
#
# The desktop entry, the icon, the AppStream component and the Flatpak are all
# named for the application id. The *running window* only joins them if the
# runner says so, and each backend reads a different thing:
#
#   Wayland  GTK 3 sends `xdg_toplevel.set_app_id()` straight from
#            `g_get_prgname()`, so `g_set_prgname(APPLICATION_ID)` is the whole
#            Wayland story. It has to run before `gtk_init()` reads the program
#            name, which means inside `my_application_new()`.
#   X11      GTK builds `WM_CLASS` from `g_get_prgname()` (the instance half)
#            and `gdk_get_program_class()` (the class half) as each GtkWindow is
#            constructed. GDK derives that class from the program name with the
#            first letter upper-cased, which is not the application id, so it is
#            set explicitly. `gtk_init()` resets the program class
#            unconditionally, and `GtkApplication::startup` is what calls
#            `gtk_init()`, so this one has to run *after* the startup chain-up.
#   Icon     GTK sets no window icon of its own. Without a default icon name the
#            window carries no `_NET_WM_ICON` and anything reading the window's
#            icon rather than resolving a desktop entry shows a generic one.
#
# None of that fails to build, and none of it fails to launch. It just quietly
# stops matching the launcher, which is exactly the class of drift this script
# exists for. The argument is checked too: every one of these has to be the
# APPLICATION_ID macro, so the id keeps coming from linux/CMakeLists.txt rather
# than being pasted into the runner as a second copy.
RUNNER_IDENTITY_NEW_FUNCTION = "MyApplication* my_application_new()"
RUNNER_IDENTITY_STARTUP_FUNCTION = "static void my_application_startup("
RUNNER_SHUTDOWN_FUNCTION = "static void my_application_shutdown("
RUNNER_STARTUP_CHAIN_UP = (
    "G_APPLICATION_CLASS(my_application_parent_class)->startup(application)"
)
APPLICATION_ID_MACRO = "APPLICATION_ID"
APPLICATION_NAME_CONSTANT = "kApplicationName"

# call -> (function it belongs in, argument it must be given, why)
RUNNER_IDENTITY_CALLS = {
    "g_set_prgname": (
        RUNNER_IDENTITY_NEW_FUNCTION,
        APPLICATION_ID_MACRO,
        "GTK 3 sends the Wayland xdg_toplevel app id from g_get_prgname(), so "
        "without this the window never groups with the installed launcher under "
        "GNOME or KDE Plasma on Wayland",
    ),
    "gdk_set_program_class": (
        RUNNER_IDENTITY_STARTUP_FUNCTION,
        APPLICATION_ID_MACRO,
        "otherwise X11's WM_CLASS class half is the program name with its first "
        "letter upper-cased, which is not the id the desktop entry's "
        "StartupWMClass declares",
    ),
    "gtk_window_set_default_icon_name": (
        RUNNER_IDENTITY_STARTUP_FUNCTION,
        APPLICATION_ID_MACRO,
        "otherwise the window carries no _NET_WM_ICON and task switchers and "
        "panels fall back to a generic icon",
    ),
    "g_set_application_name": (
        RUNNER_IDENTITY_STARTUP_FUNCTION,
        APPLICATION_NAME_CONSTANT,
        "otherwise g_get_application_name() falls back to the program name and "
        "GTK shows the reverse-DNS id where it means to show the product name",
    ),
}

# The calls that gtk_init() would undo if they ran before the startup chain-up.
RUNNER_IDENTITY_CALLS_AFTER_CHAIN_UP = frozenset(
    {"gdk_set_program_class", "gtk_window_set_default_icon_name"}
)

SECURE_STORAGE_TARGET = "flutter_secure_storage_linux_plugin"
SECURE_STORAGE_WARNING_EXCEPTION = "-Wno-error=deprecated-literal-operator"
SECURE_STORAGE_SCOPED_EXCEPTION = re.compile(
    rf"target_compile_options\(\s*{SECURE_STORAGE_TARGET}\s+PRIVATE\s+"
    rf"{re.escape(SECURE_STORAGE_WARNING_EXCEPTION)}\s*\)"
)

# An absolute path baked into the native build would tie it to one machine.
# `/` alone is far too common in CMake (every ${VAR}/sub path), so this looks
# for a quoted or bare token that starts at a real filesystem root.
ABSOLUTE_PATH_PATTERN = re.compile(
    r"(?<![\w$/{])/(?:home|Users|root|opt|usr/local|tmp|var|mnt|media)/[\w./-]+"
)


class CheckError(Exception):
    """A file could not be read or a required value could not be found."""


def _read(root: Path, relative: Path) -> str:
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise CheckError(f"cannot read {relative}: {error}") from error


def _extract(text: str, pattern: str, what: str, where: Path) -> str:
    """Return the single capture group of `pattern` in `text`.

    Requiring exactly one match is the point: a second `set(BINARY_NAME ...)`
    or a second `static const char* kApplicationName` means the file no longer
    has one answer, and picking the first would hide that.
    """
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if not matches:
        raise CheckError(f"{where}: could not find {what}")
    if len(matches) > 1:
        raise CheckError(
            f"{where}: found {len(matches)} definitions of {what}, expected 1"
        )
    return matches[0]


def application_id(root: Path) -> str:
    """The GTK application id the Linux runner registers under."""
    return _extract(
        _read(root, CMAKELISTS),
        r'^set\(APPLICATION_ID\s+"([^"]+)"\)',
        "APPLICATION_ID",
        CMAKELISTS,
    )


def binary_name(root: Path) -> str:
    """The on-disk name of the built executable."""
    return _extract(
        _read(root, CMAKELISTS),
        r'^set\(BINARY_NAME\s+"([^"]+)"\)',
        "BINARY_NAME",
        CMAKELISTS,
    )


def window_title(root: Path) -> str:
    """The user-visible name the runner puts in the title/header bar."""
    return _extract(
        _read(root, MY_APPLICATION),
        r'kApplicationName\s*=\s*"([^"]+)"',
        "kApplicationName",
        MY_APPLICATION,
    )


def window_metric(root: Path, name: str) -> int:
    """One of the runner's window-size constants."""
    return int(
        _extract(
            _read(root, MY_APPLICATION),
            rf"{name}\s*=\s*(\d+);",
            name,
            MY_APPLICATION,
        )
    )


def android_application_id(root: Path) -> str:
    """Android's applicationId — the identity Linux has to match."""
    return _extract(
        _read(root, BUILD_GRADLE),
        r'^\s*applicationId\s*=\s*"([^"]+)"',
        "applicationId",
        BUILD_GRADLE,
    )


def pubspec_name(root: Path) -> str:
    """The Dart package name, which is also the executable name."""
    return _extract(_read(root, PUBSPEC), r"^name:\s*(\S+)", "name", PUBSPEC)


def app_display_name(root: Path) -> str:
    """`AppInfo.name` — the product name the app shows about itself."""
    return _extract(
        _read(root, APP_INFO),
        r"static const String name\s*=\s*'([^']+)'",
        "AppInfo.name",
        APP_INFO,
    )


def desktop_entry_file(root: Path) -> Path:
    """Where the installed desktop entry has to live, from the app id.

    The filename is not decoration: Flatpak only exports `<app-id>.desktop`,
    and AppStream (#435) will key its component id to the same name.
    """
    return PACKAGING_DIR / f"{android_application_id(root)}.desktop"


def desktop_entry(root: Path) -> dict[str, str]:
    """The `[Desktop Entry]` group of the installed entry, as key -> value.

    A hand-rolled reader rather than `configparser`, which lowercases option
    names by default (`Name` and `Exec` would come back as `name`/`exec`) and
    whose default interpolation treats `%` — the field-code character in a
    desktop `Exec=` — as syntax. Only the default group is returned; a
    localized `Name[de]` key is a distinct key here, and a later group
    (`[Desktop Action …]`) is not read at all.
    """
    text = _read(root, desktop_entry_file(root))
    values: dict[str, str] = {}
    in_group = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            in_group = stripped[1:-1] == DESKTOP_ENTRY_GROUP
            continue
        if in_group and "=" in stripped:
            key, _, value = stripped.partition("=")
            values[key.strip()] = value.strip()
    if not values:
        raise CheckError(
            f"{desktop_entry_file(root)}: no [{DESKTOP_ENTRY_GROUP}] group"
        )
    return values


def desktop_entry_problems(root: Path) -> list[str]:
    """Disagreements between the desktop entry and the app's identity."""
    entry = desktop_entry(root)
    where = desktop_entry_file(root)
    problems: list[str] = []

    def require(key: str, expected: str, source: str) -> None:
        actual = entry.get(key)
        if actual is None:
            problems.append(f"{where}: no {key}=, expected {expected!r} ({source})")
        elif actual != expected:
            problems.append(f"{where}: {key}={actual!r} but {source} says {expected!r}")

    require("Type", "Application", "a launchable desktop entry")
    require("Name", app_display_name(root), "lib/core/app_info.dart AppInfo.name")
    # Exec is the bare command, not a path: /app/bin/<name> inside the Flatpak,
    # whatever a native package chose outside it. No `%U`/`%F` field code —
    # Linthra takes no file or URI argument, so accepting one would advertise a
    # handler that silently drops what it is opened with.
    require("Exec", pubspec_name(root), "pubspec.yaml name")
    # Icon is an icon-theme name, which is the app id: #436 installs the icon
    # files under exactly that name.
    require(
        "Icon",
        android_application_id(root),
        "android/app/build.gradle applicationId",
    )
    # StartupWMClass is the X11 `WM_CLASS` the running window carries, which the
    # runner sets to the application id on both halves
    # (`g_set_prgname(APPLICATION_ID)` and
    # `gdk_set_program_class(APPLICATION_ID)`, see runner_identity_problems).
    # A shell trusts an exact StartupWMClass match ahead of every other
    # heuristic, so a stale value here is worse than none: it points Linthra's
    # window at whatever entry claims that class. Wayland ignores the key and
    # matches on the app id directly.
    require(
        "StartupWMClass",
        android_application_id(root),
        "the WM_CLASS linux/runner/my_application.cc sets",
    )

    categories = [item for item in entry.get("Categories", "").split(";") if item]
    missing = [name for name in REQUIRED_CATEGORIES if name not in categories]
    if missing:
        problems.append(
            f"{where}: Categories is missing {', '.join(missing)} — an audio "
            f"player needs {';'.join(REQUIRED_CATEGORIES)}"
        )

    return problems


def desktop_entry_install_problems(root: Path) -> list[str]:
    """Flatpak manifests that do not install the desktop entry.

    Both are checked: `flatpak-flutter.yml` is hand-authored and
    `<app-id>.yml` is generated from it by
    scripts/regenerate_flatpak_sources.sh, so a manifest change that was never
    regenerated leaves the built Flatpak without the entry while the diff looks
    complete.
    """
    app_id = android_application_id(root)
    source = desktop_entry_file(root)
    destination = f"{DESKTOP_ENTRY_INSTALL_DIR}/{app_id}.desktop"
    install = re.compile(
        rf"install\s+-Dm644\s+{re.escape(str(source))}\s+{re.escape(destination)}"
    )

    problems: list[str] = []
    for manifest in (FLATPAK_TEMPLATE, FLATPAK_DIR / f"{app_id}.yml"):
        if install.search(_read(root, manifest)) is None:
            problems.append(
                f"{manifest} does not install {source} to {destination}, so the "
                "built Flatpak has no desktop entry to export"
            )
    return problems


def flatpak_permission_problems(root: Path) -> list[str]:
    """Missing, unexpected, or unsynchronised Flatpak finish arguments."""
    problems: list[str] = []
    app_id = android_application_id(root)
    manifests = (FLATPAK_TEMPLATE, FLATPAK_DIR / f"{app_id}.yml")

    for manifest in manifests:
        actual: set[str] = set()
        in_finish_args = False
        for line in _read(root, manifest).splitlines():
            if not in_finish_args:
                in_finish_args = (
                    re.fullmatch(r"finish-args\s*:\s*(?:#.*)?", line) is not None
                )
                continue

            # Blank lines and comments are harmless within a YAML block. The
            # next unindented mapping key ends finish-args.
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if not line[0].isspace():
                break

            stripped = line.strip()
            if not stripped.startswith("-"):
                problems.append(
                    f"{manifest} finish-args contains an unrecognised line: "
                    f"{stripped!r}"
                )
                continue
            try:
                values = shlex.split(stripped[1:].strip(), comments=True, posix=True)
            except ValueError as error:
                problems.append(
                    f"{manifest} finish-args contains an invalid scalar "
                    f"{stripped!r}: {error}"
                )
                continue
            if len(values) != 1:
                problems.append(
                    f"{manifest} finish-args entry {stripped!r} does not resolve "
                    "to exactly one scalar"
                )
                continue
            actual.add(values[0])

        missing = EXPECTED_FLATPAK_FINISH_ARGS - actual
        unexpected = actual - EXPECTED_FLATPAK_FINISH_ARGS
        if missing:
            problems.append(
                f"{manifest} finish-args missing {', '.join(sorted(missing))}"
            )
        if unexpected:
            problems.append(
                f"{manifest} finish-args contain unrelated permission(s): "
                f"{', '.join(sorted(unexpected))}"
            )
    return problems


def icon_install_problems(root: Path) -> list[str]:
    """Disagreements between the desktop entry's `Icon=` and the installed icon.

    `Icon=` names a theme entry, so the two halves are only connected by the
    installed file's basename. Both Flatpak manifests are checked, for the same
    reason the desktop entry's install step is: `flatpak-flutter.yml` is
    hand-authored and `<app-id>.yml` is generated from it by
    scripts/regenerate_flatpak_sources.sh, so an icon added to one and not
    regenerated into the other leaves the built Flatpak with no icon while the
    diff looks complete.
    """
    entry = desktop_entry(root)
    icon_name = entry.get("Icon")
    if icon_name is None:
        # desktop_entry_problems() already reports the missing key; without it
        # there is no name to hold the installed file to.
        return []

    destination = f"{ICON_INSTALL_DIR}/{icon_name}{ICON_EXTENSION}"
    install = re.compile(
        rf"install\s+-Dm644\s+{re.escape(str(ICON_SOURCE))}\s+{re.escape(destination)}"
    )

    problems: list[str] = []
    if not (root / ICON_SOURCE).is_file():
        problems.append(
            f"{ICON_SOURCE} is missing — it is the canonical vector source the "
            "Linux packaging installs as the application icon"
        )

    app_id = android_application_id(root)
    manifests = (FLATPAK_TEMPLATE, FLATPAK_DIR / f"{app_id}.yml")
    for manifest in manifests:
        if install.search(_read(root, manifest)) is None:
            problems.append(
                f"{manifest} does not install {ICON_SOURCE} to {destination}, so "
                f"{desktop_entry_file(root)}'s Icon={icon_name} resolves to "
                "nothing and launchers fall back to a generic icon"
            )

    # The rasters carry the window icon, and only exist as a set: a size that is
    # generated but never installed (or the reverse) leaves the diff looking
    # complete while the packaged window falls back to no icon.
    for size in RASTER_ICON_SIZES:
        leaf = f"{size}x{size}/apps/{icon_name}{RASTER_ICON_EXTENSION}"
        source = RASTER_ICON_SOURCE_DIR / leaf
        if not (root / source).is_file():
            problems.append(
                f"{source} is missing — regenerate the icon set with "
                "`python3 tool/branding/generate_icons.py`"
            )
        raster_install = re.compile(
            rf"install\s+-Dm644\s+{re.escape(str(source))}\s+"
            rf"{re.escape(f'{RASTER_ICON_INSTALL_DIR}/{leaf}')}"
        )
        for manifest in manifests:
            if raster_install.search(_read(root, manifest)) is None:
                problems.append(
                    f"{manifest} does not install {source} to "
                    f"{RASTER_ICON_INSTALL_DIR}/{leaf}, so GTK has no icon "
                    "gdk-pixbuf can decode and the packaged window carries no "
                    "_NET_WM_ICON"
                )
    return problems


def icon_source_problems(root: Path) -> list[str]:
    """Things in the icon source that make it unusable as an installed icon.

    Parsed with the standard library rather than shelling out to `xmllint` or
    `rsvg-convert`: this check has to run wherever the rest of the checker does,
    including a CI job that installs no extra packages for it.
    """
    path = root / ICON_SOURCE
    if not path.is_file():
        # icon_install_problems() reports the missing file once.
        return []

    problems: list[str] = []

    # Well-formedness first: a broken SVG installs perfectly and then draws
    # nothing. ElementTree also refuses an undefined entity, which is how a
    # DOCTYPE pulling in an external subset shows up here.
    try:
        element = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as error:
        return [f"{ICON_SOURCE}: not well-formed XML — {error}"]
    if element.tag != SVG_ROOT_TAG:
        problems.append(
            f"{ICON_SOURCE}: root element is {element.tag!r}, not an SVG in the "
            f"{SVG_ROOT_TAG} namespace"
        )
        return problems

    # Where that root element starts, which is the only thing content sniffing
    # has to go on. Checked on the bytes rather than the parse tree, because it
    # is a property of the file, not of the document.
    root_offset = path.read_bytes().find(b"<svg")
    if root_offset == -1 or root_offset + len(b"<svg") > SVG_SIGNATURE_WINDOW_BYTES:
        where = "nowhere" if root_offset == -1 else f"at byte {root_offset}"
        problems.append(
            f"{ICON_SOURCE}: the <svg> root element starts {where}, past the "
            f"first {SVG_SIGNATURE_WINDOW_BYTES} bytes content sniffing reads, "
            "so the file is not recognised as an image at all: GTK cannot load "
            "it as a themed icon and launchers show a generic one. Move "
            "whatever precedes it (a comment, a DOCTYPE) inside the root "
            "element."
        )

    if element.get("viewBox") is None:
        # Without a viewBox the drawing has no coordinate system to scale, so
        # the file lands in `scalable/` without actually being scalable — it
        # renders at its intrinsic size and every launcher resamples it.
        problems.append(
            f"{ICON_SOURCE}: no viewBox, so it does not scale — an icon in "
            f"{ICON_INSTALL_DIR} has to render sharply at every size"
        )
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        for match in ABSOLUTE_PATH_PATTERN.findall(line):
            problems.append(
                f"absolute host path in the application icon: "
                f"{ICON_SOURCE}:{line_number}: {match}"
            )
        for match in EXTERNAL_REFERENCE_PATTERN.findall(line):
            problems.append(
                f"{ICON_SOURCE}:{line_number}: the application icon references "
                f"something outside itself ({match.strip()!r}); it has to render "
                "from its own contents inside the sandbox"
            )
    return problems


def folder_picker_problems(root: Path) -> list[str]:
    """Disagreements between the runner's folder-picker channel and Dart's.

    The channel is how a Flatpak build reaches the xdg-desktop-portal folder
    chooser instead of `file_picker`'s zenity/kdialog, which the sandbox does
    not contain. A mismatched name still compiles and still runs; it just never
    answers, and Dart's fallback then finds no chooser at all inside the
    sandbox.
    """
    problems: list[str] = []

    runner_cmakelists = _read(root, RUNNER_CMAKELISTS)
    if FOLDER_PICKER_CHANNEL_SOURCE.name not in runner_cmakelists:
        problems.append(
            f"{RUNNER_CMAKELISTS} does not compile "
            f"{FOLDER_PICKER_CHANNEL_SOURCE.name}, so the runner registers no "
            "folder-picker channel"
        )

    native = _read(root, FOLDER_PICKER_CHANNEL_SOURCE)
    dart = _read(root, FOLDER_PICKER_DART)
    for what, native_pattern, dart_pattern in (
        ("channel name", FOLDER_PICKER_NATIVE_CHANNEL, FOLDER_PICKER_DART_CHANNEL),
        ("method name", FOLDER_PICKER_NATIVE_METHOD, FOLDER_PICKER_DART_METHOD),
    ):
        native_value = _extract(
            native,
            native_pattern,
            f"the folder picker {what}",
            FOLDER_PICKER_CHANNEL_SOURCE,
        )
        dart_value = _extract(
            dart, dart_pattern, f"the folder picker {what}", FOLDER_PICKER_DART
        )
        if native_value != dart_value:
            problems.append(
                f"folder picker {what} is {native_value!r} in "
                f"{FOLDER_PICKER_CHANNEL_SOURCE} but {dart_value!r} in "
                f"{FOLDER_PICKER_DART}"
            )

    # my_application.cc has to actually register it; a compiled-but-unreferenced
    # channel is the same silence.
    if "folder_picker_channel_new" not in _read(root, MY_APPLICATION):
        problems.append(
            f"{MY_APPLICATION} never calls folder_picker_channel_new(), so the "
            "folder-picker channel is never registered on the engine"
        )
    return problems


def window_lifecycle_problems(root: Path) -> list[str]:
    """Disagreements between the runner's window-lifecycle channel and Dart's.

    The channel is how the configurable close behaviour (#401) reaches the one
    place that can act on it: a GTK `delete-event` has to be answered
    synchronously, so Dart pushes the answer ahead of time and the runner
    applies it. A mismatched name still compiles and still runs; the runner
    just never hears what to do, every close destroys the window as before, and
    the preference in Settings quietly stops meaning anything.
    """
    problems: list[str] = []

    runner_cmakelists = _read(root, RUNNER_CMAKELISTS)
    if WINDOW_LIFECYCLE_CHANNEL_SOURCE.name not in runner_cmakelists:
        problems.append(
            f"{RUNNER_CMAKELISTS} does not compile "
            f"{WINDOW_LIFECYCLE_CHANNEL_SOURCE.name}, so the runner registers "
            "no window-lifecycle channel"
        )

    native = _read(root, WINDOW_LIFECYCLE_CHANNEL_SOURCE)
    dart = _read(root, WINDOW_LIFECYCLE_DART)
    for what, native_constant, dart_constant in WINDOW_LIFECYCLE_NAMES:
        native_value = _extract(
            native,
            rf'{native_constant}\s*=\s*\n?\s*"([^"]+)"',
            f"the window lifecycle {what}",
            WINDOW_LIFECYCLE_CHANNEL_SOURCE,
        )
        dart_value = _extract(
            dart,
            rf"String {dart_constant}\s*=\s*\n?\s*'([^']+)'",
            f"the window lifecycle {what}",
            WINDOW_LIFECYCLE_DART,
        )
        if native_value != dart_value:
            problems.append(
                f"window lifecycle {what} is {native_value!r} in "
                f"{WINDOW_LIFECYCLE_CHANNEL_SOURCE} but {dart_value!r} in "
                f"{WINDOW_LIFECYCLE_DART}"
            )

    my_application = _read(root, MY_APPLICATION)
    if "window_lifecycle_channel_new" not in my_application:
        problems.append(
            f"{MY_APPLICATION} never calls window_lifecycle_channel_new(), so "
            "the window-lifecycle channel is never registered on the engine"
        )
    # Presenting the existing window is what makes a second launch reach the
    # first instance instead of building another window on top of it.
    if "window_lifecycle_channel_present" not in my_application:
        problems.append(
            f"{MY_APPLICATION} never calls window_lifecycle_channel_present(), "
            "so activating a running Linthra builds a second window instead of "
            "showing the one it already has"
        )
    if NON_UNIQUE_FLAG in _blank(my_application):
        problems.append(
            f"{MY_APPLICATION} registers the application as "
            f"{NON_UNIQUE_FLAG}, so launching Linthra while it is already "
            "running starts a duplicate process instead of presenting the "
            "window it already has (see #401)"
        )
    return problems


def _blank(source: str, *, comments: bool = True, strings: bool = False) -> str:
    """Return `source` with comments and/or string literals replaced by spaces.

    Same length as the input, so an index into the result is an index into the
    original. Blanking comments is what stops a call *described* in a comment
    from counting as a call; blanking strings is what lets the brace matcher
    below ignore a `"{"` inside a literal.
    """
    out = list(source)
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char == '"' or char == "'":
            end = index + 1
            while end < length and source[end] != char:
                end += 2 if source[end] == "\\" else 1
            end = min(end + 1, length)
            if strings:
                for position in range(index, end):
                    if out[position] != "\n":
                        out[position] = " "
            index = end
        elif source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end == -1 else end
            if comments:
                for position in range(index, end):
                    out[position] = " "
            index = end
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            if comments:
                for position in range(index, end):
                    if out[position] != "\n":
                        out[position] = " "
            index = end
        else:
            index += 1
    return "".join(out)


def _function_body(code: str, signature: str, where: Path) -> tuple[int, int]:
    """The `[start, end)` span of the body of the function opened by `signature`.

    `code` must already have comments and strings blanked, so brace counting is
    reliable. Returns offsets into `code` rather than the text itself, because
    callers need to compare positions (the chain-up has to come first).
    """
    start = code.find(signature)
    if start == -1:
        raise CheckError(f"{where}: could not find {signature}")
    if code.find(signature, start + 1) != -1:
        raise CheckError(f"{where}: found more than one {signature}, expected 1")
    opening = code.find("{", start)
    if opening == -1:
        raise CheckError(f"{where}: {signature} has no body")
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return opening, index
    raise CheckError(f"{where}: {signature} has an unterminated body")


def window_state_problems(root: Path) -> list[str]:
    """Ways the window-state wiring (#383) can vanish without failing a build.

    Losing any one of these still compiles and still launches. The window just
    stops remembering its size, which nobody notices in review and everybody
    notices on the next launch.
    """
    problems: list[str] = []

    runner_cmakelists = _read(root, RUNNER_CMAKELISTS)
    for source in (WINDOW_STATE_STORE_SOURCE, WINDOW_STATE_POLICY_SOURCE):
        if source.name not in runner_cmakelists:
            problems.append(
                f"{RUNNER_CMAKELISTS} does not compile {source.name}, so the "
                "window cannot remember its size"
            )
    # The policy is C++17 (string_view, from_chars). apply_standard_settings
    # only asks for cxx_std_14, which is a floor: without this the standard is
    # whatever the host compiler happens to default to.
    if "cxx_std_17" not in runner_cmakelists:
        problems.append(
            f"{RUNNER_CMAKELISTS} no longer requires cxx_std_17, which the "
            f"{WINDOW_STATE_POLICY_SOURCE.name} policy needs"
        )

    my_application = _blank(_read(root, MY_APPLICATION))
    if "window_state_store_new" not in my_application:
        problems.append(
            f"{MY_APPLICATION} never calls window_state_store_new(), so the "
            "saved window geometry is never restored"
        )

    # Specifically inside my_application_shutdown(), not just somewhere in the
    # file. There is a second save on the window-recreation path in activate(),
    # so a plain substring search would keep passing while the one that runs on
    # every ordinary exit — the only one that persists the geometry a session
    # ends with — had been dropped by a merge or a regeneration.
    shutdown_start, shutdown_end = _function_body(
        my_application, RUNNER_SHUTDOWN_FUNCTION, MY_APPLICATION
    )
    if "window_state_store_save" not in my_application[shutdown_start:shutdown_end]:
        problems.append(
            f"{MY_APPLICATION}: my_application_shutdown() never calls "
            "window_state_store_save(), so an ordinary exit never writes the "
            "window geometry and every launch is a first one"
        )

    return problems


def runner_identity_problems(root: Path) -> list[str]:
    """Identity calls the runner has to make, in the places they still work.

    See the RUNNER_IDENTITY_CALLS comment above for why each one exists and why
    two of them are order-dependent. Everything here builds and launches
    perfectly when it is wrong; the only symptom is a window the desktop no
    longer recognises as Linthra.
    """
    text = _read(root, MY_APPLICATION)
    code = _blank(text, comments=True, strings=True)
    problems: list[str] = []

    bodies: dict[str, tuple[int, int]] = {}
    for signature in (RUNNER_IDENTITY_NEW_FUNCTION, RUNNER_IDENTITY_STARTUP_FUNCTION):
        bodies[signature] = _function_body(code, signature, MY_APPLICATION)

    startup_start, startup_end = bodies[RUNNER_IDENTITY_STARTUP_FUNCTION]
    chain_up = code.find(RUNNER_STARTUP_CHAIN_UP, startup_start, startup_end)
    if chain_up == -1:
        problems.append(
            f"{MY_APPLICATION}: my_application_startup() never chains up to "
            "GtkApplication::startup, so gtk_init() is never reached"
        )

    for call, (signature, argument, why) in RUNNER_IDENTITY_CALLS.items():
        pattern = re.compile(rf"\b{re.escape(call)}\s*\(\s*{re.escape(argument)}\s*\)")
        matches = list(pattern.finditer(code))
        if not matches:
            problems.append(f"{MY_APPLICATION}: no {call}({argument}) call: {why}")
            continue
        if len(matches) > 1:
            problems.append(
                f"{MY_APPLICATION}: {len(matches)} {call}({argument}) calls, expected 1"
            )
            continue
        where = matches[0].start()
        body_start, body_end = bodies[signature]
        function = signature.split("(")[0].split()[-1]
        if not body_start < where < body_end:
            problems.append(
                f"{MY_APPLICATION}: {call}({argument}) is not inside "
                f"{function}(), which is the only place it takes effect"
            )
            continue
        if (
            call in RUNNER_IDENTITY_CALLS_AFTER_CHAIN_UP
            and chain_up != -1
            and where < chain_up
        ):
            problems.append(
                f"{MY_APPLICATION}: {call}({argument}) runs before "
                "my_application_startup() chains up, so gtk_init() overwrites it"
            )

    # The id itself stays in linux/CMakeLists.txt. A literal here would be a
    # second copy that no longer moves when APPLICATION_ID does.
    app_id = android_application_id(root)
    if f'"{app_id}"' in _blank(text, comments=True, strings=False):
        problems.append(
            f"{MY_APPLICATION}: the application id is written out as a string "
            f"literal; use the {APPLICATION_ID_MACRO} macro that "
            f"{RUNNER_CMAKELISTS} defines so there is one copy of it"
        )

    return problems


def absolute_paths_under_linux(root: Path) -> list[str]:
    """Absolute host paths hardcoded in the committed Linux build files.

    Only the files Linthra owns are scanned. `linux/flutter/ephemeral` is
    generated per build and is not in git.
    """
    findings: list[str] = []
    linux_dir = root / "linux"
    for path in sorted(linux_dir.rglob("*")):
        if not path.is_file():
            continue
        if "ephemeral" in path.relative_to(linux_dir).parts:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in ABSOLUTE_PATH_PATTERN.findall(line):
                findings.append(f"{path.relative_to(root)}:{line_number}: {match}")
    return findings


def check(root: Path) -> list[str]:
    """Return the problems found, empty when the runner is consistent."""
    problems: list[str] = []

    def compare(label: str, actual: str, expected: str, source: str) -> None:
        if actual != expected:
            problems.append(f"{label} is {actual!r} but {source} says {expected!r}")

    compare(
        "linux/CMakeLists.txt APPLICATION_ID",
        application_id(root),
        android_application_id(root),
        "android/app/build.gradle applicationId",
    )
    compare(
        "linux/CMakeLists.txt BINARY_NAME",
        binary_name(root),
        pubspec_name(root),
        "pubspec.yaml name",
    )
    compare(
        "linux/runner/my_application.cc kApplicationName",
        window_title(root),
        app_display_name(root),
        "lib/core/app_info.dart AppInfo.name",
    )

    # The installed desktop entry repeats the identity above; it is checked
    # against the same sources of truth, not against the runner's copy, so a
    # runner that drifts is reported once rather than twice.
    problems.extend(desktop_entry_problems(root))
    problems.extend(desktop_entry_install_problems(root))
    problems.extend(flatpak_permission_problems(root))

    # The application icon (#436): `Icon=` above is only a name, so this is
    # what connects it to a file the built Flatpak actually contains.
    problems.extend(icon_install_problems(root))
    problems.extend(icon_source_problems(root))

    # The folder-picker channel (#438): two strings that have to agree, and a
    # source file that has to be compiled and registered.
    problems.extend(folder_picker_problems(root))

    # The window-lifecycle channel (#401): the same shape of contract, plus the
    # single-instance registration the close behaviour depends on.
    problems.extend(window_lifecycle_problems(root))

    # The window identity (#554): the GTK/GDK calls that make the *running*
    # window answer to the same id as everything installed above, in the places
    # where they still take effect.
    problems.extend(runner_identity_problems(root))
    problems.extend(window_state_problems(root))

    # Window metrics: a minimum larger than the default would open the window
    # already clamped, which reads as the app ignoring its own default.
    minimum_width = window_metric(root, "kMinimumWindowWidth")
    minimum_height = window_metric(root, "kMinimumWindowHeight")
    default_width = window_metric(root, "kDefaultWindowWidth")
    default_height = window_metric(root, "kDefaultWindowHeight")
    if minimum_width > default_width or minimum_height > default_height:
        problems.append(
            f"minimum window size {minimum_width}x{minimum_height} exceeds the "
            f"default {default_width}x{default_height}"
        )
    if minimum_width <= 0 or minimum_height <= 0:
        problems.append("minimum window size must be positive")

    # The offline-build seam. Losing it does not break any build that has a
    # network, which is exactly why it needs a guard.
    cmakelists = _read(root, CMAKELISTS)
    if SQLITE_SOURCE_VARIABLE not in cmakelists:
        problems.append(
            f"{CMAKELISTS} no longer honours {SQLITE_SOURCE_VARIABLE}, so the "
            "Linux build cannot be made to skip the SQLite download "
            "(see docs/linux-desktop.md)"
        )
    elif "FETCHCONTENT_SOURCE_DIR_SQLITE3" not in cmakelists:
        problems.append(
            f"{CMAKELISTS} sets {SQLITE_SOURCE_VARIABLE} but never forwards it "
            "to FETCHCONTENT_SOURCE_DIR_SQLITE3, so it has no effect"
        )

    # Clang 22 diagnoses the old json.hpp bundled by
    # flutter_secure_storage_linux 1.2.3. The exception must remain both unique
    # and PRIVATE to that plugin; a directory/global suppression would weaken
    # the runner's -Werror contract and hide unrelated warnings.
    cmake_code = "\n".join(
        line for line in cmakelists.splitlines() if not line.lstrip().startswith("#")
    )
    if (
        cmake_code.count(SECURE_STORAGE_WARNING_EXCEPTION) != 1
        or SECURE_STORAGE_SCOPED_EXCEPTION.search(cmake_code) is None
    ):
        problems.append(
            "the deprecated-literal-operator exception must appear exactly "
            f"once and be PRIVATE to {SECURE_STORAGE_TARGET}"
        )

    for finding in absolute_paths_under_linux(root):
        problems.append(f"absolute host path in the Linux build: {finding}")

    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check the committed Linux runner against Linthra's identity."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root to check (default: this repository)",
    )
    args = parser.parse_args(argv)

    try:
        problems = check(args.root)
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    if problems:
        print("Linux runner configuration problems:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    print("Linux runner configuration OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
