#include "strata_ort.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if __has_include(<onnxruntime/onnxruntime_c_api.h>)
#include <onnxruntime/onnxruntime_c_api.h>
#else
#include <onnxruntime_c_api.h>
#endif

struct strata_ort {
    const OrtApi *api;
    OrtEnv *env;
    OrtSessionOptions *opts;
    OrtSession *session;
    OrtAllocator *alloc;
    OrtMemoryInfo *mem;
    char *in_name;
    char *out_name;
};

/// true (and a message in [err]) when [st] is an error
static int failed(const OrtApi *api, OrtStatus *st, char *err, size_t errlen) {
    if (!st) return 0;
    if (err && errlen) snprintf(err, errlen, "%s", api->GetErrorMessage(st));
    api->ReleaseStatus(st);
    return 1;
}

void strata_ort_close(strata_ort *s) {
    if (!s) return;
    const OrtApi *api = s->api;
    if (s->in_name && s->alloc) api->AllocatorFree(s->alloc, s->in_name);
    if (s->out_name && s->alloc) api->AllocatorFree(s->alloc, s->out_name);
    if (s->mem) api->ReleaseMemoryInfo(s->mem);
    if (s->session) api->ReleaseSession(s->session);
    if (s->opts) api->ReleaseSessionOptions(s->opts);
    if (s->env) api->ReleaseEnv(s->env);
    free(s);
}

strata_ort *strata_ort_open(const char *model_path, int threads, char *err, size_t errlen) {
    // the library Strata ships is ONNX Runtime 1.22 (API version 22); the C API only grows, so any newer header is fine to compile against
    const OrtApi *api = OrtGetApiBase()->GetApi(22);
    if (!api) { if (err && errlen) snprintf(err, errlen, "ONNX Runtime is not the version Strata was built with"); return NULL; }
    strata_ort *s = (strata_ort *)calloc(1, sizeof(strata_ort));
    if (!s) return NULL;
    s->api = api;
    size_t count = 0;
    if (failed(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "strata", &s->env), err, errlen)) goto fail;
    if (failed(api, api->CreateSessionOptions(&s->opts), err, errlen)) goto fail;
    if (failed(api, api->SetIntraOpNumThreads(s->opts, threads), err, errlen)) goto fail;
    if (failed(api, api->SetSessionGraphOptimizationLevel(s->opts, ORT_ENABLE_ALL), err, errlen)) goto fail;
    if (failed(api, api->CreateSession(s->env, model_path, s->opts, &s->session), err, errlen)) goto fail;
    if (failed(api, api->GetAllocatorWithDefaultOptions(&s->alloc), err, errlen)) goto fail;
    if (failed(api, api->SessionGetInputCount(s->session, &count), err, errlen)) goto fail;
    if (count != 1) { if (err && errlen) snprintf(err, errlen, "The model isn't the one Strata expects (re-download it from Settings)"); goto fail; }
    if (failed(api, api->SessionGetOutputCount(s->session, &count), err, errlen)) goto fail;
    if (count < 1) { if (err && errlen) snprintf(err, errlen, "The model isn't the one Strata expects (re-download it from Settings)"); goto fail; }
    if (failed(api, api->SessionGetInputName(s->session, 0, s->alloc, &s->in_name), err, errlen)) goto fail;
    if (failed(api, api->SessionGetOutputName(s->session, 0, s->alloc, &s->out_name), err, errlen)) goto fail;
    if (failed(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->mem), err, errlen)) goto fail;
    return s;
fail:
    strata_ort_close(s);
    return NULL;
}

int strata_ort_run(strata_ort *s, const float *wave, int64_t n, float **out, int64_t *frames, int64_t *classes, char *err, size_t errlen) {
    const OrtApi *api = s->api;
    OrtValue *input = NULL, *output = NULL;
    OrtTensorTypeAndShapeInfo *info = NULL;
    int rc = 1;
    int64_t shape[2] = { 1, n };
    const char *in_names[1] = { s->in_name };
    const char *out_names[1] = { s->out_name };
    float *data = NULL;
    size_t dims = 0;
    int64_t d[8];

    if (failed(api, api->CreateTensorWithDataAsOrtValue(s->mem, (void *)wave, (size_t)n * sizeof(float), shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input), err, errlen)) goto done;
    if (failed(api, api->Run(s->session, NULL, in_names, (const OrtValue *const *)&input, 1, out_names, 1, &output), err, errlen)) goto done;
    if (failed(api, api->GetTensorMutableData(output, (void **)&data), err, errlen)) goto done;
    if (failed(api, api->GetTensorTypeAndShape(output, &info), err, errlen)) goto done;
    if (failed(api, api->GetDimensionsCount(info, &dims), err, errlen)) goto done;
    if (dims < 2 || dims > 8) { if (err && errlen) snprintf(err, errlen, "The model's answer has an unexpected shape"); goto done; }
    if (failed(api, api->GetDimensions(info, d, dims), err, errlen)) goto done;
    *frames = d[dims - 2];
    *classes = d[dims - 1];
    {
        size_t bytes = (size_t)(*frames) * (size_t)(*classes) * sizeof(float);
        float *copy = (float *)malloc(bytes);
        if (!copy) { if (err && errlen) snprintf(err, errlen, "Not enough memory"); goto done; }
        memcpy(copy, data, bytes);
        *out = copy;
    }
    rc = 0;
done:
    if (info) api->ReleaseTensorTypeAndShapeInfo(info);
    if (output) api->ReleaseValue(output);
    if (input) api->ReleaseValue(input);
    return rc;
}

void strata_ort_free(void *p) { free(p); }
