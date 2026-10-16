// holdmybyte codec bridge: libjxl lossless JPEG transcode and byte-exact reconstruction (Docs/SPEC.md §3.6).
// Owned by WP1. Single-threaded (no parallel runner): the engine runs one photo per worker thread, and a
// single-threaded encoder is deterministic.
#include "hmb_codecs.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/memory_manager.h>
#include <jxl/parallel_runner.h>
#include <sys/mman.h>

#include <algorithm>
#include <atomic>
#include <pthread.h>

#include "arena.h"

namespace {

int fail(char *err, size_t err_len, const char *format, ...) {
    if (err != nullptr && err_len > 0) {
        va_list args;
        va_start(args, format);
        std::vsnprintf(err, err_len, format, args);
        va_end(args);
    }
    return -1;
}

const char *encoder_error(JxlEncoderError code) {
    switch (code) {
        case JXL_ENC_ERR_OK: return "ok";
        case JXL_ENC_ERR_GENERIC: return "generic error";
        case JXL_ENC_ERR_OOM: return "out of memory";
        case JXL_ENC_ERR_JBRD: return "JPEG bitstream reconstruction data cannot be represented";
        case JXL_ENC_ERR_BAD_INPUT: return "bad input (not a JPEG libjxl can transcode)";
        case JXL_ENC_ERR_NOT_SUPPORTED: return "not supported";
        case JXL_ENC_ERR_API_USAGE: return "API usage error";
        default: return "unknown error";
    }
}

// libjxl's own buffers (image planes, coefficients: ~1.3 GB at peak for a 45 MP transcode) come from this memory
// manager instead of malloc. Blocks of 256 KB and more are anonymous mappings that go back to the kernel the moment
// libjxl frees them; through malloc, macOS kept them in its large-allocation cache, so every transcode a job ever
// ran in parallel stayed in the process's footprint (Docs/DECISIONS.md D-ENG-10). Smaller blocks stay on malloc.
// The size lives in a 64-byte header (keeps libjxl's 64-byte alignment of the returned pointer).
constexpr size_t kHeader = 64;
constexpr size_t kMapThreshold = 256 * 1024;

void *hmb_jxl_alloc(void *, size_t size) {
    if (void *p = hmb_arena::allocate(size)) return p;
    const size_t total = size + kHeader;
    uint8_t *base;
    if (total >= kMapThreshold) {
        void *mapped = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (mapped == MAP_FAILED) return nullptr;
        base = static_cast<uint8_t *>(mapped);
    } else {
        base = static_cast<uint8_t *>(std::malloc(total));
        if (base == nullptr) return nullptr;
    }
    *reinterpret_cast<size_t *>(base) = total;
    return base + kHeader;
}

void hmb_jxl_free(void *, void *address) {
    if (address == nullptr || hmb_arena::release(address)) return;
    uint8_t *base = static_cast<uint8_t *>(address) - kHeader;
    const size_t total = *reinterpret_cast<size_t *>(base);
    if (total >= kMapThreshold) {
        munmap(base, total);
    } else {
        std::free(base);
    }
}

JxlMemoryManager memory_manager = {nullptr, hmb_jxl_alloc, hmb_jxl_free};

/// A growable malloc'ed byte buffer (plain struct: no destructors, explicit release).
struct Growable {
    uint8_t *data;
    size_t capacity;
    bool grow(size_t minimum) {
        size_t next = capacity > 0 ? capacity : 1 << 16;
        while (next < minimum) next *= 2;
        uint8_t *bigger = static_cast<uint8_t *>(std::realloc(data, next));
        if (bigger == nullptr) return false;
        data = bigger;
        capacity = next;
        return true;
    }
};

// libjxl's parallel runner: the calling thread plus up to threads − 1 helper threads per parallel stage, started and
// joined inside the call (no pool outliving the call, nothing GCD-based, so it also works in a forked child). Plain
// pthreads: std::thread would allocate its libc++ thread record with our arena operator new on the calling thread
// and libc++.dylib frees it with its own operator delete at thread exit. libjxl's
// output does not depend on the number of threads or on scheduling (each task writes its own group; results are merged
// in order), so this only shortens a transcode/reconstruction, it never changes its bytes. The helper threads
// allocate from the caller's arena slot (hmb_arena::Adopt), so their std::vector storage goes back to the kernel with
// the call like the caller's.
struct Runner {
    uint32_t threads;
    void *slot;               // the calling thread's arena slot
};
struct RunnerJob {
    void *opaque;
    JxlParallelRunFunction func;
    std::atomic<uint32_t> next;
    uint32_t end;
    void *slot;
};
void runner_worker(RunnerJob *job, size_t thread) {
    hmb_arena::Adopt adopt(job->slot);
    for (uint32_t i = job->next.fetch_add(1); i < job->end; i = job->next.fetch_add(1)) {
        job->func(job->opaque, i, thread);
    }
}
struct HelperStart {
    RunnerJob *job;
    size_t thread;
};
void *runner_helper(void *context) {
    const HelperStart *start = static_cast<const HelperStart *>(context);
    runner_worker(start->job, start->thread);
    return nullptr;
}
constexpr uint32_t kMaxRunnerThreads = 16;
constexpr size_t kHelperStack = size_t(8) << 20;   // like the engine's worker threads
JxlParallelRetCode hmb_jxl_runner(void *runner_opaque, void *jpegxl_opaque, JxlParallelRunInit init,
                                  JxlParallelRunFunction func, uint32_t start_range, uint32_t end_range) {
    const Runner *runner = static_cast<const Runner *>(runner_opaque);
    if (start_range > end_range) return -1;
    if (start_range == end_range) return 0;
    const uint32_t threads =
        std::max<uint32_t>(1, std::min({runner->threads, end_range - start_range, kMaxRunnerThreads}));
    if (init(jpegxl_opaque, threads) != 0) return -1;
    if (threads == 1) {
        for (uint32_t i = start_range; i < end_range; ++i) func(jpegxl_opaque, i, 0);
        return 0;
    }
    RunnerJob job;
    job.opaque = jpegxl_opaque;
    job.func = func;
    job.next.store(start_range);
    job.end = end_range;
    job.slot = runner->slot;
    pthread_t helpers[kMaxRunnerThreads];
    HelperStart starts[kMaxRunnerThreads];
    bool started[kMaxRunnerThreads] = {};
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, kHelperStack);
    for (uint32_t t = 1; t < threads; ++t) {
        starts[t] = {&job, t};
        started[t] = pthread_create(&helpers[t], &attributes, runner_helper, &starts[t]) == 0;
    }
    pthread_attr_destroy(&attributes);
    runner_worker(&job, 0);     // a helper that could not start leaves its share to the others: same result
    for (uint32_t t = 1; t < threads; ++t) {
        if (started[t]) pthread_join(helpers[t], nullptr);
    }
    return 0;
}

}  // namespace

int hmb_jxl_transcode_jpeg(const uint8_t *jpeg, size_t size, int effort, hmb_buffer *out, char *err, size_t err_len) {
    return hmb_jxl_transcode_jpeg_threads(jpeg, size, effort, 1, out, err, err_len);
}

int hmb_jxl_reconstruct_jpeg(const uint8_t *jxl, size_t size, hmb_buffer *out, char *err, size_t err_len) {
    return hmb_jxl_reconstruct_jpeg_threads(jxl, size, 1, out, err, err_len);
}

int hmb_jxl_transcode_jpeg_threads(const uint8_t *jpeg, size_t size, int effort, int threads, hmb_buffer *out,
                                   char *err, size_t err_len) {
    if (out == nullptr) return fail(err, err_len, "hmb_jxl_transcode_jpeg: out is NULL");
    out->data = nullptr;
    out->size = 0;
    if (jpeg == nullptr || size < 4) return fail(err, err_len, "hmb_jxl_transcode_jpeg: input is empty");
    if (effort < 1 || effort > 10) return fail(err, err_len, "hmb_jxl_transcode_jpeg: effort %d outside 1...10", effort);

    hmb_arena::Scope arena;   // libjxl's containers come from a private arena, returned when this call ends
    JxlEncoder *encoder = JxlEncoderCreate(&memory_manager);
    if (encoder == nullptr) return fail(err, err_len, "hmb_jxl_transcode_jpeg: out of memory (encoder)");
    Growable buffer = {nullptr, 0};
    int result = 0;
    Runner runner = {static_cast<uint32_t>(std::max(1, threads)), hmb_arena::current()};
    do {
        if (runner.threads > 1 && JxlEncoderSetParallelRunner(encoder, hmb_jxl_runner, &runner) != JXL_ENC_SUCCESS) {
            result = fail(err, err_len, "hmb_jxl_transcode_jpeg: parallel runner rejected");
            break;
        }
        if (JxlEncoderUseContainer(encoder, JXL_TRUE) != JXL_ENC_SUCCESS ||
            JxlEncoderStoreJPEGMetadata(encoder, JXL_TRUE) != JXL_ENC_SUCCESS) {
            result = fail(err, err_len, "hmb_jxl_transcode_jpeg: setup failed (%s)", encoder_error(JxlEncoderGetError(encoder)));
            break;
        }
        JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(encoder, nullptr);
        if (settings == nullptr ||
            JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, effort) != JXL_ENC_SUCCESS) {
            result = fail(err, err_len, "hmb_jxl_transcode_jpeg: frame settings failed (%s)", encoder_error(JxlEncoderGetError(encoder)));
            break;
        }
        if (JxlEncoderAddJPEGFrame(settings, jpeg, size) != JXL_ENC_SUCCESS) {
            result = fail(err, err_len, "hmb_jxl_transcode_jpeg: %s", encoder_error(JxlEncoderGetError(encoder)));
            break;
        }
        JxlEncoderCloseInput(encoder);
        if (!buffer.grow(size / 2 + 4096)) {
            result = fail(err, err_len, "hmb_jxl_transcode_jpeg: out of memory");
            break;
        }
        size_t used = 0;
        for (;;) {
            uint8_t *next = buffer.data + used;
            size_t available = buffer.capacity - used;
            const JxlEncoderStatus status = JxlEncoderProcessOutput(encoder, &next, &available);
            used = static_cast<size_t>(next - buffer.data);
            if (status == JXL_ENC_SUCCESS) break;
            if (status == JXL_ENC_NEED_MORE_OUTPUT) {
                if (!buffer.grow(buffer.capacity * 2)) {
                    result = fail(err, err_len, "hmb_jxl_transcode_jpeg: out of memory");
                    break;
                }
                continue;
            }
            result = fail(err, err_len, "hmb_jxl_transcode_jpeg: %s", encoder_error(JxlEncoderGetError(encoder)));
            break;
        }
        if (result != 0) break;
        out->data = buffer.data;
        out->size = used;
        buffer.data = nullptr;
    } while (false);
    std::free(buffer.data);
    JxlEncoderDestroy(encoder);
    return result;
}

int hmb_jxl_reconstruct_jpeg_threads(const uint8_t *jxl, size_t size, int threads, hmb_buffer *out, char *err,
                                     size_t err_len) {
    if (out == nullptr) return fail(err, err_len, "hmb_jxl_reconstruct_jpeg: out is NULL");
    out->data = nullptr;
    out->size = 0;
    if (jxl == nullptr || size == 0) return fail(err, err_len, "hmb_jxl_reconstruct_jpeg: input is empty");

    hmb_arena::Scope arena;
    JxlDecoder *decoder = JxlDecoderCreate(&memory_manager);
    if (decoder == nullptr) return fail(err, err_len, "hmb_jxl_reconstruct_jpeg: out of memory (decoder)");
    Growable buffer = {nullptr, 0};
    size_t used = 0;
    bool reconstructing = false;
    int result = 0;
    Runner runner = {static_cast<uint32_t>(std::max(1, threads)), hmb_arena::current()};
    do {
        if (runner.threads > 1 && JxlDecoderSetParallelRunner(decoder, hmb_jxl_runner, &runner) != JXL_DEC_SUCCESS) {
            result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: parallel runner rejected");
            break;
        }
        if (JxlDecoderSubscribeEvents(decoder, JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS ||
            JxlDecoderSetInput(decoder, jxl, size) != JXL_DEC_SUCCESS) {
            result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: decoder setup failed");
            break;
        }
        JxlDecoderCloseInput(decoder);
        bool done = false;
        while (!done && result == 0) {
            const JxlDecoderStatus status = JxlDecoderProcessInput(decoder);
            switch (status) {
                case JXL_DEC_JPEG_RECONSTRUCTION:
                    if (!buffer.grow(size + size / 2 + 4096)) {
                        result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: out of memory");
                        break;
                    }
                    if (JxlDecoderSetJPEGBuffer(decoder, buffer.data, buffer.capacity) != JXL_DEC_SUCCESS) {
                        result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: could not set the JPEG buffer");
                        break;
                    }
                    reconstructing = true;
                    break;
                case JXL_DEC_JPEG_NEED_MORE_OUTPUT: {
                    used = buffer.capacity - JxlDecoderReleaseJPEGBuffer(decoder);
                    if (!buffer.grow(buffer.capacity * 2)) {
                        result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: out of memory");
                        break;
                    }
                    if (JxlDecoderSetJPEGBuffer(decoder, buffer.data + used, buffer.capacity - used) != JXL_DEC_SUCCESS) {
                        result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: could not grow the JPEG buffer");
                    }
                    break;
                }
                case JXL_DEC_FULL_IMAGE:
                    if (!reconstructing) result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: the file carries no JPEG reconstruction data");
                    break;
                case JXL_DEC_NEED_IMAGE_OUT_BUFFER:
                    result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: the file carries no JPEG reconstruction data");
                    break;
                case JXL_DEC_SUCCESS:
                    done = true;
                    break;
                case JXL_DEC_NEED_MORE_INPUT:
                    result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: truncated input");
                    break;
                case JXL_DEC_ERROR:
                    result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: decoding failed (corrupt or unsupported file)");
                    break;
                default:
                    break;   // informational events we did not subscribe to
            }
        }
        if (result != 0) break;
        if (!reconstructing) {
            result = fail(err, err_len, "hmb_jxl_reconstruct_jpeg: the file carries no JPEG reconstruction data");
            break;
        }
        used = buffer.capacity - JxlDecoderReleaseJPEGBuffer(decoder);
        out->data = buffer.data;
        out->size = used;
        buffer.data = nullptr;
    } while (false);
    std::free(buffer.data);
    JxlDecoderDestroy(decoder);
    return result;
}
