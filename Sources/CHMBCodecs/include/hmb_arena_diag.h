// holdmybyte codec bridge: diagnostics of the codec allocation arenas (Docs/DECISIONS.md D-ENG-10), for tests.
// Not part of the frozen codec API in hmb_codecs.h.
#ifndef HMB_ARENA_DIAG_H
#define HMB_ARENA_DIAG_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Address space the arenas have carved since their last reset, in bytes (0 when no codec call is running).
size_t hmb_arena_resident_bytes(void);
/// Arena slots owned by a running codec call or still holding a block that outlived its call.
int hmb_arena_busy_slots(void);
#ifdef __cplusplus
}  // extern "C"
#endif
#endif  // HMB_ARENA_DIAG_H
