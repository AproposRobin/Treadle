---
audience: developer
title: Releasing
order: 11
summary: How a Treadle package is made and checked: the toolchain vendoring decision and its sizes, scripts\package.ps1, the package layout, how the editor finds its pieces in it, the -Verify proof, the Linux tarball (scripts/package-linux.sh, its bundling decision, sizes and proof), and the update path (asset-name contract, SHA256SUMS, the in-app updater, the rehearsal).
---

# Releasing

A Treadle release is one zip, `Treadle-<version>-win64.zip` (on Linux a tarball: section "Linux package"), that a user unzips and runs: the editor, the core
library, the compiler back end's toolchain, the debugger and the C header import are all inside, and nothing else
has to be installed. `scripts\package.ps1` builds it, `-Verify` proves it works from the unzipped copy alone.
Releases are published on GitHub (https://github.com/AproposRobin/Treadle); installed copies update themselves from there (section "The update path").

## The toolchain: vendoring decision

**Decision: the trimmed llvm-mingw (with lldb-dap) and libclang ship inside the package.** The whole package is
116 MB zipped, well under the 250 MB line below which one download is simpler than a toolchain fetched on the first
Build. The debugger costs 8 MB zipped and is kept. SDL2's development files for the two SDL samples ship in
`tools\SDL2` (1.2 MB zipped; section "Samples and SDL2").

Measured 2026-10-25 from llvm-mingw `20261006-ucrt-x86_64` (`tools\llvm-mingw`, 736 MB unpacked) and
libclang 23.1.3 (`scripts\get-libclang.ps1`), zipped with .NET `Optimal` compression as `package.ps1` does:

| Piece | Folder | Zip |
|---|---|---|
| Trimmed llvm-mingw with lldb-dap (`tools\llvm`) | 314.4 MB | 79.4 MB |
| Trimmed llvm-mingw without lldb-dap (`package.ps1 -NoDebugger`) | 292.5 MB | 71.3 MB |
| libclang (`tools\libclang`: `libclang.dll` 85 MB + builtin headers) | 100.4 MB | 32.8 MB |
| **The package** (editor, core, both of the above, samples, docs, licences) | **424.0 MB** | **116.0 MB** |

The subset is `packaging\llvm-files.txt`; each line was checked by building and debugging with only the subset
(`TREADLE_LLVM` pointed at it, `TREADLE_NO_FALLBACK=1`, a fresh `LOCALAPPDATA`): `--build-run` of m1 and m3-core
with and without the debugger lines, and the `debug` self test with them. What it keeps:

| Part | Files | Why |
|---|---|---|
| compiler driver | `bin\clang.exe` (llvm-mingw's target wrapper), `clang-23.exe`, `x86_64-{w64,pc}-windows-gnu.cfg`, `mingw32-common.cfg` | the back end runs `clang.exe` for `.ll` -> `.o` and the link; the config files set compiler-rt, libunwind and lld |
| linker | `bin\ld.lld.exe` | clang's mingw driver links with `ld.lld` |
| their DLLs | `libLLVM-23.dll` (78 MB), `libclang-cpp.dll` (50 MB), `libc++.dll`, `libunwind.dll` | imported by clang-23 / ld.lld / lldb-dap |
| debugger | `bin\lldb-dap.exe`, `liblldb.dll`, `libpython3.14.dll` | lldb-dap loads liblldb, which imports the Python DLL; the Python library folder is not needed (lldb-dap runs with `--no-lldbinit`, no scripting) |
| clang resource dir | `lib\clang\23\include\`, `lib\clang\23\lib\windows\libclang_rt.builtins-x86_64.a` | builtin headers, compiler-rt builtins |
| mingw-w64 sysroot | `include\` (minus `include\c++\`), `x86_64-w64-mingw32\lib\` (minus libc++ / libomp archives) | C and Windows headers (programs and the C import of the Windows API need them), CRT objects, `libunwind.a`, the Windows import libraries a program may link |
| licence | `LICENSE.TXT` | LLVM + mingw-w64 terms of the toolchain |

Left out: the other targets (`aarch64-`, `armv7-`, `i686-`, `arm64ec-`), every other tool (clangd, clang-tidy,
lldb.exe, lldb-server, objdump and friends, widl, windres, make), the sanitizer and profile runtimes, `python\`,
`share\`, the libc++ headers and archives.

The alternative, a separate "toolchain" zip the editor downloads on the first Build (sha256-checked through the
updater's download path), stays the plan if the package ever passes about 250 MB zipped.

## Layout

```
Treadle-<version>-win64\
  Treadle.exe  treadlehost.dll      the editor and its native host (the Beef runtime is linked in)
  assets\fonts\                          the icon font and its licence
  core\                                  the core library (TreadleCore\core): .treadle files, crt.cimport, crt.cdecl
  tools\llvm\                            the trimmed llvm-mingw (above)
  tools\libclang\bin\libclang.dll        the C header import
  tools\libclang\lib\clang\23\include\   libclang's builtin headers (found as ..\lib\clang\23\include from the DLL)
  tools\runtime\treadle_rt.c, .h         the C runtime every program is built with
  tools\SDL2\x86_64-w64-mingw32\         SDL2 2.32.10 for the SDL samples: include\SDL2\, lib\libSDL2.dll.a, bin\SDL2.dll (+ LICENSE.txt)
  samples\<name>\  samples\README.md     the sample projects of packaging\samples.txt and their index
  docs\                                  the user pages: Getting-Started, Core-Library, C-Import, Debugging, Keyboard, Linux, Performance
  docs\images\                           the pictures they show
  LICENSE  NOTICE  THIRD_PARTY.md  THIRD_PARTY\  VERSION.txt
```

The zip holds these at its root (no top folder): the updater unpacks a release zip and checks for
`Treadle.exe`, `treadlehost.dll`, `LICENSE` and `VERSION.txt` there. No developer docs, tests, fixtures, `.tir`
or `.expected` files, `.pdb`, `.obj` or `.lib` ship (`package.ps1` refuses build leftovers outside `tools\`).

## Samples and SDL2

**The samples.** Both packages ship every sample of `packaging\samples.txt` (one line per sample with the reason it
ships; `!name` lines keep a folder out with the reason): m1, m2-frontend, m2-lambda-ui, m2-sdl, m3-core, m3-files,
m3-text, m4-breakout, m5-json, m6-vm. Not shipped: `bench` (measurement material), `format-history` (the format
migration corpus), `reading-order` (a layout test project), `broken` and `fixtures` (test inputs). A shipped sample
needs a `.tproj` and a `README.md` that opens with what it shows and how to run it (the scripts refuse a listed
sample without them); a folder of `TreadleCore\samples` with both that the list does not name ships too, with a
warning to add its line. `TreadleCore\samples\README.md` ships as `samples\README.md`, the users' index. The copy
leaves out `build\`, `m3-files-out\` and `*.pretty.json` (what a run in the checkout leaves), and rewrites the
paths that lead out of the sample in the source tree:

| Set | In the source tree | In the package |
|---|---|---|
| `m2-sdl`, `m4-breakout` `sdl2.cimport` | `${TREADLE_SDL2:-../../../tools/SDL2-2.32.10}` | `${TREADLE_SDL2:-../../tools/SDL2}` (the package's `tools\SDL2`) |
| `m2-sdl`, `m4-breakout` `sdl2.linux.cimport` (Linux package) | `lib SDL2` | `lib ../../libSDL2-2.0.so.0` (the package's own SDL2) |
| `m2-frontend` `src\cvars*.cimport` | `header ../../../../tools/probe/headers/small.h` | `header small.h`, the header copied beside the set |

The scripts refuse a shipped set that still names `../../../`. The `.cdecl` files are unchanged (they name the
base set file only), so nothing is imported again.

**SDL2 on Windows.** `tools\SDL2` holds the files of `packaging\sdl2-files.txt` (sha256 each: `SDL2.dll`,
`libSDL2.dll.a`, `SDL_version.h`, `LICENSE.txt`) and the whole `include\SDL2` folder, x86_64 only, from the
SDL2 2.32.10 mingw development package: `-Sdl2`, `TREADLE_SDL2`, `tools\SDL2-2.32.10` of the repository or of the
main checkout, else `package.ps1` runs `scripts\get-sdl2.ps1` (the archive's sha256 is pinned there). 4.6 MB
unpacked, 1.2 MB of the zip. The static `libSDL2.a` (15 MB), the test and main libraries, cmake and pkgconfig files
and the other architectures stay out. Build copies `SDL2.dll` next to a program that uses the set (`bin`).

**SDL2 on Linux.** The package's `libSDL2-2.0.so.0` (the one next to `libtreadlehost.so`) is the link input of the
SDL samples, so no `libsdl2-dev` is needed to build them; the program loads `libSDL2-2.0.so.0` from the system
(`libsdl2-2.0-0`) at run time, or from the package folder with `LD_LIBRARY_PATH` set to it. The headers are only
for importing the set again (`${TREADLE_SDL2:-/usr}/include/SDL2`, `libsdl2-dev`).

## How the editor finds its pieces

| Piece | Order | Where |
|---|---|---|
| Toolchain (clang, lld, lldb-dap) | `TREADLE_LLVM`, **`tools\llvm` next to the exe**, `tools\llvm-mingw` above the exe (a source tree), `TREADLE_DEV_LLVM` (development machine) | `TreadleCore/src/Language/LlvmRoot.bf` |
| Core library | `TREADLE_CORE`, **`core\` next to the exe**, `TreadleCore\core` above the exe, the copy compiled in | `TreadleCompiler/src/CoreSource.bf` (`FindFolder`) |
| libclang | `TREADLE_LIBCLANG`, **`tools\libclang\bin` next to the exe** or above it, the exe's folder, `TREADLE_DEV_LIBCLANG`, `C:\Program Files\LLVM\bin` | `TreadleCImport/src/LibClang.bf` (`Candidates`) |
| C runtime | `TREADLE_RUNTIME`, **`tools\runtime` next to the exe** or above it, the copy compiled in | `TreadleBackend/src/Driver/Builder.bf` |
| lldb-dap | `TREADLE_LLDB_DAP`, else `bin\lldb-dap.exe` of the toolchain root | `TreadleDebug/src/LldbDapAdapter.bf` |

`TREADLE_NO_FALLBACK=1` (`LlvmRoot.NoFallback`) drops the developer fallbacks (`TREADLE_DEV_LLVM`, `TREADLE_DEV_LIBCLANG`,
`C:\Program Files\LLVM`), so a package is tested on the development machine with only its own contents.

## Making a package

Prerequisites, once per clone (nothing is downloaded when it is already there):

```
powershell -File scripts\get-llvm-mingw.ps1     # tools\llvm-mingw (pinned zip, sha256 checked); -From <folder> copies one on disk
powershell -File scripts\get-libclang.ps1       # tools\libclang (pinned, sha256 checked)
```

and Beef 0.43.6 (`C:\Program Files\BeefLang\bin\BeefBuild.exe`, or `TREADLE_BEEFBUILD`). `package.ps1` also takes the
toolchain from `TREADLE_LLVM` or `tools\llvm-mingw` of the repository, and libclang from `TREADLE_LIBCLANG` or the main
checkout when run in a git worktree (`-Llvm` / `-LibClang` name them explicitly).

1. **Version.** One version in three places, which `package.ps1` checks agree: `VERSION.txt` (`0.1.3-alpha`),
   `TreadleInfo.Version` + `Channel` in `TreadleCore/src/Document/CommandLine.bf` (`0.1.3`, `alpha`), and
   `FileVersion = "0.1.3.0"` / `ProductVersion = "0.1.3"` under `[Platform.Windows]` in `TreadleEditor/BeefProj.toml`.
2. **Package and prove it:**
   ```
   powershell -File scripts\package.ps1 -Verify [-VerifyDir <empty folder>]
   ```
   It builds the `ReleasePackage` configuration (BeefBuild, below-normal priority; with `-Verify` also `Release`, see
   "Self tests and the package build"), assembles `dist\Treadle-<version>-win64\` (an earlier package
   folder there is emptied first; any other non-empty folder is refused), checks that the packaged exe's `--version`
   prints `Treadle <VERSION.txt> (host contract n)`, writes `dist\Treadle-<version>-win64.zip` and
   `dist\Treadle-<version>-win64.zip.sha256`, then runs the proof below. `-NoBuild` packages the existing ReleasePackage
   build; `-NoDebugger` leaves lldb-dap out; `-TrimToolchainTo <folder>` writes only the trimmed toolchain (to
   measure it). Running it again gives the same package (idempotent).

## Self tests and the package build

The self tests (`TREADLE_SELFTEST=...`) are developer tools: the packages do not contain them. The editor project
`TreadleEditor` has three configurations:

| Configuration | Built by | `TREADLE_SELFTEST` define | The exe |
|---|---|---|---|
| `Debug` | developers (BeefBuild, `scripts/build-linux.sh`) | on | runs the self tests when `TREADLE_SELFTEST` is set |
| `Release` | developers, the Release self-test runs | on | the same, optimised |
| `ReleasePackage` | `scripts\package.ps1`, `scripts/package-linux.sh` | off | no self-test code; `TREADLE_SELFTEST` is ignored |

The define is in `TreadleEditor/BeefProj.toml` (`PreprocessorMacros` of the Debug and Release configs).
`ReleasePackage` is declared in `BeefSpace.toml`; Beef derives its optimisation and checks from "Release" in the
name, so it builds exactly like `Release` minus the define (a name containing "Test" would make BeefBuild build a
test runner, which is why the developers' configuration keeps the plain `Release` name). Every `SelfTest*.bf`
file, `ScaleProject.bf` and the self-test parts of `ImportHeader.bf`, `ReportProblem.bf`, `Updates.bf`,
`NodeMenu.bf`, `Shell.bf`, `Program.bf` (the headless start-up check) and `Desktop.bf` (the quiet window for a
self-test run) sit inside `#if TREADLE_SELFTEST`; `NoSelfTest.bf` stands in for the two members the frame loop
reads. The few `SelfTest*` fields left in the panels (pointer and popup positions a capture sets) are inert
data without the harness.

The proof checks it on the packaged exe: no `SELFTEST` string in it, smaller than the `Release` build of the same
source (2026-10-25: 5.9 MB against 6.9 MB on Windows), and started with `TREADLE_SELFTEST=smoke,quit` and
`TREADLE_WINDOW_HIDDEN=1` it starts normally (still running after 15 s, no `[SELFTEST]` line in its log), after
which the proof closes it. The debugger check that used to run inside the package now runs the `Release` build
copied into a second copy of the unpacked folder, so it still proves the package's `tools\llvm\bin\lldb-dap`.

## The proof (`-Verify`)

The zip is unpacked into `-VerifyDir` (default `%TEMP%\treadle-pkg-verify-<stamp>`) and the packaged exe runs with
`TREADLE_LLVM`, `TREADLE_CORE`, `TREADLE_LIBCLANG`, `TREADLE_RUNTIME`, `TREADLE_LLDB_DAP` unset,
`TREADLE_NO_FALLBACK=1`, its own `TREADLE_HOME` and a fresh `LOCALAPPDATA` (no cached runtime object, no settings),
on copies of the inputs:

| Command | Must |
|---|---|
| `Treadle.exe --version` | print `Treadle <version> (host contract n)` |
| `--build-run <copy of samples\m1>` (twice: fresh, then cached runtime) | exit 0 with m1's ten lines |
| `--build-run <copy of samples\m3-core> -- a b c` | exit 0, `3 words, 3 different` |
| `--import-c <copy of TreadleCImport\fixtures\small.cimport> --out <dir>` | exit 0, `small.cdecl` written, libclang loaded from the package |
| the packaged exe's bytes and size | no `SELFTEST` string; smaller than the `Release` build's exe |
| `TREADLE_SELFTEST=smoke,quit` `TREADLE_WINDOW_HIDDEN=1` (packaged exe) | a normal start: still running after 15 s (then closed), no `[SELFTEST]` line in its log |
| `TREADLE_SELFTEST=smoke,debug,quit` with the `Release` build in a copy of the unpacked folder (`TREADLE_SAMPLES` = a copy of the samples) | `[SELFTEST] done failures=0`, lldb-dap from that copy's `tools\llvm\bin` |
| `--build-run <unpacked>\samples\m3-core` (the shipped sample, built in place) | exit 0, the word counts |
| `--build-run <unpacked>\samples\m2-sdl -- --frames 60` (opens its window for about a second) | exit 0, `frames 60`; `SDL2.dll` next to the program is the one of `tools\SDL2`, and the build's "C import paths outside the project folder" names `<unpacked>/tools/SDL2/` |
| `--build-run <unpacked>\samples\m4-breakout -- --headless` | exit 0, `frames 600 score ...` |

The package script also prints the sizes (the folder, `tools\llvm`, `tools\libclang`, `tools\SDL2`, `samples`, the
zip and what `tools\SDL2` and `samples` take of it), the sha256 and the shipped samples, and refuses a zip over
150 MB.

Results of 2026-10-25 after the rename (0.1.0-alpha, AMD Ryzen 7 7700, from the unpacked
`Treadle-0.1.0-alpha-win64.zip`, 118.4 MB):

```
[ok] --version  (exit 0, 147 ms)                         Treadle 0.1.0-alpha (host contract 1)
[ok] --build-run m1 (fresh: no runtime cache)  (exit 0, 821 ms)
[ok] --build-run m1 (again)  (exit 0, 340 ms)            build: ok (Debug) ... M1.exe in 48 ms
[ok] --build-run m3-core -- a b c  (exit 0, 747 ms)      3 words, 3 different / a: 1 / b: 1 / c: 1
[ok] --import-c small.cimport  (exit 0, 157 ms)          set small: 6 functions, 2 structs/unions, 1 enums, 2 typedefs, 2 constants, 3 variables
[ok] no SELFTEST string in the packaged exe; 5880832 bytes, the Release build with the self tests 6850560 bytes
[ok] TREADLE_SELFTEST=smoke,quit is ignored by the packaged exe (normal start, 0 self-test lines)  (exit running, 15000 ms)
[ok] TREADLE_SELFTEST=smoke,debug,quit (the Release build in the package layout)  (exit 0, 8999 ms)
     [SELFTEST] done failures=0 (lldb-dap: ...\test-layout\tools\llvm\bin\lldb-dap.exe)
```

With the samples (2026-10-25, wt/ship; `Treadle-0.1.0-alpha-win64.zip` 120.3 MB, of which `tools\SDL2` 1.2 MB and
`samples` 0.2 MB; 434.3 MB unpacked), every check above passed, and the three sample checks:

```
[ok] --build-run samples\m3-core (shipped, in place)  (exit 0, 635 ms)
[ok] --build-run samples\m2-sdl -- --frames 60 (SDL2.dll from tools\SDL2: True, its paths named: True)  (exit 0, 1802 ms)
[ok] --build-run samples\m4-breakout -- --headless  (exit 0, 899 ms)
```

The exe carries the Treadle icon (`TreadleEditor/BeefProj.toml` `IconFile`), and the host sets it as the window icon.

The build log of the run shows every clang call from the package's `tools\llvm\bin\clang.exe`; with `core\Console.treadle`
taken out of the unpacked package, m1's build fails, so the core comes from the package's `core\` folder.

## Linux package

`Treadle-<version>-linux-x64.tar.gz` holds one folder, `Treadle-<version>-linux-x64/`, that a user unpacks anywhere
and runs. `scripts/package-linux.sh` builds it on Linux (WSL2 Ubuntu 26.04 is where it is made and proven) from the
same `VERSION.txt`; `--verify` proves it from the unpacked copy. User side: [Linux.md](Linux.md); what is bundled: [Linux-Development.md](Linux-Development.md), "Package".

### Bundling decision

**Decision: self-contained. A trimmed copy of the distribution's LLVM 22 ships in `tools/llvm`**, with the
libraries it needs that are not "required" priority on Ubuntu, and SDL2 next to the editor's host. The tarball is
101 MB, well under the 250 MB line, and a user installs one package, `libc6-dev` (glibc's headers and start-up
files, which the programs Treadle builds link against; they stay the system's, as glibc must match the system).
The other form, a tarball that relies on `apt install clang-22 lld-22 lldb-22 libclang-22-dev libsdl2-2.0-0`, would
be about 11 MB but ties every user to that exact LLVM major in their distribution and to five packages; it stays
the fallback if the package ever passes 250 MB.

Measured 2026-10-25 from Ubuntu 26.04's `clang-22`, `lld-22`, `lldb-22`, `libclang-22-dev` 1:22.1.2-1ubuntu1
(`/usr/lib/llvm-22`), `tar | gzip -9` as the script does:

| Piece | Folder | tar.gz |
|---|---|---|
| Trimmed LLVM 22 (`tools/llvm`, all of the below) | 307.3 MB | 96.5 MB |
| of which the debugger (`lldb-dap`, `lldb-server`, `liblldb`, `libpython3.14`, `libipt`, ncurses, expat) | 31.3 MB | 11.1 MB |
| of which `libclang.so` (the C import) | 32.9 MB | 11.4 MB |
| `libSDL2-2.0.so.0` (2.32.10, the editor host's) | 1.9 MB | 0.7 MB |
| **The package** (editor with DWARF stripped, core, the above, samples, docs, licences) | **320.2 MB** | **100.9 MB** |

`libLLVM.so.22.1` alone is 150 MB of the toolchain (the distribution builds every target into it); a pinned LLVM
built for x86-64 only would be smaller, and that is the way to shrink this, not leaving pieces out.

The subset is `packaging/llvm-files-linux.txt` (the syntax of `llvm-files.txt`, plus `a -> b` symbolic links and
absolute paths for system libraries copied into `lib/`):

| Part | Files | Why |
|---|---|---|
| compiler driver, linker | `bin/clang`, `bin/lld`, `bin/ld.lld -> lld` | the back end runs `clang` for `.ll` -> `.o` and the link; `-fuse-ld=lld` runs `ld.lld` |
| target defaults | `bin/x86_64-pc-linux-gnu.cfg` (from `packaging/`): `--rtlib=compiler-rt --unwindlib=none` | links compiler-rt's builtins and `clang_rt.crtbegin/crtend` in place of libgcc and GCC's crtbegin, so no GCC has to be installed |
| LLVM libraries | `lib/libLLVM.so.22.1`, `lib/libclang-cpp.so.22.1` | loaded by clang, lld and lldb |
| C import | `lib/libclang.so` (the file `libclang-22.so.22`) | found as `lib/libclang.so` of the LLVM root (`LibClang.Candidates`); its builtin headers are `lib/clang/22/include` beside it |
| debugger | `bin/lldb-dap`, `bin/lldb-server` (+ Debian's versioned links `lldb-server-22`, `lldb-server-22.1.2`), `bin/lldb-argdumper`, `lib/liblldb-22.so.1` | lldb on Linux launches and controls the program through `lldb-server gdbserver`, which Debian's liblldb starts as `lldb-server-22.1.2` |
| clang resource dir | `lib/clang/22/include/`, `lib/clang/22/lib/linux/libclang_rt.builtins-x86_64.a`, `clang_rt.crtbegin-x86_64.o`, `clang_rt.crtend-x86_64.o` | builtin headers, compiler-rt |
| system libraries | `libz3.so.4`, `libxml2.so.16`, `libedit.so.2`, `libffi.so.8`; for the debugger `libpython3.14.so.1.0`, `libexpat.so.1`, `libipt.so.2`, `libncurses.so.6`, `libpanel.so.6`, `libform.so.6` | needed by libLLVM / liblldb and "optional" priority on Ubuntu (a system may lack them); found through the binaries' RUNPATH `$ORIGIN/../lib` |

Not shipped, the system's: glibc, libstdc++, libgcc_s, zlib, zstd, liblzma, libtinfo, libbsd / libmd ("required"
priority), and libcurl with its TLS stack (liblldb's; its security updates must come from the distribution). Left
out of LLVM: every other tool, the static libraries, the sanitizer and profile runtimes, the i386 and Windows
compiler-rt, the Python lldb module (lldb-dap runs with `--no-lldbinit` and no scripting).

### Linux layout

```
Treadle-<version>-linux-x64/
  TreadleEditor  libtreadlehost.so  libSDL2-2.0.so.0   the editor, its native host (RUNPATH $ORIGIN) and its SDL2
  assets/fonts/                                    the icon font and its licence
  core/                                            the core library (.treadle files, crt.cimport, crt.linux.cimport, crt.cdecl)
  tools/llvm/                                      the trimmed LLVM 22 (above) and its LICENSE.TXT
  tools/runtime/treadle_rt.c, .h                   the C runtime every program is built with
  samples/<name>/  samples/README.md               the sample projects of packaging/samples.txt and their index
  docs/                                            the user pages of the Windows zip (and docs/images when present)
  LICENSE  NOTICE  THIRD_PARTY.md  THIRD_PARTY/  THIRD_PARTY/linux/<package>.copyright  VERSION.txt
```

The editor finds its pieces as on Windows ("How the editor finds its pieces"): `tools/llvm` next to the exe
(`LlvmRoot.Get`, which needs `bin/clang`) comes before `/usr/lib/llvm-22`; libclang is `lib/libclang.so` of that
root; `core/` and `tools/runtime` next to the exe; lldb-dap is `bin/lldb-dap` of the root. No Linux lookup had to
change. The updater installs the tarball into the unpacked folder as it installs the zip on Windows (section "The
update path").

### Making it

On Ubuntu 26.04 with the packages of [Linux-Development.md](Linux-Development.md) and BeefBuild (`~/beef/IDE/dist`), from a copy of the
repository on a Linux file system (BeefBuild is slow on `/mnt/d`):

```
scripts/package-linux.sh --verify [--verify-dir <empty folder>]
```

It waits while another BeefBuild runs, builds ReleasePackage (`scripts/build-linux.sh ReleasePackage none`, niced;
with `--verify` also Release), assembles
`dist/Treadle-<version>-linux-x64/` (an earlier package folder there is emptied first), checks that `VERSION.txt`
agrees with `TreadleInfo` and that the packaged exe's `--version` prints it, writes
`dist/Treadle-<version>-linux-x64.tar.gz` (sorted, owner 0, the last commit's time) and its `.sha256`, then runs
the proof. `--no-build`, `--no-debugger`, `--llvm <root>`, `--out`, `--dist` and `--trim-toolchain-to <folder>`
work as in `package.ps1`. The script refuses a `libtreadlehost.so` without RUNPATH `$ORIGIN` (`Native/build_linux.sh`
links it so).

### The Linux proof (`--verify`)

The tarball is unpacked into the verify folder and every check runs the packaged exe with `TREADLE_LLVM`,
`TREADLE_CORE`, `TREADLE_LIBCLANG`, `TREADLE_RUNTIME`, `TREADLE_LLDB_DAP`, `TREADLE_SAMPLES`, `LD_LIBRARY_PATH`
unset, `TREADLE_NO_FALLBACK=1`, its own `TREADLE_HOME` and a fresh `XDG_CACHE_HOME` (no cached runtime object).
Where unprivileged mount namespaces work (`unshare -rm`, as under WSL2), each check also runs with the system's
LLVM 22 (`/usr/lib/llvm-22`, `libLLVM`, `libclang-cpp`, `libclang`, `liblldb`, `libz3`, `libpython3.14`,
`libipt`), GCC's files (`/usr/lib/gcc`) and SDL2 hidden (bound over with an empty folder or `/dev/null`): the
package works on a system that has none of them. The checks are the Windows ones: `--version`, `--build-run m1`
fresh and again, `--build-run m3-core -- a b c`, `--import-c small.cimport`, the packaged exe without self tests
(no `SELFTEST` string, smaller than the Release build, `TREADLE_SELFTEST` ignored: `timeout` ends the normal
start after 15 s) and `TREADLE_SELFTEST=smoke,debug,quit` with the Release build in a copy of the unpacked
folder (lldb-dap from that copy's `tools/llvm/bin`). Then the shipped samples, built in place in the unpacked
folder: `samples/m3-core`, `samples/m4-breakout -- --headless` and, where a display exists (`DISPLAY` or
`WAYLAND_DISPLAY`; else the check is skipped with a note), `samples/m2-sdl -- --frames 60`; the SDL samples run
with `LD_LIBRARY_PATH` set to the package folder, as the system's SDL2 is hidden.

Results of 2026-10-25 after the rename (0.1.0-alpha, WSL2 Ubuntu 26.04.1, AMD Ryzen 7 7700,
`Treadle-0.1.0-alpha-linux-x64.tar.gz`, 103.3 MB), with the system's LLVM 22, GCC files and SDL2 hidden:

```
[ok] --version  (exit 0, 113 ms)                          Treadle 0.1.0-alpha (host contract 1)
[ok] --build-run m1 (fresh: no runtime cache)  (exit 0, 1015 ms)
[ok] --build-run m1 (again)  (exit 0, 114 ms)
[ok] --build-run m3-core -- a b c  (exit 0, 714 ms)        3 words, 3 different / a: 1 / b: 1 / c: 1
[ok] --import-c small.cimport  (exit 0, 115 ms)            libclang: Ubuntu clang version 22.1.2 (1ubuntu1) (.../tools/llvm/lib/libclang.so)
[ok] no SELFTEST string in the packaged exe, smaller than the Release build  (exit 0, 0 ms)
    packaged 9272152 bytes, the Release build with the self tests 10533752 bytes (both without debug info)
[ok] TREADLE_SELFTEST=smoke,quit is ignored by the packaged exe (normal start)  (exit 124, 17629 ms)
[ok] TREADLE_SELFTEST=smoke,debug,quit (the Release build in the package layout)  (exit 0, 8029 ms)
```

With the samples (2026-10-25, wt/ship; `Treadle-0.1.0-alpha-linux-x64.tar.gz` 104.0 MB, 325.8 MB unpacked), every
check above passed, and:

```
[ok] --build-run samples/m3-core (shipped, in place)  (exit 0, 1017 ms)
[ok] --build-run samples/m4-breakout -- --headless (the package's libSDL2)  (exit 0, 718 ms)
[ok] --build-run samples/m2-sdl -- --frames 60 (the package's libSDL2)  (exit 0, 5431 ms)
```

The tarball also carries `treadle.png` (the 256 px icon) and `install-desktop.sh`, which writes a per-user
`treadle.desktop` for the folder it is in (docs/Linux.md).

The build log of the self test shows every clang call from the package's `tools/llvm/bin/clang` and the runtime
from its `tools/runtime`. Without the `lldb-server-22.1.2` link the debug check fails (the program "exited with
code -1"): that is the name Debian's liblldb starts.

**Open:** the package runs where its glibc (2.43) and `libxml2.so.16` do: Ubuntu 26.04 and distributions of its
generation. For older ones, build the package on the oldest distribution to support (or from a pinned LLVM built
there); an AppImage would carry the same tree.

## The update path

Installed copies update themselves from the GitHub Releases of `https://github.com/AproposRobin/Treadle`
(`ReleaseChannel.Repository` in `TreadleCore/src/Update/Releases.bf`, the one place the repository is named). Nothing
else is contacted: no service of ours, no telemetry. Code: `TreadleCore/src/Update/` (Releases, UpdateHttp,
UpdateService, UpdateApply), user side `TreadleEditor/src/Updates.bf` and `UpdateCli.bf`.

### The asset-name contract

Every installed copy looks for these names. **They must never change.**

| Asset | Content |
|---|---|
| `Treadle-<version>-win64.zip` | the Windows package, files at the zip's root |
| `Treadle-<version>-linux-x64.tar.gz` | the Linux package, one top folder `Treadle-<version>-linux-x64/` |
| `SHA256SUMS` | one `<64 hex>  <asset name>` line per package, as `sha256sum` writes it |

The tag is `v<version>` where `<version>` is the `VERSION.txt` line (`v0.1.3-alpha`). A package carries `files.txt`
at its root: every other file (and, on Linux, link) of the package, relative, `/` separators. `package.ps1` and
`package-linux.sh` write it; the updater installs and removes files by it.

### What a release must do

1. Bump the version in the three places `package.ps1` checks (VERSION.txt, `TreadleInfo` in
   `TreadleCore/src/Document/CommandLine.bf`, the `[Platform.Windows]` versions of `TreadleEditor/BeefProj.toml`).
2. `scripts\package.ps1 -Verify` and `scripts/package-linux.sh --verify` (both end with the update rehearsal below).
3. Write `SHA256SUMS` from the two `.sha256` files (`cat dist/*.sha256 > dist/SHA256SUMS` gives the right format).
4. Create the GitHub Release `v<version>` with the two packages and `SHA256SUMS`. Not a draft (drafts are never
   offered); "pre-release" only for builds that only the alpha channel should get (the default channel is alpha, so
   alpha users get pre-releases too; stable users only releases not marked pre-release).

### What the editor does

* **Check**: Help > Check for Updates at any time, and once a day (`checkForUpdates`, on by default) a few seconds
  after start and every 24 h while open; nothing when Work offline is on. One request,
  `GET https://api.github.com/repos/AproposRobin/Treadle/releases?per_page=20` (ETag-cached, so a repeat costs no rate
  limit), through the system's curl. The offer is the newest release that is not a draft, is a pre-release only on
  the alpha channel, has a version (the tag without `v`) above the running one in semver order with pre-release
  parts, is not in the skipped list, and carries this platform's package and `SHA256SUMS`. A failed automatic check
  is silent (one log line); a manual one says why.
* **Offer**: the notice line "Treadle X is available" with Update now / What changed (the release notes in a panel,
  not a browser) / Later (hidden for the session) / Skip this version (never offered again). Never modal.
* **Download and verify**: `SHA256SUMS` first, then the package, from
  `https://github.com/AproposRobin/Treadle/releases/download/<tag>/<name>` into `<install>/update/dl/`,
  with the progress in the status bar. The package's SHA-256 must equal its `SHA256SUMS` line (and its size the
  size the API gave); otherwise it is deleted and refused. It is then unpacked into `<install>/update/new/` with the system's tar, and its layout,
  `VERSION.txt` and `files.txt` checked.
* **Apply** (Restart to finish): the editor saves everything (untitled files block it), copies its program and
  native libraries to `<install>/update/helper/`, starts that copy as
  `--apply-update <install> <pid> <staged> <update dir> -- <editor arguments>` and exits. The helper waits for the
  editor, keeps a copy of every file it will overwrite or remove in `<install>/update/old/`, copies in every file
  of the new `files.txt`, removes files the old `files.txt` listed that the new one does not, and leaves everything
  else alone (projects, settings, layouts, user files inside package folders). It starts the new editor with the same
  arguments; the editor answers the helper's health request after its first frames. If it exits first or does not
  answer in 60 s, the helper restores `old` and starts the old version. Every step goes to
  `<install>/update/update.log`; the next start shows the outcome once and, after a healthy install, the rollback copy
  is deleted. Linux: the same with the tarball; executable bits and symbolic links are kept.
* **Read-only installs** (Program Files, a system folder): the notice says the install folder is read-only, with the
  release link as text, and the download is by hand. Copies with `host-install.json` and builds from source (no
  `VERSION.txt`) never update themselves.
* **Command line**: `Treadle.exe --update [--check-only]` does the same check, download, verify and helper start
  without a window (the helper restarts the program with `--update-health`, which answers the health check and
  exits).

### TREADLE_UPDATE_INDEX (rehearsals and tests)

`TREADLE_UPDATE_INDEX=<folder>` makes any build, the shipped one included, read the release list from
`<folder>/releases.json` (the API's list format) and every asset from `<folder>/<asset name>` instead of GitHub. It is
logged when used. It exists in release builds on purpose: the package rehearsal runs the shipped exe. It adds no trust
beyond the user's own environment (whoever can set a user's environment variables can already run code as them).

### The rehearsal (`-Verify`, `--verify`)

The last check of both package scripts. Package A = a copy of the unpacked package with `VERSION.txt`
`0.0.1-rehearsal`, an extra listed file `docs/rehearsal-old-page.md`, and user files (`projects/MyGame/MyGame.tproj`,
`samples/m1/my-notes.txt`). The index holds the package just built as release B with its `SHA256SUMS`. A's
`--update` must find B, verify it and start the helper; after the helper ends: `VERSION.txt` and `--version` are B's,
`files.txt` is B's, the A-only file is gone, the user files are there, the rollback copy is cleared and update.log
says "update complete"; a second `--update` says up to date. On Linux it also checks the executable bits and the
`ld.lld` link.
