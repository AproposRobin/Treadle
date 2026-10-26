# SDL window

An SDL2 window through the C header import (`docs/C-Import.md`): 640x480, a renderer filled
with a colour that a Flip Flop changes every 30 frames, events polled into an `SDL_Event` (a C union; Break reads
its type) until the window is closed, or until `--frames <n>` frames have been drawn.

## Run it

```
Treadle.exe --build-run samples\m2-sdl -- --frames 60
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m2-sdl -- --frames 60`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It opens the window for 60 frames and prints `frame 0: red`, `frame 30: blue`, `frames 60`. Without `--frames` it
runs until you close the window.

It needs SDL2 ([samples README](../README.md), "SDL2"): the Windows package carries it in `tools\SDL2`, and
`TREADLE_SDL2` names another SDL 2.32.10 mingw development package (the folder that holds `x86_64-w64-mingw32`). On
Linux the program links the Treadle folder's `libSDL2-2.0.so.0` and runs with your system's SDL2.
