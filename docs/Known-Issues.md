---
audience: user
title: Known issues and limits
order: 13
summary: What this alpha does not do yet, what to do instead today, what may still change before the beta, how fast programs run, what the editor runs and stores on your computer, and how to report a problem.
---

# Known issues and limits

This is the first alpha. The language, the editor and the file format work end to end: programs from a
console program to an SDL window and a JSON reader and writer are built and run with it. This
page lists what is missing or wrong today and what you can do instead. Items marked **(being fixed)** are
being worked on now; there are no dates.

## Language limits

Each line says what does not work and what to do today.

* **Fixed arrays** (`int[4]`, a value with its elements inline): reading an element (Index) of
  one stops the build. Use an array (`int[]`) made by Construct or Local with a length.
* **Generic parameters that are numbers** (`generic const N int`, `Buf<4>`): not built; `4` is read as a type
  name. Pass the number to a constructor and keep it in a field.
* **Is Valid** is not a node yet. Wire the object and `null` into an `!=` Operator and that into a Branch.
* **Very deep recursion** can run out of stack with no message: the program ends with exit code 3221225725
  (0xC00000FD) on Windows. A Debug program has an 8 MB main stack (a recursive JSON parser reaches about 5,000
  levels), a Release one the 1 MB default (about 2,400). Limit the depth your program accepts, or keep your own
  stack in a List.
* **No character literals**: a Switch over bytes uses numbers (`case 123` for `{`), and a `char8` input takes
  its number (`92` for a backslash).
* **A generic function** of your own needs a generic type around it; only the core library has generic
  functions in non-generic types.
* **Vectors (SIMD)** ([Language.md 2.8](Language.md#28-vectors-simd)): `Sin`, `Cos`, `Exp`, `Log` and `Pow` on
  vectors are correct but slow (LLVM calls the C library once per lane). There is no gather / scatter, no
  `[Align(32)]` (vectors are aligned to 16 at most; an AVX load of a 32-byte vector is unaligned) and no generic code
  over vector widths (`Vector<T, N>` with a constant `N` is reserved). Split Pin does not split a vector pin yet:
  use a Break node. A vector does not print as one value yet: Break it and write its lanes. Programs are compiled
  for `x86-64-v2` (SSE4.2) unless the project's config says `simd x86-64-v3` (AVX2) or another level.
* **Threads** have no race detection: two threads that change the same variable or collection without a Mutex (a
  Local LockGuard) or an Atomic call give wrong results in Debug too, with no message. Lock around shared data.
  A Lambda handed to `Thread.Start` or `ThreadPool.Run` must be made with Allocation construct: a Local one is caught
  in Debug only when the program runs (a fatal error), not by Validate. Deep recursion on a thread other than the main
  one has a 1 MB stack unless the Thread was made with a larger `stackSize`.
* **Core library gaps** (no For Each over Queue and Stack, whole-file reads and writes only, ASCII-only
  ToUpper / ToLower, Dictionary order, an unstable List.Sort, no stdin or stderr for a child process):
  [Core-Library.md](Core-Library.md) lists them.

## Editor limits

* **Expand Function** (the reverse of Extract to Function: put a function's nodes back in place of its Call) is
  not built. **Extract to Function** does not work in a Lambda Sheet.
* **Node groups do not nest**: a node is in one group at most. Ctrl+A selects a folded group's nodes, not the
  group, and the minimap still draws the hidden nodes.
* **Reordering a function's inputs** updates the Calls in open files only. A Call in a file that is not open
  keeps the old order until you open that file and refit the Call. Adding or removing an input does not update
  Calls either: open the Sheets that call the function and check Problems.
* **The project page** cannot add or remove a config, or edit a C import set's headers, includes and
  libraries: **Open** the set and edit it in a text editor, then **Import Again**.
* **Run Without Debugging** (Ctrl+F5) runs the program in its build folder (`build/<config>`), while
  `--build-run` runs it in the project folder: a relative path is read from there. Pass a full path to be sure.
* **Events**: making a field an event needs the line `attr Event` under the field in its type file, written
  in a text editor; the event's Calls look like plain Calls.
* **On Linux only**: after a crash the recovery lock stays in `~/.local/share/Treadle`; a second editor is not
  kept off a folder another editor has open; display scaling and native (non-WSL) desktops are not tried yet;
  library projects build but have not been run. [Linux.md](Linux.md) has the rest.

## Platform notes

* **Windows first.** Windows 10 or 11, 64-bit. The programs Treadle builds need only DLLs that come with
  Windows.
* **Linux**: x86-64 with **glibc 2.43 or newer** (made on Ubuntu 26.04; Ubuntu 24.04 cannot run it yet). It
  needs `sudo apt install libc6-dev` and, for the editor, a desktop session (X11, or Wayland with XWayland).
  Building from the command line needs no desktop. Attaching the debugger needs `ptrace_scope` 0 or 1.
* **No macOS** build.
* **No updates**: this version makes no update requests. Install a new version into a new folder (on Linux,
  unpack the new tarball next to the old one).

## Format stability

The graph files are your program, so this matters:

* **Nothing is frozen in the alpha.** The format is version 1 (the first line of every file, `# treadle 1`).
  Before the beta, record and key names may still change.
* **File names.** Type files are `.treadle` (layout sidecars `.treadle.layout`), project files `.tproj`. Files
  with the names from before the product's rename (`.vtype`, `.vtype.layout`, `.vproject`, first line
  `# vtype 1`) open and build as they are and are saved under their own names; `Treadle --format --migrate
  <project folder>` renames them once, and `Treadle --format --check <project folder>` lists them. A folder
  holding both names of one type (`Player.vtype` and `Player.treadle`) is an error naming both: keep one.
* **From the first beta**, the record kinds, key names, node kind and pin names, ids and the order records are
  written in change only with a new format version and a migration step. Renamed node kinds and pins keep
  loading under their old names.
* **Moving alpha files to the beta**: the beta migrates an older file when it opens it, and its
  `Treadle --format --migrate <project>` does a whole project at once. Before a migrated file is first
  saved, a backup is written beside it (`<file>.v1.bak`).
* **Keep your projects in version control.** The files are line-based text and diff well. A file of a newer
  version than the editor knows is refused, not changed.
* **Today**, `Treadle --format <project> [--check]` rewrites files in canonical form (or, with
  `--check`, only lists the ones that are not).
* The `.layout` files beside your type files only hold positions and folds: deleting one never changes the
  program.

## Performance

* **Release** builds compile with optimisation through LLVM, with no garbage collector. On the nine benchmark
  kernels of [Performance.md](Performance.md), every kernel runs as fast as the same program in C or within
  about 20% of it (generics 1.2x, Construct 1.07x; List sorting and String building are faster than C).
* **Debug** builds are slower by design: no optimisation, and run-time checks that name the node (null
  references, array indexes, deleted objects, double Deletes, leaks). Expect 1.4x to about 11x the Release time,
  the most for struct values that Release keeps in registers. Build in Debug while you write and test, in Release for speed.
* A Release build does not check indexes or deleted objects; a mistake there can crash or run on silently.
  Test in Debug first.

## Safety notes

* **Opening a project runs nothing.** The editor reads and checks the graphs; no program, script or C code
  runs until you press **Build**, **Run** or **Debug** (or use `--build-run`).
* **Build compiles your program and the C files it names.** A C import set can list `csource` C files that
  are compiled into the program, and libraries that are linked into it; Run then starts the program with your
  rights. Open a project from someone else the way you would open their source code: read its `.cimport`
  files before you build it.
* **Import C Headers** reads C headers; it does not run them.
* **Where things are kept** on Windows: settings, the window layout, the session logs and recovery in
  `%LOCALAPPDATA%\Treadle` (settings in `settings.json`); crash reports in
  `%LOCALAPPDATA%\Treadle\logs\treadle-crash-<date>-<time>.log`, with a `.dmp` beside it. On Linux: settings in
  `~/.local/share/Treadle`, crash reports in `~/.local/state/treadle/crashes`. Your projects stay where you put
  them; each build goes into the project's `build` folder.
* **No telemetry.** Treadle sends nothing anywhere: no usage data, no crash uploads, no update checks. A crash
  report stays on your computer until you send it.
* To remove Treadle, delete its folder and `%LOCALAPPDATA%\Treadle` (on Linux, `~/.local/share/Treadle`,
  `~/.local/state/treadle` and `~/.cache/treadle`).

## How to report a problem

Use **Help > Report a Problem** in the editor ([Getting-Started.md](Getting-Started.md), "Report a problem"). It
puts together a bundle on your computer and sends nothing itself:

1. Type what went wrong and the steps that make it happen.
2. Choose what goes in: the last 200 lines of the Output Log and the newest crash report are ticked; your
   project's files are not (tick **Include this project's files** only if the problem needs them; the `build`
   and `.git` folders are always left out). The dialog lists every file of the bundle and the version line
   before anything is written; a bundle can be at most 8 MB.
3. **Report on GitHub** saves the bundle as `report-<id>.zip` and opens a new issue at
   <https://github.com/AproposRobin/Treadle/issues> in your browser, filled in with your text, the version, your
   system and the last lines of the Output Log. The zip is not uploaded for you: **drag the saved zip into the
   issue by hand**, read the text, and submit it there. **Save bundle** only writes the zip (to
   `%LOCALAPPDATA%\Treadle\reports`, the path is shown); **Copy summary** puts a short text on the clipboard.

If the editor does not start, open an issue at the same address with the version line (run the editor with
`--version`), what you did, and the newest `treadle-crash-...log` from `%LOCALAPPDATA%\Treadle\logs` (Linux:
`~/.local/state/treadle/crashes`). File paths in logs and crash reports can show your user name; read them before
you post. There is no support chat yet.
