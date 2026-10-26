---
audience: developer
title: Design docs
summary: The map of the docs: what each page is for, who reads it, which pages ship with the editor, the reading order, and the self-test cases with what each covers.
order: 0
---

# Design docs

Treadle is a visual language: the graph files are the program, compiled through LLVM with no garbage
collector, edited in an editor forked from an earlier Apache-2.0 node editor (NOTICE). [Building.md](Building.md)
has the build commands and the self tests; the fork itself is recorded in `FORK-NOTES.md` at the root of the
private repository, with the self-test counts ("Build and run").

## Who reads what

**User pages** (`audience: user`) ship in the package's `docs` folder and appear in the editor's Help (the
editor lists only `audience: user` pages; `scripts/package.ps1` and `scripts/package-linux.sh` copy the nine by
name): Getting-Started, Language-Guide, Core-Library, C-Import, Debugging, Keyboard, Linux, Performance, Known-Issues. They should link only to each other and use
only Treadle's words (Language.md 10). Every other page is `audience: developer` and never ships.

**Reading order for developers:** Language, Graph-Format, Compiler, Editor-Model, then Roadmap and Follow-ups;
Toolchain, Linux-Development and Releasing when touching the build, a platform or a package. Someone who implements one
layer reads Language first and then that layer's page. A new user reads Getting-Started, then Keyboard, then the
others as needed.

## The pages

**[Getting-Started.md](Getting-Started.md)** (user) is the first hour: install, make a project, build a small
program step by step (classes, a struct, a generic type, memory, a loop, a C function), run and debug it. The
`tutorial` self test performs it and captures its pictures (`docs/images`).

**[Language-Guide.md](Language-Guide.md)** (user) is the language for a programmer who knows C#, C++ or another
node editor: how a program is built and evaluated (once per consuming flow node, evaluated Nx, Make local
variable), the kinds of types, memory (Construct, Local, regions, Defer, the Debug checks, who deletes what, Pure),
control flow and the gates' state, errors as values, functions (Receiver, Mutating, overloads, inheritance,
constructors, Lambdas, Extract to Function), calling C, project kinds and configs, and a table of familiar habits
with Treadle's names. Every example was built and run; its pictures (`docs/images/guide-*.png`) come from a scratch
project and the m2-frontend sample through the capture steps `opensheet:`, `arrange`, `validate`, `frame` and
`hold:` (`SelfTestLambda.bf`), cropped to the nodes.

**[Keyboard.md](Keyboard.md)** (user) is every shortcut and mouse gesture of the editor, by where it works, and
the right-click menus.

**[Core-Library.md](Core-Library.md)** (user) is the core library every program has: who owns what (and how
the collections move structs), the API by type, parsing, number formats and AppendF, UTF-8, what is not there yet,
and an example. How the compiler finds and compiles it is Compiler.md 10.

**[C-Import.md](C-Import.md)** (user) is calling C: writing a `.cimport` set, importing it (File > Import C
Headers, `--import-c`), what each C declaration becomes, what is skipped, linking and shipping the library, paths
and platform variants. The importer's internals are Compiler.md 8.

**[Debugging.md](Debugging.md)** (user) is the graph debugger: breakpoints, stops and steps by node, Locals and
pin values, fatal runtime errors, CodeView for PDB tools, and its limits. Its internals are Editor-Model.md 10.

**[Linux.md](Linux.md)** (user) is Treadle on Linux for a user of the tarball: what the system needs (`libc6-dev`), unpacking
and running, where the files go, what differs from Windows, and what does not work yet. Building from source is
Linux-Development.md.

**[Performance.md](Performance.md)** (user) is how fast Treadle programs run against the same programs in C: nine
benchmark kernels (`TreadleCore/samples/bench` and `scripts\bench.ps1`, which do not ship), the results, what is
slower and why, and what the Debug checks cost.

**[Known-Issues.md](Known-Issues.md)** (user) is the alpha's known issues and limits, in plain words: what the
language and the editor do not do yet, each with what to do today and a **(being fixed)** mark for the items in
the current wave (no dates), platform notes, what may change in the format before beta, what to expect of
Release and Debug speed, what the editor runs and stores, and how to report a problem (the report address is a
placeholder the owner fills in before release). Each item was checked against master or Follow-ups.md; when an
item is fixed or a Follow-ups item a user meets is added, this page changes with it.

**[Release-Notes-0.1.1-alpha.md](Release-Notes-0.1.1-alpha.md)** (public, no front matter) is the GitHub Release body for 0.1.1-alpha, written as the 0.1.0-alpha page is.

**[Release-Notes-0.1.0-alpha.md](Release-Notes-0.1.0-alpha.md)** (public, no front matter) is the GitHub Release body for 0.1.0-alpha. It ships in the public repository (no rule in `packaging/public-exclude.txt`) and is linked from the root README, but is not one of the nine pages the packages copy.

**[Language.md](Language.md)** is the semantics of the language: types, values and references, memory and
ownership (Construct, Local, Delete, Defer), generics, inheritance, enums, extensions, events, the evaluation
rules of value nodes and regions, flow nodes, entry points, errors as values, attributes, and the glossary.
Everyone reads it first; the other pages assume its words. Where a decision is not built yet it says so.

**[Graph-Format.md](Graph-Format.md)** is the on-disk record format: type files, layout sidecars, project files and
C import sets; grammar, node kinds with their stored pin names and settings, canonical order, round trip,
versioning, and three complete examples (the round-trip fixtures in `TreadleCore/samples/`). It is the contract
for the codec (`TreadleCore/src/Format/`) and for anyone reviewing a graph diff.

**[Format-Stability.md](Format-Stability.md)** is the format's stability promise: what is frozen at beta and 1.0, the version rule, migration (`--format --migrate`), the alias table for renamed nodes and pins, and the owner decisions before beta.

**[Compiler.md](Compiler.md)** is the pipeline from graph files to an executable: Load, Declare, Bind, Check, the
Sheet IR and its `.tir` text, LLVM IR emission, mangling, the runtime ABI, debug info and node mapping (DWARF and
CodeView), the C header import's internals, incremental builds and Validate, the core library's compilation, and
the diagnostic model. Compiler implementers read it.

**[Threads.md](Threads.md)** is the design of threads: the core types (Thread, Mutex, LockGuard, Condition, WaitEvent,
ThreadLocal, ThreadPool, Parallel), ownership across threads, the memory model, the runtime functions, the Debug
allocator's lock, fatal errors and leaks on worker threads, and the debugger's thread list.

**[Editor-Model.md](Editor-Model.md)** is the editor as built over the data model: the document model, node and pin
drawing, the Node menu sources, the panels, the nodes with special behaviour, Extract to Function, Validate /
Build / Run, the original editor's layers as the fork left them, undo and saving, and the debugger's internals. Editor
implementers read it with FORK-NOTES.md.

**[SIMD-and-Vectors.md](SIMD-and-Vectors.md)** is the spec for vector primitives (`float4`, `int32x4`, masks):
spellings, layout and the 16-byte alignment cap, the ops and their LLVM lowering, the Debug checks, the C ABI on
win64 and SysV, the `simd` config key, the editor's vector pins and Swizzle/Shuffle nodes, and the core math
library on top (Vec2/3/4, Mat3/4, Quat, Color, Rect, AABB, Plane, Ray, Transform) with its fixtures, benchmarks
and implementation plan. **Threads.md** (threads, locks, the pool, parallel-for, the runtime's thread support) is
written by the threads branch. **[GPU-Compute.md](GPU-Compute.md)** is GPU compute
(experimental, NVIDIA only): `[Kernel]` functions, resident buffers, streams, shared memory and barriers, the
device-side error record, the GPU's math library, the CPU path on the pool, the NVPTX lowering and the CUDA driver
runtime, the fixtures' numbers, and what is still missing (Vulkan / SPIR-V, the editor UI).

**UX-Audit.md** (private, not in the public tree) checks the editor against what a user of another node editor does in the first hour
(Works / Partial / Missing, our words, cost, priority) and records what the two passes fixed. Read it before
changing an interaction.

**[Building.md](Building.md)** is building Treadle from a clone: what to install, the pinned tools, the native host,
the Debug, Release and ReleasePackage configurations (the self tests are compiled into the first two only), the
self-test command, the command-line modes and the package scripts.

**[Toolchain.md](Toolchain.md)** is the pinned native toolchain (llvm-mingw, libclang), `scripts\llbuild.ps1`, what
the probes under `tools\probe\` measured (IR to exe, DWARF and CodeView with lldb, header import, timings, Release
fatal errors), and the vendoring checklist.

**[Linux-Development.md](Linux-Development.md)** is building Treadle from source on Linux: the packages and Beef build,
`scripts/build-linux.sh`, what the back end, the C import and the debugger do differently there, the self-test
results, what the tarball bundles, and what is decided or untried.

**[Releasing.md](Releasing.md)** is packaging: the vendoring decision with its sizes, `scripts\package.ps1` and
`scripts/package-linux.sh`, the package layouts, how the editor finds its pieces, the `-Verify` / `--verify`
proofs, and how the update channel gets configured.

**Roadmap.md** (private, not in the public tree) is the milestones (console program, debugger, core library and interop, Linux, JIT,
packaging), each with its gate and a dated status line, and the open questions for the owner.

**Follow-ups.md** (private, not in the public tree) lists where the code still owes the docs, what the editor needs from the front
end, and what each layer has not done yet. Implementers read it before starting a step; items are removed as
they are done.

**Review-2026-10-26.md** (private, not in the public tree) is the docs-versus-code review of 2026-10-26: the code findings
the docs could not fix, prioritised.

## Self tests

The editor runs its self tests from `TREADLE_SELFTEST`, a comma list run in order (`TreadleEditor/src/SelfTest.bf`);
results are `[SELFTEST] ok ...` / `[SELFTEST] FAIL ...` lines ending in `[SELFTEST] done failures=N`, and `quit`
closes the editor. FORK-NOTES.md "Build and run" has the commands and the current counts (623 checks on Windows in
Debug and Release, 510 on Linux without `tutorial`).

| Case | File | What it covers |
|---|---|---|
| `smoke` | `SelfTest.bf` | The shell is up (dock layout, seams installed), an untitled document with one Sheet, a node added and wired, undo and redo. |
| `codec` | `SelfTest.bf` | The samples (`TreadleCore/samples` or `TREADLE_SAMPLES`) read and write back byte for byte (type files, layout, project, C import set); the reading-order originals normalise to them; unknown records and keys survive; a malformed file gives a line-numbered error; the newer keys (`category`, `split`, `group`). |
| `editor` | `SelfTest.bf`, `SelfTestUX.bf`, `SelfTestUX2.bf`, `SelfTestSplit.bf`, `SelfTestGroups.bf`, `SelfTestLambda.bf`, `SelfTestEntry.bf` | A copy of the Player sample: a node of each kind through the catalogue, wiring and a refused wire with its reason, pin-filtered Node menu rows, Type Settings adds a field and a function, save and read back; the node habits (Make variable, pin hover, Add / Remove pin, Break / Make from fields, Disable Node, F2, Ctrl+Tab, breadcrumbs); the second wave (variadic "+ arg", the Ctrl+Tab list, input reorder, variable categories, Extract to Function); split struct pins (Split / Recombine with undo, Validate, a program built and run); node groups (Collapse, open, Ungroup, the file and layout); Lambda placement, inputs, by-reference captures; then the first program (`entry`): New Project's start comment and entry, another type's function found on the canvas and from an object pin, Construct T + F, Run building a modified project, Create Main, Set as entry point with undo. |
| `backend` | `SelfTestBackend.bf` | Every IR fixture (`TreadleBackend/fixtures`) built, run and compared in Debug and Release; lldb stopping on a node's listing line; the adapter on `debugtypes` summaries and attached to `attachwait`; CodeView / PDB builds (Windows); process cleanup; Build / Run through the installed toolchain on a `.tir` project. |
| `frontend` | `SelfTestFrontEnd.bf` | Every sample validates clean; each broken sample (`TreadleCompiler/fixtures/broken`) gives the diagnostic its `# expect` lines name on that node and pin; the Sheet IR dumps match `TreadleCompiler/fixtures/ir/*.tir`; the services (per-Sheet checks, type system, Node menu) and incremental Validate against a full compile. |
| `cimport` | `ImportHeader.bf` | libclang loads; small.h imports to the checked-in `small.cdecl` byte for byte; `<stdio.h>` and `SDL.h` declarations and layouts; File > Import C Headers; platform `.cdecl` names; a set made for a project with none (Compiler.md 8.3). |
| `core` | `SelfTestCore.bf` | The core validates with no diagnostic and writes back byte for byte; the built-in copy matches the folder; the Node menu's Core group; the nineteen programs of `TreadleCompiler/fixtures/core` in Debug and Release, leak-free; the m3-core, m3-files and m3-text samples (Compiler.md 10.4). |
| `debug` | `SelfTestDebug.bf` | A copy of samples/m1: breakpoint, stop, pin values, Evaluate, Step Over / Into / Out, exit 0; a double Delete stopped on its node, exit 3; m3-core's container summaries (Editor-Model.md 10). |
| `tutorial` | `SelfTestTutorial.bf` | Performs Getting-Started.md step by step on a fresh project and holds at each picture (`[SELFTEST] hold tutorial-<NN-name>`) for the capture script; `TREADLE_TUTORIAL_DIR` picks the folder. |
| `quit` | `SelfTest.bf` | Logs `done failures=N` and closes the editor (unsaved test edits dropped). |

Capture steps (no checks; for the pixel passes): `menu` (the Node menu off an int output), `menuall`,
`menusearch:<text>`, `showcase` (one node of each family on a Sheet, after `editor`), `frame`, `zoomout`,
`zoomshow`, `deselect`, `typesettings`, `projecttile`, `select:<text>`, `member:<name>`, `debugstop` (a breakpoint
from `TREADLE_DEBUG_BREAK=<type file>,<Sheet>,<node>`, stays on the stop), and the `ux.*`, `ux2.*` and Lambda
capture steps of `SelfTestUX.bf`, `SelfTestUX2.bf` and `SelfTestLambda.bf`.
