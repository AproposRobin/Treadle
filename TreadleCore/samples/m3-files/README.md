# M3: files

Files and folders with the core library: counts the words of the command line (or of a built-in sentence)
through a `Queue`, keeps their first-seen order with a `HashSet`, writes the counts to `m3-files-out/counts.txt`
with `File.WriteAllText`, reads the file back line by line with `File.ReadLines`, lists the folder with
`Directory.GetFiles`, then removes both.

## Run it

```
Treadle.exe --build-run samples\m3-files
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux
`./treadle --build-run samples/m3-files`.) Or open the folder in the editor and press Ctrl+F5. Add `--config
Release` for an optimised build.

It prints the counts read back from the file, `m3-files-out: counts.txt` and `removed: true true`. The folder is
made in the folder the program runs in (the project folder for `--build-run`) and removed again.
