---
audience: developer
title: GPU compute
summary: Feasibility and a first design for SIMT kernels in Treadle: what a kernel Sheet is, the back-end paths (NVPTX, SPIR-V/Vulkan, OpenCL), the recommended first path, buffers and dispatch, the CPU fallback, the editor, the saxpy fixture, risks and effort. No promise; a design spike comes first.
order: 16
---

# GPU compute (feasibility and design)

Treadle may run parts of a program on the GPU (SIMT: many threads running one function over an index range) if
the language can do it well. This page says what that would mean, which path to try first, and what it costs.
It is a design for a **spike**, not a commitment; it follows SIMD ([SIMD-and-Vectors.md](SIMD-and-Vectors.md))
and threads ([Threads.md](Threads.md)).

## 1. What a kernel is

* A **kernel** is a static function marked **`[Kernel]`** (`attr Kernel`). Its Sheet runs once per index of a
  dispatch. Its inputs are `Span<T>` (device buffers), numbers, vectors and structs of those; it returns nothing.
* Intrinsics in `Core.Gpu` (value nodes, valid only in a kernel Sheet): `GlobalIndex()`, `LocalIndex()`,
  `GroupIndex()`, `GroupSize()`, `GlobalCount()`; `Barrier()` (a flow Call, the work group); later group-shared
  memory (`[GroupShared]` locals).
* **Allowed:** arithmetic, vectors, `Core.Math` (the functions the GPU back end has), locals, Branch, loops,
  Select, Make/Break, Index / `Arrays.Set` on the span inputs, `Core.Atomic` on span elements, Calls of other
  static functions that obey the same rules (compiled into the kernel module), constants.
* **Refused** (Check, T2320-T2329, reserved): Construct, Local of a class, Delete, Defer of a Delete; virtual,
  interface, delegate and function pointer calls; String and the collections; C calls; static field Sets;
  recursion; Box; `ref` / `out` parameters. A Fatal node becomes a trap (the dispatch reports an error).
* **Decision:** the same front end (Bind, Check, Lower, Sheet IR) compiles a kernel; only the emitter changes
  (address spaces, the thread-index intrinsics, the kernel calling convention). Reason: one language, one
  checker; a second IR would double the compiler.

## 2. Back-end paths

`clang -print-targets` of the vendored llvm-mingw (clang 23.1.3), 2026-10-25: aarch64, arm, **nvptx /
nvptx64**, thumb, x86, x86-64. **No SPIR-V, no AMDGPU.**

| Path | Toolchain | Host runtime | Portability | Fit for Treadle's IR |
|---|---|---|---|---|
| (i) SPIR-V -> Vulkan compute | a second LLVM with the SPIRV target (build it, or a pinned official release; not in our clang) | Vulkan via an imported C API; about 1,500 lines of instance, device, pipeline, descriptor and memory setup | NVIDIA, AMD, Intel, Linux; macOS via MoltenVK | Vulkan needs Shader-capability, logical-addressing SPIR-V; LLVM's backend reaches it through HLSL-style resource intrinsics, not plain pointers (PhysicalStorageBuffer pointers are partial). The emitter would need a resource model of its own |
| (ii) NVPTX -> CUDA driver API | **already in our clang**; no CUDA toolkit needed (the driver JIT-compiles PTX) | `nvcuda.dll` / `libcuda.so` loaded at run time: cuInit, cuModuleLoadData, cuMemAlloc, cuMemcpy, cuLaunchKernel (about 300 lines of C) | NVIDIA only | Plain LLVM IR with `addrspace(1)` pointers and `ptx_kernel`; a hand-written saxpy `.ll` compiled to PTX (`.target sm_75`) with this clang on 2026-10-25 |
| (ii') AMDGPU -> HIP | not in our clang | `amdhip64` | AMD (discrete; the owner's Radeon iGPU is not a supported HIP target on Windows) | as NVPTX |
| (iii) OpenCL via SPIR-V | as (i) | `OpenCL.dll` | NVIDIA's OpenCL does not take SPIR-V (`clCreateProgramWithIL`), so not on the owner's machine | as (i) |

**The owner's machine** (read 2026-10-25): NVIDIA GeForce RTX 4060 Ti (Ada, sm_89, driver 32.0.16.2101) and an
AMD Radeon iGPU; `vulkan-1.dll`, `nvcuda.dll`, `OpenCL.dll` and `amdhip64_6.dll` present; Vulkan SDK 1.4.357
installed (`spirv-val`, `glslangValidator`); no CUDA toolkit.

**Recommendation: the spike uses (ii), NVPTX with the CUDA driver API**, and keeps the kernel rules and the host
API back-end neutral so that (i) Vulkan follows before anything ships to users. Reasons: the target is already in
the vendored clang (nothing to build or pin), Treadle's Sheet IR maps onto it directly (pointers stay pointers),
the owner's GPU runs it, the driver loads PTX without an SDK, and failures are debuggable on the CPU (section 4).
The cost is portability: NVIDIA only, which a game cannot accept, so Vulkan is the second step and the real
product decision (section 7).

## 3. Memory and dispatch

* **No implicit sharing.** Host memory and device memory are separate; data moves only through explicit nodes.
* `Core.Gpu.Device` (class): `Open() -> Result<Device, GpuError>` (no GPU or no driver is an error value, not a
  crash), `Name()`, `Wait()`; `Delete` releases the context.
* `Core.Gpu.Buffer<T>` (class, `T` a number, vector or struct of those): `this(Device, int count)`,
  `Count`, `Upload(Span<T>)`, `Download(Span<T> into)` (waits for earlier dispatches), destructor frees the
  device memory. A kernel's `Span<T>` input takes a `Buffer<T>` at the dispatch.
* **Dispatch** (a flow node, subject: the kernel): `in`, `device`, `count`, `groupSize` (default 256), one input
  per kernel parameter -> `then`, `error`. It enqueues on the device's stream; Download or `Wait` synchronises.
  Lower makes a `ccall` of `rt_gpu_launch(module, kernelName, args, count, groupSize)`.
* The PTX of a program's kernels is one module, compiled at build time and embedded as a constant; the runtime
  (`rt_gpu_*`, Windows `LoadLibrary`, Linux `dlopen`, including WSL's `/usr/lib/wsl/lib/libcuda.so`) loads it
  on the first Dispatch. A program without kernels links none of it.

## 4. CPU fallback and Debug

Every kernel is **also** compiled for the CPU as an ordinary function plus a loop over the index (split over the
thread pool once Threads lands). Dispatch runs the CPU version when `Device.Open` failed or the config says
`gpu cpu` (a config key: `auto` default, `cpu`, `gpu`). **Debug runs kernels on the CPU** with every Debug check
(spans' bounds, lane checks) naming the node, and breakpoints work there; Release uses the GPU. Reason: the
graph debugger cannot stop inside a GPU thread, and most kernel bugs are index bugs the CPU checks catch.

Results may differ in the last bits (GPU `sqrt`/division precision, transcendental approximations); the emitter
asks for IEEE `.rn` arithmetic and no contraction (the saxpy PTX above is `mul.rn.f32` + `add.rn.f32`), so
plain arithmetic matches exactly.

## 5. Editor

* A kernel Sheet's header and tab are **orange** ("runs on the GPU, once per index"); its Entry lists the
  inputs and the Node menu hides what 1. refuses (shown greyed with the reason when searched).
* The Dispatch node is a Calls-family node with a GPU icon; its subtitle names the kernel.
* What stays CPU-only: everything outside kernel Sheets, all allocation, all C calls, the debugger.

## 6. Minimal fixture: saxpy

`gpusaxpy`: `y = a * x + y` over 16,777,216 floats. Main makes x and y, opens the device, uploads, dispatches,
downloads, and compares with the CPU fallback run on copies (exact equality: no contraction on either side), then
prints the checksum and both timings. Without an NVIDIA GPU the fixture still passes on the CPU path and says so.

## 7. Risks and effort

* **Portability** (the big one): NVPTX is NVIDIA only. A Vulkan back end is a project of its own (resource
  model in the emitter, the SPIR-V target in a second LLVM, the Vulkan host code).
* **Math functions:** `sin`, `exp` and friends on NVPTX come from libdevice (part of the CUDA toolkit, which we do
  not ship); the spike uses `sqrt` and arithmetic only, later the core's own polynomial versions (the same ones
  SIMD-and-Vectors.md section 5, question 3, proposes) work on both targets.
* **Driver JIT:** PTX built for `sm_75` runs on Turing and newer; older cards are out. The JIT costs tens of
  milliseconds at the first Dispatch (the driver caches it).
* **Testing:** the GPU path runs only on machines with an NVIDIA GPU; the package gate keeps the CPU path.

| Step | Days |
|---|---|
| Spike: NVPTX emission of one kernel, `rt_gpu_*` minimal, Dispatch as an intrinsic Call, `gpusaxpy` on the 4060 Ti | 4-5 |
| v1 on NVPTX: Check rules, Buffer/Device API, Dispatch node, CPU fallback on the pool, editor colour, docs | 10-12 |
| Vulkan/SPIR-V back end (second LLVM, resource model, host runtime, both GPUs on the owner's machine) | 15-20 |

## 8. Open questions (with recommendations)

1. **Is an NVIDIA-only first version acceptable?** Recommend yes for the spike and internal use; no user-facing
   GPU feature ships before the Vulkan back end.
2. **Second LLVM for SPIR-V:** build our own (all targets, pinned, about an hour on the 7700) or pin an official
   LLVM 23 release (whether its Windows binary has the SPIRV target is unverified). Recommend checking the
   official release first in the Vulkan step.
3. **Kernels in a separate project kind** (a GPU library) or anywhere with `[Kernel]`? Recommend anywhere;
   the attribute is enough.
4. **Graphics** (vertex/fragment shaders from Sheets) is a different product; recommend not in scope.
