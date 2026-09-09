#include "linthra_audio/dsp.hpp"
#include "linthra_audio/linthra_audio.h"

#include "check.hpp"

#include <array>
#include <cmath>
#include <cstddef>

using linthra::audio::test::near;

int main() {
    using linthra::audio::DspChain;
    using linthra::audio::DspConfig;

    // Transparent bypass: no EQ, no preamp, limiter disabled.
    DspChain bypass(48'000.0F);
    DspConfig bypass_config{};
    bypass_config.limiter_enabled = false;
    bypass.configure(bypass_config);
    std::array<float, 6> clean{0.25F, -0.25F, 0.5F, -0.5F, 0.0F, 0.75F};
    const auto original = clean;
    bypass.process(clean.data(), 3, 2);
    for (std::size_t index = 0; index < clean.size(); ++index) {
        CHECK(near(clean[index], original[index]));
    }

    // Preamp is deterministic and clip-free when the limiter is off.
    DspChain preamp(48'000.0F);
    DspConfig preamp_config{};
    preamp_config.preamp_db = -6.0F;
    preamp_config.limiter_enabled = false;
    preamp.configure(preamp_config);
    std::array<float, 2> preamp_frame{1.0F, -1.0F};
    preamp.process(preamp_frame.data(), 1, 2);
    CHECK(near(preamp_frame[0], 0.501187F, 1.0e-3F));
    CHECK(near(preamp_frame[1], -0.501187F, 1.0e-3F));

    // The stereo-linked limiter applies one gain to both channels. This avoids
    // pulling a loud channel down independently and shifting the stereo image.
    DspChain limiter(48'000.0F);
    DspConfig limiter_config{};
    limiter_config.limiter_enabled = true;
    limiter_config.limiter_threshold_db = -0.3F;
    limiter.configure(limiter_config);
    std::array<float, 2> hot_frame{2.0F, 1.0F};
    limiter.process(hot_frame.data(), 1, 2);
    const float threshold = std::pow(10.0F, -0.3F / 20.0F);
    CHECK(std::abs(hot_frame[0]) <= threshold + 1.0e-4F);
    CHECK(near(hot_frame[0] / hot_frame[1], 2.0F, 1.0e-3F));

    // A peaking band should alter an impulse response without producing NaN or
    // infinity. Exact coefficients are implementation detail; stability is the
    // contract the realtime caller depends on.
    DspChain equalizer(48'000.0F);
    DspConfig eq_config{};
    eq_config.limiter_enabled = false;
    eq_config.band_count = 1;
    eq_config.bands[0] = {true, 1000.0F, 6.0F, 0.707F};
    equalizer.configure(eq_config);
    std::array<float, 32> impulse{};
    impulse[0] = 0.5F;
    equalizer.process(impulse.data(), impulse.size(), 1);
    bool changed = false;
    float energy = 0.0F;
    for (std::size_t index = 0; index < impulse.size(); ++index) {
        CHECK(std::isfinite(impulse[index]));
        energy += impulse[index] * impulse[index];
        if (!near(impulse[index], index == 0 ? 0.5F : 0.0F)) {
            changed = true;
        }
    }
    CHECK(changed);
    // "Changed" alone would accept a band that zeroed the response. A muted
    // impulse differs from the input too. The response has to carry energy.
    CHECK(energy > 0.1F * 0.5F * 0.5F);

    // Smoke-test the C ABI that a future JNI/FFI layer will call.
    LinthraAudioDsp* c_dsp = linthra_audio_create(48'000.0F);
    CHECK(c_dsp != nullptr);
    // The C entry points ignore a null handle, which would leave the samples
    // untouched and make the checks below pass for the wrong reason.
    if (c_dsp != nullptr) {
        LinthraAudioConfig c_config{};
        c_config.limiter_enabled = 0;
        c_config.preamp_db = 0.0F;
        c_config.limiter_threshold_db = -0.3F;
        c_config.limiter_release_ms = 80.0F;
        linthra_audio_configure(c_dsp, &c_config);
        std::array<float, 2> c_samples{0.2F, -0.2F};
        linthra_audio_process(c_dsp, c_samples.data(), 1, 2);
        CHECK(near(c_samples[0], 0.2F));
        CHECK(near(c_samples[1], -0.2F));
        linthra_audio_destroy(c_dsp);
    }

    return linthra::audio::test::report("DSP");
}
