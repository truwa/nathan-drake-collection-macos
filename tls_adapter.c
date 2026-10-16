/* CrossOver adapter for the Uncharted Windows runtime.
 * Guest code reads its thread block with mov rax, gs:[0]. The runtime rewrites
 * that displacement to a TEB TLS slot. Slots 0-63 are gs:[0x1480 + 8*slot].
 * Slot 64 and above live behind gs:[0x1780], and this runtime exits instead.
 * A slot is taken in DllMain, before Wine's later DLLs fill the low range.
 */
#include <windows.h>
#include <stdint.h>

#define TLS_SLOT_RVA 0x00cec320u
#define LOW_MAP_RVA  0x00010110u

typedef struct {
    uint64_t address;
    uint64_t size;
    uint64_t flags;
} Segment;

typedef void *(*LowMap)(size_t size, int protection);

static int is_tcb_load(const unsigned char *at) {
    return *(const uint64_t *)at == UINT64_C(0x25048b4865) && at[8] == 0;
}

static void stop(const char *message) {
    DWORD written = 0;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), message, lstrlenA(message), &written, NULL);
    ExitProcess(21);
}

static void relative_jump(unsigned char *at, const unsigned char *target) {
    intptr_t delta = (intptr_t)((uintptr_t)target - ((uintptr_t)at + 5));
    if (delta < INT32_MIN || delta > INT32_MAX) {
        stop("STOP: TLS trampoline is out of range\r\n");
    }
    at[0] = 0xe9;
    *(int32_t *)(at + 1) = (int32_t)delta;
}

static DWORD *tls_slot(void) {
    return (DWORD *)((unsigned char *)GetModuleHandleW(NULL) + TLS_SLOT_RVA);
}

static void claim_slot(void) {
    DWORD *slot = tls_slot();
    if (*slot != TLS_OUT_OF_INDEXES) return;
    *slot = TlsAlloc();
}

/* The guest window is one reserved block. A trampoline has to sit inside it,
 * within 2 GB of the rewritten instruction. The low-map cursor lives far
 * below the macOS guard and cannot reach the guest with a 32-bit jump.
 */
static int in_jump_range(uintptr_t from, uintptr_t to) {
    intptr_t delta = (intptr_t)(to - from);
    return delta > INT32_MIN + 0x100000 && delta < INT32_MAX - 0x100000;
}

static unsigned char *nearby_stubs(unsigned char *image, const Segment *segments,
                                   uint64_t count, size_t bytes) {
    uintptr_t low = UINTPTR_MAX;
    uintptr_t high = 0;
    for (uint64_t s = 0; s < count; ++s) {
        if (!(segments[s].flags & 1) || segments[s].size < 9) continue;
        uintptr_t start = (uintptr_t)image + segments[s].address;
        uintptr_t end = start + segments[s].size;
        if (start < low) low = start;
        if (end > high) high = end;
    }
    if (!high) return NULL;

    uintptr_t base = (high + 0xFFFF) & ~(uintptr_t)0xFFFF;
    unsigned char *stubs = VirtualAlloc((void *)base, bytes, MEM_RESERVE | MEM_COMMIT,
                                         PAGE_EXECUTE_READWRITE);
    if (stubs) return stubs;

    stubs = VirtualAlloc(NULL, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    if (stubs && in_jump_range(low, (uintptr_t)stubs) && in_jump_range(high, (uintptr_t)stubs))
        return stubs;
    if (stubs) VirtualFree(stubs, 0, MEM_RELEASE);
    return NULL;
}

__declspec(dllexport) uint64_t patch_guest_tls(
    const Segment *segments, uint64_t count, unsigned char *image) {
    claim_slot();
    DWORD slot = *tls_slot();
    if (slot == TLS_OUT_OF_INDEXES) stop("STOP: TlsAlloc failed\r\n");

    uint64_t matches = 0;
    for (uint64_t s = 0; s < count; ++s) {
        if (!(segments[s].flags & 1) || segments[s].size < 9) continue;
        unsigned char *at = image + segments[s].address;
        unsigned char *end = at + segments[s].size - 9;
        for (; at <= end; ++at) {
            if (is_tcb_load(at)) {
                ++matches;
                at += 8;
            }
        }
    }

    unsigned char *stubs = NULL;
    if (matches && slot >= 64) {
        stubs = nearby_stubs(image, segments, count, (size_t)matches * 32);
        if (!stubs) {
            unsigned char *main_image = (unsigned char *)GetModuleHandleW(NULL);
            LowMap allocate = (LowMap)(main_image + LOW_MAP_RVA);
            stubs = allocate((size_t)matches * 32, 7);
        }
        if (!stubs) stop("STOP: could not allocate TLS trampolines\r\n");
    }

    uint64_t patched = 0;
    for (uint64_t s = 0; s < count; ++s) {
        if (!(segments[s].flags & 1) || segments[s].size < 9) continue;
        unsigned char *at = image + segments[s].address;
        unsigned char *end = at + segments[s].size - 9;
        for (; at <= end; ++at) {
            if (!is_tcb_load(at)) continue;
            if (slot < 64) {
                *(uint32_t *)(at + 5) = 0x1480 + slot * 8;
            } else {
                unsigned char *stub = stubs + patched * 32;
                *(uint64_t *)stub = UINT64_C(0x178025048b4865);
                stub[8] = 0;
                stub[9] = 0x48;
                stub[10] = 0x8b;
                stub[11] = 0x80;
                *(uint32_t *)(stub + 12) = (slot - 64) * 8;
                relative_jump(stub + 16, at + 9);
                relative_jump(at, stub);
                for (unsigned i = 5; i < 9; ++i) at[i] = 0x90;
            }
            ++patched;
            at += 8;
        }
    }
    if (stubs) FlushInstructionCache(GetCurrentProcess(), stubs, (SIZE_T)matches * 32);
    return patched;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)instance;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) claim_slot();
    return TRUE;
}
