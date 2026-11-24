#ifndef STRATA_VOICE_H
#define STRATA_VOICE_H

#include <stdint.h>

/// A small, model-free voice finder: it looks at a stereo song, keeps what is sung (the centred, harmonic, non-percussive part) and notes where the
/// voice is and where its syllables begin. Lines of lyrics are then lined up against that.
typedef struct strata_voice strata_voice;

/// Analyses [n] samples of left/right audio at [sample_rate] Hz (22 050 is what Strata uses). Returns NULL when there is too little audio.
strata_voice *strata_voice_analyze(const float *left, const float *right, int64_t n, int sample_rate);

/// Lines one line of lyrics up against the voice.
///   ws, we: the stretch of the song (seconds) the line is somewhere inside; base: the time its stamp says it starts
///   n_words / syll: how many words, and how many syllables each has
///   starts: out, when each word begins (seconds); end: out, when the line stops being sung
/// Returns 0 when no singing was found there, 1 when the words were spread over the singing, 2 when they were matched to syllables.
int strata_voice_align_line(const strata_voice *v, double ws, double we, double base, int n_words, const int *syll, double *starts, double *end);

/// seconds of song per analysis frame, and the loudness of the voice at [t] seconds (for tests and drawing)
double strata_voice_frame_seconds(const strata_voice *v);
double strata_voice_level(const strata_voice *v, double t);

void strata_voice_free(strata_voice *v);

#endif
