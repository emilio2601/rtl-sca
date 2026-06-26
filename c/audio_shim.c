#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include "audio_shim.h"
#include <stdlib.h>

struct sca_audio {
    ma_device dev;
    sca_pull_fn pull;
    void *ctx;
    int started;
};

static void data_cb(ma_device *d, void *out, const void *in, ma_uint32 n) {
    (void)in;
    struct sca_audio *a = (struct sca_audio *)d->pUserData;
    a->pull(a->ctx, (float *)out, n);
}

sca_audio *sca_audio_create(void) {
    return (sca_audio *)calloc(1, sizeof(struct sca_audio));
}

int sca_audio_start(sca_audio *a, unsigned int sample_rate, sca_pull_fn pull, void *ctx) {
    if (!a) return -1;
    a->pull = pull;
    a->ctx = ctx;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 1;
    cfg.sampleRate = sample_rate;
    cfg.dataCallback = data_cb;
    cfg.pUserData = a;
    if (ma_device_init(NULL, &cfg, &a->dev) != MA_SUCCESS) return -2;
    if (ma_device_start(&a->dev) != MA_SUCCESS) {
        ma_device_uninit(&a->dev);
        return -3;
    }
    a->started = 1;
    return 0;
}

void sca_audio_destroy(sca_audio *a) {
    if (!a) return;
    if (a->started) ma_device_uninit(&a->dev);
    free(a);
}

unsigned int sca_audio_default_rate(void) {
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 1;
    cfg.sampleRate = 0; /* 0 => miniaudio fills dev.sampleRate with the native rate */
    ma_device dev;
    if (ma_device_init(NULL, &cfg, &dev) != MA_SUCCESS) return 0;
    unsigned int rate = dev.sampleRate;
    ma_device_uninit(&dev);
    return rate;
}
