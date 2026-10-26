---
audience: developer
title: Compiler
summary: The pipeline from graph files to a native executable: load, declare, bind, check, typed IR, LLVM IR text, clang and lld; mangling, runtime ABI, the C runtime, the core library, C header import, incremental builds, and the error model.
order: 3
---

# Compiler

The compiler is two Beef libraries inside the editor: the front end `TreadleCompiler` (Load to Lower) and the
back end `TreadleBackend` (the Sheet IR, LLVM IR text, the driver). It reads `.treadle` files and writes LLVM IR
text, then drives `clang` and `lld` (llvm-mingw on Windows, the distribution's LLVM 22 on Linux,
[Linux-Development.md](Linux-Development.md)). There is no separate command-line compiler: the command line is the editor's
(`Treadle.exe --build-run <project> [--config <name>] [-- <program arguments>]`, `--import-c`), with no
window. The commands, the pinned toolchain and the measured timings are in [Toolchain.md](Toolchain.md);
`scripts/llbuild.ps1` was the prototype of the driver. There is no interpreter and no second language in
between: the typed IR is an in-memory structure.

```
 .treadle files ──> Load ──> Declare ──> Bind ──> Check ──> Lower ──> Emit ──> clang -c ──> lld ──> exe/dll
  + .tproj     graph    type table  names    types,    typed IR  .ll per   .o per unit   + runtime.a
  + .cimport      model    (headers)   overloads regions,  (SSA,     unit                   + core .o
                                       generics  purity    blocks)
                 └────────── Validate stops here (Check) ──────────┘
```

## 1. Stages

| Stage | Input -> output | What it does | Errors anchored to |
|---|---|---|---|
| **Load** | files -> `Graph` model (the editor's own model, shared library) | Parses the record format, keeps unknown records, assigns pin tables from node kinds | file, line |
| **Declare** | all type headers and member headers -> `TypeTable` | Creates `TypeDecl`, `MemberDecl` for every type in the project and its dependencies, imported C declarations included; no Sheets read yet | type, member |
| **Bind** | member references, type syntax -> `Symbol` | Resolves `uses`, namespaces, nested names; picks overloads by the reference's parameter types and the wired argument types; records generic instantiation requests | node, pin |
| **Check** | bound Sheets -> typed Sheets | Pin types and conversions; required inputs; flow rules (dominance, regions, Break outside loop); value-read legality (Rule 3); Local lifetime rules; purity; unsafe; abstract/override/interface completeness; constructor chains; generic constraints at each instantiation | node, pin |
| **Lower** | typed Sheet -> **Sheet IR** | Builds basic blocks from the flow graph, materialises value nodes per Rule 1-2, inserts region entry/exit (Local destructors, Defers), null and bounds checks (debug), vtable/itable calls | node (every IR op carries its node id) |
| **Emit** | Sheet IR -> `.ll` text | One `.ll` per type file (the unit), plus requested generic instantiations as `linkonce_odr` functions; DWARF metadata mapping ops to node lines ([section 7](#7-debug-info-and-node-mapping)) | - |
| **Compile** | `.ll` -> `.o` | `clang --target=x86_64-w64-windows-gnu -c` per unit with the config's flags (`-O<optimize>`; `-g` when checks are on or optimize is 0; `-ffunction-sections -fdata-sections` when it optimises: Debug `-O0 -g`, Release `-O2`), in parallel, only for stale units | toolchain |
| **Link** | `.o` + `runtime.a` + core `.o` + C libs -> exe/dll | `clang -static` driving llvm-mingw's `lld` (its default linker); by the project's `kind`: `-mconsole` (console), `-mwindows` (windowed), `-shared` with an import library (library, a DLL; Linux: a `lib<Name>.so` with a version script); an optimised build `-Wl,--gc-sections`, one without debug info `-s`; import libraries from the `.cimport` sets. The exe imports only Windows DLLs (UCRT) | toolchain |

Validate (the editor's Shift+F7) runs Load through Check on the in-memory graphs without writing anything;
it is the same code, so Validate and Build never disagree. Build runs all stages; Run builds when stale.

### 1.1 Front end and the editor seams

The editor reaches the language only through the seams on `LanguageContext`
(`TreadleCore/src/Language/LanguageContext.bf:14`; `FORK-NOTES.md` (the fork log, kept with the private repository), "Seams"), and the
compiler's front end is what fills them:

| Stage / piece | Seam it implements | Where the seam is |
|---|---|---|
| The file list of a project | extends `ProjectIndex` (the editor's folder scan by the codec's extension); the compiler reads the `.tproj` `source` folders and `depends` projects (`ProjectLoader.ScanProject`, `ListFiles`; the services scan again when the index's `Version` changes, section 9) | `TreadleCore/src/Document/ProjectIndex.bf:23` |
| **Load** (the record reader / writer) | `IGraphCodec.Read` / `Write`: one file's text (and its layout sidecar) into a `TypeDocument` and back | `TreadleCore/src/Language/Seams.bf:72`, `TreadleCore/src/Document/TypeDocument.bf` |
| **Declare** + **Bind** (the `TypeTable`) | `ITypeSystem` (pin family and colour, `CanConvert`, value widget kind, enum members, defaults) and `INodeCatalogSource` (the Node menu entries) | `Seams.bf:21`, `Seams.bf:55` |
| **Check** | `ILanguageRules.Check` per Sheet (after the generic `GraphValidator`) and `CheckExpression` for Math nodes | `Seams.bf:107` |
| Validate / Build / Run | `IToolchain`: the back end's `BackendToolchain`, installed by the editor | `TreadleCore/src/Language/Toolchain.bf:20`, `TreadleBackend/src/Driver/BackendToolchain.bf` |
| **Lower** (Sheet IR to the back end) | `IProgramSource.Lower(workspace, config, IRProgram, List<Diagnostic>)`, `FrontEndProgramSource` (`TreadleEditor/src/FrontEndProgramSource.bf`, over `Treadle.Compiler.FrontEndBuild.WriteProgram`), set on `BackendToolchain.FrontEnd` when the editor starts; a project folder with a `.tir` file and no `.tproj` is built from that file (section 4) | `TreadleBackend/src/Driver/BackendToolchain.bf` |
| The project's `kind` and the config's flags | `FrontEndBuild.WriteProgram` reads the `.tproj`: `kind` (`console`, `windowed` or `library`) becomes the `program` line's word (`IRProgram.Kind`; a library needs no `entry`), and the config named by the build resolves through `BuildSettings` (`TreadleCore/src/Model/ProjectModel.bf`): `checks` sets `Compilation.Debug`, the `define`s are what `Build.IsDefined` / `Build.Value` fold to. The back end resolves the same config for `optimize`, `checks` and `debugFormat` (`BackendToolchain.ProjectSettings`) | `TreadleCompiler/src/Build.bf`, `TreadleBackend/src/Driver/BackendToolchain.bf` |
| Debugging | `IDebugAdapter` (the lldb-dap client) under `DebugSession` | `TreadleCore/src/Debug/DebugSession.bf:85` |

Load therefore produces the editor's own document objects: a `TypeDocument` holds the type header, the
members, their Sheets and the unknown records of a type file
([Editor-Model.md 1](Editor-Model.md#1-data-model-the-editor-works-on)); Declare reads them, the editor's open
documents standing in for their files (`TreadleCompiler/src/ProjectLoader.bf`).
The command-line front makes the same `LanguageContext` without an editor.

**Project kinds** ([Graph-Format.md 5](Graph-Format.md#5-project-file-namevproject)), as built:

| Kind | Windows | Linux |
|---|---|---|
| `console` (the default) | `<Name>.exe`, console subsystem (`-mconsole`) | `<Name>`, a PIE |
| `windowed` | `<Name>.exe`, Windows subsystem (`-mwindows`): no console window. `main` calls `rt_windowed` before `rt_start`, so `Main(args)` works as for a console program and Console output goes to the stdout the parent gave it (the editor's Run captures it through a pipe, so the Output Log shows it as for a console program; F5 launches it through lldb-dap, which gives it a pipe too: Debugging.md, "Windowed programs"), else the parent's console (`AttachConsole`, a command prompt), else the debugger's output (`OutputDebugStringA`, through a pipe the runtime reads, so C functions such as `puts` reach it as well) | the same program as `console`: a Linux program has no subsystem |
| `library` | `<Name>.dll` and its import library `<Name>.dll.a` (`-shared`): no `Main` and no `entry`; the exports are the `[Export("name")]` functions (`dllexport` wrappers, section 6.3) and `treadle_init` / `treadle_shutdown`, nothing else (with a `dllexport` in the objects lld exports no other symbol; no `.def` file, no `--export-all-symbols`) | `lib<Name>.so` (`-shared -fPIC`), exporting the same names through a version script (`build/<config>/exports.map`, everything else local) |

A library's user calls `treadle_init()` before the first export (it runs the static constructors and sets up
the Debug tables; nested calls count) and `treadle_shutdown()` after the last (the last one runs the Debug
leak report on stderr and returns the number of leaked objects, 0 in Release). The fault handlers and the
parent-death signal of a program are left out: they belong to the host. Run (Ctrl+F5) of a library builds it
and says there is nothing to run. Fixtures: `TreadleBackend/fixtures/windowed` (the self test checks the PE
subsystem and the output through a pipe and through the editor's `ProgramRun`), `library` (a C host,
`library.host.c`, compiled by the same clang against the import library or the `.so`; the exports listed by
`llvm-readobj --coff-exports` / `llvm-nm -D`), and the front end's `fixtures/projects/library`.

**Decision:** the compiler is in-process in the editor (a library), not a helper process. Reason: it
holds no foreign DLL and no global state (unlike the original editor's checker over `IDEHelper64.dll`); a crash is our
own bug to fix, and sharing the `Graph` model avoids a protocol.

## 2. Type table and binding

* `TypeDecl`: kind, name, namespace, generic parameters and constraints, base, interfaces, members, layout
  (computed lazily per instantiation), attributes, source file and record line.
* `MemberDecl`: kind, name, signature (parameter types with modes, return, outs), modifiers, Sheet (node
  list), owner, vtable slot (virtual), itable slot (interface member).
* **Name resolution** order for a type name in a Sheet: generic parameters of the member, then of the type;
  nested types; the type's namespace and its parents; `uses` lines; the global namespace; the core
  library (`Core.*` is implicitly used); C import pseudo-namespace `C.<set>`. Ambiguity is an error naming the
  candidates.
* **Overloads**: a member reference may carry parameter types (`WriteLine(StringView)`); when it does not,
  candidates are filtered by argument count and scored (exact 4, implicit 2, generic bind 1, refused -100,
  the original editor's scoring kept). Between scores that are equal, an integer argument given to a `float`
  parameter loses to a `double` one (`Math.Sqrt` of an int is `Sqrt(double)`). A tie left is an error; the
  editor fixes the reference when the user picks one.
* **Generics**: an instantiation request `TypeDecl + args` is memoised in an `InstanceTable`; the body is
  checked once per instantiation (constraints make most errors appear at the definition, but a constraint
  cannot express everything, so an instantiation failure reports the chain: "while instantiating
  `List<Pair<int,String>>` for node X in `Program.Main`"). Lower keys the instances it emits by their IR
  types (`Lower.IRCanon`: `int64` and `uint64` are `int` and `uint` there, inside generic arguments too), so
  `AppendSlot<int64>` and `AppendSlot<int>` are one function; messages keep the spelled type.
* **Math Expressions** (Language.md 5.6): one parser (`MathExpr.bf`: the grammar, positions in its messages) for
  the node, the editor's field (`TreadleRules.CheckExpression`, syntax only) and constants. `ExprTyper.bf` types
  the tree with the Operator / Select / Call nodes' rules; the node's binder (`BindMath.bf`) runs it in passes
  that only find the unwired inputs' types (what they meet; a double when nothing types them), then once more to
  report, adds one input per name with its type and keeps the bound tree on the node (`BNode.MathTree`).
  `LowerMath.bf` makes the ops the equivalent nodes make (`Operate`, the And / Or and Select slots, `Invoke` of
  the Math function, `extract` of a struct field); no op is special to it.
* **Constant folding** (Language.md 4.6): after the layout, Declare folds every constant (`Consts.bf`,
  `FoldConstants`; C import sets' `cconst` too): the init (or each of a const array's `elements`) is parsed with
  the Math Expression parser, typed by `ConstTyper` (names are constants and enum cases, resolved like a member
  reference, the constants named folded first; a constant met again while folding is a cycle, T1081) and
  evaluated in 64-bit integers (checked) and doubles (a float's value rounded to a float), then written as one
  literal token (`MemberSym.ConstValue`, `ConstElements`). A const array's type becomes `Span<T>`. Bind reads a
  pin literal that names a constant as its value (`BNode.ConstPins`). Lower puts the literal where a Get is read
  and emits a constant's `global ... const` line, in its type's unit, only when a Sheet needs its address or reads
  a const array (`ProgramLowerer.ConstGlobal`); the back end defines it as an LLVM `constant`.

## 3. Check: the rules the graph needs

Besides ordinary type checking, the Check stage does what a textual language gets from its syntax tree:

1. **Flow graph** per Sheet: flow nodes as vertices, flow wires as edges, Entry as root. Unreachable flow
   nodes are reported as warnings ("not reached") and not compiled.
2. **Dominator tree** over the flow graph (Cooper-Harvey-Kennedy; Sheets are small). Regions are computed
   from body output pins ([Language.md 5.3](Language.md#53-regions-and-scoped-lifetimes)).
3. **Value reads**: for every wire from a flow node's value output to a consumer, the consumer's owning flow
   node must be dominated by the producer; for a Local's `object`, additionally inside the Local's region.
   A value node's "owning flow node" is each flow node that transitively consumes it (a value node has as
   many owners as consumers; each is checked).
4. **Loop-carried reads**: reading a loop body's output after the loop (`done` region) is legal only if the
   loop runs at least once (Do While) or the pin is the loop's own (`index` after a For is an error:
   "not valid after the loop; store it in a local").
5. **Break / Continue** must be inside a loop region; **Try** needs a compatible `Result` return type;
   **Return** must set every `out`.
6. **Purity**: a pure Sheet contains no Set to a non-local, no Construct, no Delete, no non-pure Call, no
   Invoke, no unsafe node. Checked per Sheet, so the error sits on the offending node.
7. **Local rules**: `object` of a Local stored into a field -> warning; returned -> error; a `Delete` whose
   input provably comes from a Local or Append -> error.
8. **Sequence regions** may not share value reads across `then` outputs unless through a local (same as
   the original editor, now an error with a "Store in a local" fix).

Rules Declare and Bind add for the same reason (a graph has no syntax that rules the case out):

* **Every variable has a type** (Declare, T1078): a Local Variable, a field, a property, an input, an output and a
  `const` generic parameter; the diagnostic names the variable (`CDiag.Variable`, `local:newVar`), which the
  editor's Problems row selects in the Outline. Lowering never sees a typeless variable (if it did, T4003 names the
  function and the variable rather than writing a Sheet IR the back end cannot read).
* **A delegate Thread.Start or ThreadPool.Run will own** is not a Local Bind Function or Lambda (Bind, T2224).
* **A compound Set** (`set op *=`) finds its operator as the Operator node does, by the variable's type and the
  type wired into Value or the number type its literal fits (`Vec3 *= float`); the operator's result must be the
  variable's type (T2083).
* **`T : vector`** (Declare reads `vector` and an optional lane type after it, `GenericParamSym.IsVector` /
  `VectorElement`): a `T` operand takes the element-wise operators (BindVector `TryBindGenericVectorOperator`: a
  scalar beside it splats per instance when the lanes are named) and the vector functions; overload scoring and a
  Call's signature match refuse a non-vector argument for such a parameter, so `String.Append(int)` keeps its own
  overload beside VectorFormat's generic one.

## 4. Sheet IR

A small SSA-style IR; one function per lowered Sheet (per instantiation for generics). It lives in
`TreadleBackend/src/IR/IR.bf`; the front end builds an `IRProgram` in memory and hands it to the driver
through `IProgramSource.Lower` ([1.1](#11-front-end-and-the-editor-seams)), or writes the same program as
text (`.tir`, `IRWriter.Write` / `IRReader.Read`, round trip exact). A fixture is `<name>.tir` plus
`<name>.expected` (stdout, exit code, stderr lines), run by `TreadleBackend/src/Testing/FixtureRunner.bf`.

**In memory.** `IRProgram { Name, Kind, Entry, Units, Decls, Globals, Functions, Types }`;
`IRProgram.T("Core.Pair<int,int>")` interns a type; `AddUnit`, `AddDecl(kind, name, unit)`,
`AddFunction("Game.Rect.Area()", ret, unit)`, `AddGlobal`; then `fn.AddParam` (`this` first for instance
functions, or left out and added by Link), `AddSlot(id, type, kind)` (or `AddSlot(id, type, kind, name, shows)`
with the slot's user-facing name, and `slot.TypeText` / a parameter's `TypeText` for a spelling such as
`int64` that the IR folds into `int`), `AddRegion(id, parent)`,
`AddNode(id, kind, subject)`, `AddBlock(id)`, `block.Add(kind, type)` returning an `IROp` whose fields
(`Args`, `Result`, `Slot`, `Fn`, `TypeArg`, `Global`, `Targets`, `Cases`, `Region`, `Sub`, `Index`, `Lit`,
`NodeId`, `Pin`) are what the text form names. `IRProgram.Link(errors)` resolves names and checks the
structure. Every op carries its node and pin; ops without one (made by Lower) are allowed.

**Text form** (one record per line, `#` comments, indentation is for reading):

```
# tir 1
program <Name> console|windowed|library      # library: no entry line
entry <funcref>
unit <Unit.Name> ["<type file>"]          # following records belong to this unit (one type file)
type <Name> class|struct|enum|interface [abstract] [packed]
	base <Class>                           # classes; default Core.Object
	field <name> <Type> [owned]
	vslot <declaring funcref> <impl funcref|abstract>   # every slot, base slots first
	itable <Interface> <funcref>...        # implementations in the interface's slot order
	islot <funcref>                        # interfaces: slot order, extended interfaces first
	case <Name> [= <int>] [<payload Type>...]
	tag <int type>                          # simple enums (default int32)
	dtor <funcref>                          # the ~this Sheet
global <Owner.name> <Type> [<literal> | import "c name"]   # import: an extern C variable (cvar), never defined here
global <Owner.name> <Type> const <literal>                 # a constant's read-only global (its address is taken)
global <Owner.name> <T>[<N>] const <e0> <e1> ...           # a const array's read-only elements (N tokens)
func <funcref> <RetType> [static] [virtual] [abstract] [sctor] [import "c name"] [export "c name"]
                         [cconv cdecl|stdcall|fastcall] [sheet "<sheet key>"] [display "<Type.Member>"]
	param <name> <Type>                     # names of the parameters after `this`, in order
	region <id> [parent <id>]               # r0 is the body region, always there
	slot <id> <Type> local|variable|outtemp|loopvar ["<name>" local|pin] [region <id>] [node <id>[.<pin>]]
	                                         # name: the local's name or `<node>.<pin>` (debugger, alloca)
	node <id> <Kind> [<subject>...]         # the listing line of each node
	block <id>
		[%x =] <op> ... [@<node>[.<pin>]]
```

A funcref is `Owner.Name<generic args>(param types[,...])` without spaces: `Game.Rect.Area()`,
`Gen.Math.Max<int>(int,int)`, `Mem.Node.this(int)` (constructor), `Mem.Node.~this()`, `C.libc.printf(char8*,...)`.
Types: `int int8..int64 uint..uint64 float double bool char8 char32 void StringView`, the vector primitives (`float4`, `int32x4`, `bool4`; constants `const float4 1,2,3,4`, one value filling every lane, `zero`), `T*`, `ref T`, `T[]`,
`T[N]`, `T?`, `(A,B)`, `function R(A,B)`, `delegate R(A,B)` (a reference to a delegate object), names with generic args (`Core.Result<int,int32>`); `Object` is
`Core.Object`. A class or interface type used as a value is a reference.

**Names the front end gives** where the grammar has no word of its own (within the funcref syntax):
operators are `Type.op$eq(...)` (`op$` and the operator's name: `op$add`, `op$lt`, ...), property accessors
`Type.get$Name()` and `Type.set$Name(T)`, a static constructor `Type.$sctor()`. `ref` / `out` / `in`
parameters are passed as `T*` (a `slot.addr` or `field.addr`) and are `T*` in funcrefs too, as the function's
`param` line says (milestone 3; the `ref T` spelling did not match the `param` line).

**Program Start.** The entry function takes no parameters, or one `Core.String[]` (`Main(String[] args)`):
`main` then asks the runtime for the arguments after the program's name as a `Core.String[]` (UTF-8, made
from the wide command line on Windows; each String made by the program's `Core.String.this(StringView)`),
passes it and frees it after Main returns (Debug: tracked, so no leak report). The front end names
`Main(Core.String[])` itself as the entry. An entry `Type.Main()` that is the shim older front ends wrote (a
parameterless Main of a type that also has a static `Main(Core.String[])` with the same return type) is
bypassed: `main` calls `Main(Core.String[])` with the arguments.


| Op (`T` is the result type; calls write theirs, `void` included) | Notes |
|---|---|
| `const T <lit>` | integer (decimal: the front end writes a hexadecimal pin literal or init as decimal), float, `true`/`false`, `null`, `zero`, a case name (simple enums), `"text"` (StringView or `char8*`; `\"`, `\\`, `\n`, `\t`, `\r`, and every other byte below 0x20 and DEL as `\xHH`, two hex digits of either case) |
| `copy T %v`, `cast T %v` | cast: numeric, bool, pointer, enum <-> int, class up/down (no check); `cast Core.Span<T> %arr` from a `T[]` is `array.span` over the whole array |
| `array.span Span<T> %arr [%start %count]` | a span value `{ptr, length}` (a struct of a `T*` and an `int`, `Core.Span<T>`) over a `T[]`: its elements and its length, or `count` elements from `start`. Debug: a null array goes to `rt_null`, a range that leaves the array (`start < 0`, `count < 0`, `start + count > length`) to `rt_span_range`, each naming the node; Release: no check. The front end makes it for the `T[]` to `Span<T>` conversion (implicit, or a Cast node) and for the `Arrays.Slice` intrinsic (`List.Slice`) |
| `load.slot T s`, `store.slot s %v`, `slot.addr T* s` | Locals and hidden temps are `alloca` slots; mem2reg in LLVM makes them registers |
| `binop T add\|sub\|mul\|div\|rem\|and\|or\|xor\|shl\|shr %a %b`, `cmp bool eq\|ne\|lt\|le\|gt\|ge %a %b`, `select T %c %a %b` | signedness from the type |
| `field.addr T* %obj <field>`, `elem.addr T* %arr %i`, `array.len int %arr`, `load T %p`, `store %p %v` | a class reference or a pointer to a struct (inherited fields by name); an array object, `T*` or `T[N]*` |
| `nullcheck %obj`, `boundscheck %arr %i`, `boundscheck %span %i %len` | Debug: a branch to `rt_null` / `rt_freed` (a deleted object) / `rt_bounds`; Release: nothing. The three-operand form checks against the length it is given: the front end gives it for a Get [ ] (and an element address for a Set or a `ref`) on a `Span<T>`, extracting the span's `Length` (fixture `spanindexguard`); before it a Span index was not checked in Debug at all. Arrays have the two-operand form (the length from the array object), a List checks in its `[]` operator's Sheet (a Fatal node, Debug and Release), a StringView index is still unchecked |
| `call T <fn> %args`, `ccall T <fn> %args`, `vcall T <fn> %obj %args`, `icall T <fn> %obj %args` | `this` first; imports get the C ABI, variadic extras promoted; for `vcall` / `icall` `<fn>` is the declaring function (a vslot / islot) |
| `fn.addr function R(A) <fn>`, `fptr.call T %fp %args` | |
| `alloc C [%allocator]`, `alloc.array T[] %len [%allocator]`, `local C s`, `local S* s` | `local` needs a slot of kind local (its region is where it dies); the object is zeroed, its vtable set; for a struct `S` the result is the slot's address; with an allocator `alloc` / `alloc.array` allocate through `rt_alloc_with` |
| `local.array T[] s %len` | a dynamically sized Local array; slot `s` (kind local, type `T[]`) holds the reference. The object is on the stack when it fits **16 KiB** (`llvm.stacksave` when made, `llvm.stackrestore` at the region's exit), else on the heap (freed at the exit); zeroed. A negative or too large length is fatal in both configs (`rt_array_length`, section 6.2 "Array lengths"; Debug names a negative one through `rt_local_array_length` first), and in Debug a stack array has a header that makes a Delete of it a reported error |
| `free %o`, `dtor %o`, `delete %o [%allocator]` | `delete`: null does nothing; with an allocator: the destructor, then `rt_free_with`; Debug: a deleted object reports a double free naming both nodes. `dtor` on a `S*` runs the struct's complete destructor (nothing when it needs none) |
| `atomic.load T <order> %p`, `atomic.store <order> %p %v`, `atomic.rmw T xchg\|add\|sub\|and\|or\|xor\|min\|max <order> %p %v`, `atomic.cas (T,bool) <order> %p %expected %new`, `fence <order>` | orders `relaxed`, `acquire`, `release`, `acqrel`, `seqcst`; `T` an integer of 8 to 64 bits, a pointer or a reference (load, store, add, sub, xchg also a float); rmw returns the old value, min / max follow the type's signedness; cas returns the old value and whether it was replaced (its failure order drops the release part) |
| `bind delegate R(A) <fn> [%target]`, `bind.local delegate R(A) s <fn> [%target]` | a delegate object (`Core.Delegate`) on the heap, or in slot `s` (kind local, type `Core.Delegate`); a static `<fn>` takes no target (called through a thunk), an instance one takes its target; a virtual or interface `<fn>` is resolved from the target's tables when bound, any other is bound directly. A struct function's target is the struct's address (`S*`, its `this`); C imports are not bound (`fn.addr` for C) |
| `closure delegate R(A) %c <fn>` | `%c` is a closure object (a class with `base Core.Delegate` whose fields are the captures, made by `alloc` or `local`, the captures stored by the front end); it becomes its own delegate: target = `%c`, fn = `<fn>`, a function of the closure class (its `this` is the closure) |
| `invoke R %d %args` | calls `fn(target, args)` of the delegate (`nullcheck %d` first, as for other references) |
| `region.enter r`, `region.exit r` | exit runs the region's executed Defer bodies (last first), then the destructors of its executed Locals (last first) |
| `defer r <block>` | marks the Defer executed; `<block>` starts its body, which ends in `enddefer`; a body reads only slots, params and its own values |
| `box Core.Object %v`, `unbox T %o`, `dyncast C %o`, `typeinfo void* <Type>` | dyncast to a class or an interface; null when it fails |
| `make T %a...`, `extract T %agg <i>` | structs, tuples, `T?`, StringView |
| `case.make E <Case> %payload...`, `enum.tag T %e`, `enum.payload T %e <Case> <i>` | Result / Option are ordinary payload enums |
| `global.addr T* <global>`, `sizeof int <Type>`, `alignof int <Type>` | |
| `intrinsic T sqrt\|fabs\|floor\|ceil\|sin\|cos\|exp\|log\|trunc\|round\|pow\|minnum\|maxnum %a...` | LLVM intrinsics |
| `binop`, `cmp`, `select`, `cast`, `intrinsic` on vectors | per lane: `binop float4 add %a %b` (signedness from the lane type), `cmp bool4 lt %a %b` gives a lane mask, `select float4 %mask %a %b` picks lane by lane, `cast int32x4 %v` converts each lane (a mask lane is 0 / 1; to a mask: `!= 0`), `intrinsic float4 sqrt\|fabs\|floor\|ceil\|trunc\|round\|sin\|cos\|exp\|log\|pow\|minnum\|maxnum\|fma\|copysign %a...` and `abs\|smin\|smax\|umin\|umax` on integer lanes (`llvm.<name>.v4f32`) |
| `vec.make T %e...`, `vec.splat T %s`, `vec.get E %v <lane>\|%i`, `vec.set T %v <lane>\|%i %s` | vectors (SIMD-and-Vectors.md 1.4): one value per lane (`insertelement`), the scalar in every lane, a lane read or replaced (`extractelement` / `insertelement`); a variable index is checked by `lanecheck` first |
| `vec.shuffle T %a poison\|%b <m>...`, `vec.reduce E add\|mul\|min\|max\|and\|or\|xor %v`, `vec.any bool %m`, `vec.all bool %m`, `vec.bitmask uint %m`, `vec.bitcast T %v` | lanes picked (`shufflevector`; 0..N-1 of `a`, N..2N-1 of `b`); a reduction (integers `llvm.vector.reduce.*`; float add / mul in a fixed pairwise tree, `(l0 + l2) + (l1 + l3)` for 4 lanes, a 3-lane vector padded with -0.0 / 1.0; float min / max `llvm.vector.reduce.fmin / fmax`); mask tests (`reduce.or / and` of `<N x i1>`; the bits as an integer, lane 0 the lowest); the same bytes as another vector of one size |
| `vec.load T %p <align>`, `vec.store %p %v <align>`, `vec.spancheck %index %length <N>`, `lanecheck %i <N>` | N lanes through an element pointer (`E*`, the alignment of a lane: unaligned data); Debug: lanes index .. index + N - 1 inside the span (`rt_span_range(site, index, N, length)`), a lane index in 0..N-1 (`rt_bounds(site, i, N)`), each naming the node; Release: nothing |
| `intrinsic void memcpy\|memset %d %s %n`, `intrinsic int32 memcmp ...`, `intrinsic void console.write\|console.writeline\|console.error %sv` | |
| terminators: `br b`, `condbr %c bt bf`, `switch %v bdefault [<int> b]...`, `ret [%v]`, `enddefer`, `unreachable`, `fatal <code> "<message>"` | every block ends in exactly one |

Rules the back end relies on: the first block is where the function starts (it may also be a branch target;
the back end adds its own entry block for the slots); flow-node results the Sheet reads later live in slots
(values do not cross into Defer bodies); generic instances are separate decls and functions with their
arguments in the name (`Gen.Cell<int>`), written in the generic definition's unit section (their Sheet key is
shared, so all instances map to the same listing lines).

**Lowering of Rule 1-2** (value nodes): when lowering a flow node, the compiler walks its value inputs in pin
order and emits ops for each value node it reaches, memoising per *flow node* (so a value node feeding two
pins of the same flow node is emitted once) and clearing the memo after the flow node. Reads of flow-node
outputs load from the producer's result slot. **Rule 4**: `&&`, `||`, Select create blocks.

**Merges** become a block with several predecessors. Flow-node result slots are `alloca`s, so no phi
construction is needed in the compiler; LLVM's mem2reg does it.

**Regions**: a Local gets one `alloca` of its static size at function entry (reused each loop pass). A
dynamically sized Local array (`local.array`) saves the stack pointer when it is made and restores it at
its region's exit (or frees its heap block above 16 KiB). Struct Locals run their complete destructor at
the region's exit when the struct needs one; a struct value copied elsewhere (a variable, a field, a
parameter) is a bitwise copy and is not destroyed by the back end (`dtor %p` destroys a storage explicitly).
Every edge leaving a region (fallthrough, Break, Continue, Return, Try-return) goes through `region.exit`
for each region left, innermost first; Lower emits them, the back end does not add them.

The body region `r0` is a region like the others: Lower emits `region.enter` on every body output that opens
a region and `region.exit r0` before every `ret`. A Defer's body is its own blocks (`defer r <block>` where the
Defer runs, `enddefer` where the body ends); its inputs are made inside the body from slots. A Local or a Defer
that runs on only some paths of its region is allowed: the region's flags unwind exactly what ran.

**Stack in Debug.** A Debug frame is several times a Release one: every flow output something reads has its
own slot (so the debugger shows each pin's value), each zeroed at entry; the back end's temporaries for
payloads and Make Case are allocas too; and at `-O0` LLVM gives every aggregate value (a `Result`, a payload
enum) a stack copy. m5-json's `ParseValue` is 992 bytes in Debug (eight `Result` slots of 40 bytes, eight
back-end temporaries, the rest `-O0` copies); sharing the result slots of a Switch's exclusive cases would save
208 of them but leave only one of those pins visible in the debugger, so it is not done. Debug programs on
Windows link with an 8 MB main stack (`-Wl,--stack,8388608`; Release keeps the 1 MB default): m5-json's
nesting limit without its 512 check went from 648 to 5,283 levels in Debug (Release: 2,380).

**String literals.** A text literal on a `String` pin is a Local `String` of the function's body region,
made from the text (the IR has no constant objects), so it is freed when the function returns. On a
`StringView` or `char8*` pin it is a `const`.

**Fatal.** `fatal` takes a constant message, so a Fatal node lowers to `intrinsic void console.error` with
the node's message, then `fatal 1 "Fatal node"`. A node kind the front end does not lower yet ends its block
in `fatal 2 "<title> is not compiled yet"`; Check warns about it first (T3070).

**Milestone-2 nodes, with the existing ops only** (`TreadleCompiler/src/LowerState.bf`). The stateful flow
nodes load and store their state field (`global.addr` for a static one, `field.addr` on `this`;
[Language.md 5.1](Language.md#51-flow-nodes)) and branch with `condbr`; a Multi Gate jumps to its outputs
with `switch`, and `set random` steps a 64-bit linear congruential generator in its seed global and
probes for an output not run yet. A checked Cast is `dyncast`, its result in a slot, then `cmp ne` null
into Succeeded / Failed. Switch on text compares the length, then `intrinsic int32 memcmp` against a
`const StringView` per case. For Each over an enumerator calls `GetEnumerator` once into a slot, `MoveNext`
on the slot's address in the loop header, and `get$Current` where Element is read. A static constructor is
`Type.$sctor()` with the `sctor` flag; an auto property gets made `get$Name` / `set$Name` over its hidden
field. Construct with an allocator is `alloc C %allocator` (the runtime's `rt_alloc_with`); Delete with an
allocator is `delete %o %allocator`. Construct of a generic parameter is lowered per instance with the
instance type's constructor without inputs.

**Milestone-2 nodes on the back end's newer ops** (`TreadleCompiler/src/LowerSheet.bf`, front end wave 2). A
Local array is a slot of its region and `local.array`. A struct with a `~this` Sheet gets its `dtor` line. A
`Core.Atomic` Call is `atomic.load` / `atomic.store` / `atomic.rmw` / `atomic.cas` (its `replaced` stored
through the out input) or `fence`, with the node's `set order`, on the address of the variable it takes by ref.
Bind Function without an Allocation is `fn.addr`; with one it is `bind` or `bind.local` (a slot
`Core.Delegate local` of the node's region), a virtual function named by its declaring slot and the Receiver
cast to that class or interface. A delegate Lambda declares `<Owner>.$lambda_<node>` (`base Core.Delegate`, a
field per capture: the variable's type, a pointer to it for a by-ref capture, `__this` for `this`); its Sheet is
`<Owner>.$lambda_<node>.Invoke(<inputs>)`, reading the captures through `field.addr` on the closure; the node
makes the closure with `alloc` or `local`, stores the captures and makes the delegate with `closure`. A function
pointer Lambda is the static `<Owner>.$lambda_<node>(<inputs>)` and `fn.addr`. Inside a Lambda Sheet a Lambda's
captures that are not the Sheet's own inputs are captures of that Sheet too (Bind chains them): the node stores
the value loaded from the outer closure's field, or for a by-ref capture the address the field gives (the field
itself, or the pointer a by-ref field holds), so a chain of Lambdas reaches the function's variable. In a
generic type `<Owner>` is the instance (`Gen.Box<int>.$lambda_<node>`, `ProgramLowerer.Closure`): each instance
gets its closure class and Lambda functions, the capture and input types substituted, written with the instance
in the definition's unit (shared, `linkonce_odr`, like the instance's members). Invoke is `nullcheck` then
`invoke`, or `fptr.call` for a function pointer. A C record that lays out naturally is a `struct` with its
fields; a union (or a packed, gapped or overlapping record) is a `struct` of opaque words of its size and
alignment whose fields are read and written by byte offset (`cast` to `uint8*`, `elem.addr`, `cast` to the
field's pointer type). A C constant is its `const`. A variadic call appends its `va<i>` inputs promoted.

**Front end wave 4** (`LowerSheet.bf`, `Lower.bf`). An **extension**'s Sheets are functions of the extended type
(`C._div_t.Total()`, `Core.List<int>.CountPlus(int)`) written in the extension's own unit; for a generic extended
type, per instance as the instance is reached (`ProgramLowerer.LowerExtensionsOf`, the closure classes of its
Lambdas named `$lambda_<Extension>_<node>`). An **event** field is declared with its storage type
`Core.Event<D>` (a struct field; its `dtor` deletes the handlers with the object); Add, Remove, Clear and Count are
`call`s of the storage's functions on `field.addr` of the event; Invoke is a loop over the existing ops (a slot for
the index, `get$Count()` in the header, `At(int)` and `invoke` in the body), no new op. **Bind Function** of a
struct's function passes the variable's address as the target (`slot.addr`, `field.addr`, `global.addr`, or `this`).
A **C variable** (`cvar`) is `global.addr` of an imported global (`global C.<set>.<name> T import "<name>"`,
written once with the imported functions), or the `ccall` of its `via` function (the address for `deref`, the
value otherwise). **Construct of an array with an allocator** is `alloc.array T[] %len %allocator`.


## 5. LLVM IR emission

* Target `x86_64-w64-windows-gnu` (llvm-mingw), later `x86_64-pc-linux-gnu`. Data layout from clang's own
  target so struct layouts match C.
* Classes: `%Game.Player = type { %Object.Header, fields... }`; `Header = { ptr vtable }`.
  Structs: LLVM struct of the fields in declaration order (`[CRepr]`), with explicit padding when `[Packed]`.
  Payload enums: `{ i32 tag, [K x iA] }` where A is the largest payload alignment (so an `int` payload is
  8-aligned) and K covers the largest payload, bitcast per case.
  Nullable `T?`: `{ T, i1 }`. Tuples: anonymous structs. Arrays: `{ Header, i64 length, [0 x T] }`.
  Strings: an object (`String` class of the core) and `StringView = { ptr, i64 }`. Delegates: a
  `Core.Delegate` object `{ Header, ptr target, ptr fn }` (declared by the back end when the program does
  not), or a closure class derived from it with the captures after `fn`.
* Vectors (SIMD-and-Vectors.md 1.2): a value is `<N x T>` (a mask `<N x i1>`), in registers in every
  Treadle-to-Treadle call (never `sret`). In memory a vector takes N lanes (3 lanes the room of 4) aligned to
  min(size, 16): rt_alloc and the stack give 16, so nothing is over-aligned. LLVM aligns `<8 x float>` to 32 and
  bit-packs `<4 x i1>`, so a vector over 16 bytes is stored as an array of 16-byte vectors (`[2 x <4 x float>]`)
  and a mask as bytes (`<4 x i8>`): the LLVM layout of a struct, array or tuple holding them is Treadle's
  (`struct { float a; float4 v; }` is 32 bytes, `v` at 16). Loads and stores go through a pointer as the value
  type with an explicit `align` (1 for a field of a `[Packed]` struct); only `insertvalue` / `extractvalue` of an
  aggregate convert between the two forms (`TreadleBackend/src/Emit/EmitVector.bf`). TBAA leaves vector accesses
  untagged.
* Functions: `define` per lowered Sheet; generic instantiations `linkonce_odr` in a COMDAT, and the type data
  (TypeInfo, vtable, complete destructor) of shared types (generic instances, core types, arrays, boxed
  structs) `linkonce_odr` in every unit that uses them, so the linker folds them. Member functions take `ptr this` first (`ref this` for
  struct members).
* Virtual calls: load vtable, load slot, `call`. Interface calls: `call @rt_itable(obj, ifaceId)` then load
  slot (section 6); a per-call-site inline cache (`{typeinfo, itable}` global) is an optimisation for
  later. Release: Delete of a class nothing in the program derives from calls its complete destructor
  directly, or nothing ([6.4](#64-what-release-code-tells-llvm)).
* Debug builds: `-O0`, every check op is a real branch to a `fatal` block, frame pointers kept for the
  debugger; release: `-O2` and ThinLTO, checks removed at Lower time (not by LLVM), so release IR is clean,
  plus the allocation attributes and alias metadata of [6.4](#64-what-release-code-tells-llvm).
* Results over 16 bytes or of more than two scalars return through a hidden `sret` pointer
  ([6.3](#63-calling-conventions-and-c-interop)).
* `.ll` text is written, not bitcode. Reason: readable when debugging the compiler; `clang` accepts it
  directly; the cost (parsing) is small next to code generation.

### 5.1 Name mangling

**Decision:** Itanium C++ ABI mangling (`_ZN4Game6Player10TakeDamageEi`), with Treadle types mapped as
C++ namespaces and classes, generics as template arguments, and a fixed set of substitutions for core
types (`String` -> `N4Core6StringE`). Reason: lldb, `llvm-objdump`, `llvm-nm` and crash dumps demangle it
with no work from us; the mapping is well specified; the compiler never needs to demangle (it keeps a
table from mangled name to member for diagnostics).

| Treadle | Mangled piece |
|---|---|
| `int`, `int32`, `uint8`, `float`, `double`, `bool`, `char8`, `char32`, `void` | `x`, `i`, `h`, `f`, `d`, `b`, `c`, `Di`, `v` |
| `T*`, `ref T`, `T[]`, `T?` | `P<T>`, `R<T>`, `N4Core5ArrayI<T>EE`, `N4Core8NullableI<T>EE` |
| `Game.Player` | `N4Game6PlayerE` |
| `List<int>` | `N4Core4ListIxEE` |
| `Player.TakeDamage(int)` | `_ZN4Game6Player10TakeDamageEx` |
| constructor / destructor | `C1`; the `~this` Sheet is `D2`, the complete destructor `D1` (made by the back end: the Sheet, then the fields last first: owned objects deleted, struct fields that need it destroyed, fixed arrays of them element by element; then the base's `D1`; vtable slot 1). A struct needs a `D1` when it has a `~this` Sheet, an owned field or such a field; its `D1` takes the struct's address. An array of such structs gets `_ZN4Core5ArrayI<T>E` `D1Ev` (each element, first to last) in its vtable |
| delegate type `delegate R(A,B)` | `N4Core8DelegateI<R><A><B>EE`; the thunk of a bound static function is its symbol plus the clone suffix `.dthunk` |
| static field | `_ZN4Game6Player6sCountE` |
| vtable, type info | `_ZTVN4Game6PlayerE`, `_ZTIN4Game6PlayerE` |
| vector `float4`, `int32x4`, `uint8x16`, `bool4` | Itanium vendor vectors: `Dv4_f`, `Dv4_i`, `Dv16_h`, `Dv4_b` |
| `[Export("name")]` | the plain `name`, C linkage, the win64 C ABI ([6.3](#63-calling-conventions-and-c-interop)) |

## 6. Runtime ABI

The runtime is C, compiled by the same clang into `runtime.a` (debug and release variants).
Everything the compiler emits a call to is in this table. It is `tools/runtime/treadle_rt.c`, and
`tools/runtime/treadle_rt.h` is the ABI; the driver compiles it once per configuration and caches it (in the
project and per user, `%LOCALAPPDATA%/Treadle/cache/runtime`, keyed by clang, its flags and the source
hashes; `TREADLE_RUNTIME_CACHE=0` turns the per-user cache off). Its flags are the config's: `-O<optimize>`,
`-g` with debug info, and the Debug runtime (`-DTREADLE_DEBUG=1`: tracking, checks, the leak report) when
`checks on`, whatever the config is called, so a `Profile` config with `optimize 2` and `checks on` gets an
`-O2` Debug runtime ([Graph-Format.md 5](Graph-Format.md#5-project-file-namevproject)). It declares the Win32 functions it calls
instead of including `windows.h`, which kept most of its compile time. The
probe shim names (`treadle_alloc` / `treadle_free` / `treadle_rt_report`, [Toolchain.md](Toolchain.md),
Probe 1) remain on top of the debug allocator. Node ids are strings, so every entry point that names a node
takes a `const rt_site*` (`{ char* where; char* node }`, a constant the compiler emits per node).

### 6.1 Object header and vtable

```
Object       = { ptr vtable }                       // 8 bytes; identical in debug and release
VTable       = { ptr typeInfo, ptr dtor, ptr slot0, ptr slot1, ... }   // base class slots first
TypeInfo     = { u32 typeId, u32 flags, u64 size, u32 align, ptr name, ptr baseTypeInfo,
                 u32 ifaceCount, u32 fieldCount, ptr ifaces, ptr fields }   // pointers to the two arrays
IfaceEntry   = { u32 ifaceTypeId, ptr itable }
FieldInfo    = { ptr name, ptr typeName, u64 offset }
ITable       = { ptr slot0, ptr slot1, ... }        // in interface declaration order, extended interfaces first
```

* `typeId` is assigned at link time? **Decision:** no; it is a 32-bit FNV-1a hash of the mangled type name
  (`rt_fnv1a`), so units compile independently. A collision is found when a Debug program starts (the
  runtime walks the type registry: fatal error 9, "type id collision between A and B: rename one"); Release
  does not check. Reason: incremental compile units must not depend on a global numbering.
* `rt_itable(obj, ifaceId)` walks `TypeInfo.ifaces` (small arrays; linear) and returns the itable or
  fatal-errors. `rt_dyncast(obj, typeInfo)` walks `baseTypeInfo` and the interface list.
* Debug builds keep the same object layout. Debug allocation metadata sits **before** the object:
  `DbgHeader = { u64 magic, rt_site* allocSite, rt_site* freeSite, u64 size, ptr prev, ptr next }` (48
  bytes, a doubly linked live list). `rt_free_dbg` records the freeing site, replaces the object's vtable
  with `rt_poison_vtable` (every slot points at `rt_use_after_free`), and keeps the block in a quarantine ring
  (bounded total bytes) before it goes back to the allocator. `rt_free_dbg` on a freed block or one whose
  magic is wrong reports double free / foreign pointer with both nodes.

### 6.2 Functions the compiler calls

| Function | Build | Purpose |
|---|---|---|
| `void* rt_alloc(size, align)` / `rt_free(ptr)` | release | Default allocator (`calloc` / `_aligned_malloc` behind; declared `noalias nonnull`, `allocsize(0)`, [6.4](#64-what-release-code-tells-llvm)) |
| `void* rt_alloc_dbg(size, align, site)` / `rt_free_dbg(ptr, site)` | debug | As above with tracking |
| `void* rt_alloc_with(IAllocator*, size, align)` / `rt_free_with(...)` | both | Custom allocator (calls through its itable) |
| `ITable* rt_itable(obj, ifaceId)` | both | Interface dispatch |
| `Object* rt_dyncast(obj, TypeInfo*)` | both | Class Cast |
| `void rt_fatal(code, site, msg)` | both | Prints `fatal: <msg> at <Type.Function> node <id>`, writes a crash file, breaks into an attached debugger, runs the leak report (debug) and exits with code 3 |
| `void rt_null(site)`, `rt_bounds(site, idx, len)`, `rt_freed(site)`, `rt_span_range(site, start, count, len)` | debug | Check failures (`rt_freed`: use of a deleted object found by a check) |
| `void rt_start(argc, argv)` / `int32 rt_exit(code)` | both | Runs static constructors, calls `Main`; `rt_exit` runs the leak report (debug) and returns the program's code (a Debug run that exits 0 with leaks returns the leak count) |
| `void rt_windowed()` | both | Kind `windowed`: called by `main` before `rt_start`. Keeps a stdout the parent gave (a pipe, a file), else attaches the parent's console, else points the C library's stdout and stderr at a pipe whose reader thread passes the text to `OutputDebugStringA` (Console output, C functions such as `puts`, the leak report, fatal errors; the rest is forwarded at exit and before a fault's exit). Windows; nothing on Linux. `rt_start` makes stdout unbuffered when a debugger is present (Windows), so a stop shows what was written before it |
| `void rt_lib_start()` / `int32 rt_lib_exit()` | both | Kind `library`: behind the exported `treadle_init` / `treadle_shutdown` the back end emits. Start: static constructors and the debug tables, once (nested pairs count), no fault handlers. Exit: the last one runs `rt_exit(0)`, the leak report (debug), and returns the leak count |
| `int32 rt_leak_report()` | debug | Walks the live list; prints type, size and allocating node per leak |
| `void* rt_args_make(arrayVT, stringVT, size, align, init)` / `rt_args_free(args)` | both | `Main(String[] args)`: the arguments after the program's name as a `Core.String[]`, each String zeroed, its vtable set and `init(obj, utf8, length)` run (a thunk calling `Core.String.this(StringView)`); freed with each String's `D1` after Main returns. `rt_arg_count` / `rt_arg(i)` give the same UTF-8 arguments (on Windows from `GetCommandLineW`) |
| `void rt_local_array_length(site, len)` | debug | `local.array` with a negative length |
| `void rt_array_length(site, len, elemSize)` | both | `alloc.array` / `local.array` with a negative length or one whose size in bytes does not fit ("Array lengths" below) |
| `rt_memcpy/memset/memcmp` | both | Thin wrappers (so `Memory` intrinsics have one symbol set) |
| `void rt_abstract_call()` | both | What an abstract vtable slot points at (fatal) |
| `rt_console_write(p, n)`, `rt_console_write_line(p, n)`, `rt_console_error_write(p, n)` | both | The `console.*` intrinsics (`Console.Write`, `WriteLine`, `Error`) |

**Array lengths** (Security-Review.md finding 2). Before `alloc.array` and `local.array` compute `len * size +
header`, the length is checked in both configurations and a bad one is a fatal error naming the node
(`fatal: array length -1 is negative at ... node a3`, `... is too large (8 bytes per element) ...`). Debug: `len < 0`,
`llvm.umul.with.overflow` of `len * size` and `llvm.uadd.with.overflow` of the header and 128 bytes of slack (the
Debug headers), and the total must stay a positive int64. **Decision:** Release checks with one unsigned compare,
`len > (INT64_MAX - header - 128) / size`, which a negative length (a huge unsigned number) fails as well, so
both faults cost one compare and a branch that is never taken. Measured on an array version of the `alloc` kernel
(30,000,000 `Construct int[]` of a run-time length, write, read, Delete; Release, nine alternating runs): 930 ms
median without the check, 925 ms with it, within the run-to-run spread (908 to 1005 ms). Fixtures `arraylength`,
`arrayhuge`, `localarrayhuge` and `localarrayguard` (TreadleBackend/fixtures) end with exit code 3 and the message
in both configurations.

The core library's C helpers (`rt_arg`, `rt_dir_*`, `rt_parse_*`, `rt_format_*`, `rt_utf8_*`, `rt_env_*`,
`rt_proc_*`, `rt_time_now`, `rt_sleep`, ...) are called through the core's `crt` C import set, not by the
compiler (section 10).

**Threads** ([Threads.md](Threads.md) 4-6). The core's thread types call the runtime's thread block directly: each
declares its functions as private static functions with `[Import("treadle_rt", "rt_...")]` (no Sheet), so a call is
an ordinary `ccall`; no new op or intrinsic, and the `crt` set is unchanged.

| Function | What |
|---|---|
| `rt_thread_new(name, len, stackSize, owner)`, `rt_thread_start(t, body)`, `rt_thread_join` / `detach` / `free`, `rt_thread_alive` / `id` / `name`, `rt_thread_current` / `current_id`, `rt_thread_yield`, `rt_cpu_count` | Threads over `CreateThread` / `pthread_create` (1 MB stacks unless given; named by the thread itself with `SetThreadDescription` / `pthread_setname_np`); `start` owns the body delegate (`fn(target)`) and deletes it on the thread when it returns; Debug: a body that is not a live Construct is fatal error 12 |
| `rt_mutex_*`, `rt_cond_*`, `rt_event_*` | SRWLOCK / CONDITION_VARIABLE, pthread mutex / condition (CLOCK_MONOTONIC); events over a lock, a condition and a flag. Debug checks the Mutex's owner (fatal error 12) |
| `rt_tls_new(size)` / `rt_tls_get` / `rt_tls_free` | ThreadLocal: one block per thread, zeroed on first use, freed with the key |
| `rt_pool_run(body)` / `rt_pool_wait` / `rt_pool_size`, `rt_parallel_for(from, to, body)`, `rt_parallel_ranges(from, to, body)` | The pool (hardware threads - 1 workers, started on first use; `rt_exit` lets it finish its queue and joins it) and Parallel: chunks of `max(1, n / (8 * threads))` handed out by an atomic counter, the caller working too |

The thread block also changes three things around it. `rt_fatal` adds ` on thread "<name>"` on a thread other than the
main one, and the first thread to fail reports while another waits for the exit. The Debug allocator's live list and
quarantine are under a spin lock taken once `rt_thread_start` or the pool started a thread (before that a flag test),
and a live block's `freeSite` holds the runtime index of the thread that made it (the leak report names it; measured
cost in Threads.md 5). `rt_debug_thread_names` (a `char[8192]`, one line `<system id> <name>` per thread started, Main
first) is what the editor's debugger reads to name threads. The runtime's text buffer (`rt_env_get`, `rt_cwd_get`, ...)
is per thread.

The type registry is the COFF grouped section `.tti$m` and static constructors `.tsct$m`, bracketed by the
runtime's `$a` / `$z` entries (on Linux the ELF sections `treadle_ti` / `treadle_sct` between the linker's
`__start_` / `__stop_` symbols), so adding a unit needs no central table.

### 6.3 Calling conventions and C interop

* Treadle functions use the platform C calling convention (`win64`, later SysV) with `this` first.
  Treadle-to-Treadle calls pass structs as LLVM aggregates (clang applies no C ABI rules to IR it is
  handed). **Returning aggregates:** a result that is an aggregate (struct, tuple, nullable, fixed array,
  StringView, payload enum) of more than 16 bytes or of more than two scalars (a payload enum counts its tag
  and payload units) comes back through a hidden pointer, `ptr noalias sret(%T) align A`, the first
  parameter (before `this`, and before a delegate's target); the function stores the value there and returns
  `void`, and the caller passes a slot of its own frame and loads the value after the call. Direct, virtual,
  interface, function pointer and delegate calls, delegate thunks and the `[Export]` wrappers (which hand the
  C caller's `sret` pointer straight on) all follow the rule, so every function of one type has one
  signature. Two doubles, a StringView, `int?` and smaller results stay a first-class aggregate in registers;
  three doubles would otherwise come back with the third in x87 `st(0)`, and C returns such a struct through
  memory too (fixture `sretret`, with a C file on both sides). Calls to imported C functions get the win64 C ABI from the back end: 1/2/4/8-byte aggregates as
  integers, larger ones through a copy, `sret` returns, and for variadic arguments float -> double and small
  integers -> int; so a `[CRepr]` struct is passed exactly as C would pass it.
* `ref`/`out` are pointers. `Span<T>` and `StringView` are two-word structs (`ptr, i64`).
* **Vectors** across the C boundary (SIMD-and-Vectors.md 1.6) take clang's lowering of the same C prototype:
  win64 hands the vector type to LLVM as it is (`<4 x float>` direct; LLVM's Win64 convention itself passes 128-
  and 256-bit arguments through a pointer to a copy and returns them in XMM0 / YMM0); System V passes an 8-byte
  vector as one `double`, 16-byte ones in XMM registers, and a 32- / 64-byte argument as `ptr byval(<8 x float>)
  align 32` when the function's level has no AVX / AVX-512 (its result stays direct). A mask is refused at the
  boundary (T2302). Imports and `[Export]` wrappers follow the same rules; fixtures `simd-cabi` (x86-64-v2) and
  `simd-cabi3` (x86-64-v3) call C with `__m128`, `float2`, `int32x4`, `float3`, an 8-lane float both ways.
* A struct's (or an enum's) member function takes `this` as a pointer (`S*`). The Call's Receiver
  (`FnLowerer.CallNode`, `TreadleCompiler/src/LowerSheet.bf`): for a Mutating function it is the address of
  the place the Receiver names (`PlaceAddr`: a variable's slot, `slot.addr` of a parameter made a variable,
  `global.addr`, `field.addr` on an object or on a struct place's own address, chained, `this`, a struct
  Local's slot, `elem.addr` of an array, span or pointer element; Bind's `SheetResult.IsPlace` decides the same
  and refuses a temporary, T2272); for any other function the value is stored in an OutTemp slot of the node
  and that slot's address is passed (a copy); a Receiver that is already a pointer (`this` of a struct
  function) is passed as it is. The place's address is taken when the Call runs (Rule 5: the Receiver before
  the arguments), so a Get of the place read by a later flow node sees the change. A `ref` / `in` input wired
  from a Get uses the same `PlaceAddr`.
* C functions are declared as in the header (`declare i32 @puts(ptr)`); `stdcall`/`fastcall` only matter on
  32-bit and are recorded anyway.
* `[Export]` functions get the same win64 C ABI on the way in (a wrapper under the C name: 1/2/4/8-byte
  aggregates arrive as integers, larger ones as a pointer to the caller's copy, larger results through
  `sret`), so C can call them with `[CRepr]` structs by value. The front end fills them from the
  attribute: `[Export("name")]` on a static, non-generic function (Declare, T1076 otherwise; the name a C
  identifier, default the function's name) becomes the Sheet IR function's `export "name"`. The wrapper is
  `dllexport` on Windows, so a library (`kind library`) exports exactly these and `treadle_init` /
  `treadle_shutdown`; a console or windowed exe keeps the wrappers too (exported from the exe, as the
  `exports` fixture calls them).
* Delegates: `{ Header, ptr target, ptr fn }`; `invoke` calls `fn(target, args)`; a static function's delegate
  has `target = null` and a thunk (`fn.dthunk(target, args)` calls `fn(args)`); an instance function's `fn`
  is the function itself (its `this` is the target); a closure is its own target. Function pointers are raw
  `ptr`. `cmp eq` / `cmp ne` on two delegate values is delegate equality: the same object, or both non-null
  with the same target and the same `fn` (so two delegates of one static function are equal, two of one
  instance function are equal when bound to the same object, and a closure, its own target, equals only
  itself); null equals only null. Fixture `delegateeq`.

### 6.4 What Release code tells LLVM

What C code gets from its declarations and types, the back end states in the IR, so LLVM can keep values in
registers and inline across type units (Performance.md, "Before and after").

* **Allocation attributes.** `declare noalias nonnull ptr @rt_alloc(i64, i64) nounwind allocsize(0)`, the same
  for `rt_alloc_dbg` (both Debug and Release); `rt_alloc_with` is `noalias` with `allocsize(1)` but not
  `nonnull` (an allocator's Alloc may return null); the frees are `nounwind`. `noalias` says that no other
  pointer reaches a new block, so the fields of two Constructs never alias (the `generics` kernel's two
  accumulators stay in registers); `nonnull` holds because running out of memory ends the program.
  `treadle_rt.h` declares the same with `malloc`, `alloc_size` and `returns_nonnull`. A Local array's heap
  path goes through the same entry points.
* **Alias metadata** (Release; `!tbaa`, a tree under the root `Treadle TBAA`). Under the root: `omnipotent
  char` (aliases anything) and `vtable pointer`; under char one scalar node per LLVM access type (`i1`,
  `i16`, `i32`, `i64`, `i128`, `float`, `double`, `ptr`); `i8` is char itself, so byte buffers alias everything,
  as in C. A class or struct has a struct node: its fields at their offsets (scalar nodes, a struct field's
  struct node, char for other aggregates), a class with its base class's node first at offset 0 (a derived
  class's layout is flattened, so an access through the base type and one through the derived type meet in
  the tree). Tagged: a load or store through a `field.addr` of a class (`!{class node, scalar, offset}`, so a
  field of one class never aliases a field of an unrelated class), through a `field.addr` of a struct
  pointer (the scalar type only, `!{scalar, scalar, 0}`: such a pointer may come from a cast of other
  memory), an element of a Treadle array (its scalar type), an array's length (`i64`) and every vtable pointer
  store and load. Raw pointer loads and stores, `memcpy` / `memset`, payload enums, packed structs and whole
  aggregates carry no tag and may alias anything. The rule this needs from programs: memory reached through
  a field of a class or struct, or an array element, has that field's or element's type; reinterpreting it
  goes through a pointer (`cast T*`), which carries no tag. Fixture `aliasing` writes through one view and
  reads through another (two objects, one object passed twice, a base and a derived view, bytes over an
  `int[]`).
* **ThinLTO.** Release compiles every unit and the runtime with `-flto=thin`: the objects are LLVM bitcode, and
  lld optimises the whole program at the link, inlining functions of other types (`Vec3.Stepped` into the
  `structs` loop, the String calls of `strings`, empty constructors and destructors) with one backend thread
  per core (lld's default). The runtime's cache stamp names the flag; Debug is unchanged. Cost on the Ryzen 7
  7700, clean Release builds (no runtime cache): the link goes from about 70-100 ms to 85-155 ms (m4-breakout,
  25 units: 82 -> 155 ms), while compiling the units gets cheaper (the optimisation moves to the link), so a
  whole build stays the same or shorter (m1 298 -> 253 ms, m3-core 359 -> 291 ms, m4-breakout 487 -> 427 ms,
  the alloc kernel 283 -> 223 ms); a build with nothing changed still compiles and links nothing. A unit's
  object is compiled again when its `.ll` changes; a flag change alone is not seen there (Follow-ups.md,
  "Found by bench").
* **Code alignment.** The link passes no alignment option: LLVM's defaults (16-byte functions, loops as the CPU model
  says). Aligning every jump target or every function to 32 bytes was measured on all kernels and m6-vm and not
  taken (Performance.md, "The alignment policy, evaluated again"): the one best on m6-vm slows `virtual` by 13-17%.
* **Frame pointers.** `"frame-pointer"="all"` in Debug only (the debugger's stack walks); Release leaves them
  to `-O2`, as for C.
* **Target CPU.** Every function carries the attributes clang gives a C function compiled with `-march=<level>`,
  `"target-cpu"="<level>" "target-features"="<that CPU's features>" "tune-cpu"="generic" "no-trapping-math"="true"`
  (Debug and Release), where the level is the config's **`simd`** key (`x86-64`, `x86-64-v2` the default,
  `x86-64-v3`, `x86-64-v4`, or `native`, which the driver asks clang to name once per editor session:
  `TreadleBackend/src/Driver/SimdTarget.bf`); the runtime is compiled with `-march=<level>` (in its stamp and cache
  key) and the link passes it too (C sources compiled at the link). A changed level changes every unit's `.ll`,
  so every unit compiles again (SIMD-and-Vectors.md 1.7). The ThinLTO link compiles each function
  for the CPU its attributes name; without them it had no CPU model, so LLVM's loop unrolling (which asks the
  model for the loop buffer size) left small loops rolled: the `generics` kernel ran 1.2x C for that alone
  (274 -> 230 ms, C 229 ms). With the CPU named, the link may also inline the runtime into Treadle code;
  the calls of `rt_alloc`, `rt_free` and their `_dbg` / `_with` forms carry a call-site `noinline`
  (`attributes #2`), because with `calloc` / `free` in sight LLVM removes a Construct and Delete pair or a
  second Delete of the same object, and a Release double Delete must still reach the C heap's check (fixture
  `memory`, Toolchain.md "Release fatal errors").
* **Payload enums in memory.** A payload enum is loaded and stored one field at a time: the `i32` tag, then
  each `iA` unit of the payload area (`FunctionEmitter.LoadValue` / `StoreValue`: slots, `load` / `store`
  through a pointer, the `sret` result), put together and taken apart with `insertvalue` / `extractvalue`;
  the padding after the tag is never read or written. A whole-aggregate load and store (a Value copied from
  one stack element to another in an interpreter) becomes a `memcpy` in LLVM, copied in 8- or 16-byte pieces,
  and such a piece cannot be forwarded from the 4-byte tag store that wrote the value a few instructions
  earlier: the load waits until the store reaches the cache. Field by field, each load reads what one store
  wrote. m6-vm's 130-million-instruction loop: 247 -> 229 ms.
* **Delete of a class nothing derives from.** The IR program holds every class of the program, so a class
  that no class names as its base is final in effect. Release: Delete (and the `dtor` op) of such a static
  type calls its complete destructor directly instead of through vtable slot 1, and calls nothing when its
  chain has no destructor Sheet and no owned object or destructible struct field. A class with a derived class
  keeps the vtable call; Debug always does (a deleted object's poisoned vtable is what reports a use after
  Delete). Fixture `finaldelete`. A Construct still zeroes the object (`calloc`): taking `malloc` needs a
  proof that the constructor sets every field first, which the back end does not have.

## 7. Debug info and node mapping

Debuggers need `file:line`. Treadle has no text, so the compiler **generates a listing per unit** next to
its `.ll` (`build/<Config>/<Unit>.lst`): one line per node of the unit, in a stable order (Sheet by member
id, nodes by id), text `<SheetName> <nodeId> <kind> <subject>`. DWARF `DILocation`s point at that file and
line.

* Breakpoint on a node = breakpoint at `<Unit>.lst:<line of node>`; the editor keeps the map from the
  compiler's output (`build/<Config>/<Unit>.nodemap`, three columns `<sheetKey> <nodeId> <line>`: node ids
  are unique per Sheet only).
* A stop location maps back to a node through the same map; the Sheet opens on it.
* Pin values: each flow node's result slot and every local is a `DILocalVariable` named after the slot
  record's name (`"pet" local`, `"b7.result" pin`; [4](#4-sheet-ir)), else `<nodeId>.<pin>` from its
  `node` setting, else the slot id, so `frame variable` gives pin values without expression evaluation.
  The alloca is `%s.<id>.<name>`. A parameter that a `local` slot of its own name holds (one a Set writes)
  is described by that slot only, so the debugger lists it once.
* **Line rows.** Every op takes the line of its node; an op without one keeps the line before it. The
  function's entry code (slot set-up, the branch to the first block) is on the **Entry** node's line, so
  Step Into stops on the Entry. Every IR block starts a line row of its own: when its first instruction is
  on the line of the instruction before it, it gets column 2 instead of 1 (or back), so LLVM starts a new
  row and a jump into it (a loop's increment and test after the body) is a stop on the loop node, not the
  middle of the previous row. A region exit runs each Defer's test and body on the Defer's lines and each
  Local's destructor on the Local's line. Step Over from a For loop's last body node: the For (increment
  and test), then the body's first node; fixture `debuginfo`.
* **Parameters** (Debug): `this` and every parameter are stored to their own alloca at entry and described
  with `#dbg_declare`, so they stay readable after a call (the function keeps using the incoming values).
  The spills carry no line, so they belong to the prologue; one volatile store on the Entry node's line
  (`%entry.mark`) follows them, so Step Into stops on the Entry with the parameters already set.
  Release carries no variables.
* **Types**: a basic type is the C type of its size and encoding (`long long`, `int`, `signed char`,
  `char`, `char32_t`, `float`, `double`, `bool`) behind a `DW_TAG_typedef` with the Treadle name (`int`,
  `int32`, `int8`, `char8`, `char32`), because lldb rebuilds a base type from size and encoding and shows
  the C spelling; `int64` / `uint64` / `isize` / `usize` (the IR folds them into `int` / `uint`) are a typedef
  of that name when the slot or parameter record spells them so (`TypeText`). `char8*` reads as a C
  string. A class reference is a pointer to a structure of the class (`vtable`, then the fields, base
  fields first): `Core.String *` shows `mPtr` (a C string), `mLength`, `mCapacity`, `mInline` (the inline first buffer, `char8[24]`). `StringView` is a
  structure `{ char8* Ptr, int Length }`. A simple enum is an enumeration of its cases over its tag type
  (`(Dbg.Color) color = Green`). A payload enum is a structure `{ tag, payload }`: `tag` an enumeration of the
  case names (`<Enum>.Tag`, the case index as value), `payload` at the payload area's offset a union
  (`<Enum>.Payload`) with a member per case that carries one, named after the case: the payload itself for one
  value, else a structure `<Enum>.<Case>` of `item0`, `item1`, ... (`(Core.Option<int>) some = { tag = Some
  payload = (Some = 5) }`). A tuple is a structure named by its type text with `item0`, `item1`, ...; `T?` a
  structure `{ hasValue, value }` (listed in that order, laid out `{ T, bool }`); `T[N]` a DWARF array of N;
  `T[]` a pointer to a structure `T[]` = `{ vtable, length, elements }` whose `elements` is an array of unknown
  bound at the data offset, so `frame variable a->elements[2]` reads an element; a delegate type a pointer to
  a structure `{ vtable, target, fn }` whose `fn` is a function pointer, so lldb prints the function it calls
  (`fn = 0x... (prog.exe`Dbg::Program::Twice(long long) (.dthunk))`); `function R(A)` a function pointer. A
  generic instance is named by its instance (`Gen.Cell<int>`, `Core.List<Core.String>`). A static field (an IR
  `global`) is a DWARF global variable of its qualified name without a linkage name (`target variable` shows
  `(int) Dbg.Program.sCount = 42`; with a linkage name lldb would show it demangled, `Dbg::Program::sCount`).
  Fixture `debugtypes` (the backend self test checks lldb's `frame variable` and `target variable` output).
* Inlining is off in debug builds; `-O2` release builds carry line tables only (crash dumps still name
  nodes).

**Decision:** a listing file rather than a DWARF extension. Reason: every tool (lldb-dap, crash reporters,
`llvm-symbolizer`) works unchanged; the listing is also a readable dump of the program.

**Debug formats.** DWARF is the default (lldb and lldb-dap read it with full locals); CodeView / PDB is a
per-config option for Visual Studio, WinDbg and other PDB readers, set in the project file's config section
(`debugFormat dwarf|codeview|both`, `ProjectConfig.DebugFormatKey`; not set = `dwarf`; another value is a
build error). The IR chooses, not the command line: each unit's `!llvm.module.flags` carries
`!"Dwarf Version"` (DWARF), `!"CodeView"` (CodeView) or both (`both`: LLVM writes DWARF sections and
`.debug$S` / `.debug$T`). The link adds `-gcodeview -Wl,--pdb=<OutDir>/<Name>.pdb` and in Debug
`-Wl,-Xlink=-debug:symtab` (with a PDB lld drops the exe's COFF symbol table, where lldb names the
emitted C `main`, which has no DISubprogram; the flag keeps it and keeps the DWARF of a `both` build). A
Debug CodeView build compiles the runtime with `-gcodeview` (`both`: also `-gdwarf`); the runtime's stamp and
the link stamp include the format, a `dwarf` link deletes a PDB left by an earlier CodeView link, and each
link writes `debug-format.txt` next to the exe. `codeview` alone leaves only mingw's CRT DWARF in the exe,
which lldb would prefer, so the debugger passes the PDB (`target symbols add`); `both` needs nothing. Linux
ignores the setting (ELF, DWARF only). How each tool reads it: [Debugging.md](Debugging.md), "Using other
debuggers". The probes behind this (breakpoints by `.ll` line, file names that need not exist, locals
through `#dbg_declare` / `#dbg_value`, the CodeView module flag) are in [Toolchain.md](Toolchain.md), Probe 2.

## 8. C header import

The import layer (`TreadleCImport`, run by File > Import C Headers or `Treadle.exe --import-c`; the user
side is [C-Import.md](C-Import.md)) turns a `.cimport` set into the set's declarations, `<set>.cdecl`, which the
front end reads as the `C.<set>` pseudo-type: functions as `[Import]` static functions (flow nodes unless listed
`pure`), structs and unions with their layout, enums, typedefs, constants, and C variables.

**Decision: libclang (the C API) through Beef FFI**, not `clang -ast-dump=json`. Reason: the C API is
stable and documented; `-ast-dump=json` is explicitly not a stable format and produces hundreds of MB for
`windows.h`; libclang gives sizes, alignments, field offsets, calling conventions and macro definitions
through one in-process call with no text parsing on our side. llvm-mingw ships no `libclang.dll`: it comes
from the LLVM Windows release (MSVC build, same C ABI, callable from mingw and Beef code), loaded at run time,
so the editor starts and runs without it. `tools/probe/libclang_probe.c` lists the entry points bound.

| Step | libclang calls |
|---|---|
| Parse | `clang_createIndex`, `clang_parseTranslationUnit2` on a generated `__treadle_cimport_<set>.c` that includes each `header`, with the set's `define`s and `include` paths and the flags of 8.2, `CXTranslationUnit_DetailedPreprocessingRecord` |
| Walk | `clang_visitChildren` over `FunctionDecl`, `StructDecl`, `UnionDecl`, `EnumDecl`, `TypedefDecl`, `VarDecl`, `MacroDefinition`; `clang_Location_isInSystemHeader` decides whether a symbol belongs to the set or is only referenced |
| Types | `clang_getCanonicalType`, `clang_Type_getSizeOf`, `clang_Type_getAlignOf`, `clang_Type_getOffsetOf`, `clang_getFunctionTypeCallingConv`, `clang_getPointeeType`, `clang_getArraySize` |
| Macros | `clang_Cursor_isMacroFunctionLike` skipped; object-like macros are re-parsed with `clang_tokenize` and accepted when they are a single literal or a constant expression over accepted macros |
| Output | `<set>.cdecl` (or the platform's name, C-Import.md "Platform variants") in `--out` or `<project>/build/cimport`: a type file with C records, one file per set, written only when its bytes change. It is **not** remade by Build: the front end reads what is there (a checked-in `.cdecl` beside the set first) |

**Two FFI shapes**: on Windows the declarations spell out the Microsoft x64 convention for libclang's by-value
structs (`CXCursor`, `CXType`, `CXString` are passed as pointers to copies and returned through a hidden
pointer); on Linux they are System V declarations with the structs by value behind wrappers of the same names
([Linux-Development.md](Linux-Development.md), "C import").

### 8.1 The `.cdecl` records

A type file: `type <set> class`, namespace `C`, `static`, a `doc` line, then one `function` record per C
function (sorted by name; the record id is derived from the name, so ids stay put), each `static` with
`returns`, `cconv stdcall|fastcall` when not the C convention, `attr Variadic` for a `...` function, and
its `param` records. After the functions come the C type records, which the type-file reader keeps as records
it does not model and the front end's Declare reads (`TreadleCompiler/src/CRecords.bf`): a `cstruct` or `cunion`
is the value type `C.<name>` with its fields (Make / Break, pointers to it; a union, or a record whose fields
do not lay out naturally, reaches the back end as words of its size and alignment and its fields by offset), a
`cenum` an enum `C.<name>` with its values, a `ctypedef` a name for the type it stands for, a `cconst` a static
constant of `C.<set>` (lowered as its value). A record two sets both import is declared once.

```
cconst SDL_INIT_VIDEO uint32 32                 value: decimal integer, float, or a quoted string (type char8*)
cenum SDL_bool uint32                           underlying type
	value SDL_FALSE 0
cstruct SDL_Rect                                cunion for a union
	size 16
	align 4
	pack 1                                      only when the record is aligned below its fields (#pragma pack, packed)
	field x int32 0                             name, Treadle type, byte offset
cstruct SDL_Window
	opaque                                      declared, never defined: only pointers to it
ctypedef SDL_EventFilter function:int32(void*,SDL_Event*)
	cconv stdcall                               a function pointer typedef that is not cdecl
cvar small_global int32                         an extern variable
cvar errno int32                                a macro reading a variable through a function: (*_errno())
	via _errno deref                            the function gives its address: Get and Set
cvar stdout FILE*                               (__acrt_iob_func(1))
	via __acrt_iob_func 1                       the function gives its value (one integer argument): Get only
```

Each group is sorted by name; the file is in the codec's canonical form (reading and writing it back with
`TreadleCodec` gives the same bytes) and byte-identical on every run with the same headers and libclang. A
function pointer type cannot carry a calling convention in a TypeRef; only its `ctypedef` records one.

**C variables.** The import writes a `cvar`'s `via` function as a `function` record too, whether the set selects
it or not; the front end declares it but keeps it out of the Node menu when `only` / `hide` leave it out. Declare
makes each `cvar` a static field of `C.<set>` (`MemberSym.CVar`; [Language.md 2.7](Language.md#27-unsafe)).
Lowering reaches a plain one by its C symbol (`global C.<set>.<name> T import "<name>"` in the Sheet IR, an
external global in LLVM; mingw's auto-import resolves data in a DLL), a `deref` one through the address its
function returns, and calls a by-value one's function for its value (Set is T2219; section 4). Example: the m2
sample's `src/cvars.cimport` with `cvars.windows.cdecl` (small.h's `treadle_counter`, defined in its `counter.c`;
`treadle_limit`, a macro over `treadle_limit_get()`, so by value; `errno`; `stdout` with `fputs` and `fflush`), on
Linux `src/cvars.linux.cimport` with `cvars.linux.cdecl`, Sheet `M2.CVars.Run`, fixture `m2-cvars`
(`m2-cvars.linux.tir` on Linux, the same output). A set's `csource` files are compiled into the program by the
link's clang, with the link's target and flags (`-g` in Debug, `-O2` in Release); the fixture runner compiles
`<fixture>.c` beside a `.tir` the same way (`m2-cvars.c`).

**Build inputs and paths.** The front end collects `lib`, `bin` and `csource` from the program's sets
(`FrontEndBuild.LinkInputs`) into the program the back end builds (`IRProgram.LinkInputs`, `IRProgram.RunFiles`;
neither is part of the `.tir` text). `CImportSet.ExpandPath` / `ResolvePath` (`TreadleCore/src/Model/ProjectModel.bf`)
expand `${NAME}` / `${NAME:-fallback}` for the import (`include`) and for Build (`lib`, `bin`, `csource`). Platform
variants: `CImportFile.ForPlatform` / `ScanTakes`, `CImportFile.PlatformCDeclSuffix`, `Compilation.AddCImport` (the
`.cdecl` search order), `CImporter.CDeclFileName` (a platform file is not written when a shared `<set>.cdecl` in
the output folder already has the same bytes). File > Import C Headers on a project with no set:
`ImportHeader.CreateSet`, `ProjectFile.AddCImport`.

C vector types (`CXType_Vector`, `CXType_ExtVector`, and typedefs of them) map by their lane type and count to the
Treadle vector of that shape (`TreadleCImport/src/ImportVector.bf`): `__m128` is `float4`, `__m128d` `double2`,
`__m128i` `int64x2` (its declared lane), `__m256` `float8`, `__m256i` `int64x4`, `__m512` `float16`,
`float __attribute__((vector_size(16)))` `float4`, `ext_vector_type(3)` `float3`, a `char` lane `int8`; a shape
Treadle has no name for leaves the declaration out with the reason. Header intrinsics (`_mm_add_ps`, `static
inline`) are not imported: the vector operators and Core.Vector replace them. `TreadleCImport/fixtures/vectors.cimport`
and its `.cdecl` show each mapping.

### 8.2 Where libclang comes from

`LibClang.Load` (`TreadleCImport/src/LibClang.bf`, `Candidates`) tries, in order, and loads the first
`libclang.dll` that exists with `LoadLibraryEx(LOAD_WITH_ALTERED_SEARCH_PATH)`:

1. `TREADLE_LIBCLANG`: the DLL itself, or a folder holding it (or its `bin\`).
2. `tools\libclang\bin\libclang.dll` next to the running exe (a package, [Releasing.md](Releasing.md)) or in the
   source tree above it.
3. Next to the editor exe.
4. `TREADLE_DEV_LIBCLANG`: a developer-machine copy outside the checkout (the DLL itself, or a folder holding it
   or its `bin\`), for example the main checkout's `tools\libclang` when the editor runs from a worktree. A
   development convenience ([Toolchain.md](Toolchain.md)); skipped with `TREADLE_NO_FALLBACK=1`.
5. `C:\Program Files\LLVM\bin\libclang.dll` (the LLVM installer's; skipped with `TREADLE_NO_FALLBACK=1`).

On Linux it is `lib/libclang.so` of the LLVM root (the package's `tools/llvm`, else the distribution's), loaded
with `dlopen`. The builtin headers are the ones that belong to the loaded library (`<dll>\..\lib\clang\<major>\include`,
the major version from `clang_getClangVersion`). The parse runs with `-x c -std=gnu17 -target
x86_64-w64-windows-gnu -nostdinc`, then `-isystem` the builtin headers and the llvm-mingw sysroot
(`<llvm-mingw>\x86_64-w64-mingw32\include` when present, then `<llvm-mingw>\include`; the root is found as for
the back end, `LlvmRoot`), so `<stdio.h>` resolves to the same headers the programs are compiled against and
nothing of a host compiler leaks in. On Linux the target is `x86_64-pc-linux-gnu` with the system's glibc headers.

`scripts\get-libclang.ps1 [-Root <repo>]` installs the pinned copy under `<repo>\tools\libclang\` (git-ignored):

| | |
|---|---|
| Release | LLVM 23.1.3 (the clang version of llvm-mingw 20261006) |
| Archive | `clang+llvm-23.1.3-x86_64-pc-windows-msvc.tar.xz` from the llvm-project GitHub release, 901,331,280 bytes, sha256 `9ee6a2192fbb30c776415af529927f76ca6b5d1d55699bb1315f9878e610b5b8` (checked before anything is extracted; the `.tar.zst` of the release needs a larger zstd window than Windows' `tar` allows) |
| `bin\libclang.dll` | 89,376,256 bytes, file version 23.1.3, sha256 `745395b6706e0f67b6a6632a6cd3a1fadefedf9e4e7b16e1d53ba7afb18456ba`; imports only Windows DLLs (KERNEL32, ntdll, ADVAPI32, VERSION, OLEAUT32) |
| `lib\clang\23\include\` | clang's builtin headers, 322 files, 15,933,974 bytes |
| `include\clang-c\` | the C API headers (reference for the bindings), 13 files |
| Total | 336 files, 105,599,037 bytes |
| License | Apache-2.0 WITH LLVM-exception |

The download goes into a fresh `tools\libclang-download\` folder, which is deleted after the install
(`-KeepDownload` keeps it, and a later run reuses a kept archive whose sha256 matches).

### 8.3 Self test and numbers

`TREADLE_SELFTEST=cimport` (`TreadleEditor/src/ImportHeader.bf`, `SelfTestCImport`):

1. libclang loads; `tools\probe\headers\small.h` (set `TreadleCImport/fixtures/small.cimport`) imports to
   exactly `TreadleCImport/fixtures/small.cdecl` (`TREADLE_WRITE_FIXTURES=1` rewrites it), the same bytes on
   a second run, and the file reads and writes back byte for byte through the type-file codec.
2. `<stdio.h>`: `puts(char8*) int32`, `printf(char8*,...) int32`, `fopen(char8*,char8*) FILE*`,
   `fclose(FILE*) int32`, `FILE` a typedef of the struct `_iobuf`, `EOF = -1`.
3. `SDL.h` (`${TREADLE_SDL2:-<repo>/tools/SDL2-2.32.10}/x86_64-w64-mingw32/include/SDL2`, with
   `SDL_MAIN_HANDLED`): `SDL_Init(uint32) int32`, `SDL_CreateWindow(char8*,int32,int32,int32,int32,uint32)
   SDL_Window*`, `SDL_PollEvent(SDL_Event*) int32`, `SDL_Event` a 56-byte union aligned to 8, `SDL_Window`
   opaque, `SDL_Rect` fields at 0 4 8 12, `SDL_WindowFlags`, `SDL_INIT_VIDEO = 32`,
   `SDL_INIT_EVERYTHING = 62001`, and the time it took.
4. When the editor is opened on a project with C import sets: File > Import C Headers writes
   `build\cimport\<set>.cdecl` (or the platform's name) and the front end declares `C.<set>`.
5. Platform names: `cvars` is named `cvars.windows.cdecl` (Linux: `cvars.linux.cdecl`), `libc` `libc.cdecl`; an
   import of `cvars.cimport` into an empty folder writes exactly the checked-in platform file, and `sdl2.cimport`
   next to a copy of the shared `sdl2.cdecl` writes nothing new.
6. A project with no set: a copy of small.h in `<project>/include` gets `small.cimport` (`header small.h`,
   `include include`) and the project file's `cimport` line, imports to `build/cimport/small.cdecl`, and the front
   end declares `C.small`.

The samples' `TreadleCore\samples\libc.cdecl` and `samples\m1\libc.cdecl` are imported files, made with
`--import-c TreadleCore\samples\m1\libc.cimport --out TreadleCore\samples\m1`. Measured 2026-10-25 (Ryzen 7 7700,
libclang 23.1.3, Release editor, warm file cache):

| Input | Result | Time |
|---|---|---|
| small.h | 5 functions, 2 structs, 1 enum, 2 typedefs, 2 constants, 1 variable, no warnings | 35 ms |
| `<stdio.h>` | 157 functions, 4 structs, 2 typedefs, 24 constants; 6 warnings (5 macros, 1 for 68 static inline functions) | 32 ms |
| SDL.h | 838 functions, 96 structs / unions, 55 enums, 51 typedefs, 413 constants; 33 warnings (32 macros, 1 for 14 static inline functions) | 114 ms (parse 105, walk 8); the first run after a reboot reads the headers cold: about 1.1 s |
| libc set of the samples | 8 functions | 42 ms |

## 9. Incremental builds

* **Unit = one type file.** Each unit is one `.ll`, `.o`, `.lst` and `.nodemap` in `build/<Config>/`. Generic
  instantiations are emitted in the generic definition's unit (`linkonce_odr`, section 4), their shared type
  data in every unit that uses them. `clang -c` runs for stale units in parallel; the link runs when any `.o`
  or the link stamp changed.
* The design had a per-unit `.deps` file (the signature hash of every member the unit binds to, and the clang
  version). It was not built: the rule below gives the same answer with less machinery, except that a
  toolchain change alone does not recompile the units (the runtime's stamp does include clang; Force Build,
  Ctrl+F7, recompiles everything).
* **Build**: a unit is stale when its `.ll` text changed. The `.ll` carries everything the unit was
  lowered from (its type file, the `.cdecl` declarations and the core and `depends` code it reaches), so a
  change there that matters to the unit recompiles it. What the IR text cannot show reaches the link stamp
  (`build/<config>/link.stamp`): the front end hands the driver `IRProgram.InputStamps`
  (`FrontEndBuild.InputStamps`), one `<path>|<time>` line for the project file, each `depends` project file,
  each C import set file and its `.cdecl`, each `csource` file (compiled by the link's clang, so nothing else
  would notice it), and `core|<hash>` of the core library's file stamp; the driver adds them to the link
  stamp (`BuildOptions.Inputs`, `Builder.LinkStamp`), so a change to any of them links again without
  compiling a unit. A build with nothing changed emits, compares and links nothing (m2-frontend: about 10 ms
  in the back end with the Release editor, 20 ms with the Debug one, most of it the emit; after a `csource`
  change the link adds about 100 ms).
* The config's flags are part of the keys. Each config builds into its own `build/<config>/`, so switching
  configs never reuses another's objects. Within one config, the units' clang command (the clang path and
  `-O<optimize>`, `-g`, the section flags) is `build/<config>/obj/flags.txt`: a different one (`optimize 2`
  changed to `1`) makes every unit stale; it is written after all units compiled, so a cancelled build leaves
  them stale. The runtime's stamp holds its flags (checks included); the link stamp holds the kind, the
  optimize level, checks, debug info, the debug format, the config's settings line (its `define`s) and a
  library's export names. A `define` changes the Sheet IR of the units that read it, so they recompile by
  their `.ll`. Fixture: the front end's `fixtures/projects/config` (an unchanged Profile build does nothing;
  `optimize 2` -> `1` compiles every unit at `-O1` and links).
* Validate caches the type table between runs in the editor; only the edited type's Sheets are re-checked
  plus the units whose signature inputs changed. As built (`FrontEndServices.Current`,
  `TreadleCompiler/src/Incremental.bf`):
  * An edit inside Sheets (a node, a wire, a setting) re-binds and re-checks only those Sheets in the last
    compilation (`Compilation.Rebind`; their old results and diagnostics dropped).
  * A declaration change (a type's `DeclSignature`: header, members and their signatures, the Sheet list,
    Lambda Sheets, stateful nodes), a type file opened or closed (its document changes object) and a new
    type file (or a new untitled document) re-declare in place (`Compilation.Redeclare`): the changed types
    keep their `TypeSym` objects (so the interned `KType`s that name them stay valid), are emptied
    (`ResetType`; their old members and generic parameters are kept aside until the compilation goes,
    `DeadMembers`) and declared again with Declare's own steps, in Declare's order, for the changed types and
    their dependents: the types whose declaration names a changed type (or a new type's name) or whose
    constants fold from a changed type's constants (`MemberSym.ConstRefs`), then,
    transitively, the classes and interfaces that derive from one and the extensions of one; their constants
    are folded again (`FoldConstants`). An extension
    of a core type or a C record (whose own members stay) has its members taken out of that type and
    declared again. Then only these Sheets are bound and checked again: those of the re-declared and new
    types, the edited ones, those whose bound result refers to a re-declared type or a member of one (their
    nodes' members, subjects, pin types, generic maps and arguments: a generic instance over a changed type
    counts; a Math Expression's functions and fields, the constants its literals name), and those that name a
    changed or new type or member (a name that did not resolve may now); a
    document with Lambda Sheets binds whole. The diagnostics of the re-declared types (Declare's, found by the
    type's name) and of those Sheets are dropped first; the entry point is checked again.
  * The workspace compiles again (from scratch) when a type is renamed, removed or declared twice, a new type
    brings a new namespace, the project file or the C import sets change, a type file that was read goes
    away, or an extension of a core type adds fields or virtual functions; also after 50000 replaced members.
  * The folder is scanned again (`ProjectLoader.ListFiles`) only when the folder index changes; the type
    files a full compile would read are then compared with the compilation's units.

  Measured 2026-10-25 (frontend self test, Debug editor; a full compile against the incremental one, the same
  diagnostics both ways and again after undoing the change). The Release editor takes about half: m2-frontend
  4.6 ms for everything, 0.12 ms after a Sheet edit, 0.27 ms after a signature change, 0.19 ms for a new type.

  | Change | samples (6 types, 11 Sheets): full / incremental | m2-frontend (48 types, 77 Sheets): full / incremental |
  |---|---|---|
  | (a) an edit inside one Sheet | 2.2 / 0.23 ms (1 Sheet) | 8.0 / 0.26 ms (1 Sheet) |
  | (b) a signature change (a function's input becomes a double) | 2.1 / 0.38 ms (2 types, 7 Sheets) | 7.3 / 0.61 ms (2 types, 3 Sheets) |
  | a field added | 2.1 / 0.37 ms (2 types, 7 Sheets) | 7.3 / 0.58 ms (2 types, 3 Sheets) |
  | a type header change (an `implements` line) | 2.0 / 0.37 ms (2 types, 7 Sheets) | 7.6 / 0.59 ms (2 types, 3 Sheets) |
  | an extension of a core type changes a return type | - | 7.2 / 0.55 ms (1 type, 2 Sheets) |
  | (c) a new type | 2.1 / 0.17 ms (1 type, 0 Sheets) | 7.5 / 0.40 ms (1 type, 0 Sheets) |


## 10. The core library

The core library lives in `TreadleCore/core/` as graph files, one type per file, plus a few `[Intrinsic]`
functions the compiler implements and a C import set (`crt`) for what comes from the C runtime. Its API, who
owns what and what is missing are on the user page [Core-Library.md](Core-Library.md); this section is how the
compiler finds and compiles it. No Beef code is reused.

### 10.1 The files and how a program gets them

| File | What |
|---|---|
| `TreadleCore/core/Core.tproj` | The core as a project (`kind library`, `cimport crt.cimport`); opening the folder in the editor shows it |
| `TreadleCore/core/*.treadle` | 60 type files (the thread types since the threads wave: Thread, Mutex, LockGuard, Condition, WaitEvent, ThreadLocal, ThreadPool, Parallel, ParallelForEach) (Core-Library.md 4) |
| `TreadleCore/core/crt.cimport`, `crt.cdecl` | The `C.crt` set: `realloc`, `free`, `strlen`, `snprintf`, `getchar`, `exit`, `fopen`, `fclose`, `fread`, `fwrite`, `remove` (UCRT), `QueryPerformanceCounter` / `QueryPerformanceFrequency` (kernel32; on Linux the runtime defines them over `CLOCK_MONOTONIC`), and the runtime's own (`tools/runtime/treadle_rt.c`): `rt_arg_count` / `rt_arg`, `rt_fopen` / `rt_remove` (UTF-8 paths, `_wfopen` / `_wremove` on Windows), `rt_file_exists`,
 `rt_dir_exists` / `rt_dir_create` / `rt_dir_delete` / `rt_dir_open` / `rt_dir_next` / `rt_dir_close`, and since wave 3 `rt_parse_int` / `rt_parse_double`, `rt_ascii_ieq`, `rt_format_scan` / `rt_format_number` (AppendF), `rt_utf8_decode` / `encode` / `check` / `count`, `rt_env_get` / `set`, `rt_cwd_get` / `set`, `rt_exe_path`, `rt_machine_name`, `rt_is_windows`, `rt_proc_start` / `start_list` (an argument list, no shell) / `wait` / `exited` / `kill` / `output` / `close`, `rt_time_now`, `rt_sleep`. Written by hand (`pure` on the C functions that only read, or write the caller's local); nothing extra to link |
| `TreadleCore/core/crt.linux.cimport` | The set's Linux variant (the same names, so the same `crt.cdecl`; the platform-variant rule of C-Import.md): glibc gives the C functions, the runtime gives `QueryPerformanceCounter` / `QueryPerformanceFrequency` (the monotonic clock) and the `rt_*` functions (opendir, fork and /bin/sh, clock_gettime). Opening the core folder as a project skips it, as it skips `crt.cimport` |

**Every program depends on it implicitly.** `Compilation.AddCore` (`TreadleCompiler/src/Compilation.bf`) adds the
core's type files and its `crt` declarations before the project's own files; `Core.*` names resolve without a `uses`
line (Compiler.md 2). `CoreSource` (`TreadleCompiler/src/CoreSource.bf`) finds the files:

1. `TREADLE_CORE` (a folder), else
2. `core` beside the exe (a package), or `TreadleCore/core` of a development build's source tree (the exe three
   folders below it, `ToolDirs`; edits to the core take effect without rebuilding the
   editor), else
3. the copy compiled into `TreadleCompiler` (comptime `Embed`, the file list `CoreSource.Files`), so an installed
   editor needs no folder.

The documents are read once and shared by every compilation (the front end runs one at a time,
`FrontEndBuild.Lock`); a change of a file's size or time in the folder reads them again. A project's `depends` line
naming the core's `Core.tproj` (the samples' example project file has one) is skipped, and opening
`TreadleCore/core` as a project does not declare its files twice (`ProjectLoader`). A new core file is added to the
folder and to `CoreSource.Files`; the `core` self test fails while the built-in copy and the folder differ.

**In the editor** the core's types are in the Node menu's **Core** group (`Core | List`, `Core | Dictionary`, ...;
String and StringView under **Strings**, Math under **Math**). The `crt` set and the core's `internal` members
(`StringView.MatchesAt`, `Dictionary.FindSlot`, the enumerators' fields) are not offered.

### 10.2 How the core is compiled

* **Validate does not bind the core.** `Compilation.Run` binds and checks the project's Sheets only; the core's are
  bound and checked the first time Lower reaches them (`Compilation.CoreSheet`). The `core` self test binds all of
  them (`Run(true)`) and requires no diagnostic.
* **Only what is reached is lowered** (`TreadleCompiler/src/LowerCore.bf`, `CoreLowering`): a core function when a
  call names it, a core type's destructor and the functions its vtable and interface tables name when the type is
  used, `String.this(StringView)` and `String.View()` whenever String is (text literals, the String-to-StringView
  conversion and the back end's `args` call them by name), the static fields of a core type whose field is read.
  Each lands in the unit of the type that defines it (`unit Core.List "List.treadle"`), one function per instance:
  `Core.List<int>.Add(int)`, `Core.Memory.Resize<char8>(char8*,int)`. Generic functions with bodies work for the
  core (an instance per argument list); a project's generic functions still need a generic type around them.
  A core function's Lambdas are lowered with it (`CoreLowering.LowerLambdas`, Lambdas in Lambdas too): the closure
  class of a delegate Lambda and the Lambda's function, in the same unit; in a generic function they are one per
  instance, named with the function's arguments (`Core.Parallel.$lambda_c2<int>`, its `Invoke(int)`), so
  `Parallel.ForEach<T>` is a Local Lambda over `Parallel.For`.
* **Vector text** (`VectorFormat.treadle`): `String.Append<T>(value) where T : vector` calls the intrinsic
  `String.AppendVector<T>`, which writes `(`, each lane as `AppendValue` writes a value of the lane type, `, `
  between them and `)`, unrolled for the instance's lane count; AppendF's vector arguments take the same path.
* **Receivers without `this` in the back end.** The back end has no `this` for the built-in `StringView` (no `type`
  record) or for enums; their member functions (`StringView.IndexOf`, `Option<T>.Unwrap`) are lowered as static
  functions whose first parameter is the receiver's address (`StringView.IndexOf(StringView*,char8)`), which is what
  a call passes anyway (`ProgramLowerer.ThisAsParam`).
* **Pure and unsafe.** Reads of text go through StringView's Get [ ] (safe, so the queries are Pure value nodes);
  writes through a pointer are unsafe nodes inside an Unsafe Scope (`String.Append`), so the public functions are
  not unsafe to call. List and Dictionary keep their elements in arrays (`T[]`): Get [ ] on an array is safe and
  checked in Debug, and the storage is in the Debug leak report like any object.

### 10.3 What is intrinsic

| Function | Lowered to (`TreadleCompiler/src/LowerCoreOps.bf`, `LowerSheet.bf` `IntrinsicCall`) |
|---|---|
| `Console.Write(StringView)`, `WriteLine(StringView)`, `Error(StringView)` | `intrinsic console.write` / `console.writeline` / `console.error` (the runtime's `rt_console_*`) |
| `Math.Sqrt`, `Abs`, `Floor`, `Ceil`, `Round`, `Truncate`, `Sin`, `Cos`, `Pow`, `Exp`, `Log` | `intrinsic sqrt` / `fabs` / `floor` / ... (LLVM); `Abs(int)`, `Min`, `Max`, `Clamp` are `cmp` + `select` |
| `Memory.Copy`, `Set`, `Compare` | `intrinsic memcpy` / `memset` / `memcmp` |
| `Memory.ElementSize<T>` | `sizeof` |
| `Pointer.Add`, `Load`, `Store` | `elem.addr`, `load`, `store` |
| `Arrays.Set<T>` | `nullcheck`, `boundscheck`, `elem.addr`, `store` |
| `Arrays.Address<T>` (internal) | `elem.addr`, not checked (no caller in the core now) |
| `Arrays.Slice` (List's private `StorageSpan`, List.Slice's Span) | `array.span` with a start and a count (null and the range checked in Debug) |
| `Arrays.DestroyAt<T>` | for a struct element (not StringView): `nullcheck`, `boundscheck`, `elem.addr`, `dtor` (the struct's complete destructor; nothing when it needs none); nothing for other element types |
| `Arrays.Free<T>` | `free` (the storage without its elements' destructors; null does nothing) |
| `String.AppendValue<T>` | a call of the `String.Append` overload for T: int (any integer type and simple enums cast to it), float, double, bool, char8, char32 (char16 cast to it), StringView, String (through `View()`); another type appends `<its name>` |
| `String.AppendFormatted<T>` (internal; AppendF's placeholders) | a call of `String.AppendNumber(int / double / float, spec)` for a number (integers and simple enums as int); `AppendValue` for anything else, the spec ignored |
| `String.InlineBuffer` (private) | `field.addr` of `mInline`, cast to `char8*` (String's inline first buffer, below) |
| `StringView.Substring` | `load`, `extract`, `elem.addr`, `make` |
| `Hash.Get<T>` | an integer mix for numbers, characters, bools, simple enums and pointers; a call of the type's `GetHashCode()` otherwise; an object's address for a class without one |
| `Hash.Equal<T>` | `cmp eq`, or a call of the type's `Equals` (String's through its view) |
| `Runtime.Fatal`, `Atomic.*` | as in milestone 2 |

**String's buffer.** A String is `{ vtable, mPtr, mLength, mCapacity, mInline: char8[24] }` (56 bytes). It starts
with no buffer (`mPtr` null); `Reserve` points `mPtr` at `mInline` (capacity 24: 23 code units and the zero) for the
first need that fits, so a short String needs no heap block. Past that the text moves to a `realloc` block (the
inline bytes copied once) that grows to `max(2 * capacity, need, 16)`. The destructor frees `mPtr` only when it is
neither null nor `mInline`. The debugger reads the text through `mPtr` either way (`Summaries.bf`, Editor-Model.md).
`Concat` reserves `a + b + 1` once. `StringView.MatchesAt` (Equals, StartsWith, EndsWith, IndexOf, Replace) is one
`memcmp` through `C.crt.memcmp`, declared Pure in `crt.cdecl` because a Pure Sheet may not use the unsafe
`Memory.Compare`; the hash is FNV-1a in the Sheet's own loop (clang unrolls it).

**AppendF.** The generic `AppendF<A0..>` walks the format with `FormatNext` (one `rt_format_scan` per segment; the
literal run before a placeholder is appended with one `memcpy`) and hands each placeholder to `AppendSlot`, which
formats into the String itself: `AppendNumber` with an empty spec calls the plain `Append` (an integer: reserve 21
bytes, `rt_format_int`, two digits per step from a table; a float or double: reserve 32, one `snprintf` of `%.7g` /
`%.15g`), with a spec reserves 512 and calls `rt_format_number` (the format chosen once by the spec's letter;
integers in decimal through `rt_format_int` / `rt_format_digits`, never `snprintf`). A width is applied in place by
`AlignFrom`: it reserves `|width|` more and `rt_format_align` counts the code points written since the placeholder
started, moves them right and fills spaces in front, or appends the spaces. No temporary String is made.

Everything else in Core-Library.md 4 is Sheets. What still needs the C runtime goes through `C.crt`: String's buffer
(`realloc`), byte comparison (`memcmp`), floating-point formatting (`snprintf`), console input (`getchar`), the clock, the command line, `exit`, files
(`fread`, `fwrite`, `fclose`) and, through the runtime's own functions (one shape on Windows and Linux; UTF-8 paths
through the wide calls on Windows): opening and deleting files (`rt_fopen`, `rt_remove`), whether a file or directory
is there, making, deleting and listing directories; since wave 3 the number
parsers, AppendF's placeholder scanner and the number specs, UTF-8 decoding, encoding and checking, the environment,
child processes, the calendar clock and sleeping (10.1's crt row). The Sheets around them make the API: the
Result and Option values, the loops over code points, the padding, the ownership of what comes back.
`TreadleCompiler/src/CoreIR.bf` (milestone 1's String and `Console.WriteLine(int)` in hand-written IR) and
`CoreLibrary.bf` (the core as text constants) are gone: nothing is left that needs hand-written IR.

### 10.4 Tests

`TREADLE_SELFTEST=core` (`TreadleEditor/src/SelfTestCore.bf`): the core validates with no diagnostic (60 types, 339
Sheets); the built-in copy is the folder's; the folder opened as a project validates; every core file writes back
byte for byte; the Node menu offers the core under Core and hides `crt` and internal members; the twenty-six programs
of `TreadleCompiler/fixtures/core` (`args`, `collections`, `containers`, `dictionary`, `files`, `format`, `list`,
`math`, `moves` (a folder: a struct and its Main), `numbers`, `numformat`, `parse`, `random`, `result`, `sort` (a folder), `strings`,
`system`, `text`, `threads-basic`, `threads-cond`, `threads-fatal`, `threads-leak`, `threads-mutex`, `threads-parallelfor`, `time`, `unicode`) validate clean, build and run in Debug and Release against their `.expected`
(Debug exits with the leak count, so a pass is leak-free); the `TreadleCore/samples/m3-core`, `m3-files` and `m3-text`
samples run against `fixtures/core/<sample>.expected`. The back end's `floats` fixture (`TreadleBackend/fixtures`)
covers the float literal suffixes. The wave 3 fixtures: `parse` (every rule of 4.1, Overflow at both ends of int64,
InvalidChar positions, TryParse), `numformat` (each spec, alignment both ways, five and six arguments, broken
placeholders as text), `unicode` (bytes and code points, For Each over CodePoints, IndexOf(char32), Append(char32) and
U+FFFD, Validate of an invalid byte, non-ASCII console text), `system` (environment variables, the working directory,
the executable path, the machine name; the program starts itself as its child: captured output and exit code,
NotFound, Kill, output not captured; Time.Now / UtcNow and ISO 8601, Sleep), `containers` (BinarySearch, Slice and
Span, the HashSet operations, TryPeek).

`Treadle.exe --build-run TreadleCore\samples\m3-files` (Debug and Release alike) queues the words of a built-in
sentence (or of its arguments), counts them, keeps their first-seen order with a HashSet, writes the counts to
`m3-files-out/counts.txt` under the working folder, reads the file back with `File.ReadLines`, lists the folder and
removes it:

```
13 words, 10 different, 10 lines read back
  the 3
  quick 1
  brown 1
  fox 2
  jumps 1
  over 1
  lazy 1
  dog 1
  and 1
  naps 1
m3-files-out: counts.txt
removed: true true
--- exit code: 0
```

`Treadle.exe --build-run TreadleCore\samples\m3-text` (Debug and Release alike; on Linux the child is `echo`)
reads its arguments (or a built-in list) as numbers into a table, counts the code points of a non-ASCII text, runs
a child process and prints the year:

```
text    |kind   |     value
--------+-------+----------
12      |int    |        12
3.5     |double |      3.50
0x1F    |int    |        31
-7      |int    |        -7
abc     |-      | bad at 0
1e3     |double |  1,000.00
1'000   |int    |     1,000
4x2     |-      | bad at 1
zwölf   |-      | bad at 0
total   |       |  2,039.50
"Grüße aus Köln ✓": 21 bytes, 16 code points
child said "hello from a child process", exit code 0
year 2026
--- exit code: 0
```

## 11. Error model

```
Diagnostic { severity: Error|Warning|Note, code: "T0123", message,
             stage: Load|Declare|Bind|Check|Lower|Toolchain, type: "Game.Player", member: "f8d2a",
             node: "d4", pin: "b" | null, file, line, related: [Diagnostic] }
```

* Every diagnostic from Declare onwards has a type; from Bind onwards a member and a node; a pin when the
  problem is one input. The editor puts a problem strip under the node's header and rings the pin; Problems
  selects the node.
* Load errors have `file:line` only.
* Toolchain errors (clang or lld failing) are reported as one diagnostic on the project with the tool's
  output attached; they indicate a compiler bug or a broken install, never a user error, and the `.ll` is kept
  for inspection.
* `related` carries chains: generic instantiation sites, the two Delete nodes of a double free found by
  Check, the Local and its reader.
* `--build-run` prints each problem as `problem: error|warning <message> [<where>] node <id> pin <pin>` and
  exits non-zero. (A machine-readable `--json` output was planned and is not built.)
* Run-time fatal errors print `fatal: <message> at <Type.Member> node <id>` (Debug) and exit with code 3; under
  the debugger the editor stops on the node ([Debugging.md](Debugging.md)).

## 12. Toolchain requirements

| Tool | From | Used for |
|---|---|---|
| `clang.exe` | llvm-mingw `20261006-ucrt-x86_64` (clang 23.1.3) | `.ll -> .o`, linking (drives `lld`), compiling the runtime C files |
| `ld.lld.exe` | llvm-mingw | Linker (through clang) |
| `libclang.dll` | LLVM for Windows (MSVC build; llvm-mingw has none) | C header import (section 8.2) |
| `lldb-dap.exe` | llvm-mingw (the `C:\Program Files\LLVM` 22.1.8 build does not start on the dev machine: it needs `python311.dll`) | The debugger ([Debugging.md](Debugging.md)) |
| `lldb.exe`, `llvm-nm`, `llvm-pdbutil` | llvm-mingw | The `backend` self test and developer diagnostics; not packaged |
| `llvm-objdump`, `llvm-cxxfilt` | llvm-mingw (Linux: LLVM 22) | The Disassembly panel; packaged since 0.1.4-alpha |

On Linux the same roles are filled by the distribution's LLVM 22 (`clang-22`, `lld-22`, `lldb-22`,
`libclang-22-dev`; [Linux-Development.md](Linux-Development.md)). The toolchain root is found by `LlvmRoot` (`TREADLE_LLVM`,
`tools\llvm` next to the exe, `tools\llvm-mingw` above it, then the development machine's folder;
[Releasing.md](Releasing.md), "How the editor finds its pieces"). In the editor it is a project-independent
Toolchain row in Preferences (`TreadleEditor/src/Prefs.bf:296`).
