#include "linthra_desktop/window_state.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;

// Ordinary code rather than assert(): CI builds this target in Release, and
// Release defines NDEBUG, which would expand every assert() to nothing and let
// the binary exit 0 without checking anything. Same reasoning as the audio DSP
// tests next door.
void check(bool condition, const char* expression, const char* file, int line) {
    if (condition) {
        return;
    }
    std::cerr << file << ':' << line << ": CHECK failed: " << expression << '\n';
    ++failures;
}

}  // namespace

#define CHECK(condition) check((condition), #condition, __FILE__, __LINE__)

int main() {
    using linthra::desktop::FormatWindowState;
    using linthra::desktop::IsPositionUsable;
    using linthra::desktop::IsSizeUsable;
    using linthra::desktop::ParseWindowState;
    using linthra::desktop::ResolveWindowState;
    using linthra::desktop::WindowGeometry;
    using linthra::desktop::WindowLimits;
    using linthra::desktop::WorkArea;

    // The runner's own numbers, so the expectations below mean what they say.
    const WindowLimits limits{420, 600, 1180, 780};
    const std::vector<WorkArea> single_monitor{WorkArea{0, 0, 1920, 1050}};

    // --- parsing ---------------------------------------------------------

    {
        const WindowGeometry parsed = ParseWindowState(
            "# a comment\n"
            "width=1400\n"
            "height=900\n"
            "x=120\n"
            "y=64\n"
            "maximized=true\n");
        CHECK(parsed.width == 1400);
        CHECK(parsed.height == 900);
        CHECK(parsed.x == 120);
        CHECK(parsed.y == 64);
        CHECK(parsed.has_position);
        CHECK(parsed.maximized);
    }

    {
        // A Wayland session saves a size and no position, and that is a
        // complete file rather than a damaged one.
        const WindowGeometry parsed =
            ParseWindowState("width=1400\nheight=900\nmaximized=false\n");
        CHECK(parsed.width == 1400);
        CHECK(!parsed.has_position);
        CHECK(!parsed.maximized);
    }

    {
        // A position needs both halves; one alone places nothing.
        const WindowGeometry parsed =
            ParseWindowState("width=1400\nheight=900\nx=10\n");
        CHECK(!parsed.has_position);
    }

    {
        // Zero is a real coordinate: a window flush against the top-left of the
        // first monitor is exactly where a tiling WM puts one.
        const WindowGeometry parsed =
            ParseWindowState("width=1400\nheight=900\nx=0\ny=0\n");
        CHECK(parsed.has_position);
        CHECK(parsed.x == 0);
        CHECK(parsed.y == 0);
    }

    {
        // Junk is skipped, not fatal, and it does not poison the good keys.
        const WindowGeometry parsed = ParseWindowState(
            "\n"
            "[Window]\n"
            "width=1400\n"
            "height=nine hundred\n"
            "height=880\n"
            "nonsense\n"
            "unknown=42\n"
            "maximized=perhaps\n");
        CHECK(parsed.width == 1400);
        CHECK(parsed.height == 880);
        CHECK(!parsed.maximized);
    }

    {
        // Truncated mid-write, the shape a crash or a full disk leaves behind.
        const WindowGeometry parsed = ParseWindowState("width=14");
        CHECK(parsed.width == 14);
        CHECK(parsed.height == 0);
        CHECK(!IsSizeUsable(parsed));
    }

    {
        const WindowGeometry parsed = ParseWindowState("");
        CHECK(!IsSizeUsable(parsed));
        CHECK(!parsed.has_position);
    }

    {
        // A negative size is not a small window, it is a broken file.
        CHECK(!IsSizeUsable(ParseWindowState("width=-1400\nheight=900\n")));
        CHECK(!IsSizeUsable(ParseWindowState("width=1400\nheight=0\n")));
        CHECK(!IsSizeUsable(ParseWindowState("width=99999\nheight=900\n")));
    }

    // --- round trip ------------------------------------------------------

    {
        WindowGeometry saved;
        saved.width = 1300;
        saved.height = 820;
        saved.x = 40;
        saved.y = 28;
        saved.has_position = true;
        saved.maximized = true;

        const WindowGeometry parsed = ParseWindowState(FormatWindowState(saved));
        CHECK(parsed.width == saved.width);
        CHECK(parsed.height == saved.height);
        CHECK(parsed.x == saved.x);
        CHECK(parsed.y == saved.y);
        CHECK(parsed.has_position);
        CHECK(parsed.maximized);
    }

    {
        WindowGeometry saved;
        saved.width = 1300;
        saved.height = 820;
        const WindowGeometry parsed = ParseWindowState(FormatWindowState(saved));
        CHECK(!parsed.has_position);
        CHECK(parsed.width == 1300);
    }

    // --- position validity ------------------------------------------------

    {
        WindowGeometry saved;
        saved.width = 1200;
        saved.height = 800;
        saved.x = 100;
        saved.y = 50;
        saved.has_position = true;
        CHECK(IsPositionUsable(saved, single_monitor));

        // The second monitor it was on has been unplugged.
        saved.x = 2400;
        CHECK(!IsPositionUsable(saved, single_monitor));
        CHECK(IsPositionUsable(
            saved, {WorkArea{0, 0, 1920, 1050}, WorkArea{1920, 0, 1920, 1050}}));

        // Barely peeking in from the right is not reachable enough to keep.
        saved.x = 1900;
        CHECK(!IsPositionUsable(saved, single_monitor));

        // A title bar above the work area cannot be grabbed with the mouse,
        // however much of the body shows.
        saved.x = 100;
        saved.y = -40;
        CHECK(!IsPositionUsable(saved, single_monitor));

        // A panel at the top of the screen moves the work area down with it.
        saved.y = 20;
        CHECK(!IsPositionUsable(saved, {WorkArea{0, 32, 1920, 1018}}));
    }

    {
        // A coordinate near the end of the int range parses fine and must be
        // rejected on the numbers, not by overflowing the rectangle arithmetic
        // on the way there. Built through the parser, since that is where such
        // a value comes from.
        const WindowGeometry parsed = ParseWindowState(
            "width=1200\nheight=800\nx=2147483647\ny=2147483647\n");
        CHECK(parsed.has_position);
        CHECK(!IsPositionUsable(parsed, single_monitor));
        CHECK(!ResolveWindowState(parsed, limits, single_monitor).has_position);

        const WindowGeometry negative = ParseWindowState(
            "width=1200\nheight=800\nx=-2147483648\ny=-2147483648\n");
        CHECK(negative.has_position);
        CHECK(!IsPositionUsable(negative, single_monitor));
    }

    {
        // No monitors reported at all (a session still coming up): place
        // nothing rather than guessing.
        WindowGeometry saved;
        saved.width = 1200;
        saved.height = 800;
        saved.has_position = true;
        CHECK(!IsPositionUsable(saved, {}));
    }

    // --- resolution -------------------------------------------------------

    {
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=1400\nheight=900\nx=64\ny=48\n"), limits,
            single_monitor);
        CHECK(resolved.width == 1400);
        CHECK(resolved.height == 900);
        CHECK(resolved.has_position);
        CHECK(resolved.x == 64);
        CHECK(!resolved.maximized);
    }

    {
        // First launch, and every damaged file: the documented default.
        const WindowGeometry resolved =
            ResolveWindowState(ParseWindowState(""), limits, single_monitor);
        CHECK(resolved.width == limits.default_width);
        CHECK(resolved.height == limits.default_height);
        CHECK(!resolved.has_position);
        CHECK(!resolved.maximized);
    }

    {
        // A size below the runner's floor comes back at the floor, not below
        // it, so the window never opens already clamped by GTK.
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=200\nheight=120\n"), limits,
            single_monitor);
        CHECK(resolved.width == limits.min_width);
        CHECK(resolved.height == limits.min_height);
    }

    {
        // Maximized survives a restart; the size under it is remembered too, so
        // un-maximizing lands back where the user left it.
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=1400\nheight=900\nmaximized=true\n"),
            limits, single_monitor);
        CHECK(resolved.maximized);
        CHECK(resolved.width == 1400);
    }

    {
        // A corrupt size drops the maximized flag with it rather than opening
        // a default-sized window maximized for reasons the file cannot support.
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=0\nheight=0\nmaximized=true\n"), limits,
            single_monitor);
        CHECK(!resolved.maximized);
        CHECK(resolved.width == limits.default_width);
    }

    {
        // A saved size below the floor is clamped up, so the position has to be
        // judged on the clamped rectangle. A 1x1 window in the very corner is
        // "visible" as one pixel and completely unreachable at 420x600.
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=1\nheight=1\nx=1919\ny=1049\n"), limits,
            single_monitor);
        CHECK(resolved.width == limits.min_width);
        CHECK(resolved.height == limits.min_height);
        CHECK(!resolved.has_position);
    }

    {
        // The same position with a real size is still fine: the rule is about
        // what actually opens, not about distrusting corners.
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=800\nheight=600\nx=1200\ny=400\n"),
            limits, single_monitor);
        CHECK(resolved.has_position);
        CHECK(resolved.x == 1200);
    }

    {
        // The size is kept even when the position has to be thrown away: losing
        // a monitor should not also lose the window's shape.
        const WindowGeometry resolved = ResolveWindowState(
            ParseWindowState("width=1400\nheight=900\nx=4000\ny=10\n"), limits,
            single_monitor);
        CHECK(resolved.width == 1400);
        CHECK(!resolved.has_position);
    }

    if (failures == 0) {
        std::cout << "window_state tests passed\n";
    }
    return failures == 0 ? 0 : 1;
}
