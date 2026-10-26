---
audience: user
title: Performance
order: 12
summary: How fast a Treadle program runs compared with the same program in C: ten benchmark kernels, the machine and compiler, how to run them yourself, what each one measures, why some are slower, and what the Debug checks cost.
---

# Performance

A Treadle program is compiled to native code: the graphs become LLVM IR, which clang compiles with `-O2` and
link-time optimisation (ThinLTO) in Release, with no garbage collector and no interpreter in between. How close
does that get to C? Ten small programs (kernels), each written twice, as a Treadle project and as a C file with
the same algorithm, the same sizes and the same checksum, answer that question.

## Results

Times are the work inside each program, measured by the program itself (Stopwatch in Treadle,
QueryPerformanceCounter in C), not the start of the process. Each program ran 5 times, the Treadle and the C
program taking turns; the table gives the median and, in brackets, the fastest and the slowest run.
**Treadle / C** above 1 means Treadle is slower. **Debug** is one run of the same Treadle project built in Debug,
and **Debug / Release** what the Debug build costs.

| Kernel | Treadle ms | C ms | Treadle / C | Checksums | Debug ms | Debug / Release |
|---|---|---|---|---|---|---|
| intloop | 593 (588-600) | 591 (583-609) | 1.00 | match | 788 | 1.3x |
| floatmath | 672 (670-709) | 685 (670-699) | 0.98 | match | 1,884 | 2.8x |
| structs | 241 (237-255) | 238 (233-244) | 1.01 | match | 3,196 | 13x |
| virtual | 596 (583-601) | 616 (589-625) | 0.97 | match | 3,091 | 5.2x |
| generics | 229 (227-230) | 230 (225-231) | 1.00 | match | 1,590 | 6.9x |
| alloc | 677 (660-684) | 617 (612-668) | 1.10 | match | 1,156 | 1.7x |
| list | 267 (264-275) | 327 (323-328) | 0.82 | match | 1,020 | 3.8x |
| dict | 573 (565-585) | 632 (625-640) | 0.91 | match | 2,008 | 3.6x |
| strings | 203 (199-205) | 249 (246-253) | 0.81 | match | 486 | 2.4x |
| vmdispatch | 170 (169-175) | 97 (92-103) | 1.76 | match | 638 | 3.8x |
| nbody4 | 698 (678-798) | 687 (678-744) | 1.02 | match | 1,650 | 2.4x |
| floatmath4 | 238 (212-242) | 224 (204-234) | 1.06 | match | 542 | 2.3x |
| nbody-mathlib | 733 (727-741) | 734 (726-743) | 1.00 | match | 10,257 | 14x |

nbody-mathlib was measured later the same day, after the merge of the core math library, in a run of all thirteen
kernels; on that run both languages took longer in absolute time (the machine was busier), and every other kernel's
Treadle / C ratio stayed within the run-to-run spread of the rows above.

Measured on 2026-10-25 after the vector primitives (Language.md 2.8; the Debug column is the measurement before
them, the Debug builds did not change, except nbody4 and floatmath4, measured after the merge; nbody4 now deletes its
two arrays, whose leak report stopped its Debug run), at the default `simd x86-64-v2`: the C files are compiled with
`-march=x86-64-v2 -ffp-contract=off` since then (bench.ps1 `-Simd`), the same level and the same roundings as
Treadle (Treadle never contracts `a * b + c`); with them the C floatmath runs in 685 ms where the table before had
1,100. floatmath4 is floatmath by hand in `double4` vectors: 2.8x the scalar kernel's speed, within 6% of C's
vector version; nbody4 (`float4` gravity) is C's SSE-intrinsics speed. On an AMD Ryzen 7
7700 (8 cores, 16 threads; every kernel is single-threaded), 32 GB, Windows 11 Home 10.0.26200, with the Treadle
toolchain's clang 23.1.3 (llvm-mingw 20261006) for both languages. Other programs were running on the machine at the time, so
treat differences under about 10% as noise; the brackets show how much the runs moved.

In short: plain loops over numbers (intloop, floatmath), struct values, virtual calls, generic classes,
sorting a List, a hash table and String building run at C speed or faster, Construct within 10%; the
interpreter loop of vmdispatch is the same machine code as C's but lands 1.8x in this build, an effect of
where the linker places the loop that hits C just as hard ([below](#why-some-kernels-are-slower)); none of them
is a wrong result.

### Before and after the compiler's code generation work

The first measurement of these kernels (the same day, an earlier compiler) found four kernels 1.9x to 4x
slower than C. The compiler now tells LLVM that two Constructs are different memory and which memory accesses
can never overlap, optimises across types at the link, returns large structs the way C does, and calls the
destructor of a class nothing derives from without going through the type's table. The two compilers'
programs and the C program ran in turn, 5 times each (medians, ms):

| Kernel | Before | After | C | Before / C | After / C |
|---|---|---|---|---|---|
| intloop | 566 | 568 | 596 | 0.95 | 0.95 |
| floatmath | 687 | 686 | 1,128 | 0.61 | 0.61 |
| structs | 1,079 | 252 | 249 | 4.33 | 1.01 |
| virtual | 615 | 629 | 640 | 0.96 | 0.98 |
| generics | 903 | 274 | 229 | 3.95 | 1.20 |
| alloc | 715 | 674 | 613 | 1.17 | 1.10 |
| list | 607 | 538 | 328 | 1.85 | 1.64 |
| dict | 658 | 660 | 692 | 0.95 | 0.95 |
| strings | 616 | 555 | 249 | 2.47 | 2.23 |

## Run it yourself

You need a Release build of the editor and the Treadle toolchain (llvm-mingw) where the editor finds it
(next to the editor, or named by `TREADLE_LLVM`). From the repository folder:

```
powershell -File scripts\bench.ps1
powershell -File scripts\bench.ps1 -Kernels structs,generics -Runs 9
powershell -File scripts\bench.ps1 -SkipDebug -Editor <path to Treadle.exe> -OutDir <folder>
```

For each kernel the script:

1. builds `TreadleCore\samples\bench\<kernel>` in Release with `Treadle.exe --build-run`, from an empty
   build folder (the build also runs the program once, a warm-up);
2. compiles `TreadleCore\samples\bench\c\<kernel>.c` with the same clang and the flags Treadle's Release build
   uses: `--target=x86_64-w64-windows-gnu -O2 -ffunction-sections -fdata-sections -flto=thin`, a static link
   with `--gc-sections` and `-s`; no `-march`, as in Treadle;
3. runs the two programs 5 times each, taking turns, so that a change in the machine's load reaches both;
4. builds the Treadle project in Debug and runs it once.

Builds run at below-normal priority so that they disturb the rest of the machine less; the measured runs at
normal priority. The script prints the table and writes it as Markdown to `results.md` in the output folder
(`build\bench` by default), with every run's output in `runs.log`. Every kernel prints two lines,
`checksum <number>` and `us <microseconds>`, so a kernel can also be run by hand: `--build-run
TreadleCore\samples\bench\intloop --config Release`.

## What each kernel measures

| Kernel | What it does | What it exercises |
|---|---|---|
| intloop | Two nested For loops, 20,000 x 10,000, folding `(acc * 31 + i * j + j) % 1000000007` | Integer arithmetic, locals and loop counters (the multiply and the 64-bit modulo dominate) |
| floatmath | The Mandelbrot set on a 2,000 x 2,000 grid in double, at most 512 iterations a point; checksum: the iterations | Double arithmetic in a While loop with an And condition |
| structs | An array of 1,000,000 `Vec3` structs (three doubles), each replaced 600 times by `Arrays.Set(array, i, array[i].Stepped())`, then summed | Struct values: a Pure function on a struct receiver, a struct result, array element writes |
| virtual | 1,000,000 `Circle` / `Rect` / `Tri` objects in a `Shape[]`, the virtual `Area` of each summed over 250 passes | Virtual calls through the type's table on objects spread over the heap |
| generics | An `Accumulator<int>` and an `Accumulator<double>` (a generic class with an `operator+` constraint) each take 400,000,000 values | Generic instances and calls on heap objects in a tight loop |
| alloc | 30,000,000 times: Construct a 32-byte object, write and read a field, Delete it (C: `malloc` / `free`, with the pointer stored so that clang cannot remove the pair) | Construct and Delete |
| list | `List<int>.Add` of 30,000,000 values, their sum with For Each, then 3,000,000 pseudo-random ints sorted by `List.Sort` with a Lambda comparer (C: a growable array and `qsort`) | List growth, For Each, Sort with a delegate |
| dict | 6 rounds of a new `Dictionary<int,int>`: `SetItem` of 2,000,000 pseudo-random keys, then `TryGet` of each | The core's hash table. The C file is a hash table written the same way (open addressing with linear probing, the same hash, growing at three quarters full), so this compares the generated code for the same algorithm, not Treadle's table against a C library's |
| strings | 3,000,000 small Strings built with `AppendF("item {0}:{1};", ...)`, each hashed with `GetHashCode` and appended to one large String (C: `snprintf` into a stack buffer, an FNV-1a hash, a growable buffer) | String building, formatting, hashing |
| vmdispatch | A stack machine with ten opcodes runs a 15-instruction program (a loop of 14 instructions, 7,142,857 times: 99,999,999 instructions); each step reads an `Instr` struct from an array and Switches on its enum opcode (C: a `switch` in a `for (;;)`) | An interpreter's dispatch loop: Switch on an enum (an LLVM `switch`, a jump table), struct array reads, `int[]` stack and registers |
| nbody4 | 2,000 bodies, 100 steps of O(n^2) gravity on `float4` vectors (x, y, z and the mass in w, velocities in a second `float4[]`; a square root and a divide per pair, no reciprocal estimate); checksum: the final positions (C: SSE intrinsics, `__m128`, the same operations in the same order) | Vector primitives (Language.md 2.8): element-wise operators with a splatting scalar, Math Expressions over vectors and swizzles, `float4[]` element reads and writes |
| floatmath4 | The floatmath Mandelbrot four points at a time in `double4` vectors: a lane mask says which points still iterate, `Vector.Any` leaves the loop, a Select per lane counts the iterations (C: clang's vector extensions on four doubles) | A hand-vectorised loop: masks, Select per lane, `Vector.Any` / `Vector.Sum`; at `x86-64-v2` a `double4` is two SSE2 halves |
| nbody-mathlib | 4,096 bodies, 20 steps of O(n^2) gravity on the core math library: positions and velocities in `Core.Vec3[]`, the forces through Vec3's operators (-, +, * by a float) and LengthSquared, the masses in a `float[]`; checksum: the final coordinates (C: plain floats, the same operations in the same order) | The core math library (Core-Library.md): struct operators chosen by both operand types, Pure Sheets on a struct receiver inlined to scalar code |

Both versions draw their pseudo-random numbers from the same 64-bit generator, so the checksums must be equal;
the script reports any difference. The sizes were chosen so that each Treadle kernel ran for 0.5 to 1.2 s with
the first compiler.

## Why some kernels are slower

**generics (was 1.2x, now C speed).** Both programs kept the two accumulators in registers; the Treadle loop
was not unrolled because its functions named no target CPU, so the link-time optimiser had no CPU model to
unroll for. The compiler now gives every function the CPU attributes clang gives C
([Compiler.md 6.4](Compiler.md#64-what-release-code-tells-llvm), "Target CPU"), and the two loops are the same
instructions. The same change makes intloop's loop the same as C's (unrolled two passes at a time, as clang
does for C): 0.97x before, 1.01x now, which is C speed.

**vmdispatch (1.8x in this build; the same machine code as C).** Both programs compile the interpreter to the
same loop: the opcode read, one range check, one jump through a table of the ten cases, each case jumping back.
Instruction for instruction the two loops are equal; only their addresses differ. How fast such a loop runs on
this processor depends on where its branches fall (how the branch predictor sees the shared indirect jump and the
ten jumps back), and it is bimodal: about 70 to 100 ms in one placement, about 170 ms in the other, for either
language. Moving the loop shows it: with the linker told to align every jump target to 32 bytes
(`-mllvm -align-all-nofallthru-blocks=5`) the same Treadle objects run in 70 ms and the C program in 170 ms; an
unrelated change elsewhere in the Treadle program (whether `rt_alloc` may be inlined into `Main`) moves it
between 97 and 169 ms. The ratio in the table is therefore the placement of this build, not a cost of Treadle;
an alignment flag was not taken, because it slowed m6-vm by 10%.

**The alignment policy, evaluated again (2026-10-25, after the per-thread allocator).** Four link-time policies against
none, each a fresh Release build of every kernel and of m6-vm, 5 runs each taking turns, two rounds (medians; the
machine was busy, so absolute times are above the table's, and single runs moved by up to 2x on `strings`):

| Policy (lld `-mllvm`) | vmdispatch | m6-vm loop | virtual | the other kernels |
|---|---|---|---|---|
| none (the current one) | 182 / 171 ms | 277 / 247 ms (min 232 / 229) | 709 / 673 ms | |
| jump targets at 32 bytes (`-align-all-nofallthru-blocks=5`) | 97 / 84 ms | 235 / 237 ms (min 228 / 223) | 804 / 785 ms (+13% / +17%) | within the spread |
| jump targets at 16 bytes (`=4`, round one only) | 109 ms | 235 ms | 900 ms (+27%) | alloc +6% |
| functions at 32 bytes (`-align-all-functions=5`) | 64 / 64 ms | 256 / 268 ms (min 249 / 244) | 695 / 667 ms | strings 212 / 320 ms (one bad round) |
| loops at 32 bytes (`-align-loops=32`, round one only) | 71 ms | 325 ms | 732 ms | within the spread |

**Decision: no alignment flag (unchanged).** The policy best on m6-vm, the real program, is 32-byte jump targets
(4-15% faster by medians, 2-3% by the fastest runs), but it slows `virtual` by 13-17% in both rounds, so it does not
pass "no regression on the other kernels"; 32-byte functions fix vmdispatch for good (64 ms in every run, faster than
C's 97) but are not better on m6-vm (slower in round two, slower by the fastest runs) and swung `strings` in one round.
The caveat stays as written above: vmdispatch's 1.8x is where the linker places one dispatch loop, a C program built
the same way lands in the same two modes, and m6-vm, the interpreter a user would write, is not helped by any one
alignment without a cost elsewhere.

**m6-vm (the sample interpreter, not a kernel).** `--bench` runs `fib(27)` and a loop of 130 million
instructions: 16 and 246 ms before this work, 15 and 227 ms after (medians of 9). A Value (a payload enum) is
now copied field by field (Compiler.md 6.4, "Payload enums in memory"), which removed a store-forwarding stall
on every stack copy; what remains is its interpreter design: a 32-byte instruction read per step, the `OnTrace`
test, the opcode Switch's shared jump and `Arith` calling `IntOp` (not inlined) for every arithmetic step.

**alloc (1.1x).** A Construct zeroes the new object (C's `malloc` does not), because the compiler cannot yet
prove that a constructor sets every field. The Delete calls no destructor at all here: nothing derives from the
class and nothing in it needs destroying.

**floatmath (0.6x), list, strings (0.8x) and dict (0.9x)** are faster than C. list sorts with the core's introsort
(`Sort` with a Lambda comparer; C calls `qsort`), strings writes into a String's inline buffer and formats integers
with the runtime's digit loop (C goes through `snprintf`). For floatmath that is clang's choice for the C code: it
packs two of the loop's doubles into one vector register, which lengthens the loop's critical path; with that
optimisation turned off (`-fno-slp-vectorize`) C takes 750 ms, still within 10% of Treadle. dict is the same
algorithm in both and within the noise.

These causes are recorded for the compiler's and the core library's next steps; this page will be updated when
they change.

## What the Debug checks cost

A Debug build compiles without optimisation and adds run-time checks:
null references, array indexes, use of deleted objects, double Deletes and leaks, each reported with the node
that caused it. The last column above is that price: 1.3x to 2.4x for code dominated by arithmetic or by the C
runtime (intloop, alloc, strings), 2.8x to 6.9x for most others, and up to 13x where Release now inlines across
types and keeps values in registers (structs), which a Debug build does not do. Build in Debug while
writing and testing, and in Release for speed.

## Editor

How quickly the editor answers on a large project: 200 types, 2,001 Sheets, 60,001 nodes and 79,566 wires, with
generics, extensions, Lambdas and events, one big Sheet of 600 nodes and 1,000 wires and one type file of 2 MB. The
project is generated (the same every time), validates and builds without a message, and runs.

Release editor, a 1920 x 1080 window, Dark theme; medians of three runs. A frame time is the editor's own work for
the frame (every panel laid out and drawn), not the graphics card's or the wait for the display, so a frame of
1 ms still shows at the display's rate. **Before** is the editor as it was before this measurement, **After** with
the two fixes below; a dash means the step did not change.

| Step | Target | Before | After |
|---|---|---|---|
| Open the project (folder scan, Project Browser, first frames) | <= 2 s | 265 ms | 228 ms |
| Open the big Sheet (first view, includes the first full Validate) | | 406 ms | 336 ms |
| Frame on the big Sheet at 1:1 | <= 16 ms | 0.9 ms | 1.0 ms |
| Frame on the big Sheet zoomed out (all 600 nodes visible) | <= 33 ms | 1.5 ms | 1.5 ms |
| Frame with the minimap | | 0.9 ms | 1.0 ms |
| Worst frame of 60 on the big Sheet | | 18-22 ms (every 30 frames) | 1.5-3.7 ms |
| Marquee of 295 nodes, per frame | | 1.7 ms | 1.7 ms |
| Drag of 295 nodes, per frame | | 1.3 ms | 1.0 ms |
| Undo of the drag (the call and the next frame) | | 61 ms | 56 ms |
| Frame after a one-Sheet edit, every node selected | | 14.5 ms | 2.3 ms |
| Validate after a one-Sheet edit (graph checks + front end) | <= 5 ms | 0.8 + 5.3 ms | 0.5 + 4.1 ms |
| Validate after a one-Sheet edit, all 200 types open | | 13.5 ms | 12.1 ms |
| Validate, whole project from scratch | | 311 ms | 259 ms |
| Node menu open | | 21 ms | 1.4 ms |
| Node menu: a three-letter search over the whole catalogue | <= 30 ms | 1.0 ms | 0.9 ms |
| Build, whole project (Force Build, Debug; front end lower) | | 5.6 s (1.1 s) | 5.0 s (1.0 s) |
| Open the 2 MB type file | | 80 ms | 66 ms |
| Outline of the 2 MB type (206 functions), per frame | | 1.0 ms | 0.8 ms |
| Find in Sheets, all 200 types open | | 36 ms | 25 ms |
| Open every type file | | 706 ms | 559 ms |
| Save All, 200 files | | 287 ms | 240 ms |
| Memory (private bytes) after opening the project and the big Sheet | | 315 MB | 318 MB |
| Memory growth over the edit loop, after its warm-up | <= 50 MB | 0.3 MB | -4.3 MB |

All five targets pass. The two fixes: the editor re-read the project's types twice a second and on every Node menu
open, about 20 ms each time with 200 types (the hitch every 30 frames, most of the menu's open time); it now does
so only when a file or an open document changed. And an edit inside a Sheet made the Node menu's catalogue and
the type answers be rebuilt on the next frame (about 10 ms); they now rebuild only when a declaration changed.
Differences under about 10% between the columns are noise (other programs were running).

The edit loop is 6,000 steps (add a node, wire it, move it, undo, redo, change a value, delete it, then Validate,
Find or the Node menu), one a frame, with every type file open: about the editing of 30 minutes or more. Memory
grows while the undo history fills (it keeps 200 steps per document, each a copy of the document's open Sheets:
about 1.4 MB per step on the big Sheet) and then stays flat: no leak. With every type open and the history full
the editor held about 770 MB.

Known costs that remain: an undo on the big Sheet makes the next frame take about 50 ms (the type is checked again
in full); Validate after an edit grows with the number of open type files (4 ms with one, 12 ms with 200); the
first view of a Sheet waits for the first whole-project Validate (about 320 ms at this size).

Measured on 2026-10-25 on the machine above. To measure yourself: `TREADLE_SELFTEST=scalegen,quit` with
`TREADLE_SCALE_OUT=<folder>` writes the project, `Treadle.exe --format <folder>` puts it in canonical form,
and `TREADLE_SELFTEST=scalemeasure,quit` with `TREADLE_SCALE_DIR=<folder>` and `TREADLE_WINDOW=1920x1080` writes
the `[SCALE]` lines and this table to the session log.
