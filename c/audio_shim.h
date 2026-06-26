#ifndef SCA_AUDIO_SHIM_H
#define SCA_AUDIO_SHIM_H

/* Pull `frames` mono float samples into `out`. Runs on miniaudio's audio
   thread; must be real-time safe (no alloc/lock). */
typedef void (*sca_pull_fn)(void *ctx, float *out, unsigned int frames);

typedef struct sca_audio sca_audio;

sca_audio *sca_audio_create(void);
/* Open a default playback device (mono f32 at sample_rate) and start it.
   Returns 0 on success, negative on failure. */
int sca_audio_start(sca_audio *a, unsigned int sample_rate, sca_pull_fn pull, void *ctx);
void sca_audio_destroy(sca_audio *a);

/* Native sample rate the default playback device negotiates (cfg rate 0), so the
   caller can resample to it and avoid an opaque downstream conversion. Returns 0
   if no device is available. */
unsigned int sca_audio_default_rate(void);

#endif
