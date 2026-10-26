# Samples

Projects to open, read and run. Each folder has a README that says what the sample shows and how to run it.

| Sample | What it shows | SDL2 |
|---|---|---|
| [m1](m1/README.md) | The Getting-Started program (`docs/Getting-Started.md`): classes, a struct, a generic type, memory, a loop, a C call | |
| [m2-frontend](m2-frontend/README.md) | A tour of the language: one small graph per feature, each printing a line | |
| [m2-lambda-ui](m2-lambda-ui/README.md) | Lambdas: a function pointer handed to C's `qsort`, a delegate that captures a local | |
| [m2-sdl](m2-sdl/README.md) | An SDL2 window through the C header import | yes |
| [m3-core](m3-core/README.md) | The core library: counting words with a List, a Dictionary and a sort | |
| [m3-files](m3-files/README.md) | Files and folders: writing, reading back and listing | |
| [m3-text](m3-text/README.md) | Text: parsing numbers, aligned tables, UTF-8, a child process, the date | |
| [m4-breakout](m4-breakout/README.md) | A Breakout game in an SDL2 window, with a headless mode | yes |
| [m5-json](m5-json/README.md) | A JSON reader and writer with errors, a pretty printer and path lookups | |
| [m6-vm](m6-vm/README.md) | A bytecode virtual machine and the small scripting language it runs | |
| [m7-particles](m7-particles/README.md) | 200,000 particles stepped with SIMD vectors on every core, drawn through a turning camera, with a headless mode | yes |

## Open or run one

* **In the editor:** File > Open Project Folder... (or the start page), choose the sample's folder, then Run Without
  Debugging (Ctrl+F5) or Start Debugging (F5).
* **From a terminal**, in the Treadle folder:
  ```
  Treadle.exe --build-run samples\m3-core -- a b c        (Windows)
  ./treadle --build-run samples/m3-core -- a b c          (Linux)
  ```
  It builds the project, runs it in the project folder and prints its output; what follows `--` goes to the
  program.

A build writes a `build` folder inside the sample. To keep the originals as they are, copy a sample folder
somewhere else first and open the copy.

## SDL2

`m2-sdl`, `m4-breakout` and `m7-particles` draw in a window with SDL2 2.32.10.

* **Windows:** the Treadle folder carries SDL2's headers, import library and `SDL2.dll` in `tools\SDL2`, and the
  samples find it there (`../../tools/SDL2` from the sample's `sdl2.cimport`). Build copies `SDL2.dll` next to
  the program. To use another copy, set `TREADLE_SDL2` to an SDL 2.32.10 mingw development package (the folder
  that holds `x86_64-w64-mingw32`). A copy of a sample outside the Treadle folder needs `TREADLE_SDL2`, or the
  paths in its `sdl2.cimport` changed to where `tools\SDL2` is.
* **Linux:** the program is linked against the Treadle folder's `libSDL2-2.0.so.0` (`sdl2.linux.cimport`) and runs
  with the system's SDL2 (`sudo apt install libsdl2-2.0-0`, present on most desktops). Without it, start the
  editor with `LD_LIBRARY_PATH` set to the Treadle folder.
