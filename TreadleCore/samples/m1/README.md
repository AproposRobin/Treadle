# M1: the zoo

The program Getting-Started (`docs/Getting-Started.md`) builds step by step: an `Animal` base class with a
virtual `Speak` and two subclasses (`Dog`, `Bird`), a `Point` struct, a generic `Box<T>` with two instances,
Construct / Local / Delete / Defer Delete / Defer, a Branch, a loop, a Sequence and a call into the C library
(`libc.cimport`).

## Run it

```
Treadle.exe --build-run samples\m1
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m1`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It prints

```
Woof
4
Tweet
2
7
7
done
goodbye from Defer
an animal is freed
an animal is freed
```
