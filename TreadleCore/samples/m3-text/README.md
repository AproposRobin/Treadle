# M3: text

Text with the core library: `Int` / `Double` `TryParse` and parse errors, an `AppendF` table with alignment and
number formats, UTF-8 code points, `Process.Start` with its output captured (`cmd /c echo` on Windows, `echo` on
Linux) and `Time.Now` as a `DateTime`.

## Run it

```
Treadle.exe --build-run samples\m3-text
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m3-text`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It prints a table of numbers (each argument, or a built-in list) with their total, the bytes and code points of
a non-ASCII text, what the child process wrote, and the current year.
