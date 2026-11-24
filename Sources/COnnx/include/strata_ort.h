#ifndef STRATA_ORT_H
#define STRATA_ORT_H

#include <stddef.h>
#include <stdint.h>

/// A tiny wrapper over ONNX Runtime's C API: one model, one input (a 16 kHz waveform), one output (scores for every 20 ms).
typedef struct strata_ort strata_ort;

/// Opens the model. Returns NULL (and writes a message into [err]) when it can't.
strata_ort *strata_ort_open(const char *model_path, int threads, char *err, size_t errlen);

/// Runs the model on [n] samples. On success returns 0 and hands back a malloc'd float buffer of frames × classes (free it with strata_ort_free).
int strata_ort_run(strata_ort *s, const float *wave, int64_t n, float **out, int64_t *frames, int64_t *classes, char *err, size_t errlen);

void strata_ort_free(void *p);
void strata_ort_close(strata_ort *s);

#endif
