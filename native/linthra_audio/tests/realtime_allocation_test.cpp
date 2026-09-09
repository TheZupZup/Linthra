#include "linthra_audio/dsp.hpp"

#include "check.hpp"

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <new>
#include <vector>

// Replacing the plain forms alone would leave a hole: an over-aligned C++17
// type routes to the `std::align_val_t` overloads instead, and an allocation
// through those would go uncounted — leaving the no-allocation check reporting
// a comfortable zero for the one case it exists to catch.

// The processing callback runs on the audio thread, where an allocation is a
// dropped buffer waiting to happen. The header says process() only performs
// bounded arithmetic over already-prepared state; both #337 and #342 ask for
// that to stay true.
//
// A comment cannot enforce it, so this binary replaces global operator new and
// counts. It lives in its own executable on purpose: the replacement is
// program-wide, and the other DSP tests should keep the ordinary allocator.

namespace {
std::atomic<long> allocations{0};
}  // namespace

void* operator new(std::size_t size) {
    allocations.fetch_add(1, std::memory_order_relaxed);
    // Never return nullptr from the throwing form.
    void* memory = std::malloc(size == 0 ? 1 : size);
    if (memory == nullptr) {
        throw std::bad_alloc();
    }
    return memory;
}

void* operator new[](std::size_t size) {
    return ::operator new(size);
}

void operator delete(void* memory) noexcept {
    std::free(memory);
}

void operator delete[](void* memory) noexcept {
    std::free(memory);
}

void operator delete(void* memory, std::size_t) noexcept {
    std::free(memory);
}

void operator delete[](void* memory, std::size_t) noexcept {
    std::free(memory);
}

void* operator new(std::size_t size, std::align_val_t alignment) {
    allocations.fetch_add(1, std::memory_order_relaxed);
    const std::size_t align = static_cast<std::size_t>(alignment);
    // aligned_alloc wants a size that is a multiple of the alignment.
    const std::size_t rounded = ((size == 0 ? 1 : size) + align - 1) / align * align;
    void* memory = std::aligned_alloc(align, rounded);
    if (memory == nullptr) {
        throw std::bad_alloc();
    }
    return memory;
}

void* operator new[](std::size_t size, std::align_val_t alignment) {
    return ::operator new(size, alignment);
}

void operator delete(void* memory, std::align_val_t) noexcept {
    std::free(memory);
}

void operator delete[](void* memory, std::align_val_t) noexcept {
    std::free(memory);
}

void operator delete(void* memory, std::size_t, std::align_val_t) noexcept {
    std::free(memory);
}

void operator delete[](void* memory, std::size_t, std::align_val_t) noexcept {
    std::free(memory);
}

namespace {

using linthra::audio::DspChain;
using linthra::audio::DspConfig;

constexpr float kSampleRate = 48'000.0F;
constexpr float kPi = 3.14159265358979323846F;

/// An over-aligned type, so allocating one routes to the std::align_val_t
/// overloads instead of the plain ones.
struct alignas(64) CacheLine {
    float samples[16];
};

/// Allocations recorded while [body] ran.
template <typename Body>
long allocations_during(Body body) {
    const long before = allocations.load(std::memory_order_relaxed);
    body();
    return allocations.load(std::memory_order_relaxed) - before;
}

}  // namespace

int main() {
    // Everything the measured region touches is built first, so the count is
    // about process() and nothing else.
    constexpr std::size_t block_frames = 256;
    constexpr std::size_t blocks = 64;
    std::vector<float> block(block_frames * 2);
    for (std::size_t frame = 0; frame < block_frames; ++frame) {
        const float time = static_cast<float>(frame) / kSampleRate;
        // Deliberately over the ceiling, so the limiter is engaging and
        // releasing throughout rather than sitting at unity.
        const float sample = 1.8F * std::sin(2.0F * kPi * 440.0F * time);
        block[frame * 2] = sample;
        block[frame * 2 + 1] = sample * 0.6F;
    }

    DspConfig config{};
    config.preamp_db = -3.0F;
    config.limiter_enabled = true;
    config.band_count = 3;
    config.bands[0] = {true, 80.0F, 4.0F, 0.9F};
    config.bands[1] = {true, 1'000.0F, -3.0F, 1.2F};
    config.bands[2] = {true, 8'000.0F, 6.0F, 0.7F};

    // The very first call, on a chain that has never processed anything. It
    // runs on the audio callback like every other one, so state built lazily on
    // first use would be just as fatal there — warming up outside the count
    // would hide exactly that.
    DspChain first(kSampleRate);
    first.configure(config);
    const long during_first_call = allocations_during([&] {
        first.process(block.data(), block_frames, 2);
    });
    CHECK(during_first_call == 0);

    DspChain chain(kSampleRate);
    chain.configure(config);
    chain.process(block.data(), block_frames, 2);

    const long during_process = allocations_during([&] {
        for (std::size_t index = 0; index < blocks; ++index) {
            chain.process(block.data(), block_frames, 2);
        }
    });
    CHECK(during_process == 0);

    // reset() is called from the host between streams and is on the same
    // no-allocation footing.
    const long during_reset = allocations_during([&] { chain.reset(); });
    CHECK(during_reset == 0);

    // Mono and the bypassed channel counts take the same path.
    const long during_other_shapes = allocations_during([&] {
        chain.process(block.data(), block_frames * 2, 1);
        chain.process(block.data(), block_frames, 3);
        chain.process(block.data(), 0, 2);
    });
    CHECK(during_other_shapes == 0);

    // Sanity: the counter is actually wired up. Without this, a build where the
    // replacement never took effect would report a comfortable zero.
    const long during_allocation = allocations_during([] {
        std::vector<float> scratch(1'024);
        // Keep the allocation from being optimised away.
        scratch[0] = 1.0F;
        CHECK(scratch[0] == 1.0F);
    });
    CHECK(during_allocation > 0);

    // ...and wired up for over-aligned types too, which take the separate
    // std::align_val_t overloads rather than the ones above.
    //
    // Allocated through a vector rather than a bare new/delete pair on purpose:
    // C++14 permits eliding an allocation outright, and at -O2 GCC does exactly
    // that to a local deleted right after it is made, which leaves the counter
    // reading zero for the very case this is here to prove.
    const long during_aligned_allocation = allocations_during([] {
        std::vector<CacheLine> wide(4);
        wide[0].samples[0] = 1.0F;
        CHECK(wide[0].samples[0] == 1.0F);
    });
    CHECK(during_aligned_allocation > 0);

    return linthra::audio::test::report("realtime allocation");
}
