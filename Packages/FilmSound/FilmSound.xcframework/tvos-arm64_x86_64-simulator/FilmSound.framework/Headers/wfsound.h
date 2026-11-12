/*
 * Woodruff Family: sound the Apple TV has no decoder for (DTS, DTS-HD, Dolby TrueHD, MLP), decoded to plain
 * samples by FFmpeg's decoders (libavcodec, LGPL 2.1 or later). This file and wfsound.c are under the same
 * licence. scripts/build_filmsound.sh builds them, with FFmpeg, into FilmSound.framework.
 */
#ifndef WFSOUND_H
#define WFSOUND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The kinds of sound this decodes. */
enum {
    WFSOUND_DTS = 1,     /* DTS and DTS-HD (the decoder takes whichever the packets hold) */
    WFSOUND_TRUEHD = 2,  /* Dolby TrueHD */
    WFSOUND_MLP = 3      /* MLP */
};

typedef struct WFSound WFSound;

/* A decoder for one track of [kind]. NULL when it can't be made. */
WFSound *wfsound_open(int kind);

/*
 * Decodes one packet, as the file holds it (it may hold several frames). Returns the number of frames now at
 * *samples (0 when the decoder needs more before it gives any), or a negative number when nothing in the packet
 * could be decoded. *samples stays good until the next call on this decoder.
 *
 * Samples are 32-bit floats, one after another for each frame, [*channels] to a frame at [*rate] a second, always
 * in this order: front left, front right, centre, low, surround left, surround right, rear left, rear right
 * (two channels: left, right; one: by itself). Sound with more than two channels comes out as six or as eight.
 *
 * [*channels] and [*rate] only ever grow while the decoder lives, also across wfsound_flush: sound that gives a
 * few plainer frames (after the film is moved, say) has them spread into the shape it had.
 */
int wfsound_decode(WFSound *sound, const uint8_t *packet, int size, const float **samples, int *channels, int *rate);

/* Forgets what it holds: the film was moved to another place. */
void wfsound_flush(WFSound *sound);

void wfsound_close(WFSound *sound);

/* What this was built from (FFmpeg's version and how it was configured), for the app's credits. */
const char *wfsound_about(void);

#ifdef __cplusplus
}
#endif

#endif
