---
audience: user
title: Linux
summary: Treadle on x86-64 Linux: what your system needs, unpacking and running the package, where your files go, what is different from Windows, and what does not work yet.
order: 10
---

# Linux

Treadle runs on x86-64 Linux with glibc. The Linux package is a tarball, `Treadle-<version>-linux-x64.tar.gz`,
with the same editor, core library and samples as the Windows zip, and its own copy of the compiler, linker and
debugger: no compiler or SDL2 package is needed on your system. This page is also in the editor's **Help** menu.

## What you need

* **x86-64 Linux with glibc 2.43 or newer.** The package is made on Ubuntu 26.04; distributions of the same
  generation work. Older ones (Ubuntu 24.04, glibc 2.39) cannot run it yet.
* **One package:**

  ```
  sudo apt install libc6-dev        # glibc's headers, crt1.o / crti.o and libc.so / libm.so for the programs you build
  ```

  That is all on Ubuntu 26.04. glibc, libstdc++, zlib, zstd, liblzma, libtinfo and libbsd come with every
  install. No GCC, LLVM or SDL2 package is needed.
* **A desktop session** for the editor: X11, or Wayland with XWayland (libGL and what SDL2 loads). Building a
  program from the command line needs none.
* **The debugger** needs `libcurl4t64`, which desktop installs already have.

## Install and run

```
tar xzf Treadle-0.1.2-alpha-linux-x64.tar.gz
cd Treadle-0.1.2-alpha-linux-x64
./treadle                                   # the editor
./treadle samples/m1                        # open a sample
./treadle --build-run samples/m3-core -- a b c
./install-desktop.sh                        # optional: Treadle in the application menu, with its icon
```

The folder can live anywhere. `install-desktop.sh` writes `~/.local/share/applications/treadle.desktop` for the
folder it is in (run it again after moving the folder; delete that file to remove the entry). To update,
unpack the new tarball next to the old one; there is no updater on Linux yet. [Getting-Started.md](Getting-Started.md) is the first hour in the editor, the same on both platforms.

## Your files

* Settings, the window layout, logs and recovery: `~/.local/share/Treadle` (`TREADLE_HOME` moves them).
* Crash reports: `$XDG_STATE_HOME/treadle/crashes` (else `~/.local/state/treadle/crashes`).
* The compiled runtime cache: `$XDG_CACHE_HOME/treadle/runtime` (else `~/.cache/treadle/runtime`).

## Closing the editor

The editor closes cleanly on SIGTERM (`kill <pid>`): it takes its own quit path and exits with code 0, so a
script can end it.

## What is different from Windows

* **Programs** are built for Linux: `<Name>` with no `.exe`, linked against your system's glibc. A C import set's
  `bin` libraries are not copied next to the program; shared libraries come from the system paths.
* **C import** reads the system's glibc headers (`/usr/include`), so a `.cdecl` made on Linux holds the Linux
  sizes (`long` is 64 bits). A set can have a Linux variant, `<name>.linux.cimport` next to `<name>.cimport`, read
  in its place on Linux ([C-Import.md](C-Import.md), "Platform variants"). The SDL sample's
  `sdl2.linux.cimport` takes SDL from `${TREADLE_SDL2:-/usr}/include/SDL2` and links `SDL2`.
* **Debugger:** the same breakpoints, stops, steps and pin values as on Windows ([Debugging.md](Debugging.md)),
  over the package's `lldb-dap`. Attaching to a running program needs `ptrace_scope` 0 or 1 (1 is the Ubuntu
  default).
* **Program processes:** a program started by Run, and the debugger, end when you press Stop or Cancel, when the
  editor exits and when the editor is killed.
* **Delete** moves files to the desktop Trash; **Show in Explorer** opens the folder with `xdg-open`.

## What does not work yet

* **Library projects** (`kind library`, a `lib<name>.so`): the build makes them as on Windows (where they are a
  DLL and are tested), but no Linux run has checked one yet.
* **No AppImage and no updater:** the tarball is installed and updated by hand.
* **Older distributions** (glibc before 2.43) need a package made there, which does not exist yet.
* **After a crash** the recovery lock stays in `~/.local/share/Treadle`, and a second editor is not kept off a
  folder another editor has open.
* **Not tried:** a distribution other than Ubuntu 26.04, a native (non-WSL) desktop session, display scaling.
