#include "linthra_desktop/window_state.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace linthra::desktop {
namespace {

constexpr std::string_view kWhitespace = " \t\r\n";

std::string_view Trim(std::string_view value) {
    const std::size_t begin = value.find_first_not_of(kWhitespace);
    if (begin == std::string_view::npos) {
        return {};
    }
    const std::size_t end = value.find_last_not_of(kWhitespace);
    return value.substr(begin, end - begin + 1);
}

// Reads a whole decimal integer, or leaves `out` untouched. from_chars is used
// rather than std::stoi because a malformed value here is ordinary input, not
// an exceptional case: half of what this parser has to survive is a file that
// was truncated mid-write by a crash or a full disk.
bool ReadInt(std::string_view value, int* out) {
    value = Trim(value);
    if (value.empty()) {
        return false;
    }
    int parsed = 0;
    const char* begin = value.data();
    const char* end = begin + value.size();
    const std::from_chars_result result = std::from_chars(begin, end, parsed);
    if (result.ec != std::errc() || result.ptr != end) {
        return false;
    }
    *out = parsed;
    return true;
}

void ReadBool(std::string_view value, bool* out) {
    value = Trim(value);
    if (value == "true" || value == "1") {
        *out = true;
    } else if (value == "false" || value == "0") {
        *out = false;
    }
}

// The overlap between two rectangles, in pixels. Zero on either axis means they
// do not meet.
//
// Widened to 64 bits on purpose. A hand-edited or truncated state file can hold
// a coordinate near INT_MAX that parses perfectly well, and adding a width to it
// in `int` is signed overflow — undefined behaviour, which an optimising build
// is free to turn into a crash or into a nonsense answer, before the caller ever
// gets to reject the position. In 64 bits every value this parser can produce
// adds and subtracts exactly, so the rejection happens on the numbers rather
// than on the compiler's mood. The result is clamped back to an int, which it
// always fits: an overlap is never wider than the work area.
void Intersection(const WindowGeometry& window, const WorkArea& area,
                  int* overlap_width, int* overlap_height) {
    const std::int64_t left =
        std::max<std::int64_t>(window.x, area.x);
    const std::int64_t right = std::min<std::int64_t>(
        static_cast<std::int64_t>(window.x) + window.width,
        static_cast<std::int64_t>(area.x) + area.width);
    const std::int64_t top = std::max<std::int64_t>(window.y, area.y);
    const std::int64_t bottom = std::min<std::int64_t>(
        static_cast<std::int64_t>(window.y) + window.height,
        static_cast<std::int64_t>(area.y) + area.height);
    *overlap_width = static_cast<int>(std::max<std::int64_t>(0, right - left));
    *overlap_height = static_cast<int>(std::max<std::int64_t>(0, bottom - top));
}

}  // namespace

WindowGeometry ParseWindowState(std::string_view text) {
    WindowGeometry geometry;
    bool saw_x = false;
    bool saw_y = false;

    while (!text.empty()) {
        const std::size_t newline = text.find('\n');
        const std::string_view line =
            Trim(newline == std::string_view::npos ? text
                                                   : text.substr(0, newline));
        text = newline == std::string_view::npos ? std::string_view()
                                                 : text.substr(newline + 1);
        if (line.empty() || line.front() == '#' || line.front() == '[') {
            continue;
        }
        const std::size_t separator = line.find('=');
        if (separator == std::string_view::npos) {
            continue;
        }
        const std::string_view key = Trim(line.substr(0, separator));
        const std::string_view value = line.substr(separator + 1);

        if (key == "width") {
            ReadInt(value, &geometry.width);
        } else if (key == "height") {
            ReadInt(value, &geometry.height);
        } else if (key == "x") {
            saw_x = ReadInt(value, &geometry.x) || saw_x;
        } else if (key == "y") {
            saw_y = ReadInt(value, &geometry.y) || saw_y;
        } else if (key == "maximized") {
            ReadBool(value, &geometry.maximized);
        }
    }

    geometry.has_position = saw_x && saw_y;
    return geometry;
}

std::string FormatWindowState(const WindowGeometry& geometry) {
    std::string out;
    out += "# Linthra window state. Deleting this file resets the window.\n";
    out += "width=" + std::to_string(geometry.width) + "\n";
    out += "height=" + std::to_string(geometry.height) + "\n";
    if (geometry.has_position) {
        out += "x=" + std::to_string(geometry.x) + "\n";
        out += "y=" + std::to_string(geometry.y) + "\n";
    }
    out += std::string("maximized=") + (geometry.maximized ? "true" : "false") +
           "\n";
    return out;
}

bool IsSizeUsable(const WindowGeometry& saved) {
    return saved.width > 0 && saved.height > 0 &&
           saved.width <= kMaxReasonableDimension &&
           saved.height <= kMaxReasonableDimension;
}

bool IsPositionUsable(const WindowGeometry& saved,
                      const std::vector<WorkArea>& work_areas) {
    if (!saved.has_position || !IsSizeUsable(saved)) {
        return false;
    }
    for (const WorkArea& area : work_areas) {
        if (area.width <= 0 || area.height <= 0) {
            continue;
        }
        // A title bar above the monitor's work area cannot be grabbed, so a
        // window there is unreachable however much of its body is visible.
        if (saved.y < area.y) {
            continue;
        }
        int overlap_width = 0;
        int overlap_height = 0;
        Intersection(saved, area, &overlap_width, &overlap_height);
        if (overlap_width >= std::min(kMinVisibleWidth, saved.width) &&
            overlap_height >= std::min(kMinVisibleHeight, saved.height)) {
            return true;
        }
    }
    return false;
}

WindowGeometry ResolveWindowState(const WindowGeometry& saved,
                                  const WindowLimits& limits,
                                  const std::vector<WorkArea>& work_areas) {
    WindowGeometry resolved;
    if (IsSizeUsable(saved)) {
        resolved.width = saved.width;
        resolved.height = saved.height;
        resolved.maximized = saved.maximized;
    } else {
        // A corrupt size says nothing about whether the window was maximized,
        // so a first-launch default is the honest answer for both.
        resolved.width = limits.default_width;
        resolved.height = limits.default_height;
    }
    resolved.width = std::max(resolved.width, limits.min_width);
    resolved.height = std::max(resolved.height, limits.min_height);

    // Checked against the geometry the window will actually open with, not the
    // one the file claimed. A saved 1x1 window at the very corner of a monitor
    // is "visible" as a 1x1 rectangle and completely unreachable once the
    // minimum size has been applied to it, so validating the saved size would
    // accept a position that strands the real window off the screen.
    WindowGeometry candidate = resolved;
    candidate.x = saved.x;
    candidate.y = saved.y;
    candidate.has_position = saved.has_position;
    if (IsPositionUsable(candidate, work_areas)) {
        resolved.x = candidate.x;
        resolved.y = candidate.y;
        resolved.has_position = true;
    }
    return resolved;
}

}  // namespace linthra::desktop
