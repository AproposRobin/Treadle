---
audience: user
title: C header import
order: 7
summary: Calling C libraries from Treadle: writing a .cimport set, importing it into a .cdecl file, what each C declaration becomes, what is skipped, linking and shipping the library, paths and platform variants.
---

# C header import

A C library is called from Treadle through a **C import set**: a small `.cimport` file that names the headers.
Importing it reads those headers with libclang (shipped with Treadle) and writes the set's declarations,
`<set>.cdecl`. From then on the set is the type `C.<set>` in the Node menu: its functions are Calls, its structs
have Make / Break, its enums and constants are values.

## Running it

| How | What it does |
|---|---|
| File > Import C Headers | Imports the open project's `cimport` files (every `.cimport` in the project folder when the project file lists none) into `<project>\build\cimport`, each file in a child editor (`Treadle --import-c <file> --out <dir>`), so a header that crashes libclang (one nested thousands of levels deep overflows its parser) fails that file with *import failed: <reason>* and the editor runs on; the summary goes to the Output Log, then the project is rescanned so the Node menu and Validate see the new declarations. A project with no set at all asks for a header (the file dialog) and makes its set, no other question asked: `<name>.cimport` in the project folder, set `<name>` (the header's file name without its extension), `header <file>`, and as `include` lines the header's folder and, when that folder sits in an `include` folder (`include/SDL2/SDL.h`), that one too, relative to the project when inside it; the project file gets `cimport <name>.cimport`. Add `lib`, `only` and the rest by hand when the set needs them. |
| `Treadle.exe --import-c <file.cimport> [--out <dir>]` | Imports every set of the file (this platform's variant of it, [Platform variants](#platform-variants)) into `<dir>\<set>.cdecl`, or `<dir>\<set>.windows.cdecl` / `<set>.linux.cdecl` when the set file has a platform variant (default `<project root>\build\cimport`, the project root being the nearest folder at or above the file with a `.tproj`), prints a summary with every warning, exits 0 (all sets imported), 1 (a set failed) or 2 (usage). No window opens. |

The import is not run by Build: run it again after changing the set or the headers. A `.cdecl` whose bytes would
not change is not rewritten. The compiler looks for a set's declarations in this order: `<set>.windows.cdecl`
(on Linux `<set>.linux.cdecl`) next to the set file, `<set>.cdecl` next to it, then the same two under
`build\cimport`. So a `.cdecl` checked in beside the set wins, and a project builds on a machine that has
the library but not its headers.

## Writing a `.cimport`

```
# cimport 1
import sdl2
	prefix SDL_
	header SDL.h
	include ../third_party/SDL2/include/SDL2
	define SDL_MAIN_HANDLED
	lib SDL2
	hide SDL_main*
	category "C / SDL2"
```

| Key | Meaning for the import |
|---|---|
| `header <file>` | Included, in order (`#include "<file>"`): a path relative to the set file, or a name found through `include` and the system folders (`stdio.h`). |
| `include <dir>` | `-I`: relative to the set file or absolute, variables expanded ([Paths and variables](#paths-and-variables)). Headers found here belong to the set. |
| `define NAME` / `define NAME value` | `-DNAME` / `-DNAME=value` for the parse. |
| `only a b printf/2` | Only these symbols (functions, types, constants); `/N` is ignored by the import. |
| `hide _* SDL_main*` | Globs (`*`, `?`) of symbols not offered. |
| `prefix SDL_ IMG_` | Only symbols starting with one of these (when there is no `only`). |
| `param <function> <name>...` | The set's own names for a function's parameters, in order (`param qsort base count size compare`). |
| `pure <function>...` | These functions are Pure: their Calls are value nodes. |
| `category "text"` | The Node menu group of the set (default `C \| <set>`). |
| `lib`, `bin`, `csource` | Not used by the import; Build reads them ([Building with a set](#building-with-a-set)). |

Put `prefix` and `param` right after the `import` line: that is where they are written back, so the file stays
unchanged when it is saved.

**Which declarations belong to the set.** With `only`: those names, wherever they are declared. Otherwise:
declarations in one of the set's `header` files, or in any header that is not a system header (found through
the set's `include` paths); both filtered by `prefix` and `hide`. Types a selected declaration uses are always
imported, filters or not (`FILE` comes with `fopen`).

**The `.cdecl` file** is a type file of the `C` namespace: one `function` record per C function, then the C
records (`cstruct`, `cunion`, `cenum`, `ctypedef`, `cconst`, `cvar`) with their sizes and offsets. It is generated:
read it to see what was imported, do not edit it. The same headers give the same bytes on every run, so it diffs
cleanly when checked in.

## What maps to what

| C | Treadle |
|---|---|
| `int`, `unsigned int` | `int32`, `uint32` |
| `long`, `unsigned long` | `int32`, `uint32` on Windows; `int64`, `uint64` on Linux |
| `long long`, `unsigned long long` | `int64`, `uint64` |
| `short`, `unsigned short` | `int16`, `uint16` |
| `char`, `signed char`, `unsigned char` | `char8`, `int8`, `uint8` |
| `_Bool` / `bool` | `bool` |
| `wchar_t`, `char16_t`, `char32_t` | `uint16` (Linux: `uint32`), `uint16`, `uint32` |
| `float`, `double` | `float`, `double` |
| `size_t`, `rsize_t`, `uintptr_t` | `uint` |
| `ptrdiff_t`, `intptr_t`, `ssize_t` | `int` |
| `T*`, `const T*` | `T*` (const is dropped) |
| `void*` | `void*` |
| `T a[N]` (field) | `T[N]`; `T a[N][M]` is `T[N*M]` (same bytes) |
| `T a[]` (parameter), `T a[N]` (parameter) | `T*` |
| `T a[]` (last field) | `T[0]` |
| `R (*)(A, B)` | `function:R(A,B)` |
| `struct X`, `union X`, `enum X` | `C.X`: a struct with Make / Break (a union too, its fields overlapping), an enum |
| `typedef struct {...} X;` | `X` (the record takes the typedef's name) |
| anonymous struct / union / enum without a typedef | `anon_<header>_<line>` |
| anonymous struct / union member | its fields, flattened into the outer record at their offsets |
| `typedef` of a struct, union, enum or function pointer | the typedef's name |
| other `typedef`s (`Uint32`, `LPSTR`) | what they stand for (`uint32`, `char8*`) |
| object-like macro: literal, string(s), constant expression | a constant of the set (`C.sdl2.SDL_INIT_VIDEO`): integer types follow C's literal rules and the usual arithmetic conversions; casts to integer and float types are applied |
| constants of `enum { A, B };` | constants of the set |
| `extern` variable | a **C variable**: a static field of the set, read with Get and written with Set |
| parameter names | the header's, with leading underscores dropped and the first letter lower case (`_Str` -> `str`); `p<i>` when unnamed; a pin name the node already uses (`in`, `then`, `result`, ...) gets `Value` appended; `param` lines override |

**C variables.** An `extern` variable, or an object-like macro of the form `(*f())`, `f()` or `f(<integer>)` where
`f` is a function: C's way to reach per-thread or DLL data. `errno` (`(*_errno())` on Windows) is read and written;
`stdout` (`(__acrt_iob_func(1))` on Windows) is given by value, so it can be read but not Set (T2219). No unsafe
node is needed.

**Calls.** A C function's `T*` input wired from a variable of type `T` gets the variable's address (`SDL_PollEvent`
filling a local `SDL_Event`). A variadic function (`printf`) gets extra inputs `va0`, `va1`, ... (**+ arg** on the
selected Call), each promoted as C does.

## Limits (warned and skipped, with the header and line)

* **Bitfields**: each run of bitfields becomes opaque bytes `_bits<k> uint8[n]` over the storage units it
  uses; the other fields keep their offsets.
* **Static (inline) functions** (`static inline`, mingw's `__mingw_ovr`): no library exports them; one
  warning per set lists them (one each when named in `only`).
* **Types Treadle has no word for**: `long double`, `__int128`, `_Complex`, vectors, `_Atomic`, blocks, and
  pointers to variadic functions. A function using one is skipped; a field becomes opaque bytes of its size;
  a pointer to one becomes `void*` (a pointer to a variadic function skips its user).
* **Macros**: function-like macros are skipped silently (they are code, not values); empty macros (flags,
  include guards) too; any other object-like macro that is not a literal or a constant expression (`__cdecl`,
  `__attribute__((...))`, `((void*)0)`, a call of a function-like macro, wide strings) is skipped with a
  warning.
* **Calling conventions** other than C / stdcall / fastcall (vectorcall and the like): the function is skipped.
* **Macro variables**: only `(*f())`, `f()` and `f(<integer>)` become C variables; any other expression over a
  function call (`(&__iob_func()[1])`, a cast, a field) is skipped with the macro warning. Windows and Linux spell
  `errno`, `stdout` and many parameter names differently, so a set naming them needs a Linux variant
  ([Platform variants](#platform-variants)).
* **C only**: C++ headers are not supported (the parse is C17 with GNU extensions).

## Building with a set

**The `.cimport` set says what links and what ships**, not the project file: the library belongs to the headers
it was imported from, and every project that lists the set needs the same files.

| Key | What Build does |
|---|---|
| `lib <file>` | A path (relative to the set file, or absolute; a `.a`, `.dll.a` or `.lib`; variables expanded) is passed to the link as it is. |
| `lib <name>` | A bare name is passed as `-l<name>`, except the C runtime and the system libraries linked anyway (`msvcrt`, `ucrt`, `ucrtbase`, `kernel32`, `c`, `m`), which are informative. |
| `bin <file>` | A file the program needs at run time (a DLL), relative to the set file or absolute, variables expanded: Build copies it next to the exe when it is missing there or has another time stamp. |
| `csource <file>` | A C source (relative to the set file or absolute, variables expanded) compiled into the program with the same compiler and flags: what defines the set's C variables or small helpers. Limit: the program is linked again when the list of files changes, not when the source alone changes (change a Sheet, or rebuild). |

The project file lists the set with a `cimport <file>` line (File > Import C Headers adds it). The repository's
SDL sample imports `SDL.h` with `lib .../lib/libSDL2.dll.a` and `bin .../bin/SDL2.dll`; its checked-in
`sdl2.cdecl` holds only the symbols its `only` line names and the types they use:

```
Treadle.exe --build-run TreadleCore\samples\m2-sdl -- --frames 120
```

builds it, copies `SDL2.dll` next to `SdlDemo.exe`, runs it with `--frames 120` (a 640x480 window for 120 frames
of 16 ms, filled red and blue in turn every 30 frames by a Flip Flop) and prints `frame 0: red`, `frame 30: blue`,
`frame 60: red`, `frame 90: blue`, `frames 120`, exit code 0. Without `--frames` it runs until the window is closed.

### Paths and variables

**Rule: a set file names no machine's folders.** The paths of `include`, `lib`, `bin` and `csource` are relative to
the `.cimport` file, or start with an environment variable; an absolute path still works but should not be
checked in.

* `${NAME}` is the environment variable `NAME`.
* `${NAME:-fallback}` is `fallback` when `NAME` is unset or empty; the fallback may be a relative path.
* After expansion a relative path is taken relative to the set file's folder.
* A variable that is unset and has no fallback stays as written, so the import's or the link's error names it.

The SDL sample's set:

```
	include ${TREADLE_SDL2:-../../../tools/SDL2-2.32.10}/x86_64-w64-mingw32/include/SDL2
	lib ${TREADLE_SDL2:-../../../tools/SDL2-2.32.10}/x86_64-w64-mingw32/lib/libSDL2.dll.a
	bin ${TREADLE_SDL2:-../../../tools/SDL2-2.32.10}/x86_64-w64-mingw32/bin/SDL2.dll
```

`TREADLE_SDL2` is the root of an SDL 2.32.10 mingw development package (the folder that holds
`x86_64-w64-mingw32`).

**Build names what is outside.** Every Build gives one warning, *C import paths outside the project folder*, that
lists each `include`, `header`, `lib`, `bin` and `csource` path that, after the variables and `..`, is not inside
the project folder (a header or library given by name alone is not a path). The SDL sample lists its three SDL2
paths. Read the list before you run a project someone else made: those are files of your machine that go into
the program or next to it.


## Platform variants

`<name>.linux.cimport` next to `<name>.cimport` is the set file read on Linux, `<name>.windows.cimport` the one read
on Windows; the base file is read where it has no variant (the folder scan, a project file's `cimport` line and File >
Import C Headers alike). A variant keeps the same `import` names, with the platform's own `include`, `lib` and
`bin`. Where the headers differ between the platforms (the C library's macro variables, glibc's parameter names), a
set file with a variant writes `<set>.windows.cdecl` on Windows and `<set>.linux.cdecl` on Linux, and each platform
reads its own first; where they agree, one shared `<set>.cdecl` serves both. The SDL sample's Linux variant takes SDL
from `${TREADLE_SDL2:-/usr}/include/SDL2` and links `-lSDL2` (no `bin`: the system's loader finds the library).
On Linux the parse uses the system's glibc headers ([Linux.md](Linux.md), "What is different from Windows").

## Where libclang comes from

The package carries it (`tools\libclang` on Windows, `tools/llvm/lib/libclang.so` on Linux), and the import uses
the C headers of the package's own toolchain, so `<stdio.h>` is the header the programs are compiled against.
`TREADLE_LIBCLANG` names another `libclang.dll` (or a folder holding it). The editor starts and runs without
libclang; only the import needs it.
