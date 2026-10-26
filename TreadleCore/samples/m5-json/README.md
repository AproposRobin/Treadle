# JSON

A JSON reader and writer made entirely of Treadle graphs: a recursive-descent parser with line and column
errors, a writer with a compact and a pretty form, path lookups, a generic fold over the tree, and a set of
built-in checks. It follows RFC 8259, with two relaxations noted below.

## Run it

```
Treadle.exe --build-run samples\m5-json -- --selftest
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux `./treadle --build-run
samples/m5-json -- --selftest`.) Or open the folder in the editor and press Ctrl+F5. Add `--config Release` for an optimised build.

What follows `--` goes to the program:

| Argument | Effect |
|---|---|
| `--selftest` | Runs the ten built-in cases and prints `selftest ok`, or the first case that failed (exit code 1) |
| `<file>` | Reads the file, prints its statistics, the compact form (when it is under 2000 bytes) and the round-trip check, and writes the pretty form to `<file without extension>.pretty.json` |
| `-` | Reads the document from stdin and prints the pretty form instead of writing a file |

A program started by `--build-run` runs in the project folder (Ctrl+F5 in the editor runs it in the build folder,
`build\Debug` or `build\Release`), so a file of the project folder is named as it is:

```
Treadle.exe --build-run samples\m5-json -- data.json
```

prints

```
nodes 49, depth 4, bytes 616
compact 493 bytes, pretty 841 bytes
{"empty":{"list":[],"map":{}},"items":[{"id":1,"path":"C:\\samples\\m4-breakout","size":1500000,...
round trip: ok
wrote data.pretty.json
```

and writes `data.pretty.json` next to `data.json`. From a terminal in the project folder the built program takes
the same name: `build\Release\M5Json.exe data.json`.

The exit code is 0 when the document is JSON and reads back the same, 1 when the file cannot be read or written,
is not JSON (the message gives the line and column) or does not round-trip, and 2 without an argument.

## What it reads and writes

* **Values:** null, true, false, numbers (read with `Double.Parse`, so every number is a double), strings, arrays
  and objects. A key that appears twice in one object is an error.
* **Strings** are UTF-8. The escapes `\" \\ \/ \b \f \n \r \t` and `\uXXXX` are decoded; a `\u` escape of a high
  surrogate must be followed by one of a low surrogate, and the pair becomes one character. A lone surrogate, a
  raw control character (a tab or a line break inside the quotes) and an unknown escape are errors.
* **Errors** name the line and the column (columns count bytes, from 1) where reading stopped: a trailing comma
  (`[1,2,]` is an error at column 6, where the `]` is), a missing `:` or `,`, text after the value, an empty
  document, a bad literal, nesting deeper than 512 levels.
* **Relaxed:** a number with leading zeros (`01`) or a point with no digits after it (`1.`) is accepted, because
  the text goes to `Double.Parse` as it is.
* **Writing:** object members are sorted by key, so the output is the same on every run (the order of the input
  is not kept). An integer below 10^15 is written without a fraction; other numbers with 15 significant digits,
  or 17 when 15 would not read back as the same double. NaN and the infinities cannot occur in JSON text; a value
  that holds one is written as `null`. Pretty output indents by two spaces.

## Who owns what

A `JsonValue` owns what it holds: the String of a string, the List and the elements of an array, the
Dictionary, its String keys and its values of an object. `JsonValue.Free(value)` deletes all of it, the
children first. A copy of a value (what For Each gives, or what `Query.Find` finds) is a second name for the
same objects, not a second owner: free only the root. `JsonDocument` holds a root and frees it in its
destructor, so a Defer Delete of the document cleans up everything. When the parser stops with an error it
frees what it had read so far. A Debug build reports leaks when the program ends; this sample has none.

## The built-in cases

| Case | Checks |
|---|---|
| scalars | Each kind of scalar in one array: 9 values, depth 2, both round trips |
| query | `a.b[2].c`, `a.b[1]`, a whole subtree, a missing member, an index out of range, an index on a number |
| string escapes | Every short escape and a `\u` escape decode to the right bytes and are written back |
| unicode | `\u` escapes in the Basic Multilingual Plane and a surrogate pair give the same bytes as the raw UTF-8 |
| deep nesting | 500 nested arrays parse; 513 are refused at the 513th bracket |
| 1 MB array | A generated array of about 1 MB (14730 objects): parsed and written with the time and the rate printed, the count checked, the compact text equal to the input |
| trailing comma in an array / in an object | `[1,2,]` and `{"a":1,}`, at the exact column |
| invalid documents | 14 documents that are not JSON, one of them with the error checked at line 2, column 8 |
| round trip | The exact compact and pretty texts of a mixed document, keys sorted, `0.30000000000000004` kept with 17 digits |

## What is inside

| Type | What it shows |
|---|---|
| `JsonValue` | A payload enum whose cases hold a List and a Dictionary of itself; `Free` walks it with a Switch and For Each |
| `Parser` | A class reading a StringView with a position: Switch on the next byte, recursion with a depth limit, `Result<JsonValue, ParseError>` from every reader, Result: match to free partial values on errors, While loops, Math nodes for the surrogate pair |
| `ParseError` | A struct with the line, the column and a constant message, and `Describe` with AppendF |
| `Writer` | Recursive writing, a Lambda comparer to sort the keys, number formats (`G15`, `G17`) and Double.TryParse to pick between them |
| `Query` | A path walk with Is Case on the enum, Int.Parse for indexes, Dictionary.TryGet, `Option<JsonValue>` |
| `Visitor<T>` | A generic class holding a delegate, folding over the tree with Invoke |
| `Stats` | Two folds with Lambdas: the number of values and the deepest level |
| `Equality` | Structural comparison and the write-then-read round trip |
| `JsonDocument` | A class whose destructor frees a tree |
| `SelfTest` | The ten cases, a Stopwatch for the timing |
| `Program` | The command line, File and stdin reading, Path.ChangeExtension, File.WriteAllText |
