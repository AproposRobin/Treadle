# Treadle 0.1.0-alpha

The first public alpha of Treadle, a visual programming language and IDE. The node graphs are the program:
Treadle compiles them through LLVM to native code, with no garbage collector and no interpreter, and runs them
at about the speed of C. This release is for testing. Please try it, build something small, and tell us what
breaks.

## What is in the alpha

### Language

* Classes (one base class, virtual functions, destructors), structs, interfaces, delegates, tuples, and enums,
  including enums whose cases carry values (Make Case, Switch, Is Case).
* Generics with constraints (interfaces, `class` / `struct`, a base class, `new`, `delete`, operators), each
  type argument compiled to its own copy.
* Extensions that add functions, properties and operators to any type, core and C types included.
* Delegates, events (Add, Remove, Invoke, Clear, Count) and Lambdas with their own Sheet and captures.
* Memory without a garbage collector: **Construct** and **Delete**, **Local** objects freed by their region,
  **Defer** and **Defer Delete**, Owned fields deleted by their object's destructor.
* Debug builds check leaks, double Deletes, use after Delete, null member access and indexes, and name the
  node in every message. Release builds drop the checks for speed.
* Errors as values: `Result<T, E>` and `Option<T>`, with **Try**, **Result: match**, **Unwrap** and
  **UnwrapOr**. **Fatal** stops the program with a message.
* Pure functions as value nodes, checked to have no side effects; build constants for per-config code.
* Project kinds: console, windowed and library (a DLL or `.so` with C-callable exports).

### Editor

* A Sheet per function, constructor, destructor and Lambda, with the Outline on the left and Properties on the
  right, the Project Browser, Output Log and Problems below.
* A searchable Node menu that opens from a dragged wire and offers only nodes that fit the pin.
* Validate, with diagnostics on the node and pin in Problems; Build, Run and Debug from the toolbar and the
  keyboard.
* Arrange and Align, node groups, comments, split struct pins, Extract to Function, Find in a Sheet or in the
  whole project, a minimap, breadcrumbs, full undo and redo.
* Crash recovery, and **Help > Report a Problem**, which bundles logs for an issue and uploads nothing.
* The user docs inside the editor's Help.

### Compiler and back end

* Graphs compile to LLVM IR, then clang and lld link a native executable. Release builds use `-O2` with
  ThinLTO.
* Incremental builds: an unchanged project rebuilds in milliseconds in the back end.
* Debug info in DWARF, and on Windows optionally a PDB (CodeView) for other debuggers.
* A command line for scripted builds: `--build-run <project> [--config <name>]`, `--format` and
  `--format --migrate`.

### Core library

* Written in Treadle itself and part of every program: String and StringView (UTF-8), List, Dictionary,
  HashSet, Queue, Stack, Span, File, Directory, Path, Math, Random, Console, Time, Stopwatch, Environment,
  Process, Option and Result.
* Parsing that returns a Result, number formats and AppendF placeholders, sorting.
* Threads: Thread, Mutex, Condition, WaitEvent, ThreadLocal, ThreadPool and Parallel For, with Lambdas as the
  thread bodies.
* SIMD vectors as plain types (`float4`, `int32x4`, `double2` ...): element-wise operators, swizzles, lane
  masks and the Core.Vector functions, compiled for `x86-64-v2` (SSE4.2) by default or a level the project names.
* A math library on top of them: Vec2, Vec3, Vec4 and their double forms, Mat3 and Mat4 (column-major), Quat,
  Color and Color32, Rect and RectI, AABB, Plane, Ray and Transform, with operators and text forms; the n-body
  benchmark on Vec3 runs at the speed of the same program in C.

### C import

* Name headers in a `.cimport` set; the shipped libclang reads them, and their functions, structs, unions,
  enums, constants and variables become nodes. **File > Import C Headers** makes the set for you.
* Variadic functions, function pointers, platform variants per set, libraries to link and C files to compile.

### Debugger

* A graph debugger over lldb-dap (shipped): breakpoints on nodes, Step Over, Step Into and Step Out by node,
  values on the pins, Locals with expandable objects and containers, Call Stack, and an Evaluate box.
* Fatal runtime errors stop on the failing node. **Attach to Process** debugs a running Debug build, and
  library projects can be debugged in the program that loaded them.

### Platforms

* **Windows 10 and 11** (64-bit): the editor and everything it needs in one zip. The programs it builds need
  only the DLLs that come with Windows.
* **Linux** (x86-64, glibc 2.43 or newer): the same editor, core library and samples in one tarball, with its
  own LLVM, linker and debugger.

### Docs

* Nine user pages, also in the editor's Help: Getting Started (your first hour), the Language Guide, Core
  Library, C Header Import, Debugging, Keyboard and Mouse, Linux, Performance and Known Issues.

## Downloads

| Package | For |
|---|---|
| `Treadle-0.1.0-alpha-win64.zip` | Windows 10 or 11, 64-bit |
| `Treadle-0.1.0-alpha-linux-x64.tar.gz` | Linux x86-64 with glibc 2.43 or newer |

```
Treadle-0.1.0-alpha-win64.zip
SHA256: 3a6d37cc9d9cd5de66304bf209d8f1c07e9b149990061c65b64faf5b242fb616

Treadle-0.1.0-alpha-linux-x64.tar.gz
SHA256: fbe2f8f083f65e1f4c1cc93905d7b64d36224f7fc0a5146a908b51a828d5532d
```

## Requirements

* **Windows**: Windows 10 or 11, 64-bit. Unzip into a folder you can write to and run `Treadle.exe`. Nothing
  else to install.
* **Linux**: x86-64 with glibc 2.43 or newer (made on Ubuntu 26.04; Ubuntu 24.04 cannot run it yet), the
  package `libc6-dev` (`sudo apt install libc6-dev`), and a desktop session (X11, or Wayland with XWayland)
  for the editor. Unpack the tarball and run `./treadle`.
* No network connection. Treadle sends nothing anywhere: no telemetry, no crash uploads, no update checks.

## Known limits

* Fixed arrays (`int[4]`) cannot be indexed yet, and generic parameters cannot be numbers.
* Nullable values (`int?`) cannot be compared with `==`; there are no character literals.
* An Owned local variable and a struct with a destructor in a local variable are not freed on return; use a
  Local node or a Defer Delete.
* A generic function of your own needs a generic type around it.
* The core library has gaps: no For Each over Queue and Stack, whole-file reads and writes only, ASCII-only
  case mapping, and no stdin or stderr for a child process.
* Editor: no Expand Function, node groups do not nest, and reordering a function's inputs updates only open files.
* Linux: library projects build but have not been run, and native (non-WSL) desktops are not tried yet.
* There is no macOS build and no in-app updater.

The full list, with what to do instead today, is [Known-Issues.md](Known-Issues.md).

## Reporting a problem

Use **Help > Report a Problem** in the editor. It builds a bundle on your computer that you review, and opens a
pre-filled issue at <https://github.com/AproposRobin/Treadle/issues>. Attach the saved zip to the issue
yourself. If the editor does not start, open an issue with the version line (`--version`), what you did, and
the newest crash log ([Known-Issues.md](Known-Issues.md) says where it is).

## About this alpha

This is an alpha for testing. Nothing is frozen before the beta: the language, the editor and the file format
may still change, and there is no compatibility promise until then, with one exception. Projects made with
this alpha will be brought forward by `Treadle --format --migrate <project folder>`, which writes a backup
beside each file before it is first saved. Keep your projects in version control.

## Thanks

Treadle's editor shell, native host and graph-editing model come from VisualBeef, a node editor by the
same author (Apache-2.0, see NOTICE). Thank you to the projects Treadle is built on and ships with: LLVM (clang, lld,
lldb and libclang), llvm-mingw and mingw-w64, the Beef language, Dear ImGui and cimgui, imnodes, SDL2, stb,
Lucide, Python, and on Linux Z3, libxml2, libedit, libffi, Expat, libipt and ncurses. THIRD_PARTY.md lists
each one with its version and licence.
