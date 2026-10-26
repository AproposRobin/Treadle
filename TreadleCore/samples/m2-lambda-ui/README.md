# Lambdas

Lambdas in the editor: a function pointer Lambda handed to C's `qsort` as its compare callback (through
`cstd.cimport`), and a Local Lambda of a delegate type (`IntFn`) that captures a local, handed to a function that
takes the delegate.

## Run it

```
Treadle.exe --build-run samples\m2-lambda-ui
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m2-lambda-ui`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It prints `adeelrt` (the letters of "treadle", sorted by the callback), then `142`.
