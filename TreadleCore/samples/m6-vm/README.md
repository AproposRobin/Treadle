# Mini VM

A small bytecode virtual machine made entirely of Treadle graphs, with the language it runs: a lexer, a
precedence-climbing parser, a compiler to stack bytecode with patched jumps and call frames, the virtual machine
itself, and a disassembler. The scripting language is tiny: numbers, texts, booleans, variables, `if`, `while`,
functions (recursive, and passed around as values) and three built-in functions.

## Run it

```
Treadle.exe --build-run samples\m6-vm -- --selftest
```

(`samples\` of the Treadle folder; in a source checkout `TreadleCore\samples\`; on Linux `./treadle --build-run
samples/m6-vm -- --selftest`.) Or open the folder in the editor and press Ctrl+F5. Add `--config Release` for an optimised build.

What follows `--` goes to the program:

| Argument | Effect |
|---|---|
| (none) | Runs the built-in demo script |
| `<file>` | Runs the script in the file |
| `--disasm [<file>]` | Prints the bytecode of the file, or of the demo script |
| `--bench` | Times `fib(27)` (recursive) and a loop of 10,000,000 iterations, run by the virtual machine |
| `--selftest` | Runs 13 built-in test scripts and prints `selftest ok`, or the first one that failed (exit code 1) |

The exit code is 0 when the script ran, 1 for an error found before it runs (a character, the grammar, a
misplaced `return` or function), 2 for an error while it runs, 3 when the file cannot be read.

A program started by `--build-run` runs in the project folder, so the sample script is named as it is (Ctrl+F5 in
the editor runs it in the build folder, `build\Debug` or `build\Release`, where it is `..\..\sample.mini`):

```
Treadle.exe --build-run samples\m6-vm -- sample.mini
```

prints

```
sum of fib(1..10) = 143
2 5 -8
len(mini) = 4 and true
```

## The language

A script is a list of statements. `#` starts a comment that runs to the end of the line.

```
program    = { statement } ;
statement  = "let" NAME "=" expression ";"
           | NAME "=" expression ";"
           | "fn" NAME "(" [ NAME { "," NAME } ] ")" block
           | "if" expression block [ "else" ( block | if-statement ) ]
           | "while" expression block
           | "return" [ expression ] ";"
           | block
           | expression ";" ;
block      = "{" { statement } "}" ;
expression = unary { BINARY-OPERATOR unary } ;      (by precedence, below)
unary      = ( "-" | "!" ) unary | call ;
call       = primary { "(" [ expression { "," expression } ] ")" } ;
primary    = INT | FLOAT | TEXT | "true" | "false" | NAME | "(" expression ")" ;
```

`INT` is a whole number (`42`), `FLOAT` has a fraction (`2.5`), `TEXT` is anything between double quotes on one
line (no escapes). Names start with a letter or `_`.

Binary operators, from the loosest to the tightest; all group to the left:

| Level | Operators |
|---|---|
| 1 | `\|\|` |
| 2 | `&&` |
| 3 | `==` `!=` |
| 4 | `<` `<=` `>` `>=` |
| 5 | `+` `-` |
| 6 | `*` `/` `%` |

What the values do:

* Whole numbers are 64-bit; `/` between two of them truncates (`7 / 2` is `3`), and dividing by zero is an error.
  Mixing a whole number with a fraction gives a fraction (`7.0 / 2` is `3.5`).
* `+` joins texts when either side is a text: `"n=" + 5` is `n=5`.
* `==` and `!=` compare any two values; the other operators need numbers.
* `&&` and `||` stop early and give the deciding value. `nil`, `false` and `0` count as false, everything else as
  true.
* `let` at the top level makes a global; inside a function, parameters and `let` are local to the call.
  Assigning to a global that was never made with `let` is an error.
* Functions are declared at the top level and can be used before their declaration. A function's name is a value:
  `let f = square; f(3)` calls it, and a function can take another one as a parameter. A function without
  `return` gives `nil`.
* Built-in functions: `print(a, b, ...)` prints its values separated by spaces and ends the line; `len(text)` is
  the length of a text in bytes; `str(value)` is the value as `print` shows it.

Errors name the line and column:

```
error: line 3, column 9: operands must be numbers
error: line 2, column 10: undefined variable 'y'
error: line 1, column 15: expected ')'
```

## A sample script

```
# A sample script for the m6-vm virtual machine.
fn fib(n) {
  if n < 2 { return n; }
  return fib(n - 1) + fib(n - 2);
}

fn map3(f, a, b, c) {
  print(f(a), f(b), f(c));
}

fn double(x) { return x * 2; }

let total = 0;
let i = 1;
while i <= 10 {
  total = total + fib(i);
  i = i + 1;
}
print("sum of fib(1..10) =", total);
map3(double, 1, 2.5, -4);
let name = "mini";
print("len(" + name + ") =", len(name), "and", str(len(name)) + "!" == "4!");
```

## How it is built

| Type | What it does |
|---|---|
| `TokenKind`, `Token` | A token: a payload enum (a number, a text, a name, a symbol by its code, the end) and its position |
| `Lexer` | Turns the script into a `List<Token>`, or a `ScriptError` at the first character it cannot read |
| `Ast` | The syntax tree: a payload enum whose nodes own their children's lists; `Ast.Free` deletes a whole tree |
| `Parser` | Statements by recursive descent, expressions by precedence climbing; on an error everything it built is deleted |
| `Opcode`, `Instr`, `Chunk` | The 28 instructions, an instruction (opcode, two operands, position) and a compiled script: code, constants, function table |
| `Compiler` | Walks the tree and writes the chunk: local slots, globals by name, jumps patched once their target is known |
| `Value` | A value of the language: a payload enum (`Nil`, `Int`, `Float`, `Bool`, `Str`, `Func`) and the arithmetic on it |
| `Vm` | Runs a chunk on a value stack with call frames on a `Stack`, globals and native functions in Dictionaries, and an `OnTrace` event fired for each instruction while tracing |
| `Disassembler` | Prints a chunk |
| `ScriptError` | The error of every stage: line, column, message |
| `Program` | The command line, the self test and the benchmark |

The self test runs the scripts of each part of the language (arithmetic, precedence, texts, locals and globals,
`if` and `while`, recursion, functions as values), two runtime errors, a character error and a grammar error, a
traced run whose subscriber must be called once per instruction, and a generated script of 12,500 assignments
(more than 50,000 instructions).
