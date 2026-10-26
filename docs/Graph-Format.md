---
audience: developer
title: Graph format
summary: The on-disk text format of type files (.treadle), layout files (`layout/<Type>.layout`), project files and C import sets: grammar, canonical form, versioning, and three complete examples.
order: 2
---

# Graph format

The graph files are the program. They must be human-diffable, stable under small edits, merge-friendly in
git, versioned, and round-trip byte-identically through load and save when nothing changed. Layout data
lives in a sidecar so that a semantic diff never shows a node being dragged.

## 1. Choice of format

**Decision: a custom line-oriented record format** (one record per line, properties on tab-indented
continuation lines), not TOML and not JSON.

1. A one-node edit is a 1-4 line diff; git merges line-based records cleanly, with no trailing-comma or
   closing-bracket churn (JSON) and no array-of-tables headers (`[[nodes]]`) that TOML would need per node.
2. Wires are the most numerous records; `wire a.then b.in` on one line is what a reviewer wants to read.
3. Canonical ordering (nodes by id, wires by destination) makes the output a pure function of the content,
   which is what byte-identical round trips and clean merges need; neither TOML nor JSON libraries promise an
   ordering or a quoting style.
4. The reader / writer is plain Beef with no parser library (`TreadleCore/src/Format/`: `TreadleCodec.bf` about 1,400 lines, `RecordText.bf` 300 for tokens and quoting); `MiniToml` (`TreadleCore/src/Document/MiniToml.bf`, kept from
   the original editor) and `UpdateJson` (`TreadleCore/src/Update/UpdateJson.bf`) are the references for line
   splitting and JSON-style string escaping, which this format reuses for its string tokens.
5. The project file and the C import set use the same reader, so there is one parser in the whole stack.

## 2. Lexical rules

| Rule | Value |
|---|---|
| Encoding | UTF-8, no byte order mark, `LF` line endings, one trailing `LF` |
| Header | First line: `# treadle 1` (type file), `# treadle-layout 1` (layout), `# tproj 1`, `# cimport 1`. The number is the format version. |
| Record | Starts at column 0: `kind [id] tokens...` |
| Property | A line starting with exactly one tab, inside a record: `key tokens...` |
| Comment | A line starting with `#` after the header. Written only by hand; the writer keeps it with the record after it (or the record it sits inside). |
| Blank line | Ignored on read and not kept; the writer puts one blank line between members and none inside a Sheet |
| Token | A **word** (`[A-Za-z0-9_.:<>,\[\]*?()+-]+`, no spaces) or a **string** (`"..."` with JSON escapes `\" \\ \n \t \r \uXXXX`). The writer re-escapes strings canonically (`\uXXXX` only for control characters, so a hand-written `\u00e9` comes back as the character itself). |
| Free text | One rule for every value a person types: type, member, parameter, local and payload names, Switch case labels (`case <label>`) and the pin names made from them, project, config and C import set names, folders and paths (`source`, `depends`, `cimport`, `output`, `header`, `include`, `lib`). Such a value is written as a word when it reads back as one: not empty, no space, tab or other control character (bytes up to 0x20 and 0x7F), not starting with `"`; quotes, backslashes and UTF-8 inside a word stay as they are (`back\slash`, `café`). Otherwise it is a string with the escapes above: `case "two words"`, `case "say \"hi\""`, `case ""`, `project "My Game"`. The writer quotes only when needed, so a file without such values is unchanged. A wire or `route` end `<id>.<pin>` whose pin name needs quoting is one string as a whole: `wire "a2.case:two words" a3.in` (node ids have no dots, so the first dot splits it). |
| Id | A word of 1-8 chars from `[a-z0-9]`, unique in its file. The editor assigns 5-char random ids (Crockford base32, lower case, no `i l o u`), so two branches adding nodes never collide on a counter. |
| Type syntax (in a token) | `int`, `String`, `Game.Player`, `List<int>`, `int[]`, `int[4]`, `int?`, `int*`, `(int,float)`, `function:int(int)`, `delegate:void(int)`, vectors `float4`, `int32x4`, `bool4` (`Vector<float,4>` reads as `float4`; a vector literal on an `in` line lists the lanes without spaces, `in v 0,1,0,0`, or one value for all, `in v 2`). Names resolve through the file's `uses` lines, then the type's namespace and its parents. |
| Struct literal (in a token) | On an `in` line of a struct-typed input whose fields are all numbers, bools or characters (the core math types: `Vec3`, `Quat`, `Color`, `Color32`, `Rect`, ...): one value per field in declaration order, separated by commas without spaces, every field written: `in translation 1,2.5,-3` (a Vec3), `in value 255,128,0,255` (a Color32). Each value must fit its field (T2232 otherwise, also for a count other than the fields'); it compiles as the Make of those fields. Not on a Receiver (it takes a wire). The format reads it as any word, so it needs no new syntax. |
| Member reference | `Type.Member` or `Type.Member(ParamTypes)` when the member is overloaded: `Console.WriteLine(StringView)`. `this.Member` for the own type. C imports: `C.<set>.<symbol>`. |

Unknown record kinds and unknown property keys are **kept verbatim and written back in place**, so a file
from a newer version survives a round trip through an older editor. The document stays editable: it loads
with a message naming how many records of a newer format are kept as they are, and edits round-trip them
safely. In place means: an unknown record and its properties after the record before it; an unknown property
after the known key it followed (unknown node properties are kept as node settings in the same place).

## 3. Type file (`<Type>.treadle`)

### 3.1 Records

Order in the file (canonical): header, `type`, its properties, then the members in declaration order (the
Outline's order, kinds mixed), each followed by its own records: its properties in the key order of the
table below, its `param`, `out`, `local` records in declaration order, then its Sheets (`lambda:` Sheets
after the member's other Sheets). Within a Sheet: `node` sorted by id; `wire` sorted by
destination node id, then destination pin, then source node id, then source pin; then `group` sorted by id, its
`node` lines sorted by id.

| Record | Form | Properties |
|---|---|---|
| `type` | `type <Name> <class\|struct\|interface\|enum\|delegate\|extension>` | `namespace A.B`, `uses A.C` (repeatable), `base Type`, `implements Iface` (repeatable), `generic T [constraints...]` (repeatable: `generic T IFoo class`, `generic const N int`), `access`, `abstract`, `sealed`, `static`, `underlying int32` (enum), `extends Type` (extension), `signature ret(params)` (delegate), `attr Name arg...`, `doc "text"` |
| `field` | `field <name> <Type>` | `static`, `const` (a constant, [Language.md 4.6](Language.md#46-constants): static whether `static` is written or not), `readonly`, `access`, `init <token>` (literal, `.Case`, `default`, `null`; a `const` field's init is a constant expression, the rest of the line: `init Cols * 60 + Gap * 2`; a vector constant: `init float4(0, 1, 0, 0)`, `init Up * 2 + 1`), `elements <expr>, <expr>, ...` (a `const` field of type `T[]`: its values, constant expressions separated by commas, the rest of the line: `elements 1, 2, Rows`), `owner <owned\|ref\|appended\|pointer\|custom>`, `category "text"` (the group the Outline and the Node menu list it under; free text, section 2), `attr`, `doc` |
| `case` | `case <Name> [= value]` (enum) | `payload <name> <Type>` (repeatable, for payload enums), `doc` |
| `property` | `property <id> <name> <Type>` | `static`, `auto` (hidden field, no Sheets), `access`, `attr`, `doc`; `get` / `set` presence is given by the Sheet records that follow (`sheet get`, `sheet set`) |
| `function` | `function <id> <name>` | `static`, `virtual`, `abstract`, `override`, `sealed`, `pure`, `unsafe`, `mutating`, `inline`, `access`, `returns <Type>` (default `void`), `generic T ...`, `cconv cdecl\|stdcall`, `attr`, `doc` |
| `ctor` / `dtor` | `ctor <id>` / `dtor <id>` | `static` (ctor), `access`, `chain base\|this` (the Base Constructor node is `node <id> ChainCtor` in the Sheet), `attr`, `doc` |
| `operator` | `operator <id> <symbol\|implicit\|explicit>` | as `function` (always static) |
| `param` | `param <name> <Type>` | `mode value\|ref\|out\|in`, `default <token>` |
| `out` | `out <name> <Type>` | A further output (an `out` parameter) |
| `local` | `local <name> <Type>` | `init <token>`, `owner owned\|ref` |
| `sheet` | `sheet get\|set\|body\|lambda:<nodeid>` | Starts the node list of a property accessor, a function body, or a Lambda Sheet's nested body. A `function`/`ctor`/`dtor`/`operator` with no `sheet body` is abstract/extern/imported. |
| `node` | `node <id> <Kind> [subject]` | `set <key> <token...>` (a node setting) and the kind-specific keys below (`case`, `capture`) and `split <pin> <Type>` (a split struct pin, [3.2](#32-node-kinds-and-their-subjects)), in file order; then `in <pin> <token>` (literal on an unlinked input) in pin order; `comment "text"`, `disabled`, `unsafe` (Scope). Settings decide the pins, so they lead. |
| `wire` | `wire <fromId>.<pin> <toId>.<pin>` | none |
| `group` | `group <id> ["title"]` | `node <id>` (repeatable): a collapsed node group of the Sheet, its members by record id. A view only: the compiler ignores it. Whether it is folded and where its node is drawn are layout ([section 4](#4-layout-file-typevtypelayout)). A member whose node is gone is left out on the next write; a group with none goes. |

### 3.2 Node kinds and their subjects

| Kind | Subject | Pins (in -> out) | Settings |
|---|---|---|---|
| `Entry` | - | `then`, one output per parameter by name | - |
| `Return` | - | `in`, `value`, one input per `out` | - |
| `Call` | member reference | `in`, `receiver` (member), args by name -> `then`, `result`, outs by name; pure calls have no `in`/`then` (read without type information, a Call is a flow call when a wire uses its `in` or `then`); a flow Call of a function with `[ExpandEnumAsFlow]` also has `case:<Case>` per case of the returned enum; a Call of a C variadic function takes `va0`, `va1`, ...; an event's Add / Remove / Invoke / Clear / Count is a Call of `<Type>.<event>.Add` ... with `handler` or `arg0`, `arg1`, ... ([Language.md 4.5](Language.md#45-events)) | `set order relaxed\|acquire\|release\|acqrel\|seqcst` on a `Core.Atomic` Call |
| `Get` / `Set` | `this.field` (own type, Receiver unconnected = this), `Type.field` (a member of another type; `receiver` must be wired), `Type.staticField`, `local:name`, `param:name`, properties the same way | Get: `receiver` -> `value`. Set: `in`, `receiver`, `value` -> `then`, `result` | `set op += -= *= /=` (compound Set) |
| `Construct` / `Local` | Type | `in`, ctor args by name, (`allocator`) -> `then`, `object` | `set ctor (Types)` picks the constructor; `set function-scope` on Local; `set count` for arrays (then `count` is an input) |
| `Delete` | - | `in`, `object`, (`allocator`) -> `then` | - |
| `Defer` | - | `in` -> `deferred`, `done` | - |
| `DeferDelete` | - | `in`, `object` -> `then` | - |
| `Branch` | - | `in`, `condition` -> `true`, `false` | - |
| `Sequence` | - | `in` -> `then0..n` | `set count n` |
| `While` / `DoWhile` | - | `in`, `condition` -> `body`, `done` | - |
| `For` | - | `in`, `start`, `count`, `step` -> `body`, `index`, `done` | `set index-type int` |
| `ForEach` | - | `in`, `collection` -> `body`, `element`, `index`, `done` | `set element-type T` |
| `Break` / `Continue` | - | `in` | - (a `Break` with a type subject is the struct Break below) |
| `Switch` | - | `in`, `value` -> `case:<label>` per case, `default`, `done`; payload outputs `case:<label>.<field>` | `set on Type`, `case <label>` (repeatable, ordered; the label is free text, section 2: `case "two words"`; the editor edits it in Properties) |
| `Scope` | - | `in` -> `body`, `done` | `unsafe` |
| `Gate` / `DoOnce` / `DoN` / `FlipFlop` / `MultiGate` | - | Gate: `in` -> `exit`, `done`; DoOnce: `in` -> `once`, `done`; DoN: `in`, `n` -> `do`, `counter`, `done`; FlipFlop: `in` -> `a`, `b`, `isA`, `done`; MultiGate: `in` -> `out0..n`, `done` | `set state <fieldName>` (default: a hidden compiler field), `set start-closed` (Gate), `set count n`, `set loop`, `set random` (MultiGate) |
| `GateOpen` / `GateClose` / `GateToggle` / `ResetDoOnce` / `ResetDoN` / `ResetMultiGate` | - | `in` -> `then` | `set state <fieldName>` (which node's state; [Language.md 5.1](Language.md#51-flow-nodes)) |
| `ResultMatch` | - | `in`, `result` -> `ok`, `value`, `err`, `error`, `done` | - |
| `Try` | - | `in`, `result` -> `then`, `value` | - |
| `Fatal` | - | `in`, `message` | - |
| `Operator` | `+ - * / % == != < > <= >= && \|\| ! & \| ^ << >> ~ neg` | `a`, `b` -> `result` | - |
| `Select` | - | `condition`, `true`, `false` -> `result` | - |
| `Cast` | Type | `value` -> `result`; with `set checked` a flow node: `in`, `value` -> `then` (Succeeded), `failed`, `result`; with `set kind box` a flow node: `in`, `value` -> `then`, `result` | `set kind numeric\|class\|unchecked\|box\|unbox`, `set checked` |
| `Make` / `Break` | struct or tuple Type | Make: fields -> `value`; Break: `value` -> fields | - |
| `MakeCase` / `IsCase` | `Enum.Case` | MakeCase: payload fields -> `value`; IsCase: `value` -> `result`, payload fields | - |
| `Index` | - | `collection`, `index` -> `value` | `set checked` (kept; not honoured yet, [Language.md 3.1](Language.md#31-debug-checks)) |
| `This` / `Base` | - | -> `value` | - |
| `Literal` | - | -> `value` | `set type T`, `set value <token>` (only when a literal must feed several nodes; otherwise literals live in `in` lines) |
| `Bind` | member reference | `receiver` -> `value` (a delegate or function pointer); with `set alloc construct\|local` a flow node (`in`, `then` added) | `set alloc construct\|local\|pointer` |
| `Lambda` | - | captures -> `value`; body is `sheet lambda:<id>`, whose Entry gives the inputs; with `set alloc` or a `capture` line a flow node (`in`, `then` added) | `set type <delegate type or function:R(A)>`, `set inputs <name>...` (`p0`, `p1`, ... when not named), `set alloc construct\|local`, `capture <name> by-ref` (by value when there is no line; the reader also takes `by-value`) |
| `Invoke` | - | `in`, `delegate`, `arg0`, `arg1`, ... -> `then`, `result` | - |
| `Math` | - | one input per name (the first segment of `a.x`; function names are not inputs) -> `result` | `set expr "a*b+1"` (the grammar: [Language.md 5.6](Language.md#56-math-expression)) |
| `Swizzle` | - | `value` (a vector) -> `result` | `set lanes zyx`: the lanes picked by the letters `x y z w`; one letter gives the lane's value ([Language.md 2.8](Language.md#28-vectors-simd)) |
| `Shuffle` | - | `a`, `b` (two vectors of one type) -> `result` | `set mask 0 4 1 5`: the lanes picked by number, 0..N-1 from `a`, N..2N-1 from `b` |
| `ChainCtor` | `base` or `this` | args by name | `set ctor (Types)` |
| `Intrinsic` | name | by intrinsic | core library only |

Knots (reroute points) are not nodes; they live in the layout file ([section 4](#4-layout-file-typevtypelayout)).

Pins not listed in `in` lines and not wired hold the type's `default`; a required input with neither is a
compile error on the node ("needs a value"). Pins are never written: the reader makes the pins a node's kind
and settings give, plus any pin a wire or an `in` line names (its type comes later from the compiler).

**Split struct pins.** A node line `split <pin> <Type>` (any node, any struct-, tuple- or vector-typed value pin;
`Type` is the struct as the pin had it when it was split) draws that pin as one pin per field, named
`<pin>.<field>`: `value.First`, `value.Second`; a vector's fields are its lanes, `value.x` ... `value.w`
(`value.lane0` ... above 4 lanes: `split value float4`, `in value.w 4`). Wires and `in` lines name those field pins like any other pin
(`wire a1.x a2.value.X`, `in value.Y 2`); the pin itself takes no wire or literal while it is split. The
compiler reads an input split as a `Make <Type>` fed by the field pins and wired into the pin, an output
split as a `Break <Type>` fed by the pin and giving the field pins; a field pin with neither a wire nor a
literal is the field's default. Messages about them are on the node. The editor adds the field pins that
have neither when it shows the Sheet (the file only names the ones in use).

```
node a2 Set this.mPos
	split value Game.Vec2
	in value.Y 2
node a3 Get this.mPos
	split value Game.Vec2
wire a1.x a2.value.X
wire a3.value.Y a4.value
```

### 3.3 Example 1: a class with fields

The examples in this document are the canonical files the editor writes ([section 7](#7-canonical-form-and-round-trip)):
they are the round-trip fixtures in `TreadleCore/samples/`, byte for byte. The same three type files in
reading order are in `TreadleCore/samples/reading-order/`; they normalise to these on save.

`Game/Player.treadle`

```
# treadle 1
type Player class
	namespace Game
	uses Game.Core
	base Actor
	implements IDamageable
	doc "The player character."

field mHealth int
	init 100
	doc "Hit points; the player dies at 0."

field mName String
	owner owned

field sCount int
	static
	access internal

property q7k2m Name String
	access public
sheet get
node a1 Entry
node a2 Return
node a3 Get this.mName
wire a1.then a2.in
wire a3.value a2.value

ctor c4x9p
	chain base
param name String
sheet body
node b1 Entry
node b2 ChainCtor base
	in level 1
node b3 Set this.mName
node b4 Construct String
	set ctor (StringView)
node b5 Return
wire b4.then b3.in
wire b4.object b3.value
wire b1.then b4.in
wire b1.name b4.text
wire b3.then b5.in

function f8d2a TakeDamage
	override
	access public
param amount int
sheet body
node d1 Entry
node d2 Set this.mHealth
	set op -=
node d3 Branch
node d4 Operator <=
	in b 0
node d5 Call this.Die()
node d6 Get this.mHealth
node d7 Return
wire d1.then d2.in
wire d1.amount d2.value
wire d4.result d3.condition
wire d2.then d3.in
wire d6.value d4.a
wire d3.true d5.in
wire d3.false d7.in
wire d5.then d7.in

function g3m1c Die
	virtual
	access protected
sheet body
node e1 Entry
node e2 Return
wire e1.then e2.in
```

Read: `TakeDamage` subtracts `amount` from `mHealth` (a compound Set with `-=`), then branches on
`mHealth <= 0`; both arms merge into the Return (two wires into `d7.in`). `d6` (a Get) is evaluated when
`d3` runs, after the Set, so it reads the new value.

### 3.4 Example 2: Branch, Loop, Construct, Local, Delete, a libc call

`App/Program.treadle` (the entry type of a console project)

```
# treadle 1
type Program class
	namespace App
	uses Game
	static

function m0001 Main
	static
	returns int
param args String[]
local total int
sheet body
node a0 Call String.Append(int)
node a1 Entry
node a2 Construct Game.Player
	set ctor (String)
	in name "Hero"
node a3 DeferDelete
node a4 For
	in start 0
	in count 3
node a5 Call Game.Player.TakeDamage(int)
	in amount 40
node a6 Set local:total
	set op +=
node a7 Local String
	set ctor ()
node a8 Call String.Append(StringView)
	in text "Health "
node a9 Call C.libc.puts
node b1 Branch
node b2 Operator >
	in b 0
node b3 Get Game.Player.mHealth
node b4 Return
	in value 0
node b5 Return
	in value 1
node b6 Call String.CStr()
wire a8.then a0.in
wire a7.object a0.receiver
wire b3.value a0.value
wire a1.then a2.in
wire a2.then a3.in
wire a2.object a3.object
wire a3.then a4.in
wire a4.body a5.in
wire a2.object a5.receiver
wire a5.then a6.in
wire a4.index a6.value
wire a6.then a7.in
wire a7.then a8.in
wire a7.object a8.receiver
wire a0.then a9.in
wire b6.result a9.s
wire b2.result b1.condition
wire a4.done b1.in
wire b3.value b2.a
wire a2.object b3.receiver
wire b1.true b4.in
wire b1.false b5.in
wire a7.object b6.receiver
```

Read: `Main` constructs a `Player` on the heap and registers its deletion with Defer Delete (runs when the
function body region ends, after the Return value is computed). A For loop runs three times: each pass
calls `TakeDamage(40)`, adds the index to the local `total`, makes a `Local String` (freed at the end of
each pass), appends `"Health "` and the health value to it and prints it through libc's `puts`
(`String.CStr()` is a pure call giving a `char8*`, valid while the String lives). After the loop a Branch on
`mHealth > 0` returns 0 or 1. `b3` (Get `mHealth`, Receiver wired from the Construct's object) feeds two flow
nodes (`a0` and `b1`) and is evaluated once for each. Node ids are shown short here for readability; the
editor writes 5-character ids.

### 3.5 Example 3: a generic struct

`Core/Pair.treadle`

```
# treadle 1
type Pair struct
	namespace Core
	generic TFirst
	generic TSecond
	attr CRepr
	doc "Two values of any types."

field First TFirst

field Second TSecond

ctor k1a7e
param first TFirst
param second TSecond
sheet body
node a1 Entry
node a2 Set this.First
node a3 Set this.Second
node a4 Return
wire a1.then a2.in
wire a1.first a2.value
wire a2.then a3.in
wire a1.second a3.value
wire a3.then a4.in

function k2b8f Swap
	pure
	returns Pair<TSecond,TFirst>
sheet body
node b1 Entry
node b2 Make Pair<TSecond,TFirst>
node b3 Get this.First
node b4 Get this.Second
node b5 Return
wire b4.value b2.First
wire b3.value b2.Second
wire b1.then b5.in
wire b2.value b5.value

operator k3c9g ==
	returns bool
	generic TFirst operator==
	generic TSecond operator==
param a Pair<TFirst,TSecond>
param b Pair<TFirst,TSecond>
sheet body
node c1 Entry
node c2 Return
node c3 Operator &&
node c4 Operator ==
node c5 Operator ==
node c6 Break Pair<TFirst,TSecond>
node c7 Break Pair<TFirst,TSecond>
wire c1.then c2.in
wire c3.result c2.value
wire c4.result c3.a
wire c5.result c3.b
wire c6.First c4.a
wire c7.First c4.b
wire c6.Second c5.a
wire c7.Second c5.b
wire c1.a c6.value
wire c1.b c7.value
```

Read: `Swap` is pure, so a call to it is a value node. The `==` operator adds operator constraints on the
generic parameters so that comparing the fields is legal; `generic TFirst operator==` on the operator
record narrows the type's own parameter for this member (Beef's `where` on a method).

## 4. Layout file (`layout/<path>/<Type>.layout`)

Optional and disposable: deleting it loses positions, comment boxes, knots and the view; never meaning. The
editor writes it only when its text changed, and not at all when there is no layout. A type with no layout file opens
auto-arranged, and its next save writes the file. Records are grouped per
Sheet by the owner's id; Sheet blocks follow the type file's Sheet order, and inside one: `view`, `saved`,
nodes and node groups by id, then `box`, `route`, `collapsed`, `pinned`.

**Where it lives.** Layout files and backups are kept out of the source folders, so a graph can be run, shared
or built without anyone's layout. Under the project folder (the folder of the nearest `.tproj` above the type
file):

| What | Path | Example |
|---|---|---|
| Layout of a type file | `layout/<path of the type file relative to the project, extension dropped>.layout` | `src/Game/Engine.treadle` has `layout/src/Game/Engine.layout` |
| Backup of a saved-over file | `backup/<path relative to the project>.bak` (one file, replaced by the next save) | `backup/src/Game/Engine.treadle.bak`, `backup/layout/src/Game/Engine.layout.bak`, `backup/Shooter.tproj.bak` |
| Backup a format migration leaves | `backup/<path>.v<old>.bak` (once, never overwritten) | `backup/src/Game/Engine.treadle.v1.bak` |

The folder names are the optional project keys `layoutDir` and `backupDir` (section 5), `layout` and `backup`
by default, relative to the project folder (a rooted path is used as it is). A type file with no project file
above it keeps its sidecars beside it as `<file>.layout` (`Engine.treadle.layout`) and `<file>.bak`, and the
frozen `format-history` corpus is never moved. The path mapping is the only change from the first alpha: the
text of every file and the format version (still 1) are unchanged. Old projects are moved once: when a project is
opened (and by `--format --migrate`), `<Type>.treadle.layout` and `<Type>.vtype.layout` beside the sources and
`.bak` / `.v<old>.bak` backups of format files move into the two folders, one line per project says "moved N layout
files and M backups to layout/ and backup/", and where both places hold a file the newer one is kept and the
other is dropped with a line saying so.

Version control: **New Project** writes a `.gitignore` containing `backup/`; the layout folder stays committed by
default because positions are worth sharing. Ignore `layout/` as well to share only the graphs; they then open
auto-arranged for everyone else.

`layout/Game/Player.layout` (for `Game/Player.treadle`)

```
# treadle-layout 1
sheet get:q7k2m
	node a1 0 0
	node a2 300 0
	node a3 120 120
sheet c4x9p
	node b1 0 0
	node b2 260 0
	node b3 780 0
	node b4 520 0
	node b5 1040 0
sheet f8d2a
	view -40 120 1.0
	node d1 0 0
	node d2 260 0
	node d3 520 0
	node d4 380 160
	node d5 780 -60
	node d6 220 180
	node d7 1040 0
	box x1 200 -80 700 320 "Damage" 2
	route d6.value d4.a 300,170
sheet g3m1c
	node e1 0 0
	node e2 300 0
```

| Record / property | Meaning |
|---|---|
| `sheet <id>` / `sheet get:<id>` / `sheet set:<id>` / `sheet lambda:<nodeid>` | The Sheet the lines below belong to |
| `view x y zoom` | Last scroll and zoom |
| `saved <n> x y zoom` | The editor's saved view `n` (1-9) |
| `node <id> x y [w]` | Position in graph units (integers); `w` only for nodes the user resized (comment-bearing, Math). With a `group` id: where the folded group's node is drawn |
| `box <id> x y w h "title" <colorIndex>` | A comment box (purely visual; per-node comments are in the type file); the index names an 8-colour palette (`LayoutCodec.Palette`) |
| `route <from>.<pin> <to>.<pin> x,y [x,y ...]` | Knots of one wire |
| `collapsed <id>` | A node drawn compact (its unwired pins hidden); with a `group` id: the group is folded (drawn as one node). A line whose node or group is gone is left out on the next write |
| `pinned <id>` | A comment bubble pinned to a readable size |

Keys are stable node ids, so hand edits of the type file never shuffle positions (the original editor needed
content hashes because its keys were code positions; Treadle does not). A `node` line whose id is gone
from the type file is pruned on the next layout write.

## 5. Project file (`<Name>.tproj`)

```
# tproj 1
project Shooter
	kind console
	entry App.Program
	output bin/Shooter
	version 0.1.0
	namespace App
depends ../core/Core.tproj
cimport libc.cimport
cimport sdl2.cimport
config Debug
	define DEBUG
	checks on
	optimize 0
config Release
	optimize 2
	checks off
source Game
source App
```

`kind` is `console` (the default when the line is missing), `windowed` or `library` (as built: Compiler.md
1.1, "Project kinds"). A console program has a console window; a windowed one has none (the Windows
subsystem; on Linux the two are the same program), with the same `Main` forms and its Console output still
shown in the editor's Output Log by Run; a library is a DLL (Linux: `lib<Name>.so`) with no `entry` and no
`Main`, exporting its `[Export("name")]` functions ([Language.md 6](Language.md#6-entry-points)) and the pair
`treadle_init` / `treadle_shutdown` its user calls around them. `namespace` is the root namespace File > New
Class (and the other + Add > New entries) propose (a type in a sub-folder of a source folder gets the folder path after it: `Game/Enemies` gives
`App.Enemies`); New Project writes it, and New Class (any + Add > New entry) adds it (the project name made an identifier) to a file
without one. `source` lists folders scanned for `.treadle` files (default: the project folder). `depends` names
graph library projects compiled with this one. A `config`'s settings are kept in file order (above, Debug and
Release differ); unknown records are written at the end.

`layoutDir` and `backupDir` are optional lines of the `project` record (`layoutDir <folder>`, `backupDir <folder>`; written
only when set): the folders, relative to the project folder, that hold the layout files and the backups (section 4,
"Where it lives"). The defaults are `layout` and `backup`. The project index skips both folders.

A build names a config, and the config's keys decide what it does; the name only gives the defaults:

| Key | Values | Default | Effect |
|---|---|---|---|
| `optimize` | `0`, `1`, `2`, `3`, `size` | `2` for a config called `Release`, else `0` | clang's `-O` level for the units and the runtime (`size` is `-Os`); above 0 also `--gc-sections` at the link |
| `checks` | `on`, `off` | `off` for `Release`, else `on` | The Debug runtime and the checks: null, bounds and use-after-free checks naming the node, allocation tracking and the leak report at exit |
| `define` | `NAME` or `NAME=value`, several per line or several lines | none | Names the program reads with the core's `Build.IsDefined("NAME")` (a constant `bool`) and `Build.Value("NAME")` (a constant `StringView`, empty for a bare name); a later line's value wins |
| `debugFormat` | `dwarf`, `codeview`, `both` | `dwarf` | The debug info ([Compiler.md 7](Compiler.md#7-debug-info-and-node-mapping)) |
| `simd` | `x86-64`, `x86-64-v2`, `x86-64-v3`, `x86-64-v4`, `native` | `x86-64-v2` | The x86-64 level the program is compiled for: every function's `"target-cpu"` and the runtime's `-march` ([Compiler.md 6.4](Compiler.md#64-what-release-code-tells-llvm), SIMD-and-Vectors.md 1.7); `v3` adds AVX2, FMA and BMI2, `native` this machine's CPU (a warning, T1093: the program may not start on another one). Another value is T1094. A change compiles every unit again |

Debug info (`-g`, no stripping) is written when `checks` is on or `optimize` is 0. So a third config is just
keys, for example a profiling build with the Debug runtime at `-O2`:

```
config Profile
	optimize 2
	checks on
	define PROFILE LEVEL=3
```

A value that does not parse (`optimize fast`, `checks maybe`, `define 3D`) stops the build with a message
naming the config. Each config builds into `build/<config>/`; a changed key rebuilds what it changes
([Compiler.md 9](Compiler.md#9-incremental-builds)).

As built, Build reads every line above except `output` and `version`, which are kept and written back: the
program is `build/<Config>/<project>.exe` (`.dll` for a library; Linux: `<project>`, `lib<project>.so`). The
editor's project page (Properties, the project tile selected; Editor-Model.md) has rows for `kind`, `optimize`,
`checks`, `define` and `debugFormat` and writes these lines (there is no `lto` key: an optimised config always
compiles and links with ThinLTO, Compiler.md 6). New Project writes `checks` and `optimize` for Debug and Release. (The sample project file above is
`TreadleCore/samples/Shooter.tproj` with an SDL set and two `source` lines added for the example.)

## 6. C import set (`<name>.cimport`)

```
# cimport 1
import libc
	header stdio.h
	header stdlib.h
	header string.h
	lib msvcrt
	pure strlen strcmp memcmp
	hide _*
	only puts printf malloc free strlen strcmp memcmp
	category "C / libc"
```

One file holds one or more `import <set>` records. The keys the codec models are `header`, `include`,
`define`, `lib`, `pure`, `hide`, `only` and `category`; the importer's own `prefix` and `param`, and Build's
`bin` and `csource`, are kept as properties the codec does not model (written right after the `import` line).
What each key means for the import and for Build is in [C-Import.md](C-Import.md), "Writing a `.cimport`" and
"Building with a set"; the sample `TreadleCore/samples/libc.cimport` also has `param` lines. The declarations
the import writes (`<set>.cdecl`, a type file with C records) are made by File > Import C Headers or
`--import-c`, not on every build ([Compiler.md 8](Compiler.md#8-c-header-import)). `<name>.linux.cimport` /
`<name>.windows.cimport` beside a set file is that platform's variant of it.

## 7. Canonical form and round trip

* The writer emits records in the canonical order of [3.1](#31-records) and the properties of a record in a
  fixed key order (the order of the tables above). A load followed by a save of a canonical file is
  byte-identical; the editor saves only dirty documents, so untouched files are never rewritten.
* A hand-written file in another order is accepted and normalised on its first save (one-time diff). A type
  token that would not print back the same (spacing, unusual syntax) is kept verbatim, so a type never
  changes on a round trip.
* Ids are never reused within a file; a deleted node's id stays free but a new node gets a fresh random id.
* Renames of members are edits to every referencing line in the project, made by the editor as one undo
  group (as the original editor does); the compiler never guesses.
* A merge conflict can only happen on lines both sides changed: the same node's properties, the same wire
  destination, or the same member header. Two sides adding different nodes never conflict (different ids,
  different lines; the writer re-sorts on the next save). The editor opens a file with git conflict markers
  as read-only and shows the lines in the Problems panel.

## 8. Versioning

The header holds one integer, the format version (`# treadle 1`). It changes only when an existing record's
meaning changes. New record kinds and new keys do not bump it (they are preserved by older readers). As built
([Format-Stability.md](Format-Stability.md) 2-5):

* **Older file:** every reader runs the migration chain (`TreadleCore/src/Format/Migrations.bf`: one step per
  version and file kind over the file's records, before binding) and reads the result. In the editor the
  document is marked dirty; its first save keeps the old text once as `backup/<path>.v<old>.bak` (the layout's as
  `backup/layout/<path>.layout.v<old>.bak`) and writes the current version. `--format --migrate <paths>` does the same in
  batch; `--format` without `--migrate`, and `--format --check`, list such a file and leave it.
* **Newer file:** the compiler, the C import and `--format` refuse it with one diagnostic on line 1, "saved by a
  newer version V; this build reads up to N; open read-only" (`--format` and `--build-run` exit with code 2).
  The editor opens it read-only: a notice bar with the same message, every Sheet read-only, Save, edits and
  Build refused. A newer layout sidecar is not read (the Sheets are laid out again).
* **Renamed node kinds and pins:** read through the alias table (`TreadleCore/src/Format/Aliases.bf`): an old
  name loads as the current one and the next save writes the current one; no bump. Rows are never removed.
* **Frozen corpus:** `TreadleCore/samples/format-history/v<N>/`, one folder per version ever written, never
  re-saved (its README).

Each alias row adds a deprecation line here, in this form:

> **Deprecated 2026-10-25 (placeholder):** node kind `ExampleBranch` renamed to `Branch`, and the Branch pin
> `example-condition` renamed to `condition`; old files load unchanged and are saved with the new names. Alias
> kept forever. These two rows are the documented example: no release ever wrote either old name.

Added without a version change (2026-10-25, the editor habits): a field's `category`, a node's
`split <pin> <Type>` and the Sheet's `group` record, which an older reader keeps in place as unknown lines, and
the layout's `node` / `collapsed` lines naming a group, which an older editor may drop (layout is disposable).
