---
audience: developer
title: Threads
summary: The design of threads in Treadle: the core types (Thread, Mutex, LockGuard, Condition, WaitEvent, ThreadLocal, ThreadPool, Parallel), ownership across threads, the memory model, the runtime functions over Win32 and pthreads, the thread-safe Debug allocator, fatal errors and leaks on worker threads, and the debugger's thread list.
order: 6
---

# Threads

Treadle programs run on several threads with the core library's `Thread` type and its helpers. There is no
garbage collector, no borrow checker and no race detector: the rules are Beef's and C11's, written down here, with
Debug checks where a check costs nothing at run time. This page is the design; the user-facing API is in
[Core-Library.md](Core-Library.md) (Threads), the language rules in [Language.md](Language.md) (4.7 Threads), the
runtime rows in [Compiler.md 6](Compiler.md#6-runtime-abi).

## 1. The API

Every type is a core library type file (`TreadleCore/core/<Type>.treadle`), written in Treadle over runtime
functions it imports with `[Import]` (no compiler intrinsic is needed: the calls are plain C calls, section 4).

| Type | Kind | Members |
|---|---|---|
| `Thread` | class, sealed | `this()`, `this(StringView name)`, `this(StringView name, int stackSize)`; `Start(delegate:void() body) -> bool`, `Join()`, `Detach()`, `Name() -> StringView`, `IsAlive() -> bool`, `Id() -> int`; static `Current() -> Thread` (null on the main thread), `CurrentId() -> int`, `Sleep(int milliseconds)`, `Yield()`, `HardwareThreads() -> int` |
| `Mutex` | class, sealed | `Lock()`, `Unlock()`, `TryLock() -> bool`. Not recursive |
| `LockGuard` | struct with a destructor | `this(Mutex m)` locks, the destructor unlocks; made with a **Local** node, so the lock is held for exactly the Local's region |
| `Condition` | class, sealed | `Wait(Mutex)`, `WaitFor(Mutex, int milliseconds) -> bool` (false: timed out), `Signal()`, `Broadcast()` |
| `WaitEvent` | class, sealed | `this()` (manual reset), `this(bool autoReset)`; `Set()`, `Reset()`, `Wait()`, `WaitFor(int milliseconds) -> bool` |
| `ThreadLocal<T>` | class, generic | `Get() -> T`, `Set(T value)`: one value per thread, `default` until the thread sets it |
| `ThreadPool` | static class | `Run(delegate:void() work)`, `WaitAll()`, `Size() -> int` |
| `Parallel` | static class | `For(int from, int to, delegate:void(int) body)`, `ForRange(int from, int to, delegate:void(int,int) body)`, `ForEach<T>(Span<T> items, delegate:void(T) body)` |

`Atomic` (Language.md 4.3) is the interlocked API and is not repeated: `Atomic.Add` with `seqcst` is Beef's
`Interlocked.Add`.

**Decision: `Event` is `WaitEvent`.** `Core.Event<D>` is already the storage of an event field (Language.md
4.5); a second type named `Event` would make the Node menu and the error texts ambiguous. Beef's own name for
the manual / auto reset event is `WaitEvent`.

**Decision: Start takes the body.** A Thread is made (Construct, with its name and stack size) and then started
with the body (`Start`), which reads as two nodes in the order things happen; `Start` is also where the body's
ownership moves (2). A Thread is started once (a second Start is a fatal error); it is not reused.

**Decision: a `LockGuard` struct, not a Lock flow node pair.** A `Local LockGuard` node over a Mutex is the
graph's `scope` lock: the region that owns the Local is the critical section, drawn as what the Local's region
already is (a Branch arm, a loop body, a Scope), and every way out of it (Return, Break, a Try that returns)
unlocks through the region exit the compiler already emits. A Lock / Unlock pair of flow nodes would need a
check that every path from the Lock reaches the Unlock, which the region rule gives for free. `Lock` / `Unlock`
stay for the cases a region does not fit (hand-over-hand locking).

**Decision: `Current` is the Thread object.** `Thread.Current()` gives the `Thread` that runs the caller (the
runtime keeps it per thread), or null on the main thread and on a pool worker. `CurrentId()` is the system's
thread id, on every thread.

### 1.1 Parallel and the pool

`ThreadPool` has `HardwareThreads() - 1` workers (at least 1), started on the first `Run` or `Parallel` call and
shut down at exit: `rt_exit` waits for the queued work to finish, then joins the workers, before the leak report
(so work queued and never waited for runs, and its objects are not reported as leaks). The workers are named
`Pool 1`, `Pool 2`, ...

`Parallel.For(from, to, body)` calls `body(i)` for every `i` in `[from, to)` across the pool and the calling
thread, and returns when all of them returned. The range is cut into chunks (`max(1, n / (8 * threads))`
indices each) that the threads take with an atomic counter, so uneven work balances. `ForRange` hands a chunk
to the body as `(lo, hi)`, which is what a reduction wants: a local sum over the chunk, one `Atomic.Add` at the
end. `ForEach<T>(span, body)` is `For` over the span's indices with `body(span[i])` (through the internal class
`ParallelForEach<T>`, whose `Run(i)` is bound as the `For` body: a Lambda in a generic function of the core is not
declared yet, Follow-ups).

The calling thread runs chunks of its own job too and waits only for the chunks other threads took; a
`Parallel.For` inside a `Parallel.For` body therefore never deadlocks (with every worker busy, the inner one runs
on the thread that called it). The body is called while the call is running only: a **Local** delegate (a Local
Lambda, by-reference captures included) is the normal thing to pass.

`ThreadPool.Run(work)` queues one call of `work` on a worker and returns at once; the pool owns `work` and
deletes it after it ran. `WaitAll()` waits until everything queued so far ran.

## 2. Ownership across threads

There is no borrow checker. The rules are the single-thread rules ([Language.md 3](Language.md#3-memory-model-and-ownership))
plus these:

* **An object may be made on one thread and deleted on another** (Construct on a worker, Delete on the main
  thread, and the reverse). Whoever deletes it must know no other thread still uses it: Join, a Mutex, a
  Condition or an Atomic store-release / load-acquire pair says so.
* **A Local never crosses a thread.** A Local object lives in its region of one thread's stack; handing its
  reference to another thread that outlives the region is a use after free. The exception is a call that
  returns only when the other threads are done with it: `Parallel.For` / `ForRange` / `ForEach` bodies may be
  Local, and may capture by reference.
* **Thread.Start and ThreadPool.Run own their delegate.** The body must be made with Allocation **construct**: the
  Thread deletes it after the body returns (on the thread itself, so a detached Thread needs nothing more), the
  pool after the work ran. A Local delegate would be freed when its region ends, while the thread may still run
  it. Debug checks this when `Start` / `Run` is called: a delegate that is not a live Construct (a Local, a
  deleted one) is fatal error 12, `fatal: Thread.Start: the delegate must be made with Allocation construct (a Local
  one is freed when its region ends while the thread may still run it)` (the runtime has no site for the calling
  node; under the debugger the stop's first project frame is the Start node). Release does not check; the editor
  makes a Lambda dragged from `Start`'s or `Run`'s input a Construct one. A Check rule (as T2216 for event
  handlers) is a follow-up: it needs Bind, which another branch owns.
* **The body's captures** are copied into the closure when the Lambda node runs (by value) or point at the
  variables (by reference, Local Lambdas only, so never on a Thread). A by-value capture of an object reference
  copies the reference, not the object: the object is shared, and the rules above apply to it.
* **A Thread object** must be Joined or Detached before it is deleted; its destructor Joins a thread that is still
  joinable (Beef's choice is the same: no silent detach, no abort), so `Defer Delete` after `Start` is a join at
  region exit. Deleting a Thread from its own body is a fatal error (it would join itself).
* **Program end.** When Main returns, the pool is drained and joined (1.1); threads the program started and did
  not join are not waited for: the process ends and they stop where they are. In Debug the objects they still
  hold are leaks in the report, each naming its thread (6).

## 3. Memory model

Treadle's memory model is C11's, through LLVM: a **data race** (two threads access the same memory location, at
least one writes, at least one access is not atomic, and nothing orders them) is **undefined behaviour**, in Debug
and in Release. What orders them: Join (everything the thread did happens before Join returns), Start (everything
before Start happens before the body runs), Mutex Unlock -> a later Lock of the same Mutex, Condition and
WaitEvent wakeups (with their Mutex / the Set), the atomic Calls of `Core.Atomic` with their memory orders, and the
pool's and Parallel's own returns (everything a work item did happens before `WaitAll` / `For` returns).

Debug adds **no race detection** in this wave: a race is not reported, and the Debug allocator's checks are only
as good as the order the threads happen to run in. The usual tools work on a Treadle exe (it is native code with
DWARF): ThreadSanitizer would need the runtime and the program built with `-fsanitize=thread`, which is a
follow-up.

The core collections (List, Dictionary, String, ...) are **not** thread-safe, as in Beef: a List several threads
change needs a Mutex around every use (reads included, while any thread writes).

## 4. The runtime

The functions are a block at the end of `tools/runtime/treadle_rt.c` (declared in `treadle_rt.h`), over Win32 on
Windows (no winpthreads: `CreateThread`, `SRWLOCK`, `CONDITION_VARIABLE`, `TlsAlloc`, `SetThreadDescription`) and
pthreads on Linux (glibc 2.34 and later has them in libc; `pthread_setname_np`, `pthread_key_create`). The core's
type files import them with `[Import("treadle_rt", "rt_...")]` on private static functions without a Sheet, so they
are ordinary `ccall`s: no new IR op, no `[Intrinsic]` in `LowerCoreOps.bf`, and the `crt` import set is unchanged.
**Decision:** imports, not intrinsics. Reason: every thread operation is one C call with plain arguments (pointers,
integers, a delegate reference); an intrinsic would only re-spell that call in the compiler, and an import keeps the
whole API in the core's type files (and out of the `crt` set another branch edits).

| Function | What |
|---|---|
| `void* rt_thread_new(const char* name, int64 len, int64 stackSize, void* owner)` | A thread record (not started): its name (copied; empty: `Thread <n>`), the stack size (0: 1 MB), the owning `Thread` object |
| `int32 rt_thread_start(void* t, void* body)` | Starts the thread on the delegate `body` (`fn(target)`); the record owns `body` from now on and deletes it (its destructor, then `rt_free`) when it returns. Debug: `body` must be a live Construct (2) |
| `void rt_thread_join(void* t)`, `void rt_thread_detach(void* t)`, `void rt_thread_free(void* t)` | Join (waits; once), Detach (the thread record frees itself when the thread ends), free (Joins first when still joinable) |
| `int32 rt_thread_alive(void* t)`, `int64 rt_thread_id(void* t)`, `const char* rt_thread_name(void* t, int64* len)` | State, the system's thread id, the name |
| `void* rt_thread_current(void)`, `int64 rt_thread_current_id(void)`, `void rt_thread_yield(void)`, `int32 rt_cpu_count(void)` | The current `Thread` object (null on the main thread), the current system id, a yield, the hardware threads |
| `void* rt_mutex_new(void)`, `rt_mutex_free`, `rt_mutex_lock`, `rt_mutex_unlock`, `int32 rt_mutex_trylock` | A non-recursive mutex (SRWLOCK / pthread_mutex). Debug: Lock by the thread that holds it, Unlock by a thread that does not, and freeing a locked Mutex are fatal errors |
| `void* rt_cond_new(void)`, `rt_cond_free`, `rt_cond_wait(c, m)`, `int32 rt_cond_wait_ms(c, m, ms)`, `rt_cond_signal`, `rt_cond_broadcast` | A condition variable over the Mutex (CONDITION_VARIABLE / pthread_cond with CLOCK_MONOTONIC) |
| `void* rt_event_new(int32 autoReset)`, `rt_event_free`, `rt_event_set`, `rt_event_reset`, `rt_event_wait`, `int32 rt_event_wait_ms` | A manual / auto reset event (a mutex, a condition and a flag: the same code on both systems) |
| `void* rt_tls_new(int64 size)`, `rt_tls_free`, `void* rt_tls_get(void* key)` | A thread-local slot of `size` bytes: `rt_tls_get` gives the calling thread's block, zeroed on its first use; every block is freed with the key (a thread that ends keeps its block until then) |
| `void rt_pool_run(void* work)`, `rt_pool_wait(void)`, `int32 rt_pool_size(void)` | The pool (1.1); `rt_pool_run` owns `work` |
| `void rt_parallel_for(int64 from, int64 to, void* body)`, `void rt_parallel_ranges(int64 from, int64 to, void* body)` | `body(i)` per index, `body(lo, hi)` per chunk |
| `char rt_debug_thread_names[8192]` | Not a function: a line `<system id> <name>` per thread started (Main first), which the editor's debugger reads (6) |

Stacks: the main thread keeps its stack (8 MB in Debug, linked with `--stack`; the 1 MB default in Release), a
new thread gets **1 MB** unless its constructor names a `stackSize`; pool workers get 1 MB. A Debug frame is
several times a Release one (Compiler.md 4, "Stack in Debug"), so deep recursion on a worker wants a larger
stack.

**Thread names** are set by the thread itself before its body runs: `SetThreadDescription` (Windows 10 1607 and
later; looked up with `GetProcAddress`, so an older kernel just has no names) and `pthread_setname_np` (Linux:
the first 15 bytes). Debuggers show them (6). The main thread is `Main` in the runtime's own tables only: naming it
on Linux would rename the process (`ps`, `top`).

**Runtime state that was global.** The shared text buffer of `rt_env_get` / `rt_cwd_get` / `rt_exe_path` /
`rt_machine_name` becomes thread-local (Security-Review.md 21). The leak report, the crash file and the windowed
program's output pipe are written by whichever thread ends the program.

## 5. The Debug allocator

The live list (a doubly linked list through every block's `DbgHeader`), its counters and the quarantine ring are
shared state: two threads in `rt_alloc_dbg` / `rt_free_dbg` at once would break the list. Two ways were weighed:

| Way | Cost on one thread | Cost with threads | Correctness |
|---|---|---|---|
| A lock around the list and the ring | one uncontended atomic exchange and one release store per alloc and per free, and only once a second thread was started (a flag read before) | contention on a short critical section (the block is allocated before it; only evicting from the quarantine frees inside) | simple; a block freed on another thread is unlinked from the one list |
| Per-thread lists merged at exit | nothing extra | none | a block deleted on another thread must reach the owner's list (a lock per list, or a deferred free queue), and the quarantine still needs one ring or per-thread rings; merging at a thread's end needs a lock anyway |

**Decision: the lock**, a small spin lock (atomic exchange, `pause`, then a yield after 64 spins), taken only
when `rt_threads_used` is set (by the first `rt_thread_start` or pool start; before that a program has one
thread). The lock and unlock are macros, not calls: the Debug runtime is compiled at `-O0`, where the first version
(inline functions, a thread-local read per allocation, the thread index packed into the size word) cost the `alloc`
kernel 12% before any thread ran.

Measured on the Ryzen 7 7700 (8 cores, 16 threads), the bench kernels built in Debug (`TREADLE_RUNTIME` pointing at
each runtime), 15 runs each alternating, medians:

| Kernel | Runtime before threads (two copies) | With the lock (one thread: the flag test) | The lock taken on every call |
|---|---|---|---|
| `alloc` (10 million Construct / Delete) | 1,152 / 1,170 ms | 1,180 ms (+1.6%; min +0.8%) | 1,239 ms (+7%) |
| `strings` | 488 / 490 ms | 490 ms (+0.2%) | 500 ms (+2.4%) |

The two copies of the old runtime differ by 1.6%, so a single-threaded program pays nothing measurable; a Debug
program that started threads pays the uncontended lock, about 7% on an allocation-only loop (no budget applies to
that case: the per-thread lists would avoid it at the cost of the cross-thread Delete path, Follow-ups). Release has
no bookkeeping and no lock (`calloc` / `free` are thread-safe).

**Which thread made it.** The `DbgHeader` stays 48 bytes and unchanged in layout: while a block is live its
`freeSite` (null until the Delete) holds the runtime index of the thread that made it (0 = the main thread, 1.. in
start order; written only once a second thread ran), and the leak report names that thread when it is not the main
one:

```
leak: Core.String (56 bytes) made at Cx.ThreadsLeakMain.Leak node la2 on thread "leaker"
```

The names live in a runtime table that outlives the threads (a thread that ended is still named in the report).

## 6. Fatal errors and the debugger

A fatal error on a thread other than the main one adds the thread's name to the line (the main thread's line is
unchanged, so every fixture before threads still matches):

```
fatal: Fatal node at Cx.ThreadsFatalMain.Doom node da2 on thread "doomed"
```

The first thread to reach `rt_fatal` reports and ends the process with exit code 3 (the leak report runs in Debug
as before); a second thread that fails meanwhile waits for the process to end, so two reports never interleave.
The Release fault handlers (an access violation, a heap failure) are process-wide and work on every thread; their
line has no node in Release, as before.

**Debugger.** At each stop the adapter (`TreadleDebug/src/LldbDapAdapter.bf`, `ReadThreads`) reads the stopped
thread's stack, then lldb-dap's `threads` list, and names each thread from the runtime's table
`rt_debug_thread_names` (one `evaluate`; lldb's thread id is the system's), else by lldb's own name (lldb reads the
thread description on Windows and the 15-byte `comm` on Linux once it has seen the thread), else `Thread <id>`.
Right after a thread started, lldb-dap may answer `threads` without it although it is the one that stopped: the
adapter asks again (four times, 50 ms apart) and otherwise adds the stopped thread itself. `DebugSession.Threads`
holds the list, `SelectThread(id)` makes another thread current: the adapter reads its stack and reports it as a
stop on that thread (the program does not run), so Call Stack, Locals and the canvas follow it.

**Decision: rows at the top of Call Stack, not a panel of its own.** With more than one thread, Call Stack starts with
a **Threads (n)** header and one row per thread (`Main`, `worker 2`, `Pool 1`, ...), the current one selected; a
click selects a thread. Reason: a thread is chosen in order to see its stack, so the two belong in one panel; a new
dockable panel would need its own layout slot and View menu entry for a list that is usually short. Continue
resumes every thread; the steps step the current thread (lldb lets the others run meanwhile, as native debuggers
do). A breakpoint hit on any thread stops the whole program on that thread.

## 7. Tests

* Back end fixture `threads` (`TreadleBackend/fixtures/threads.tir` + `threads.c`): a C self check compiled by the
  same clang into a program: 8 threads made with `rt_thread_new` / `rt_thread_start` each add 1 to a counter
  under `rt_mutex_*` 100,000 times (800000), each also counting in a thread-local slot (8 of 8 right), a pool range sum
  over 0..999,999 (499999500000), a condition wakes a waiter that sets an event (Debug and Release).
* Core fixtures (`TreadleCompiler/fixtures/core/threads-*.treadle`, run by the `core` self test in Debug, leak-free,
  and Release): `threads-basic` (4 named threads squaring into an array, Join, `Name`, `IsAlive`, `Current`,
  `CurrentName`), `threads-mutex` (8 threads, a LockGuard in the loop body, a counter of exactly 1,000,000; a
  ThreadLocal<int> per thread; TryLock), `threads-cond` (a producer and a consumer over a Queue<int> with a Mutex
  and a Condition, a WaitEvent to finish: 500500 from 1000 values), `threads-parallelfor` (10 million indices, each
  mixed by 8 LCG rounds: the plain loop, ForRange and For over 64 blocks agree; ForEach over 1000 ints; the timings
  on stderr), `threads-leak` (Debug: the String a worker leaked is reported with its node and thread, exit 1),
  `threads-fatal` (a Fatal on a worker: the line names the thread, exit 3).
* `threads-parallelfor` in Release on the Ryzen 7 7700 (8 cores, 16 hardware threads, 15 pool workers), 7 runs:
  the plain loop 22.7-23.3 ms, ForRange 3.7 ms (6.1-6.3x; the first Parallel call starts the pool), For over 64
  blocks 3.3 ms (6.8-7.0x).
* `debug` self test, threads part (`TreadleEditor/src/SelfTestDebugThreads.bf`): a breakpoint on a node of the
  Lambda that threads-basic's workers run stops on a worker thread named `worker <n>` (current in the session's
  thread list), on the Lambda's node; selecting the other threads in turn finds the main one, named `Main`, whose
  stack is `Cx.ThreadsBasicMain.Main` waiting in Join, without the program running on.

## 8. Not in this wave

* Race detection (ThreadSanitizer builds), a Check rule for a Local delegate handed to `Start` / `Run` (2), a
  `Lock` region node, reader-writer locks, semaphores, thread priorities and affinity, `Task<T>` results from
  the pool, cancellation, and a thread-safe allocator interface for `IAllocator` users (a custom allocator must
  lock by itself when threads share it).
* C code a C import set calls that starts threads of its own and calls back into Treadle: the Debug allocator's
  lock is taken only once Treadle started a thread, so such a program must start one Treadle thread first (or
  call `ThreadPool.Size()`, which starts the pool).
