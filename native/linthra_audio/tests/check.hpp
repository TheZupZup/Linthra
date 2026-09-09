#pragma once

#include <cmath>
#include <iostream>

// The tiny expectation harness the DSP test binaries share.
//
// These tests used to use assert(), but CI builds this target in Release and
// Release defines NDEBUG, which expands assert() to nothing. Every expectation
// was being compiled out, so the binary exited 0 without checking any DSP
// behaviour at all.
//
// check() is ordinary code, so it runs in every build type. It records the
// failure instead of aborting, which lets one run report every broken
// expectation rather than only the first, and report() turns the count into an
// exit status CTest understands.
namespace linthra::audio::test {

inline int failures = 0;

inline bool near(float left, float right, float tolerance = 1.0e-4F) {
    return std::abs(left - right) <= tolerance;
}

inline void check(bool condition, const char* expression, const char* file, int line) {
    if (condition) {
        return;
    }
    std::cerr << file << ':' << line << ": CHECK failed: " << expression << '\n';
    ++failures;
}

/// Prints a summary for [suite] and returns the process exit status.
inline int report(const char* suite) {
    if (failures != 0) {
        std::cerr << failures << ' ' << suite << " check(s) failed\n";
        return 1;
    }
    return 0;
}

}  // namespace linthra::audio::test

#define CHECK(condition)                    \
    ::linthra::audio::test::check(          \
        (condition), #condition, __FILE__, __LINE__)
