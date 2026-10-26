# Particles

200,000 particles made entirely of Treadle graphs: gravity, drag and a moving point that pushes them away,
computed with SIMD vectors, bouncing inside a box, stepped on every core with `Parallel.For`, and drawn as points
in an SDL2 window seen through a turning camera.

## Run it

```
Treadle.exe --build-run samples\m7-particles --config Release
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`.) It needs SDL2
([samples README](../README.md), "SDL2"): the Windows package carries it in `tools\SDL2`, and `TREADLE_SDL2` names
another SDL 2.32.10 mingw development package (the folder that holds `x86_64-w64-mingw32`). On Linux,
`./treadle --build-run samples/m7-particles --config Release` links the Treadle folder's `libSDL2-2.0.so.0`, and the
program runs with your system's SDL2. Or open the folder in the editor and press Ctrl+F5. The project is `kind windowed`: there is no console window,
and what the program prints shows in the Output Log. What follows `--` goes to the program:

| Argument | Effect |
|---|---|
| (none) | A 960x600 window until you close it or press Escape |
| `--frames <n>` | Stop after `n` frames (in the window), or step `n` times (with `--headless`, 300 when not given) |
| `--shot <file.bmp>` | Save frame 150 of the window as a BMP picture |
| `--headless` | No window: step the particles, print a summary, and the time per step on stderr |
| `--selftest` | Run eight checks and print `selftest ok` |

A headless run prints the same summary every time and in both configurations, because the particles come from a
random generator with a fixed seed and the parallel steps write only their own particles:

```
particles 200000 (100000 in float4 lanes, 100000 as Vec3), frames 300, seed 7
checksum 1372415374318782687
speed min 0.214 max 47.953 avg 13.648 over 200000 particles from 64 chunks
bursts 2 (1 handler), particles re-seeded 65518
inside the world 200000 of 200000, NaN false, on screen 200000
parallel == serial: true
```

The last line compares the run with a second one from the same seed that steps on one thread. The time per step of
both goes to stderr, for example on an 8-core, 16-thread machine in Release:

```
ms per frame: serial 1.494, parallel 0.217, speedup 6.88x on 16 hardware threads
```

## What it does

Each step every particle feels gravity, loses some speed to drag, and is pushed away from a point that circles the
middle of the box. A particle that leaves the box is mirrored back in and its speed is reversed and reduced. Every
two seconds of simulated time a burst throws the particles lying near the floor upward again, the left half and the
right half in turn. The camera circles the box. Particles of the first emitter are drawn orange, of the second blue.

## What is inside

| Type | What it shows |
|---|---|
| `Program` | The three modes, the summary built with AppendF, two checksums computed at once by `ThreadPool.Run` jobs |
| `Tuning` | Constants, a `float4` constant among them |
| `Kin` | The step of one particle on `float4` values: Math Expressions, Operators giving lane masks, Select per lane, `Core.Math.Min` / `Max` on vectors; the checksum through a Cast to `int32x4` and `Vector.Sum` |
| `EmitterA` | Particles as `float` arrays, four per particle, read and written with `Vector.Load` and `Vector.Store` |
| `EmitterB` | Particles as arrays of the math library's `Vec3`, widened to `float4` for the step |
| `Sim` | The world `AABB`, the chunks, `Parallel.For` with a Local Lambda, the same chunks in a plain loop |
| `Stats` | The minimum, maximum and average speed, merged by the workers under a `Mutex` held by a Local `LockGuard` |
| `Bursts`, `BurstHandler`, `Reseeder` | An event fired every 120 steps and the handler that re-seeds a region of the box |
| `Camera` | A `Quat` orbit camera: `Mat4.Rotation`, `Mat4.Translation`, `Mat4.Perspective` |
| `Projector` | The projection to the screen on four named threads (`project 0` ... `project 3`), with `Atomic.Add` |
| `Window` | The SDL window, `SDL_RenderDrawPoints` in batches through `Span.Slice`, a screenshot with `SDL_SaveBMP_RW` |
| `SelfTest` | The eight checks: vector identities, bounces, parallel against serial, no NaN, a Mutex counter over eight named threads, the burst count, `Mat4 * Vec4` against a reference, quaternion lengths |

When you run the window under the debugger (F5), the threads list shows `project 0` to `project 3` and the pool's
threads (`Pool 1`, ...) that `Parallel.For` uses.
