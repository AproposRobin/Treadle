---
audience: developer
title: Editor model
summary: What the editor needs from the data model and how it is built: the document model, node and pin kinds, type colouring, the vector types, the Node menu catalogue, the panels, nodes with special behaviour, Extract to Function, Validate / Build / Run, undo and saving, the debugger's internals, the original editor's layers as the fork left them, and how the editor behaves at scale.
order: 4
---

# Editor model

The editor is a fork of an earlier node editor written in Beef (Apache-2.0, named in NOTICE; "the original editor" below) and keeps its look: the dock layout, the Outline on the
left, Properties on the right, the node canvas, the Node menu, the palette. What changed underneath is the
truth: the original editor's graph is a view of Beef text; Treadle's graph **is** the document. That removed the
parser, the code writer, the round-trip machinery and the external checker, and replaced them with the
record reader/writer ([Graph-Format.md](Graph-Format.md)) and the in-process compiler
([Compiler.md](Compiler.md)). The keys are in [Keyboard.md](Keyboard.md); how the editor compares with
another node editor's habits is `UX-Audit.md` (private).

## 1. Data model the editor works on

The compiler and the editor share one library, `TreadleCore` (namespace `Treadle`):

```
Project      { file, name, kind, entry, sources, dependencies: [Project], cimports: [CImportSet], configs }
TypeDocument { file, header: TypeDecl, members: [MemberDecl], sheets: [Sheet], layout, dirty, unknownRecords }
MemberDecl   { id, kind, name, signature, modifiers, attrs, doc, category, sheets }   // field / property / function / ctor / dtor / operator / case
Sheet        { key: <id> | get:<id> | set:<id> | lambda:<node>, name, member, graph }
Node         { id, kind: NodeKind, subject, settings: [(key, tokens)], inputs: [Pin], outputs: [Pin], comment, disabled }
Pin          { name, label, kind: Flow | Value, type: TypeRef, default, optional, mode: Value|Ref|Out, role: Receiver|Arg|Result|Body|... }
Link         { from: Pin, to: Pin }
Layout       { node positions "SheetKey|NodeId" -> (x, y, w), comment boxes, knots, bubble pins, views, collapsed }
```

As built: `TypeDocument` (`TreadleCore/src/Document/TypeDocument.bf`, the former `GraphDocument`) holds the type
header, the members, their Sheets (each with a lazily built `Graph`), the layout and the unknown records of a
type file, undo / redo by snapshot and the dirty / disk-change state. `TypeDecl`, `MemberDecl`, `TypeRef`, params,
locals, project and C import records are in `TreadleCore/src/Model/`. A document is read and written only through
`IGraphCodec` (`TreadleCodec`, `TreadleCore/src/Format/`), so the shell never looks inside the file. The project's
files come from `ProjectIndex` (`TreadleCore/src/Document/ProjectIndex.bf`), a folder scan by the codec's
extension. Every service the shell asks about the language hangs off one `LanguageContext` per workspace
(`TreadleCore/src/Language/LanguageContext.bf`; section 8).

`Node` and `Pin` (`TreadleCore/src/Graph/Graph.bf`) were trimmed in the GraphModel step: the Beef-only fields
(`Text2`, `NullCond`, `Cascade`, `Parens`, the `OutForm` family, `Original`, `Qualifier`, `Alloc`, trivia) are
gone; node kinds follow Graph-Format.md 3.2 (`NodeKind`, with `BreakStruct` for the struct Break and `Unknown` for
a kind a newer file has); pins carry the format's names and a structured `TypeRef`; nodes carry their record id.

**Types on pins are structured** (`TypeRef { decl | generic param | primitive, args, array/pointer/nullable
modifiers }`), not text. **Decision:** structured, because the compiler's type table exists anyway and every pin
is typed by it. Reason: no re-parsing of type text, no heuristics for colour and shape.

## 2. Node kinds, pins and colouring

### 2.1 Node kinds as the editor draws them

| Family | Kinds | Header colour (original palette kept) | Icon |
|---|---|---|---|
| Entry / Return | `Entry`, `Return`, `ChainCtor` | purple-red | function |
| Calls | `Call` (flow), `Invoke`, `Intrinsic` | blue | call |
| Value calls | `Call` of a pure function, `Operator`, `Select`, `Cast`, `Make`, `Break`, `MakeCase`, `IsCase`, `Index`, `Math`, `Literal`, `Bind`, `Lambda`, `Swizzle`, `Shuffle` | green | function / sigma / box |
| Variables | `Get`, `Set`, `This`, `Base` | compact pill in the value's colour; Set titled "Set Name" | variable |
| Flow control | `Branch`, `Sequence`, `While`, `DoWhile`, `For`, `ForEach`, `Break`, `Continue`, `Switch`, `Scope`, `Gate`..., `ResultMatch`, `Try` | grey | branch / loop |
| Lifetime | `Construct`, `Local`, `Delete`, `Defer`, `DeferDelete` | green box (Construct), teal box (Local), blue bin (Delete), grey (Defer) | box / bin |
| Fatal | `Fatal` | red | warning |
| Unsafe | any node with pointer pins, `Scope` with `unsafe` | a hatched header stripe | lock |

Subtitles carry what the user must know: `Construct` "heap: you delete it"; `Local` "freed when this region
ends" / "freed when the function returns"; a value node consumed by N flow nodes "evaluated Nx" (the count is
the compiler's, `FrontEndServices.EvaluationCount`); `Try` "returns early on error".

### 2.2 Pins

| Pin kind | Drawn | Rules |
|---|---|---|
| Flow in / out | white arrow | An input accepts many wires; an output has one wire |
| Value in | circle (filled when wired); a widget when unwired and the type has one (checkbox, number, text, enum dropdown, type-coloured `default`) | One wire |
| Value out | circle | Many wires |
| `ref` in | circle with a ring; needs a variable | Fed by a value that is not a variable (or holding a literal) on a node in the flow: the problem strip's **Fix** (Make local variable) adds a Local of the value's type, a Set of it right before the node and a Get wired into the pin, one undo step; a value wire dropped on the pin does the same. A node not in the flow gets no Fix (`PinVariables.bf`) |
| `out` | an output pin on the right | |
| Receiver | first input of a member call/get/set; unwired reads `this` in grey; red when there is no `this` | |
| Body flow out | arrow with a bracket (owns a region) | |
| Wildcard | grey; takes the connected type and unifies the node's other `T` pins | |
| Split struct pin | one pin per field, `<pin>.<field>` | Split / Recombine Struct Pin; `split <pin> <Type>` in the file |

**Type colours**: the original editor's `Theme.FamilyColor` table is kept as is (bool red, int cyan, float green,
string magenta, char violet, object blue, struct dark blue, enum teal, interface pale green, delegate light
red, pointer steel blue, wildcard grey, flow white); collections take their element's colour and a shape
(array slots, list rows, map squares, set dots). The family comes from the structured `TypeRef` through
`ITypeSystem.Family`, which the compiler's `TreadleTypeSystem` answers from its type table; `NullTypeSystem` (no
compiler) answers with the generic name rules of `TreadleCore/src/Catalog/TypeRules.bf`.

### 2.3 Vector types

The vector primitives of [SIMD-and-Vectors.md](SIMD-and-Vectors.md) (`float4`, `double2`, `int32x4`,
`uint8x16`, `bool4`, ...) as the editor has them. The editor works from the names alone, so all of this holds
before the compiler knows the types (then every node naming one carries the compiler's message, and nothing
else changes; Follow-ups.md, "Vector types").

* **Names** (`TreadleCore/src/Model/VectorTypes.bf`, `TypeRef.bf`): the element name and the lane count, an `x`
  between them when the element ends in a digit; elements `float double int8 int16 int32 int64 uint8 uint16
  uint32 uint64 bool`, lanes 2, 3, 4, 8, 16, 32, 64, at most 64 bytes (a 3-lane vector counts 4 lanes). Such a
  token reads as a `TypeRef` of kind `Vector` (`Name` the spelling, `Element` the lane type, `Size` the lanes);
  `Vector<float,4>` (the reserved long form) reads as the same type and is written `float4`. A name with the
  shape and no such type (`int4`, `double16`, `float5`) stays a plain name; `VectorTypes.Check` gives its T1090
  text (`int4`: "int32x4 or int64x4"). The type picker lists the common ones after the primitives.
* **Pins**: family `Vector`, drawn in the Vector colour, gold (`Theme.VectorPin`, 253 200 35, the one kept from
  the original palette for vector-like structs), apart from float green, int teal and struct dark blue on the
  canvas in both themes; the shape (`PinStyle.Lanes`) is a rounded square with one inner bar per 4 lanes (one
  for 2 to 4 lanes, two for 8, four from 16) in the element's colour, framed when unwired and filled when wired.
  The tooltip names the layout: `float4 (4 x float, 16 bytes)`. Nothing converts implicitly to, from or between
  vectors (TypeRules: Make, Cast and the operators do it); a mask (`bool4`) is accepted by a Select's condition.
* **Unwired input**: one number field per lane up to 4 lanes (`x y z w` as hints; a checkbox per lane for a
  mask), one field above 4 lanes; stored as one token, `in v 0,1,0,0`, equal lanes as one splat value
  (`PinValueKind.Vector`, `PinValue.SplitLanes` / `JoinLanes`). Typed `1, 2, 3, 4` is stored `1,2,3,4`; a lane
  count other than 1 or N is refused.
* **Nodes** (pin names as the file stores them; `TreadleCore/src/Graph/VectorNodes.bf`, `NodeFactory`):

| Node | Kind and subject | Pins (in -> out) | Settings, Properties |
|---|---|---|---|
| Make float4 | `Make float4` | `x y z w` (`lane0 ... laneN-1` above 4 lanes) -> `value` | Properties: Vector Type (the lanes follow; wires on lanes that stay are kept) |
| Break float4 | `Break float4` | `value` -> `x y z w` / `lane0 ...` | the same |
| Splat float4 | `Math`, `set expr "float4(x)"` | `x` -> `result` | the Math Expression |
| Swizzle .zyx | `Swizzle` | `value` -> `result` (one letter: the element; else the vector of that many lanes) | `set lanes zyx`; Properties: Lanes as text, one dropdown per output lane, Add Lane, Remove Last Lane |
| Shuffle 0 4 1 5 | `Shuffle` | `a`, `b` -> `result` (the element x the mask's length) | `set mask 0 4 1 5` (0 to N-1 from `a`, N to 2N-1 from `b`); Properties: Mask as text, one dropdown per output lane (`a.x` ... `b.w`) |
| Get Lane | `Call Core.Vector.GetLane` | `v`, `i` -> `result` | - |
| Set Lane | `Call Core.Vector.WithLane` | `v`, `i`, `s` -> `result` | - |
| Reduce Add / Multiply / Min / Max | `Call Core.Vector.Sum` / `Product` / `MinLane` / `MaxLane` | `v` -> `result` | - |
| Any Lane / All Lanes | `Call Core.Vector.Any` / `All` (masks) | `m` -> `result` | - |
| Operators | `Operator +` ... | `a`, `b` -> `result`: with a vector on either side element-wise (a scalar splats), a comparison gives the mask (`bool4`) | as any Operator |

  A Swizzle's, a Shuffle's and an Operator's result type follows the wired vector and the setting
  (`VectorNodes.Sync`, run when a wire comes or goes and after a file is read). The editor's checks
  (`GraphValidator` -> `VectorNodes.Check`) name a letter or lane beyond the input (T2301, "'w' is lane 3, the
  input has 3 lanes (xyz)"), `&&` / `||` on vectors (T2300) and a scalar wired into a Swizzle or Shuffle.
  Split / Recombine Pin works on vector pins as on structs, through the Make / Break rows (`split value float4`).
* **Node menu**: dragged from a vector output, the group **Vector | float4** comes first (Break, Swizzle,
  Shuffle, Get Lane, Set Lane, the reductions; Any / All for a mask), then Math and Comparison (the operators take
  vectors as they are); dragged into a vector input, Make and Splat first. These rows are made for the pin's
  type (`VectorCatalog.Typed`). Without a pin the catalogue lists Swizzle, Shuffle and the `Core.Vector` calls
  under **Math | Vector**, Make / Break of every vector type (the uncommon ones as advanced rows) and Splat of
  the common ones; from a scalar pin only the common vectors of exactly that element (Make / Splat float4 from a
  float). All of these are stand-ins (`NodeSpec.StandIn`, `VectorCatalog.AddStandIns`): a row of the
  catalogue source with the same key (the call name, or the kind word and subject) replaces its stand-in; the compiler's
  `VectorCatalogSource` replaces every `Core.Vector` call row, so Make / Break / Splat, Swizzle and Shuffle stay.
* **Math Expression**: the field reads `v.zyx`, `v.x` and `float4(a, b, c, d)` as paths and calls (the inputs
  are `v`, `a`, `b`, `c`); what they mean is the compiler's, and the node shows its message until it binds them.

## 3. The Node menu catalogue

Built into one `NodeCatalog` (the original editor's search and ranking kept as `TreadleCore/src/Catalog/NodeCatalog.bf`:
prefix 100, word start 60, acronym 40, substring 30, fuzzy; context relevance bonus; 300 results cap). The
entries reach it through `INodeCatalogSource`, which the compiler's `TreadleCatalogSource`
(`TreadleCompiler/src/Services.bf`) implements; the flow nodes are the menu's own built-ins:

| Source | Entries | Category |
|---|---|---|
| **Built-in nodes** | Flow control, Lifetime, Operators, Cast, Make/Break of any struct, Select, Math Expression, This/Base, Return, Literal, Fatal, Try, Result: match | `Flow Control`, `Lifetime`, `Math \| Operators`, `Utilities` |
| **The project's types** | Every visible member: functions as Call (flow or value), fields and properties as Get / Set (a field with a `category` under `Variables \| <Category>`), constructors as Construct / Local, enum cases, operators, extension members under the extended type | `<Namespace> \| <Type>` |
| **Core library** | Same rules over `TreadleCore/core/*.treadle` ([Core-Library.md](Core-Library.md)); its `internal` members and its `crt` C set are not offered | `Core \| List` (shown in the menu's Core group), String / StringView under Strings, Math under Math |
| **C import sets** | Each imported function (flow unless `pure`), struct Make/Break, enum cases, constants | the set's `category`, else `C \| <set>` |
| **Vector stand-ins** (`VectorCatalog`) | Swizzle, Shuffle, Make / Break / Splat of vector types; Get / Set Lane and the reductions until the source lists its own (the compiler's `VectorCatalogSource` does; section 2.3) | `Math \| Vector` |

Context sensitivity (dragging off a pin): only entries that can be wired to the pin are offered (`EntriesFor`
filters by pin type), the context line names the pin; from a generic struct's pin the menu lists its Break /
Make (`Break Pair<int,float>`). Favorites, hotkeys and recents as in the original editor (`settings.json`,
`node_menu.txt`). Overloads are grouped by the editor (`NodeMenu.OverloadsOf`), since `ITypeSystem` does not
list them (Follow-ups.md). A search that names parameter types (`writeline int`) lists the overload taking
exactly those types first and folds the function's other overloads into one dim row under it ("7 more
overloads of WriteLine"); picking that row lists them, Enter never takes it (`NodeMenu.CollapseOverloads`).

## 4. Panels

| Panel | Content as built | Not built yet |
|---|---|---|
| **Outline** (`Outline.bf`) | Type Settings row, **FUNCTIONS** (functions, constructors, destructor, properties; **+** adds Function / Property / Constructor / Destructor), **VARIABLES** (fields with type pill, Category headers; **+**), **CASES** for enums (**+**), **LOCAL VARIABLES** of the front Sheet (**+**, **L** on the Sheet). Drag a variable onto the canvas: Get (Ctrl), Set (Alt), plain asks; onto a pin: wired. | **+** for Operator and Override; Problems row |
| **Type Settings** (`TypeSettings.bf`, Properties' type page) | Name, Kind, Namespace, Access, Abstract / Sealed / Static, Underlying Type (enum), Doc; **Extension** (extension types): Extends, a type field with a picker of the class, struct and enum types of the project, its dependencies, the core library and the C imports (a generic one with its parameters, `Core.List<T>`); **Signature** (delegate types): Returns, one Input row per parameter type (an X removes it), Add Input (a signature the rows cannot show is one text row); **Uses**: one namespace per row with a picker of the known namespaces and an X, Add Namespace; Base Type, Implements / Extends (interfaces), Generic Parameters with constraints, Attributes. Each edit is one undo step. A member's page: Name, Type, Default Value, Value (case), Inheritance, Access, Pure / Unsafe, Runs First (constructor), Inputs / Outputs with Move Up / Down. | Implement Missing Members, Add Override (Review-2026-10-26.md) |
| **Properties: node** (`PropertiesPanel.bf`, `LambdaProperties.bf`) | Subject, Type, the kind's settings (Constructor, Lifetime / Until Return on Local, Checked and Kind on Cast, State Field on stateful nodes, Allocation / Signature / Captures on a Lambda and Bind, Operator on a compound Set), Inputs (one widget per unwired input), Outputs, Comment, Disabled, problems; comment boxes, multi-select, the Sheet page. | quick fixes other than the ref strip's |
| **Project Browser** (`ProjectBrowser.bf`) | Folders and `.treadle` tiles, `.cimport` and `.tproj` tiles, tree + tiles + Project Drawer (Ctrl+Space), New Type..., New Project, rename, delete to the Recycle Bin; the project page in Properties (below). | |
| **Project page** (`ProjectSettings.bf`, `ImportHeader.bf`; the project tile selected) | **Project**: Name, Kind (console / windowed / library), Entry Type, Output, Version, Namespace, File. **Configs**: Active Config (what Build and Run use). One section per config: Make Active, Optimize (`optimize` 0 / 1 / 2 / 3 / size), Checks (`checks` on / off), Defines (one `define NAME[=value]` per row, an X removes it, a field adds them), Debug Format (`debugFormat` dwarf / codeview / both), and any other key as a text row; a row shows the file's value or the config name's default (Release: 2, off; any other: 0, on), and a default with no line writes nothing. **C Imports**: each `cimport` file (Open in a text editor, Remove: the file stays), each set in it with its headers and its `only` names (one row each with an X, a field adds names), Add Set (a `.cimport` file is listed; a header gets a set of its own), Import Again. **Files**: Source, Depends. An edit writes the project file (an `only` edit the `.cimport` file). | Add / remove a config; a set's headers, includes and libs (Open edits the file) |
| **Problems** | Compiler diagnostics (From: Validate / Build / Run), click opens the Sheet on the node and selects the pin; the node draws a problem strip under its header. | |
| **Output Log** | Editor messages, compiler and clang/lld output, the program's console output. | |
| **Find in Sheets** (`FindPanel.bf`) | Ctrl+Shift+F over the project's Sheets and nodes; Ctrl+F in one Sheet. | |
| **Locals / Call Stack / Debug Output** (`Debugger.bf`) | From lldb-dap (section 10). | |
| **Graph Source** | - | **Decision:** a read-only view of the type file's records for the front Sheet, no live text editing (the format is for diffs, not authoring). Not built. |

## 5. Nodes with special editor behaviour

* **Entry**: one per Sheet, not deletable; its output pins follow the function's Inputs rows (reordered with
  Move Up / Down, the Calls in the open documents follow).
* **ChainCtor** (Base Constructor / This Constructor): part of the constructor's declaration (Properties:
  *Runs First*). The Node menu places it in a constructor's Sheet (one row per constructor it can run) and sets
  `chain base|this`; deleting the node clears `chain` in the same undo step.
* **Construct / Local**: the Node menu offers "Construct `<Type>`" and "Local `<Type>`" per class/struct; the node
  menu's Change to Construct / Local switches between them (same node id, wires stay).
* **Value node fan-out**: a value node consumed by more than one flow node says "evaluated Nx"; the pin menu's
  **Make local variable** stores a value once.
* **Switch**: **Add pin +** adds the next enum member or number, **Remove Case** on a case pin.
* **Sequence / Multi Gate**: **Add pin +**, **Remove Pin**.
* **Lambda**: double-click opens its nested Sheet as a tab; the breadcrumbs show `Type > Function > Lambda <id>`.
* **C variadic Call**: **+ arg** / **- arg** add and remove `va<n>` pins.
* **Node groups**: Collapse Nodes (Ctrl+G) folds a selection into a group node (`group` record; folding is layout).

Planned and not built (from the first design): an Add Delete quick action on a Construct, a "Make StringView"
first entry from a `char8*` output, Wrap in Unsafe, a region highlight on hovering a Local, and a refused wire from
a Local's `object` out of its region at drop time (the compiler reports it).

## 6. Extract to Function and local variables in the format

**Extract to Function** (node menu, Ctrl+Shift+E; `ExtractFunction.bf`):

1. The selected nodes must form one flow run (one incoming flow wire, at most one outgoing) or be all value
   nodes (the new function is then Pure).
2. Value wires entering the selection become inputs of the new function (named after the source pin, typed
   from the wire); wires leaving it become the return value (one) or further outputs (`out`). A Get of a local or
   an input of this function stays outside and feeds the Call; a Set of one is refused.
3. A new `function <newid> <Name>` record is written right after the member the selection came from, with the
   selected `node` and `wire` lines moved under it (ids are unique per file, so they move unchanged); an Entry
   and a Return are added and wired; its page opens with the Name in edit (no dialog).
4. In the original Sheet a `Call this.<Name>(...)` node (a fresh id) takes the selection's place and the
   boundary wires are re-pointed to it. Layout: the moved nodes keep their positions; the Call sits at the
   selection's centre. One undo step.

The reverse, **Expand Function** (inline a Call of an own non-virtual function), is not built.

**Local variables** are `local <name> <Type>` records under the function ([Graph-Format.md 3.1](Graph-Format.md#31-records));
Get / Set nodes reference them as `local:<name>`. Renaming a local rewrites those subjects in the same
file (one undo step). A local's `owner owned` makes the compiler delete it at function exit.

## 7. Validate, Build, Run in the editor

| Command | Does | Shows |
|---|---|---|
| **Validate** (Shift+F7, and after each edit for the edited Sheets) | Compiler Load..Check on the in-memory documents (incremental, Compiler.md 9); no files written | Node problem strips, Problems rows (From: Validate), status bar |
| **Build** (F7; Ctrl+F7 Force Build) | Saves, runs the full pipeline for stale units, links | Output Log streams clang/lld; Problems rows (From: Build) |
| **Run** (Ctrl+F5) / **Start Debugging** (F5) | Builds when stale, then runs plain or under lldb-dap (Debug) | Debug Output, Locals, Call Stack; a fatal error stops on the node |

Because Validate is the same compiler, there is no "Level 1 / Level 2" split and no resident helper process.
The three commands go through `IToolchain` (`TreadleCore/src/Language/Toolchain.bf`): the editor installs the back
end's `BackendToolchain`, whose Validate runs the generic `GraphValidator` and then `ILanguageRules.Check` (the
compiler's `TreadleRules`), and whose Build / Run lower through `FrontEndProgramSource` (the front end). Run under
the debugger goes through `DebugSession` and its `IDebugAdapter` (section 10).

## 8. The original editor's layers: kept, changed, replaced

This section was the plan for the fork; the fork is done and `FORK-NOTES.md` (the fork log, kept with the private repository) is the record of
what happened, folder by folder, with the seams at `file:line`. In short, as of 2026-10-25:

| Original editor | Treadle |
|---|---|
| `Syntax/*`, `GraphBuilder`, `CodeGen`, `CallOverloads`, `CtorChains`, `ConstructorChoices`, `MathExpr`, `SymbolStore` and the Beef symbol catalogue, `SourceDocument` and every Beef text edit, `BeefToolchain`, `BuildRunner`, `ResidentChecker`, `DebugEngine` (IDEHelper64.dll), `SourcePanel`, `BeefCheck`, the meta, check and test projects | **Removed**; overloads, constructors and Math expressions come from the compiler (`ITypeSystem`, `ILanguageRules.CheckExpression`) |
| `Graph/Graph.bf`, `NodeFactory`, `FlowMacros`, `FlowTypes`, `Layout`, `PinValue`, `GraphValidator` (generic checks only) | **Kept**, trimmed to the GraphModel of section 1 |
| `Catalog/NodeCatalog`, `NodeHotkeys`, `MergedCategories`, `TypeRules` | **Kept**; entries from `INodeCatalogSource` |
| `Document/GraphDocument` | **Replaced** by `TypeDocument` |
| `Document/FileSafety`, `RecentProjects`, `Diagnostics`, `CommandLine`, `LayoutExtras`, crash and trash helpers, `Update/*` | **Kept** (the updater's repository and key emptied, [Releasing.md](Releasing.md)) |
| `Language/LanguageContext` | **Rewritten** as the one facade per workspace: `Types` (`ITypeSystem`), `Catalog` (`INodeCatalogSource`), `Codec` (`IGraphCodec`), `Rules` (`ILanguageRules`), `Index` (`ProjectIndex`), `Toolchain` (`IToolchain`); null services by default (`Language/Seams.bf`), the compiler's installed by the editor |
| `Debug/DebugSession` | **Rewritten** over `IDebugAdapter`; the engine is `TreadleDebug` (section 10) |
| The editor's shell, canvas, panels, Node menu, Prefs, Theme, start page, recovery, updates, docs panel | **Kept**, Beef strings neutralised; `ProjectBrowser`, `PropertiesPanel`, `FindPanel`, `Debugger`, `PinVariables`, `TypeSettings`, `ProjectSettings`, `SelfTest*` **rewritten** over the new model |
| `Native/` (the host, `treadlehost`: SDL2 + OpenGL + Dear ImGui) | **Kept**, rebuilt from source as `treadlehost.dll` / `libtreadlehost.so` (FORK-NOTES.md, "Native"); its own exports carry the `th_` prefix |

**Layers.** The proposal's five layers (Graph, Language, backend, Workbench, Shell) are these projects:
**`TreadleCore`** (the graph model, documents, format, catalog, debug session, updater, the language seams),
**`TreadleCompiler`** (the front end), **`TreadleBackend`** (Sheet IR, LLVM IR, the driver), **`TreadleCImport`**,
**`TreadleDebug`** (lldb-dap), **`TreadleEditor`** (the workbench and the ImGui shell in one project, as in
the original editor) and **`Native`** (the host). There is one language, so there is no `ILanguage` registry; the shell
talks to the language only through the seams on `LanguageContext`. Splitting Workbench from Shell for a later
renderer is still worthwhile but not scheduled.

**Quiet window.** Self-test runs (`TREADLE_SELFTEST`) and `--build-run`, `--format` and `--import-c` open a
quiet window, so a test or capture run never appears on the screen or takes the focus from whoever is using the
computer. `Desktop.SetQuietWindow` (`TreadleEditor/src/Desktop.bf`) decides it once, just before `th_init` in
`Program.bf`, and passes it to the host with `th_set_window_quiet`: `TREADLE_WINDOW_VISIBLE=1` gives a normal
window (for a person watching), else `TREADLE_WINDOW_HIDDEN=1` or `0` decides, else the run kind does. On
Windows the window is made off-screen beyond the right edge of the desktop, without a taskbar button, shown
without activation and never raised (`Desktop.BringToFront` and `th_raise_window` do nothing); on Linux the
host uses SDL's offscreen video driver, so there is no window at all (FORK-NOTES.md, "Native"). The editor
renders every frame as usual, so pixel passes work on a quiet window: `TREADLE_CAPTURE_DIR` gives scripts the
host's framebuffer capture (a name written to `capture.request` there comes back as `<name>.bmp`).

## 9. Undo, saving, safety

* Every model edit is an undo step by snapshot (the original editor's approach kept): `TypeDocument` copies the built
  graphs, the header and members, and the layout per step; files are small. Folding a node group is layout and
  not an undo step.
* Save writes the type file and, when layout changed, the layout file, both through the codec, with an atomic
  write and `.bak` (`FileSafety.AtomicWrite`). A document with unresolved diagnostics **saves anyway** (unlike
  the original editor, which refused because its text would have been wrong): the graph is the truth and an error is a
  state of the program, not of the file. Build refuses while errors exist.
* External change detection, read-only mode, recovery journal and crash reports stay as they were.

### Fatal errors and crash reports

The Beef runtime reports a fatal error (`Runtime.FatalError`, a failed assert, an index out of range, an access
violation, a Debug check such as a deleted object used) and, in Debug builds, the leak check at exit with its
own "Fatal Error!" box; the editor never lets it show. `CrashHandler` (`TreadleEditor/src/CrashHandler.bf`)
hooks three places: a runtime error handler (`Runtime.AddErrorHandler`, the message with its file and line), an
unhandled-exception filter in front of the runtime's, and a crash-info hook in the runtime's crash catcher
(`Runtime.AddCrashInfoFunc`, which also receives the leak report through `gBfDebugMessageData`). Each writes
the report first (`treadle-crash-<date>-<time>.log` with the stack named through dbghelp, a minidump, the
recovery journal flushed, a `[FATAL]` line in the session log) and then ends the process with exit code 3. A
run with no user at the window (`TREADLE_SELFTEST`, `--build-run`, `--format`, `--import-c`, `--version`,
`--help`; `CrashHandler.InstallHeadless`, first thing in `Program.Main`) also prints the report to stderr,
sets the runtime's report kind to print-only, and starts a watchdog that writes `watchdog: still running
<phase>` and exits 5 after `TREADLE_WATCHDOG` seconds (default 900). The interactive editor shows its own
message box naming the report file, after the file is written. A leak report goes to
`treadle-leak-<date>-<time>.log` and `[LEAK]` lines in the session log, each leaked object with its allocation
site (read from the object's Debug header), exit code 4, no box in either mode: only Debug builds have the
leak check, and users only get Release builds. Under a debugger the runtime breaks into it as before.
`TREADLE_DEBUG_FATAL=fatal|assert|null|leak|hang` triggers each path in a headless run; the `fatal` self test
(`SelfTestFatal.bf`) runs each in a child editor and checks its exit code and log.

## 10. The debugger (internals)

The user side is [Debugging.md](Debugging.md). The debug information it relies on (listing files, node maps,
DWARF / CodeView) is [Compiler.md 7](Compiler.md#7-debug-info-and-node-mapping).

### How it is built

| Piece | Where | What |
|---|---|---|
| `DebugSession` | `TreadleCore/src/Debug/DebugSession.bf` | The state machine the panels read: state, breakpoints on (file, Sheet, node), frames, the selected frame's variables, output, Evaluate, members on demand. Updated once per frame from the adapter's events. |
| `IDebugAdapter` | same file | The engine seam. Requests are queued; answers come back through `Poll`; frames and variables are what the adapter read at the stop, so the UI thread never waits on the debugger. `NullDebugAdapter` refuses. |
| `DebugProgram` | `TreadleCore/src/Debug/DebugProgram.bf` | What a build gives the debugger: every type file of the project read through the codec (unit name = the type's full name <-> file, Sheets, which nodes are flow nodes, the flow node each value node is evaluated for, the names of each Sheet's variables) and every `<Unit>.nodemap` of `build/Debug`. Made on the UI thread at launch and not changed afterwards. |
| `LldbDapAdapter` | `TreadleDebug/src/LldbDapAdapter.bf` | `IDebugAdapter` over lldb-dap: the protocol on a worker thread (launch, or attach by process id), the node mapping below. |
| Summaries | `TreadleDebug/src/Summaries.bf` | The value text of each type and the children the adapter makes for Lists, Dictionaries and arrays ("Variables" below). |
| `ProcessList` | `TreadleDebug/src/ProcessList.bf` | The running processes whose executable is in a folder (Attach to Process). |
| `DapConnection` | `TreadleDebug/src/DapConnection.bf` | lldb-dap as a child process in a job object (it and the program end with the editor): `Content-Length` framed JSON written to its stdin, read from its stdout on a thread (`Treadle.Update.UpdateJson` parses). |
| The editor | `TreadleEditor/src/Debugger.bf` | F5 (`StartDebugging` -> `StartBuild("Debug")` -> `OnDebugBuildFinished` -> `LaunchDebugger`), keys, persistence, the stop's navigation, the canvas overlay, the three panels. |

**Why lldb-dap.** llvm-mingw 23.1.3 ships `lldb-dap.exe` next to `lldb.exe` and it works on this machine
(the `C:\Program Files\LLVM` lldb and lldb-dap do not start, [Toolchain.md](Toolchain.md)), so nothing is
installed. The Debug Adapter Protocol gives structured stops, stacks, variables with types and children,
memory reads and evaluation, so nothing parses lldb's console text; and the program's stdout and stderr
arrive as `output` events (lldb-dap runs the program on a pseudo console, so output is line-buffered and in
order). It is started with `--no-lldbinit` (this machine's `~\.lldbinit` loads a script that fails).
`TREADLE_LLDB_DAP` names another lldb-dap; otherwise it is `bin\lldb-dap.exe` of the llvm-mingw root
(`TREADLE_LLVM`, else `tools\llvm-mingw` of the repository, else
`TREADLE_DEV_LLVM`). `TREADLE_DEBUG_TRACE=<file>` writes each session's protocol transcript there.

### The node mapping

* **Breakpoint** on node `b7` of Sheet `m0001` in `Program.treadle`: the file's unit is `Zoo.Program`, the
  node map gives line 14, so lldb-dap gets a source breakpoint on `build\Debug\Zoo.Program.lst` line 14. A
  node with no line in the build (edited since, or lowered to nothing) is skipped with a line in Debug
  Output. Breakpoints set while running are sent at once.
* **Stop**: a frame whose source is `<Unit>.lst` maps back through the node map to (unit, Sheet, node); the
  unit's type file makes it a project frame. Frames in the runtime (`treadle_rt.c`), the C library, the
  core library's units (`Core.Console.lst`, no type file in the project) and the system are not.
* **Value nodes** have listing lines of their own, but their code runs for the flow node that reads them
  (Compiler.md 4, Rule 1-2). A stop on a value node's line is shown on that flow node when it is the only
  flow node reading the value (through other value nodes too): the program is about to run it, its inputs
  being evaluated. So a stop "on b9" may be before b9's Legs() input was called, and Step Into from there
  goes into Legs.
* **Steps** are line steps repeated until the step is done: Step Over (`next`) and Step Into (`stepIn`)
  continue while the top frame is on the same node at the same depth, or on a value node read by several
  flow nodes; a frame outside the project is left with `stepOut`; when no project frame is left (Main
  returned) the program runs on to the end. Step Out is `stepOut`, then line steps to a flow node. 400 line
  steps at most per step.
* **Call stack**: frame names are lldb's (`Zoo::Program::Main()`), shown by the Sheet's name
  (`Zoo.Program.Main`), node id and title.
* **Variables** keep the debug info's names (Compiler.md 7): `this`, the parameters, `<node>.<pin>` for a
  flow node's output slot, and the Sheet's own name for each variable (`pet`): the slot record carries the
  name (`slot s0 Zoo.Animal variable "pet" local`) and the back end gives the DWARF variable that name. A
  parameter a Set writes is shown once, by its variable. lldb shows Treadle's type names (the back end
  describes the basic types as typedefs: `int`, `int64`, `char8`, ...), taken as they come, and a reference
  (a pointer to a class, String, a core collection, an array or a delegate) is shown by the referenced type
  itself (`Zoo.Animal`, `Core.List<Core.String>`). Values are summarised by the adapter
  (`TreadleDebug/src/Summaries.bf`), the same text in Locals, Evaluate and the pin bubbles (a bubble drops an
  object's address and cuts the text at 40 characters):

  | Type | Shows | Expands to |
  |---|---|---|
  | basic types | lldb's value (`5`, `true`, `'A'`, `2.25`) | |
  | simple enum | the case name (`Green`; the DWARF type is an enumeration) | |
  | `String` | its text, quoted (`"13 words, 10 different"`, the first 200 bytes) | its fields |
  | `StringView` | its text, quoted | `Ptr`, `Length` |
  | `List<T>` | `["the", "fox", ...] (10)`: the first 8 elements and the count | the elements `[0]`, `[1]`, ... (up to 500) |
  | `Dictionary<K,V>` | `{"the": 3, "lazy": 1, ...} (10)`: the first 8 entries in slot order and the count | one row per entry, `["the"]` = `3` |
  | `T[]` | `[10, 20, 30] (3)` | the elements |
  | `Option`, `Result`, any payload enum | `Some(5)`, `None`, `Ok(x)`, `Err(7)`, `Rect(4, 6)` | `tag`, `payload` (a union of the cases) |
  | `T?` | the value, or `null` | `hasValue`, `value` |
  | tuple | `(3, true)` | `item0`, `item1`, ... |
  | delegate | the function bound: `Zoo.Program.Twice`, `Lambda c2` (lldb's symbol of `fn`) | `vtable`, `target`, `fn` |
  | object | its own type and address, read through its vtable -> TypeInfo -> name (`Zoo.Dog (0x1A4ED746D60)`, cached per vtable); `null`; a deleted object `<deleted object> (0x..)`; a Local not constructed yet says so | its fields |
  | struct | its first members, each summarised (`{Value = 11, Ok = true}`) | its fields |

  Elements of the containers are read from the program's memory (DAP `readMemory`) with the layouts of
  Compiler.md 5: `String` = `{ vtable, mPtr, mLength, mCapacity, mInline }` (the text read through `mPtr`, which
  points at `mInline` for a short String), `List<T>` = `{ vtable, mItems: T[], mCount }`, `Dictionary<K,V>` = `{ vtable, mKeys, mValues,
  mStates, mCount, mUsed, mCapacity }`, an array = `{ vtable, length, elements at byte 16 }`. An element of a
  basic type, `StringView` or a reference is formatted from those bytes (a String element by its text, a
  nested List or Dictionary by its count past the first level); an element of a struct, enum, tuple or nullable
  type is read through lldb by its variable path (`counts->mValues->elements[3]`), which a variable has and a
  pin does not (lldb reads `a3.object` as the variable `a3`), so a pin's such elements show `{...}`.
* **Pin values on the canvas** come from the selected frame's variables: an output pin of a flow node is
  its `<node>.<pin>` slot; an input pin takes the value of the pin wired to it; a Get of a local or
  parameter is that variable; an unwired Receiver is `this`. Other value nodes keep no value ("shown only by
  running code").

### Processes

Nothing the editor starts outlives it (`TreadleCore/src/Language/ProcessJob.bf`):

| | Windows | Linux |
|---|---|---|
| Build tools (clang, lld) | a job object with kill-on-close per process: Cancel ends the tree, a killed editor closes the job | Cancel kills each process and its descendants (Beef's tree kill); they end within a build step anyway |
| Run (Ctrl+F5, `ProgramRun`) | a job object: Stop, deleting the ProgramRun (Close Project, exit) and a killed editor end the program and what it started | its own process group (started through `setsid`, which execs in place, so the process id is the program's): Stop and deleting the ProgramRun send SIGKILL to the group; a killed editor: the runtime's `prctl(PR_SET_PDEATHSIG, SIGKILL)` in `rt_start`, made only when the program's parent is the process named by `TREADLE_RUN_PARENT` (the editor sets it in its own environment at the first such start), so a program started from a shell or under lldb is not affected |
| Debugging (lldb-dap) | a job object (`DapConnection`): the program lldb-dap launches is in the same job | its own process group (`setsid`) plus `setpriv --pdeathsig KILL`: Stop Debugging and the session's end kill the group, a killed editor kills lldb-dap, whose debuggee (traced by lldb-server) dies with it |

Deleting a `RunningProcess` whose child still runs kills it first (job or group), then joins its pipe
readers. On Linux the parent-death signal follows the *thread* that started the child; the editor starts
programs and lldb-dap on its main thread. The `backend` self test proves it on both systems with the
`attachwait` fixture held by `attach.hold`: started through ProgramRun, its handle deleted, the process is
gone within 1 s (Windows and Linux: 0 ms); on Linux also started from a thread that then ends, gone within
1 s through the parent-death signal.

### Self tests

`TREADLE_SELFTEST=debug` (`TreadleEditor/src/SelfTestDebug.bf`) works on a copy of `TreadleCore/samples/m1`
under `%TEMP%\treadle-debug-<n>` opened as the project (on Windows its Debug config sets `debugFormat both`,
and the test checks the PDB and `debug-format.txt` afterwards): F9 on b7 (Call Speak) and its settings entry, F5,
the stop on b7 with `pet` = `Zoo.Dog`, the receiver pin's value, Evaluate, three Step Overs (b9, b3, b5), the
second stop with `pet` = `Zoo.Bird`, Step Into Bird's Speak (its Sheet opens) and Step Out, Step Into the
Legs call b9 reads with `this`, Step Out, F9 off, Continue to exit code 0 with the program's output in
Debug Output; then a copy with a second Delete of the Box through a local: the stop on that Delete node
(e1) with the runtime's double free message, exit code 3; then a copy of `TreadleCore/samples/m3-core`
stopped on d3 (the WriteLine of the first line, after the counting): the Dictionary<String,int> `counts` as
`{"brown": 1, ..., "the": 3, ...} (10)`, the List<String> `a3.object` as `["the", "quick", ...] (13)`, the
sorted `b7.object` as `["the", "fox", ...] (10)`, the String `d1.object` and the bubble on d3's input as
`"13 words, 10 different"`, and expanded, `counts` with its 10 entries (`["the"]` = `3`) and `b7.object`
with its 10 elements. The `backend` self test drives the adapter on its own: on the `debugtypes` fixture's
locals (`Some(5)`, `None`, `Err(7)`, `Green`, `(3, true)`, `9`, `null`, `[10, 20, 30] (3)`,
`Dbg.Program.Twice`, `{Value = 11, Ok = true}`, `Gen.Box<double> (0x..)`, `Rect(4, 6)`) and attached to the
`attachwait` fixture's program (found among the running programs of its folder, stopped on a3, run to exit
0), and on Windows the CodeView builds: `vdispatch` with `both` and `codeview` (the PDB's line table has node
a4's listing line, `llvm-pdbutil dump -l`; lldb breaks there through the DWARF, and through the PDB after
`target symbols add`) and the adapter launching a `codeview` build of `attachwait` and stopping on a3.
`debugstop` (captures) starts debugging the open project with a breakpoint on
`TREADLE_DEBUG_BREAK=<type file>,<Sheet name>,<node id>` and stays on the stop.

## 11. Scale

How the editor behaves on a large project, how that is measured and what the measurement found. The numbers are
in [Performance.md, "Editor"](Performance.md#editor).

**The project.** `ScaleProject` (`TreadleEditor/src/ScaleProject.bf`) writes a synthetic project from a fixed
seed: static classes of int arithmetic Sheets (Operator, Get / Set of a local, Calls of other types' functions,
always to a function earlier in the plan, so the program has no call cycles and runs), generic classes used from
them (Construct, Call, Delete), extensions of `Core.List<T>`, delegate types with event-bearing classes (Bind,
Add, Invoke), Local Lambdas with their `lambda:` Sheets, one type with one big Sheet (`Huge/BigSheet.treadle`), one
large type file (`Huge/Huge.treadle`, about 2 MB with node comments and docs) and a Program whose Main calls into
them. Every Sheet has a layout. The measured size (`ScaleProject.Full`): 200 types, 2,001 Sheets, 60,001 nodes,
79,566 wires, a big Sheet of 600 nodes and 1,000 wires; it validates and builds without a message and runs.
`ScaleProject.Reduced` (the self test): 20 types, 200 Sheets, 6,000 nodes, a big Sheet of 300 nodes.

**The self tests** (`TreadleEditor/src/SelfTestScale.bf`):

* `scale` writes the reduced project under `%TEMP%\treadle-scale-<stamp>`, measures it (one run each) and checks
  generous bounds so that a regression shows without flakiness: open <= 5 s, a frame on the big Sheet <= 50 ms at
  1:1 and zoomed out, the incremental Validate <= 50 ms, the Node menu search <= 100 ms, and memory growth
  <= 50 MB over an 800-step edit loop after its 400-step warm-up (the undo history is full by then, so growth
  after it would be a leak). The folder is deleted at the end; the minimap preference is put back.
* `scalegen` writes a project of `TREADLE_SCALE_SIZE` (`full`, the default, or `reduced`) into
  `TREADLE_SCALE_OUT`; `Treadle.exe --format <folder>` then puts it in canonical form.
* `scalemeasure` measures the project in `TREADLE_SCALE_DIR`, each step three times where it can be repeated,
  plus Build (Force Build, Debug) and an edit loop of `TREADLE_SCALE_SOAK` steps (default 6,000). It writes
  `[SCALE]` lines and a Markdown table to the session log.

**Method.** Release editor, `TREADLE_WINDOW=1920x1080`, Dark theme, `TREADLE_NO_IDLE=1` (continuous frames),
`TREADLE_HOME` set to a folder of its own (the settings stay untouched); the window was moved off screen and never
activated while it ran. A frame time is the CPU time of the editor's frame: from the start of `Frame()` (`Shell.
TrackFrameTime` stamps `FrameBeganAt`) to the self-test tick near its end, every panel built and drawn into
ImGui's lists; the GPU's work and the wait for the display (vsync) are not in it. Frame samples are 60 frames
(30 for the marquee and the drag) after a settle frame; the median is reported, the log also gives p95 and the
worst. The marquee and the drag go through the canvas's own input path: mouse events into ImGui's queue
(`ImGuiIO_AddMousePosEvent` / `AddMouseButtonEvent`, not the desktop's) and the held pointer
(`GraphPanel.SelfTestMouse`). Validate is timed as the graph checks of the edited Sheet (`TypeDocument.Commit`)
and the front end bringing its compilation up to date (`FrontEndServices.Current`); "full" turns `Incremental`
off for one run. The edit loop cycles add a Branch, wire it, move it, undo, redo, change a literal, delete it, and
one of Validate, Find in Sheets or the Node menu, one step a frame, on the big Sheet with every type file open.
Memory is the process's private bytes.

**What was fixed.**

* *Project types rescan* (`ProjectTypes.bf`, `RefreshProjectTypes`): the frame loop rescanned the project's types
  twice a second and the Node menu on every open, copying every type's members each time: 18-21 ms at 200 types,
  a visible hitch every 30 frames and most of the Node menu's open time. It now skips the rescan while the folder
  index and the open documents (address, version, path) are as they were.
* *Declaration generation* (`TreadleCompiler/src/Services.bf`: `mDeclGeneration`, `mSheetsOnly`, read by
  `TreadleTypeSystem` and `TreadleCatalogSource`): an incremental Validate that only binds edited Sheets again bumped
  the one generation the catalogue and the type-name cache followed, so the next frame rebuilt the whole catalogue
  (about 10 ms at 200 types, through `IsVariadicCall` on a selected Call) and resolved every type name again. They
  now follow a generation that moves only when declarations can have changed.

**What is left** (follow-ups, with their numbers): undo on the big Sheet costs about 55 ms in the next frame
because restoring the snapshot makes the incremental Validate declare the type again (about 35 ms in the front
end, 10 ms of catalogue rebuild); an undo snapshot copies every built graph of the document (about 1.4 MB per
step on the 600-node Sheet; the 200-step history is most of the 450 MB the edit loop adds); the incremental
Validate grows with the open documents (4 ms with the big Sheet's type open, 12 ms with all 200), its floor being
the rebind of the 600-node Sheet; the once-a-second disk check stats every open file (5 ms with 200 open); the
first view of a Sheet waits for the first full compile (about 320 ms).
