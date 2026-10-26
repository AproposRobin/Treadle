# Third-party notices

Treadle itself is licensed under the Apache License, Version 2.0 (`LICENSE`, attribution in
`NOTICE`). The components below are bundled with it or linked into the binaries it produces and keep
their own licences. The exact upstream licence texts are in the `THIRD_PARTY/` folder, which ships in
every package next to this file, so every distribution of `Treadle.exe` + `treadlehost.dll`
carries them. Nothing here is proprietary and nothing is under a copyleft licence that would apply
to Treadle. Treadle is derived from VisualBeef (Apache-2.0, see `NOTICE`).

## What is in the Windows package

| Component | Version | Licence | Where it ends up | Licence text |
|---|---|---|---|---|
| Dear ImGui (docking branch) | 1.92.9b | MIT, (c) 2014-2026 Omar Cornut | compiled into `treadlehost.dll`; source in `Native/third_party/cimgui/imgui/` | `THIRD_PARTY/ImGui-LICENSE.txt` |
| stb_truetype 1.26, stb_rect_pack, stb_textedit | as embedded in Dear ImGui 1.92.9b | public domain, or MIT (alternative A in each header) | compiled into `treadlehost.dll` | the header comments in `Native/third_party/cimgui/imgui/imstb_*.h` (public domain dedication and MIT text) |
| cimgui (C bindings for Dear ImGui) | generated for Dear ImGui 1.92.9b docking | MIT, (c) 2015 Stephan Dilly | compiled into `treadlehost.dll`; source in `Native/third_party/cimgui/` | `THIRD_PARTY/cimgui-LICENSE.txt` |
| imnodes | as vendored in `Native/third_party/cimnodes/imnodes/` | MIT, (c) 2019 Johann Muszynski | compiled into `treadlehost.dll` (not used at run time, see below) | `THIRD_PARTY/imnodes-LICENSE.txt` |
| cimnodes (C bindings for imnodes) | as vendored in `Native/third_party/cimnodes/` | generated from imnodes by the cimgui generator; the upstream repository has no licence file of its own, so imnodes's MIT licence is the one that applies | compiled into `treadlehost.dll` | `THIRD_PARTY/imnodes-LICENSE.txt` |
| SDL2 | 2.32.10 (`SDL2-devel-2.32.10-mingw.zip`) | zlib, (c) 1997-2025 Sam Lantinga | **statically linked** into `treadlehost.dll` | `THIRD_PARTY/SDL2-LICENSE.txt` |
| SDL2 development files for the SDL samples (`SDL2.dll`, `libSDL2.dll.a`, the `include/SDL2` headers, x86_64 only) | 2.32.10, unmodified from `SDL2-devel-2.32.10-mingw.zip` (archive sha256 in `scripts/get-sdl2.ps1`, file sha256 in `packaging/sdl2-files.txt`) | zlib, (c) 1997-2025 Sam Lantinga | shipped as `tools/SDL2/x86_64-w64-mingw32/` for `samples/m2-sdl` and `samples/m4-breakout`; Build copies `SDL2.dll` next to a program that imports SDL2 | `THIRD_PARTY/SDL2-LICENSE.txt` (also `tools/SDL2/LICENSE.txt`) |
| LLVM C++ runtime from llvm-mingw 20261006 (clang 23.1.3): libc++, libc++abi, libunwind, compiler-rt builtins | as released in llvm-mingw 20261006 | Apache-2.0 with LLVM Exceptions | **statically linked** into `treadlehost.dll` (`-static`) | `THIRD_PARTY/LLVM-LICENSE.txt` |
| mingw-w64 runtime (CRT start-up code, import libraries, headers) | the mingw-w64 revision llvm-mingw 20261006 is built from (`a3d93999ef0521681d45e445c39964a7af0f593f`) | permissive (ZPL / BSD-style / public domain parts; list in the file) | statically linked into `treadlehost.dll` | `THIRD_PARTY/mingw-w64-runtime-COPYING.txt` (`COPYING.MinGW-w64-runtime.txt`, the file meant for binaries) |
| Lucide icons (`lucide.ttf`) | 0.460.0 | ISC | shipped as `assets/fonts/lucide.ttf` | `THIRD_PARTY/Lucide-LICENSE.txt` (also `assets/fonts/LICENSE-lucide.txt`) |
| Beef language runtime and corlib | 0.43.6 (nightly 2026-09-14, commit `19ee8d2e`) | MIT, (c) 2019 BeefyTech LLC | linked statically into `Treadle.exe` | `THIRD_PARTY/Beef-LICENSE.txt`; the third-party list of the Beef install (`LICENSES.TXT`: cJSON, FreeType, libffi, tcmalloc, utf8proc, LLVM and others) is `THIRD_PARTY/Beef-LICENSES.txt` |
| llvm-mingw toolchain, trimmed (clang 23.1.3 driver `clang.exe` / `clang-23.exe`, `ld.lld.exe`, `libLLVM-23.dll`, `libclang-cpp.dll`, `libc++.dll`, `libunwind.dll`, clang's builtin headers, `libclang_rt.builtins-x86_64.a`) | llvm-mingw 20261006 (`llvm-mingw-20261006-ucrt-x86_64.zip`, sha256 in `docs/Toolchain.md`) | Apache-2.0 with LLVM Exceptions (LLVM); the toolchain's own `LICENSE.TXT` | shipped as `tools/llvm/` (the subset is `packaging/llvm-files.txt`); compiler-rt builtins and libunwind are linked into the programs Treadle builds | `THIRD_PARTY/LLVM-LICENSE.txt` (also `tools/llvm/LICENSE.TXT`) |
| lldb 23.1.3 (`lldb-dap.exe`, `liblldb.dll`) | from llvm-mingw 20261006 | Apache-2.0 with LLVM Exceptions | shipped in `tools/llvm/bin/` (the debugger) | `THIRD_PARTY/LLVM-LICENSE.txt` |
| Python runtime DLL (`libpython3.14.dll`, imported by `liblldb.dll`; no Python library or scripts) | 3.14, as built by llvm-mingw 20261006 | PSF License Agreement (Python-2.0) | shipped in `tools/llvm/bin/` | `THIRD_PARTY/Python-LICENSE.txt` (`python/LICENSE.txt` of the llvm-mingw zip) |
| mingw-w64 headers, CRT objects and import libraries (the toolchain's sysroot: `include/`, `x86_64-w64-mingw32/lib/`) | the mingw-w64 revision above | permissive (ZPL / BSD-style / public domain parts) | shipped in `tools/llvm/`; the CRT start-up objects and the static parts of the runtime are linked into the programs Treadle builds | `THIRD_PARTY/mingw-w64-runtime-COPYING.txt` |
| libclang (`libclang.dll`, MSVC build, and clang's builtin headers) | LLVM 23.1.3 (`clang+llvm-23.1.3-x86_64-pc-windows-msvc.tar.xz`, sha256 in `scripts/get-libclang.ps1`) | Apache-2.0 with LLVM Exceptions | shipped as `tools/libclang/` (the C header import) | `THIRD_PARTY/LLVM-LICENSE.txt` |

System libraries (the Windows universal C runtime `api-ms-win-crt-*`, `KERNEL32`, `USER32`, `GDI32`,
`OPENGL32`, `SETUPAPI`, `WINMM`, `IMM32`, `VERSION`, `ADVAPI32`, `SHELL32`, `OLE32`, `OLEAUT32`) are
imported from Windows and not shipped.

`treadlehost.dll` is built from source by `Native/build_windows.ps1` with the pinned llvm-mingw and SDL2
(versions and sha256 in the header of that script and in `scripts/ci-windows.ps1`); the release
build does that in GitHub Actions (`docs/CI.md`). The DLL contains no GCC runtime and no winpthreads. The build is
reproducible: the sha256 of `treadlehost.dll` and `libtreadlehost.so` is recorded in `packaging/host-sha256.txt`.
The Linux build (`libtreadlehost.so`) compiles the same Dear ImGui, cimgui, imnodes and cimnodes sources and
loads SDL2 dynamically (the Linux package ships the distribution's `libSDL2-2.0.so.0` next to it; section
"What is in the Linux package").

## What is in the Linux package

`Treadle-<version>-linux-x64.tar.gz` (`scripts/package-linux.sh`, docs/Releasing.md "Linux package") carries the
same `THIRD_PARTY/` folder, plus `THIRD_PARTY/linux/<package>.copyright`: the Debian copyright file of every
distribution package a shipped library comes from (copied at packaging time from `/usr/share/doc/<package>/`).
The libraries are the Ubuntu 26.04 builds, unmodified.

| Component | Version | Licence | Where it ends up | Licence text |
|---|---|---|---|---|
| Dear ImGui, stb, cimgui, imnodes, cimnodes | as in the Windows table | as in the Windows table | compiled into `libtreadlehost.so` | as in the Windows table |
| SDL2 (`libSDL2-2.0.so.0`) | 2.32.10 (Ubuntu `libsdl2-classic` 2.32.10+dfsg-6) | zlib | shipped next to `libtreadlehost.so` (loaded dynamically, not linked in); the SDL samples' programs link against it and load it at run time | `THIRD_PARTY/SDL2-LICENSE.txt`, `THIRD_PARTY/linux/libsdl2-classic.copyright` |
| Beef language runtime and corlib | as in the Windows table | MIT | linked statically into `TreadleEditor` | as in the Windows table |
| LLVM 22, trimmed: `clang`, `lld`, `libLLVM.so.22.1`, `libclang-cpp.so.22.1`, clang's builtin headers, compiler-rt builtins and `clang_rt.crtbegin/crtend` | 22.1.2 (Ubuntu `clang-22`, `lld-22`, `libllvm22`, `libclang-cpp22` 1:22.1.2-1ubuntu1) | Apache-2.0 with LLVM Exceptions | `tools/llvm/` (the subset is `packaging/llvm-files-linux.txt`); compiler-rt's builtins and start-up files are linked into the programs Treadle builds | `THIRD_PARTY/LLVM-LICENSE.txt` (also `tools/llvm/LICENSE.TXT`), `THIRD_PARTY/linux/{clang-22,lld-22,libllvm22}.copyright` |
| libclang (`libclang.so`, the file `libclang-22.so.22`) | 22.1.2 (Ubuntu `libclang1-22`) | Apache-2.0 with LLVM Exceptions | `tools/llvm/lib/` (the C header import) | `THIRD_PARTY/LLVM-LICENSE.txt`, `THIRD_PARTY/linux/libclang1-22.copyright` |
| lldb 22 (`lldb-dap`, `lldb-server`, `lldb-argdumper`, `liblldb-22.so.1`) | 22.1.2 (Ubuntu `lldb-22`, `liblldb-22`) | Apache-2.0 with LLVM Exceptions | `tools/llvm/` (the debugger) | `THIRD_PARTY/LLVM-LICENSE.txt`, `THIRD_PARTY/linux/{lldb-22,liblldb-22}.copyright` |
| Python runtime library (`libpython3.14.so.1.0`, linked by `liblldb`; no Python library or scripts) | 3.14.4 (Ubuntu `libpython3.14`) | PSF License Agreement (Python-2.0) | `tools/llvm/lib/` | `THIRD_PARTY/Python-LICENSE.txt`, `THIRD_PARTY/linux/libpython3.14.copyright` |
| Z3 (`libz3.so.4`, linked by `libLLVM`) | 4.13.3 (Ubuntu `libz3-4`) | MIT | `tools/llvm/lib/` | `THIRD_PARTY/linux/libz3-4.copyright` |
| libxml2 (`libxml2.so.16`, linked by `libLLVM` / `liblldb`) | 2.15.2 (Ubuntu `libxml2-16`) | MIT | `tools/llvm/lib/` | `THIRD_PARTY/linux/libxml2-16.copyright` |
| libedit (`libedit.so.2`) | 3.1-20251016 (Ubuntu `libedit2`) | BSD-3-Clause | `tools/llvm/lib/` | `THIRD_PARTY/linux/libedit2.copyright` |
| libffi (`libffi.so.8`) | 3.5.2 (Ubuntu `libffi8`) | MIT | `tools/llvm/lib/` | `THIRD_PARTY/linux/libffi8.copyright` |
| Expat (`libexpat.so.1`, linked by `libpython3.14`) | 2.7.4 (Ubuntu `libexpat1`) | MIT | `tools/llvm/lib/` | `THIRD_PARTY/linux/libexpat1.copyright` |
| libipt (`libipt.so.2`, Intel Processor Trace decoder, linked by `liblldb`) | 2.1.2 (Ubuntu `libipt2`) | BSD-3-Clause | `tools/llvm/lib/` | `THIRD_PARTY/linux/libipt2.copyright` |
| ncurses (`libncurses.so.6`, `libpanel.so.6`, `libform.so.6`, linked by `liblldb`) | 6.6 (Ubuntu `libncurses6`) | MIT-style (X11) | `tools/llvm/lib/` | `THIRD_PARTY/linux/libncurses6.copyright` |

System libraries (glibc, libstdc++, libgcc_s, zlib, zstd, liblzma, libtinfo, libbsd, libmd, libcurl and its TLS
stack, libGL and what SDL2 loads for X11 / Wayland / audio) are the system's and not shipped. The programs Treadle
builds on Linux link the system's glibc (from `libc6-dev`) and the packaged compiler-rt; no GCC runtime.

## Not shipped, used at run time or to build

* **BeefBuild** builds the editor itself (it is written in Beef); a Treadle program never needs Beef.
* **Build tools** (not part of the package): the rest of llvm-mingw 20261006 (only the trimmed subset in the
  table ships), the static `libSDL2.a` and the rest of the mingw-w64 SDL2 development package (the package ships
  only the files of `packaging/sdl2-files.txt` and the headers), 7-Zip
  (LGPL) to unpack the Beef installer in CI.
  The compiler output contains only the runtime pieces listed above.

imnodes is compiled into `treadlehost.dll` and has Beef bindings (`Native/src/ImNodes.bf`), but the node
canvas is drawn by the editor itself (`GraphPanel.bf`); imnodes is unused at run time.

## Licence files per vendored folder

* `Native/third_party/cimgui/imgui/LICENSE.txt`: identical to upstream `ocornut/imgui` `LICENSE.txt` at
  v1.92.9b-docking.
* `Native/third_party/cimgui/LICENSE`: identical to upstream `cimgui/cimgui` `LICENSE`.
* `Native/third_party/cimnodes/imnodes/LICENSE.md`: identical to upstream `Nelarius/imnodes` `LICENSE.md`.
* `Native/third_party/cimnodes/`: the cimnodes repository carries no licence file; see the table.
* `TreadleEditor/assets/fonts/LICENSE-lucide.txt`: identical to upstream `lucide-icons/lucide` `LICENSE`
  at 0.460.0.

The copies in `THIRD_PARTY/` are byte-for-byte the upstream texts (line endings aside), taken from:
Dear ImGui, cimgui, imnodes, Lucide (their repositories at the versions above), SDL2 (`LICENSE.txt` of
`SDL2-devel-2.32.10-mingw.zip`), LLVM (`LICENSE.TXT` of `llvm-mingw-20261006-ucrt-x86_64.zip`), Python (`python/LICENSE.txt` of the same zip), mingw-w64
(`COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt` at the revision above), Beef (`LICENSE.TXT` and
`LICENSES.TXT` of `BeefSetup_0_43_6__09_14_2026.exe`).
