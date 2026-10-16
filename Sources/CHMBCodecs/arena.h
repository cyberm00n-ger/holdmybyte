// holdmybyte codec bridge: per-call allocation arenas for libjxl's C++ containers (Docs/DECISIONS.md D-ENG-10).
// Private to CHMBCodecs (not part of the frozen hmb_codecs.h API).
#ifndef HMB_ARENA_H
#define HMB_ARENA_H

#include <cstddef>

namespace hmb_arena {

/// While a Scope is alive on a thread, every `operator new` on that thread is served from a private arena (one
/// slot of a reserved address range), and the arena's pages go back to the kernel when the scope ends. Without
/// it, a libjxl transcode leaves ~1 GB of freed std::vector storage in malloc's regions per concurrent transcode,
/// resident for the rest of the process. Blocks still alive at the end (none are expected) keep their slot until
/// they are freed; `operator delete` recognises arena blocks by address from any thread.
class Scope {
public:
    Scope();
    ~Scope();
    /// Gives every block of this scope up at once (its owners are gone, e.g. skipped by a longjmp); the pages go back
    /// when the scope ends. Only for blocks nothing can reach any more.
    void discard();
    Scope(const Scope &) = delete;
    Scope &operator=(const Scope &) = delete;
private:
    void *slot_;
};

/// Lets another thread allocate from a scope's arena while it runs work for that scope's call (libjxl's parallel
/// runner): while an Adopt is alive, `operator new` on this thread is served from `slot` (from `current()` on the
/// thread that owns the scope; nullptr adopts nothing). The scope must outlive every Adopt of its slot.
class Adopt {
public:
    explicit Adopt(void *slot);
    ~Adopt();
    Adopt(const Adopt &) = delete;
    Adopt &operator=(const Adopt &) = delete;
private:
    void *previous_;
};
/// The calling thread's active arena slot (nullptr when no scope is active), for `Adopt`.
void *current();

/// Allocation from the calling thread's active scope; nullptr when there is none (or its slot is full).
void *allocate(size_t size);
/// Frees `p` if it is an arena block (true); false for any other pointer.
bool release(void *p);

/// Diagnostics for tests: bytes of pages the arenas currently hold (all slots), and slots in use or retired.
size_t residentBytes();
int busySlots();

}  // namespace hmb_arena

#endif  // HMB_ARENA_H
