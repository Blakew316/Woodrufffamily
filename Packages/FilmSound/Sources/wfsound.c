/*
 * Woodruff Family: see wfsound.h. LGPL 2.1 or later, as the FFmpeg libraries this is linked with.
 */
#include "wfsound.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

struct WFSound {
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    /* Turns what the decoder gives into floats in the order wfsound.h promises; made for the layout, format and
     * rate of a frame, and made again when any of them changes. */
    SwrContext *convert;
    AVChannelLayout from;
    int from_format;
    int from_rate;
    int natural; /* the channels the converter gives for those frames: 1, 2, 6 or 8 */
    int to_rate; /* the rate the converter gives */
    /* What comes out. Both only ever grow while the decoder lives: a film moved to another place can give a few
     * frames of its plainer core (fewer channels, a lower rate) before the whole sound is back, and those are
     * spread into the larger shape so the sound's shape doesn't change back and forth. */
    int channels;
    int rate;
    /* The samples of the packet just decoded. */
    float *samples;
    size_t capacity; /* in floats */
};

static void drop_convert(WFSound *sound) {
    if (sound->convert) swr_free(&sound->convert);
    av_channel_layout_uninit(&sound->from);
    sound->from_format = -1;
    sound->from_rate = 0;
    sound->natural = 0;
    sound->to_rate = 0;
}

WFSound *wfsound_open(int kind) {
    enum AVCodecID id = kind == WFSOUND_DTS ? AV_CODEC_ID_DTS
                      : kind == WFSOUND_TRUEHD ? AV_CODEC_ID_TRUEHD
                      : kind == WFSOUND_MLP ? AV_CODEC_ID_MLP : AV_CODEC_ID_NONE;
#ifdef WFSOUND_SELFTEST
    /* Only in the test built by scripts/build_filmsound.sh: plain eight-channel samples, to check the order they
     * come out in. */
    if (kind == 100) id = AV_CODEC_ID_PCM_S16LE;
#endif
    const AVCodec *codec = id == AV_CODEC_ID_NONE ? NULL : avcodec_find_decoder(id);
    if (!codec) return NULL;
#ifndef WFSOUND_SELFTEST
    /* In the app FFmpeg says nothing: it would write a line to the console for every packet it can't read. */
    av_log_set_level(AV_LOG_QUIET);
#endif
    WFSound *sound = calloc(1, sizeof(*sound));
    if (!sound) return NULL;
    sound->from_format = -1;
    sound->codec = avcodec_alloc_context3(codec);
    sound->packet = av_packet_alloc();
    sound->frame = av_frame_alloc();
#ifdef WFSOUND_SELFTEST
    if (kind == 100 && sound->codec) {
        sound->codec->sample_rate = 48000;
        sound->codec->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1;
    }
#endif
    if (!sound->codec || !sound->packet || !sound->frame || avcodec_open2(sound->codec, codec, NULL) < 0) {
        wfsound_close(sound);
        return NULL;
    }
    return sound;
}

void wfsound_close(WFSound *sound) {
    if (!sound) return;
    drop_convert(sound);
    if (sound->frame) av_frame_free(&sound->frame);
    if (sound->packet) av_packet_free(&sound->packet);
    if (sound->codec) avcodec_free_context(&sound->codec);
    free(sound->samples);
    free(sound);
}

void wfsound_flush(WFSound *sound) {
    if (!sound) return;
    avcodec_flush_buffers(sound->codec);
    drop_convert(sound);
}

/* The channels wfsound gives for sound of [count] channels. */
static int natural_for(int count) {
    return count <= 1 ? 1 : count == 2 ? 2 : count <= 6 ? 6 : 8;
}

/* The converter for [frame]'s layout, format and rate, giving sound->rate: kept while they stay the same. */
static int ready_convert(WFSound *sound, const AVFrame *frame) {
    if (sound->convert && sound->from_format == frame->format && sound->from_rate == frame->sample_rate &&
        sound->to_rate == sound->rate && av_channel_layout_compare(&sound->from, &frame->ch_layout) == 0) {
        return 0;
    }
    drop_convert(sound);
    AVChannelLayout to;
    int count = frame->ch_layout.nb_channels;
    int natural = natural_for(count);
    if (natural == 1) {
        to = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;
    } else if (natural == 2) {
        to = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    } else if (natural == 6) {
        to = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1_BACK;
    } else {
        to = (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1;
    }
    /* A layout the decoder couldn't name: taken as the usual one for that many channels. */
    AVChannelLayout in;
    if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
        av_channel_layout_default(&in, count);
    } else if (av_channel_layout_copy(&in, &frame->ch_layout) < 0) {
        return -1;
    }
    int made = swr_alloc_set_opts2(&sound->convert, &to, AV_SAMPLE_FMT_FLT, sound->rate,
                                   &in, (enum AVSampleFormat)frame->format, frame->sample_rate, 0, NULL);
    av_channel_layout_uninit(&in);
    if (made < 0 || !sound->convert || swr_init(sound->convert) < 0) {
        drop_convert(sound);
        return -1;
    }
    if (av_channel_layout_copy(&sound->from, &frame->ch_layout) < 0) {
        drop_convert(sound);
        return -1;
    }
    sound->from_format = frame->format;
    sound->from_rate = frame->sample_rate;
    sound->natural = natural;
    sound->to_rate = sound->rate;
    return 0;
}

/* [made] frames of [natural] channels at [at] become frames of [channels] channels, in place (there is room).
 * Six in eight: the surrounds stay the surrounds and the rears are silent. Two: left and right. One: both
 * speakers of two, the centre of more. */
static void spread(float *at, int made, int natural, int channels) {
    for (int i = made - 1; i >= 0; i--) {
        float one[8];
        memcpy(one, at + (size_t)i * (size_t)natural, (size_t)natural * sizeof(float));
        float *to = at + (size_t)i * (size_t)channels;
        memset(to, 0, (size_t)channels * sizeof(float));
        if (natural == 1 && channels == 2) {
            to[0] = one[0];
            to[1] = one[0];
        } else if (natural == 1) {
            to[2] = one[0];
        } else {
            memcpy(to, one, (size_t)natural * sizeof(float));
        }
    }
}

int wfsound_decode(WFSound *sound, const uint8_t *packet, int size, const float **samples, int *channels, int *rate) {
    if (!sound || !packet || size <= 0 || !samples || !channels || !rate) return -1;
    /* (The decoders read a little past a packet's end: FFmpeg wants it copied with room after it.) */
    if (av_new_packet(sound->packet, size) < 0) return -1;
    memcpy(sound->packet->data, packet, (size_t)size);
    int sent = avcodec_send_packet(sound->codec, sound->packet);
    av_packet_unref(sound->packet);
    if (sent < 0) return -1;

    /* A packet can hold more than one frame (a file may keep several TrueHD access units together): every frame
     * it gives is taken. One that can't be decoded ends the packet; what came before it is still given. */
    int frames = 0;
    int failed = 0;
    for (;;) {
        int got = avcodec_receive_frame(sound->codec, sound->frame);
        if (got == AVERROR(EAGAIN) || got == AVERROR_EOF) break;
        if (got < 0) { failed = 1; break; }
        AVFrame *frame = sound->frame;
        int more = frame->nb_samples;
        int natural = natural_for(frame->ch_layout.nb_channels);
        if (more <= 0 || frame->sample_rate <= 0) {
            av_frame_unref(frame);
            continue;
        }
        if (natural > sound->channels || frame->sample_rate > sound->rate) {
            /* The sound grew (its first frames, or the whole sound back after its core): what this packet gave
             * in the smaller shape is let go, a few thousandths of a second. */
            frames = 0;
            if (natural > sound->channels) sound->channels = natural;
            if (frame->sample_rate > sound->rate) sound->rate = frame->sample_rate;
        }
        if (ready_convert(sound, frame) < 0) {
            av_frame_unref(frame);
            failed = 1;
            break;
        }
        int room = frame->sample_rate == sound->rate ? more : swr_get_out_samples(sound->convert, more);
        if (room < more) room = more;
        size_t needed = ((size_t)frames + (size_t)room) * (size_t)sound->channels;
        if (needed > sound->capacity) {
            float *grown = realloc(sound->samples, needed * 2 * sizeof(float));
            if (!grown) {
                av_frame_unref(frame);
                failed = 1;
                break;
            }
            sound->samples = grown;
            sound->capacity = needed * 2;
        }
        float *at = sound->samples + (size_t)frames * (size_t)sound->channels;
        uint8_t *out = (uint8_t *)at;
        int made = swr_convert(sound->convert, &out, room, (const uint8_t **)frame->extended_data, more);
        av_frame_unref(frame);
        if (made < 0) { failed = 1; break; }
        /* Eight channels come from FFmpeg as ... rear left, rear right, side left, side right: the sides go
         * first here. */
        if (natural == 8) {
            float *each = at;
            for (int i = 0; i < made; i++, each += 8) {
                float left = each[4], right = each[5];
                each[4] = each[6];
                each[5] = each[7];
                each[6] = left;
                each[7] = right;
            }
        }
        if (natural < sound->channels) spread(at, made, natural, sound->channels);
        frames += made;
    }
    if (failed && frames == 0) return -1;
    *samples = sound->samples;
    *channels = sound->channels;
    *rate = sound->rate;
    return frames;
}

const char *wfsound_about(void) {
    static char about[1024];
    if (!about[0]) snprintf(about, sizeof(about), "FFmpeg %s, configured: %s", LIBAVCODEC_IDENT, avcodec_configuration());
    return about;
}

#ifdef WFSOUND_SELFTEST
/* Only in the test: the plain samples it feeds become [channels] channels at [rate], as a film's sound can change
 * shape under a decoder that stays the same one. */
int wfsound_test_plain(WFSound *sound, int channels, int rate) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_PCM_S16LE);
    AVCodecContext *made = codec ? avcodec_alloc_context3(codec) : NULL;
    if (!made) return -1;
    made->sample_rate = rate;
    av_channel_layout_default(&made->ch_layout, channels);
    if (avcodec_open2(made, codec, NULL) < 0) {
        avcodec_free_context(&made);
        return -1;
    }
    avcodec_free_context(&sound->codec);
    sound->codec = made;
    return 0;
}
#endif
