---
audience: developer
title: Building from source
summary: Building Treadle from a clone on Windows and Linux: what to install, the pinned tools, the native host, the Debug, Release and ReleasePackage configurations, the self tests, the command-line modes and the package scripts.
order: 5
---

# Building from source

## Windows

From a `cmd` prompt in the repository root. You need Git, Windows 10 or 11 (PowerShell 5.1 and `tar.exe` are
part of it) and Beef **0.43.6, the nightly of 2026-09-14**
(<https://nightly.beeflang.org/BeefSetup_0_43_6__09_14_2026.exe>, installed to the default
`C:\Program Files\BeefLang`; another nightly is a different compiler and is not tested). Everything else is
fetched into `tools\` (git-ignored) by the `get-*` scripts, each pinned by sha256; `-From <folder>` copies an
unpacked copy you already have instead of downloading.

```
powershell -File scripts\get-llvm-mingw.ps1
powershell -File scripts\get-sdl2.ps1
powershell -File scripts\get-libclang.ps1
powershell -File Native\build_windows.ps1
"C:\Program Files\BeefLang\bin\BeefBuild.exe" -workspace=. -config=Debug -platform=Win64
"C:\Program Files\BeefLang\bin\BeefBuild.exe" -workspace=. -config=Release -platform=Win64
set TREADLE_SELFTEST=smoke,codec,editor,backend,frontend,cimport,core,debug,tutorial,fatal,scale,quit
build\Debug_Win64\TreadleEditor\Treadle.exe
build\Release_Win64\TreadleEditor\Treadle.exe
```

1. The `get-*` lines install the pinned toolchain once: llvm-mingw 20261006 (clang, lld, lldb-dap: the back
   end, the runtime and the debugger) under `tools\llvm-mingw`, the SDL2 2.32.10 mingw devel package (the
   native host and the m2-sdl sample) under `tools\SDL2-2.32.10`, and libclang 23.1.3 (the C header import)
   under `tools\libclang` ([Toolchain.md](Toolchain.md), "What is pinned"). The editor finds them there by
   looking in the source tree it was built in (`build\<Config>_Win64\TreadleEditor` three folders below the
   repository root: no other parent folder is searched); `TREADLE_LLVM`, `TREADLE_SDL2` and `TREADLE_LIBCLANG`
   point it elsewhere.
2. `Native\build_windows.ps1` rebuilds the native host `Native\bin\win64\treadlehost.dll` + `treadlehost.lib`
   (SDL2, OpenGL 3, Dear ImGui and imnodes; about a minute). It is optional: the host binaries are committed,
   and a rebuild with the pinned toolchain gives the same bytes (the script prints the sha256 and compares it
   with `packaging\host-sha256.txt`).
3. The BeefBuild lines build the editor into `build\` (git-ignored). In PowerShell quote the workspace
   argument, `"-workspace=."`, and use `$env:TREADLE_SELFTEST = '...'` in place of the `set` line. The exe is
   `Treadle.exe`; the Beef runtime DLLs and `treadlehost.dll` are copied next to it. `Treadle.exe <project
   folder>` opens a project.
4. The `set` line and the two exe lines after it run the self tests in each build and exit (start the exe
   from the repository root, as here). The results are the `[SELFTEST]` lines of the session log
   (`%LOCALAPPDATA%\Treadle\logs\treadle-<date>.log`, or under `TREADLE_HOME` when set), ending in
   `[SELFTEST] done failures=N`. Test runs open a quiet window: off-screen, without a taskbar button, never
   activated, still rendered (`TREADLE_WINDOW_VISIBLE=1` shows a normal window).

### Configurations

| Configuration | What it is | The self tests |
|---|---|---|
| `Debug` | development build, runtime checks on | compiled in (the `TREADLE_SELFTEST` define) |
| `Release` | optimised, the build the Release self-test runs use | compiled in |
| `ReleasePackage` | `Release` without the define: what the packages ship | not in the exe; `TREADLE_SELFTEST` is ignored |

The define is set in `TreadleEditor/BeefProj.toml` (`PreprocessorMacros`); the self-test sources are wrapped in
`#if TREADLE_SELFTEST`. [Releasing.md](Releasing.md), "Self tests and the package build", has the details.

### Command-line modes

```
Treadle.exe --build-run <project folder> [--config Release] [-- <program arguments>...]
Treadle.exe --import-c <file.cimport> [--out <dir>]
Treadle.exe --format <project folder or file>... [--check]
Treadle.exe --format --migrate <project folder or file>... [--check]
Treadle.exe --version
Treadle.exe --update [--check-only]
```

`--update` checks GitHub Releases (or `TREADLE_UPDATE_INDEX`, a local release index: [Releasing.md](Releasing.md),
"The update path"), downloads and verifies a newer package and starts the helper that installs it, without a window.

`--format --migrate` also renames files that still carry the extensions from before the product rename
(`.vtype`, `.vtype.layout`, `.vproject`, `.kir`) to the current ones ([Format-Stability.md](Format-Stability.md)).

## Linux

x86-64 Linux with glibc (made and proven on Ubuntu 26.04 under WSL2): the packages and Beef build of
[Linux-Development.md](Linux-Development.md), then

```
scripts/build-linux.sh [Debug|Release|both|ReleasePackage] [self-test list|none]
build/Release_Linux64/TreadleEditor/treadle --build-run TreadleCore/samples/m3-core [--config Release]
```

## Packages

`scripts\package.ps1 -Verify` (Windows) and `scripts/package-linux.sh --verify` (Linux) build the
`ReleasePackage` configuration and assemble `dist\Treadle-<version>-win64.zip` and
`dist/Treadle-<version>-linux-x64.tar.gz`, then prove them from an unpacked copy ([Releasing.md](Releasing.md)).
