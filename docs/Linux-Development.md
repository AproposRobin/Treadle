---
audience: developer
title: Linux development
summary: Building Treadle from source on x86-64 Linux (WSL2 Ubuntu 26.04 tested): packages, Beef, the native host, scripts/build-linux.sh, what the back end, the C import and the debugger do differently, the self-test results, how the tarball is made, and what is decided or untried.
order: 13
---

# Linux development

Treadle builds and runs on x86-64 Linux with glibc since 2026-10-25 (Roadmap Milestone 4). Tested on
Ubuntu 26.04.1 under WSL2 (kernel 6.18, WSL 3.0.3, glibc 2.43), the editor's window through WSLg. Windows
stays the main platform; everything below also builds and passes there unchanged. What a user of the Linux
package needs is [Linux.md](Linux.md) (a user page); this page is building from source and the internals.

## What you need

| | |
|---|---|
| OS | x86-64 Linux with glibc; a desktop session (X11, or Wayland with XWayland) for the editor and the SDL sample. Nothing graphical is needed to build. |
| Packages | Beef's own (`build-essential cmake ninja-build clang lld git ccache python3 llvm-22-dev libzstd-dev libxml2-dev libedit-dev zlib1g-dev libcurl4-openssl-dev libffi-dev autoconf automake libtool texinfo`), the native host's (`libsdl2-dev libgl1-mesa-dev`), the editor's Open dialogs (`zenity`) and Treadle's toolchain: `clang-22 lld-22 lldb-22 libclang-22-dev`. Optional: `imagemagick xdotool` for screenshots. |
| Versions checked | `clang-22`, `lld-22`, `lldb-22` (with `lldb-dap`), `libclang-22-dev`, `llvm-22-dev`: 1:22.1.2-1ubuntu1; `libsdl2-dev` 2.32.10+dfsg-6. |
| Beef | Built from source, `master` at `8bd578c` (2026-10-10), against LLVM 22.1 (`llvm-22-dev`; Beef's build script stops when it is missing instead of compiling LLVM); about 3 minutes with `bin/build.sh` (below). There is no Linux binary release. BeefBuild is `~/beef/IDE/dist/BeefBuild`. |

LLVM 22 is used for everything because Beef needs exactly that major; the distribution's default `clang`
package may be another major (21 on Ubuntu 26.04) and is not used.

## Build and run

```
# once: the packages, then Beef
sudo apt install build-essential cmake ninja-build clang lld git ccache python3 llvm-22-dev \
    libzstd-dev libxml2-dev libedit-dev zlib1g-dev libcurl4-openssl-dev libffi-dev \
    autoconf automake libtool texinfo libsdl2-dev libgl1-mesa-dev zenity \
    clang-22 lld-22 lldb-22 libclang-22-dev
git clone https://github.com/beefytech/Beef ~/beef
git -C ~/beef checkout 8bd578c
CMAKE_BUILD_PARALLEL_LEVEL=6 nice -n 15 ~/beef/bin/build.sh
export PATH=~/beef/IDE/dist:$PATH          # BeefBuild (build-linux.sh also finds ~/beef/IDE/dist/BeefBuild)

# then, in a clone on the Linux file system
git clone <repository> ~/treadle && cd ~/treadle

scripts/build-linux.sh                     # host + Debug and Release + every self test
scripts/build-linux.sh Debug none          # just the Debug build
build/Debug_Linux64/TreadleEditor/treadle <project folder>
build/Release_Linux64/TreadleEditor/treadle --build-run TreadleCore/samples/m1 [--config Release]
build/Release_Linux64/TreadleEditor/treadle --build-run TreadleCore/samples/m2-frontend
build/Release_Linux64/TreadleEditor/treadle --build-run TreadleCore/samples/m2-sdl -- --frames 120
build/Release_Linux64/TreadleEditor/treadle --import-c TreadleCore/samples/m2-sdl/sdl2.linux.cimport --out /tmp/cimport
```

* `scripts/build-linux.sh [Debug|Release|both] [self-test list|none]` runs `Native/build_linux.sh`
  (`Native/bin/linux64/libtreadlehost.so`: cimgui, cimnodes, ImGui's SDL2 + OpenGL3 back ends and the host, against
  the system SDL2; incremental, a few seconds with ccache) when the committed `libtreadlehost.so` does not load on
  this system (it needs glibc 2.43), when this checkout built it before, or with `TREADLE_BUILD_HOST=1` (the same
  toolchain gives the same bytes, `packaging/host-sha256.txt`; another compiler or SDL2 rewrites the tracked file:
  `git checkout -- Native/bin` discards it unless the host changed), then
  BeefBuild per configuration (into `build/`, git-ignored), then the self
  tests of each build in a scratch `TREADLE_HOME`, and prints `<Config>: exit 0, 510 checks passed, [SELFTEST]
  done failures=0`. It exits non-zero when a build or a check fails and keeps that run's session log.
* The Debug editor finds `libtreadlehost.so` in `Native/bin/linux64` (rpath); Release copies it next to the
  editor (rpath `$ORIGIN`, `Native/BeefProj.toml`).
* Build from a Linux file system. A Windows checkout seen through `/mnt/d` works but BeefBuild takes about
  100 s there instead of about 4 s (the file accesses); the 2026-10-25 runs used a copy under
  `~/treadle-linux` (`rsync` of the worktree without `build/` and `.git/`). `*.sh` are LF in every checkout
  (`.gitattributes`); the `.bf` files may be CRLF, Beef does not mind.
* Per-user files and SIGTERM: as for the package ([Linux.md](Linux.md), "Your files" and "Closing the editor").

## Back end

The editor builds for the platform it runs on. On Linux (`TreadleBackend/src/Driver/Builder.bf`,
`TreadleBackend/src/Emit/Emitter.bf`):

| | Windows | Linux |
|---|---|---|
| Toolchain root (`Treadle.Language.LlvmRoot`) | `TREADLE_LLVM`, `tools\llvm` next to the exe, `tools/llvm-mingw`, `TREADLE_DEV_LLVM` (skipped with `TREADLE_NO_FALLBACK=1`) | `TREADLE_LLVM` (a root with `bin/clang`), `tools/llvm` next to the exe, `/usr/lib/llvm-22`, the newest `/usr/lib/llvm-<N>`, `/usr` |
| Target, data layout | `x86_64-w64-windows-gnu`, `e-m:w-...` | `x86_64-pc-linux-gnu`, `e-m:e-...` |
| Link | `-static -mconsole` (or `-mwindows`), lld | `-fuse-ld=lld -Wl,-z,nostart-stop-gc -lm`, a PIE against the system glibc (no `-static`: glibc does not support it) |
| Program | `<Name>.exe`, a set's `bin` DLLs copied next to it | `<Name>` (no extension); nothing to copy (shared libraries come from the system paths) |
| Runtime tables | COFF grouped sections `.tti$m` / `.tsct$m` between the runtime's `$a` / `$z` markers | ELF sections `treadle_ti` / `treadle_sct`, walked from `__start_` to `__stop_` (weak, so a program without entries links) |
| C ABI of imports and `[Export]` | win64: 1/2/4/8-byte aggregates as an integer, others through a pointer to a copy, `sret` results | System V: aggregates up to 16 bytes as one or two eightbytes (`i64` / `iN`, `double`, `float`, `<2 x float>`, flattened into separate arguments as clang does), larger ones `byval` on the stack, `sret` results; an aggregate whose eightbytes do not fit the integer (6) and SSE (8) registers left goes in memory. `[Export]` functions are plain global symbols (no `dllexport`) |

`.lst` and `.nodemap` files are the same on both. The runtime (`tools/runtime/treadle_rt.c`) compiles for both
from one file: on Linux `posix_memalign` for alignments above 16, `<exe>.fatal.txt` next to
`/proc/self/exe`, the Debug runtime's trap when `/proc/self/status` names a tracer, the arguments from
`argv` as they are (UTF-8), and `QueryPerformanceCounter` / `QueryPerformanceFrequency` over `CLOCK_MONOTONIC`
(nanoseconds; the core library's Time imports them from kernel32, glibc
has none). Console output stays on stdio, as on Windows.

The self tests' `atomics` fixture starts its threads with `CreateThread`; on Linux the backend self test uses
`TreadleBackend/fixtures/atomics.linux.tir` in its place (pthreads, same expected output): a fixture
`<name>.linux.tir` replaces `<name>.tir` on Linux and is skipped on Windows.

## C import

`TreadleCImport/src/LibClang.bf` loads `libclang.so` with `dlopen` (`Internal.LoadSharedLibrary`):
`TREADLE_LIBCLANG` (the file, or a folder holding it or its `lib/`), else `lib/libclang.so` of the LLVM root
(`/usr/lib/llvm-22/lib/libclang.so` from `libclang-22-dev`), else `/usr/lib/x86_64-linux-gnu/libclang-<N>.so.1`.
The builtin headers are the loaded library's (`/usr/lib/llvm-22/lib/clang/22/include`); the parse runs with
`-target x86_64-pc-linux-gnu -nostdinc` and `-isystem` the builtin headers, `/usr/local/include`,
`/usr/include/x86_64-linux-gnu` and `/usr/include`, so a `.cdecl` holds the Linux sizes (`long` is 64 bits).

The FFI declarations: libclang's structs are passed and returned by value. On Windows the bindings spell the
Microsoft x64 forms by hand (pointers to copies, hidden result pointers); on Linux they are `c_*` function
pointers with the structs by value, which Beef lowers by the System V rules for `[CRepr]` structs (checked
against a clang-built library with the same shapes: a 32-byte `CXCursor` on the stack, a 16-byte `CXString` in
RAX:RDX, a by-value visitor callback). Methods with the Windows names and shapes wrap them, so the importer's
code is the same on both. Beef needs no calling-convention attribute for this on Linux (its default is the C
convention there); the visitor trampoline is marked `[CallingConvention(.Cdecl)]` anyway.

**Platform variants of a set file.** `<name>.linux.cimport` next to `<name>.cimport` is the file read on Linux
(`<name>.windows.cimport` likewise on Windows): the folder scan, a project file's `cimport` line and File >
Import C Headers all take the variant (`CImportFile.ForPlatform` / `ScanTakes`, `TreadleCore/src/Model/ProjectModel.bf`).
A variant has the same `import` names, so it writes and reads the same `.cdecl` files; the `.cdecl` names the
base file in its doc line, so both platforms write the same bytes. The SDL sample's
`samples/m2-sdl/sdl2.linux.cimport` keeps the `${TREADLE_SDL2:-...}` rule with the system as the fallback:

```
	include ${TREADLE_SDL2:-/usr}/include/SDL2
	lib SDL2
```

(no `bin`: `libSDL2-2.0.so.0` is found by the dynamic loader). Its import writes the checked-in `sdl2.cdecl` byte
for byte. `libc.cimport` needs no variant (`lib msvcrt` is informative on both); the checked-in `libc.cdecl`
files stay the Windows imports, which link and run on Linux as they are (a Linux import differs only in
spelling: glibc's `qsort` takes the `__compar_fn_t` typedef).

## Debugger

`lldb-dap` from `lldb-22` (`/usr/lib/llvm-22/bin/lldb-dap`, through `LlvmRoot.Tool`; `TREADLE_LLDB_DAP` names
another), the same protocol and node mapping as on Windows ([Debugging.md](Debugging.md)). Breakpoint sources
are the listing paths with `/`. lldb 22 prints a `char32` as `U+0x000003bb U'λ'` (lldb 23: `U+03BB`); the
backend self test accepts both.

## Thread joins

Beef's POSIX `Thread.Join(ms)` hands a relative time to `pthread_timedjoin_np`, which wants an absolute one: a
timed Join returns false at once unless the thread already ended, and joining a thread that a timed Join (or
`IsAlive`) did join is undefined (the editor crashed in `BfpThread_WaitFor`). `Treadle.Language.ThreadJoin`
joins each thread once and polls `Join(0)` for a timeout; `RunningProcess` (whose reader threads lost the end
of a child's output before), the build job, `DapConnection` and `LldbDapAdapter` use it.

## Test results (2026-10-25)

After the merge into master (core library, nested Lambdas):
`TREADLE_SELFTEST=smoke,codec,editor,backend,frontend,cimport,core,debug,quit` gives 338 checks,
`done failures=0`, in Debug and Release on Linux and on Windows (smoke 8, codec 21, editor 68, backend 64,
frontend 98, cimport 23, core 26, debug 30); `--build-run` of m1, m2-frontend and m3-core prints the same
stdout on both, Debug and Release, and m2-sdl the five lines below.

On the branch, before the merge, `TREADLE_SELFTEST=smoke,codec,editor,backend,frontend,cimport,debug,quit`,
WSL2 Ubuntu 26.04, LLVM 22.1.2:

| Config | Linux | Windows (same tree) |
|---|---|---|
| Debug | 294 checks, `done failures=0` (43 s) | 294 checks, `done failures=0` (33 s) |
| Release | 294 checks, `done failures=0` (23 s) | 294 checks, `done failures=0` (25 s) |

smoke 8, codec 21, editor 58, backend 64, frontend 90, cimport 23, debug 30 on both. `--build-run` of m1 (10 lines)
and m2-frontend (42 lines) prints the same stdout on Linux and Windows and exits 0, Debug and Release; m2-sdl with
`-- --frames 120` opens its window under WSLg and prints `frame 0: red`, `frame 30: blue`, `frame 60: red`,
`frame 90: blue`, `frames 120`, exit code 0, Debug and Release. The editor opened on `samples/m1` under WSLg
shows the dock layout (Outline, the canvas, Properties, the Project Browser with the seven types) and ends on
SIGTERM with exit code 0.


## Package

`scripts/package-linux.sh` makes `Treadle-<version>-linux-x64.tar.gz` (one folder, `Treadle-<version>-linux-x64/`),
the Linux counterpart of the Windows zip ([Releasing.md](Releasing.md), "Linux package", which has the commands
and `--verify`). It is self-contained for everything Treadle itself needs; the system provides glibc and a desktop.

**What is bundled:** the editor (`TreadleEditor`, `libtreadlehost.so`) with the SDL2 the host loads
(`libSDL2-2.0.so.0` next to it), the core library, the runtime sources, a trimmed LLVM 22 in `tools/llvm`
(`clang`, `lld`, `lldb-dap` + `lldb-server` + `liblldb`, `libclang.so` for the C import, clang's builtin headers,
compiler-rt's builtins and start-up files; `packaging/llvm-files-linux.txt`), the libraries those need that a
system may lack (`libz3`, `libxml2`, `libedit`, `libffi`, `libpython3.14`, `libexpat`, `libipt`, ncurses), the
samples m1 and m3-core, the user docs and the licences (`THIRD_PARTY/linux/` has the Debian copyright file of
every library taken from the distribution). No GCC is needed on the user's system: the packaged clang links
compiler-rt in place of libgcc (`tools/llvm/bin/x86_64-pc-linux-gnu.cfg`). Every binary finds its libraries
through `$ORIGIN`.

**Which systems:** made on Ubuntu 26.04 (glibc 2.43) from its LLVM 22.1.2 packages, so it runs on Ubuntu 26.04
and distributions of the same generation. A package built on the oldest supported distribution is open
(Releasing.md).

## Decided and not tried

* **Pinned toolchain.** Decided (Toolchain.md, "Linux"): the package bundles the distribution's LLVM 22
  subset, source builds use the distribution's clang 22; no download script unless an older distribution
  is targeted.
* **Process handling by platform:** Windows uses job objects; on Linux a program started by Run and lldb-dap
  run in a process group of their own that Stop, Cancel and the editor's exit kill, and they die with a killed
  editor through the parent-death signal (Debugging.md "Processes"); build tools are killed with their
  descendants on Cancel. The recovery `session.lock` has no delete-on-close or share mode on POSIX
  (`TreadleEditor/src/PosixRaw.bf`).
* **Not tried on Linux:** a distribution other than Ubuntu 26.04, a native (non-WSL) desktop session,
  display scaling (`TREADLE_UI_SCALE` / `GDK_SCALE` as in the original editor).
