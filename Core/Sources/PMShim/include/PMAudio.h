#ifndef PM_AUDIO_H
#define PM_AUDIO_H
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    _Atomic(float) target;
    _Atomic(int) failed;
    float current;
    double sample_rate;
} pm_audio_gain;
static inline void *pm_audio_gain_create(double rate) {
    pm_audio_gain *g = calloc(1, sizeof(*g));
    if (!g) return NULL;
    atomic_init(&g->target, 1); atomic_init(&g->failed, 0);
    g->current = 1; g->sample_rate = rate;
    return g;
}
static inline void pm_audio_gain_destroy(void *ptr) { free(ptr); }
static inline void pm_audio_gain_set(void *ptr, float value) {
    if (ptr && isfinite(value) && value >= 0 && value <= 1)
        atomic_store_explicit(&((pm_audio_gain *)ptr)->target, value, memory_order_relaxed);
}
static inline float pm_audio_gain_get(void *ptr) {
    return ptr ? atomic_load_explicit(&((pm_audio_gain *)ptr)->target, memory_order_relaxed) : 0;
}
static inline int pm_audio_gain_failed(void *ptr) {
    return ptr ? atomic_load_explicit(&((pm_audio_gain *)ptr)->failed, memory_order_relaxed) : 1;
}
/// Testable sample math: attenuation only, invalid signal samples become silence.
static inline float pm_audio_attenuate(float sample, float gain) {
    return isfinite(sample) && isfinite(gain) && gain >= 0 && gain <= 1 ? sample * gain : 0;
}
static inline float *pm_audio_channel(const AudioBufferList *list, unsigned channel, unsigned frame) {
    for (unsigned b = 0; b < list->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        if (channel < buffer->mNumberChannels)
            return (float *)buffer->mData + frame * buffer->mNumberChannels + channel;
        channel -= buffer->mNumberChannels;
    }
    return NULL;
}
/// Allocation/lock-free mono/stereo float32 routing, supporting either buffer layout.
/// Any buffer mismatch marks the route for teardown on the next UI observation.
static inline void pm_audio_render(void *ptr, const AudioBufferList *input, AudioBufferList *output) {
    pm_audio_gain *g = ptr;
    if (!g || !output) return;
    for (unsigned b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    unsigned frames = 0, in_channels = 0, out_channels = 0;
    int valid = input && input->mNumberBuffers > 0 && input->mNumberBuffers <= 2 && output->mNumberBuffers > 0 && output->mNumberBuffers <= 2;
    if (valid) {
        for (unsigned side = 0; side < 2; ++side) {
            const AudioBufferList *list = side ? output : input;
            for (unsigned b = 0; b < list->mNumberBuffers; ++b) {
                const AudioBuffer *buf = &list->mBuffers[b];
                if (!buf->mData || !buf->mNumberChannels || buf->mNumberChannels > 2 ||
                    buf->mDataByteSize % (sizeof(float) * buf->mNumberChannels)) { valid = 0; break; }
                unsigned n = buf->mDataByteSize / (sizeof(float) * buf->mNumberChannels);
                if (!frames) frames = n;
                if (frames != n) { valid = 0; break; }
                if (side) out_channels += buf->mNumberChannels; else in_channels += buf->mNumberChannels;
            }
        }
    }
    if (!valid || in_channels != out_channels || in_channels < 1 || in_channels > 2) {
        atomic_store_explicit(&g->failed, 1, memory_order_relaxed); return;
    }
    float target = atomic_load_explicit(&g->target, memory_order_relaxed);
    // Bound per-frame gain changes to a 10ms ramp to avoid slider clicks.
    float step = (float)(1.0 / fmax(1.0, g->sample_rate * .01));
    for (unsigned f = 0; f < frames; ++f) {
        float diff = target - g->current;
        g->current += fmaxf(-step, fminf(step, diff));
        for (unsigned channel = 0; channel < in_channels; ++channel)
            *pm_audio_channel(output, channel, f) = pm_audio_attenuate(*pm_audio_channel(input, channel, f), g->current);
    }
}
static inline float pm_audio_rms(const float *samples, unsigned count) {
    if (!samples || !count) return 0;
    double squares = 0;
    for (unsigned i = 0; i < count; ++i) if (isfinite(samples[i])) squares += (double)samples[i] * samples[i];
    return (float)fmin(1, sqrt(squares / count));
}
#endif
