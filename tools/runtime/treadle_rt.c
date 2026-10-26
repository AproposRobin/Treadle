/*
 * treadle_rt.c - the C runtime linked into every Treadle program (ABI: treadle_rt.h).
 *
 * Compiled by the same clang as the program, once per configuration, and cached by the build
 * driver (TreadleBackend). Two builds share this file:
 *
 *   Release (default)        rt_alloc / rt_free are calloc / free; no bookkeeping. A double free the C
 *                            heap notices and an access that faults end the program as a fatal error
 *                            (exit code 3) through the fault handlers rt_start installs.
 *   Debug (-DTREADLE_DEBUG)  every heap block made by rt_alloc_dbg carries an rt_dbg_header in
 *                            front of the object: magic, the allocating and the freeing site, the
 *                            size and a doubly linked live list. rt_free_dbg poisons the object
 *                            (its vtable becomes rt_poison_vtable, the rest 0xDD) and keeps it in a
 *                            quarantine ring before the memory goes back to the C heap, so a double
 *                            free names both Delete nodes and a use after free is caught. At exit
 *                            the live list is the leak report (type, size, Construct node).
 *
 * rt_exit returns the program's exit code; in Debug a clean exit (code 0) with leaks returns the
 * number of leaked objects instead, so a leak is never silent. A fatal error prints
 * "fatal: <message> at <Type.Member> node <id>", writes <exe>.fatal.txt, breaks into an attached
 * debugger (Debug), flushes and ends the process with exit code 3.
 *
 * The legacy probe shim (treadle_alloc / treadle_free / treadle_rt_report, used by the hand-written
 * probes in tools/probe) is kept at the end on top of the same allocator.
 */
#ifndef _WIN32
#define _GNU_SOURCE 1 /* posix_memalign, readlink under -std=c11 */
#endif
#include "treadle_rt.h"

#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <malloc.h>
#ifdef _WIN32
#include <io.h>
#define rt_isatty _isatty
#define rt_fileno _fileno
#else
#define rt_isatty isatty
#define rt_fileno fileno
#endif
/* stdout is not a terminal (a pipe: the editor's Run, a debugger, a redirection) and the program may run for
   long: each Console write is flushed, so its output arrives while it runs (the C library would buffer it). */
static int rt_flush_each;
#ifndef _WIN32
/* POSIX (Linux, glibc): the arguments are UTF-8 already, the exe's path is /proc/self/exe, the
   linker's __start_ / __stop_ symbols bound the tables (see "start / exit"). */
#include <unistd.h>
#include <signal.h>
/* PR_SET_PTRACER: Debug > Attach to Process under Yama ptrace_scope 1; PR_SET_PDEATHSIG: a program the
   editor runs dies with the editor */
#include <sys/prctl.h>
#endif
#ifdef _WIN32
/* The few Win32 functions the runtime calls, declared here rather than through windows.h, which is
   most of the runtime's compile time (kernel32 and shell32 are default mingw link libraries). */
typedef unsigned long rt_dword;
typedef unsigned short rt_wchar;
#define MAX_PATH 260
#define CP_UTF8 65001u
__declspec(dllimport) rt_dword __stdcall GetModuleFileNameA(void* module, char* path, rt_dword size);
__declspec(dllimport) int __stdcall IsDebuggerPresent(void);
__declspec(dllimport) rt_wchar* __stdcall GetCommandLineW(void);
__declspec(dllimport) rt_wchar** __stdcall CommandLineToArgvW(const rt_wchar* line, int* count);
__declspec(dllimport) int __stdcall WideCharToMultiByte(unsigned cp, rt_dword flags, const rt_wchar* w, int wn,
                                                        char* s, int sn, const char* dflt, int* used);
__declspec(dllimport) void* __stdcall LocalFree(void* mem);
__declspec(dllimport) void* __stdcall AddVectoredExceptionHandler(unsigned long first, long (__stdcall *handler)(void*));
__declspec(dllimport) void* __stdcall SetUnhandledExceptionFilter(long (__stdcall *filter)(void*));
__declspec(dllimport) int __stdcall TerminateProcess(void* process, unsigned exitCode);
__declspec(dllimport) void* __stdcall GetCurrentProcess(void);
__declspec(dllimport) void* __stdcall GetStdHandle(rt_dword which);
__declspec(dllimport) int __stdcall AttachConsole(rt_dword pid);
__declspec(dllimport) void __stdcall OutputDebugStringA(const char* text);
#endif

/* ================================================================== shared helpers */

static int32_t rt_argc;
static char** rt_argv;

/* A windowed program (kind windowed) with no output of its own (no pipe or file from its parent, no
   parent console to attach): the C library's stdout and stderr go into a pipe whose reader thread
   hands the text to OutputDebugStringA (sink_pipe_start, below the Win32 declarations). Only when
   that pipe cannot be made is rt_debug_sink set: the runtime's own writes (Console, the leak
   report, fatal errors) then call OutputDebugStringA directly, C functions such as puts are lost. */
static int rt_debug_sink;

#ifdef _WIN32
static int sink_pipe_start(void);
static void sink_pipe_finish(void);

static void sink_write(const char* p, size_t n)
{
    char buf[512];
    while (n > 0) {
        size_t k = n < sizeof buf - 1 ? n : sizeof buf - 1;
        memcpy(buf, p, k);
        buf[k] = 0;
        OutputDebugStringA(buf);
        p += k;
        n -= k;
    }
}
#endif

/* stderr, or the debugger sink of a windowed program without one. */
static void err_write(const char* p, size_t n)
{
#ifdef _WIN32
    if (rt_debug_sink) { sink_write(p, n); return; }
#endif
    fwrite(p, 1, n, stderr);
}

__attribute__((unused, format(printf, 1, 2))) static void err_printf(const char* fmt, ...)
{
    char buf[1024];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    err_write(buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
}

uint32_t rt_fnv1a(const char* s)
{
    uint32_t h = 2166136261u;
    for (; *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
    return h;
}

static const char* site_where(const rt_site* s) { return (s && s->where) ? s->where : "?"; }
static const char* site_node(const rt_site* s) { return (s && s->node) ? s->node : "?"; }

static const char* type_name_of(void* obj)
{
    void* const* vt;
    const rt_type_info* ti;
    if (!obj) return "null";
    vt = ((rt_object*)obj)->vtable;
    if (!vt) return "?";
    ti = (const rt_type_info*)vt[0];
    return (ti && ti->name) ? ti->name : "?";
}

static void write_crash_file(const char* text)
{
#ifdef _WIN32
    char path[MAX_PATH + 16];
    rt_dword n = GetModuleFileNameA(NULL, path, MAX_PATH);
    FILE* f;
    if (n == 0 || n >= MAX_PATH) return;
    strcpy(path + n, ".fatal.txt");
    f = fopen(path, "w");
    if (!f) return;
    fputs(text, f);
    fputc('\n', f);
    fclose(f);
#else
    char path[4096 + 16];
    ssize_t n = readlink("/proc/self/exe", path, 4096);
    FILE* f;
    if (n <= 0 || n >= 4096) return;
    strcpy(path + n, ".fatal.txt");
    f = fopen(path, "w");
    if (!f) return;
    fputs(text, f);
    fputc('\n', f);
    fclose(f);
#endif
}

#if !defined(_WIN32) && defined(TREADLE_DEBUG)
/* A debugger is attached when /proc/self/status names a tracer. */
static int being_traced(void)
{
    char buf[4096];
    FILE* f = fopen("/proc/self/status", "r");
    int traced = 0;
    if (!f) return 0;
    while (fgets(buf, sizeof buf, f))
        if (strncmp(buf, "TracerPid:", 10) == 0) { traced = atoi(buf + 10) != 0; break; }
    fclose(f);
    return traced;
}
#endif

/* ---- threads: what the runtime needs before the threads block itself (at the end, docs/Threads.md) */
static _Thread_local uint32_t rt_cur_index;           /* this thread's runtime index: 0 is the main thread */
static volatile int32_t rt_threads_used;              /* set before the first Treadle thread starts */
static const char* rt_thread_index_name(uint32_t index);
static void rt_fatal_gate(void);
static void rt_threads_at_exit(void);
static void rt_debug_name_thread(uint32_t index);   /* the debugger's table of thread names (at the end) */

static void fatal_text(const char* text)
{
    rt_fatal_gate();                                  /* one thread reports; another one waits for the exit */
    fflush(stdout);
    err_write(text, strlen(text));
    err_write("\n", 1);
#ifdef TREADLE_DEBUG
    rt_leak_report();
#endif
    fflush(stderr);
    write_crash_file(text);
#if defined(_WIN32) && defined(TREADLE_DEBUG)
    if (IsDebuggerPresent()) __builtin_debugtrap();
#elif defined(TREADLE_DEBUG)
    if (being_traced()) __builtin_debugtrap();
#endif
    exit(3);
}

void rt_fatal(int32_t code, const rt_site* site, const char* msg)
{
    char buf[1024];
    int n;
    (void)code;
    if (site)
        n = snprintf(buf, sizeof buf, "fatal: %s at %s node %s", msg ? msg : "fatal error", site_where(site), site_node(site));
    else
        n = snprintf(buf, sizeof buf, "fatal: %s", msg ? msg : "fatal error");
    /* on a thread other than the main one, which thread (docs/Threads.md 6) */
    if (rt_cur_index != 0 && n > 0 && (size_t)n < sizeof buf)
        snprintf(buf + n, sizeof buf - (size_t)n, " on thread \"%s\"", rt_thread_index_name(rt_cur_index));
    fatal_text(buf);
}

void rt_null(const rt_site* site) { rt_fatal(1, site, "null reference"); }

void rt_bounds(const rt_site* site, int64_t index, int64_t length)
{
    char msg[160];
    snprintf(msg, sizeof msg, "index %lld out of range (length %lld)", (long long)index, (long long)length);
    rt_fatal(2, site, msg);
}

void rt_span_range(const rt_site* site, int64_t start, int64_t count, int64_t length)
{
    char msg[160];
    snprintf(msg, sizeof msg, "span of %lld from %lld out of range (length %lld)", (long long)count, (long long)start, (long long)length);
    rt_fatal(2, site, msg);
}

void rt_freed(const rt_site* site) { rt_fatal(4, site, "use of a deleted object"); }

void rt_abstract_call(void) { rt_fatal(5, NULL, "call of an abstract function"); }

static void rt_use_after_free(void) { rt_fatal(4, NULL, "virtual call on a deleted object"); }

/* A freed object's vtable: its TypeInfo, then 1 + 256 slots that all trap (filled by rt_start). */
static const rt_type_info rt_poison_type = { 0, 0, 0, 1, "<deleted object>", NULL, 0, 0, NULL, NULL };
void* rt_poison_vtable[2 + 256];

/* ================================================================== allocation */

static void* plain_alloc(int64_t size, int64_t align)
{
    void* p;
    /* A negative size is an array length below zero, or one whose size in bytes wrapped past 64 bits
       (alloc.array computes length * element size + header): never a 1-byte block the stores after it
       would overrun. */
    if (size < 0) rt_fatal(11, NULL, "allocation of a negative size (an array length below zero, or too large)");
    if (size == 0) size = 1;
    if (align > 16) {
#ifdef _WIN32
        p = _aligned_malloc((size_t)size, (size_t)align);
#else
        if (posix_memalign(&p, (size_t)align, (size_t)size) != 0) p = NULL;
#endif
        if (p) memset(p, 0, (size_t)size);
    } else
        p = calloc(1, (size_t)size);
    if (!p) { fputs("fatal: out of memory\n", stderr); exit(3); }
    return p;
}

#ifdef TREADLE_DEBUG

#define RT_MAGIC_LIVE 0x4B45534C49564531ull /* "KESLIVE1" */
#define RT_MAGIC_FREE 0x4B45534652454531ull /* "KESFREE1" */
#define RT_QUARANTINE_COUNT 4096
#define RT_QUARANTINE_BYTES (4u << 20)

typedef struct rt_dbg_header {
    uint64_t magic;
    const rt_site* alloc_site;
    const rt_site* free_site;                     /* live: the runtime index of the thread that made it */
    uint64_t size;
    struct rt_dbg_header* prev;
    struct rt_dbg_header* next;
} rt_dbg_header;                                  /* 48 bytes: objects stay 16-aligned */

/* While a block is live its free_site holds the runtime index of the thread that made it (0: the main thread;
   written only once a second thread ran), so the hot path has no extra field or mask. */
#define RT_HSIZE(h) ((h)->size)
#define RT_HTHREAD(h) ((uint32_t)(uintptr_t)(h)->free_site)

/* ---- per-thread lists (docs/Threads.md 5): each thread links the blocks it makes into its own live list, with
   its own counters and its own quarantine ring, and changes them without a lock or any atomic instruction (a
   program with one thread pays a flag test, as before threads). The cross-thread paths take a small spin lock
   (an atomic exchange; pause, then a yield after 64 tries):
     * a Delete of a block another thread made poisons it and marks it freed, and counts it on its maker's list;
       the maker unlinks such blocks itself (a sweep when they add up to 64 plus an eighth of its live blocks)
       and quarantines them in its ring;
     * a thread that ends moves its live blocks to the list of ended threads (the orphan list, under the lock),
       and its ring with them, so a later Delete or the leak report still finds them;
     * the leak report freezes the lists: it takes the lock, raises rt_alloc_frozen and waits until no thread is
       inside a change of its list (its busy flag), so it walks lists that stand still.
   The live lists, counters and rings are only ever changed by their owner or under the lock. */
static volatile int32_t rt_alloc_lock_word;
static volatile int32_t rt_alloc_frozen;                 /* the leak report walks the lists: wait */

static void rt_spin_yield(void);
void rt_sleep(int64_t ms);

/* Taken when the exchange finds the lock held: spin, then yield. */
static void rt_alloc_lock_wait(void)
{
    int tries = 0;
    do {
        do {
            if (++tries > 64) rt_spin_yield();
            else __builtin_ia32_pause();
        } while (__atomic_load_n(&rt_alloc_lock_word, __ATOMIC_RELAXED));
    } while (__atomic_exchange_n(&rt_alloc_lock_word, 1, __ATOMIC_ACQUIRE));
}

#define RT_ALLOC_LOCK() \
    do { if (__atomic_exchange_n(&rt_alloc_lock_word, 1, __ATOMIC_ACQUIRE)) rt_alloc_lock_wait(); } while (0)
#define RT_ALLOC_UNLOCK() __atomic_store_n(&rt_alloc_lock_word, 0, __ATOMIC_RELEASE)

typedef struct rt_ring {
    rt_dbg_header** slot;
    uint32_t count, pos;
    uint64_t bytes, cap;                              /* bytes held, the most it holds */
} rt_ring;

typedef struct rt_dbg_list {
    rt_dbg_header* head;
    int64_t live, total, bytes, peak;                 /* its linked blocks (a block another thread deleted counts until the sweep) */
    volatile int64_t remote_n;                        /* its blocks other threads deleted (written under the lock) */
    int64_t swept_n;                                  /* of those, unlinked by the owner */
    volatile int32_t sweep_due;                       /* set by a deleting thread when enough wait: the owner sweeps */
    volatile int32_t busy;                            /* 1 while the owner changes the list */
    uint32_t index;                                   /* the runtime index of the owner */
    rt_ring ring;
} rt_dbg_list;

#define RT_WORKER_QUARANTINE_COUNT 1024
#define RT_WORKER_QUARANTINE_BYTES (1u << 20)

static rt_dbg_header* rt_main_slots[RT_QUARANTINE_COUNT];
static rt_dbg_list rt_main_list = { .index = 0, .ring = { rt_main_slots, RT_QUARANTINE_COUNT, 0, 0, RT_QUARANTINE_BYTES } };
static rt_dbg_header* rt_orphan_slots[RT_QUARANTINE_COUNT];
static rt_dbg_list rt_orphan_list = { .index = 0xFFFFFFFFu, .ring = { rt_orphan_slots, RT_QUARANTINE_COUNT, 0, 0, RT_QUARANTINE_BYTES } };
static _Thread_local rt_dbg_list* rt_cur_list;        /* this thread's list (set when it starts; main in rt_start) */
static rt_dbg_list** rt_lists;                        /* by runtime index: the running threads' lists (under the lock) */
static uint32_t rt_lists_cap;
static int64_t rt_ended_total, rt_ended_peak;         /* the counters of the lists of ended threads */

static void quarantine(rt_ring* r, rt_dbg_header* h)
{
    /* Evict the oldest blocks until the new one fits (by count and by bytes). */
    uint32_t pos = r->pos;
    uint64_t size = RT_HSIZE(h);
    while (r->slot[pos] || r->bytes + size > r->cap) {
        rt_dbg_header* old = r->slot[pos];
        if (old) {
            r->bytes -= RT_HSIZE(old);
            free(old);
            r->slot[pos] = NULL;
        }
        if (!r->slot[pos] && r->bytes + size <= r->cap) break;
        pos = (pos + 1) % r->count;
        if (pos == r->pos) break;                     /* the block alone is larger than the ring */
    }
    if (r->bytes + size > r->cap) { free(h); return; }
    r->slot[pos] = h;
    r->bytes += size;
    r->pos = (pos + 1) % r->count;
}

/* quarantine of the main list's ring with its fields named directly (no pointer to follow at -O0: the one-thread
   path costs what it did before threads) */
static void quarantine_main(rt_dbg_header* h)
{
    uint32_t pos = rt_main_list.ring.pos;
    uint64_t size = RT_HSIZE(h);
    while (rt_main_slots[pos] || rt_main_list.ring.bytes + size > RT_QUARANTINE_BYTES) {
        rt_dbg_header* old = rt_main_slots[pos];
        if (old) {
            rt_main_list.ring.bytes -= RT_HSIZE(old);
            free(old);
            rt_main_slots[pos] = NULL;
        }
        if (!rt_main_slots[pos] && rt_main_list.ring.bytes + size <= RT_QUARANTINE_BYTES) break;
        pos = (pos + 1) % RT_QUARANTINE_COUNT;
        if (pos == rt_main_list.ring.pos) break;
    }
    if (rt_main_list.ring.bytes + size > RT_QUARANTINE_BYTES) { free(h); return; }
    rt_main_slots[pos] = h;
    rt_main_list.ring.bytes += size;
    rt_main_list.ring.pos = (pos + 1) % RT_QUARANTINE_COUNT;
}

/* The owner changes its list: its busy flag is set meanwhile (plain stores; a raised freeze flag waits first).
   Macros, not functions: the Debug runtime is compiled at -O0, where a call per alloc and free was measurable. */
static void rt_frozen_wait(rt_dbg_list* L)
{
    L->busy = 0;                                      /* the report may walk it */
    while (__atomic_load_n(&rt_alloc_frozen, __ATOMIC_ACQUIRE)) rt_sleep(1);
    L->busy = 1;
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
}
#define RT_LIST_ENTER(L) \
    do { (L)->busy = 1; __atomic_signal_fence(__ATOMIC_SEQ_CST); if (rt_alloc_frozen) rt_frozen_wait(L); } while (0)
#define RT_LIST_LEAVE(L) \
    do { __atomic_signal_fence(__ATOMIC_SEQ_CST); (L)->busy = 0; } while (0)

static void rt_list_register(rt_dbg_list* L)        /* under the lock */
{
    uint32_t need = L->index + 1;
    if (need > rt_lists_cap) {
        uint32_t cap = rt_lists_cap ? rt_lists_cap : 16;
        rt_dbg_list** n;
        while (cap < need) cap *= 2;
        n = (rt_dbg_list**)realloc(rt_lists, sizeof(rt_dbg_list*) * cap);
        if (!n) { RT_ALLOC_UNLOCK(); fputs("fatal: out of memory\n", stderr); exit(3); }
        memset(n + rt_lists_cap, 0, sizeof(rt_dbg_list*) * (cap - rt_lists_cap));
        rt_lists = n;
        rt_lists_cap = cap;
    }
    if (!rt_lists[0]) rt_lists[0] = &rt_main_list;
    rt_lists[L->index] = L;
}

/* A thread that starts (rt_thread_run), or a thread the runtime did not start that allocates once threads run
   (a C host calling a library's exports): its own list. */
static rt_dbg_list* rt_dbg_thread_begin(uint32_t index)
{
    rt_dbg_list* L = (rt_dbg_list*)calloc(1, sizeof(rt_dbg_list));
    rt_dbg_header** slots = (rt_dbg_header**)calloc(RT_WORKER_QUARANTINE_COUNT, sizeof(rt_dbg_header*));
    if (!L || !slots) { fputs("fatal: out of memory\n", stderr); exit(3); }
    L->index = index;
    L->ring.slot = slots;
    L->ring.count = RT_WORKER_QUARANTINE_COUNT;
    L->ring.cap = RT_WORKER_QUARANTINE_BYTES;
    RT_ALLOC_LOCK();
    rt_list_register(L);
    RT_ALLOC_UNLOCK();
    rt_cur_list = L;
    return L;
}

static uint32_t rt_name_new(const char* name, int64_t len, const char* prefix);
static rt_dbg_list* rt_dbg_adopt(void)
{
    uint32_t index = rt_name_new(NULL, 0, "Thread");
    rt_cur_index = index;
    return rt_dbg_thread_begin(index);
}

/* The owner unlinks the blocks of its list that other threads deleted, into its ring. */
static void rt_sweep(rt_dbg_list* L)
{
    rt_dbg_header* h = L->head;
    while (h) {
        rt_dbg_header* next = h->next;
        if (__atomic_load_n(&h->magic, __ATOMIC_ACQUIRE) == RT_MAGIC_FREE) {
            if (h->prev) h->prev->next = h->next; else L->head = h->next;
            if (h->next) h->next->prev = h->prev;
            h->prev = h->next = NULL;
            L->live--;
            L->bytes -= (int64_t)RT_HSIZE(h);
            L->swept_n++;
            quarantine(&L->ring, h);
        }
        h = next;
    }
}

/* The thread ends: its blocks still live go to the orphan list, the ones another thread deleted and its ring to
   the orphan ring (a later Delete of them is still caught as a double free). */
static void rt_dbg_thread_end(void)
{
    rt_dbg_list* L = rt_cur_list;
    rt_dbg_header* h;
    uint32_t k;
    if (!L || L == &rt_main_list) return;
    RT_ALLOC_LOCK();
    h = L->head;
    while (h) {
        rt_dbg_header* next = h->next;
        h->prev = h->next = NULL;
        if (h->magic == RT_MAGIC_FREE)
            quarantine(&rt_orphan_list.ring, h);
        else {
            h->next = rt_orphan_list.head;
            if (rt_orphan_list.head) rt_orphan_list.head->prev = h;
            rt_orphan_list.head = h;
            rt_orphan_list.live++;
            rt_orphan_list.bytes += (int64_t)RT_HSIZE(h);
        }
        h = next;
    }
    for (k = 0; k < L->ring.count; k++) {
        uint32_t at = (L->ring.pos + k) % L->ring.count;    /* oldest first */
        if (L->ring.slot[at]) quarantine(&rt_orphan_list.ring, L->ring.slot[at]);
    }
    rt_ended_total += L->total;
    rt_ended_peak += L->peak;
    if (L->index < rt_lists_cap) rt_lists[L->index] = NULL;
    RT_ALLOC_UNLOCK();
    rt_cur_list = NULL;
    free(L->ring.slot);
    free(L);
}

/* The main thread keeps the one-thread path after threads start: no thread-local read, no busy flag (its list is
   walked by a report on the main thread; a report another thread makes, a fatal error there, leaves it out). Which
   thread runs is one read of the thread block: the thread id in the TEB (Windows), the TCB's self pointer (Linux). */
static uintptr_t rt_main_tid;
static inline uintptr_t rt_thread_word(void)
{
    uintptr_t v;
#ifdef _WIN32
    __asm__ volatile("movq %%gs:0x48, %0" : "=r"(v));
#else
    __asm__ volatile("movq %%fs:0x10, %0" : "=r"(v));
#endif
    return v;
}
#define RT_ON_MAIN() (rt_thread_word() == rt_main_tid)

void* rt_alloc_dbg(int64_t size, int64_t align, const rt_site* site)
{
    rt_dbg_header* h;
    rt_dbg_list* L;
    if (size < 0) rt_fatal(11, site, "allocation of a negative size (an array length below zero, or too large)");
    if (size == 0) size = 1;
    if (size > INT64_MAX - (int64_t)sizeof(rt_dbg_header)) { fputs("fatal: out of memory\n", stderr); exit(3); }
    (void)align;                                     /* the header keeps 16-byte alignment */
    h = (rt_dbg_header*)plain_alloc((int64_t)sizeof(rt_dbg_header) + size, 16);
    h->magic = RT_MAGIC_LIVE;
    h->alloc_site = site;
    h->size = (uint64_t)size;
    if (!rt_threads_used || RT_ON_MAIN()) {        /* one thread, or the main thread: the main list, no thread-local read */
        h->next = rt_main_list.head;
        if (rt_main_list.head) rt_main_list.head->prev = h;
        rt_main_list.head = h;
        rt_main_list.live++; rt_main_list.total++; rt_main_list.bytes += size;
        if (rt_main_list.bytes > rt_main_list.peak) rt_main_list.peak = rt_main_list.bytes;
        if (rt_main_list.sweep_due) { rt_main_list.sweep_due = 0; rt_sweep(&rt_main_list); }
        return h + 1;
    }
    L = rt_cur_list;
    if (!L) L = rt_dbg_adopt();
    h->free_site = (const rt_site*)(uintptr_t)L->index; /* the thread that made it (main: 0) */
    RT_LIST_ENTER(L);
    h->next = L->head;
    if (L->head) L->head->prev = h;
    L->head = h;
    L->live++; L->total++; L->bytes += size;
    if (L->bytes > L->peak) L->peak = L->bytes;
    if (L->sweep_due) { L->sweep_due = 0; rt_sweep(L); }
    RT_LIST_LEAVE(L);
    return h + 1;
}

/* poison: the vtable traps, the fields read as 0xDD (a macro: no call at -O0) */
#define RT_POISON(p, size) \
    do { \
        if ((size) >= sizeof(void*)) { \
            ((rt_object*)(p))->vtable = (void* const*)rt_poison_vtable; \
            memset((char*)(p) + sizeof(void*), 0xDD, (size_t)(size) - sizeof(void*)); \
        } else \
            memset((p), 0xDD, (size_t)(size)); \
    } while (0)

static void rt_double_free(rt_dbg_header* h, const rt_site* site)
{
    char msg[512];
    snprintf(msg, sizeof msg, "double free of an object made at %s node %s (first deleted at %s node %s)",
             site_where(h->alloc_site), site_node(h->alloc_site), site_where(h->free_site), site_node(h->free_site));
    rt_fatal(6, site, msg);
}

/* A Delete of a block another thread made (or that the orphan list holds): under the lock. */
static void rt_free_remote(rt_dbg_header* h, const rt_site* site)
{
    rt_dbg_list* owner;
    uint32_t index;
    uint64_t size;
    RT_ALLOC_LOCK();
    if (h->magic == RT_MAGIC_FREE) { RT_ALLOC_UNLOCK(); rt_double_free(h, site); }
    if (h->magic != RT_MAGIC_LIVE) {
        RT_ALLOC_UNLOCK();
        rt_fatal(7, site, "delete of an object that was not made by Construct (a Local, an appended object or a foreign pointer)");
    }
    index = RT_HTHREAD(h);
    owner = (index < rt_lists_cap) ? rt_lists[index] : (index == 0 ? &rt_main_list : NULL);
    size = RT_HSIZE(h);
    RT_POISON(h + 1, size);
    if (!owner) {                                    /* its thread ended: the orphan list */
        if (h->prev) h->prev->next = h->next; else rt_orphan_list.head = h->next;
        if (h->next) h->next->prev = h->prev;
        h->prev = h->next = NULL;
        h->magic = RT_MAGIC_FREE;
        h->free_site = site;
        rt_orphan_list.live--;
        rt_orphan_list.bytes -= (int64_t)size;
        quarantine(&rt_orphan_list.ring, h);
    } else {                                         /* still linked in its maker's list until the maker sweeps */
        h->free_site = site;
        __atomic_store_n(&h->magic, RT_MAGIC_FREE, __ATOMIC_RELEASE);
        __atomic_store_n(&owner->remote_n, owner->remote_n + 1, __ATOMIC_RELAXED);
        if (owner->remote_n - owner->swept_n >= 64 + (owner->live >> 3))   /* a heuristic: the owner's counts are read unlocked */
            __atomic_store_n(&owner->sweep_due, 1, __ATOMIC_RELAXED);
    }
    RT_ALLOC_UNLOCK();
}

void rt_free_dbg(void* p, const rt_site* site)
{
    rt_dbg_header* h;
    rt_dbg_list* L;
    uint64_t size;
    if (!p) return;
    h = ((rt_dbg_header*)p) - 1;
    if (h->magic == RT_MAGIC_FREE) rt_double_free(h, site);
    if (h->magic != RT_MAGIC_LIVE)
        rt_fatal(7, site, "delete of an object that was not made by Construct (a Local, an appended object or a foreign pointer)");
    size = RT_HSIZE(h);
    if (!rt_threads_used || (RT_HTHREAD(h) == 0 && RT_ON_MAIN())) { /* one thread, or main deletes its own: the main list */
        if (h->prev) h->prev->next = h->next; else rt_main_list.head = h->next;
        if (h->next) h->next->prev = h->prev;
        h->prev = h->next = NULL;
        h->magic = RT_MAGIC_FREE;
        h->free_site = site;
        rt_main_list.live--; rt_main_list.bytes -= (int64_t)size;
        RT_POISON(p, size);
        quarantine_main(h);
        return;
    }
    L = rt_cur_list;
    if (!L) L = rt_dbg_adopt();
    if (RT_HTHREAD(h) != L->index) {
        rt_free_remote(h, site);
        return;
    }
    RT_LIST_ENTER(L);
    if (h->prev) h->prev->next = h->next; else L->head = h->next;
    if (h->next) h->next->prev = h->prev;
    h->prev = h->next = NULL;
    h->magic = RT_MAGIC_FREE;
    h->free_site = site;
    L->live--; L->bytes -= (int64_t)size;
    RT_POISON(p, size);
    if (L == &rt_main_list) quarantine_main(h); else quarantine(&L->ring, h);
    RT_LIST_LEAVE(L);
}

static int64_t rt_report_list(rt_dbg_list* L, int64_t* live, int64_t* bytes)
{
    rt_dbg_header* h;
    int64_t n = 0;
    for (h = L->head; h; h = h->next) {
        void* obj = h + 1;
        const char* name;
        if (h->magic != RT_MAGIC_LIVE) continue;     /* deleted by another thread, not swept yet */
        name = (RT_HSIZE(h) >= sizeof(void*)) ? type_name_of(obj) : "block";
        if (RT_HTHREAD(h))
            err_printf("leak: %s (%llu bytes) made at %s node %s on thread \"%s\"\n", name, (unsigned long long)RT_HSIZE(h),
                    site_where(h->alloc_site), site_node(h->alloc_site), rt_thread_index_name(RT_HTHREAD(h)));
        else
            err_printf("leak: %s (%llu bytes) made at %s node %s\n", name, (unsigned long long)RT_HSIZE(h),
                    site_where(h->alloc_site), site_node(h->alloc_site));
        n++;
        (*live)++;
        *bytes += (int64_t)RT_HSIZE(h);
    }
    return n;
}

int32_t rt_leak_report(void)
{
    int64_t n = 0, live = 0, bytes = 0, total, peak;
    uint32_t k;
    int threads = rt_threads_used != 0;
    fflush(stdout);
    if (threads) {
        RT_ALLOC_LOCK();
        /* freeze: once the flag is seen (the sleep lets every thread's stores reach memory), a thread inside a
           change of its list finishes it and the next one waits */
        __atomic_store_n(&rt_alloc_frozen, 1, __ATOMIC_SEQ_CST);
        rt_sleep(2);
        for (k = 0; k < rt_lists_cap; k++)
            if (rt_lists[k] && rt_lists[k] != rt_cur_list)
                while (__atomic_load_n(&rt_lists[k]->busy, __ATOMIC_ACQUIRE)) rt_sleep(1);
    }
    total = rt_main_list.total + rt_ended_total;
    peak = rt_main_list.peak + rt_ended_peak;
    /* the main thread changes its list without the busy flag: only a report on the main thread (or before a second
       thread ran) walks it */
    if (!threads || RT_ON_MAIN())
        n += rt_report_list(&rt_main_list, &live, &bytes);
    else if (rt_main_list.live > 0)
        err_printf("treadle_rt: the main thread's objects are not listed (the report ran on thread \"%s\")\n", rt_thread_index_name(rt_cur_index));
    if (threads) {
        for (k = 1; k < rt_lists_cap; k++)
            if (rt_lists[k]) {
                n += rt_report_list(rt_lists[k], &live, &bytes);
                total += rt_lists[k]->total;
                peak += rt_lists[k]->peak;
            }
        n += rt_report_list(&rt_orphan_list, &live, &bytes);
    }
    if (n || getenv("TREADLE_RT_VERBOSE"))
        err_printf("treadle_rt: allocs=%lld live=%lld bytes_live=%lld bytes_peak=%lld\n",
                (long long)total, (long long)live, (long long)bytes, (long long)peak);
    if (threads) {
        __atomic_store_n(&rt_alloc_frozen, 0, __ATOMIC_SEQ_CST);
        RT_ALLOC_UNLOCK();
    }
    fflush(stderr);
    return n > 0x7fff ? 0x7fff : (int32_t)n;
}

/* The release entry points stay linkable in Debug (same tracking, no site). */
void* rt_alloc(int64_t size, int64_t align) { return rt_alloc_dbg(size, align, NULL); }
void rt_free(void* p) { rt_free_dbg(p, NULL); }

#else /* Release */

/* Release keeps no bookkeeping: rt_alloc is calloc (16-byte aligned, as in Debug, which ignores a larger
   alignment too) and rt_free is free. A header with a magic word checked on Delete was measured and not
   taken (Toolchain.md, "Release fatal errors": about 5% on a Construct / Delete loop, over the 2%
   budget). What costs nothing is done instead: the faults the C heap and the processor already detect
   end the program the Treadle way (rt_start installs the handlers, "fault handlers" below). */
void* rt_alloc(int64_t size, int64_t align) { (void)align; return plain_alloc(size, 16); }
void rt_free(void* p) { free(p); }
void* rt_alloc_dbg(int64_t size, int64_t align, const rt_site* site) { (void)site; (void)align; return plain_alloc(size, 16); }
void rt_free_dbg(void* p, const rt_site* site) { (void)site; free(p); }
int32_t rt_leak_report(void) { return 0; }

#endif

/* Custom allocators: an object implementing Core.IAllocator { Alloc(int size, int align) -> void*; Free(void*) }. */
typedef void* (*rt_alloc_slot)(void* self, int64_t size, int64_t align);
typedef void (*rt_free_slot)(void* self, void* p);

void* rt_alloc_with(void* allocator, int64_t size, int64_t align)
{
    void* const* it = rt_itable(allocator, rt_fnv1a("N4Core10IAllocatorE"));
    void* p = ((rt_alloc_slot)it[0])(allocator, size, align);
    if (p) memset(p, 0, (size_t)size);
    return p;
}

void rt_free_with(void* allocator, void* p)
{
    void* const* it;
    if (!p) return;
    it = rt_itable(allocator, rt_fnv1a("N4Core10IAllocatorE"));
    ((rt_free_slot)it[1])(allocator, p);
}

/* ================================================================== dispatch */

void* const* rt_itable(void* obj, uint32_t iface_id)
{
    const rt_type_info* ti;
    uint32_t i;
    char msg[256];
    if (!obj) rt_fatal(1, NULL, "interface call on null");
    ti = (const rt_type_info*)((rt_object*)obj)->vtable[0];
    if (ti == &rt_poison_type) rt_fatal(4, NULL, "interface call on a deleted object");
    for (; ti; ti = ti->base)
        for (i = 0; i < ti->iface_count; i++)
            if (ti->ifaces[i].iface_id == iface_id)
                return ti->ifaces[i].itable;
    snprintf(msg, sizeof msg, "%s does not implement interface %08x", type_name_of(obj), iface_id);
    rt_fatal(8, NULL, msg);
    return NULL;
}

void* rt_dyncast(void* obj, const rt_type_info* target)
{
    const rt_type_info* ti;
    uint32_t i;
    if (!obj || !target) return NULL;
    ti = (const rt_type_info*)((rt_object*)obj)->vtable[0];
    for (; ti; ti = ti->base) {
        if (ti == target || ti->type_id == target->type_id) return obj;
        if (target->flags & RT_TI_INTERFACE)
            for (i = 0; i < ti->iface_count; i++)
                if (ti->ifaces[i].iface_id == target->type_id) return obj;
    }
    return NULL;
}

/* ================================================================== start / exit */

/* Linker-collected tables: a pointer to every TypeInfo, and to every static constructor.
   Windows: COFF grouped sections, merged in the order of the part after '$' (.tti$m between the
   .tti$a and .tti$z markers here; .tsct$m likewise). Linux: ELF sections named treadle_ti and
   treadle_sct, bounded by the linker's __start_ / __stop_ symbols (weak: a program without
   entries has no section, and both are null). TI_FIRST / TI_END and SCT_FIRST / SCT_END are the
   first entry and one past the last. */
#ifdef _WIN32
__attribute__((section(".tti$a"), used)) static const rt_type_info* const ti_begin = NULL;
__attribute__((section(".tti$z"), used)) static const rt_type_info* const ti_end = NULL;
__attribute__((section(".tsct$a"), used)) static void (* const sct_begin)(void) = NULL;
__attribute__((section(".tsct$z"), used)) static void (* const sct_end)(void) = NULL;
#define TI_FIRST (&ti_begin + 1)
#define TI_END (&ti_end)
#define SCT_FIRST (&sct_begin + 1)
#define SCT_END (&sct_end)
#else
extern const rt_type_info* const __start_treadle_ti[] __attribute__((weak));
extern const rt_type_info* const __stop_treadle_ti[] __attribute__((weak));
extern void (* const __start_treadle_sct[])(void) __attribute__((weak));
extern void (* const __stop_treadle_sct[])(void) __attribute__((weak));
#define TI_FIRST (__start_treadle_ti)
#define TI_END (__stop_treadle_ti)
#define SCT_FIRST (__start_treadle_sct)
#define SCT_END (__stop_treadle_sct)
#endif

static void check_type_ids(void)
{
#if defined(TREADLE_DEBUG)
    const rt_type_info* const* a;
    const rt_type_info* const* b;
    for (a = TI_FIRST; a < TI_END; a++) {
        if (!*a) continue;
        for (b = a + 1; b < TI_END; b++)
            if (*b && *b != *a && (*b)->type_id == (*a)->type_id && strcmp((*a)->name, (*b)->name) != 0) {
                char msg[512];
                snprintf(msg, sizeof msg, "type id collision between %s and %s (%08x): rename one", (*a)->name, (*b)->name, (*a)->type_id);
                rt_fatal(9, NULL, msg);
            }
    }
#endif
}

#ifdef _WIN32
/* The arguments as UTF-8, from the wide command line (argv of a mingw main is in the ANSI code page). */
static void utf8_args(void)
{
    int n = 0, i;
    rt_wchar** w = CommandLineToArgvW(GetCommandLineW(), &n);
    char** a;
    if (!w || n <= 0) return;
    a = (char**)calloc((size_t)n + 1, sizeof(char*));
    if (!a) { LocalFree(w); return; }
    for (i = 0; i < n; i++) {
        int len = WideCharToMultiByte(CP_UTF8, 0, w[i], -1, NULL, 0, NULL, NULL);
        a[i] = (char*)malloc(len > 0 ? (size_t)len : 1);
        if (!a[i]) { a[i] = ""; continue; }
        if (len <= 0) a[i][0] = 0;
        else WideCharToMultiByte(CP_UTF8, 0, w[i], -1, a[i], len, NULL, NULL);
    }
    LocalFree(w);
    rt_argc = n;
    rt_argv = a;
}
#endif

/* ================================================================== fault handlers (Release) */

/* Release has no checks of its own, but what the C heap and the processor already detect costs nothing
   to report: a double free the heap notices (Windows: STATUS_HEAP_CORRUPTION; glibc: its "double free
   detected" abort), and an access through a dangling or null reference that faults. Each ends the
   program as rt_fatal does: stdout flushed, "fatal: ..." on stderr, exit code 3 (no node: Release
   keeps no sites; the Debug build of the same program names it). No <exe>.fatal.txt: the heap may be
   damaged, so nothing is allocated on the way out. */
#ifndef TREADLE_DEBUG
static const char rt_msg_access[] = "fatal: invalid memory access (a deleted or null object; a Release build has no checks; its Debug build names the node)\n";
#ifdef _WIN32
static const char rt_msg_heap[] = "fatal: the C heap found a double free or a damaged block (a Release build has no checks; its Debug build names the Delete node)\n";
#else
static const char rt_msg_abort[] = "fatal: the program was aborted (the C heap found a double free or a damaged block, or a C function called abort; a Release build has no checks; its Debug build names the Delete node)\n";
#endif

static void fault_exit(const char* text, size_t n)
{
    fflush(stdout);
#ifdef _WIN32
    err_write(text, n);
    fflush(stderr);
    sink_pipe_finish();
    TerminateProcess(GetCurrentProcess(), 3);
#else
    if (write(2, text, n) < 0) { /* nothing more to do */ }
#endif
    _exit(3);
}

#ifdef _WIN32
#define RT_STATUS_HEAP_CORRUPTION 0xC0000374ul
#define RT_STATUS_ACCESS_VIOLATION 0xC0000005ul
/* `info` is an EXCEPTION_POINTERS*: its first member points at the EXCEPTION_RECORD, whose first member
   is the code. The heap's report comes first (vectored); an access violation only when nothing in the
   program handles it (the unhandled filter, so SEH a C library uses on purpose still works). */
static long __stdcall rt_vectored(void* info)
{
    if (**(rt_dword**)info == RT_STATUS_HEAP_CORRUPTION)
        fault_exit(rt_msg_heap, sizeof rt_msg_heap - 1);
    return 0;                                        /* EXCEPTION_CONTINUE_SEARCH */
}

static long __stdcall rt_unhandled(void* info)
{
    rt_dword code = **(rt_dword**)info;
    if (code == RT_STATUS_ACCESS_VIOLATION)
        fault_exit(rt_msg_access, sizeof rt_msg_access - 1);
    if (code == RT_STATUS_HEAP_CORRUPTION)
        fault_exit(rt_msg_heap, sizeof rt_msg_heap - 1);
    return 0;                                        /* EXCEPTION_CONTINUE_SEARCH: Windows' own report */
}
#else
static void rt_signal(int sig)
{
    if (sig == SIGABRT)
        fault_exit(rt_msg_abort, sizeof rt_msg_abort - 1);
    fault_exit(rt_msg_access, sizeof rt_msg_access - 1);
}
#endif

static void install_fault_handlers(void)
{
#ifdef _WIN32
    AddVectoredExceptionHandler(1, rt_vectored);
    SetUnhandledExceptionFilter(rt_unhandled);
#else
    signal(SIGABRT, rt_signal);
    signal(SIGSEGV, rt_signal);
    signal(SIGBUS, rt_signal);
#endif
}
#endif

/* The poison vtable, the type id check and the static constructors (rt_start, rt_lib_start). */
static void start_tables(void)
{
    int i;
    rt_poison_vtable[0] = (void*)&rt_poison_type;
    for (i = 1; i < 2 + 256; i++) rt_poison_vtable[i] = (void*)&rt_use_after_free;
    check_type_ids();
    {
        void (* const* f)(void);
        for (f = SCT_FIRST; f < SCT_END; f++)
            if (*f) (*f)();
    }
}

void rt_start(int32_t argc, char** argv)
{
    rt_argc = argc;
    rt_argv = argv;
    rt_flush_each = !rt_isatty(rt_fileno(stdout));
#ifdef _WIN32
    utf8_args();
    /* Under a debugger (F5: lldb-dap gives the program a pipe, which the C library would fill 4 KB at a
       time) the program's output is written at once, so what it wrote before a stop is in Debug Output. */
    if (IsDebuggerPresent()) setvbuf(stdout, NULL, _IONBF, 0);
#endif
#ifndef TREADLE_DEBUG
    install_fault_handlers();
#endif
#if !defined(_WIN32) && defined(TREADLE_DEBUG) && defined(PR_SET_PTRACER)
    /* A Debug program lets a debugger that is not its parent attach (Debug > Attach to Process: the
       editor starts lldb-dap, which attaches by pid). Yama's ptrace_scope 1, the default of Ubuntu and
       others, allows only ancestors otherwise; a Release program keeps the system's rule. */
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
#endif
#ifndef _WIN32
    /* Started by the editor (Run: its parent is the process TREADLE_RUN_PARENT names): die with it.
       Linux has no job objects, so a killed editor could not end its program otherwise; Stop kills the
       program's process group. Debug and Release alike; any other parent (a shell, lldb-server) is left
       alone. If the editor ended before the request, the parent is already another process: exit. */
    {
        const char* parent = getenv("TREADLE_RUN_PARENT");
        long want = parent ? strtol(parent, NULL, 10) : 0;
        if (want > 0 && (long)getppid() == want) {
            prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
            if ((long)getppid() != want) _exit(3);
        }
    }
#endif
#ifdef TREADLE_DEBUG
    rt_cur_list = &rt_main_list;                     /* the main thread's live list */
    rt_main_tid = rt_thread_word();
#endif
    rt_debug_name_thread(0);                         /* the main thread in the debugger's table */
    start_tables();
}

int32_t rt_exit(int32_t code)
{
    int32_t leaks;
    rt_threads_at_exit();                            /* the pool drains its work and ends (docs/Threads.md 1.1) */
    fflush(stdout);
    leaks = rt_leak_report();
    if (code == 0 && leaks > 0) code = leaks;
    fflush(stderr);
    return code;
}

/* kind windowed (Windows subsystem): main calls this before rt_start. A parent that gave the program
   a stdout (the editor's Run and a debugger capture it through a pipe, a shell redirection to a file)
   is used as it is; else the console of the parent (a command prompt) when there is one; else (started
   from Explorer, or by a program that gave it no handles) stdout and stderr, so Console output, C
   functions such as puts, the leak report and fatal errors, go to the debugger's output
   (OutputDebugStringA through sink_pipe_start; DebugView shows it without a debugger). Linux: nothing to
   do, a program has the streams it was started with. */
void rt_windowed(void)
{
#ifdef _WIN32
    void* out = GetStdHandle((rt_dword)-11);             /* STD_OUTPUT_HANDLE */
    if (out && out != (void*)(intptr_t)-1) return;
    if (AttachConsole((rt_dword)-1)) {                   /* ATTACH_PARENT_PROCESS */
        if (!freopen("CONOUT$", "w", stdout)) rt_debug_sink = 1;
        if (!freopen("CONOUT$", "w", stderr)) rt_debug_sink = 1;
        return;
    }
    if (!sink_pipe_start()) rt_debug_sink = 1;
#endif
}

/* kind library: treadle_init / treadle_shutdown, which the back end exports from the DLL / .so, call
   these. Start: the static constructors and the debug tables, once (nested pairs count); no fault
   handlers and no parent-death signal, which belong to the host process. Exit: at the last
   treadle_shutdown, the Debug leak report on stderr; returns the number of leaked objects (Debug; 0 in
   Release and for an inner shutdown). */
static int rt_lib_refs;

void rt_lib_start(void)
{
    if (rt_lib_refs++ > 0) return;
#ifdef _WIN32
    utf8_args();
#endif
#ifdef TREADLE_DEBUG
    rt_cur_list = &rt_main_list;                     /* the thread that calls treadle_init has the main list */
    rt_main_tid = rt_thread_word();
#endif
#if !defined(_WIN32) && defined(TREADLE_DEBUG) && defined(PR_SET_PTRACER)
    /* Debug > Attach to Process on the host (its lldb-dap is the editor's child, not the host's ancestor): as a
       Debug program does in rt_start, a Debug library lets a debugger that is not the host's parent attach */
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
#endif
    start_tables();
}

int32_t rt_lib_exit(void)
{
    if (rt_lib_refs <= 0 || --rt_lib_refs > 0) return 0;
    return rt_exit(0);
}

int32_t rt_arg_count(void) { return rt_argc; }
const char* rt_arg(int32_t i) { return (i >= 0 && i < rt_argc) ? rt_argv[i] : ""; }

/* args = the program's arguments after its own name, as a Core.String[]: { vtable, i64 length,
   String* elements }. Debug builds track the blocks like Construct does (site "Program Start"). */
#ifdef TREADLE_DEBUG
static const rt_site args_site = { "Program Start", "args" };
#endif

static void* args_alloc(int64_t size, int64_t align)
{
#ifdef TREADLE_DEBUG
    return rt_alloc_dbg(size, align, &args_site);
#else
    return rt_alloc(size, align);
#endif
}

static void args_release(void* p)
{
#ifdef TREADLE_DEBUG
    rt_free_dbg(p, &args_site);
#else
    rt_free(p);
#endif
}

void* rt_args_make(void* const* array_vtable, void* const* string_vtable, int64_t string_size,
                   int64_t string_align, rt_string_init_fn init)
{
    int64_t n = rt_argc > 1 ? rt_argc - 1 : 0, i;
    char* arr = (char*)args_alloc(16 + 8 * n, 8);
    ((rt_object*)arr)->vtable = array_vtable;
    *(int64_t*)(arr + 8) = n;
    for (i = 0; i < n; i++) {
        const char* s = rt_argv[i + 1];
        void* str = args_alloc(string_size, string_align);
        ((rt_object*)str)->vtable = string_vtable;
        init(str, s, (int64_t)strlen(s));
        ((void**)(arr + 16))[i] = str;
    }
    return arr;
}

void rt_args_free(void* args)
{
    int64_t n, i;
    if (!args) return;
    n = *(int64_t*)((char*)args + 8);
    for (i = 0; i < n; i++) {
        void* str = ((void**)((char*)args + 16))[i];
        if (!str) continue;
        ((rt_dtor_fn)((rt_object*)str)->vtable[1])(str);
        args_release(str);
    }
    args_release(args);
}

void rt_local_array_length(const rt_site* site, int64_t length)
{
    char msg[160];
    snprintf(msg, sizeof msg, "Local array length %lld is negative", (long long)length);
    rt_fatal(10, site, msg);
}

void rt_array_length(const rt_site* site, int64_t length, int64_t elem_size)
{
    char msg[160];
    if (length < 0)
        snprintf(msg, sizeof msg, "array length %lld is negative", (long long)length);
    else
        snprintf(msg, sizeof msg, "array length %lld is too large (%lld bytes per element)", (long long)length, (long long)elem_size);
    rt_fatal(10, site, msg);
}

/* ================================================================== intrinsics */

void rt_console_write(const char* p, int64_t n)
{
    if (n <= 0) return;
#ifdef _WIN32
    if (rt_debug_sink) { sink_write(p, (size_t)n); return; }
#endif
    fwrite(p, 1, (size_t)n, stdout);
    if (rt_flush_each) fflush(stdout);
}
void rt_console_write_line(const char* p, int64_t n)
{
    rt_console_write(p, n);
#ifdef _WIN32
    if (rt_debug_sink) { sink_write("\n", 1); return; }
#endif
    fputc('\n', stdout);
    if (rt_flush_each) fflush(stdout);
}
void rt_console_error_write(const char* p, int64_t n) { fflush(stdout); if (n > 0) err_write(p, (size_t)n); }
void* rt_memcpy(void* d, const void* s, int64_t n) { return memmove(d, s, (size_t)n); }
void* rt_memset(void* d, int32_t v, int64_t n) { return memset(d, v, (size_t)n); }
int32_t rt_memcmp(const void* a, const void* b, int64_t n) { return memcmp(a, b, (size_t)n); }

/* ================================================================== files and directories */
/* The core library's File and Directory (TreadleCore/core: crt.cimport names these): one shape on every
 * platform. Paths are UTF-8 bytes as the program gives them; a trailing separator is ignored. Windows: the
 * wide (UTF-16) calls (_wstat64, _wmkdir, _wrmdir, _wfindfirst64, _wfopen, _wremove) with the path converted
 * from UTF-8 and names converted back, so a non-ASCII path is the file it names (Security-Review.md finding
 * 14); Linux: stat / mkdir / opendir / fopen on the bytes. */
#ifdef _WIN32
#include <io.h>
#include <direct.h>
static wchar_t* rt_wide(const char* s);
#else
#include <dirent.h>
#include <unistd.h>
#endif
#include <sys/stat.h>

/* Copies a path into buf (4096 bytes); 0 when it is empty or too long. Both separators work on every platform,
 * as Path accepts both: elsewhere than Windows a backslash becomes '/'. */
static int rt_path_copy(const char* path, char* buf)
{
    size_t n = strlen(path);
    if (n == 0 || n >= 4096) return 0;
    memcpy(buf, path, n + 1);
#ifndef _WIN32
    for (size_t i = 0; i < n; i++)
        if (buf[i] == '\\') buf[i] = '/';
#endif
    return 1;
}

/* 1 for a directory, 2 for anything else that exists, 0 when nothing is there. */
static int rt_path_kind(const char* path)
{
    char buf[4096];
    if (!rt_path_copy(path, buf)) return 0;
    size_t n = strlen(buf);
    while (n > 1 && (buf[n - 1] == '/' || buf[n - 1] == '\\') && !(n == 3 && buf[1] == ':')) buf[--n] = 0;
#ifdef _WIN32
    struct _stat64 s;
    wchar_t* w = rt_wide(buf);
    int found = w && _wstat64(w, &s) == 0;
    free(w);
    if (!found) return 0;
    return (s.st_mode & _S_IFDIR) ? 1 : 2;
#else
    struct stat s;
    if (stat(buf, &s) != 0) return 0;
    return S_ISDIR(s.st_mode) ? 1 : 2;
#endif
}

int32_t rt_file_exists(const char* path) { return rt_path_kind(path) == 2; }
int32_t rt_dir_exists(const char* path) { return rt_path_kind(path) == 1; }

/* Creates the directory and the missing ones above it; 1 when it exists afterwards. */
int32_t rt_dir_create(const char* path)
{
    char buf[4096];
    size_t n, i;
    if (!rt_path_copy(path, buf)) return 0;
    n = strlen(buf);
    for (i = 1; i <= n; i++) {
        if (i < n && buf[i] != '/' && buf[i] != '\\') continue;
        char c = buf[i];
        buf[i] = 0;
        if (rt_path_kind(buf) == 0) {
#ifdef _WIN32
            wchar_t* w = rt_wide(buf);
            if (w) _wmkdir(w);
            free(w);
#else
            mkdir(buf, 0777);
#endif
        }
        buf[i] = c;
    }
    return rt_path_kind(path) == 1;
}

/* Deletes an empty directory; 1 when it is gone. */
int32_t rt_dir_delete(const char* path)
{
#ifdef _WIN32
    wchar_t* w = rt_wide(path);
    int ok = w && _wrmdir(w) == 0;
    free(w);
    return ok;
#else
    char buf[4096];
    return rt_path_copy(path, buf) && rmdir(buf) == 0;
#endif
}

/* fopen of a UTF-8 path (File.ReadAllText, WriteAllText, ReadLines); null when it cannot be opened. */
void* rt_fopen(const char* path, const char* mode)
{
#ifdef _WIN32
    wchar_t* w = rt_wide(path);
    wchar_t* m = rt_wide(mode);
    FILE* f = (w && m) ? _wfopen(w, m) : NULL;
    free(w);
    free(m);
    return f;
#else
    return fopen(path, mode);
#endif
}

/* Deletes a file at a UTF-8 path (File.Delete); 0 when it was deleted, as remove. */
int32_t rt_remove(const char* path)
{
#ifdef _WIN32
    wchar_t* w = rt_wide(path);
    int r = w ? _wremove(w) : -1;
    free(w);
    return r;
#else
    return remove(path);
#endif
}

typedef struct rt_dir {
#ifdef _WIN32
    intptr_t handle;
    struct _wfinddata64_t data;
    int pending;            /* data holds an entry rt_dir_next has not given yet */
#else
    DIR* dir;
    char path[4096];
#endif
    char name[1024];
} rt_dir;

/* A listing of the directory's entries, or null when it cannot be read. */
void* rt_dir_open(const char* path)
{
    rt_dir* d = (rt_dir*)calloc(1, sizeof(rt_dir));
    size_t n = strlen(path);
    if (!d || n + 3 >= 4096) { free(d); return NULL; }
#ifdef _WIN32
    char pattern[4096];
    wchar_t* w;
    memcpy(pattern, path, n);
    if (n > 0 && path[n - 1] != '/' && path[n - 1] != '\\') pattern[n++] = '/';
    pattern[n++] = '*';
    pattern[n] = 0;
    w = rt_wide(pattern);
    d->handle = w ? _wfindfirst64(w, &d->data) : -1;
    free(w);
    if (d->handle == -1) { free(d); return NULL; }
    d->pending = 1;
#else
    if (!rt_path_copy(n ? path : ".", d->path)) { free(d); return NULL; }
    d->dir = opendir(d->path);
    if (!d->dir) { free(d); return NULL; }
#endif
    return d;
}

/* The next entry's name (dirs: 1 for directories, 0 for the other entries), without "." and ".."; null at
 * the end. The name is valid until the next call. */
const char* rt_dir_next(void* handle, int32_t dirs)
{
    rt_dir* d = (rt_dir*)handle;
    if (!d) return NULL;
    for (;;) {
        int isDir;
#ifdef _WIN32
        if (!d->pending && _wfindnext64(d->handle, &d->data) != 0) return NULL;
        d->pending = 0;
        isDir = (d->data.attrib & _A_SUBDIR) != 0;
        if (WideCharToMultiByte(CP_UTF8, 0, d->data.name, -1, d->name, (int)sizeof d->name, NULL, NULL) <= 0) continue;
#else
        struct dirent* e = readdir(d->dir);
        if (!e) return NULL;
        if (e->d_type == DT_UNKNOWN) {
            char full[8192];
            snprintf(full, sizeof full, "%s/%s", d->path, e->d_name);
            isDir = rt_path_kind(full) == 1;
        }
        else
            isDir = e->d_type == DT_DIR;
        snprintf(d->name, sizeof d->name, "%s", e->d_name);
#endif
        if (strcmp(d->name, ".") == 0 || strcmp(d->name, "..") == 0 || isDir != (dirs != 0)) continue;
        return d->name;
    }
}

void rt_dir_close(void* handle)
{
    rt_dir* d = (rt_dir*)handle;
    if (!d) return;
#ifdef _WIN32
    _findclose(d->handle);
#else
    closedir(d->dir);
#endif
    free(d);
}

#ifndef _WIN32
/* kernel32's QueryPerformanceCounter / QueryPerformanceFrequency, which the core library's Time
   imports (TreadleCore/core/crt.cdecl): on Linux the counter is CLOCK_MONOTONIC in nanoseconds. */
#include <time.h>
int32_t QueryPerformanceCounter(int64_t* count)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) { *count = 0; return 0; }
    *count = (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
    return 1;
}
int32_t QueryPerformanceFrequency(int64_t* frequency) { *frequency = 1000000000LL; return 1; }
#endif

/* ================================================================== legacy probe shim */

void* treadle_alloc(size_t n) { return rt_alloc_dbg((int64_t)n, 16, NULL); }
void treadle_free(void* p) { rt_free_dbg(p, NULL); }
int treadle_rt_report(void) { return rt_leak_report(); }

/* ================================================================== text, environment, processes, calendar */
/* The core library's third wave (TreadleCore/core/crt.cdecl names these; docs/Core-Library.md): number parsing,
 * AppendF's placeholder scanner and number formats, UTF-8, the console's code page, the environment, child
 * processes, the calendar clock and sleeping. Texts come in as a pointer and a byte count (not zero-terminated)
 * unless the parameter is a name, path or args; texts going out are UTF-8 in a runtime buffer, valid until the next
 * call of the same family. */
#include <math.h>
#ifdef _WIN32
#include <wchar.h>
typedef struct rt_secattr { rt_dword length; void* descriptor; int inherit; } rt_secattr;
typedef struct rt_startinfo {
    rt_dword cb; wchar_t* reserved; wchar_t* desktop; wchar_t* title;
    rt_dword x, y, xsize, ysize, xchars, ychars, fill, flags;
    unsigned short show, reserved2; unsigned char* reserved3;
    void* in; void* out; void* err;
} rt_startinfo;
typedef struct rt_procinfo { void* process; void* thread; rt_dword pid, tid; } rt_procinfo;
typedef struct rt_systime { unsigned short year, month, weekday, day, hour, minute, second, ms; } rt_systime;
__declspec(dllimport) int __stdcall MultiByteToWideChar(unsigned cp, rt_dword flags, const char* s, int sn, wchar_t* w, int wn);
__declspec(dllimport) rt_dword __stdcall GetModuleFileNameW(void* module, wchar_t* path, rt_dword size);
__declspec(dllimport) int __stdcall GetComputerNameW(wchar_t* name, rt_dword* size);
__declspec(dllimport) int __stdcall CreatePipe(void** read, void** write, rt_secattr* sa, rt_dword size);
__declspec(dllimport) int __stdcall SetHandleInformation(void* h, rt_dword mask, rt_dword flags);
__declspec(dllimport) void* __stdcall GetStdHandle(rt_dword which);
__declspec(dllimport) int __stdcall CreateProcessW(const wchar_t* app, wchar_t* cmd, void* pa, void* ta, int inherit,
                                                   rt_dword flags, void* env, const wchar_t* dir, rt_startinfo* si,
                                                   rt_procinfo* pi);
__declspec(dllimport) int __stdcall ReadFile(void* h, void* buf, rt_dword n, rt_dword* got, void* overlapped);
__declspec(dllimport) rt_dword __stdcall WaitForSingleObject(void* h, rt_dword ms);
__declspec(dllimport) int __stdcall GetExitCodeProcess(void* h, rt_dword* code);
__declspec(dllimport) int __stdcall TerminateProcess(void* h, unsigned code);
__declspec(dllimport) int __stdcall CloseHandle(void* h);
__declspec(dllimport) rt_dword __stdcall GetLastError(void);
__declspec(dllimport) void __stdcall Sleep(rt_dword ms);
__declspec(dllimport) void __stdcall GetSystemTime(rt_systime* t);
__declspec(dllimport) void __stdcall GetLocalTime(rt_systime* t);
__declspec(dllimport) int __stdcall SetConsoleOutputCP(unsigned cp);
__declspec(dllimport) unsigned __stdcall GetConsoleOutputCP(void);
__declspec(dllimport) int __stdcall SetConsoleCP(unsigned cp);
__declspec(dllimport) unsigned __stdcall GetConsoleCP(void);
__declspec(dllimport) void* __stdcall CreateThread(void* sa, size_t stack, rt_dword (__stdcall *fn)(void*), void* arg,
                                                   rt_dword flags, rt_dword* tid);
#include <fcntl.h>

/* The output pipe of a windowed program with no output of its own (rt_windowed): fds 1 and 2 (the C
   library's stdout and stderr) write into it, a thread hands each chunk to OutputDebugStringA, so the
   program's text reaches a debugger's output in the order it was written. At exit (atexit) and before
   a fault's TerminateProcess, sink_pipe_finish flushes, closes the write ends and waits for the thread
   to forward the rest (2 s at most). */
static void* rt_sink_read_end;
static void* rt_sink_thread;

static rt_dword __stdcall sink_pump(void* arg)
{
    char buf[1024];
    rt_dword got;
    (void)arg;
    while (ReadFile(rt_sink_read_end, buf, sizeof buf - 1, &got, NULL) && got > 0) {
        buf[got] = 0;
        OutputDebugStringA(buf);
    }
    return 0;
}

static void sink_pipe_finish(void)
{
    if (!rt_sink_thread) return;
    fflush(stdout);
    fflush(stderr);
    _close(_fileno(stdout));
    _close(_fileno(stderr));
    WaitForSingleObject(rt_sink_thread, 2000);
    CloseHandle(rt_sink_thread);
    CloseHandle(rt_sink_read_end);
    rt_sink_thread = NULL;
}

static int sink_pipe_start(void)
{
    void* rd;
    void* wr;
    int fd;
    /* the streams of a program started without handles have no file: opened on NUL first, so they
       have one, which then becomes the pipe */
    if (!freopen("NUL", "w", stdout) || !freopen("NUL", "w", stderr)) return 0;
    if (!CreatePipe(&rd, &wr, NULL, 0)) return 0;
    fd = _open_osfhandle((intptr_t)wr, _O_WRONLY | _O_TEXT);
    if (fd < 0) { CloseHandle(rd); CloseHandle(wr); return 0; }
    if (_dup2(fd, _fileno(stdout)) != 0 || _dup2(fd, _fileno(stderr)) != 0) { _close(fd); CloseHandle(rd); return 0; }
    _close(fd);
    rt_sink_read_end = rd;
    rt_sink_thread = CreateThread(NULL, 0, sink_pump, NULL, 0, NULL);
    if (!rt_sink_thread) { CloseHandle(rd); return 0; }
    atexit(sink_pipe_finish);
    return 1;
}
#else
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#endif

/* ---- numbers */

/* An integer: an optional '-' or '+', an optional 0x / 0X (hex) or 0b / 0B (binary) prefix, then digits; a ' after
 * a digit is ignored (Beef's Int64.Parse). No white space. 0: *out holds it; 1: no digits; 2: outside int64's range
 * (hex and binary too); 3: a character that is not a digit of the base, at *pos. */
int32_t rt_parse_int(const char* p, int64_t n, int64_t* out, int64_t* pos)
{
    int64_t i = 0;
    int neg = 0, digits = 0, radix = 10;
    uint64_t v = 0, limit;
    *out = 0;
    *pos = 0;
    if (n <= 0) return 1;
    if (p[0] == '-' || p[0] == '+') { neg = p[0] == '-'; i = 1; }
    if (i + 1 < n && p[i] == '0' && (p[i + 1] == 'x' || p[i + 1] == 'X')) { radix = 16; i += 2; }
    else if (i + 1 < n && p[i] == '0' && (p[i + 1] == 'b' || p[i + 1] == 'B')) { radix = 2; i += 2; }
    limit = neg ? (uint64_t)INT64_MAX + 1u : (uint64_t)INT64_MAX;
    for (; i < n; i++) {
        char c = p[i];
        int d;
        if (c == '\'' && digits) continue;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else d = 99;
        if (d >= radix) { *pos = i; return 3; }
        if (v > (limit - (uint64_t)d) / (uint64_t)radix) return 2;
        v = v * (uint64_t)radix + (uint64_t)d;
        digits = 1;
    }
    if (!digits) return 1;
    *out = neg ? (int64_t)(0u - v) : (int64_t)v;
    return 0;
}

/* 1 when the two texts are equal ignoring the case of ASCII letters. */
int32_t rt_ascii_ieq(const char* a, int64_t an, const char* b, int64_t bn)
{
    int64_t i;
    if (an != bn) return 0;
    for (i = 0; i < an; i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
        if (x != y) return 0;
    }
    return 1;
}

/* A floating-point number: an optional sign, digits with an optional '.' and fraction (a digit on at least one side),
 * an optional exponent (e or E, an optional sign, digits); or Infinity, Inf or NaN in any case. No white space.
 * The codes of rt_parse_int; a value past double's range is an infinity (Beef's rule), not code 2. */
int32_t rt_parse_double(const char* p, int64_t n, double* out, int64_t* pos)
{
    int64_t i = 0, digits = 0;
    char small[128];
    char* buf = small;
    *out = 0;
    *pos = 0;
    if (n <= 0) return 1;
    if (p[0] == '-' || p[0] == '+') i = 1;
    if (rt_ascii_ieq(p + i, n - i, "infinity", 8) || rt_ascii_ieq(p + i, n - i, "inf", 3)) {
        *out = p[0] == '-' ? -INFINITY : INFINITY;
        return 0;
    }
    if (rt_ascii_ieq(p + i, n - i, "nan", 3)) { *out = NAN; return 0; }
    for (; i < n && p[i] >= '0' && p[i] <= '9'; i++) digits++;
    if (i < n && p[i] == '.')
        for (i++; i < n && p[i] >= '0' && p[i] <= '9'; i++) digits++;
    if (digits == 0) {
        if (i < n) { *pos = i; return 3; }
        return 1;
    }
    if (i < n && (p[i] == 'e' || p[i] == 'E')) {
        int64_t e = 0;
        i++;
        if (i < n && (p[i] == '-' || p[i] == '+')) i++;
        for (; i < n && p[i] >= '0' && p[i] <= '9'; i++) e++;
        if (e == 0) { *pos = i; return 3; }
    }
    if (i < n) { *pos = i; return 3; }
    if (n >= (int64_t)sizeof small) {
        buf = (char*)malloc((size_t)n + 1);
        if (!buf) return 1;
    }
    memcpy(buf, p, (size_t)n);
    buf[n] = 0;
    *out = strtod(buf, NULL);
    if (buf != small) free(buf);
    return 0;
}

/* One step through an AppendF format from pos. The literal text before what comes next is [pos, *litEnd); then
 * -1: the end of the format (*next = n); -2: "{{" or "}}", whose first brace ends the literal text, *next is past the
 * second; k >= 0: placeholder {k[,width][:spec]}, *next is past its '}', *width its alignment (negative: left), its
 * spec [*specStart, *specStart + *specLen). A '{' or '}' that starts neither is literal text. */
int32_t rt_format_scan(const char* p, int64_t n, int64_t pos, int64_t* litEnd, int64_t* next, int64_t* width,
                       int64_t* specStart, int64_t* specLen)
{
    int64_t i;
    *width = 0;
    *specStart = 0;
    *specLen = 0;
    for (i = pos; i < n; i++) {
        if ((p[i] == '{' || p[i] == '}') && i + 1 < n && p[i + 1] == p[i]) {
            *litEnd = i + 1;
            *next = i + 2;
            return -2;
        }
        if (p[i] == '{') {
            int64_t j = i + 1, k = 0, w = 0, digits = 0, s = 0, sl = 0;
            int neg = 0;
            while (j < n && p[j] >= '0' && p[j] <= '9' && digits < 9) { k = k * 10 + (p[j] - '0'); j++; digits++; }
            if (digits == 0) continue;
            if (j < n && p[j] == ',') {
                int64_t wd = 0;
                j++;
                if (j < n && p[j] == '-') { neg = 1; j++; }
                while (j < n && p[j] >= '0' && p[j] <= '9' && wd < 4) { w = w * 10 + (p[j] - '0'); j++; wd++; }
                if (wd == 0) continue;
            }
            if (j < n && p[j] == ':') {
                s = j + 1;
                while (j < n && p[j] != '}' && p[j] != '{') j++;
                sl = j - s;
            }
            if (j >= n || p[j] != '}') continue;
            *litEnd = i;
            *next = j + 1;
            *width = neg ? -w : w;
            *specStart = s;
            *specLen = sl;
            return (int32_t)k;
        }
    }
    *litEnd = n;
    *next = n;
    return -1;
}

/* Copies a formatted number into buf, with ',' between groups of three digits of its integer part. */
static int64_t rt_group(char* buf, int64_t cap, const char* digits)
{
    int64_t len = (int64_t)strlen(digits), start = 0, intEnd, o = 0, i;
    if (digits[0] == '-') start = 1;
    for (intEnd = start; intEnd < len && digits[intEnd] >= '0' && digits[intEnd] <= '9'; intEnd++) {}
    int64_t need = 0;
    for (i = 0; i < len; i++) {
        int comma = i >= start && i + 1 < intEnd && (intEnd - i - 1) % 3 == 0;
        need += 1 + comma;
        if (o + 2 < cap) {
            buf[o++] = digits[i];
            if (comma) buf[o++] = ',';
        }
    }
    buf[o] = 0;
    return need;                                     /* the length it needs (rt_format_number clamps) */
}

/* The decimal digits of v (a '-' first when negative), zero-terminated, into buf, which has room for 21 bytes;
 * returns their count. Two digits per step from a table: String.Append(int) and the integer formats, no snprintf. */
int64_t rt_format_int(char* buf, int64_t v)
{
    static const char pairs[201] =
        "00010203040506070809101112131415161718192021222324252627282930313233343536373839"
        "40414243444546474849505152535455565758596061626364656667686970717273747576777879"
        "8081828384858687888990919293949596979899";
    char tmp[20];
    char* q = tmp + 20;
    uint64_t u = v < 0 ? 0u - (uint64_t)v : (uint64_t)v;
    int64_t n, o = 0;
    while (u >= 100) {
        unsigned r = (unsigned)(u % 100);
        u /= 100;
        q -= 2;
        q[0] = pairs[2 * r];
        q[1] = pairs[2 * r + 1];
    }
    if (u >= 10) {
        q -= 2;
        q[0] = pairs[2 * u];
        q[1] = pairs[2 * u + 1];
    }
    else *--q = (char)('0' + u);
    if (v < 0) buf[o++] = '-';
    n = (tmp + 20) - q;
    memcpy(buf + o, q, (size_t)n);
    o += n;
    buf[o] = 0;
    return o;
}

/* An integer in decimal with at least `digits` digits (zeros in front; the '-' before them), zero-terminated into
 * buf (cap bytes, at least 2); returns the length it needs (more than written when cut; rt_format_number clamps). */
static int64_t rt_format_digits(char* buf, int64_t cap, int64_t i, int digits)
{
    char tmp[24];
    int64_t n = rt_format_int(tmp, i), neg = i < 0, o = 0, k;
    int64_t zeros = digits - (n - neg);
    if (zeros < 0) zeros = 0;
    if (neg) buf[o++] = '-';
    for (k = 0; k < zeros && o + 1 < cap; k++) buf[o++] = '0';
    for (k = neg; k < n && o + 1 < cap; k++) buf[o++] = tmp[k];
    buf[o] = 0;
    return neg + zeros + (n - neg);
}

/* AppendF's alignment of one placeholder: p holds the formatted value (n bytes) with room after it for |width| more
 * and a terminating zero. Pads it with spaces to |width| code points: in front (right-aligned) for a positive width,
 * after it for a negative one; a longer value is left as it is. Returns the new length (zero-terminated). */
int64_t rt_utf8_count(const char* p, int64_t n);
int64_t rt_format_align(char* p, int64_t n, int64_t width)
{
    int64_t w = width < 0 ? -width : width;
    int64_t cps = rt_utf8_count(p, n);
    int64_t pad = w - cps;
    if (pad <= 0) return n;
    if (width > 0) {
        memmove(p + pad, p, (size_t)n);
        memset(p, ' ', (size_t)pad);
    }
    else memset(p + n, ' ', (size_t)pad);
    p[n + pad] = 0;
    return n + pad;
}

/* A number as a format spec says, written zero-terminated into buf (cap bytes; 512 is always enough); returns its
 * length. kind: 0 an integer (i), 1 a double (d), 2 a float (d). The spec is a letter and an optional precision
 * (0 to 99): F fixed (2 decimals by default), E / e scientific (6), G / g general (significant digits: 15, a float
 * 7), N fixed with ',' between thousands (2 decimals, an integer 0), D decimal with at least that many digits, X / x
 * hex digits (upper / lower case) and B binary digits, at least that many. D, X and B round a float to an integer;
 * X and B of a negative integer give its 64-bit two's complement. An empty or unknown spec writes the plain form
 * (String.Append's). rt_format_number_raw returns the length the text needs (snprintf's), which may exceed cap - 1;
 * rt_format_number clamps it (Security-Review.md finding 13). */
static int64_t rt_format_number_raw(char* buf, int64_t cap, int32_t kind, int64_t i, double d, const char* spec, int64_t specLen)
{
    char letter = specLen > 0 ? spec[0] : 0;
    int prec = -1;
    int64_t k;
    char tmp[512];
    if (cap < 2) {
        if (cap > 0) buf[0] = 0;
        return 0;
    }
    if (specLen > 3) letter = '?';
    for (k = 1; k < specLen && letter != '?'; k++) {
        if (spec[k] < '0' || spec[k] > '9') letter = '?';
        else prec = (prec < 0 ? 0 : prec * 10) + (spec[k] - '0');
    }
    if (kind != 0 && (letter == 'D' || letter == 'd' || letter == 'X' || letter == 'x' || letter == 'B' || letter == 'b')) {
        double r = d < 0 ? -d : d;
        if (r != r || r > 9.2e18) r = 0;
        i = (int64_t)(r + 0.5);
        if (d < 0) i = -i;
        kind = 0;
    }
    if (kind == 0 && (letter == 'F' || letter == 'f' || letter == 'E' || letter == 'e' || letter == 'G' || letter == 'g' ||
                      ((letter == 'N' || letter == 'n') && prec > 0))) {
        d = (double)i;
        kind = 1;
    }
    switch (letter) {
    case 'F': case 'f':
        return snprintf(buf, (size_t)cap, "%.*f", prec < 0 ? 2 : prec, d);
    case 'E': case 'e':
        return snprintf(buf, (size_t)cap, letter == 'E' ? "%.*E" : "%.*e", prec < 0 ? 6 : prec, d);
    case 'G': case 'g':
        return snprintf(buf, (size_t)cap, letter == 'G' ? "%.*G" : "%.*g", prec <= 0 ? (kind == 2 ? 7 : 15) : prec, d);
    case 'N': case 'n':
        if (kind == 0) rt_format_int(tmp, i);
        else snprintf(tmp, sizeof tmp, "%.*f", prec < 0 ? 2 : prec, d);
        return rt_group(buf, cap, tmp);
    case 'D': case 'd':
        return rt_format_digits(buf, cap, i, prec < 0 ? 1 : prec);
    case 'X': case 'x':
        return snprintf(buf, (size_t)cap, letter == 'X' ? "%0*llX" : "%0*llx", prec < 0 ? 1 : prec, (unsigned long long)i);
    case 'B': case 'b': {
        uint64_t u = (uint64_t)i;
        int bits = 1, o = 0, b;
        while (bits < 64 && (u >> bits) != 0) bits++;
        if (prec > bits) bits = prec > 64 ? 64 : prec;
        for (b = bits - 1; b >= 0 && o + 1 < cap; b--) buf[o++] = (char)('0' + ((u >> b) & 1u));
        buf[o] = 0;
        return bits;                                 /* the length it needs (more than o when cut) */
    }
    default:
        if (kind == 0) return rt_format_digits(buf, cap, i, 1);
        return snprintf(buf, (size_t)cap, kind == 2 ? "%.7g" : "%.15g", d);
    }
}

/* The number's text never runs past buf: a length the buffer could not hold is cut to cap - 1 (the text is then
 * cut too, snprintf and the loops above stop at cap). The core always passes 512, which every format fits, so a
 * cut is a runtime bug: Debug stops with fatal error 13 naming the lengths, Release returns the cut text. */
int64_t rt_format_number(char* buf, int64_t cap, int32_t kind, int64_t i, double d, const char* spec, int64_t specLen)
{
    int64_t n;
    if (cap < 2) {
        if (cap > 0) buf[0] = 0;
        return 0;
    }
    n = rt_format_number_raw(buf, cap, kind, i, d, spec, specLen);
    if (n < 0) n = 0;
    if (n > cap - 1) {
#ifdef TREADLE_DEBUG
        char msg[160];
        snprintf(msg, sizeof msg, "a number's text needs %lld bytes, its buffer holds %lld (rt_format_number)", (long long)n, (long long)(cap - 1));
        rt_fatal(13, NULL, msg);
#endif
        n = cap - 1;
    }
    buf[n] = 0;
    return n;
}

/* ---- UTF-8 */

/* The code point at text[pos] (n bytes in all) in *cp and the bytes it takes (1 to 4); 0 at the end. A byte that
 * does not start a valid sequence (an overlong form, a surrogate, past U+10FFFF, cut off) takes 1 byte and gives
 * U+FFFD. */
int32_t rt_utf8_decode(const char* text, int64_t n, int64_t pos, int32_t* cp)
{
    const unsigned char* p = (const unsigned char*)text;
    unsigned c;
    int len, k;
    uint32_t v;
    *cp = 0;
    if (pos < 0 || pos >= n) return 0;
    c = p[pos];
    if (c < 0x80) { *cp = (int32_t)c; return 1; }
    if (c >= 0xC2 && c <= 0xDF) { len = 2; v = c & 0x1F; }
    else if (c >= 0xE0 && c <= 0xEF) { len = 3; v = c & 0x0F; }
    else if (c >= 0xF0 && c <= 0xF4) { len = 4; v = c & 0x07; }
    else { *cp = 0xFFFD; return 1; }
    if (pos + len > n) { *cp = 0xFFFD; return 1; }
    for (k = 1; k < len; k++) {
        unsigned b = p[pos + k];
        if ((b & 0xC0) != 0x80) { *cp = 0xFFFD; return 1; }
        v = (v << 6) | (b & 0x3F);
    }
    if ((len == 3 && (v < 0x800 || (v >= 0xD800 && v <= 0xDFFF))) || (len == 4 && (v < 0x10000 || v > 0x10FFFF))) {
        *cp = 0xFFFD;
        return 1;
    }
    *cp = (int32_t)v;
    return len;
}

/* Writes the code point as UTF-8 into buf (room for 4 bytes) and returns its length; a surrogate, a negative value
 * or one past U+10FFFF writes U+FFFD. */
int32_t rt_utf8_encode(int32_t c, char* buf)
{
    uint32_t v = (uint32_t)c;
    if (c < 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) v = 0xFFFD;
    if (v < 0x80) { buf[0] = (char)v; return 1; }
    if (v < 0x800) {
        buf[0] = (char)(0xC0 | (v >> 6));
        buf[1] = (char)(0x80 | (v & 0x3F));
        return 2;
    }
    if (v < 0x10000) {
        buf[0] = (char)(0xE0 | (v >> 12));
        buf[1] = (char)(0x80 | ((v >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (v & 0x3F));
        return 3;
    }
    buf[0] = (char)(0xF0 | (v >> 18));
    buf[1] = (char)(0x80 | ((v >> 12) & 0x3F));
    buf[2] = (char)(0x80 | ((v >> 6) & 0x3F));
    buf[3] = (char)(0x80 | (v & 0x3F));
    return 4;
}

/* The number of code points of valid UTF-8 text; otherwise -1 - (the offset of the first byte that does not start
 * a valid sequence). */
int64_t rt_utf8_check(const char* p, int64_t n)
{
    int64_t pos = 0, count = 0;
    while (pos < n) {
        int32_t cp;
        int32_t len = rt_utf8_decode(p, n, pos, &cp);
        if (len == 1 && cp == 0xFFFD) return -1 - pos;
        pos += len;
        count++;
    }
    return count;
}

/* The number of code points (a byte that starts no valid sequence counts as one, as rt_utf8_decode reads it). */
int64_t rt_utf8_count(const char* p, int64_t n)
{
    int64_t pos = 0, count = 0;
    while (pos < n) {
        int32_t cp;
        pos += rt_utf8_decode(p, n, pos, &cp);
        count++;
    }
    return count;
}

/* The console speaks UTF-8 (Windows): before Main, in Debug and Release, the console's output and input code pages
 * become UTF-8 (65001); at exit they go back to what they were. Without a console (a pipe, a file) nothing changes
 * and the bytes go out as they are, as on Linux. */
#ifdef _WIN32
static unsigned rt_console_old_out, rt_console_old_in;
static void rt_console_restore(void)
{
    if (rt_console_old_out) SetConsoleOutputCP(rt_console_old_out);
    if (rt_console_old_in) SetConsoleCP(rt_console_old_in);
}
__attribute__((constructor)) static void rt_console_utf8(void)
{
    rt_console_old_out = GetConsoleOutputCP();
    rt_console_old_in = GetConsoleCP();
    if (rt_console_old_out == CP_UTF8) rt_console_old_out = 0;
    if (rt_console_old_in == CP_UTF8) rt_console_old_in = 0;
    if (rt_console_old_out) SetConsoleOutputCP(CP_UTF8);
    if (rt_console_old_in) SetConsoleCP(CP_UTF8);
    if (rt_console_old_out || rt_console_old_in) atexit(rt_console_restore);
}
#endif

/* ---- environment */

static _Thread_local char* rt_text_buf;      /* per thread (docs/Threads.md 4) */
static _Thread_local size_t rt_text_cap;

static char* rt_text_room(size_t n)
{
    if (n + 1 > rt_text_cap) {
        char* p = (char*)realloc(rt_text_buf, n + 1);
        if (!p) return NULL;
        rt_text_buf = p;
        rt_text_cap = n + 1;
    }
    return rt_text_buf;
}

#ifdef _WIN32
/* UTF-8 to a new UTF-16 string (free it), or null. */
static wchar_t* rt_wide(const char* s)
{
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t* w;
    if (n <= 0) return NULL;
    w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

/* UTF-16 to UTF-8 in the text buffer. */
static const char* rt_narrow(const wchar_t* w)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char* s;
    if (n <= 0) return "";
    s = rt_text_room((size_t)n);
    if (!s) return "";
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}
#else
static const char* rt_copy_text(const char* s)
{
    size_t n = strlen(s);
    char* b = rt_text_room(n);
    if (!b) return "";
    memcpy(b, s, n + 1);
    return b;
}
#endif

/* The variable's value (UTF-8), or null when it is not set. */
const char* rt_env_get(const char* name)
{
#ifdef _WIN32
    wchar_t* wn = rt_wide(name);
    const wchar_t* v;
    if (!wn) return NULL;
    v = _wgetenv(wn);
    free(wn);
    return v ? rt_narrow(v) : NULL;
#else
    const char* v = getenv(name);
    return v ? rt_copy_text(v) : NULL;
#endif
}

/* Sets the variable for this process and the processes it starts (an empty value: Windows removes it, Linux keeps
 * it empty); a null value removes it. 1 when done; a name that is empty or has a '=' is refused. */
int32_t rt_env_set(const char* name, const char* value)
{
    if (!name[0] || strchr(name, '=')) return 0;
#ifdef _WIN32
    {
        wchar_t* wn = rt_wide(name);
        wchar_t* wv = rt_wide(value ? value : "");
        int ok = wn && wv && _wputenv_s(wn, wv) == 0;
        free(wn);
        free(wv);
        return ok;
    }
#else
    return (value ? setenv(name, value, 1) : unsetenv(name)) == 0;
#endif
}

/* The working directory (UTF-8). */
const char* rt_cwd_get(void)
{
#ifdef _WIN32
    wchar_t* w = _wgetcwd(NULL, 0);
    const char* s;
    if (!w) return "";
    s = rt_narrow(w);
    free(w);
    return s;
#else
    char* c = getcwd(NULL, 0);
    const char* s;
    if (!c) return "";
    s = rt_copy_text(c);
    free(c);
    return s;
#endif
}

/* Changes the working directory; 1 when done. */
int32_t rt_cwd_set(const char* path)
{
#ifdef _WIN32
    wchar_t* w = rt_wide(path);
    int ok = w && _wchdir(w) == 0;
    free(w);
    return ok;
#else
    char buf[4096];
    return rt_path_copy(path, buf) && chdir(buf) == 0;
#endif
}

/* The full path of the running program (UTF-8). */
const char* rt_exe_path(void)
{
#ifdef _WIN32
    wchar_t w[4096];
    rt_dword n = GetModuleFileNameW(NULL, w, 4096);
    if (n == 0 || n >= 4096) return "";
    w[n] = 0;
    return rt_narrow(w);
#else
    char b[4096];
    ssize_t n = readlink("/proc/self/exe", b, sizeof b - 1);
    if (n <= 0) return "";
    b[n] = 0;
    return rt_copy_text(b);
#endif
}

/* The computer's name (UTF-8). */
const char* rt_machine_name(void)
{
#ifdef _WIN32
    wchar_t w[256];
    rt_dword n = 256;
    if (!GetComputerNameW(w, &n)) return "";
    w[n < 256 ? n : 255] = 0;
    return rt_narrow(w);
#else
    char b[256];
    if (gethostname(b, sizeof b) != 0) return "";
    b[sizeof b - 1] = 0;
    return rt_copy_text(b);
#endif
}

/* 1 on Windows, 0 elsewhere. */
int32_t rt_is_windows(void)
{
#ifdef _WIN32
    return 1;
#else
    return 0;
#endif
}

/* ---- processes */

typedef struct rt_proc {
#ifdef _WIN32
    void* process;
    void* out;          /* the read end of the child's stdout, or null */
#else
    int pid;
    int out;            /* the read end of the child's stdout, or -1 */
#endif
    char* text;         /* what the child wrote to its stdout, zero-terminated */
    int64_t length, cap;
    int32_t code;
    int32_t done;
} rt_proc;

static void rt_proc_keep(rt_proc* h, const char* p, int64_t n)
{
    if (h->length + n + 1 > h->cap) {
        int64_t cap = h->cap ? h->cap * 2 : 4096;
        char* t;
        while (cap < h->length + n + 1) cap *= 2;
        t = (char*)realloc(h->text, (size_t)cap);
        if (!t) return;
        h->text = t;
        h->cap = cap;
    }
    memcpy(h->text + h->length, p, (size_t)n);
    h->length += n;
    h->text[h->length] = 0;
}

#ifndef _WIN32
/* True when the program can be found: a path with a '/' that can be run, or a name on PATH. */
static int rt_proc_found(const char* path)
{
    const char* dirs;
    char buf[4096];
    if (strchr(path, '/')) return access(path, X_OK) == 0;
    dirs = getenv("PATH");
    if (!dirs) dirs = "/usr/bin:/bin";
    while (*dirs) {
        const char* end = strchr(dirs, ':');
        size_t len = end ? (size_t)(end - dirs) : strlen(dirs);
        if (len > 0 && len + strlen(path) + 2 < sizeof buf) {
            memcpy(buf, dirs, len);
            buf[len] = '/';
            strcpy(buf + len + 1, path);
            if (access(buf, X_OK) == 0) return 1;
        }
        if (!end) break;
        dirs = end + 1;
    }
    return 0;
}
#endif

#ifdef _WIN32
/* Starts the command line `line` (UTF-8) with CreateProcessW; fills h, or returns 0 with *error set. */
static int rt_proc_spawn(rt_proc* h, const char* line, int32_t capture, int32_t* error)
{
    wchar_t* wline = rt_wide(line);
    rt_startinfo si;
    rt_procinfo pi;
    rt_secattr sa = { sizeof(rt_secattr), NULL, 1 };
    void* rd = NULL;
    void* wr = NULL;
    int ok;
    if (!wline) return 0;
    memset(&si, 0, sizeof si);
    memset(&pi, 0, sizeof pi);
    si.cb = sizeof si;
    if (capture) {
        if (!CreatePipe(&rd, &wr, &sa, 0)) { free(wline); return 0; }
        SetHandleInformation(rd, 1 /* HANDLE_FLAG_INHERIT */, 0);
        si.flags = 0x100; /* STARTF_USESTDHANDLES */
        si.in = GetStdHandle((rt_dword)-10);
        si.out = wr;
        si.err = GetStdHandle((rt_dword)-12);
    }
    ok = CreateProcessW(NULL, wline, NULL, NULL, 1, 0, NULL, NULL, &si, &pi);
    if (!ok) {
        rt_dword e = GetLastError();
        *error = (e == 2 || e == 3) ? 1 : 2; /* ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND */
    }
    free(wline);
    if (wr) CloseHandle(wr);
    if (!ok) {
        if (rd) CloseHandle(rd);
        return 0;
    }
    CloseHandle(pi.thread);
    h->process = pi.process;
    h->out = rd;
    return 1;
}

/* One argument quoted for the command line the C runtime splits (CommandLineToArgvW's rules): unchanged
   when it is not empty and has no space, tab, newline or quote; else in quotes, with a run of backslashes
   doubled before a quote (and before the closing quote) and each quote escaped. Writes to out when not
   null; returns the length. */
static size_t rt_win_quote(const char* a, char* out)
{
    size_t o = 0, k;
    if (*a && !strpbrk(a, " \t\n\v\"")) {
        size_t n = strlen(a);
        if (out) memcpy(out, a, n);
        return n;
    }
    if (out) out[o] = '"';
    o++;
    for (;;) {
        size_t bs = 0;
        while (*a == '\\') { bs++; a++; }
        if (!*a) {
            for (k = 0; k < bs * 2; k++) { if (out) out[o] = '\\'; o++; }
            break;
        }
        if (*a == '"')
            bs = bs * 2 + 1;
        for (k = 0; k < bs; k++) { if (out) out[o] = '\\'; o++; }
        if (out) out[o] = *a;
        o++;
        a++;
    }
    if (out) out[o] = '"';
    o++;
    return o;
}
#else
/* Forks; the child runs `file` with `argv` (execvp: a name without '/' is looked up on PATH). Fills h, or
   returns 0. */
static int rt_proc_fork(rt_proc* h, const char* file, char* const* argv, int32_t capture)
{
    int fds[2] = { -1, -1 };
    int pid;
    if (capture && pipe(fds) != 0) return 0;
    pid = fork();
    if (pid == 0) {
        if (capture) { dup2(fds[1], 1); close(fds[0]); close(fds[1]); }
        execvp(file, argv);
        _exit(127);
    }
    if (capture) close(fds[1]);
    if (pid < 0) {
        if (capture) close(fds[0]);
        return 0;
    }
    h->pid = pid;
    h->out = capture ? fds[0] : -1;
    return 1;
}
#endif

/* Starts `path` (a path, or a program name the system looks up on PATH) with the command-line text `args`
 * (Windows: passed on as CreateProcess passes it, the program splits it; Linux: /bin/sh reads it after the quoted
 * path, so the shell's quoting rules apply). capture 1: the child's stdout is kept for rt_proc_output (its stdin
 * and stderr are this program's); 0: it shares this program's. Returns a handle, or null with *error 1 (the
 * program was not found) or 2 (it could not be started). */
void* rt_proc_start(const char* path, const char* args, int32_t capture, int32_t* error)
{
    rt_proc* h = (rt_proc*)calloc(1, sizeof(rt_proc));
    *error = 2;
    if (!h) return NULL;
    fflush(stdout);
    fflush(stderr);
#ifdef _WIN32
    {
        size_t pn = strlen(path), an = strlen(args);
        char* line = (char*)malloc(pn + an + 4);
        int ok;
        if (!line) { free(h); return NULL; }
        line[0] = '"';
        memcpy(line + 1, path, pn);
        line[pn + 1] = '"';
        line[pn + 2] = an ? ' ' : 0;
        memcpy(line + pn + 3, args, an + 1);
        ok = rt_proc_spawn(h, line, capture, error);
        free(line);
        if (!ok) { free(h); return NULL; }
    }
#else
    {
        size_t pn = strlen(path), an = strlen(args), i, o = 0;
        char* line;
        char* argv[4];
        int ok;
        if (!rt_proc_found(path)) { *error = 1; free(h); return NULL; }
        line = (char*)malloc(pn * 4 + an + 8);
        if (!line) { free(h); return NULL; }
        line[o++] = '\'';
        for (i = 0; i < pn; i++) {
            if (path[i] == '\'') { memcpy(line + o, "'\\''", 4); o += 4; }
            else line[o++] = path[i];
        }
        line[o++] = '\'';
        if (an) { line[o++] = ' '; memcpy(line + o, args, an); o += an; }
        line[o] = 0;
        argv[0] = (char*)"sh";
        argv[1] = (char*)"-c";
        argv[2] = line;
        argv[3] = NULL;
        ok = rt_proc_fork(h, "/bin/sh", argv, capture);
        free(line);
        if (!ok) { free(h); return NULL; }
    }
#endif
    *error = 0;
    return h;
}

/* Starts `path` with an argument list and no shell (Process.Start(path, List<String>)): `block` holds `count`
 * arguments, each ended by a NUL byte (`length` bytes in all). Windows: each argument is quoted for the C
 * runtime's splitter (rt_win_quote), so the program receives exactly these strings; Linux: fork + execvp with
 * them as argv[1..]. capture and the result as rt_proc_start; *error 2 also when the block does not hold
 * `count` arguments (one of them had a NUL byte in it). */
void* rt_proc_start_list(const char* path, const char* block, int64_t length, int64_t count, int32_t capture, int32_t* error)
{
    rt_proc* h;
    int64_t i, found = 0;
    *error = 2;
    if (count < 0 || length < 0 || count > 1000000) return NULL;
    for (i = 0; i < length; i++)
        if (block[i] == 0) found++;
    if (found != count || (length > 0 && block[length - 1] != 0)) return NULL;
    h = (rt_proc*)calloc(1, sizeof(rt_proc));
    if (!h) return NULL;
    fflush(stdout);
    fflush(stderr);
#ifdef _WIN32
    {
        size_t pn = strlen(path), total = pn + 3, o;
        const char* a = block;
        char* line;
        int ok;
        for (i = 0; i < count; i++) { total += rt_win_quote(a, NULL) + 1; a += strlen(a) + 1; }
        line = (char*)malloc(total + 1);
        if (!line) { free(h); return NULL; }
        line[0] = '"';
        memcpy(line + 1, path, pn);
        line[pn + 1] = '"';
        o = pn + 2;
        a = block;
        for (i = 0; i < count; i++) {
            line[o++] = ' ';
            o += rt_win_quote(a, line + o);
            a += strlen(a) + 1;
        }
        line[o] = 0;
        ok = rt_proc_spawn(h, line, capture, error);
        free(line);
        if (!ok) { free(h); return NULL; }
    }
#else
    {
        char** argv;
        const char* a = block;
        int ok;
        if (!rt_proc_found(path)) { *error = 1; free(h); return NULL; }
        argv = (char**)calloc((size_t)count + 2, sizeof(char*));
        if (!argv) { free(h); return NULL; }
        argv[0] = (char*)path;
        for (i = 0; i < count; i++) { argv[i + 1] = (char*)a; a += strlen(a) + 1; }
        ok = rt_proc_fork(h, path, argv, capture);
        free(argv);
        if (!ok) { free(h); return NULL; }
    }
#endif
    *error = 0;
    return h;
}

#ifndef _WIN32
static int32_t rt_proc_status(int status)
{
    return WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
}

static void rt_proc_drain(rt_proc* h)
{
    char buf[4096];
    if (h->out < 0) return;
    for (;;) {
        ssize_t got = read(h->out, buf, sizeof buf);
        if (got > 0) { rt_proc_keep(h, buf, got); continue; }
        if (got < 0 && errno == EINTR) continue;
        break;
    }
    close(h->out);
    h->out = -1;
}
#endif

/* Reads the child's stdout to its end (it is kept), waits for the child and returns its exit code (Linux: 128 + the
 * signal when one ended it). */
int32_t rt_proc_wait(void* handle)
{
    rt_proc* h = (rt_proc*)handle;
    if (!h) return -1;
    if (h->done) return h->code;
#ifdef _WIN32
    if (h->out) {
        char buf[4096];
        rt_dword got = 0;
        while (ReadFile(h->out, buf, sizeof buf, &got, NULL) && got > 0) rt_proc_keep(h, buf, got);
        CloseHandle(h->out);
        h->out = NULL;
    }
    {
        rt_dword code = 0;
        WaitForSingleObject(h->process, 0xFFFFFFFFu);
        GetExitCodeProcess(h->process, &code);
        h->code = (int32_t)code;
    }
#else
    {
        int status = 0;
        rt_proc_drain(h);
        while (waitpid(h->pid, &status, 0) < 0 && errno == EINTR) {}
        h->code = rt_proc_status(status);
    }
#endif
    h->done = 1;
    return h->code;
}

/* 1 when the child has ended. */
int32_t rt_proc_exited(void* handle)
{
    rt_proc* h = (rt_proc*)handle;
    if (!h || h->done) return 1;
#ifdef _WIN32
    return WaitForSingleObject(h->process, 0) == 0;
#else
    {
        int status = 0;
        int r = waitpid(h->pid, &status, WNOHANG);
        if (r == h->pid) {
            /* reaped here: keep the code, read what is left of the output */
            rt_proc_drain(h);
            h->code = rt_proc_status(status);
            h->done = 1;
            return 1;
        }
        return r < 0;
    }
#endif
}

/* Ends the child at once (Windows: exit code 1; Linux: SIGKILL, so 137); 1 when it was running. */
int32_t rt_proc_kill(void* handle)
{
    rt_proc* h = (rt_proc*)handle;
    if (!h || h->done) return 0;
#ifdef _WIN32
    return TerminateProcess(h->process, 1) != 0;
#else
    return kill(h->pid, SIGKILL) == 0;
#endif
}

/* What the child wrote to its stdout (complete after rt_proc_wait), zero-terminated, and its length. */
const char* rt_proc_output(void* handle, int64_t* length)
{
    rt_proc* h = (rt_proc*)handle;
    *length = (h && h->text) ? h->length : 0;
    return (h && h->text) ? h->text : "";
}

/* Frees the handle; a child still running keeps running. */
void rt_proc_close(void* handle)
{
    rt_proc* h = (rt_proc*)handle;
    if (!h) return;
#ifdef _WIN32
    if (h->out) CloseHandle(h->out);
    CloseHandle(h->process);
#else
    if (h->out >= 0) close(h->out);
    if (!h->done) waitpid(h->pid, NULL, WNOHANG);
#endif
    free(h->text);
    free(h);
}

/* ---- the calendar clock and sleeping */

/* The date and time now: utc 1 for UTC, 0 for local time. */
void rt_time_now(int32_t utc, int64_t* year, int64_t* month, int64_t* day, int64_t* hour, int64_t* minute,
                 int64_t* second, int64_t* ms)
{
#ifdef _WIN32
    rt_systime t;
    if (utc) GetSystemTime(&t);
    else GetLocalTime(&t);
    *year = t.year; *month = t.month; *day = t.day;
    *hour = t.hour; *minute = t.minute; *second = t.second; *ms = t.ms;
#else
    struct timespec ts;
    struct tm tm;
    time_t s;
    clock_gettime(CLOCK_REALTIME, &ts);
    s = ts.tv_sec;
    if (utc) gmtime_r(&s, &tm);
    else localtime_r(&s, &tm);
    *year = tm.tm_year + 1900; *month = tm.tm_mon + 1; *day = tm.tm_mday;
    *hour = tm.tm_hour; *minute = tm.tm_min; *second = tm.tm_sec; *ms = ts.tv_nsec / 1000000;
#endif
}

/* Sleeps at least ms milliseconds (not at all for 0 or less). */
void rt_sleep(int64_t ms)
{
    if (ms <= 0) return;
#ifdef _WIN32
    Sleep((rt_dword)ms);
#else
    {
        struct timespec ts;
        ts.tv_sec = ms / 1000;
        ts.tv_nsec = (long)(ms % 1000) * 1000000L;
        while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {}
    }
#endif
}

/* ================================================================== threads */
/* Threads, mutexes, condition variables, events, thread-local slots, the pool and Parallel (docs/Threads.md). The core
 * library's Thread, Mutex, LockGuard, Condition, WaitEvent, ThreadLocal, ThreadPool and Parallel import these with
 * [Import]. Win32 on Windows (no winpthreads), pthreads on Linux. A delegate is { vtable, target, fn }: a body is
 * called as fn(target), fn(target, i) or fn(target, lo, hi). */
#ifdef _WIN32
typedef struct rt_srw { void* p; } rt_srw;            /* SRWLOCK */
typedef struct rt_cv { void* p; } rt_cv;              /* CONDITION_VARIABLE */
__declspec(dllimport) void __stdcall InitializeSRWLock(rt_srw* l);
__declspec(dllimport) void __stdcall AcquireSRWLockExclusive(rt_srw* l);
__declspec(dllimport) void __stdcall ReleaseSRWLockExclusive(rt_srw* l);
__declspec(dllimport) unsigned char __stdcall TryAcquireSRWLockExclusive(rt_srw* l);
__declspec(dllimport) void __stdcall InitializeConditionVariable(rt_cv* c);
__declspec(dllimport) int __stdcall SleepConditionVariableSRW(rt_cv* c, rt_srw* l, rt_dword ms, unsigned long flags);
__declspec(dllimport) void __stdcall WakeConditionVariable(rt_cv* c);
__declspec(dllimport) void __stdcall WakeAllConditionVariable(rt_cv* c);
__declspec(dllimport) rt_dword __stdcall GetCurrentThreadId(void);
__declspec(dllimport) void* __stdcall GetCurrentThread(void);
__declspec(dllimport) int __stdcall SwitchToThread(void);
__declspec(dllimport) rt_dword __stdcall GetActiveProcessorCount(unsigned short group);
__declspec(dllimport) rt_dword __stdcall TlsAlloc(void);
__declspec(dllimport) void* __stdcall TlsGetValue(rt_dword index);
__declspec(dllimport) int __stdcall TlsSetValue(rt_dword index, void* value);
__declspec(dllimport) int __stdcall TlsFree(rt_dword index);
__declspec(dllimport) void* __stdcall GetModuleHandleA(const char* name);
__declspec(dllimport) void* __stdcall GetProcAddress(void* module, const char* name);
#define RT_INFINITE 0xFFFFFFFFul
#define RT_STACK_RESERVATION 0x00010000ul
typedef rt_srw rt_lock_t;
typedef rt_cv rt_cond_t;
static void lk_init(rt_lock_t* l) { InitializeSRWLock(l); }
static void lk_destroy(rt_lock_t* l) { (void)l; }
static void lk_lock(rt_lock_t* l) { AcquireSRWLockExclusive(l); }
static void lk_unlock(rt_lock_t* l) { ReleaseSRWLockExclusive(l); }
static int lk_trylock(rt_lock_t* l) { return TryAcquireSRWLockExclusive(l) != 0; }
static void cv_init(rt_cond_t* c) { InitializeConditionVariable(c); }
static void cv_destroy(rt_cond_t* c) { (void)c; }
static void cv_wait(rt_cond_t* c, rt_lock_t* l) { SleepConditionVariableSRW(c, l, RT_INFINITE, 0); }
/* 1: woken, 0: timed out (a wait may also end spuriously; the callers loop on their condition) */
static int cv_wait_ms(rt_cond_t* c, rt_lock_t* l, int64_t ms)
{
    rt_dword w = ms <= 0 ? 0 : (ms >= 0xFFFFFFFEll ? 0xFFFFFFFEul : (rt_dword)ms);
    return SleepConditionVariableSRW(c, l, w, 0) != 0;
}
static void cv_signal(rt_cond_t* c) { WakeConditionVariable(c); }
static void cv_broadcast(rt_cond_t* c) { WakeAllConditionVariable(c); }
static int64_t rt_now_id(void) { return (int64_t)GetCurrentThreadId(); }
static void rt_spin_yield(void) { SwitchToThread(); }
__declspec(dllimport) unsigned long long __stdcall GetTickCount64(void);
static int64_t rt_ms_now(void) { return (int64_t)GetTickCount64(); }
static rt_srw rt_init_lock;                           /* SRWLOCK_INIT is all zero */
static void rt_init_enter(void) { AcquireSRWLockExclusive(&rt_init_lock); }
static void rt_init_leave(void) { ReleaseSRWLockExclusive(&rt_init_lock); }
#else
#include <pthread.h>
#include <sched.h>
typedef pthread_mutex_t rt_lock_t;
typedef pthread_cond_t rt_cond_t;
static void lk_init(rt_lock_t* l) { pthread_mutex_init(l, NULL); }
static void lk_destroy(rt_lock_t* l) { pthread_mutex_destroy(l); }
static void lk_lock(rt_lock_t* l) { pthread_mutex_lock(l); }
static void lk_unlock(rt_lock_t* l) { pthread_mutex_unlock(l); }
static int lk_trylock(rt_lock_t* l) { return pthread_mutex_trylock(l) == 0; }
static void cv_init(rt_cond_t* c)
{
    pthread_condattr_t a;
    pthread_condattr_init(&a);
    pthread_condattr_setclock(&a, CLOCK_MONOTONIC);
    pthread_cond_init(c, &a);
    pthread_condattr_destroy(&a);
}
static void cv_destroy(rt_cond_t* c) { pthread_cond_destroy(c); }
static void cv_wait(rt_cond_t* c, rt_lock_t* l) { pthread_cond_wait(c, l); }
static int cv_wait_ms(rt_cond_t* c, rt_lock_t* l, int64_t ms)
{
    struct timespec ts;
    if (ms < 0) ms = 0;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    ts.tv_sec += (time_t)(ms / 1000);
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    return pthread_cond_timedwait(c, l, &ts) == 0;
}
static void cv_signal(rt_cond_t* c) { pthread_cond_signal(c); }
static void cv_broadcast(rt_cond_t* c) { pthread_cond_broadcast(c); }
static int64_t rt_now_id(void) { return (int64_t)gettid(); }
static void rt_spin_yield(void) { sched_yield(); }
static int64_t rt_ms_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static pthread_mutex_t rt_init_lock = PTHREAD_MUTEX_INITIALIZER;
static void rt_init_enter(void) { pthread_mutex_lock(&rt_init_lock); }
static void rt_init_leave(void) { pthread_mutex_unlock(&rt_init_lock); }
#endif

/* Runtime memory (not objects: not in the leak report). Out of memory ends the program. */
static void* rt_thr_alloc(size_t n)
{
    void* p = calloc(1, n ? n : 1);
    if (!p) { fputs("fatal: out of memory\n", stderr); exit(3); }
    return p;
}

/* Deletes a delegate the runtime owns (a Thread's body, pool work): its destructor, then the memory. */
static void rt_delete_object(void* obj)
{
    if (!obj) return;
    ((rt_dtor_fn)((rt_object*)obj)->vtable[1])(obj);
    rt_free(obj);
}

/* A delegate the runtime is to own must not be null and (Debug) must be a live Construct (docs/Threads.md 2). */
static void rt_check_owned_body(void* body, const char* what)
{
    char msg[300];
    if (!body) {
        snprintf(msg, sizeof msg, "%s: the delegate is null", what);
        rt_fatal(12, NULL, msg);
    }
#ifdef TREADLE_DEBUG
    if ((((rt_dbg_header*)body) - 1)->magic != RT_MAGIC_LIVE) {
        snprintf(msg, sizeof msg, "%s: the delegate must be made with Allocation construct (a Local one is freed when its region ends while the thread may still run it)", what);
        rt_fatal(12, NULL, msg);
    }
#endif
}

/* ---- names by runtime index (kept after a thread ended: the leak report still names it) */
static rt_lock_t rt_names_lock;
static char** rt_names;
static uint32_t rt_names_count, rt_names_cap;
static volatile int32_t rt_names_ready;

static void rt_threads_init(void)
{
    if (__atomic_load_n(&rt_names_ready, __ATOMIC_ACQUIRE)) return;
    rt_init_enter();
    if (!rt_names_ready) {
        lk_init(&rt_names_lock);
        rt_names_cap = 16;
        rt_names = (char**)rt_thr_alloc(sizeof(char*) * rt_names_cap);
        rt_names[0] = (char*)"Main";
        rt_names_count = 1;
        __atomic_store_n(&rt_names_ready, 1, __ATOMIC_RELEASE);
    }
    rt_init_leave();
}

/* A new runtime index with its name (a copy; empty: "<prefix> <index>"). */
static uint32_t rt_name_new(const char* name, int64_t len, const char* prefix)
{
    uint32_t ix;
    char* copy;
    rt_threads_init();
    lk_lock(&rt_names_lock);
    ix = rt_names_count;
    if (!name || len <= 0) {
        copy = (char*)rt_thr_alloc(48);
        snprintf(copy, 48, "%s %u", prefix, (unsigned)ix);
    } else {
        copy = (char*)rt_thr_alloc((size_t)len + 1);
        memcpy(copy, name, (size_t)len);
    }
    if (rt_names_count == rt_names_cap) {
        char** n = (char**)realloc(rt_names, sizeof(char*) * rt_names_cap * 2);
        if (!n) { fputs("fatal: out of memory\n", stderr); exit(3); }
        rt_names = n;
        rt_names_cap *= 2;
    }
    rt_names[rt_names_count++] = copy;
    lk_unlock(&rt_names_lock);
    return ix;
}

static const char* rt_thread_index_name(uint32_t index)
{
    const char* s = "a thread";
    if (index == 0) return "Main";
    if (!__atomic_load_n(&rt_names_ready, __ATOMIC_ACQUIRE) || index == 0xFFFF) return s;
    lk_lock(&rt_names_lock);
    if (index < rt_names_count) s = rt_names[index];
    lk_unlock(&rt_names_lock);
    return s;
}

/* rt_fatal: the first thread reports and ends the process; another one that fails meanwhile waits for that. */
static volatile int64_t rt_fatal_thread;
static void rt_fatal_gate(void)
{
    int64_t me = rt_now_id(), none = 0;
    if (__atomic_compare_exchange_n(&rt_fatal_thread, &none, me, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) return;
    if (none == me) { fflush(stderr); _exit(3); }    /* a fatal error while reporting one */
    for (;;) rt_sleep(1000);
}

/* ---- the thread record */
typedef struct rt_thread {
#ifdef _WIN32
    void* handle;
#else
    pthread_t pt;
#endif
    void* owner;                                     /* the Core.Thread object (null for a pool worker) */
    void* body;                                      /* the delegate, owned from Start */
    void (*centry)(void*);                           /* a runtime thread (a pool worker) runs this instead */
    void* carg;
    int64_t stack;
    volatile int64_t sysid;
    uint32_t index;
    volatile int32_t refs;                           /* the owner, and the thread while it runs */
    volatile int32_t state;                          /* 0 made, 1 running, 2 ended */
    int32_t started, joined, detached;
} rt_thread;

static _Thread_local rt_thread* rt_cur_thread;

static void rt_thread_release(rt_thread* t)
{
    if (__atomic_sub_fetch(&t->refs, 1, __ATOMIC_ACQ_REL) == 0) free(t);
}

static void rt_name_this_thread(const char* name)
{
#ifdef _WIN32
    typedef long (__stdcall *set_desc_fn)(void* thread, const wchar_t* name);
    static set_desc_fn set_desc;
    static volatile int32_t looked;
    if (!__atomic_load_n(&looked, __ATOMIC_ACQUIRE)) {
        void* k = GetModuleHandleA("kernel32.dll");
        set_desc = k ? (set_desc_fn)GetProcAddress(k, "SetThreadDescription") : NULL;
        __atomic_store_n(&looked, 1, __ATOMIC_RELEASE);
    }
    if (set_desc) {
        wchar_t* w = rt_wide(name);
        if (w) { set_desc(GetCurrentThread(), w); free(w); }
    }
#else
    char buf[16];
    size_t n = strlen(name);
    if (n > 15) n = 15;
    memcpy(buf, name, n);
    buf[n] = 0;
    pthread_setname_np(pthread_self(), buf);
#endif
}

static void rt_thread_run(rt_thread* t)
{
    rt_cur_thread = t;
    rt_cur_index = t->index;
#ifdef TREADLE_DEBUG
    rt_dbg_thread_begin(t->index);                   /* its own live list (docs/Threads.md 5) */
#endif
    __atomic_store_n(&t->sysid, rt_now_id(), __ATOMIC_RELEASE);
    rt_name_this_thread(rt_thread_index_name(t->index));
    rt_debug_name_thread(t->index);
    if (t->centry)
        t->centry(t->carg);
    else {
        void** d = (void**)t->body;
        ((void (*)(void*))d[2])(d[1]);
        t->body = NULL;
        rt_delete_object(d);                         /* the body is the thread's: deleted on the thread */
    }
#ifdef TREADLE_DEBUG
    rt_dbg_thread_end();                             /* its live blocks to the orphan list */
#endif
    __atomic_store_n(&t->state, 2, __ATOMIC_RELEASE);
    rt_thread_release(t);
}

#ifdef _WIN32
static rt_dword __stdcall rt_thread_main(void* arg) { rt_thread_run((rt_thread*)arg); return 0; }
#else
static void* rt_thread_main(void* arg) { rt_thread_run((rt_thread*)arg); return NULL; }
#endif

void* rt_thread_new(const char* name, int64_t len, int64_t stackSize, void* owner)
{
    rt_thread* t = (rt_thread*)rt_thr_alloc(sizeof(rt_thread));
    t->owner = owner;
    t->stack = stackSize > 0 ? stackSize : (1 << 20);
    t->index = rt_name_new(name, len, "Thread");
    t->refs = 1;
    return t;
}

static int rt_thread_launch(rt_thread* t)
{
    __atomic_store_n(&rt_threads_used, 1, __ATOMIC_SEQ_CST);   /* the Debug allocator keeps per-thread lists from now on */
    __atomic_add_fetch(&t->refs, 1, __ATOMIC_ACQ_REL);
    t->started = 1;
    t->state = 1;
#ifdef _WIN32
    t->handle = CreateThread(NULL, (size_t)t->stack, rt_thread_main, t, RT_STACK_RESERVATION, NULL);
    if (!t->handle) {
        t->state = 0; t->started = 0;
        __atomic_sub_fetch(&t->refs, 1, __ATOMIC_ACQ_REL);
        return 0;
    }
#else
    {
        pthread_attr_t a;
        size_t st = (size_t)t->stack;
        if (st < 65536) st = 65536;
        pthread_attr_init(&a);
        pthread_attr_setstacksize(&a, st);
        if (pthread_create(&t->pt, &a, rt_thread_main, t) != 0) {
            pthread_attr_destroy(&a);
            t->state = 0; t->started = 0;
            __atomic_sub_fetch(&t->refs, 1, __ATOMIC_ACQ_REL);
            return 0;
        }
        pthread_attr_destroy(&a);
    }
#endif
    return 1;
}

/* Starts the thread on `body`, which the thread owns from now on (deleted at once when the start fails). */
int32_t rt_thread_start(void* handle, void* body)
{
    rt_thread* t = (rt_thread*)handle;
    rt_check_owned_body(body, "Thread.Start");
    if (t->started) rt_fatal(12, NULL, "Thread.Start: the thread was started already (a Thread runs once)");
    t->body = body;
    if (!rt_thread_launch(t)) {
        t->body = NULL;
        rt_delete_object(body);
        return 0;
    }
    return 1;
}

void rt_thread_join(void* handle)
{
    rt_thread* t = (rt_thread*)handle;
    if (!t->started || t->joined || t->detached) return;
    if (t == rt_cur_thread) rt_fatal(12, NULL, "Thread.Join: a thread cannot join itself");
#ifdef _WIN32
    WaitForSingleObject(t->handle, RT_INFINITE);
    CloseHandle(t->handle);
    t->handle = NULL;
#else
    pthread_join(t->pt, NULL);
#endif
    t->joined = 1;
}

void rt_thread_detach(void* handle)
{
    rt_thread* t = (rt_thread*)handle;
    if (!t->started || t->joined || t->detached) return;
#ifdef _WIN32
    CloseHandle(t->handle);
    t->handle = NULL;
#else
    pthread_detach(t->pt);
#endif
    t->detached = 1;
}

/* The owner is deleted: a thread still joinable is Joined, then the owner's reference goes. */
void rt_thread_free(void* handle)
{
    rt_thread* t = (rt_thread*)handle;
    if (!t) return;
    if (t == rt_cur_thread && t->started && !t->joined && !t->detached)
        rt_fatal(12, NULL, "Thread: deleted by its own body (it would join itself); Detach it first");
    rt_thread_join(t);
    __atomic_store_n(&t->owner, NULL, __ATOMIC_RELEASE);
    rt_thread_release(t);
}

int32_t rt_thread_alive(void* handle) { return __atomic_load_n(&((rt_thread*)handle)->state, __ATOMIC_ACQUIRE) == 1; }

int64_t rt_thread_id(void* handle)
{
    rt_thread* t = (rt_thread*)handle;
    int i;
    /* the thread writes its id as it starts: wait for it briefly */
    for (i = 0; t->started && i < 100000 && __atomic_load_n(&t->sysid, __ATOMIC_ACQUIRE) == 0; i++) rt_spin_yield();
    return __atomic_load_n(&t->sysid, __ATOMIC_ACQUIRE);
}

/* The thread's name (null handle: the current thread's). */
const char* rt_thread_name(void* handle, int64_t* len)
{
    const char* s = rt_thread_index_name(handle ? ((rt_thread*)handle)->index : rt_cur_index);
    *len = (int64_t)strlen(s);
    return s;
}

void* rt_thread_current(void) { return rt_cur_thread ? __atomic_load_n(&rt_cur_thread->owner, __ATOMIC_ACQUIRE) : NULL; }
int64_t rt_thread_current_id(void) { return rt_now_id(); }
void rt_thread_yield(void) { rt_spin_yield(); }

int32_t rt_cpu_count(void)
{
#ifdef _WIN32
    rt_dword n = GetActiveProcessorCount(0xFFFF);    /* ALL_PROCESSOR_GROUPS */
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
#endif
    return n > 0 ? (int32_t)n : 1;
}

/* ---- Mutex (not recursive; Debug checks the owner) */
typedef struct rt_mutex { rt_lock_t lock; volatile int64_t owner; } rt_mutex;

void* rt_mutex_new(void)
{
    rt_mutex* m = (rt_mutex*)rt_thr_alloc(sizeof(rt_mutex));
    lk_init(&m->lock);
    return m;
}

void rt_mutex_free(void* handle)
{
    rt_mutex* m = (rt_mutex*)handle;
    if (!m) return;
#ifdef TREADLE_DEBUG
    if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED)) rt_fatal(12, NULL, "Mutex: deleted while a thread holds it");
#endif
    lk_destroy(&m->lock);
    free(m);
}

void rt_mutex_lock(void* handle)
{
    rt_mutex* m = (rt_mutex*)handle;
#ifdef TREADLE_DEBUG
    if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED) == rt_now_id())
        rt_fatal(12, NULL, "Mutex.Lock: this thread holds it already (a Mutex is not recursive)");
#endif
    lk_lock(&m->lock);
    __atomic_store_n(&m->owner, rt_now_id(), __ATOMIC_RELAXED);
}

int32_t rt_mutex_trylock(void* handle)
{
    rt_mutex* m = (rt_mutex*)handle;
    if (!lk_trylock(&m->lock)) return 0;
    __atomic_store_n(&m->owner, rt_now_id(), __ATOMIC_RELAXED);
    return 1;
}

void rt_mutex_unlock(void* handle)
{
    rt_mutex* m = (rt_mutex*)handle;
#ifdef TREADLE_DEBUG
    if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED) != rt_now_id())
        rt_fatal(12, NULL, "Mutex.Unlock: this thread does not hold it");
#endif
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    lk_unlock(&m->lock);
}

/* ---- Condition (over a Mutex the caller holds) */
void* rt_cond_new(void)
{
    rt_cond_t* c = (rt_cond_t*)rt_thr_alloc(sizeof(rt_cond_t));
    cv_init(c);
    return c;
}

void rt_cond_free(void* c)
{
    if (!c) return;
    cv_destroy((rt_cond_t*)c);
    free(c);
}

static void rt_cond_check(rt_mutex* m, const char* what)
{
#ifdef TREADLE_DEBUG
    if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED) != rt_now_id()) rt_fatal(12, NULL, what);
#else
    (void)m; (void)what;
#endif
}

void rt_cond_wait(void* c, void* mutex)
{
    rt_mutex* m = (rt_mutex*)mutex;
    rt_cond_check(m, "Condition.Wait: this thread does not hold the Mutex");
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    cv_wait((rt_cond_t*)c, &m->lock);
    __atomic_store_n(&m->owner, rt_now_id(), __ATOMIC_RELAXED);
}

int32_t rt_cond_wait_ms(void* c, void* mutex, int64_t ms)
{
    rt_mutex* m = (rt_mutex*)mutex;
    int r;
    rt_cond_check(m, "Condition.WaitFor: this thread does not hold the Mutex");
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    r = cv_wait_ms((rt_cond_t*)c, &m->lock, ms);
    __atomic_store_n(&m->owner, rt_now_id(), __ATOMIC_RELAXED);
    return r;
}

void rt_cond_signal(void* c) { cv_signal((rt_cond_t*)c); }
void rt_cond_broadcast(void* c) { cv_broadcast((rt_cond_t*)c); }

/* ---- WaitEvent (manual or auto reset): a lock, a condition and a flag, the same code on both systems */
typedef struct rt_event { rt_lock_t lock; rt_cond_t cond; int32_t set, autoReset; } rt_event;

void* rt_event_new(int32_t autoReset)
{
    rt_event* e = (rt_event*)rt_thr_alloc(sizeof(rt_event));
    lk_init(&e->lock);
    cv_init(&e->cond);
    e->autoReset = autoReset != 0;
    return e;
}

void rt_event_free(void* h)
{
    rt_event* e = (rt_event*)h;
    if (!e) return;
    cv_destroy(&e->cond);
    lk_destroy(&e->lock);
    free(e);
}

void rt_event_set(void* h)
{
    rt_event* e = (rt_event*)h;
    lk_lock(&e->lock);
    e->set = 1;
    if (e->autoReset) cv_signal(&e->cond); else cv_broadcast(&e->cond);
    lk_unlock(&e->lock);
}

void rt_event_reset(void* h)
{
    rt_event* e = (rt_event*)h;
    lk_lock(&e->lock);
    e->set = 0;
    lk_unlock(&e->lock);
}

void rt_event_wait(void* h)
{
    rt_event* e = (rt_event*)h;
    lk_lock(&e->lock);
    while (!e->set) cv_wait(&e->cond, &e->lock);
    if (e->autoReset) e->set = 0;
    lk_unlock(&e->lock);
}

int32_t rt_event_wait_ms(void* h, int64_t ms)
{
    rt_event* e = (rt_event*)h;
    int32_t got;
    int64_t end = rt_ms_now() + (ms > 0 ? ms : 0);
    lk_lock(&e->lock);
    while (!e->set) {
        int64_t left = end - rt_ms_now();
        if (left <= 0) break;
        cv_wait_ms(&e->cond, &e->lock, left);
    }
    got = e->set;
    if (got && e->autoReset) e->set = 0;
    lk_unlock(&e->lock);
    return got;
}

/* ---- ThreadLocal: one slot per key; a thread's block is made zeroed on its first Get, every block is freed with
   the key (a thread that ends keeps its block until then) */
typedef struct rt_tls_block { struct rt_tls_block* next; int64_t pad; } rt_tls_block;   /* 16 bytes: values 16-aligned */
typedef struct rt_tls {
#ifdef _WIN32
    rt_dword index;
#else
    pthread_key_t key;
#endif
    int64_t size;
    rt_lock_t lock;
    rt_tls_block* blocks;
} rt_tls;

void* rt_tls_new(int64_t size)
{
    rt_tls* k = (rt_tls*)rt_thr_alloc(sizeof(rt_tls));
    k->size = size > 0 ? size : 1;
    lk_init(&k->lock);
#ifdef _WIN32
    k->index = TlsAlloc();
    if (k->index == 0xFFFFFFFFul) rt_fatal(12, NULL, "ThreadLocal: the system has no thread-local slot left");
#else
    if (pthread_key_create(&k->key, NULL) != 0) rt_fatal(12, NULL, "ThreadLocal: the system has no thread-local slot left");
#endif
    return k;
}

void* rt_tls_get(void* handle)
{
    rt_tls* k = (rt_tls*)handle;
#ifdef _WIN32
    rt_tls_block* b = (rt_tls_block*)TlsGetValue(k->index);
#else
    rt_tls_block* b = (rt_tls_block*)pthread_getspecific(k->key);
#endif
    if (!b) {
        b = (rt_tls_block*)rt_thr_alloc(sizeof(rt_tls_block) + (size_t)k->size);
        lk_lock(&k->lock);
        b->next = k->blocks;
        k->blocks = b;
        lk_unlock(&k->lock);
#ifdef _WIN32
        TlsSetValue(k->index, b);
#else
        pthread_setspecific(k->key, b);
#endif
    }
    return b + 1;
}

void rt_tls_free(void* handle)
{
    rt_tls* k = (rt_tls*)handle;
    rt_tls_block* b;
    if (!k) return;
#ifdef _WIN32
    TlsFree(k->index);
#else
    pthread_key_delete(k->key);
#endif
    for (b = k->blocks; b; ) {
        rt_tls_block* n = b->next;
        free(b);
        b = n;
    }
    lk_destroy(&k->lock);
    free(k);
}

/* ---- the pool and Parallel (docs/Threads.md 1.1) */
typedef struct rt_work { void* body; struct rt_work* next; } rt_work;
typedef struct rt_job {
    void* body;
    int32_t ranges;
    int64_t to, chunk;
    volatile int64_t next;                           /* the next index to hand out */
    int32_t inside;                                  /* workers taking chunks of it (under the pool lock) */
    struct rt_job* nextJob;
} rt_job;

static rt_lock_t pool_lock;
static rt_cond_t pool_work_cv, pool_done_cv;
static rt_work* pool_head;
static rt_work* pool_tail;
static int64_t pool_pending;                         /* queued and running work of Run */
static rt_job* pool_jobs;                            /* the Parallel calls running */
static int pool_shutdown;
static int32_t pool_size;
static rt_thread** pool_threads;
static volatile int32_t pool_started;

static void rt_job_chunks(rt_job* j)
{
    void** d = (void**)j->body;
    for (;;) {
        int64_t lo = __atomic_fetch_add(&j->next, j->chunk, __ATOMIC_RELAXED), hi, i;
        if (lo >= j->to) return;
        hi = lo + j->chunk;
        if (hi > j->to || hi < lo) hi = j->to;
        if (j->ranges)
            ((void (*)(void*, int64_t, int64_t))d[2])(d[1], lo, hi);
        else
            for (i = lo; i < hi; i++)
                ((void (*)(void*, int64_t))d[2])(d[1], i);
    }
}

static rt_job* rt_open_job(void)
{
    rt_job* j;
    for (j = pool_jobs; j; j = j->nextJob)
        if (__atomic_load_n(&j->next, __ATOMIC_RELAXED) < j->to) return j;
    return NULL;
}

static void rt_pool_worker(void* arg)
{
    (void)arg;
    lk_lock(&pool_lock);
    for (;;) {
        rt_job* j = rt_open_job();
        if (j) {
            j->inside++;
            lk_unlock(&pool_lock);
            rt_job_chunks(j);
            lk_lock(&pool_lock);
            if (--j->inside == 0) cv_broadcast(&pool_done_cv);
            continue;
        }
        if (pool_head) {
            rt_work* w = pool_head;
            void** d = (void**)w->body;
            pool_head = w->next;
            if (!pool_head) pool_tail = NULL;
            lk_unlock(&pool_lock);
            free(w);
            ((void (*)(void*))d[2])(d[1]);
            rt_delete_object(d);                     /* the pool owns its work */
            lk_lock(&pool_lock);
            if (--pool_pending == 0) cv_broadcast(&pool_done_cv);
            continue;
        }
        if (pool_shutdown) break;
        cv_wait(&pool_work_cv, &pool_lock);
    }
    lk_unlock(&pool_lock);
}

static void rt_pool_start(void)
{
    int32_t i, n;
    if (__atomic_load_n(&pool_started, __ATOMIC_ACQUIRE)) return;
    rt_threads_init();
    rt_init_enter();
    if (!pool_started) {
        lk_init(&pool_lock);
        cv_init(&pool_work_cv);
        cv_init(&pool_done_cv);
        n = rt_cpu_count() - 1;
        if (n < 1) n = 1;
        pool_threads = (rt_thread**)rt_thr_alloc(sizeof(rt_thread*) * (size_t)n);
        for (i = 0; i < n; i++) {
            rt_thread* t = (rt_thread*)rt_thr_alloc(sizeof(rt_thread));
            t->stack = 1 << 20;
            t->index = rt_name_new(NULL, 0, "Pool");
            t->refs = 1;
            t->centry = rt_pool_worker;
            if (!rt_thread_launch(t)) { free(t); break; }
            pool_threads[i] = t;
        }
        pool_size = i;
        __atomic_store_n(&pool_started, 1, __ATOMIC_RELEASE);
    }
    rt_init_leave();
}

int32_t rt_pool_size(void) { rt_pool_start(); return pool_size; }

void rt_pool_run(void* body)
{
    rt_work* w;
    rt_check_owned_body(body, "ThreadPool.Run");
    rt_pool_start();
    w = (rt_work*)rt_thr_alloc(sizeof(rt_work));
    w->body = body;
    lk_lock(&pool_lock);
    if (pool_tail) pool_tail->next = w; else pool_head = w;
    pool_tail = w;
    pool_pending++;
    cv_signal(&pool_work_cv);
    lk_unlock(&pool_lock);
}

void rt_pool_wait(void)
{
    if (!__atomic_load_n(&pool_started, __ATOMIC_ACQUIRE)) return;
    lk_lock(&pool_lock);
    while (pool_pending > 0) cv_wait(&pool_done_cv, &pool_lock);
    lk_unlock(&pool_lock);
}

/* body(i) for i in [from, to) (ranges 0), or body(lo, hi) per chunk (ranges 1), on the pool and this thread. */
static void rt_parallel_run(int64_t from, int64_t to, void* body, int32_t ranges)
{
    rt_job j;
    rt_job** p;
    int64_t n, threads;
    if (!body) rt_fatal(1, NULL, "Parallel: the body is null");
    if (to <= from) return;
    rt_pool_start();
    n = to - from;
    threads = (int64_t)pool_size + 1;
    memset(&j, 0, sizeof j);
    j.body = body;
    j.ranges = ranges;
    j.to = to;
    j.next = from;
    j.chunk = n / (threads * 8);
    if (j.chunk < 1) j.chunk = 1;
    lk_lock(&pool_lock);
    j.nextJob = pool_jobs;
    pool_jobs = &j;
    cv_broadcast(&pool_work_cv);
    lk_unlock(&pool_lock);
    rt_job_chunks(&j);                               /* the caller takes chunks too */
    lk_lock(&pool_lock);
    for (p = &pool_jobs; *p; p = &(*p)->nextJob)
        if (*p == &j) { *p = j.nextJob; break; }
    while (j.inside > 0) cv_wait(&pool_done_cv, &pool_lock);
    lk_unlock(&pool_lock);
}

/* rt_exit: the queued work runs to its end, then the workers end and are joined. */
static void rt_threads_at_exit(void)
{
    int32_t i;
    if (!__atomic_load_n(&pool_started, __ATOMIC_ACQUIRE)) return;
    lk_lock(&pool_lock);
    pool_shutdown = 1;
    cv_broadcast(&pool_work_cv);
    lk_unlock(&pool_lock);
    for (i = 0; i < pool_size; i++) {
        rt_thread_join(pool_threads[i]);
        rt_thread_release(pool_threads[i]);
    }
    free(pool_threads);
    pool_threads = NULL;
    pool_size = 0;
    pool_shutdown = 0;
    __atomic_store_n(&pool_started, 0, __ATOMIC_RELEASE);
}

void rt_parallel_for(int64_t from, int64_t to, void* body) { rt_parallel_run(from, to, body, 0); }
void rt_parallel_ranges(int64_t from, int64_t to, void* body) { rt_parallel_run(from, to, body, 1); }

/* The debugger's table of thread names (docs/Threads.md 6): a line "<system id> <name>" per thread started (the
   main thread first), which the editor's debugger reads with one evaluate at a stop: lldb on Windows does not read
   thread descriptions, and on Linux it reads only the first 15 bytes. A thread that ended keeps its line; when the
   table is full, later threads are not listed (the debugger shows lldb's own name for them). */
char rt_debug_thread_names[8192];
static size_t rt_debug_thread_names_len;

static void rt_debug_name_thread(uint32_t index)
{
    char line[160];
    int n, i;
    rt_threads_init();
    n = snprintf(line, sizeof line, "%lld %s", (long long)rt_now_id(), rt_thread_index_name(index));
    if (n <= 0) return;
    if ((size_t)n >= sizeof line - 1) n = (int)sizeof line - 2;
    for (i = 0; i < n; i++)
        if ((unsigned char)line[i] < 0x20) line[i] = ' ';
    line[n++] = '\n';
    lk_lock(&rt_names_lock);
    if (rt_debug_thread_names_len + (size_t)n < sizeof rt_debug_thread_names) {
        memcpy(rt_debug_thread_names + rt_debug_thread_names_len, line, (size_t)n);
        rt_debug_thread_names_len += (size_t)n;
        rt_debug_thread_names[rt_debug_thread_names_len] = 0;
    }
    lk_unlock(&rt_names_lock);
}
