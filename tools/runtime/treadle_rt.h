/*
 * treadle_rt.h - the ABI between compiled Treadle programs and their C runtime (treadle_rt.c).
 *
 * Everything the compiler's back end (TreadleBackend) emits a call to, and every data structure it
 * emits that the runtime reads, is declared here. docs/Compiler.md section 6 is the design; the
 * places where this ABI differs from it are listed in docs/Follow-ups.md ("Back end").
 *
 * Node ids are strings in the graph format, so the runtime names a node through a site record
 * (rt_site: the function and the node id) that the compiler emits as a constant per node.
 */
#ifndef TREADLE_RT_H
#define TREADLE_RT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Where something happened: "Game.Program.Main" and "a7". Emitted as constants by the compiler. */
typedef struct rt_site {
    const char* where;
    const char* node;
} rt_site;

/* TypeInfo flags. */
enum {
    RT_TI_CLASS = 1, RT_TI_STRUCT = 2, RT_TI_ENUM = 4, RT_TI_INTERFACE = 8,
    RT_TI_ARRAY = 16, RT_TI_BOX = 32, RT_TI_ABSTRACT = 64
};

struct rt_type_info;

typedef struct rt_iface_entry {
    uint32_t iface_id;          /* FNV-1a 32 of the interface's mangled type name */
    uint32_t reserved;
    void* const* itable;        /* the class's implementations, in interface slot order */
} rt_iface_entry;

typedef struct rt_field_info {
    const char* name;
    const char* type_name;
    uint64_t offset;
} rt_field_info;

/* LLVM: { i32, i32, i64, i32, ptr, ptr, i32, i32, ptr, ptr } */
typedef struct rt_type_info {
    uint32_t type_id;           /* FNV-1a 32 of the mangled type name (no _Z prefix) */
    uint32_t flags;
    uint64_t size;              /* instance size (object including its header) */
    uint32_t align;
    const char* name;           /* Treadle name, "Game.Player" */
    const struct rt_type_info* base;
    uint32_t iface_count;
    uint32_t field_count;
    const rt_iface_entry* ifaces;
    const rt_field_info* fields;
} rt_type_info;

/* VTable = [ typeInfo, dtor, slot0, slot1, ... ] (a flat pointer array); Object = { vtable }. */
typedef struct rt_object {
    void* const* vtable;
} rt_object;

typedef void (*rt_dtor_fn)(void* self);

/* ---- allocation ---------------------------------------------------------------------------- */
/* The same facts the back end declares (Emitter.bf, RuntimeDeclarations): a new block is noalias, its
   size is the size argument, and rt_alloc / rt_alloc_dbg never return null (out of memory is fatal). */
#if defined(__clang__) || defined(__GNUC__)
#define RT_ALLOC_FN(n) __attribute__((malloc, alloc_size(n)))
#define RT_NONNULL_RET __attribute__((returns_nonnull))
#else
#define RT_ALLOC_FN(n)
#define RT_NONNULL_RET
#endif
RT_ALLOC_FN(1) RT_NONNULL_RET void* rt_alloc(int64_t size, int64_t align);
void  rt_free(void* p);
RT_ALLOC_FN(1) RT_NONNULL_RET void* rt_alloc_dbg(int64_t size, int64_t align, const rt_site* site);
void  rt_free_dbg(void* p, const rt_site* site);
RT_ALLOC_FN(2) void* rt_alloc_with(void* allocator, int64_t size, int64_t align);
void  rt_free_with(void* allocator, void* p);

/* ---- dispatch and casts -------------------------------------------------------------------- */
void* const* rt_itable(void* obj, uint32_t iface_id);
void* rt_dyncast(void* obj, const rt_type_info* target);
void  rt_abstract_call(void);

/* ---- checks and fatal errors --------------------------------------------------------------- */
void rt_fatal(int32_t code, const rt_site* site, const char* msg);
void rt_null(const rt_site* site);
void rt_bounds(const rt_site* site, int64_t index, int64_t length);
void rt_span_range(const rt_site* site, int64_t start, int64_t count, int64_t length);
void rt_freed(const rt_site* site);
extern void* rt_poison_vtable[];

/* ---- program start and exit ---------------------------------------------------------------- */
void    rt_start(int32_t argc, char** argv);
int32_t rt_exit(int32_t code);
/* kind windowed: called by main before rt_start (Console output to the parent's stdout, its console,
   or the debugger's output) */
void    rt_windowed(void);
/* kind library: treadle_init / treadle_shutdown (nested pairs count; the last shutdown runs the leak
   report and returns the number of leaks in Debug) */
void    rt_lib_start(void);
int32_t rt_lib_exit(void);
int32_t rt_leak_report(void);
int32_t rt_arg_count(void);
const char* rt_arg(int32_t i);   /* UTF-8; on Windows made from the wide command line */

/* Main(String[] args): `main` asks for the array before calling Main and frees it afterwards.
   init(obj, utf8, length) runs Core.String.this(StringView) on a zeroed String object. */
typedef void (*rt_string_init_fn)(void* obj, const char* p, int64_t n);
void* rt_args_make(void* const* array_vtable, void* const* string_vtable, int64_t string_size,
                   int64_t string_align, rt_string_init_fn init);
void  rt_args_free(void* args);

/* A dynamically sized Local array was given a negative length (Debug check, node named). */
void rt_local_array_length(const rt_site* site, int64_t length);
/* An array (alloc.array, local.array) was given a negative length or one whose size in bytes does
   not fit 63 bits (both configs, node named). */
void rt_array_length(const rt_site* site, int64_t length, int64_t elem_size);

/* ---- core library intrinsics that must be native ------------------------------------------- */
void  rt_console_write(const char* p, int64_t n);
void  rt_console_write_line(const char* p, int64_t n);
void  rt_console_error_write(const char* p, int64_t n);

/* Files and directories (the core library's File and Directory) */
int32_t rt_file_exists(const char* path);
int32_t rt_dir_exists(const char* path);
int32_t rt_dir_create(const char* path);
int32_t rt_dir_delete(const char* path);
void* rt_dir_open(const char* path);
const char* rt_dir_next(void* handle, int32_t dirs);
void  rt_dir_close(void* handle);
void* rt_fopen(const char* path, const char* mode);   /* UTF-8 path (Windows: _wfopen) */
int32_t rt_remove(const char* path);                 /* UTF-8 path (Windows: _wremove) */
/* Process.Start with an argument list: count NUL-ended arguments in block (no shell) */
void* rt_proc_start_list(const char* path, const char* block, int64_t length, int64_t count, int32_t capture, int32_t* error);
void* rt_memcpy(void* d, const void* s, int64_t n);
void* rt_memset(void* d, int32_t v, int64_t n);
int32_t rt_memcmp(const void* a, const void* b, int64_t n);
uint32_t rt_fnv1a(const char* s);

/* ---- threads (docs/Threads.md; the core library's Thread, Mutex, Condition, WaitEvent, ThreadLocal, ThreadPool and
   Parallel import these). A body is a delegate object { vtable, target, fn }; Start and pool_run own it. */
void*   rt_thread_new(const char* name, int64_t len, int64_t stackSize, void* owner);
int32_t rt_thread_start(void* thread, void* body);
void    rt_thread_join(void* thread);
void    rt_thread_detach(void* thread);
void    rt_thread_free(void* thread);
int32_t rt_thread_alive(void* thread);
int64_t rt_thread_id(void* thread);
const char* rt_thread_name(void* thread, int64_t* len);   /* null thread: the current one */
void*   rt_thread_current(void);
int64_t rt_thread_current_id(void);
void    rt_thread_yield(void);
int32_t rt_cpu_count(void);
void*   rt_mutex_new(void);
void    rt_mutex_free(void* mutex);
void    rt_mutex_lock(void* mutex);
void    rt_mutex_unlock(void* mutex);
int32_t rt_mutex_trylock(void* mutex);
void*   rt_cond_new(void);
void    rt_cond_free(void* cond);
void    rt_cond_wait(void* cond, void* mutex);
int32_t rt_cond_wait_ms(void* cond, void* mutex, int64_t ms);
void    rt_cond_signal(void* cond);
void    rt_cond_broadcast(void* cond);
void*   rt_event_new(int32_t autoReset);
void    rt_event_free(void* event);
void    rt_event_set(void* event);
void    rt_event_reset(void* event);
void    rt_event_wait(void* event);
int32_t rt_event_wait_ms(void* event, int64_t ms);
void*   rt_tls_new(int64_t size);
void    rt_tls_free(void* key);
void*   rt_tls_get(void* key);
void    rt_pool_run(void* body);
void    rt_pool_wait(void);
int32_t rt_pool_size(void);
void    rt_parallel_for(int64_t from, int64_t to, void* body);      /* body(i) for each i in [from, to) */
void    rt_parallel_ranges(int64_t from, int64_t to, void* body);   /* body(lo, hi) for each chunk */

#ifdef __cplusplus
}
#endif
#endif
