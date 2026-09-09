#include "linthra_audio/dsp.hpp"

#include "check.hpp"

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <new>
#include <vector>

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

namespace {

using linthra::audio::DspChain;
using linthra::audio::DspConfig;

constexpr float kSampleRate = 48'000.0F;
constexpr float kPi = 3.14159265358979323846F;

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

    DspChain chain(kSampleRate);
    chain.configure(config);
    // One warm-up block outside the measurement, so nothing lazily built on
    // first use is charged to the steady-state path.
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

    return linthra::audio::test::report("realtime allocation");
}
