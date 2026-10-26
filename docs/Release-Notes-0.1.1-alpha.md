# Treadle 0.1.1-alpha

The second alpha of Treadle. It makes the first program easier to write and run, gives each type its own place in
the window, shows problems when you ask for them, adds views of what a type and a function become in memory and in
machine code, and brings an updater, so this is the last version you install by hand. It also fixes a set of
compiler bugs found by the first alpha's samples. 0.1.0-alpha has no working updater: unpack 0.1.1-alpha into a new
folder once; later versions arrive through **Help > Check for Updates**.

## Running your program

* **Run** is the first button on the toolbar (Ctrl+F5): it builds when something changed and starts the program.
  **Build** (F7) is next to it and only builds.
* The status bar names the entry point (**Entry: Program.Main**); a click opens it. A static `Main` of any type has
  **Set as entry point** in the Outline. A project without one offers **Create Main** in Problems.
* A new project's `Main` starts with a comment that says how to run it.

## Calling other types' functions

* Drag a wire from an object pin and the Node menu lists that type's functions, also those of other types in the
  project.
* **Construct + Defer Delete + Call** in one step: one row of the Node menu places the object, frees it at the
  end of the region and calls the function you searched for.
* A Call with nothing to run on says so on the node: wire its **Receiver**.

## Making types

* **+ Add** in the Project Browser has one entry per kind: **New Class**, **New Struct**, **New Enum**, **New
  Interface**, **New Delegate**, **New Extension**. The **Create Type** dialog proposes a name and the namespace
  from the folder, takes a base class and interfaces, and writes the type from its kind's template.
* The type pickers (base class, interfaces, a variable's type) list only the types that fit there.
* **Make Child Class** and **Duplicate** on a type's menu in the Outline or the Project Browser.
* **Overrides on functions**: a class's FUNCTIONS header has **Override...** for the virtual and abstract
  functions of its bases. A class that leaves an abstract function without a body is an error (T1053) unless it
  is abstract itself.

## The window

* **A tab per type**: the top row of the graph area has a tab for each open type, in its kind's colour; under it,
  the tabs of that type's Sheets. Each type keeps its own Sheet in front. Ctrl+PageUp / PageDown move between
  Sheets.
* A strip over the canvas names the type, its base, namespace and file, has **Type Settings** and **Validate**,
  and shows the signature of the Sheet in front.
* Math types on unwired pins (Vec2, Vec3, Vec4, Quat, Color, Rect and the others) show one field per component;
  Color pins have a swatch with a colour picker. Vector pins can be split into their lanes.
* The Call Stack lists `Main` first, then the threads by name; the narrow right dock's tabs share its width.

## Problems when you ask for them

* Problems appear after **Validate** (Shift+F7), **Build** or **Run**, not while you type. After an edit they are
  dimmed as from before the change, the status bar says **Not validated**, and Validate has a dot. **Editor
  Preferences** can validate after every edit again.

## Under the hood

* **Layout** in Type Settings: the size, alignment and the offset of each field of a class or struct, with padding.
* **Lives in** says where a variable's value is kept.
* A **Memory** view while debugging, and a **Disassembly** view of a function (right-click it in the Outline).

## Projects and files

* Layout files and backups no longer sit next to your sources: they go to `layout/` and `backup/` in the project
  folder (the project keys `layoutDir` and `backupDir` choose others). An older project is moved over when it
  opens, and the Output Log says what moved. New projects get a `.gitignore` with `backup/`.

## Updates

* Treadle updates itself from its GitHub Releases. Once a day, a few seconds after it starts, it looks for a newer
  version (**Help > Check for Updates** looks at any time); a line under the toolbar offers **Update now**, **What
  changed**, **Later** and **Skip this version**. The download is checked against the release's SHA256SUMS, your
  files are saved, and the new version starts with the same project; if it does not start, the old one is put back.
  **Editor Preferences > Updates** turns the check off, picks the channel (Alpha or Stable) and has **Work
  Offline**, which stops every network request.

## Samples

* The packages carry the samples: `samples\README.md` lists them, and **Open a sample...** on the start page opens
  one. The Windows package includes SDL2 for the SDL samples.
* A new sample, **m7-particles**: 200,000 particles on SIMD vectors and every core, drawn in an SDL2 window, with
  a headless mode.

## Compiler and runtime fixes

* A variable, field, input or output with no type is now error T1078 at Validate, on the variable, instead of a
  build failure.
* `Core.Vector.Equal` and `Core.Vector.Normalize` build again.
* In a Math Expression an int next to a fractional literal now meets it in the wider type (`s / 1000.0` divides
  doubles) instead of failing with T2214.
* A compound Set with an operator of two types (`*=` on a Vec3 with a float) works.
* Generic code over any vector type (`T : vector`); vectors print as `(1, 2, 3, 4)`.
* Debug builds check a Span's index.
* A Local delegate wired into `Thread.Start` or `ThreadPool.Run` is an error at Validate (T2224).
* Debug builds with threads are faster: each thread keeps its own allocation lists.
* Struct literals on pins (the math types' fields) compile as the Make of their fields.
* The tools, libclang, the C runtime and the core are found only beside the editor or in a development build, not
  in parent folders.
* Linux: Attach to Process for libraries, and the Call Stack's thread names.

## Experimental: GPU kernels

* `[Kernel]` functions run on an NVIDIA GPU through the CUDA driver, or on the CPU when there is none (or with
  `TREADLE_GPU=cpu`): streams, pinned buffers, shared memory and barriers, and errors reported from the GPU. This is
  a preview; the language page marks it as such.

## Known issues

See [Known-Issues.md](Known-Issues.md). In the Windows package, building an SDL sample prints a warning about C
import paths outside the project for the package's own `tools\SDL2`; the build and the program are fine.
