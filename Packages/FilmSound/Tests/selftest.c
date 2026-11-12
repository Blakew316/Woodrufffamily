/*
 * Woodruff Family: checks wfsound on the Mac that builds it (scripts/build_filmsound.sh). A tone of its own pitch
 * is put in every channel, encoded as DTS and as Dolby TrueHD with FFmpeg's own encoders, decoded through
 * wfsound, and each channel that comes out must hold the tone wfsound.h says it does: packet by packet, with
 * several packets kept together as a file may keep them, and again from the middle as when a film is moved.
 * Plain samples then check the order of 7.1 and that sound which changes shape keeps the larger one.
 * LGPL 2.1 or later.
 */
#include "wfsound.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>

#define RATE 48000

/* Only in the test's build of wfsound.c. */
int wfsound_test_plain(WFSound *sound, int channels, int rate);

/* The pitch of each place, in the order wfsound gives them: front left, front right, centre, low, surround left,
 * surround right, rear left, rear right. */
static const double pitches[8] = {300, 500, 700, 50, 900, 1100, 1300, 1500};

/* Which of those places an FFmpeg channel is, in sound with [count] channels (-1: none of them). */
static int place(enum AVChannel channel, int count) {
    switch (channel) {
    case AV_CHAN_FRONT_LEFT: return 0;
    case AV_CHAN_FRONT_RIGHT: return 1;
    case AV_CHAN_FRONT_CENTER: return 2;
    case AV_CHAN_LOW_FREQUENCY: return 3;
    case AV_CHAN_SIDE_LEFT: return 4;
    case AV_CHAN_SIDE_RIGHT: return 5;
    /* With six channels the one pair of surrounds is "back" in some layouts and "side" in others. */
    case AV_CHAN_BACK_LEFT: return count > 6 ? 6 : 4;
    case AV_CHAN_BACK_RIGHT: return count > 6 ? 7 : 5;
    default: return -1;
    }
}

/* The sample at [index] of the tone for [channel] of [layout]. */
static double tone(const AVChannelLayout *layout, int channel, long index, int rate) {
    int p = place(av_channel_layout_channel_from_index(layout, channel), layout->nb_channels);
    return p < 0 ? 0 : 0.25 * sin(2 * M_PI * pitches[p] * (double)index / rate);
}

/* How much of [pitch] is in channel [at] of [frames] frames. */
static double amount(const float *samples, int frames, int channels, int rate, int at, double pitch) {
    double re = 0, im = 0;
    for (int i = 0; i < frames; i++) {
        double phase = 2 * M_PI * pitch * i / rate;
        double v = samples[(size_t)i * channels + at];
        re += v * cos(phase);
        im += v * sin(phase);
    }
    return sqrt(re * re + im * im) / frames;
}

/* Every channel of what came out holds the pitch of the place [expect] gives for it, louder than any other
 * place's, or nothing at all where [expect] says -1. A NULL [expect]: channel n holds place n. */
static int judge(const char *name, const float *samples, int frames, int channels, int rate, const int *expect) {
    int bad = 0;
    for (int at = 0; at < channels; at++) {
        int want = expect ? expect[at] : at;
        int loudest = -1;
        double most = 0;
        for (int p = 0; p < 8; p++) {
            double a = amount(samples, frames, channels, rate, at, pitches[p]);
            if (a > most) { most = a; loudest = p; }
        }
        int ok = want < 0 ? most < 0.002 : (loudest == want && most > 0.02);
        if (want < 0) printf("  %s: channel %d is silent (%.4f)%s\n", name, at, most, ok ? "" : "  <-- WRONG");
        else printf("  %s: channel %d holds %.0f Hz (%.3f)%s\n", name, at, loudest < 0 ? 0 : pitches[loudest], most, ok ? "" : "  <-- WRONG");
        if (!ok) bad = 1;
    }
    return bad;
}

/* What wfsound gives for everything decoded, kept end to end. */
struct heard {
    float *samples;
    int frames, capacity, channels, rate;
    int failures; /* packets nothing came of */
};

static int keep(struct heard *h, const float *samples, int frames, int channels, int rate) {
    if (frames <= 0) return 0;
    if (h->channels && (h->channels != channels || h->rate != rate)) {
        /* The shape grew: what was kept in the smaller shape is let go, as the app starts its sound again. */
        h->frames = 0;
    }
    h->channels = channels;
    h->rate = rate;
    if (h->frames + frames > h->capacity) {
        h->capacity = (h->frames + frames) * 2;
        h->samples = realloc(h->samples, (size_t)h->capacity * 8 * sizeof(float));
        if (!h->samples) return -1;
    }
    memcpy(h->samples + (size_t)h->frames * channels, samples, (size_t)frames * channels * sizeof(float));
    h->frames += frames;
    return 0;
}

/* One encoded packet. */
struct piece {
    uint8_t *data;
    int size;
};

/* Pieces [from] up to [count], [together] at a time as one packet each, through [sound]. */
static int through(WFSound *sound, const struct piece *pieces, int from, int count, int together, struct heard *h) {
    for (int n = from; n < count; n += together) {
        int size = 0;
        for (int k = n; k < n + together && k < count; k++) size += pieces[k].size;
        uint8_t *joined = malloc((size_t)size);
        if (!joined) return -1;
        int at = 0;
        for (int k = n; k < n + together && k < count; k++) {
            memcpy(joined + at, pieces[k].data, (size_t)pieces[k].size);
            at += pieces[k].size;
        }
        const float *samples = NULL;
        int channels = 0, rate = 0;
        int frames = wfsound_decode(sound, joined, size, &samples, &channels, &rate);
        free(joined);
        if (frames < 0) h->failures++;
        else if (keep(h, samples, frames, channels, rate) < 0) return -1;
    }
    return 0;
}

/* What was heard is six channels of at least [least] frames, each channel in its place once [skip] frames (the
 * coders' own run-in) are left out. */
static int six(const char *name, const struct heard *h, int least, int skip) {
    printf("%s: %d frames of %d channels at %d came out, %d packets gave nothing\n", name, h->frames, h->channels, h->rate, h->failures);
    if (h->channels != 6 || h->rate != RATE || h->frames < least || h->failures > 0) {
        printf("%s: six channels at %d, at least %d frames and no packet lost were expected  <-- WRONG\n", name, RATE, least);
        return 1;
    }
    return judge(name, h->samples + (size_t)skip * 6, h->frames - skip, 6, RATE, NULL);
}

/* Six channels of tones through FFmpeg's encoder for [id], then through wfsound's decoder of [kind]: packet by
 * packet, [together] packets at a time when that is more than one, and from the middle after a flush. */
static int coded(const char *name, int kind, enum AVCodecID id, int together) {
    const AVCodec *codec = avcodec_find_encoder(id);
    if (!codec) { printf("%s: no encoder in this build\n", name); return 1; }
    AVCodecContext *enc = avcodec_alloc_context3(codec);
    const AVChannelLayout *layout = NULL;
    for (const AVChannelLayout *l = codec->ch_layouts; l && l->nb_channels; l++) {
        if (l->nb_channels == 6) { layout = l; break; }
    }
    if (!enc || !layout) { printf("%s: its encoder takes no six-channel sound\n", name); return 1; }
    enum AVSampleFormat format = codec->sample_fmts ? codec->sample_fmts[0] : AV_SAMPLE_FMT_S32;
    int planar = av_sample_fmt_is_planar(format);
    enum AVSampleFormat packed = av_get_packed_sample_fmt(format);
    if (packed != AV_SAMPLE_FMT_S16 && packed != AV_SAMPLE_FMT_S32) { printf("%s: sample format %d isn't handled here\n", name, format); return 1; }
    enc->sample_rate = RATE;
    enc->sample_fmt = format;
    enc->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
    if (id == AV_CODEC_ID_DTS) enc->bit_rate = 1536000;
    if (av_channel_layout_copy(&enc->ch_layout, layout) < 0 || avcodec_open2(enc, codec, NULL) < 0) {
        printf("%s: its encoder wouldn't open\n", name);
        return 1;
    }
    int each = enc->frame_size > 0 ? enc->frame_size : 1024;

    /* Two seconds of sound, encoded. */
    AVFrame *frame = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    struct piece *pieces = NULL;
    int count = 0, room = 0;
    int failed = 0;
    long made = 0;
    for (int ended = 0; !ended && !failed;) {
        if (made < 2L * RATE) {
            frame->nb_samples = each;
            frame->format = format;
            frame->sample_rate = RATE;
            av_channel_layout_copy(&frame->ch_layout, layout);
            if (av_frame_get_buffer(frame, 0) < 0) { failed = 1; break; }
            for (int i = 0; i < each; i++) {
                for (int c = 0; c < 6; c++) {
                    double v = tone(layout, c, made + i, RATE);
                    void *to = planar ? frame->data[c] : frame->data[0];
                    int index = planar ? i : i * 6 + c;
                    if (packed == AV_SAMPLE_FMT_S16) ((int16_t *)to)[index] = (int16_t)lrint(v * 32767);
                    else ((int32_t *)to)[index] = (int32_t)lrint(v * 2147483647.0);
                }
            }
            frame->pts = made;
            if (avcodec_send_frame(enc, frame) < 0) failed = 1;
            av_frame_unref(frame);
            made += each;
        } else {
            avcodec_send_frame(enc, NULL);
            ended = 1;
        }
        while (!failed) {
            int got = avcodec_receive_packet(enc, packet);
            if (got == AVERROR(EAGAIN) || got == AVERROR_EOF) break;
            if (got < 0) { failed = 1; break; }
            if (count == room) {
                room = room ? room * 2 : 256;
                pieces = realloc(pieces, (size_t)room * sizeof(*pieces));
                if (!pieces) { failed = 1; break; }
            }
            pieces[count].data = malloc((size_t)packet->size);
            pieces[count].size = packet->size;
            if (!pieces[count].data) { failed = 1; break; }
            memcpy(pieces[count].data, packet->data, (size_t)packet->size);
            count++;
            av_packet_unref(packet);
        }
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&enc);
    if (failed || count < 8) {
        printf("%s: its encoder gave %d packets and then failed\n", name, count);
        return 1;
    }
    printf("%s: %d packets of %d frames each\n", name, count, each);

    char label[64];
    WFSound *sound = wfsound_open(kind);
    if (!sound) { printf("%s: wfsound has no decoder for it\n", name); return 1; }

    /* Packet by packet. */
    struct heard alone = {0};
    if (through(sound, pieces, 0, count, 1, &alone) < 0) failed = 1;
    if (!failed) failed = six(name, &alone, RATE, RATE / 2);

    /* From the middle, after the film was moved: the decoder is the same one, flushed. */
    if (!failed) {
        struct heard moved = {0};
        wfsound_flush(sound);
        snprintf(label, sizeof(label), "%s from the middle", name);
        if (through(sound, pieces, count / 2, count, 1, &moved) < 0) failed = 1;
        if (!failed) failed = six(label, &moved, RATE / 2, RATE / 4);
        free(moved.samples);
    }
    wfsound_close(sound);

    /* Several packets together, as a file may keep them: the same sound must come out, to the frame. */
    if (!failed && together > 1) {
        struct heard kept = {0};
        WFSound *again = wfsound_open(kind);
        snprintf(label, sizeof(label), "%s, %d packets together", name, together);
        if (!again || through(again, pieces, 0, count, together, &kept) < 0) failed = 1;
        if (!failed) failed = six(label, &kept, RATE, RATE / 2);
        if (!failed && kept.frames != alone.frames) {
            printf("%s: %d frames came out, and %d packet by packet  <-- WRONG\n", label, kept.frames, alone.frames);
            failed = 1;
        }
        if (!failed && memcmp(kept.samples, alone.samples, (size_t)alone.frames * 6 * sizeof(float)) != 0) {
            printf("%s: the sound isn't the same as packet by packet  <-- WRONG\n", label);
            failed = 1;
        }
        free(kept.samples);
        wfsound_close(again);
    }

    if (failed) printf("%s: FAILED\n", name);
    free(alone.samples);
    for (int n = 0; n < count; n++) free(pieces[n].data);
    free(pieces);
    return failed;
}

/* Half a second of plain samples of [channels] channels at [rate] through [sound], and what must come out:
 * [out] channels at [out_rate], each holding the place [expect] gives. */
static int shaped(WFSound *sound, const char *name, int channels, int rate, int out, int out_rate, const int *expect) {
    if (wfsound_test_plain(sound, channels, rate) < 0) { printf("%s: the test's plain samples wouldn't open\n", name); return 1; }
    AVChannelLayout layout;
    av_channel_layout_default(&layout, channels);
    struct heard h = {0};
    int failed = 0;
    int each = 1024;
    int16_t *block = malloc((size_t)each * (size_t)channels * sizeof(int16_t));
    for (long made = 0; made < rate / 2 && !failed; made += each) {
        for (int i = 0; i < each; i++) {
            for (int c = 0; c < channels; c++) block[i * channels + c] = (int16_t)lrint(tone(&layout, c, made + i, rate) * 32767);
        }
        const float *samples = NULL;
        int got_channels = 0, got_rate = 0;
        int frames = wfsound_decode(sound, (const uint8_t *)block, each * channels * (int)sizeof(int16_t), &samples, &got_channels, &got_rate);
        if (frames < 0 || keep(&h, samples, frames, got_channels, got_rate) < 0) failed = 1;
    }
    free(block);
    printf("%s: %d channels at %d in, %d frames of %d channels at %d out\n", name, channels, rate, h.frames, h.channels, h.rate);
    if (failed) printf("%s: decoding failed  <-- WRONG\n", name);
    if (!failed && (h.channels != out || h.rate != out_rate || h.frames < out_rate / 4)) {
        printf("%s: %d channels at %d were expected  <-- WRONG\n", name, out, out_rate);
        failed = 1;
    }
    /* The first frames are left out when the rate was changed: the converter's own run-in. */
    int skip = rate == out_rate ? 0 : out_rate / 20;
    if (!failed) failed = judge(name, h.samples + (size_t)skip * h.channels, h.frames - skip, h.channels, h.rate, expect);
    free(h.samples);
    return failed;
}

/* Plain samples: eight channels in FFmpeg's order (… rear left, rear right, side left, side right) must come out
 * with the sides before the rears, and sound that changes shape keeps the larger shape. */
static int plain(void) {
    WFSound *sound = wfsound_open(100);
    if (!sound) { printf("plain: wfsound wouldn't open the test's plain samples\n"); return 1; }
    static const int six_in_eight[8] = {0, 1, 2, 3, 4, 5, -1, -1};
    static const int two_in_eight[8] = {0, 1, -1, -1, -1, -1, -1, -1};
    /* (One channel by itself is the centre, so it carries the centre's pitch.) */
    static const int one_in_eight[8] = {-1, -1, 2, -1, -1, -1, -1, -1};
    int bad = 0;
    bad |= shaped(sound, "5.1", 6, RATE, 6, RATE, NULL);
    bad |= shaped(sound, "7.1 after 5.1", 8, RATE, 8, RATE, NULL);
    bad |= shaped(sound, "5.1 after 7.1", 6, RATE, 8, RATE, six_in_eight);
    wfsound_flush(sound);
    bad |= shaped(sound, "two channels after 7.1 and a flush", 2, RATE, 8, RATE, two_in_eight);
    bad |= shaped(sound, "one channel after 7.1", 1, RATE, 8, RATE, one_in_eight);
    bad |= shaped(sound, "7.1 at twice the rate", 8, 2 * RATE, 8, 2 * RATE, NULL);
    bad |= shaped(sound, "5.1 at the first rate again", 6, RATE, 8, 2 * RATE, six_in_eight);
    wfsound_close(sound);

    /* One channel that becomes two plays from both speakers. */
    WFSound *small = wfsound_open(100);
    if (!small) return 1;
    static const int one[1] = {2};
    static const int both[2] = {2, 2};
    bad |= shaped(small, "one channel", 1, RATE, 1, RATE, one);
    bad |= shaped(small, "two channels after one", 2, RATE, 2, RATE, NULL);
    bad |= shaped(small, "one channel after two", 1, RATE, 2, RATE, both);
    wfsound_close(small);
    return bad;
}

int main(void) {
    printf("%s\n", wfsound_about());
    int bad = 0;
    bad |= coded("DTS", WFSOUND_DTS, AV_CODEC_ID_DTS, 1);
    bad |= coded("TrueHD", WFSOUND_TRUEHD, AV_CODEC_ID_TRUEHD, 20);
    bad |= plain();
    /* Sound this isn't for has no decoder here. */
    if (wfsound_open(0) || wfsound_open(4)) { printf("a decoder opened for a kind there is none of  <-- WRONG\n"); bad = 1; }
    printf(bad ? "FAILED\n" : "every channel is where wfsound.h says\n");
    return bad;
}
