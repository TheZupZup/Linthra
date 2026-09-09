#include "linthra_audio/dsp.hpp"

#include "check.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

// Limiter response (#337).
//
// The contract the realtime caller depends on, in one place so a future DSP
// change has to break a named expectation rather than quietly get worse:
//
//   * the ceiling holds on every frame, not just the first
//   * attack is immediate, there is no overshoot to ride out
//   * release is a one-pole recovery with the configured time constant
//   * the gain is stereo-linked, so the image never shifts
//   * reset() drops the ducking, so one stream cannot inherit another's

namespace {

using linthra::audio::DspChain;
using linthra::audio::DspConfig;
using linthra::audio::test::near;

constexpr float kSampleRate = 48'000.0F;
constexpr float kPi = 3.14159265358979323846F;

float threshold_linear(float db) {
    return std::pow(10.0F, db / 20.0F);
}

/// A stereo sine at [amplitude], [frames] long, interleaved.
std::vector<float> sine(std::size_t frames, float amplitude, float hz = 1'000.0F) {
    std::vector<float> buffer(frames * 2);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const float time = static_cast<float>(frame) / kSampleRate;
        const float sample = amplitude * std::sin(2.0F * kPi * hz * time);
        buffer[frame * 2] = sample;
        buffer[frame * 2 + 1] = sample;
    }
    return buffer;
}

DspChain armed(float threshold_db = -0.3F, float release_ms = 80.0F) {
    DspConfig config{};
    config.limiter_enabled = true;
    config.limiter_threshold_db = threshold_db;
    config.limiter_release_ms = release_ms;
    DspChain chain(kSampleRate);
    chain.configure(config);
    return chain;
}

/// The gain the limiter is currently applying, measured by pushing one quiet
/// frame through and reading what came back. The probe is far below the
/// ceiling, so it cannot itself trigger the limiter, but it does advance the
/// release by one frame, which every caller below accounts for.
float measure_gain(DspChain& chain) {
    constexpr float probe = 0.1F;
    std::array<float, 2> frame{probe, probe};
    chain.process(frame.data(), 1, 2);
    return frame[0] / probe;
}

void the_ceiling_holds_across_a_sustained_signal() {
    // A full second of signal 6 dB over the ceiling. A limiter that only
    // catches the first frame, or one whose release outruns the next peak,
    // fails here even though a single-frame test would pass.
    DspChain chain = armed();
    const float ceiling = threshold_linear(-0.3F);
    const std::vector<float> input = sine(static_cast<std::size_t>(kSampleRate), 2.0F);
    std::vector<float> buffer = input;
    chain.process(buffer.data(), buffer.size() / 2, 2);

    float peak = 0.0F;
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        const float sample = buffer[index];
        CHECK(std::isfinite(sample));
        peak = std::max(peak, std::abs(sample));
        // Gain is a scalar, so the waveform keeps its shape. Every check above
        // reads magnitudes, and a limiter that rectified the negative half
        // would satisfy all of them while wrecking the signal.
        if (sample != 0.0F && input[index] != 0.0F) {
            CHECK(std::signbit(sample) == std::signbit(input[index]));
        }
    }
    CHECK(peak <= ceiling + 1.0e-4F);
    // ...and it is limiting, not muting: the signal still reaches the ceiling.
    CHECK(peak > ceiling * 0.9F);
}

void a_louder_signal_does_not_get_louder_output() {
    // Doubling the input again must not move the output ceiling at all.
    const float ceiling = threshold_linear(-0.3F);
    float previous_peak = 0.0F;
    for (const float amplitude : {1.5F, 3.0F, 12.0F}) {
        DspChain chain = armed();
        std::vector<float> buffer = sine(4'800, amplitude);
        chain.process(buffer.data(), buffer.size() / 2, 2);
        float peak = 0.0F;
        for (const float sample : buffer) {
            peak = std::max(peak, std::abs(sample));
        }
        CHECK(peak <= ceiling + 1.0e-4F);
        if (previous_peak > 0.0F) {
            CHECK(near(peak, previous_peak, 1.0e-3F));
        }
        previous_peak = peak;
    }
}

void a_lower_threshold_lowers_the_ceiling() {
    // Upper bounds alone would let every setting collapse to the lowest one:
    // an implementation that limited everything to -12 dB satisfies "<= -0.3"
    // and "<= -6" too. Each peak has to reach its *own* ceiling, and the
    // ceilings have to come down in order. That is the contract being named.
    float previous_peak = 0.0F;
    for (const float threshold_db : {-0.3F, -6.0F, -12.0F}) {
        DspChain chain = armed(threshold_db);
        std::vector<float> buffer = sine(4'800, 2.0F);
        chain.process(buffer.data(), buffer.size() / 2, 2);
        float peak = 0.0F;
        for (const float sample : buffer) {
            peak = std::max(peak, std::abs(sample));
        }
        const float ceiling = threshold_linear(threshold_db);
        CHECK(peak <= ceiling + 1.0e-4F);
        CHECK(peak > ceiling * 0.9F);
        if (previous_peak > 0.0F) {
            CHECK(peak < previous_peak);
        }
        previous_peak = peak;
    }
}

void attack_is_immediate_so_the_first_loud_frame_is_already_under() {
    // Peak protection cannot afford a wind-up: the frame that goes over is the
    // frame that has to come back under, or the transient it was protecting
    // against is already in the output.
    DspChain chain = armed();
    const float ceiling = threshold_linear(-0.3F);

    std::vector<float> buffer(8, 0.0F);  // two silent stereo frames
    buffer.push_back(5.0F);              // then one very hot frame
    buffer.push_back(5.0F);
    chain.process(buffer.data(), buffer.size() / 2, 2);

    CHECK(std::abs(buffer[8]) <= ceiling + 1.0e-4F);
    CHECK(std::abs(buffer[9]) <= ceiling + 1.0e-4F);
}

void release_recovers_as_a_one_pole_toward_unity() {
    // The release is a one-pole with limiter_release_ms as its time constant,
    // so after one tau the gain has closed ~63% of the distance back to unity
    // and after five tau it is within a fraction of a percent.
    constexpr float release_ms = 100.0F;
    const auto frames_in = [](float ms) {
        return static_cast<std::size_t>(kSampleRate * ms / 1'000.0F);
    };

    DspChain chain = armed(-0.3F, release_ms);
    std::array<float, 2> hot{4.0F, 4.0F};
    chain.process(hot.data(), 1, 2);

    const float engaged = measure_gain(chain);
    CHECK(engaged < 0.5F);   // one very loud frame ducks hard
    CHECK(engaged > 0.0F);

    // Walk one time constant, then read the gain. measure_gain advances the
    // release itself, so the walk is one frame short of a whole tau.
    std::vector<float> quiet(2 * (frames_in(release_ms) - 2), 0.1F);
    chain.process(quiet.data(), quiet.size() / 2, 2);
    const float after_one_tau = measure_gain(chain);
    const float expected_one_tau = 1.0F - (1.0F - engaged) * std::exp(-1.0F);
    CHECK(near(after_one_tau, expected_one_tau, 0.02F));
    CHECK(after_one_tau > engaged);

    // Four more time constants is effectively all the way back.
    std::vector<float> rest(2 * frames_in(4.0F * release_ms), 0.1F);
    chain.process(rest.data(), rest.size() / 2, 2);
    const float recovered = measure_gain(chain);
    CHECK(recovered > 0.99F);
    CHECK(recovered <= 1.0F);
}

void a_shorter_release_recovers_sooner() {
    // Proves limiter_release_ms is wired to something, rather than the
    // recovery merely being some fixed rate that happens to look plausible.
    const auto gain_after = [](float release_ms) {
        DspChain chain = armed(-0.3F, release_ms);
        std::array<float, 2> hot{4.0F, 4.0F};
        chain.process(hot.data(), 1, 2);
        std::vector<float> quiet(2 * 2'400, 0.1F);  // 50 ms
        chain.process(quiet.data(), quiet.size() / 2, 2);
        return measure_gain(chain);
    };
    CHECK(gain_after(20.0F) > gain_after(400.0F));
}

void the_gain_is_stereo_linked_across_a_whole_buffer() {
    // One gain for both channels. Pulling only the loud channel down would
    // keep the peaks legal while quietly moving the image to the other side.
    DspChain chain = armed();
    constexpr float ratio = 0.4F;
    constexpr std::size_t frames = 4'800;
    std::vector<float> buffer(frames * 2);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const float time = static_cast<float>(frame) / kSampleRate;
        const float sample = 2.0F * std::sin(2.0F * kPi * 1'000.0F * time);
        buffer[frame * 2] = sample;
        buffer[frame * 2 + 1] = sample * ratio;
    }
    chain.process(buffer.data(), frames, 2);

    bool sawAttenuation = false;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const float left = buffer[frame * 2];
        const float right = buffer[frame * 2 + 1];
        if (std::abs(left) > 1.0e-3F) {
            CHECK(near(right / left, ratio, 1.0e-3F));
        }
        if (std::abs(left) < 2.0F * 0.99F) {
            sawAttenuation = true;
        }
    }
    CHECK(sawAttenuation);
}

void mono_is_limited_too() {
    DspChain chain = armed();
    const float ceiling = threshold_linear(-0.3F);
    std::vector<float> buffer(4'800);
    for (std::size_t frame = 0; frame < buffer.size(); ++frame) {
        const float time = static_cast<float>(frame) / kSampleRate;
        buffer[frame] = 2.0F * std::sin(2.0F * kPi * 1'000.0F * time);
    }
    const std::vector<float> input = buffer;
    chain.process(buffer.data(), buffer.size(), 1);
    float peak = 0.0F;
    for (std::size_t index = 0; index < buffer.size(); ++index) {
        const float sample = buffer[index];
        CHECK(std::abs(sample) <= ceiling + 1.0e-4F);
        peak = std::max(peak, std::abs(sample));
        if (sample != 0.0F && input[index] != 0.0F) {
            CHECK(std::signbit(sample) == std::signbit(input[index]));
        }
    }
    // ...and limited, not muted. Without this a mono-only regression that
    // zeroed every sample would satisfy the ceiling and pass, the way the
    // sustained stereo test already guards against.
    CHECK(peak > ceiling * 0.9F);
}

void an_equalizer_boost_cannot_push_past_the_ceiling() {
    // The limiter sits after the EQ, which is the whole reason it is there: a
    // +12 dB band on a signal already near full scale is exactly the case that
    // would clip without it.
    DspConfig config{};
    config.limiter_enabled = true;
    config.band_count = 1;
    config.bands[0] = {true, 1'000.0F, 12.0F, 0.707F};
    DspChain chain(kSampleRate);
    chain.configure(config);

    std::vector<float> buffer = sine(4'800, 0.9F);
    chain.process(buffer.data(), buffer.size() / 2, 2);
    const float ceiling = threshold_linear(-0.3F);
    float peak = 0.0F;
    for (const float sample : buffer) {
        CHECK(std::isfinite(sample));
        CHECK(std::abs(sample) <= ceiling + 1.0e-4F);
        peak = std::max(peak, std::abs(sample));
    }
    // ...and there is still music coming out. Every check above is an upper
    // bound, which a band that returned zero would satisfy perfectly, so the
    // suite could otherwise certify an EQ that silences playback.
    CHECK(peak > 0.5F);
}

void reset_drops_the_ducking() {
    DspChain chain = armed();
    std::array<float, 2> hot{4.0F, 4.0F};
    chain.process(hot.data(), 1, 2);
    CHECK(measure_gain(chain) < 0.5F);

    chain.reset();
    CHECK(measure_gain(chain) == 1.0F);

    // ...and the limiter is still armed. Unity gain on a quiet probe is also
    // what a reset() that threw the configuration away would produce, and the
    // next loud stream would then run straight past the ceiling, which is
    // exactly what a host calls reset() between streams to avoid.
    std::array<float, 2> after{4.0F, 4.0F};
    chain.process(after.data(), 1, 2);
    CHECK(std::abs(after[0]) <= threshold_linear(-0.3F) + 1.0e-4F);
}

void configure_drops_the_ducking() {
    // Re-configuring mid-session (the user moves a slider) must not leave the
    // next buffer attenuated by a peak from before the change.
    DspChain chain = armed();
    std::array<float, 2> hot{4.0F, 4.0F};
    chain.process(hot.data(), 1, 2);

    DspConfig config{};
    config.limiter_enabled = true;
    config.limiter_threshold_db = -6.0F;
    chain.configure(config);
    CHECK(measure_gain(chain) == 1.0F);

    // ...and the new threshold is the one in force, not merely "some limiter".
    std::array<float, 2> after{4.0F, 4.0F};
    chain.process(after.data(), 1, 2);
    CHECK(std::abs(after[0]) <= threshold_linear(-6.0F) + 1.0e-4F);
    CHECK(std::abs(after[0]) > threshold_linear(-6.0F) * 0.9F);
}

void a_disabled_limiter_never_touches_the_gain() {
    DspConfig config{};
    config.limiter_enabled = false;
    DspChain chain(kSampleRate);
    chain.configure(config);

    std::array<float, 2> hot{4.0F, 4.0F};
    chain.process(hot.data(), 1, 2);
    CHECK(hot[0] == 4.0F);
    CHECK(measure_gain(chain) == 1.0F);
}

}  // namespace

int main() {
    the_ceiling_holds_across_a_sustained_signal();
    a_louder_signal_does_not_get_louder_output();
    a_lower_threshold_lowers_the_ceiling();
    attack_is_immediate_so_the_first_loud_frame_is_already_under();
    release_recovers_as_a_one_pole_toward_unity();
    a_shorter_release_recovers_sooner();
    the_gain_is_stereo_linked_across_a_whole_buffer();
    mono_is_limited_too();
    an_equalizer_boost_cannot_push_past_the_ceiling();
    reset_drops_the_ducking();
    configure_drops_the_ducking();
    a_disabled_limiter_never_touches_the_gain();
    return linthra::audio::test::report("limiter");
}
