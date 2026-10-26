# M2: a tour of the language

One small graph per language feature, each called once from `Program` and printing a line or two: gates (Do Once,
Do N, Flip Flop, Multi Gate), casts, tuples, delegates, events and Lambdas, nullables, enumerators and For Each,
Switch on strings, allocators, atomics, SIMD vectors, extensions, properties, static constructors, C variables
through the C import (`src/cvars.cimport`, with a small C source) and a library project brought in by a `depends`
line (`lib/M2Lib.tproj`). Open a Sheet in `src\` to see how a feature is wired; its doc line says what it prints.

## Run it

```
Treadle.exe --build-run samples\m2-frontend
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m2-frontend`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It prints one line per check (the first is `the static constructor ran first`, the last `cvar stdout`) and exits
with code 0.
