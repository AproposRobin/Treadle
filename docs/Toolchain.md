---
audience: developer
title: Native toolchain
order: 6
summary: How Treadle turns LLVM IR into a Windows executable: the pinned llvm-mingw toolchain, scripts\llbuild.ps1, debug info, C header import, timings, and how to vendor the toolchain.
---

# Native toolchain

The Treadle compiler emits LLVM IR text (`.ll`, [Compiler.md](Compiler.md) 5). Everything after that, from IR to a running
`.exe`, is clang + lld from one pinned toolchain, driven by `scripts\llbuild.ps1`. This page records
what is pinned, the exact commands, and what the probes under `tools\probe\` measured on
2026-10-24 (AMD Ryzen 7 7700 8-Core, 16 threads, Windows 11 10.0.26200).

## What is pinned

| Piece | Version | Where | Used for |
|---|---|---|---|
| **llvm-mingw** `20261006-ucrt-x86_64` | clang **23.1.3**, lld, lldb 23.1.3, lldb-dap, libc++, libunwind, llvm-objdump, llvm-readobj, llvm-dlltool, llvm-windres; mingw-w64 CRT on the Universal CRT | `$env:TREADLE_LLVM`, else `<repo>\tools\llvm-mingw` (git-ignored, installed by `scripts\get-llvm-mingw.ps1`), else `$env:TREADLE_DEV_LLVM` (the editor only) | **the pipeline**: `.ll` -> `.o` -> `.exe`/`.dll`, debugging |
| SDL2 2.32.10 mingw devel | headers, `libSDL2.a`, `libSDL2.dll.a`, `SDL2.dll`, installed by `scripts\get-sdl2.ps1` (archive pinned by sha256) | `$env:TREADLE_SDL2`, else `<repo>\tools\SDL2-2.32.10` (git-ignored), its `x86_64-w64-mingw32` folder ([C-Import.md](C-Import.md), "Paths and variables") | the native host (`Native\build_windows.ps1`), the m2-sdl sample, header-import probe input |
| **libclang** from LLVM 23.1.3 for Windows (MSVC build) | `libclang.dll` 23.1.3 + `lib\clang\23\include` + `include\clang-c`, installed by `scripts\get-libclang.ps1` (archive and DLL pinned by sha256) | `<repo>\tools\libclang` (git-ignored) | **the C header import** ([C-Import.md](C-Import.md)); llvm-mingw ships no `libclang.dll` |
| LLVM for Windows (MSVC target) | clang 22.1.8, **libclang.dll** + `include\clang-c`, lld, lldb (broken, see below) | `C:\Program Files\LLVM` | the probes below; the import's last fallback |

Release zip of the toolchain, as `scripts\get-llvm-mingw.ps1` and `Native\build_windows.ps1` record it:
`llvm-mingw-20261006-ucrt-x86_64.zip` from https://github.com/mstorsjo/llvm-mingw/releases,
sha256 `317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a`.

Scripts and the editor find the toolchain root in this order: `-Toolchain` parameter (scripts only),
`$env:TREADLE_LLVM`, then `tools\llvm` next to the exe (the editor only: the
trimmed copy a package ships, [Releasing.md](Releasing.md)), then `tools\llvm-mingw` of the repository (the editor
looks above its exe), then the last fallback: for the editor the folder named by `TREADLE_DEV_LLVM` (below), which
`TREADLE_NO_FALLBACK=1` skips (`Treadle.Language.LlvmRoot`, `TreadleCore/src/Language/LlvmRoot.bf`); the
scripts stop at `tools\llvm-mingw`.

**Developer-machine conveniences.** `TREADLE_DEV_LLVM` (an llvm-mingw root) and `TREADLE_DEV_LIBCLANG` (a
`libclang.dll`, or a folder holding it or its `bin\`, [C-Import.md](C-Import.md)) are the editor's last fallbacks,
for a developer who keeps one copy outside the checkout (for example an llvm-mingw shared with another project, or the
main checkout's `tools\libclang` when the editor runs from a worktree) instead of running the get scripts in every
clone. They come after every other location, so unlike `TREADLE_LLVM` / `TREADLE_LIBCLANG` they never override a
copy the editor finds itself; the code holds no machine path, and `TREADLE_NO_FALLBACK=1` skips both (a package is
tested with its own contents only).
Nothing else is searched. `scripts\get-llvm-mingw.ps1` installs the pinned zip into `tools\llvm-mingw`. When
`TREADLE_LLVM`, `TREADLE_LIBCLANG` or `TREADLE_LLDB_DAP` is set, the first Build or Import C Headers of a session
says so in the Output Log (`toolchain from TREADLE_LLVM=<path>`), so a copy chosen from outside is never silent.


Target triple: `x86_64-w64-windows-gnu`. The C library is the Windows Universal CRT (`ucrtbase.dll`
through the `api-ms-win-crt-*` forwarders), which every Windows 10/11 installation has, so a
Treadle exe needs **no DLL that is not part of Windows**. `-static` makes lld take libunwind /
libc++ / mingw helper libraries as static archives, so even C++ runtime pieces never add a DLL.

## Files

```
scripts\llbuild.ps1            IR (+ C runtime, + libs) -> exe / dll        PowerShell 5.1, no && chains
tools\runtime\treadle_rt.c     treadle_alloc / treadle_free / treadle_rt_report (Debug: counters, double-free + leak detection)
tools\probe\hello.ll           hand-written IR probe with DWARF metadata pointing at its own lines
tools\probe\rtfault.ll         deliberate double free + leak, shows the Debug runtime counters
tools\probe\gen_synthetic.ps1  writes a ~2,000-line .ll (many small functions) for timing
tools\probe\libclang_probe.c   libclang C API walker: functions / structs / typedefs / enums (/ macros)
tools\probe\headers\           small.h, use_stdio.h, use_sdl.h: inputs of the header-import probes
tools\probe\probe_all.ps1      runs everything below and prints the numbers; output in tools\probe\out (gitignored)
```

## The pipeline (`scripts\llbuild.ps1`)

```
powershell -File scripts\llbuild.ps1 -IR <a.ll>[,<b.ll>] [-CSource tools\runtime\treadle_rt.c[,...]]
    [-Libs user32,gdi32,path\to\lib.a] [-LibDirs <dir>] [-Out <file.exe|file.dll>]
    [-Config Debug|Release] [-Lto] [-Subsystem console|windows] [-Shared] [-CodeView]
    [-KeepSymbols] [-KeepObjects] [-ObjDir <dir>] [-Timing] [-ShowImports]
    [-ExtraCFlags ...] [-ExtraLinkFlags ...] [-Toolchain <llvm-mingw root>]
```

What it runs (one process at a time, all at BelowNormal priority: the script lowers its own
priority class and clang/lld inherit it):

| Step | Debug | Release |
|---|---|---|
| each `.ll` | `clang --target=x86_64-w64-windows-gnu -O0 -g -c x.ll -o x.o` | `clang ... -O2 -ffunction-sections -fdata-sections [-flto] -c x.ll -o x.o` |
| each `.c` | same + `-std=c11 -Wall -DTREADLE_DEBUG=1` | same + `-std=c11 -Wall -DNDEBUG` |
| link | `clang --target=... -static -mconsole|-mwindows -g *.o -o out.exe [-l...]` | `clang ... -static -O2 -Wl,--gc-sections -s [-flto] *.o -o out.exe [-l...]` |
| `-Shared` | adds `-shared -Wl,--output-def,out.def`, then `llvm-dlltool -m i386:x86-64 -d out.def -D out.dll -l out.lib` (an MSVC-style import library, so lld-link based tools such as Beef can link against the DLL) | |
| `-CodeView` (Debug) | adds `-gcodeview` and `-Wl,--pdb=out.pdb` | |
| `-ShowImports` | `llvm-objdump -p out.exe`, prints size and the `DLL Name:` list | |

`-g` on an `.ll` input does not add debug info; the IR has to carry it (`!llvm.dbg.cu`,
`DISubprogram`, `DILocation`, `#dbg_declare` / `#dbg_value` records). Without `-s` the IR's debug
info survives `-O2` too; Release strips by default (`-KeepSymbols` keeps it). The intermediate
objects go to `<out dir>\obj\<name>\` and are deleted afterwards unless `-KeepObjects`.

Windowed programs keep a plain `main`: mingw's `crt2.o` startup calls `main` for both subsystems
(the `-mwindows` build of hello.ll ran unchanged, PE header `Subsystem 2 (Windows GUI)`).

## Probe 1: hello.ll + treadle_rt.c

`hello.ll` is hand-written IR (clang 23 syntax: opaque `ptr`, `#dbg_declare` / `#dbg_value`
records, no `llvm.dbg.*` intrinsics): a `%Shape = { ptr, i32, i32 }` struct, two "classes" whose
vtables are constant function-pointer tables (`%ShapeVT = { ptr, ptr }`), a virtual call
(`load` table, `load` slot 0, `call i32 %fn(ptr %self)`), a phi loop, `printf`, and the runtime
shim for allocation. `main` returns `treadle_rt_report()`, so a leak or double free turns into a
non-zero exit code in Debug.

```
powershell -File scripts\llbuild.ps1 -IR tools\probe\hello.ll -CSource tools\runtime\treadle_rt.c -Out tools\probe\out\hello_debug.exe   -Config Debug   -Timing -ShowImports
powershell -File scripts\llbuild.ps1 -IR tools\probe\hello.ll -CSource tools\runtime\treadle_rt.c -Out tools\probe\out\hello_release.exe -Config Release -Timing -ShowImports
```

Output of every variant (Debug, Release, Release `-Lto`, `-Subsystem windows`), exit code 0:

```
Treadle hello from LLVM IR 42
loop sum 0..9=285
Rect area = 12
Square area = 25
```

| Build | Size | Build wall time (3 processes) | Imports |
|---|---|---|---|
| Debug (-O0 -g, DWARF) | 69,632 bytes | 166 ms (clang .ll 54 ms, clang .c 92 ms, lld 161 ms on the first, cold run) | 9 DLLs, all Windows: `KERNEL32.dll`, `api-ms-win-crt-{stdio,runtime,locale,heap,environment,private,string,math}-l1-1-0.dll` |
| Release (-O2, stripped) | 10,752 bytes | 160 ms | the same 9 |
| Release -Lto | 10,752 bytes | 158 ms | the same 9 |
| Release -Subsystem windows | 10,752 bytes | 215 ms | the same 9 |
| Release -Shared (hello.dll + .def + .lib) | 9,216 bytes | 260 ms | 5 DLLs (KERNEL32 + 4 api-ms-win-crt) |

No `libc++.dll`, `libunwind.dll` or `libwinpthread-1.dll`: the import list is the proof that the
exe runs on a bare Windows 10/11.

`rtfault.ll` frees a block twice and leaks another:

| Build | Result |
|---|---|
| Debug | stderr `treadle_rt: double free of 0000018B...` then `treadle_rt: allocs=2 live=1 bytes_live=64 bytes_peak=96 double_free=1 foreign=0`; exit code **2** (1 live + 1 double free) |
| Release | no bookkeeping: the second `free` reaches the Windows heap, which aborts the process with **0xC0000374** (STATUS_HEAP_CORRUPTION), stderr empty (since 2026-10-25 the runtime reports it: "Release fatal errors" below) |

`TREADLE_RT_VERBOSE=1` makes the Debug report print even when nothing is wrong.

### Release fatal errors (2026-10-25)

Release keeps no bookkeeping (no live list, no quarantine, no sites). The question was whether a cheap
check on Delete should make a Release double free a Treadle fatal error: a 16-byte header in front of each
block with a magic word, checked and cleared on Delete, the object's vtable pointed at the trap table.
Measured on a Construct + Delete loop (50,000,000 pairs of a 16-byte object, `-O2`, Windows, CPU time of 15
interleaved runs, 15.6 ms ticks): no header 1,109 / 1,125 / 1,141 ms (min / first quartile / median), the
header 1,172 / 1,188 / 1,203 ms, **about +5%** (+1.3 ns per pair). Variants did not get under the 2% budget:
an 8-byte header word 1,172 / 1,188 / 1,203, the header without the vtable store 1,172 / 1,188 / 1,188, while
16 extra bytes per block alone cost nothing (1,125 / 1,141 / 1,156): the price is the code on the path, not
the memory. **Decision: no header.** What costs nothing is done instead: the runtime's `rt_start` (Release)
installs fault handlers that end the program the Treadle way (stdout flushed, `fatal: ...` on stderr, exit
code **3**):

| Fault | Windows | Linux |
|---|---|---|
| A double free the C heap notices | STATUS_HEAP_CORRUPTION, caught by a vectored handler: `fatal: the C heap found a double free or a damaged block (...)` | glibc's own `free(): double free detected` line, then its abort, caught (SIGABRT): `fatal: the program was aborted (...)` |
| An access through a deleted or null reference that faults | an unhandled access violation (the unhandled filter, so SEH that C code uses on purpose still works): `fatal: invalid memory access (...)` | SIGSEGV / SIGBUS, same message |

Every message says a Release build has no checks and that its Debug build names the node. The `memory`
fixture's Release run is the check: its second Delete runs the destructor through the freed object, then
Windows' heap reports the double free and Linux faults on the freed vtable (glibc's tcache writes over a
freed block's first word); both end with exit code 3 and the fatal line. Not covered, as before: a use of
freed memory that neither faults nor reaches the heap's checks runs on (undefined), and a block reused by a
later Construct looks live. Release `rt_alloc` now ignores alignments above 16 as Debug does (it used
`_aligned_malloc` and then `free`, a mismatch on Windows). No `<exe>.fatal.txt` is written for these faults
(the heap may be damaged, so nothing is allocated on the way out).

## Probe 2: debug info

Debugger: **lldb 23.1.3 from llvm-mingw** (`tools\llvm-mingw\bin\lldb.exe`, batch
mode `--no-lldbinit -b -o <cmd> ... -- prog.exe`). `lldb-dap.exe` (the Debug Adapter Protocol
server an IDE talks to) ships next to it and starts.

`C:\Program Files\LLVM\bin\lldb.exe` and `lldb-dap.exe` (22.1.8) **do not start on this machine**:
`error: unable to find 'python311.dll'` (that build embeds Python 3.11; only Python 3.14 is
installed). They are not used.

This machine's `~\.lldbinit` imports an Unreal Engine formatter script that fails to load; always
pass `--no-lldbinit` in scripts.

### DWARF (default), breakpoint by `hello.ll:<line>`

```
lldb --no-lldbinit -b -o "breakpoint set -f hello.ll -l 88" -o "breakpoint set -f hello.ll -l 63" -o run -o "frame variable" -o continue -o "bt 2" -o "p *(Shape*)$rcx" -o kill -- hello_debug.exe
```

```
Breakpoint 1: where = hello_debug.exe`main + 106 at hello.ll:88:1, address = 0x000000014000155a
Breakpoint 2: where = hello_debug.exe`shape_area + 7 at hello.ll:63:1, address = 0x00000001400014d7
* thread #1, stop reason = breakpoint 1.1
      frame #0: 0x00007ff786d5155a hello_debug.exe`main at hello.ll:88:1
(int) sum = 0            <- #dbg_declare on the alloca
(int) i = 0              <- #dbg_value on the phi; shows 1 on the next iteration
* thread #1, stop reason = breakpoint 2.1
      frame #0: hello_debug.exe`shape_area at hello.ll:63:1      <- the indirect call site
      frame #1: hello_debug.exe`main at hello.ll:99:1
(Shape)  (vt = 0x00007ff786d530c8, w = 3, h = 4)                <- struct type from DICompositeType
```

Works: breakpoint by file:line on the `.ll` itself, stop, locals (`frame variable`, `p sum`),
backtrace with IR line numbers, struct display through the DWARF type. lldb also prints the source
lines of the `.ll` because `DIFile(filename: "hello.ll", directory: "C:/src/treadle/tools/probe")`
points at a real file.

### Synthetic file names (what the IDE will do)

The IDE maps debug locations back to node ids, so the "file" need not exist. `hello_virt.ll` is
hello.ll with `DIFile(filename: "Main.treadle", directory: "K:/virtual/project")`:

```
Breakpoint 1: where = hello_virt.exe`main + 106 at Main.treadle:88:1
* thread #1, stop reason = breakpoint 1.1
(int) sum = 0
frame #0: hello_virt.exe`main at Main.treadle:88:1
```

So the plan of [Compiler.md 7](Compiler.md#7-debug-info-and-node-mapping) is sound: one `DIFile` per
unit (the type file's generated listing `build/dbg/<Type>.lst`), **line = the node's line in that
listing** (node ids are short strings, so the `.nodemap` file maps `nodeId <-> line`), column = pin or
sub-step within the node, `DISubprogram` per Sheet, `#dbg_declare` for every variable the
front end keeps in an alloca (visible at -O0 without any effort), `#dbg_value` for SSA values. lldb
only shows the source text when the file exists; the IDE renders the node instead. Keep
`Dwarf Version 4` + `Debug Info Version 3` module flags as in hello.ll.

### CodeView / PDB (for Visual Studio, WinDbg, and tools that only read PDBs)

CodeView is selected by the IR, not the command line: `-gcodeview` on an `.ll` input changes
nothing unless the module carries `!{i32 2, !"CodeView", i32 1}`. Checked both ways:

| Variant | Object | lld `--pdb=` | lldb |
|---|---|---|---|
| hello.ll (Dwarf Version flag) + `-CodeView` | `.debug_*` DWARF sections | writes a 253,952-byte PDB that only holds treadle_rt.c (compiled from C with -gcodeview) and the CRT | breakpoint resolves through DWARF, as above |
| hello_cv.ll (CodeView flag instead of Dwarf Version) + `-CodeView` | `.debug$S` 0x4c8 + `.debug$T` 0x554 bytes | PDB with a correct line table for `C:\src\treadle\tools\probe\hello.ll` (lines 33..107 -> addresses, `llvm-pdbutil dump -l`), exe 60,928 bytes | **pending** with the plain command, because the exe still has DWARF sections from mingw's CRT objects (`crt2.o`, `crtexe.c`) and lldb prefers that symbol file. After `target symbols add hello_cv.pdb`: `Breakpoint 1: where = hello_cv.exe\`main + 103 at hello.ll:88`, stop, `(int) sum = 0`, but `(int) i = <variable not available>` (register-located `#dbg_value` is not described in CodeView at -O0). |

Conclusion: ship **DWARF** as the default Debug format (lldb / lldb-dap, full locals); offer
CodeView as an option for users who want a PDB for Visual Studio / WinDbg, and have llbuild pass
the PDB explicitly to lldb (`target symbols add`) or strip the CRT's DWARF when CodeView is chosen.
The PDB records the absolute output path (`PDBFileName: C:/src/treadle/tools/probe/out/hello_cv.pdb`).

Built (2026-10-25): the per-config `debugFormat dwarf|codeview|both` of the project file
([Compiler.md](Compiler.md) 7). `both` puts both module flags in each unit, so the exe keeps its DWARF for
lldb and lld writes a PDB beside it; `codeview` is the probe's variant, and the debugger passes the PDB with
`target symbols add`. One more finding: with `--pdb` lld leaves out the COFF symbol table, so lldb showed
the emitted `main` (no DISubprogram) as a nameless frame; `-Wl,-Xlink=-debug:symtab` keeps the table (and the
DWARF). The m1 sample with `both`: `llvm-pdbutil dump -l M1.pdb` lists every `build/Debug/<Unit>.lst` with
its line rows, lldb breaks on `Zoo.Program.lst:4` and shows the same locals as a DWARF build; with
`codeview` and the PDB added the same breakpoint resolves, `int` slots read `long long`, a Local's object
reads "no location". A Release build with `codeview` keeps its stripped exe (16,896 bytes) and writes a
294,912-byte PDB of line tables.

## Probe 3: C header import for the interop layer

Two ways to turn a C header into declarations the compiler can use, measured with the same three
inputs: `small.h` (5 functions, 2 structs, 4 typedefs, 1 enum, 2 macros), the whole `<stdio.h>` of
llvm-mingw, and `<SDL2/SDL.h>` (the full SDL2 API; `-I<SDL include> -DSDL_MAIN_HANDLED`).

### (a) `clang -Xclang -ast-dump=json -fsyntax-only`

```
clang -x c -fsyntax-only -Xclang -ast-dump=json [-I...] use_sdl.h > ast.json
```

| Input | Wall | JSON size | `"kind":` nodes | of them `*Decl` |
|---|---|---|---|---|
| small.h | 74 ms | 37,791 bytes | 77 | 45 |
| stdio.h | 58 ms | 7,565,415 bytes | 6,741 | 2,862 |
| SDL.h | **1,200 ms** | **266,199,026 bytes** | 210,611 | 55,900 |
| SDL.h with `-Xclang -ast-dump-filter=SDL_CreateWindow` | 148 ms | 214,578 bytes (one declaration, still 200 KB because the filter prints the full subtree) | | |

Shape: one tree, every node `{ "id": "0x...", "kind": "TypedefDecl", "loc": {...}, "range": {...},
"name": ..., "type": { "qualType": "unsigned int" }, "inner": [...] }`. Types are **strings**
(`qualType`, sometimes `desugaredQualType`); sizes, alignments, field offsets, enum constant
values and calling conventions are not there and would have to be recomputed from the strings.
Implicit builtins (`__int128_t`, `__builtin_va_list`, ...) and every system header are included.
The format is explicitly unstable between clang versions.

### (b) libclang C API (`tools\probe\libclang_probe.c`)

Built with llvm-mingw clang against the MSVC LLVM's `include\clang-c` and `lib\libclang.lib`
(135 ms; the C ABI is the same for both toolchains, so a mingw or Beef caller can use the
MSVC-built `libclang.dll`, 83,735,040 bytes):

```
clang -O2 -std=c11 libclang_probe.c -I"C:\Program Files\LLVM\include" "C:\Program Files\LLVM\lib\libclang.lib" -o libclang_probe.exe
set PATH=C:\Program Files\LLVM\bin;%PATH%
libclang_probe [-all] [-macros] use_sdl.h -target x86_64-w64-windows-gnu -isystem <llvm-mingw resource include> -isystem <llvm-mingw>\include -I<SDL include> -DSDL_MAIN_HANDLED
```

The walker uses `clang_parseTranslationUnit2` with `SkipFunctionBodies | KeepGoing` (+
`DetailedPreprocessingRecord` for macros) and `clang_visitChildren`; it prints one tab-separated
line per declaration with **typed** facts: `clang_getResultType`, `clang_Cursor_getArgument`,
`clang_isFunctionTypeVariadic`, `clang_Type_getSizeOf` / `getAlignOf`, `clang_Cursor_getOffsetOfField`,
`clang_getEnumConstantDeclValue`, `clang_getTypedefDeclUnderlyingType`, `clang_getCanonicalType`,
calling convention, object-like macro tokens.

| Input | Mode | Wall | Output | Counts |
|---|---|---|---|---|
| small.h | main file only | 51 ms (180 ms on the first, cold run) | 1,007 bytes | 5 functions, 2 structs, 4 typedefs, 1 enum |
| small.h | all + macros | 51 ms | 15,697 bytes | 445 decls incl. 427 predefined macros |
| stdio.h | all + macros | 53 ms | 56,308 bytes | 395 functions, 7 structs, 30 typedefs, 635 macros |
| SDL.h | all + macros | **133 ms** | **720,603 bytes** | 6,900 functions, 113 structs, 377 typedefs, 63 enums, 2,510 macros, 0 diagnostics |

Sample lines:

```
struct   small_rect   size=24 align=8
   field  origin : small_point @0
   field  size : small_point @8
   field  label : const char * @16
typedef  small_callback  = int (*)(void *, small_id)   canonical int (*)(void *, unsigned int)
function small_register  small_id  (const char * name, small_callback cb, void * user)
function small_printf    int       (const char * fmt, ...)
enum     small_kind      : unsigned int   /  const SMALL_RECT = 10
struct   SDL_Rect  size=16 align=4   /  field x : int @0 ...
```

### Recommendation: libclang, called through FFI from the Beef compiler

(Adopted: [Compiler.md 8](Compiler.md#8-c-header-import).)

Reasons, in order:

1. **9x faster and 370x smaller on the realistic input** (SDL.h: 133 ms / 0.7 MB against 1.2 s /
   266 MB). The JSON dump of a real API header is too large to parse on every import; the
   libclang walk is fast enough to run on every build.
2. **Typed answers.** Sizes, alignments, field offsets, enum values, canonical types, variadic and
   calling-convention facts come from clang's own target layout (`-target x86_64-w64-windows-gnu`),
   exactly what the IR generator needs for struct types and ABI-correct calls. The JSON has none of
   that; a Beef-side C type parser would have to reproduce clang's rules.
3. **In-process, incremental.** `CXIndex` / `CXTranslationUnit` can be kept alive, reparsed
   (`clang_reparseTranslationUnit`) and queried per cursor; the IDE can ask for one function's
   signature or hover text without re-dumping everything. The C API is stable across LLVM
   versions (the JSON dump is not).
4. **Simple binding.** It is a flat C API over opaque structs (`CXCursor` 32 bytes by value,
   `CXString`, `CXType`), which Beef's `[CLink]` / `[Import("libclang.dll")]` externs cover directly;
   `libclang_probe.c` is the list of entry points to bind.

Cost: `libclang.dll` is 84 MB and llvm-mingw has none, so it has to be vendored from the LLVM
Windows release (MSVC build, C ABI, works from mingw code as shown) or built from the pinned
llvm-mingw sources; it also needs a resource directory with clang's builtin headers (`stddef.h`,
`stdint.h`, pass `-isystem <llvm-mingw>\lib\clang\23\include -isystem <llvm-mingw>\include`).

Fallback if FFI is undesirable at first: run `libclang_probe.exe` as a subprocess and read its
tab-separated lines; same cost (130 ms for SDL), no DLL in the compiler's own process. Rejected:
`-ast-dump=json` (size, strings instead of layout, unstable schema).

## Probe 4: 2,000-line IR to a running exe

`gen_synthetic.ps1` writes `f_0 .. f_N` (7 instructions each, a chain of calls, a `main` that
calls the chain 1,000 times and prints a checksum). Two variants: plain (217 functions, 1,981
lines, 56 KB) and with full debug info (122 functions, 1,991 lines, 103 KB; every function a
`DISubprogram`, every instruction a `DILocation`, i.e. what IDE Debug builds will emit). Each
build = `clang -c` on the `.ll`, `clang -c` on `treadle_rt.c`, lld link; 3 runs; wall time of the
whole `llbuild.ps1` run including PowerShell overhead (about 10 ms):

| Variant | Config | Build wall ms (3 runs, min) | Exe | Program output |
|---|---|---|---|---|
| plain | Debug -O0 -g | 225 / 163 / 154 (**154**) | 90,112 bytes | `checksum=df2927bd` |
| plain | Release -O2 | 337 / 331 / 352 (**331**) | 13,824 bytes | `checksum=df2927bd` (same as -O0) |
| debug info | Debug -O0 -g | 164 / 166 / 155 (**155**) | 86,528 bytes | `checksum=7da5e202` |
| debug info | Release -O2 | 275 / 275 / 268 (**268**) | 12,288 bytes | `checksum=7da5e202` (same as -O0) |

Raw per-process times (debug-info variant): `clang -O0 -c` **45 ms**, `treadle_rt.c` 51 ms, link
56 ms = 152 ms; `clang -O2 -c` 149 ms, link 53 ms. Process start-up dominates at this size, so
for the IDE: compile the runtime once and cache its `.o` (saves a third), keep -O0 for Run, and
the whole edit-run cycle stays near 0.1 s on this CPU. 2,000 lines of IR is about 200 to 250
small nodes' worth of functions; cost grows roughly linearly with IR size at -O0.

## Vendoring checklist

### Windows

The toolchain is not committed, only pinned: each `scripts\get-*.ps1` header names its archive, sha256 and
install location, and `-From <folder>` copies an unpacked copy instead of downloading.

1. llvm-mingw: **done** by `scripts\get-llvm-mingw.ps1`, which downloads
   `llvm-mingw-20261006-ucrt-x86_64.zip` (sha256 `317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a`)
   into a fresh folder, checks it and unpacks it to `<repo>\tools\llvm-mingw` (git-ignored). Only `bin\`,
   `x86_64-w64-mingw32\`, `lib\clang\23\` and `include\` are needed for x86-64; the `aarch64-`, `armv7-`,
   `i686-` folders and `python\` (lldb's scripting) can be dropped from a trimmed redistribution.
2. SDL2: **done** by `scripts\get-sdl2.ps1`, which downloads `SDL2-devel-2.32.10-mingw.zip` (sha256
   `f15cff5fca62ec9381a016ef1d42a95c638cd72d2f226ba5781c76fe43dbd1ac`) and keeps its `x86_64-w64-mingw32`
   folder and `LICENSE.txt` under `<repo>\tools\SDL2-2.32.10` (git-ignored).
3. `scripts\llbuild.ps1` (`$DefaultToolchain`) and `Native\build_windows.ps1` look in `<repo>\tools\llvm-mingw`
   before their development-machine fallback.
4. For the header import: **done** by `scripts\get-libclang.ps1`, which downloads
   `clang+llvm-23.1.3-x86_64-pc-windows-msvc.tar.xz` (sha256 `9ee6a2192fbb30c776415af529927f76ca6b5d1d55699bb1315f9878e610b5b8`,
   the release matching llvm-mingw's clang 23.1.3) into a fresh folder, checks it, and extracts only
   `bin\libclang.dll` (sha256 `745395b6706e0f67b6a6632a6cd3a1fadefedf9e4e7b16e1d53ba7afb18456ba`, 89,376,256
   bytes), `lib\clang\23\include` (the builtin headers, which must stay at `..\lib\clang\23\include` from
   the DLL) and `include\clang-c` to `<repo>\tools\libclang` (git-ignored). A redistribution ships those
   three; `TREADLE_LIBCLANG` points the editor at another copy ([C-Import.md](C-Import.md), "Where
   libclang comes from").
5. Smoke test on a clean machine: `probe_all.ps1 -SkipHeaders -SkipTiming` must print the hello
   output, exit 0, and an import list of Windows DLLs only.
6. Packaging a Treadle release: **done** by `scripts\package.ps1`, which ships the trimmed subset listed in
   `packaging\llvm-files.txt` as `tools\llvm` (sizes, the measured subset and the proof in
   [Releasing.md](Releasing.md); the subset needs no lldb.exe, only lldb-dap.exe + liblldb.dll + libpython3.14.dll
   for debugging). The original note: the user-facing bundle needs clang.exe, ld.lld.exe (lld.exe),
   the `x86_64-w64-mingw32\lib` CRT archives, `lib\clang\23\lib\windows\libclang_rt.builtins-x86_64.a`,
   and lldb.exe + lldb-dap.exe + liblldb.dll for debugging. clang's own DLLs (`libclang-cpp.dll`,
   `libLLVM-23.dll` when present) must stay beside it. License: Apache-2.0 with LLVM exceptions
   + mingw-w64's licenses (`LICENSE.TXT` in the zip root); ship them.

### Linux (clang + lld)

Done 2026-10-25 ([Linux-Development.md](Linux-Development.md)): Treadle builds and runs natively on Ubuntu 26.04 (WSL2) with
the distribution's LLVM 22, the major Beef itself is built against, nothing vendored yet.

1. Packages: `clang-22 lld-22 lldb-22 libclang-22-dev` (1:22.1.2-1ubuntu1; `clang --version`:
   `Ubuntu clang version 22.1.2 (1ubuntu1)`, `ld.lld --version`: `Ubuntu LLD 22.1.2`, `lldb-dap
   --version`: `Ubuntu LLVM version 22.1.2`), `libsdl2-dev` 2.32.10+dfsg-6 for the SDL sample. The
   default `clang` package of Ubuntu 26.04 is 21 and is not used: `Treadle.Language.LlvmRoot` takes
   `TREADLE_LLVM`, else `tools/llvm` next to the exe, else `/usr/lib/llvm-22`, else the newest `/usr/lib/llvm-<N>`, else `/usr`.
2. The back end emits `target triple = "x86_64-pc-linux-gnu"` with the ELF data layout (`-m:e`),
   compiles each unit and the runtime with `clang --target=x86_64-pc-linux-gnu -c` (the same `-O0 -g`
   / `-O2 -ffunction-sections -fdata-sections` as on Windows) and links with `clang -fuse-ld=lld
   -Wl,-z,nostart-stop-gc ... -lm` into a PIE against the system glibc (no `-static`). The C ABI of
   imports and exports is System V (Linux-Development.md, "Back end"). Debugging is DWARF with the distribution's
   `lldb` / `lldb-dap`.
3. libclang for the C import is the distribution's `libclang.so` (`libclang-22-dev`), loaded with
   `dlopen`; its builtin headers and the system's glibc headers are the parse's only include folders.
4. **Decision (2026-10-25): no separately pinned Linux LLVM.** The Linux package already bundles the
   subset of the distribution's LLVM 22 it needs (clang, lld, lldb-dap, libclang; `scripts/package-linux.sh`
   with `packaging/llvm-files-linux.txt`), so an installed Treadle does not follow distribution updates;
   a source build uses the distribution's clang 22 packages, which is also what Beef itself needs. A
   download script with sha256-pinned archives (apt.llvm.org `llvm-toolchain-*-22`, as the Windows
   section pins llvm-mingw) is written only if an older distribution without LLVM 22 packages is
   targeted. llvm-mingw's Linux-hosted cross toolchains (`llvm-mingw-<date>-ucrt-ubuntu-*-x86_64.tar.xz`),
   which build the same Windows exe from Linux, stay an option for CI, not for Linux-native output.

## Gotchas found on the way

* `clang -fsyntax-only x.ll` is an error ("cannot apply AST actions to LLVM IR file"); validate IR
  with `clang -c x.ll -o NUL` or `opt -verify`.
* Hand-written string constants: the array length must count the escapes (`c"...\0A\00"` is
  text + 2).
* `-static` is about libunwind/libc++/mingw helpers; the C library stays the UCRT DLL set. That is
  intended: UCRT is part of Windows 10+, and linking `libucrt.a` differently gains nothing.
* mingw's CRT objects carry DWARF, so a CodeView build still has `.debug_*` sections and lldb
  prefers them (see Probe 2).
* A `-Shared` build exports every global symbol by default (hello.dll exports `main` and the
  shape functions, see `hello.def`); real DLLs should mark their exports (`dllexport` storage
  class in the IR) and link with `-Wl,--exclude-all-symbols`.
* `Start-Process` in PowerShell 5.1 has no priority parameter; the scripts lower their own
  priority class (inherited by children) and set `PriorityClass` on the started process as well.
