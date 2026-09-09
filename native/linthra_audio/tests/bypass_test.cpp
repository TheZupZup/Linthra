#include "linthra_audio/dsp.hpp"

#include "check.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <algorithm>
#include <cstring>
#include <vector>

// Bypass transparency (#342).
//
// "Transparent" here means *bit-exact*, not merely close: the samples that come
// out are the samples that went in, compared with ==. That is a stronger claim
// than a tolerance, and it is one the current chain can honestly make, because
// every stage that is off multiplies by a value that is exactly 1.0F:
//
//   * preamp 0 dB  -> powf(10, 0/20) == 1.0F
//   * a band with |gain_db| <= 0.0001 is left disabled and never runs
//   * the limiter's gain starts at 1.0F and only leaves it once a frame peak
//     actually exceeds the ceiling
//
// and multiplying a finite float by exactly 1.0F returns that float unchanged.
//
// The one place an exact comparison would be dishonest is *after* the limiter
// has engaged: its release is smooth, so a quiet passage that follows a loud one
// is still being attenuated on the way back to unity. That case is covered at
// the end as the limit of the guarantee rather than papered over with a
// tolerance.

namespace {

using linthra::audio::DspChain;
using linthra::audio::DspConfig;

/// Whether two floats have the same object representation.
///
/// `==` is not strong enough for a bit-exactness claim: it reports `-0.0F` and
/// `0.0F` as equal, so a chain that quietly lost the sign of zero would sail
/// through a suite that deliberately feeds both signs. Comparing the bits says
/// what the tests below actually mean.
bool bits_equal(float left, float right) {
    std::uint32_t left_bits = 0;
    std::uint32_t right_bits = 0;
    std::memcpy(&left_bits, &left, sizeof(float));
    std::memcpy(&right_bits, &right, sizeof(float));
    return left_bits == right_bits;
}

/// The ceiling the limiter is configured with, computed exactly the way
/// DspChain::configure does, so "just under the threshold" means the same
/// number on both sides of the test.
float threshold_linear(float db) {
    return std::pow(10.0F, db / 20.0F);
}

/// Interesting sample values: silence in both signs, small and normal levels,
/// and the extremes a decoder can hand us. Everything here is below the default
/// -0.3 dBFS ceiling except the last pair, which is used only where the limiter
/// is off.
constexpr std::array<float, 11> kQuietSamples{
    0.0F, -0.0F, 1.0e-7F, -1.0e-7F, 0.25F, -0.25F,
    0.5F, -0.5F, 0.75F,   -0.75F,   0.9F,
};

/// Runs [samples] through [chain] as an interleaved buffer of [channels] and
/// checks every output sample is the input, bit for bit.
void expect_exact(DspChain& chain, const std::vector<float>& samples, std::uint32_t channels) {
    std::vector<float> buffer = samples;
    chain.process(buffer.data(), buffer.size() / channels, channels);
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        CHECK(bits_equal(buffer[index], samples[index]));
    }
}

std::vector<float> quiet_buffer() {
    return std::vector<float>(kQuietSamples.begin(), kQuietSamples.end());
}

void bypass_is_bit_exact_with_the_limiter_off() {
    DspConfig config{};
    config.limiter_enabled = false;

    // Mono, and the same samples read as stereo frames. The buffer has an odd
    // length, so the stereo pass deliberately uses one fewer sample rather than
    // reading past the end.
    DspChain mono(48'000.0F);
    mono.configure(config);
    expect_exact(mono, quiet_buffer(), 1);

    std::vector<float> stereo = quiet_buffer();
    stereo.pop_back();
    DspChain chain(48'000.0F);
    chain.configure(config);
    expect_exact(chain, stereo, 2);

    // The extremes only belong here, where nothing can pull them down.
    DspChain extremes(48'000.0F);
    extremes.configure(config);
    expect_exact(extremes, std::vector<float>{1.0F, -1.0F, 0.999999F, -0.999999F}, 2);
}

void bypass_is_bit_exact_while_the_limiter_is_armed() {
    // The default config arms the limiter, so this is the case that actually
    // ships: a signal that never reaches the ceiling must come out untouched.
    DspChain chain(48'000.0F);
    chain.configure(DspConfig{});
    CHECK(chain.config().limiter_enabled);
    expect_exact(chain, quiet_buffer(), 2);
    expect_exact(chain, quiet_buffer(), 1);
}

void a_sample_exactly_at_the_ceiling_is_untouched() {
    // The limiter engages on frame_peak > threshold, so the threshold itself is
    // the last value that passes through unchanged. Worth pinning: turning that
    // into >= would start attenuating a signal that is already legal.
    DspConfig config{};
    DspChain chain(48'000.0F);
    chain.configure(config);
    const float ceiling = threshold_linear(config.limiter_threshold_db);
    expect_exact(chain, std::vector<float>{ceiling, -ceiling}, 2);
}

void silence_stays_silence() {
    for (const bool limiter : {false, true}) {
        for (const std::uint32_t channels : {1U, 2U}) {
            DspConfig config{};
            config.limiter_enabled = limiter;
            DspChain chain(48'000.0F);
            chain.configure(config);
            std::vector<float> buffer(64, 0.0F);
            chain.process(buffer.data(), buffer.size() / channels, channels);
            for (const float sample : buffer) {
                CHECK(bits_equal(sample, 0.0F));
            }
        }
    }
}

void a_flat_equalizer_band_is_bypassed() {
    // A band at 0 dB is arithmetically a no-op, and configure() leaves it
    // disabled rather than running a biquad that would introduce rounding.
    DspConfig config{};
    config.limiter_enabled = false;
    config.band_count = 1;
    config.bands[0] = {true, 1'000.0F, 0.0F, 0.707F};
    DspChain chain(48'000.0F);
    chain.configure(config);
    expect_exact(chain, quiet_buffer(), 2);
}

void a_disabled_band_is_bypassed_even_with_gain() {
    DspConfig config{};
    config.limiter_enabled = false;
    config.band_count = 1;
    config.bands[0] = {false, 1'000.0F, 9.0F, 0.707F};
    DspChain chain(48'000.0F);
    chain.configure(config);
    expect_exact(chain, quiet_buffer(), 2);

    // The same band left out of band_count is equally inert.
    DspConfig counted{};
    counted.limiter_enabled = false;
    counted.band_count = 0;
    counted.bands[0] = {true, 1'000.0F, 9.0F, 0.707F};
    DspChain ignored(48'000.0F);
    ignored.configure(counted);
    expect_exact(ignored, quiet_buffer(), 2);
}

void an_unsupported_call_leaves_the_buffer_alone() {
    // The header promises an unsupported channel count is bypassed rather than
    // risking a bad audio callback. Zero frames and a null buffer are the other
    // two shapes a host can hand in.
    DspConfig config{};
    config.preamp_db = -12.0F;  // loud enough to be obvious if it ran
    DspChain chain(48'000.0F);
    chain.configure(config);

    for (const std::uint32_t channels : {0U, 3U, 8U}) {
        std::vector<float> buffer = quiet_buffer();
        const std::vector<float> original = buffer;
        chain.process(buffer.data(), 2, channels);
        for (std::size_t index = 0; index < buffer.size(); ++index) {
            CHECK(bits_equal(buffer[index], original[index]));
        }
    }

    std::vector<float> buffer = quiet_buffer();
    const std::vector<float> original = buffer;
    chain.process(buffer.data(), 0, 2);
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        CHECK(bits_equal(buffer[index], original[index]));
    }
    chain.process(nullptr, 4, 2);
}

/// Runs [seconds] of quiet stereo through [chain] in blocks and returns the
/// gain it is applying at the end, measured from what came back out.
float gain_after_quiet_seconds(DspChain& chain, int seconds) {
    constexpr float probe = 0.1F;
    constexpr std::size_t block_frames = 480;
    std::vector<float> block(block_frames * 2, probe);
    const int blocks = seconds * 48'000 / static_cast<int>(block_frames);
    for (int index = 0; index < blocks; ++index) {
        std::fill(block.begin(), block.end(), probe);
        chain.process(block.data(), block_frames, 2);
    }
    return block[0] / probe;
}

void the_limiter_never_releases_all_the_way_back_to_transparency() {
    // The honest edge of the guarantee, and the one place a tolerance would be
    // hiding something real.
    //
    // One loud frame pulls the gain down, and the quiet frames that follow are
    // still attenuated on the way back to unity, so they are not bit-exact.
    // The part worth pinning is that they never become bit-exact either. The
    // release is
    //
    //     gain += (1 - gain) * step
    //
    // and once `(1 - gain) * step` falls below half an ULP of a float near 1.0
    // the addition rounds to nothing and the gain stalls short of unity. With
    // the default 80 ms release at 48 kHz that floor is ~0.99989, reached in
    // well under a second and unmoved by another minute of silence.
    //
    // About -0.001 dB, so nobody will hear it, but it does mean "transparent
    // again once the limiter releases" is not a promise this chain keeps.
    // `reset()`, which a host calls between streams, is what actually restores
    // exactness, and that is the guarantee the suite claims.
    DspChain chain(48'000.0F);
    chain.configure(DspConfig{});

    std::array<float, 2> hot{4.0F, 4.0F};
    chain.process(hot.data(), 1, 2);

    std::array<float, 2> quiet{0.5F, 0.5F};
    chain.process(quiet.data(), 1, 2);
    CHECK(!bits_equal(quiet[0], 0.5F));
    CHECK(quiet[0] < 0.5F);
    CHECK(quiet[0] > 0.0F);

    // Close to unity after a second, and no closer after five: stalled, not
    // still converging.
    const float after_one = gain_after_quiet_seconds(chain, 1);
    const float after_five = gain_after_quiet_seconds(chain, 5);
    CHECK(after_one > 0.999F);
    CHECK(after_one < 1.0F);
    CHECK(bits_equal(after_five, after_one));
    CHECK(!bits_equal(after_five, 1.0F));

    // So a quiet buffer is still not bit-exact, however long the wait.
    std::array<float, 2> late{0.5F, -0.25F};
    chain.process(late.data(), 1, 2);
    CHECK(!bits_equal(late[0], 0.5F));

    // reset() is the seam that does restore it, immediately.
    chain.reset();
    expect_exact(chain, quiet_buffer(), 2);
}

}  // namespace

int main() {
    bypass_is_bit_exact_with_the_limiter_off();
    bypass_is_bit_exact_while_the_limiter_is_armed();
    a_sample_exactly_at_the_ceiling_is_untouched();
    silence_stays_silence();
    a_flat_equalizer_band_is_bypassed();
    a_disabled_band_is_bypassed_even_with_gain();
    an_unsupported_call_leaves_the_buffer_alone();
    the_limiter_never_releases_all_the_way_back_to_transparency();
    return linthra::audio::test::report("bypass");
}
