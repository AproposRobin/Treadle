# M3: counting words

The core library: counts the words of the command line (or of a built-in sentence when there are none) and prints
them by count, most frequent first, then how long it took. The words go into a `List<String>` that owns them, are
counted in a `Dictionary<String, int>`, sorted with a Lambda comparer, printed with `AppendF` and timed with a
`Stopwatch`.

## Run it

```
Treadle.exe --build-run samples\m3-core -- a b c
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m3-core -- a b c`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It prints `3 words, 3 different` and each word with its count. Without arguments it counts its own sentence.
