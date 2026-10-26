# mathgen: the core math library generator

The core math library (`TreadleCore/core`: Vec2 ... Transform, MathFormat and the scalar additions of `Math.treadle`)
is regular, so its graphs are written by this generator instead of by hand. It is source kept for maintenance; it is
not part of the packages and the build does not run it. The committed files are its output after `--format`.

## What it generates

| Script | Writes |
|---|---|
| `gen.js <core dir> overloads vectors` | the 18 type files of the math library (`Vec2.treadle` ... `Transform.treadle`, `MathFormat.treadle`) and `Math.treadle` (`Math.base.treadle` plus the scalar additions: Tan, Asin, Acos, Atan, Atan2, Fma, CopySign, Radians, Degrees, SmoothStep, Tau). `overloads`: operators chosen by both operands' types; `vectors`: Vec2 / Vec4 (and the double forms) compute through vector primitives |
| `fixgen.js <fixtures/core dir> [name]` | the fixtures `math-*` and `mathlib-glm` (`.treadle` + `.expected`) and the C twin `mathlib-glm.c`. It first builds and runs a C reference program (`mathref.h`, double precision, written independently of the library) to get every check's expected value |
| `fmtfix.js <fixtures/core dir>` | the fixture `math-format` (the exact text of every math type and of AppendF) |
| `benchgen.js <samples/bench dir>` | the benchmark kernel `nbody-mathlib` (its C twin is written by hand) |

`checks.js` lists the fixture checks, `dsl.js` builds each check as Treadle nodes and as C at the same time,
`lib.js` writes type files, and `vec.js`, `mat.js`, `quat.js`, `misc.js`, `fmt.js` and `mathadd.js` describe the types.

## Running it

Node.js 18 or later. On the development machine the portable Node is in `%USERPROFILE%\.local\node`. From the
repository root, after building the editor:

```
set NODE=%USERPROFILE%\.local\node\node.exe
%NODE% tools\mathgen\gen.js TreadleCore\core overloads vectors
%NODE% tools\mathgen\fixgen.js TreadleCompiler\fixtures\core
%NODE% tools\mathgen\fmtfix.js TreadleCompiler\fixtures\core
%NODE% tools\mathgen\benchgen.js TreadleCore\samples\bench
build\Release_Win64\TreadleEditor\Treadle.exe --format TreadleCore\core TreadleCompiler\fixtures\core TreadleCore\samples\bench\nbody-mathlib
```

`fixgen.js` compiles its C reference with the clang of `tools\llvm-mingw` (`scripts\get-llvm-mingw.ps1`), or the one
named by `TREADLE_CLANG`; its work files go to `%TEMP%\treadle-mathgen`. Then run the `core` self tests and check
that `git diff` shows only the change you meant.
