#ifndef LINTHRA_DESKTOP_WINDOW_STATE_HPP_
#define LINTHRA_DESKTOP_WINDOW_STATE_HPP_

#include <string>
#include <string_view>
#include <vector>

// Remembering the Linux window's geometry across restarts (issue #383).
//
// Everything in this header is pure: no GTK, no GDK, no filesystem. That is the
// point. The Linux runner has to do the toolkit half — read the config file,
// ask GDK for the monitors, call gtk_window_move() — but every rule about what
// a saved geometry *means* lives here, where it can be tested without a display
// server, a window manager, or a second monitor to unplug.
namespace linthra::desktop {

// One window geometry, as saved or as resolved.
struct WindowGeometry {
    int width = 0;
    int height = 0;
    int x = 0;
    int y = 0;

    // Whether x/y carry a real position. A Wayland session cannot report or
    // restore one, so a state file written there has a size and no position,
    // and that is not a defect to repair.
    bool has_position = false;

    bool maximized = false;
};

// A monitor's usable area, panels and docks already subtracted.
struct WorkArea {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
};

// What the runner will accept, and what it falls back to.
struct WindowLimits {
    int min_width = 0;
    int min_height = 0;
    int default_width = 0;
    int default_height = 0;
};

// Largest dimension a saved size may claim before it is treated as corrupt
// rather than as an enormous monitor. Well past any real display, and far short
// of the values a truncated or hand-edited file produces.
inline constexpr int kMaxReasonableDimension = 32000;

// How much of the window has to land on a monitor for its saved position to be
// worth restoring. A window peeking in by a few pixels is, in practice, a
// window the user cannot grab.
inline constexpr int kMinVisibleWidth = 120;
inline constexpr int kMinVisibleHeight = 60;

// Parses the `key=value` text written by FormatWindowState.
//
// Deliberately forgiving: unknown keys, blank lines, comments and malformed
// numbers are ignored rather than failing the whole file. A state file is a
// convenience, and the worst it may ever do is cost the user their window size
// — never a launch.
WindowGeometry ParseWindowState(std::string_view text);

// Renders a geometry as the text the state file holds.
std::string FormatWindowState(const WindowGeometry& geometry);

// Whether a saved size is usable at all, before any clamping.
bool IsSizeUsable(const WindowGeometry& saved);

// Whether a saved position still lands on one of the monitors that exist now.
//
// Requires a real patch of the window to be inside a work area *and* its top
// edge not to sit above that area: a window whose title bar is off the top of
// the screen cannot be moved with the mouse, which is the state a disconnected
// monitor used to leave behind.
bool IsPositionUsable(const WindowGeometry& saved,
                      const std::vector<WorkArea>& work_areas);

// The geometry to open with: the saved one where it is sane, the defaults where
// it is not, clamped to the runner's minimum either way.
//
// The returned geometry's has_position is false whenever the caller should let
// the window manager place the window itself, which is both the Wayland case
// and the disconnected-monitor one.
WindowGeometry ResolveWindowState(const WindowGeometry& saved,
                                  const WindowLimits& limits,
                                  const std::vector<WorkArea>& work_areas);

}  // namespace linthra::desktop

#endif  // LINTHRA_DESKTOP_WINDOW_STATE_HPP_
