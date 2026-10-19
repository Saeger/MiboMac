#include "mibo_player.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#define STALL_TIMEOUT_SEC 15

struct mp_player {
    void *ctx;
    mp_video_cb video_cb;
    mp_audio_cb audio_cb;
    mp_state_cb state_cb;
    pthread_t thread;
    int thread_running;
    atomic_int abort_flag;
    atomic_int audio_enabled;
    atomic_long last_io;
    char *url;
};

static long now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec;
}

static int interrupt_cb(void *opaque) {
    mp_player *p = opaque;
    if (atomic_load(&p->abort_flag)) return 1;
    return now_sec() - atomic_load(&p->last_io) > STALL_TIMEOUT_SEC;
}

static void emit_state(mp_player *p, int state, const char *msg) {
    if (p->state_cb) p->state_cb(p->ctx, state, msg);
}

static AVCodecContext *open_decoder(AVStream *st) {
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *c = avcodec_alloc_context3(codec);
    if (!c) return NULL;
    if (avcodec_parameters_to_context(c, st->codecpar) < 0 || avcodec_open2(c, codec, NULL) < 0) {
        avcodec_free_context(&c);
        return NULL;
    }
    c->flags |= AV_CODEC_FLAG_LOW_DELAY;
    return c;
}

static void *player_thread(void *arg) {
    mp_player *p = arg;
    AVFormatContext *fmt = NULL;
    AVCodecContext *vdec = NULL, *adec = NULL;
    struct SwsContext *sws = NULL;
    SwrContext *swr = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    uint8_t *bgra = NULL;
    int bgra_stride = 0, sws_w = 0, sws_h = 0, sws_fmt = -1;
    float *pcm = NULL;
    int pcm_cap = 0;
    int vidx = -1, aidx = -1, playing = 0;
    char errbuf[256] = {0};

    emit_state(p, MP_STATE_CONNECTING, "Conectando…");
    atomic_store(&p->last_io, now_sec());

    fmt = avformat_alloc_context();
    fmt->interrupt_callback.callback = interrupt_cb;
    fmt->interrupt_callback.opaque = p;

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    av_dict_set(&opts, "timeout", "10000000", 0);
    av_dict_set(&opts, "fflags", "nobuffer", 0);
    av_dict_set(&opts, "probesize", "500000", 0);
    av_dict_set(&opts, "analyzeduration", "1500000", 0);
    int r = avformat_open_input(&fmt, p->url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) {
        av_strerror(r, errbuf, sizeof errbuf);
        fmt = NULL;
        goto fail;
    }
    if ((r = avformat_find_stream_info(fmt, NULL)) < 0) {
        av_strerror(r, errbuf, sizeof errbuf);
        goto fail;
    }
    vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    aidx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (vidx < 0 || !(vdec = open_decoder(fmt->streams[vidx]))) {
        snprintf(errbuf, sizeof errbuf, "sem vídeo decodificável");
        goto fail;
    }
    if (aidx >= 0) adec = open_decoder(fmt->streams[aidx]);

    while (!atomic_load(&p->abort_flag)) {
        r = av_read_frame(fmt, pkt);
        if (r < 0) {
            if (r == AVERROR_EOF) snprintf(errbuf, sizeof errbuf, "transmissão encerrada");
            else av_strerror(r, errbuf, sizeof errbuf);
            goto fail;
        }
        atomic_store(&p->last_io, now_sec());

        if (pkt->stream_index == vidx) {
            if (avcodec_send_packet(vdec, pkt) >= 0) {
                while (avcodec_receive_frame(vdec, frame) >= 0) {
                    if (frame->width != sws_w || frame->height != sws_h || frame->format != sws_fmt) {
                        sws_freeContext(sws);
                        sws = sws_getContext(frame->width, frame->height, frame->format, frame->width,
                                             frame->height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
                        free(bgra);
                        bgra_stride = frame->width * 4;
                        bgra = malloc((size_t)bgra_stride * frame->height);
                        sws_w = frame->width;
                        sws_h = frame->height;
                        sws_fmt = frame->format;
                    }
                    if (sws && bgra) {
                        uint8_t *dst[4] = {bgra, NULL, NULL, NULL};
                        int dst_stride[4] = {bgra_stride, 0, 0, 0};
                        sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height,
                                  dst, dst_stride);
                        if (!playing) {
                            playing = 1;
                            emit_state(p, MP_STATE_PLAYING, "Ao vivo");
                        }
                        if (p->video_cb) p->video_cb(p->ctx, bgra, sws_w, sws_h, bgra_stride);
                    }
                    av_frame_unref(frame);
                }
            }
        } else if (pkt->stream_index == aidx && adec && atomic_load(&p->audio_enabled) && p->audio_cb) {
            if (avcodec_send_packet(adec, pkt) >= 0) {
                while (avcodec_receive_frame(adec, frame) >= 0) {
                    if (!swr) {
                        AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
                        swr_alloc_set_opts2(&swr, &mono, AV_SAMPLE_FMT_FLT, frame->sample_rate, &frame->ch_layout,
                                            frame->format, frame->sample_rate, 0, NULL);
                        if (swr && swr_init(swr) < 0) swr_free(&swr);
                    }
                    if (swr) {
                        int out_cap = swr_get_out_samples(swr, frame->nb_samples);
                        if (out_cap > pcm_cap) {
                            free(pcm);
                            pcm_cap = out_cap;
                            pcm = malloc(sizeof(float) * pcm_cap);
                        }
                        uint8_t *out[1] = {(uint8_t *)pcm};
                        int n = swr_convert(swr, out, pcm_cap, (const uint8_t **)frame->extended_data,
                                            frame->nb_samples);
                        if (n > 0) p->audio_cb(p->ctx, pcm, n, frame->sample_rate);
                    }
                    av_frame_unref(frame);
                }
            }
        }
        av_packet_unref(pkt);
    }
    emit_state(p, MP_STATE_STOPPED, "Parado");
    goto cleanup;

fail:
    if (atomic_load(&p->abort_flag)) emit_state(p, MP_STATE_STOPPED, "Parado");
    else emit_state(p, MP_STATE_ERROR, errbuf[0] ? errbuf : "erro");

cleanup:
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&vdec);
    avcodec_free_context(&adec);
    sws_freeContext(sws);
    swr_free(&swr);
    free(bgra);
    free(pcm);
    if (fmt) avformat_close_input(&fmt);
    return NULL;
}

mp_player *mp_create(void *ctx, mp_video_cb video, mp_audio_cb audio, mp_state_cb state) {
    av_log_set_level(AV_LOG_ERROR);
    mp_player *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->ctx = ctx;
    p->video_cb = video;
    p->audio_cb = audio;
    p->state_cb = state;
    return p;
}

int mp_start(mp_player *p, const char *url) {
    mp_stop(p);
    free(p->url);
    p->url = strdup(url);
    atomic_store(&p->abort_flag, 0);
    if (pthread_create(&p->thread, NULL, player_thread, p) != 0) return -1;
    p->thread_running = 1;
    return 0;
}

void mp_stop(mp_player *p) {
    if (!p || !p->thread_running) return;
    atomic_store(&p->abort_flag, 1);
    pthread_join(p->thread, NULL);
    p->thread_running = 0;
}

void mp_set_audio_enabled(mp_player *p, int enabled) {
    if (p) atomic_store(&p->audio_enabled, enabled);
}

void mp_destroy(mp_player *p) {
    if (!p) return;
    mp_stop(p);
    free(p->url);
    free(p);
}
