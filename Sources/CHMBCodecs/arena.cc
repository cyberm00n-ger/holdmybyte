// holdmybyte codec bridge: per-call arenas for libjxl's C++ containers (see arena.h, Docs/DECISIONS.md D-ENG-10).
//
// Why: a lossless JPEG → JPEG XL transcode of a 45 MP photo churns through ~2 GB of std::vector storage (token
// streams, coefficient copies; 30 000 allocations, peak ~0.9 GB). macOS malloc keeps the freed pages of these sizes
// resident (dirty in its large cache, or "reusable" in its small regions, which still count as resident), so every
// archive lane added ~1–1.5 GB of resident memory that never went away. libjxl's JxlMemoryManager only covers its
// image planes; its containers use the global operator new.
//
// How: this file replaces the global operator new/delete. Outside an arena scope they are exactly the default
// (malloc/free with the new-handler loop). Inside `hmb_arena::Scope` (only around libjxl calls in jxl.cc, which run
// single-threaded on the calling thread), allocations come from a private slot of one reserved address range:
// small blocks from size-class free lists carved out of 1 MB slabs, larger blocks as page runs (best fit,
// coalesced on free). When the scope ends with no block alive the slot's pages are replaced by fresh zero-fill
// mappings, which returns them to the kernel at once. `operator delete` tells arena blocks apart by address alone,
// so a block freed later or on another thread is handled too; a slot with surviving blocks is only reused once they
// are all gone. If the reservation fails or a slot runs out, allocations fall back to malloc transparently.
#include "arena.h"
#include "hmb_arena_diag.h"

#include <pthread.h>
#include <sys/mman.h>
#include <mach/vm_statistics.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>

namespace {

constexpr size_t kSlotCount = 16;
constexpr size_t kSlotBytes = size_t(4) << 30;   // address space per slot; pages are committed on first touch
constexpr size_t kHeader = 16;                   // keeps the 16-byte alignment operator new guarantees
constexpr size_t kSmallMax = 256 * 1024;         // larger requests are page runs
constexpr size_t kSlabBytes = 1 << 20;           // small blocks are carved from slabs of this size
constexpr uint32_t kMagic = 0x484D4241;          // "HMBA"
constexpr int kSmallClasses = 96;
constexpr int kTag = VM_MAKE_TAG(VM_MEMORY_APPLICATION_SPECIFIC_1);

struct Header {
    uint32_t magic;
    uint32_t big;        // 0: small block (value = class), 1: page run (value = run bytes)
    uint64_t value;
};
static_assert(sizeof(Header) == kHeader, "header size");

struct FreeBlock { FreeBlock *next; };
struct Run { Run *next; size_t bytes; };          // a free page run, kept sorted by address

// Size classes: multiples of 16 up to 1 KB (0…63), then 4 per power of two up to 256 KB (64…95).
int classOf(size_t n) {
    if (n <= 1024) return static_cast<int>((n + 15) / 16) - 1;
    int p = 63 - __builtin_clzll(static_cast<unsigned long long>(n - 1));     // 2^p < n ≤ 2^(p+1)
    const size_t quarter = size_t(1) << (p - 2);
    const size_t sub = (n - (size_t(1) << p) + quarter - 1) / quarter;         // 1…4
    return 64 + (p - 10) * 4 + static_cast<int>(sub) - 1;
}
size_t classSize(int index) {
    if (index < 64) return static_cast<size_t>(index + 1) * 16;
    const int p = 10 + (index - 64) / 4;
    const size_t sub = static_cast<size_t>((index - 64) % 4 + 1);
    return (size_t(1) << p) + sub * (size_t(1) << (p - 2));
}

struct Slot {
    std::mutex lock;
    uint8_t *base = nullptr;
    size_t bump = 0;            // page-aligned end of the carved part
    size_t highWater = 0;       // furthest end of the carved range since the last reset (the pages to drop)
    long live = 0;              // blocks handed out and not yet freed
    bool owned = false;         // a scope is using the slot
    Run *runs = nullptr;
    FreeBlock *small[kSmallClasses] = {};
    uint8_t *slab = nullptr;    // current slab for small blocks
    size_t slabLeft = 0;
};

std::atomic<uintptr_t> g_base{0};
size_t g_page = 16384;
Slot g_slots[kSlotCount];
std::mutex g_acquire;
std::once_flag g_reserve;
thread_local Slot *t_slot = nullptr;

// fork() safety: the child must not inherit a lock held by another thread of the parent (tests fork; see
// CodecTests.fiftyEncodesDoNotLeak), so every arena lock is taken around the fork, like malloc does with its own.
void forkPrepare() {
    g_acquire.lock();
    for (Slot &s : g_slots) s.lock.lock();
}
void forkRelease() {
    for (size_t i = kSlotCount; i-- > 0;) g_slots[i].lock.unlock();
    g_acquire.unlock();
}

void reserve() {
    pthread_atfork(forkPrepare, forkRelease, forkRelease);
    g_page = static_cast<size_t>(getpagesize());
    void *base = mmap(nullptr, kSlotCount * kSlotBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, kTag, 0);
    if (base == MAP_FAILED) return;
    for (size_t i = 0; i < kSlotCount; ++i) g_slots[i].base = static_cast<uint8_t *>(base) + i * kSlotBytes;
    g_base.store(reinterpret_cast<uintptr_t>(base), std::memory_order_release);
}

/// Slot of an arena pointer, or nullptr.
Slot *slotOf(const void *p) {
    const uintptr_t base = g_base.load(std::memory_order_acquire);
    const uintptr_t offset = reinterpret_cast<uintptr_t>(p) - base;
    if (base == 0 || offset >= kSlotCount * kSlotBytes) return nullptr;
    return &g_slots[offset / kSlotBytes];
}

/// Drops every page of the slot and its bookkeeping (lock held, no live block).
void resetLocked(Slot &s) {
    if (s.highWater > 0) {
        // A fixed mapping over the old one replaces its pages by zero-fill ones: the old pages are freed now.
        mmap(s.base, s.highWater, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, kTag, 0);
    }
    s.bump = 0;
    s.highWater = 0;
    s.runs = nullptr;
    std::memset(s.small, 0, sizeof s.small);
    s.slab = nullptr;
    s.slabLeft = 0;
}

/// A page run of `bytes` (page multiple): best fit among the free runs (split), else from the bump pointer.
uint8_t *takeRun(Slot &s, size_t bytes) {
    Run **best = nullptr;
    for (Run **link = &s.runs; *link != nullptr; link = &(*link)->next) {
        if ((*link)->bytes >= bytes && (best == nullptr || (*link)->bytes < (*best)->bytes)) best = link;
    }
    if (best != nullptr) {
        Run *run = *best;
        uint8_t *start = reinterpret_cast<uint8_t *>(run);
        if (run->bytes > bytes) {
            Run *rest = reinterpret_cast<Run *>(start + bytes);
            rest->next = run->next;
            rest->bytes = run->bytes - bytes;
            *best = rest;
        } else {
            *best = run->next;
        }
        return start;
    }
    if (s.bump + bytes > kSlotBytes) return nullptr;
    uint8_t *start = s.base + s.bump;
    s.bump += bytes;
    if (s.bump > s.highWater) s.highWater = s.bump;
    return start;
}

/// Returns a page run to the address-sorted free list, merging it with adjacent runs; a run that then ends at the
/// bump pointer goes back to the bump region (its pages stay committed until the reset).
void giveRun(Slot &s, uint8_t *start, size_t bytes) {
    Run *prev = nullptr, *next = s.runs;
    while (next != nullptr && reinterpret_cast<uint8_t *>(next) < start) { prev = next; next = next->next; }
    Run *run = reinterpret_cast<Run *>(start);
    run->bytes = bytes;
    run->next = next;
    if (next != nullptr && start + bytes == reinterpret_cast<uint8_t *>(next)) {
        run->bytes += next->bytes;
        run->next = next->next;
    }
    if (prev != nullptr && reinterpret_cast<uint8_t *>(prev) + prev->bytes == start) {
        prev->bytes += run->bytes;
        prev->next = run->next;
        run = prev;
    } else if (prev != nullptr) {
        prev->next = run;
    } else {
        s.runs = run;
    }
    if (run->next == nullptr && reinterpret_cast<uint8_t *>(run) + run->bytes == s.base + s.bump) {
        s.bump -= run->bytes;
        if (s.runs == run) {
            s.runs = nullptr;
        } else {
            Run *before = s.runs;
            while (before->next != run) before = before->next;
            before->next = nullptr;
        }
    }
}

void *allocate(Slot &s, size_t n) {
    std::lock_guard<std::mutex> guard(s.lock);
    if (n == 0) n = 1;
    Header *h;
    if (n <= kSmallMax) {
        const int index = classOf(n);
        if (FreeBlock *block = s.small[index]) {
            s.small[index] = block->next;
            h = reinterpret_cast<Header *>(block);
        } else {
            const size_t bytes = kHeader + classSize(index);
            if (s.slabLeft < bytes) {
                uint8_t *slab = takeRun(s, kSlabBytes);
                if (slab == nullptr) return nullptr;
                s.slab = slab;
                s.slabLeft = kSlabBytes;     // the tail of the previous slab is abandoned until the reset
            }
            h = reinterpret_cast<Header *>(s.slab);
            s.slab += bytes;
            s.slabLeft -= bytes;
        }
        h->big = 0;
        h->value = static_cast<uint64_t>(index);
    } else {
        const size_t bytes = (kHeader + n + g_page - 1) / g_page * g_page;
        uint8_t *start = takeRun(s, bytes);
        if (start == nullptr) return nullptr;
        h = reinterpret_cast<Header *>(start);
        h->big = 1;
        h->value = bytes;
    }
    h->magic = kMagic;
    ++s.live;
    return reinterpret_cast<uint8_t *>(h) + kHeader;
}

void release(Slot &s, void *p) {
    std::lock_guard<std::mutex> guard(s.lock);
    Header *h = reinterpret_cast<Header *>(static_cast<uint8_t *>(p) - kHeader);
    if (h->magic != kMagic) std::abort();          // not an arena block: a corrupted heap, never ignore it
    h->magic = 0;
    if (h->big == 0) {
        const int index = static_cast<int>(h->value);
        FreeBlock *block = reinterpret_cast<FreeBlock *>(h);
        block->next = s.small[index];
        s.small[index] = block;
    } else {
        giveRun(s, reinterpret_cast<uint8_t *>(h), static_cast<size_t>(h->value));
    }
    --s.live;
    if (s.live == 0 && !s.owned) resetLocked(s);    // the last survivor of an ended scope
}

void *arenaAllocate(size_t n) {
    Slot *s = t_slot;
    return s != nullptr ? allocate(*s, n) : nullptr;
}

bool arenaRelease(void *p) {
    if (p == nullptr) return true;
    Slot *s = slotOf(p);
    if (s == nullptr) return false;
    release(*s, p);
    return true;
}

void *defaultNew(size_t size) {
    if (size == 0) size = 1;
    for (;;) {
        if (void *p = std::malloc(size)) return p;
        std::new_handler handler = std::get_new_handler();
        if (handler == nullptr) throw std::bad_alloc();
        handler();
    }
}

}  // namespace

namespace hmb_arena {

Scope::Scope() : slot_(nullptr) {
    std::call_once(g_reserve, reserve);
    if (g_base.load(std::memory_order_acquire) == 0 || t_slot != nullptr) return;
    std::lock_guard<std::mutex> acquire(g_acquire);
    for (Slot &s : g_slots) {
        std::lock_guard<std::mutex> guard(s.lock);
        if (!s.owned && s.live == 0) {
            s.owned = true;
            slot_ = &s;
            break;
        }
    }
    t_slot = static_cast<Slot *>(slot_);
}

Scope::~Scope() {
    if (slot_ == nullptr) return;
    t_slot = nullptr;
    Slot &s = *static_cast<Slot *>(slot_);
    std::lock_guard<std::mutex> guard(s.lock);
    s.owned = false;
    if (s.live == 0) resetLocked(s);
}

void *allocate(size_t size) { return arenaAllocate(size); }
bool release(void *p) { return arenaRelease(p); }

void Scope::discard() {
    if (slot_ == nullptr) return;
    Slot &s = *static_cast<Slot *>(slot_);
    std::lock_guard<std::mutex> guard(s.lock);
    s.live = 0;
}

size_t residentBytes() {
    std::call_once(g_reserve, reserve);
    size_t total = 0;
    for (Slot &s : g_slots) {
        std::lock_guard<std::mutex> guard(s.lock);
        total += s.highWater;
    }
    return total;
}

int busySlots() {
    std::call_once(g_reserve, reserve);
    int busy = 0;
    for (Slot &s : g_slots) {
        std::lock_guard<std::mutex> guard(s.lock);
        if (s.owned || s.live > 0) ++busy;
    }
    return busy;
}

}  // namespace hmb_arena

// Replaceable global allocation functions ([new.delete]). Identical to the defaults unless an arena scope is active
// on the calling thread (allocation) or the pointer lies in the arena range (deallocation).
void *operator new(std::size_t size) {
    if (void *p = arenaAllocate(size)) return p;
    return defaultNew(size);
}
void *operator new[](std::size_t size) { return ::operator new(size); }
void *operator new(std::size_t size, const std::nothrow_t &) noexcept {
    try { return ::operator new(size); } catch (...) { return nullptr; }
}
void *operator new[](std::size_t size, const std::nothrow_t &) noexcept {
    try { return ::operator new(size); } catch (...) { return nullptr; }
}
void operator delete(void *p) noexcept { if (!arenaRelease(p)) std::free(p); }
void operator delete[](void *p) noexcept { ::operator delete(p); }
void operator delete(void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete[](void *p, std::size_t) noexcept { ::operator delete(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { ::operator delete(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { ::operator delete(p); }

size_t hmb_arena_resident_bytes(void) { return hmb_arena::residentBytes(); }
int hmb_arena_busy_slots(void) { return hmb_arena::busySlots(); }
