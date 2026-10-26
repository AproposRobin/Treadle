/* The C side of the threads fixture (docs/Threads.md 7): the runtime's thread functions called from C, compiled by
   the same clang into the program. 8 threads add 1 to a counter under a mutex 100,000 times each; a Parallel range
   sum over 0..999,999 on the pool; a thread-local slot per thread; a condition and an event. Each body is a delegate
   object made like a Construct ({ vtable, target, fn }), so Debug's check that Start owns a Construct passes. */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

void* rt_alloc(int64_t size, int64_t align);
void rt_free(void* p);
void* rt_thread_new(const char* name, int64_t len, int64_t stackSize, void* owner);
int32_t rt_thread_start(void* thread, void* body);
void rt_thread_join(void* thread);
void rt_thread_free(void* thread);
void* rt_mutex_new(void);
void rt_mutex_free(void* m);
void rt_mutex_lock(void* m);
void rt_mutex_unlock(void* m);
void* rt_cond_new(void);
void rt_cond_free(void* c);
void rt_cond_wait(void* c, void* m);
void rt_cond_signal(void* c);
void* rt_event_new(int32_t autoReset);
void rt_event_free(void* e);
void rt_event_set(void* e);
void rt_event_wait(void* e);
void* rt_tls_new(int64_t size);
void rt_tls_free(void* k);
void* rt_tls_get(void* k);
void rt_parallel_ranges(int64_t from, int64_t to, void* body);
int32_t rt_pool_size(void);

typedef struct { uint32_t id, flags; uint64_t size; uint32_t align; const char* name; const void* base;
                 uint32_t ic, fc; const void* i; const void* f; } ti_t;
static const ti_t body_ti = { 0, 1, 24, 8, "C.Body", NULL, 0, 0, NULL, NULL };
static void body_dtor(void* self) { (void)self; }
static void* const body_vt[2] = { (void*)&body_ti, (void*)body_dtor };

static void* make_delegate(void* fn, void* target)
{
    void** d = (void**)rt_alloc(24, 8);
    d[0] = (void*)body_vt;
    d[1] = target;
    d[2] = fn;
    return d;
}

static void* mutex;
static void* tls;
static long long counter, tls_ok;

static void add_body(void* target)
{
    int i;
    long long* mine = (long long*)rt_tls_get(tls);
    (void)target;
    for (i = 0; i < 100000; i++) {
        rt_mutex_lock(mutex);
        counter++;
        rt_mutex_unlock(mutex);
        (*mine)++;
    }
    rt_mutex_lock(mutex);
    if (*mine == 100000) tls_ok++;
    rt_mutex_unlock(mutex);
}

static volatile long long range_sum;
static void range_body(void* target, int64_t lo, int64_t hi)
{
    long long s = 0;
    int64_t i;
    (void)target;
    for (i = lo; i < hi; i++) s += i;
    __atomic_fetch_add(&range_sum, s, __ATOMIC_SEQ_CST);
}

static void* cond;
static void* done;
static int ready, seen;
static void waiter_body(void* target)
{
    (void)target;
    rt_mutex_lock(mutex);
    while (!ready) rt_cond_wait(cond, mutex);
    seen = 1;
    rt_mutex_unlock(mutex);
    rt_event_set(done);
}

long long c_threads(void)
{
    void* t[8];
    void* w;
    void* range;
    int i;
    mutex = rt_mutex_new();
    tls = rt_tls_new(8);
    for (i = 0; i < 8; i++) {
        t[i] = rt_thread_new("adder", 5, 0, NULL);
        rt_thread_start(t[i], make_delegate((void*)add_body, NULL));
    }
    for (i = 0; i < 8; i++) {
        rt_thread_join(t[i]);
        rt_thread_free(t[i]);
    }
    /* Parallel.ForRange over a Local delegate (not owned: the caller frees it) */
    range = make_delegate((void*)range_body, NULL);
    rt_parallel_ranges(0, 1000000, range);
    /* a condition and an event */
    cond = rt_cond_new();
    done = rt_event_new(0);
    w = rt_thread_new(NULL, 0, 256 * 1024, NULL);
    rt_thread_start(w, make_delegate((void*)waiter_body, NULL));
    rt_mutex_lock(mutex);
    ready = 1;
    rt_cond_signal(cond);
    rt_mutex_unlock(mutex);
    rt_event_wait(done);
    rt_thread_join(w);
    rt_thread_free(w);
    rt_cond_free(cond);
    rt_event_free(done);
    rt_tls_free(tls);
    rt_mutex_free(mutex);
    rt_free(range);
    printf("counter %lld\n", counter);
    printf("thread-local %lld of 8\n", tls_ok);
    printf("condition %d\n", seen);
    printf("range sum %lld\n", (long long)range_sum);
    printf("pool %s\n", rt_pool_size() > 0 ? "yes" : "no");
    return counter;
}
