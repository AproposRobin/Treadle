---
audience: developer
title: GPU compute
summary: GPU compute in Treadle (experimental, NVIDIA only): [Kernel] functions and their subset, device-resident buffers, pinned memory and streams, shared memory and barriers, the device-side error record, the transcendental Math functions on the GPU, the CPU path on the thread pool, how it is compiled, the fixtures and their numbers on the RTX 4060 Ti, and what is still missing (Vulkan / SPIR-V, the editor UI).
order: 16
---

# GPU compute

Treadle can run a function on an NVIDIA GPU: a static function marked **`[Kernel]`** runs once per index of a
dispatch, on the GPU through the CUDA driver (loaded at run time, no toolkit) or on the CPU, over the thread pool,
with every Debug check. It is **experimental and NVIDIA only** (branch `wt/gpu2` on top of the spike `wt/gpu`):
nothing here is in a release, the editor has no UI for it, and the language may change. Section 9 says what is
still missing before it can ship; section 11 keeps the design the spike tested.

## 1. What is usable on NVIDIA today

* **Kernels**: a `[Kernel]` function (`attr Kernel` on a static function) with Span, number, bool, vector and struct
  inputs, checked against the kernel subset at Validate (section 2). It reads `Kernel.Index()`, and in blocks
  `Kernel.BlockIndex()`, `Kernel.ThreadInBlock()`, `Kernel.BlockSize()`.
* **Device-resident data**: a `GpuBuffer<T>` stays on the GPU across dispatches; nothing comes back until a
  `Download`. `Construct GpuBuffer<T>(count)` makes a zeroed buffer without a copy, `GpuBuffer.Upload(span)` refills
  one (section 3).
* **Pinned host memory and streams**: `PinnedBuffer<T>` is page-locked host memory (`cuMemHostAlloc`); `GpuStream`
  queues `UploadAsync`, `Gpu.DispatchAsync` and `DownloadAsync`, which run in order beside the host; `Sync` waits.
* **Shared memory and barriers**: `Kernel.Shared<T>(count)` (static, per block) and `Kernel.Barrier()`, with the
  block size chosen on the dispatch (`set block <n>`, 256 by default).
* **Errors on the GPU name the node**: a failed check in a kernel stops the program at the next wait with
  `fatal: GPU: <message> at <Type.Function> node <id> (in the kernel <Type.Function>)`, exit code 3 (section 5).
* **Math**: Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Exp, Log and Pow work in kernels, in float and double (section 6),
  besides Sqrt, Abs, Floor, Ceil, Min, Max and arithmetic.
* **A CPU path that is the same program**: `Kernel.RunCpu`, and `Gpu.Dispatch` without a GPU (or with
  `TREADLE_GPU=cpu`), run the kernel on the CPU, split over the thread pool; kernels that use Shared or Barrier run
  in whole blocks there too, each block's threads as fibers (section 4).
* **Linux**: the same code loads `libcuda.so.1`; under WSL2 the RTX 4060 Ti is passed through
  (`/usr/lib/wsl/lib`), so the fixtures run on the GPU there too, and their CPU path with `TREADLE_GPU=cpu`
  (section 10).

## 2. Kernels

```
function k1 Saxpy
	static
	attr Kernel
param x Span<float>
param y Span<float>
param a float
sheet body
  Entry -> At(x, Kernel.Index()) -> At(y, Kernel.Index()) -> y.SetAt(Kernel.Index(), a * xv + yv) -> Return
```

| Core | What |
|---|---|
| `Kernel.Index()` (pure) | the index this run works on, `0 ..< count`; on the GPU `ctaid.x * ntid.x + tid.x` |
| `Kernel.BlockIndex()`, `Kernel.ThreadInBlock()`, `Kernel.BlockSize()` (pure) | the block of this run, its place in the block, the threads per block (`Index / BlockSize`, `Index % BlockSize` on the CPU; `ctaid.x`, `tid.x`, `ntid.x` on the GPU) |
| `Kernel.Shared<T>(count)` (`set type <T>`, `count` typed on the node) `-> Span<T>` | memory shared by the runs of one block, one array per node: a static `addrspace(3)` array (CUDA's `__shared__`) on the GPU, undefined at the block's start; zeroed per block on the CPU; at most 48 KB per block |
| `Kernel.Barrier()` | every run of the block waits here until all have reached it; all must reach the same Barriers |

* **Span access**: `Span<T>.At(index)` and `Span<T>.SetAt(index, value)` check the index in every config (a fatal
  error naming the node on the CPU, the error record on the GPU). Get [ ] on a span works too, unchecked
  (Follow-ups.md).
* **Whole blocks**: a kernel that calls Shared or Barrier (itself or through a function it calls; Check finds it)
  runs in whole blocks: its dispatch count must be a multiple of the block size, else the dispatch is a fatal error
  (`... must be a multiple of the block size`), on the GPU and on the CPU alike.
* **The rules** (Check, `TreadleCompiler/src/Kernel.bf`), codes **T2340-T2348**:

| Code | Refused |
|---|---|
| T2340 | the kernel's header: not static, generic, returns a value, out / ref / in inputs, more than 8 inputs, an input named `count`, an input of a type the GPU has no form of, an overload of another kernel, virtual / imported / exported |
| T2341 | Construct, Local, Delete, Defer, Defer Delete; Lambda, Bind Function, Invoke; the Gate family (hidden static state) |
| T2342 | a pin whose type is an object, an array, a String / StringView, a delegate or a function pointer |
| T2343 | a call of a C function, a virtual or interface call, a function of an object, a core type other than Math, Kernel, Atomic, Vector, Pointer and the core structs (Span, Vec3, Mat4, ...) |
| T2344 | a Get or Set of a static field (the GPU module has its own copy of the globals) |
| T2345 | recursion |
| T2346 | a Math function without GPU code: the transcendental functions on vectors, and Sinh, Cosh, Tanh, Exp2, Log2, Log10, Cbrt, Hypot, SinCos should the core add them |
| T2347 | a dispatch without `set kernel`, naming a function that is not a kernel, or inside a kernel; `set block` outside 1-1024 |
| T2348 | Kernel.Shared without `set type`, of a type the GPU has no form of, or with a count that is not a number typed on the node |

  A function the kernel calls obeys the same rules; a fault inside it is reported at the call, naming the
  function. A Fatal node is allowed: on the GPU it fills the error record.

## 3. Dispatch, buffers, streams

| Core | What |
|---|---|
| `Kernel.RunCpu` (`set kernel <Type.Function>`, `set block <n>`, inputs `count` and the kernel's) | runs the kernel for every index on the CPU, over the thread pool (`TREADLE_KERNEL_THREADS=1`: the calling thread only), Debug checks included |
| `Gpu.Dispatch` (the same; a Span<T> input takes a `GpuBuffer<T>`) `-> bool` | queues the launch on the GPU and returns (true), or runs the CPU path (false, no GPU) |
| `Gpu.DispatchAsync` (`stream` first) `-> bool` | the same, queued on a `GpuStream` |
| `Gpu.Upload<T>(Span<T>) -> GpuBuffer<T>`, `Construct GpuBuffer<T>(Span<T>)` | device memory with a copy (host memory without a GPU); Delete frees it |
| `Construct GpuBuffer<T>(int count)` (`set ctor (int)`) | `count` zeroed elements, no copy |
| `GpuBuffer<T>.Upload(data)`, `.Download(into)`, `.Count()`; `Gpu.Download<T>(buffer, into)` | copies into the buffer / back (as many elements as both have; both wait for the launches before them) |
| `GpuBuffer<T>.UploadAsync(data, stream)`, `.DownloadAsync(into, stream)` | queued copies; the host span must stay as it is until the stream's Sync |
| `Construct GpuStream`, `GpuStream.Sync()`, Delete | a CUDA stream (`CU_STREAM_NON_BLOCKING`); Delete waits for it first. Without a GPU everything runs at once, in order |
| `Construct PinnedBuffer<T>(int count)`, `.AsSpan()`, `.Count()`, Delete | page-locked host memory (`cuMemHostAlloc`), zeroed; uploads and downloads from its span run at the bus's speed and async ones beside the host |
| `Gpu.Sync()`, `Gpu.IsAvailable()`, `Gpu.PrintInfo()` | waits for every launch; whether a GPU, its driver and the PTX are usable; one line on stderr naming the device or why there is none |

`TREADLE_GPU=cpu` in the environment makes `IsAvailable` false: buffers live in host memory and every dispatch runs
the CPU path. That is how the no-GPU case is tested on a machine that has one. A generic function cannot be called
with its type given explicitly (`Gpu.Alloc<float>(n)` would not bind: T2067), so a zeroed buffer is a Construct.

## 4. The CPU path

* **Pooled.** Lower writes, per kernel, a chunk function `$kcpuR_<Name>(args, lo, hi, block)` (Kernel.SetBlockSize
  once, then for each index Kernel.SetIndex and the kernel, its inputs read from the argument addresses) and
  `$kcpu_<Name>(count, block, inputs)`, which hands it to `rt_kernel_cpu`: the range is cut into Parallel.ForRange's
  chunks over the pool, the calling thread taking chunks too (below 4,096 indices, or with
  `TREADLE_KERNEL_THREADS=1`, all on the calling thread).
* **The index is a thread-local of the program** (`@treadle.kernel.index`, `@treadle.kernel.block`, linkonce_odr in
  each unit that uses them), reached through `llvm.threadlocal.address` so that its address is computed once per
  chunk; the runtime never touches it.
* **Blocks on fibers.** A kernel that uses Shared or Barrier runs block by block (blocks over the pool). The threads
  of a block are fibers of the OS thread (Win32 fibers; on Linux a small x86-64 stack switch in `treadle_gpu.c`),
  256 KB of stack each, made once per thread and reused. `Kernel.Barrier()` switches back to the block's scheduler,
  which resumes the fibers in turn, so all have reached the barrier before any goes on; a fiber keeps its own index
  on its stack across the switch. `Kernel.Shared` gives each node its zeroed memory per block from a 48 KB arena per
  thread. The cost is the switches: fine for a reduction, slow for a tiled matrix multiply (section 8).
* **Debug checks** are the kernel's own: a failed one is a fatal error on the thread that ran it (`... on thread
  "Pool 3"`).

## 5. Errors on the GPU

A check that fails in a kernel (a Fatal node, Span.At / SetAt, a null or a deleted object) writes the **device-side
error record**, one `int4` (`@treadle_gpu_error`: kind, site, two values), with a compare-and-swap so that the first
failure of the program wins, and the thread exits (PTX `exit`: a trap would make the CUDA context unusable, the
record included). The host reads the record after every wait (`Gpu.Sync`, a stream's `Sync`, a `Download`) and
stops the program:

```
fatal: GPU: Span.SetAt: the index is out of range at Core.Span.SetAt node e05 (in the kernel Cx.GpuErrorMain.Fill)
```

exit code 3, the same text the CPU path gives for the same check (`Span.SetAt: the index is out of range` and
`fatal: Fatal node at Core.Span.SetAt node e05`), plus the kernel launched since the last wait. The site is the
number of the check's `@.site.N` (on the GPU each site is that i32); the `__gpu` unit holds the host's table of the
sites (place, node, and a Fatal node's message) and the kernels' names. Kinds: null, index (index and length), span
range, deleted object, Fatal node, a local array's length, abstract call. Driver errors are still fatal errors with
the driver's text (`fatal: GPU: cuMemAlloc failed: ...`).

## 6. Math on the GPU

The vendored clang (23.1.3) compiles NVPTX but has **no libdevice** (CUDA's bitcode math library, part of the CUDA
toolkit): `llvm.sin` and `llvm.cos` select nothing (`Cannot select: fsin`), and `llvm.exp`, `llvm.log`,
`llvm.tan`, `llvm.pow` and the rest become calls of libdevice functions it cannot provide; only `llvm.sqrt`,
`llvm.exp2` (ex2.approx) and the rounding functions have instructions. So the transcendental functions are
Treadle's own: **`tools/runtime/treadle_gpu_math.c`**, plain C without headers, compiled by the same clang for
nvptx64 to bitcode at Build (`__gpu_math.bc`, cached) and linked into the kernels' module with
`-mlink-builtin-bitcode` (only what a kernel calls is kept, and inlined) when the module calls one. The GPU module
calls `treadle_gpu_<name>f` / `treadle_gpu_<name>` where the CPU code calls `llvm.<name>.f32 / .f64`.

| Function | float | double |
|---|---|---|
| Sin, Cos | Cody-Waite reduction in float (FMA, three parts; through double above 105,615), minimax polynomials | reduction with FMA (three parts of pi/2), Taylor to x^21 |
| Tan | through double | sin / cos of the reduced argument |
| Exp | reduction by ln 2, Taylor to r^7, 2^k in two steps | Taylor to r^13 |
| Log | 2 atanh((m - 1) / (m + 1)) | the same, to s^25 |
| Pow, Atan, Atan2, Asin, Acos | through double | pow = exp(y log x); atan by reduction to tan(pi/12) and its series; asin / acos through atan2 |

Accuracy against the C library on the host (2,000,000 arguments each over `-50 ..< 50` and the domains): float
within 2 ulp (Sin, Cos, Log; the rest 1); double within 1-4 ulp except Pow, up to about 130 ulp for results near
1e±10 (the error of exp(y log x) grows with |y log x|). The `gpu-math` fixture compares the GPU with the CPU path
(the C library) over 262,144 arguments per function: the largest |cpu - gpu| / max(|cpu|, 1) is 1.2e-7 in float
and 4.2e-15 in double. Limits: no Payne-Hanek reduction (the trigonometric functions lose accuracy above about
|x| = 1e9); the functions on vectors are refused (T2346).

## 7. How it is compiled

* **Front end** (`TreadleCompiler/src/Kernel.bf`, `KernelLower.bf`): Declare marks the member
  (`KernelEntry = tk_<Owner>_<Name>`); Bind gives a dispatch node the kernel's inputs (and Kernel.Shared its type);
  Check applies section 2 and marks kernels that run in blocks. Lower writes the kernel as usual with the flag
  `kernel "<entry>"` and next to it `$kcpuR_`, `$kcpu_` (section 4) and `$kgpu_<Name>(count, block, stream,
  inputs) -> bool`, which passes each input's address (a buffer's `mSpan` for a span), the block size, the stream's
  handle and the flags to `rt_gpu_launch`, and runs `$kcpu_` over the host buffers when it returns 0.
  `Kernel.Shared` lowers to the op `intrinsic kernel.shared` (a T* to the node's own memory) made a Span.
* **Back end** (`TreadleBackend/src/Emit/EmitKernel.bf`): a second UnitEmitter in kernel mode writes the kernels and
  everything they call into one NVPTX module; a `ptx_kernel` entry per kernel; the Core.Kernel functions as the PTX
  special registers and `llvm.nvvm.barrier0` (their CPU forms over the thread-locals come from the same hook); the
  runtime's check entry points as the error record; every function `convergent`; the Math intrinsics renamed to
  treadle_gpu_math.c's. IEEE arithmetic, no contraction, so plain arithmetic matches the CPU bit for bit.
* **Driver** (`EmitKernelBuild.bf`): `clang --target=nvptx64-nvidia-cuda -march=sm_75 -O3 -S` on
  `build/<Config>/__gpu_kernels.nvptx.ll` (kept; skipped when neither its text nor the math library changed) gives
  `__gpu_kernels.ptx`; a unit `__gpu` holds it, the site table and the kernels' names, registered by a static
  constructor (`rt_gpu_register`). A program without kernels gets none of it.
* **Runtime** (`tools/runtime/treadle_gpu.c`, appended to `treadle_rt.c`): the driver API through `LoadLibraryA` /
  `dlopen`, device 0's primary context, the module through `cuModuleLoadDataEx` (the driver JIT-compiles the PTX for
  the GPU it runs on; GPUs older than sm_75 are refused), launches with the dispatch's block size on the default
  stream or a GpuStream, the error record, pinned memory and streams; and the CPU path (`rt_kernel_cpu`, the
  fibers, `rt_kernel_shared`, `rt_kernel_barrier`).

## 8. Results (RTX 4060 Ti, 2026-10-25)

Release builds, wall clock with Stopwatch; RTX 4060 Ti (sm_89), CUDA driver API 13.5, PTX `.version 6.3 .target
sm_75`. The fixtures (TreadleCompiler/fixtures/core, the `core` self test) run small sizes in Debug and the sizes
below in Release (an argument), with the GPU and with `TREADLE_GPU=cpu`. Self tests on Windows (2026-10-25):
`TREADLE_SELFTEST=smoke,codec,backend,frontend,core,quit` passes in the Debug and the Release editor (failures 0),
and `core,quit` with `TREADLE_GPU=cpu` in both (failures 0).

* **Resident data** (`gpu-resident`: y = 0.5 x + y, 100 dispatches over 16,777,216 floats, one download):

| GPU, 100 dispatches + Sync | upload x (pageable) + y (pinned) | one download | stream path (async upload, 100 DispatchAsync, async download) | Kernel.RunCpu (pool) | float8 loop (one thread) |
|---|---|---|---|---|---|
| 84-91 ms | 14.2-15.8 ms | 7.5-10.9 ms | 94-101 ms | 330-384 ms | 344-479 ms |

  0.85 ms per dispatch on the GPU (the kernel moves 201 MB: about 235 GB/s) against 3.3 ms on the CPU, which is
  memory bound (the pool and one float8 thread are equal). With the copies the GPU path is about 110 ms against
  340 ms: resident data is what makes the GPU worth it (the spike's single dispatch with copies was 21 ms against 4).

* **The CPU path on the pool** (16M saxpy per dispatch, from the same fixture): pooled 3.3 ms, one thread
  (`TREADLE_KERNEL_THREADS=1`) 6.9-8.2 ms (a scalar loop: Span.At's checks keep it from vectorising; the spike's
  one-thread loop with a plain static index was 3.4-4.4 ms, but a static index cannot serve the pool). Debug: the
  1M gpu-saxpy RunCpu went from 15 ms to 2.3 ms.

* **Shared memory** (`gpu-shared`):

| | GPU | Kernel.RunCpu (blocks on fibers) | CPU version |
|---|---|---|---|
| block reduction, sum of 16,777,216 floats (65,536 threads x 256 elements, a tree in shared memory) | 0.66-0.76 ms | 10-20 ms | 9.6-10.3 ms (a double loop, one thread) |
| tiled matrix multiply 1024 x 1024 (16 x 16 tiles) | 1.55-1.63 ms (about 1.3 TFLOP/s) | 0.89-1.01 s | 62 ms (float8, one thread, same order of additions) |

  The GPU and CPU results agree (reduction: 1e-4 relative against the double sum; matrix: exact).

* **Errors** (`gpu-error`): `fatal: GPU: Span.SetAt: the index is out of range at Core.Span.SetAt node e05 (in the
  kernel Cx.GpuErrorMain.Fill)`, exit 3, where the spike printed `CUDA_ERROR_LAUNCH_FAILED (719)`.

* **Math** (`gpu-math`): section 6.

## 9. What is still missing

* **Portability: Vulkan / SPIR-V.** NVPTX runs on NVIDIA only. The Vulkan path needs a **second LLVM with the SPIR-V
  target** (the vendored clang 23.1.3 has aarch64, arm, nvptx, thumb and x86 only), a resource model in the emitter
  (descriptor-bound buffers instead of raw pointers, workgroup memory for Shared) and about 1,500 lines of Vulkan
  host code; the math library would compile for it unchanged. No user-facing GPU feature before it.
* **Editor UI** (not built): no kernel Sheet colour, no Dispatch node in the Node menu (a Call of `Gpu.Dispatch`
  with `set kernel` typed in the file), no UI for `set kernel`, `set block` and Shared's `set type`; the Node menu
  does not hide what a kernel refuses.
* One module per program; no events or graph capture; a GpuStream's async copies from pageable memory are staged
  by the driver; atomics on GPU memory are allowed but untested; vector transcendentals; Payne-Hanek reduction;
  a native Linux install (not WSL) has not been tried.
* The error record names the check's own node (a core function's for Span.At) and the kernel; the call chain in
  between is not recorded.

## 10. Linux

The runtime loads `libcuda.so.1` (WSL's `/usr/lib/wsl/lib` included) and runs the block fibers with its own x86-64
stack switch. The PTX is compiled at Build by the system clang (`/usr/lib/llvm-22`, nvptx64 target, the math
library linked). Its default PTX ISA is 4.2, which refuses sm_75, so the driver gives `+ptx63` explicitly (the
same PTX as on Windows: `.version 6.3 .target sm_75`). Under WSL2 on this machine the GPU is passed through, so
the 2026-10-25 runs went further than the planned compile-only check:

* `scripts/build-linux.sh both smoke,codec,backend,frontend,core,quit`: Debug 561 checks, Release 561, failures 0,
  the GPU fixtures on the GPU (`GPU: NVIDIA GeForce RTX 4060 Ti (sm_89), CUDA driver API 13.5`); with
  `TREADLE_GPU=cpu`, `core,quit`: Debug 111, Release 111, failures 0 (the CPU path, the fibers included).
* gpu-shared at full size: reduction GPU 0.87 ms, RunCpu on fibers 33 ms, CPU loop 9.7 ms; matmul 1024 GPU
  1.52 ms, RunCpu on fibers 0.54 s (the stack switch is cheaper than Win32 fibers), float8 66 ms. gpu-math and
  gpu-error give the Windows results and text.

## 11. The design this spike tested

The feasibility note before the spike chose NVPTX through the CUDA driver API (the target is in the vendored
clang 23.1.3; it lists aarch64, arm, nvptx / nvptx64, thumb, x86 and x86-64, no SPIR-V and no AMDGPU) over SPIR-V /
Vulkan (needs a second LLVM and a resource model), HIP (not in our clang, not on the owner's iGPU) and OpenCL
(NVIDIA's does not take SPIR-V). The machine: RTX 4060 Ti (Ada, sm_89) and an AMD Radeon iGPU, `vulkan-1.dll`,
`nvcuda.dll`, `OpenCL.dll`, `amdhip64_6.dll`, the Vulkan SDK 1.4.357, no CUDA toolkit. Decisions that held:

* **One front end.** Bind, Check, Lower and the Sheet IR are shared; only the emitter differs (address spaces, the
  thread index, the entry). A second IR would double the compiler.
* **Explicit copies.** Host and device memory are separate; data moves through Upload and Download only.
* **A CPU fallback that is the same program.** Every kernel is also an ordinary function; Debug runs it with every
  check and breakpoints, which is where most kernel bugs (index bugs) are found.
* **Graphics** (vertex and fragment shaders from Sheets) is a different product and not in scope.
