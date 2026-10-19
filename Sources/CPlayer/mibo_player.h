#ifndef MIBO_PLAYER_H
#define MIBO_PLAYER_H

#include <stdint.h>

typedef struct mp_player mp_player;

enum { MP_STATE_CONNECTING = 0, MP_STATE_PLAYING = 1, MP_STATE_STOPPED = 2, MP_STATE_ERROR = 3 };

typedef void (*mp_video_cb)(void *ctx, const uint8_t *bgra, int width, int height, int stride);
typedef void (*mp_audio_cb)(void *ctx, const float *samples, int nb_samples, int sample_rate);
typedef void (*mp_state_cb)(void *ctx, int state, const char *message);

mp_player *mp_create(void *ctx, mp_video_cb video, mp_audio_cb audio, mp_state_cb state);
/* Starts a background thread that plays the RTSP url. Returns 0 on success. */
int mp_start(mp_player *p, const char *url);
/* Aborts any blocking I/O and joins the thread. Safe to call multiple times. */
void mp_stop(mp_player *p);
void mp_set_audio_enabled(mp_player *p, int enabled);
void mp_destroy(mp_player *p);

#endif
