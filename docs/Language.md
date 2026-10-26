---
audience: developer
title: Language
summary: The semantics of the visual language Treadle: types, memory, generics, inheritance, enums, threads, errors, evaluation order, flow nodes, entry points, modules, and the glossary.
order: 1
---

# Language

Treadle is a visual programming language. **The graph is the program.** There is no textual source form,
no round trip to another language, and nothing is "generated code": the compiler reads graph files and
emits native code through LLVM. Programs run at native speed with no garbage collector.

The semantics follow the Beef language where a visual language has no reason to differ (value and
reference types, single inheritance with virtual methods, interfaces, payload enums, generics by
monomorphisation, manual `delete`, scoped allocation, `defer`, append allocation, debug-build memory
checks). Where the graph makes something unnecessary or unsafe, Treadle changes it; every such change is
marked **Decision** with its reason. Treadle does not use Beef's corlib or runtime: it has a minimal core
library of its own and a C interop layer, so libc, SDL or any C library is called directly.

Someone who knows a node-graph scripting editor should feel at home: flow pins carry the order statements run
in, value nodes compute, member calls have a Receiver, allocation is a node, variables are Get/Set nodes.
The words differ (see the [Glossary](#10-glossary)); the ideas do not.

## 1. Program structure

| Unit | What it is | Stored as |
|---|---|---|
| **Project** | A folder with a project file: name, output kind (console / windowed / library), entry type, imported C header sets, dependencies, build settings. | `<Name>.tproj` ([Graph-Format.md](Graph-Format.md)) |
| **Type** | A class, struct, interface, enum, delegate type, extension or node library (static class). One type per file. The compile unit. | `<Type>.treadle` + optional `layout/<Type>.layout` |
| **Member** | A field, property, function, constructor, destructor, operator, or event (delegate field) of a type. | A record in the type file |
| **Sheet** | The node graph of one function body (also: a getter, a setter, a constructor). | Records in the type file |
| **Namespace** | A dotted name declared in the type's header. Folders do not define namespaces; a new type defaults to the namespace of its folder path. | `namespace` in the type header |

**Decision:** one type per file, namespaces declared not inferred. Reason: the file is the unit of diff,
merge and incremental compile; folder moves must not change meaning.

A **node library** is a static class whose functions appear in the Node menu under their own category
(the original editor's Node Library idea, kept).

## 2. Types

### 2.1 Kinds

| Kind | Value or reference | Allocation | Inheritance |
|---|---|---|---|
| **class** | Reference (`T` is a pointer to an object with a header) | Construct (heap), Local (scope), Append (inside owner) | Single base class, virtual and abstract functions, interfaces |
| **struct** | Value (copied on assignment and when passed) | Inline: a local slot, a field, an array element; `Local` gives a pointer when needed | No base; may implement interfaces (calls bind statically) |
| **interface** | Reference to any class implementing it | None | May extend interfaces |
| **enum** | Value | Inline | None. Simple (named integers, optional `[Flags]`) or **payload** (each case carries a tuple of values; the enum is a tagged union) |
| **delegate** | Reference (an object holding a target and a function pointer) | Construct / Local like a class | None |
| **function pointer** | Value (raw pointer, C-compatible) | Inline | None |
| **tuple** | Value `(int x, float y)`; Make / Break of a tuple have one pin per element, `item0`, `item1`, ... | Inline | None |
| **array** `T[]` | Reference (object with length + elements) | Construct / Local, fixed length at creation | None |
| **fixed array** `T[N]` | Value, inline, `N` constant | Inline | None |
| **pointer** `T*` | Value | Inline | Only in `unsafe` Sheets ([2.7](#27-unsafe)) |
| **nullable** `T?` | Value (`T` + has-value flag) for struct/enum/primitive `T` | Inline | |
| **Span<T>** | Value (pointer + length), core library | Inline | |

Primitive types: `bool`, `int8 int16 int32 int64 int` (`int` = 64-bit, like Beef), `uint8 ... uint64 uint`,
`float`, `double`, `char8` (UTF-8 code unit), `char32`, `void` (return type only). `usize`/`isize` are
aliases for `uint`/`int` in the C import layer.

**Decision:** `int` is 64-bit (Beef). Reason: one less overflow trap for users; C `int` imports as `int32`.

### 2.2 Values vs references

* A **class** value on a pin is a reference. Two pins may refer to the same object; a Set on a field
  through one is seen through the other. `null` is a legal class value unless the pin type says otherwise.
* A **struct** value on a pin is a copy. Passing a struct to a function copies it; `ref` parameters pass it
  by reference (the pin shows a `ref` marker and needs a variable, as in the original editor). Functions that change
  their own struct's fields are marked **mutating** (Beef's `mut`); a Set on a field of a struct received
  by value changes only the copy, and the compiler warns when that copy is never read. A Set of a field whose
  Receiver is a place (a `ref` parameter, a local variable, a struct Local's object, a field of one) writes the
  place itself, so through a `ref` parameter the caller's variable changes.
* **Mutating calls change their Receiver's place** (Beef's `mut` receiver). A Call of a Mutating function
  passes the address of the place its Receiver names, so the change lands there: a local variable, a
  parameter (an Entry output or `Get param:`; the function's own copy, the caller's variable keeps its
  value), a static field, a field of an object, a field of such a place (chained: `this.mPair.mInner`), `this`,
  a struct Local's object, an element of an array, a span or a pointer (Get [ ]). A Get of the place read
  afterwards (by a later flow node, Rule 2) sees the change. **Decision:** a temporary Receiver (a Make, a
  call's result, a property, a Cast, a For Each element, a Get [ ] of a type with an operator [ ]) is an
  error, T2272 "cannot mutate a temporary" (Beef refuses it too). Reason: the change would be lost without
  a trace; Store in a local first when the copy is meant. A function that is not Mutating gets a copy of its
  Receiver, as before (it cannot change it: T2080), and calling a Mutating function on its own `this` (the
  Receiver unwired or wired from This) is an error, T2273 (Beef refuses it: `this` is read-only there).
* **This of a struct or an enum** is the receiver's place. Wired into an input that takes the type by value
  (a parameter, a Return, a Break, a Switch) it gives a copy of the value (T3064 when the struct has a
  destructor and is not Copyable); wired into a `ref` input it passes the place itself, which only a
  Mutating function (or a constructor) may do (T2231 otherwise). A `ref` parameter is written (Set
  `param:`) and passed on through the caller's place.
* **Nullability.** Class, interface, delegate and array references may hold `null` (Beef's rule). Reading a
  member through `null` is a **fatal error** with the node id in debug builds and undefined in release.
  **Decision:** no non-null reference types in the first version; a null test is an `==` / `!=` Operator
  against `null` feeding a Branch, or the **Is Valid** Operator (`valid`: not null, and in Debug not deleted), and `T?` covers
  value types. Reason: non-null tracking across graphs is a large feature; it is listed as an open question in
  `Roadmap.md` (private).
* **Nullable values** `T?` (a struct, an enum or a primitive `T` and a has-value flag): `==` / `!=` against the
  literal `null` test the flag; `==` / `!=` of two `T?` (or a `T?` and a `T`, which converts) are equal when both
  are null or both hold values that are equal, and need `T` to have the operator (T2133 otherwise). **Decision:**
  the Operator node with `null` rather than separate Has Value / Is Null nodes. Reason: it is the form class
  references already use, so one habit covers both. A `T` (or a literal) wired into a `T?` input becomes a `T?`
  with a value; the value comes back out through a Cast to `T` ([2.3](#23-conversions-and-cast)).

### 2.3 Conversions and Cast

Implicit conversions: widening integer and float conversions, `T` to `T?`, a class to its base or an
interface it implements, `null` to any reference, `T[]` to `Span<T>`, `String` to `StringView`, any pointer
to `void*` (unsafe only). Everything else needs a **Cast** node:

| Cast | Pins | Behaviour |
|---|---|---|
| Numeric Cast | `Value` in, `Result` out, Cast To | Truncates / converts like C. Debug: no check (Beef semantics). |
| Class Cast | `Object` in, `Result` out | Dynamic check through the type info; a value node whose `Result` is `null` when the check fails. **Checked Cast To** (`set checked`) is a flow node: flow in, `Succeeded` and `Failed` flow out, `Result` valid after `Succeeded`. |
| Unchecked Cast | unsafe | No check. |
| Enum to Integer / Integer to Enum | | Integer to Enum is unchecked (Beef). |
| Array to Span | `Value` `T[]` in, `Result` `Span<T>` out | The implicit conversion as a node: a Span over the whole array (its elements and its length, no copy). Debug: a null array is a fatal error naming the node. |
| Nullable to value | `Value` `T?` in, `Result` `T` out | The value a `T?` holds. A null is a fatal error naming the node (`cast of a null int? to int`), in both configurations (one branch). **Checked Cast To** (`set checked`) is the flow form: `Succeeded` with `Result`, `Failed` when the value is null. |

| Box / Unbox | `Value` struct in, `Object` out | **Decision:** boxing a struct into an interface or `Object` is explicit (a boxing Cast, a flow node like Construct) because it allocates. Reason: no-GC; hidden allocations would need hidden deletes. |

### 2.4 Generics

Types and functions take generic parameters (`List<T>`, `Max<T>(a, b)`), compiled by **monomorphisation**:
each distinct argument list is a separate type or function in the output. Constraints:

| Constraint | Meaning |
|---|---|
| `T : IFoo, IBar` | `T` implements the interfaces; their members are callable on `T` values with static binding |
| `T : class` / `T : struct` / `T : enum` | Kind |
| `T : Base` | `T` is `Base` or derived |
| `T : delete` | `T` values may be deleted by the generic code (a class, array or delegate) |
| `T : new` | `T` is a class or struct with a constructor without inputs: **Local `T`** makes one, **Construct `T`** too when `T : class` is also given (per instance, the type's constructor without inputs runs) |
| `T : operator T + T` and the other operator constraints | The operator exists; Beef-style |
| `T : vector` / `T : vector float` | `T` is a vector type (2.8); the second form also names the lane type (any lane type may follow `vector`). A `T` value takes the element-wise `+`, `-`, `*`, `/` and negation (the bitwise operators too when integer lanes are named); a number beside it splats into its lanes when the lanes are named (T2320 otherwise); the Core.Vector and Math vector functions take it (those that give or take a lane value need the lanes named). A comparison of two `T` would give a lane mask, which generic code cannot name (T2133: use `Vector.Equal`). A non-vector argument is T1007 |
| `const int N` | A compile-time integer parameter (fixed arrays, SIMD widths) |

Unconstrained `T` permits only: copy, compare for equality when `T` is a value type with `==`, pass along,
`default`. **Decision:** no duck-typed `var` constraint (Beef allows it); the Node menu cannot offer
members of an unknown type. A generic function's Sheet shows `T` pins in wildcard grey.

Generic instantiation errors are reported on the node that asked for the instantiation (the Call or
Construct), with the chain of instantiations in the message.

### 2.5 Inheritance, virtual functions, interfaces

* A class has one base class (`Object` when none is set in Type Settings). Fields are laid out base first.
* Functions are **virtual** when marked so, **abstract** when declared without a Sheet (the class is then
  abstract), and **override** when they replace a base function (the Outline shows them as Overrides). A
  function not marked virtual binds statically. `sealed` on a class or function forbids further overriding.
* **Base** node: `base` as a value, used as the Receiver of a call to run the base version.
* Constructors are not inherited; a constructor may chain to a base constructor (the **Base
  Constructor** node, `ChainCtor`, right of the Entry; the editor does not place one yet, Follow-ups.md) or to
  another constructor of its own type.
* Destructors (`~this`) are virtual and run on `delete` and at the end of a Local's scope: derived first,
  then base.
* A **struct** may have a destructor too: it runs when a Local of the struct's region ends, with the object
  or struct that holds it as a field, and for each element of an array of it. A struct is copied bit for bit, so
  a copy of one with a destructor is destroyed twice or never: Check warns (T3064) on a Set, a Call input or a
  Return that copies one from a variable, unless the struct has `[Copyable]`.
* **Interfaces** declare functions and properties. A class lists them in Type Settings; missing members are
  errors on the type (a quick fix that writes stubs, Implement Missing Members, is planned). Interface calls on
  an interface-typed Receiver dispatch through the interface table ([Compiler.md 6](Compiler.md#6-runtime-abi)).
  Interface members with a default Sheet are allowed (Beef has them).
* A **struct** implementing an interface is called statically; converting it to an interface reference
  needs Box ([2.3](#23-conversions-and-cast)).

### 2.6 Enums

Simple enum: named cases with integer values, an underlying integer type, optional `[Flags]`. Payload enum:
cases carry fields; the type is a tagged union. Nodes: **Make Case** (value node, one input per payload
field), **Switch** over the enum (one flow output per case, payload pins on each case output), **Is Case**
(value node: `bool` plus payload outputs readable only where the Branch said true). `Result<T, E>` and
`Option<T>` are ordinary payload enums of the core library.

### 2.7 Unsafe

Pointer arithmetic, dereference, unchecked casts, raw calls through function pointers of C types, address-of,
and `sizeof`/`offsetof` are **unsafe nodes**. They are allowed only in a Sheet whose function is marked
**Unsafe** in Properties, or inside an **Unsafe** block node (a Scope node with a flag). Anywhere else the
node shows an error. Imported C functions that take or return pointers are callable without an unsafe
marker (the call itself is safe to make; what is done with the pointer is not). **Decision:** C calls are
not unsafe by default. Reason: otherwise every libc call needs an unsafe block and the marker loses meaning.

C calls (the front end, milestone 2): a C function's `T*` input wired from a variable of type `T` (a local, a
parameter, a field) gets the variable's address, as a `ref` input does (`SDL_PollEvent` filling a local
`SDL_Event`); a variadic function (`printf`) takes extra inputs named `va0`, `va1`, ... after its own, each
promoted as C does (`bool`, `char8` and integers below 32 bits to `int32`, `float` to `double`), a text literal
on one being `char8*`. The C records of an import set are types of the `C` namespace: `C.SDL_Event` (a struct
or union with its fields, Make / Break), `C.SDL_EventType` (an enum), `C.div_t` (a typedef: the type it names);
its constants are static constants of the set (`C.sdl2.SDL_INIT_VIDEO`).

**C variables** (`cvar`, [C-Import.md](C-Import.md)): an imported `extern` variable is a static field of its set
(`C.cvars.treadle_counter`), read with Get and written with Set (a compound Set too, and a `ref` / `T*` input
gets its address), without an unsafe marker: the variable itself is shared C state, as a static field is. A
variable C reaches through a function (`errno` is `(*_errno())`, `stdout` is `(__acrt_iob_func(1))` on Windows)
is the same: Get calls the function, and Set writes through the address it gives (`errno`); one the function
gives by value (`stdout`) cannot be set (T2219).

### 2.8 Vectors (SIMD)

Vector types are **primitives** that compile to SSE / AVX registers (the design and its reasons:
[SIMD-and-Vectors.md](SIMD-and-Vectors.md)):

* **Names.** The lane type followed by the lane count, with an `x` between them when the lane type ends in a
  digit: `float2` ... `float16`, `double2` ... `double8`, `int8x16`, `int32x4`, `uint8x16`, `int64x2`, and the lane
  masks `bool2` ... `bool64`. Lanes: 2, 3, 4, 8, 16 (8- and 16-bit lanes also 32 and 64); a vector is at most 64
  bytes. `int` / `uint` are no lane types: `int4` is T1090 ("int32x4 or int64x4"), as is any name of that shape that
  is no vector (`double16`, `float5`). `Vector<float,4>` is the same type as `float4` (read, written short; T1091
  when its arguments are no lane type and count).
* **Layout.** A vector is N lanes in memory (3 lanes take the room of 4: `float3` is 16 bytes), aligned to
  min(size, 16) everywhere: fields, arrays, Locals. A mask takes one byte per lane.
* **Values.** Vectors are value types: copied, passed in registers (never through a hidden result pointer),
  usable as fields, array elements (`float4[]`, `List<float4>`), generic arguments, nullables; hashable and
  equatable (`HashSet<float4>`: every lane equal; the hash is FNV-1a over the bytes, so `-0.0` and `0.0` hash
  differently).
* **Literals.** On a vector input: the lanes separated by commas, no spaces (`in v 0,1,0,0`; `true,false,true,true`
  for a mask), or one value for every lane (`in scale 2`).
* **Operators** work lane by lane on two vectors of one type; a scalar (or a literal) on the other side fills
  every lane (`v * k`). Float lanes: `+ - * / %`, negation, comparisons; integer lanes also `& | ^ ~ << >>`
  (signedness from the lane type); masks `& | ^ !` and `== !=`. A comparison gives a **lane mask** (`float4 < float4`
  is a `bool4`), not a bool; `&&` and `||` on masks are T2300 (combine masks with `&` `|`, test them with
  `Vector.Any` / `Vector.All`). Two vectors of different types are T2320 (Cast one), an operator the lanes do not
  have T2321. There is no floating-point contraction: `a * b + c` is two roundings at every `simd` level; the
  single-rounding form is `Math.Fma`.
* **Select** with a mask condition picks lane by lane, and both inputs are made (no Rule 4 short cut); its inputs
  are vectors with the mask's lane count (T2322).
* **Make / Break** of a vector type have one pin per lane: `x y z w` for 2 to 4 lanes, `lane0 ... laneN-1` above.
* **Swizzle** (`set lanes zyx`: `value` in, `result` out) picks lanes by the letters `x y z w` (one letter gives
  that lane's value); **Shuffle** (`set mask 0 4 1 5`: `a`, `b` in, `result` out) picks lanes of two vectors by
  number (0 to N-1 from `a`, N to 2N-1 from `b`). A letter or lane the vector does not have is T2301, a Shuffle of
  two vector types T2323, a Swizzle of a value that is no vector T2324.
* **Cast** between vectors of one lane count converts each lane as the scalar Cast does; `set kind bits`
  (Reinterpret) gives the same bytes as another vector of the same size. Anything else is T2325.
* **Core.Vector** (Calls; the vector type follows the vector wired in): `GetLane(v, i)`, `WithLane(v, i, s)`
  (Debug: an index outside the lanes is a fatal error naming the node; a constant index outside is T2301),
  `Sum`, `Product` (floats: in a fixed pairwise order, `(l0 + l2) + (l1 + l3)`), `MinLane`, `MaxLane`, `And`, `Or`,
  `Xor` (integer lanes; T2328 for other lanes), `Any(m)`, `All(m)`, `Bitmask(m)` (lane 0 the lowest bit),
  `Equal(a, b)` (every lane), `Splat<float4>(value)`, `Load<float4>(span, index)` and `Store(v, span, index)` (a
  flow node; Debug checks the span), `LoadPtr<float4>(ptr)` / `StorePtr(v, ptr)` (unsafe), `Dot`, `Length`,
  `Normalize`, `Cross` (3 or 4 lanes; the 4th is 0), `Lerp`. A function the type it makes cannot be told from its
  inputs names it (`Load<float4>`, or `set type float4`; T2326); a span of other lanes is T2327; an unknown function
  T2329.
* **Core.Math** functions take vectors too and work lane by lane: `Sqrt Abs Floor Ceil Round Truncate Sin Cos Exp
  Log Pow Min Max Clamp Lerp Fma CopySign` (float lanes; `Abs Min Max Clamp` integer lanes too). `Min` / `Max`
  keep the scalar rule: a NaN lane takes the other operand.
* **C.** A C function or an `[Export]` takes and returns vectors as C does (`__m128` is `float4`, `__m256` is
  `float8`, a `vector_size` / `ext_vector_type` vector its lane type and count); a mask cannot cross the boundary
  (T2302). On Linux a 32-byte vector argument of an import at a level without AVX is a warning (T3090).
* **Target.** The project config key `simd` (`x86-64`, `x86-64-v2` the default, `x86-64-v3`, `x86-64-v4`,
  `native`; [Graph-Format.md 5](Graph-Format.md#5-project-file-namevproject)) is the CPU level the program is
  compiled for. Wider vectors work at every level (a `float8` is two SSE operations below AVX).

## 3. Memory model and ownership

Treadle has **no garbage collector**. Memory is owned by whoever allocated it, or by the scope that
allocated it, and is freed exactly once.

| Node | Kind | What it does | Freed |
|---|---|---|---|
| **Construct `T`** | Flow node with `Object` output | Allocates `T` on the heap with the default allocator, runs the chosen constructor. One input per constructor parameter. | By a **Delete** node, by an owner's destructor, or never (a leak, reported in debug builds) |
| **Local `T`** | Flow node with `Object` output | Allocates `T` in the current **region** (Beef's `scope`), runs the constructor. For a struct `T` the output is the struct itself (a value), the slot is a local. | When control leaves the region ([5.3](#53-regions-and-scoped-lifetimes)); destructor runs |
| **Local `T` (function scope)** | Local with "Lives until the function returns" ticked (Beef's `scope::`) | As Local, slot in the function's own region | When the function returns |
| **Append `T`** | A field setting, not a node: "Stored inside the owner" | The field's object lives inside the owner's allocation | With the owner |
| **Delete** | Flow node, `Object` input | Runs the destructor, frees the memory. `Delete` of `null` does nothing. | - |
| **Defer** | Flow node with `Deferred` body and `Completed` | Runs the Deferred body when control leaves the region, last Defer first | - |
| **Defer Delete** | Shortcut for Defer -> Delete of one object | The most common Defer | - |
| **Owned field** | A field setting: "Owned, deleted with the object" | The type's destructor deletes it after the user's destructor Sheet runs | With the owner |
| **Construct with allocator** | Construct with an `Allocator` input (advanced, hidden by default) | Allocates a class object or an array (`Construct T` with a count) through a `Core.IAllocator` (its `Alloc(size, align)`; the memory is zeroed); Delete needs the same allocator (**Delete with allocator**: the destructor, then the allocator's `Free`). A Local takes no allocator | By the allocator |

**Decision:** Construct and Local are **flow nodes**, not value nodes as in the original editor. Reason: with
per-consumer re-evaluation of value nodes ([5.2](#52-value-nodes-and-evaluation-order)) a pure Construct would allocate once per consumer; an
allocation is a side effect and must run exactly once, at a defined point in the flow.

**Decision:** no automatic ownership analysis in the compiler beyond warnings. Reason: Beef's model works
without one; the debug runtime catches leaks, double frees and use after free at run time, with the
allocating node named.

Field ownership choices in Properties (the original editor's list, kept): Owned made here, Owned set later,
Reference, Appended, Value, Pointer (unsafe), Custom (a destructor Sheet does it).

**Where values live.** Every value is in one of five places; the editor names it on Construct and Local nodes
(a "lives in" badge) and in Properties' Storage row ([Debugging.md](Debugging.md), "Under the hood"):

| Place | What lives there | Made | Freed |
|---|---|---|---|
| **frame** | local variables, parameters, pin values, a Local with Until Return | when the function is entered | when it returns |
| **region** | a Local's object (or struct value); a Local delegate; a Local array (one over 16 KiB is put on the heap, still freed with the region) | when the node runs | when control leaves the node's region, destructor first |
| **heap** | a Construct's object; arrays made by Construct; a Construct delegate | when the node runs | by Delete (or the owner's destructor for an Owned field); never: a leak |
| **static** | static fields, constants | before Program Start | never |
| **inline** | a struct's fields, an Appended object, a struct field of a class | with the value around it | with the value around it |

A variable of a class type holds a reference (8 bytes) wherever it lives; the object is where its Construct or
Local made it. A struct is copied by value into whichever place holds it.

### 3.1 Debug checks

| Check | Debug build | Release build |
|---|---|---|
| Leak | At exit: every live heap object is listed with its type and the Construct node that made it | Nothing |
| Double free | Fatal error naming both Delete nodes | Undefined |
| Use after free | Deleted objects keep a poison header; a member access or virtual call through one is a fatal error naming the node; memory is quarantined before reuse | Undefined |
| Delete of a Local or Appended object | Fatal error | Undefined |
| Null member access | Fatal error with the node | Crash |
| Array or Span index out of range | Fatal error with the node and index (a Span's against its Length) | Unchecked (an Index node's `set checked` is read but not honoured yet: Release stays unchecked) |
| Array length below zero, or too large for memory (Construct / Local of an array) | Fatal error with the node and length | Fatal error with the node and length (one compare) |
| Integer overflow | Unchecked (Beef); checked arithmetic nodes are not offered yet | Unchecked |
| Fatal error | Message, node id, call stack; the IDE opens the Sheet on the node | Message and abort |

## 4. Members

| Member | Notes |
|---|---|
| **Field** | Type, access, static, const (a **constant**, [4.6](#46-constants)), initial value (a literal, an enum case, `default`, or an **init Sheet** for anything else), ownership. Get / Set nodes read and write it. |
| **Property** | Getter and setter Sheets (`value` is the setter's input), or auto: a hidden field `__prop_<Name>` (static with the property) that the compiler's `get$Name` / `set$Name` read and write; Make / Break of a struct leave it out (Make starts it at `default`). An interface property cannot be auto. Get / Set nodes look like a field's. |
| **Indexer** | A property with parameters; the Index node calls it. |
| **Function** | Parameters (value / `ref` / `out` / `in`), return type, further outputs are `out` parameters, modifiers (static, virtual, abstract, override, sealed, pure, unsafe, mutating, inline), attributes. |
| **Constructor** / **Destructor** | As above; a static constructor (no inputs) runs once before Program Start. |
| **Operator** | `+ - * / % == != < > <= >= [] ()` and conversions, as static functions with an Operator Sheet; the Operator node picks them up. |
| **Event** | A field of a delegate type with multicast semantics (`Add`, `Remove`, `Invoke`, `Clear`, `Count` nodes), marked Event (`attr Event`); [4.5](#45-events). |
| **Extension** | A type file with kind `extension` adds members to another type (its own, a core, or an imported one); the Node menu lists them under the extended type; [4.4](#44-extensions). |
| **Mixin** | **Decision:** not in the language. Reason: a mixin is text pasted into a scope; the graph equivalent is a function or a collapsed Sheet. |

### 4.1 Pure functions

A function marked **Pure** becomes a **value node** (no flow pins) at its call sites. Pure is **checked**:
a pure Sheet may not Set a field of `this` or of a reference, may not Construct (Local is fine), may not
call non-pure functions, and may not use unsafe nodes. It may use loops, locals and Branches. Properties
(getters) are pure by default. **Decision:** checked rather than trusted. Reason: pure nodes re-evaluate
per consumer ([5.2](#52-value-nodes-and-evaluation-order)); a hidden side effect would run an unpredictable
number of times.

### 4.2 Delegates and function pointers

* **Bind Function** node: picks a function (and a Receiver for member functions) and gives a delegate
  object; it allocates like a Construct (heap) or Local, chosen in Properties, and is then a flow node
  (decision 2026-10-24: allocation is a flow node, [3](#3-memory-model-and-ownership)); binding a static
  function to a function pointer allocates nothing and stays a value node. Call it with **Invoke**.
* **Lambda Sheet**: a node whose body is a nested Sheet (tab in the editor); it captures the locals it
  reads by value or by reference (Properties lists them; by-reference captures may not outlive the region).
  Allocated like Bind Function: with captures or an allocation it is a flow node, otherwise a value node.
* **Function pointer** (`function int(int)`): a raw pointer, value type; Bind Function of a static function
  gives one. Used for C callbacks; a calling convention may be set (`cdecl`, `stdcall`, `fastcall`).

As built (milestone 2): Bind Function without an Allocation gives a function pointer of a static function (or
a C function), a value node; `set alloc construct` (heap, Delete frees it) or `set alloc local` (freed when the
node's region ends) gives a delegate of a static, member, virtual or interface function (a virtual or interface
function is resolved from the Receiver when bound); functions with `ref` / `out` inputs are not bound. A struct's
(or an enum's) function is bound to the struct's **address**, not a copy, so Invoke sees and changes the variable
itself: the Receiver is a variable (a local, a parameter, a field, a static field) or `this` of a struct function.
A local, a parameter or `this` dies with the function, so that delegate must be Local (T2217); a field of an object
or a static field may be held by a heap delegate (which must not outlive the object, like any reference). A
Receiver that is a value and not a variable (a Make, a call's result) is copied into a temporary of the function
first, which a struct with a destructor allows only when it is `[Copyable]` (T2218: the copy would be destroyed
twice or never); that delegate is Local too. A delegate type (a type file of kind `delegate`, `signature int(int)`) is its signature: its pins and
every `delegate:int(int)` pin take each other. A Lambda node says what it gives with `set type` (a delegate type,
or a `function:` type for a C callback), names its inputs with `set inputs x y` (`p0`, `p1`, ... when not named;
they are the Lambda Sheet's Entry outputs) and how a capture is held with `capture <name> by-ref` (by value when
not said). Its captures are what the Lambda Sheet reads of the function: its locals, its parameters, `this`; a
delegate Lambda allocates (`set alloc construct|local`, a flow node), a by-reference capture needs `local`
(T2198), and a Local delegate is checked like a Local object (not returned, not deleted, not read outside its
region). A function pointer Lambda captures nothing and is a value node. **Invoke** takes the delegate and its
inputs `arg0`, `arg1`, ...; an Invoke of a function pointer is an unsafe node.

A Lambda inside a Lambda Sheet captures what any Lambda does: the function's locals, its inputs and `this`,
and also the inputs of the Lambdas around it (a `Get param:<name>` finds the Sheet's own input first, then the
nearest enclosing Lambda's, then the function's). What the inner Lambda reads of the function (or of a Lambda
further out) is a capture of each Lambda in between too, held in its closure so the inner one is filled from
it when it is made; Properties lists such a capture on the outer Lambda as "for a Lambda inside". By value, the
inner Lambda copies the value the outer one holds. By reference (a Local inner Lambda, as anywhere) it writes the
variable itself: allowed for an input of the Lambda around it, and for a variable the Lambda around it also holds
by reference (so every Lambda on the way is Local and freed before the variable's region ends); when the outer
one holds it by value the inner by-reference capture is refused (T2198: it would write the outer closure's copy).
A Lambda in a generic type is compiled per instance of the type: its closure, its function and its captures
take the instance's type arguments (`Box<int>` and `Box<int16>` each have their own). In the editor a Lambda
dragged out of a delegate or function pointer input gives that input's type (the delegate type of that
signature when exactly one is in scope), names its inputs `a`, `b`, ... (written in `set inputs`; the
Lambda Sheet's Entry gives them), is Local when it feeds a call (Construct otherwise; no Allocation for a
function pointer), runs right before the node it feeds, and its Sheet starts with a Return when the signature
returns something. A by-reference capture is offered only on a Local Lambda; leaving Local turns the
by-reference captures into by-value ones.

### 4.3 Atomics

`Core.Atomic` offers **Atomic Load**, **Store**, **Add**, **Sub**, **And**, **Or**, **Xor**, **Min**, **Max**,
**Exchange**, **CompareExchange** (the old value, and `replaced`) and **Fence** as Calls. Each takes the
variable it works on by ref (`location`: a local, a parameter, a field or a static field; no unsafe node is
needed) and a memory order as its `set order` setting: `relaxed`, `acquire`, `release`, `acqrel` or `seqcst`
(default). They work on integers of 8 to 64 bits, pointers and references (Load, Store, Add, Sub and Exchange also
on floats; T2261 otherwise); a Load cannot be `release` / `acqrel`, a Store cannot be `acquire` / `acqrel`
(T2260). The read-modify-write calls return the old value.

### 4.4 Extensions

An **extension** is a type file of kind `extension` whose `extends` line names another type: a class, a struct or
an enum of the program (the project's own, a dependency's, the core library's, or an imported C record such as
`C._div_t`). Its members become members of that type, as Beef's `extension` does: a Call, Get or Bind names them
on the extended type (`Call Core.String.Doubled`, `Call C.div_t.Total`), `this` in their Sheets is the extended
type, and the Node menu lists them under it. A generic type is extended with its own parameters (`extends
Core.List<T>`, or `extends Core.List`): the extension's Sheets use `T`, and are compiled for each instance the
program uses. Names in an extension resolve in its own namespace and `uses` lines first, then the extended type's;
its problems are reported on the extension's file. Its members belong to the project that declares the extension
(`internal` is that project's); private members of the extended type are visible to it.

The rules:

* **Fields** (and the hidden fields of an auto property or a stateful node such as a Gate) only on a type of the
  extension's own project (T1071): another project's type, a core type or a C record has its layout already. A
  **constant** ([4.6](#46-constants)) has no storage in the type: an extension may add one to any type (`TwoPi` to
  `Core.Math`).
* No enum cases, constructors or destructors (T1072): they stay in the type's own file.
* Functions have Sheets and bind statically (T1073): an extension adds no virtual, abstract or override function.
  Operators and properties may be added.
* An interface, a delegate type, a C import set, an opaque C record or another extension cannot be extended
  (T1070); a member the type already has with the same signature is T1031.

**Decision:** extensions are file-level, like every type (one per file), and do not change a type's layout outside
its project. Reason: a type of another project (or the core, or C) is laid out and compiled once; adding fields
there would change every user of it.

### 4.5 Events

An **event** is a field of a delegate type (one returning nothing) marked **Event** (`attr Event`) in a class. It
holds any number of handlers, delegates of that type, and calls all of them in the order they were added. Its
nodes are Calls on the event, with the object as the Receiver (unwired: `this`):

| Node | Subject | Pins | What it does |
|---|---|---|---|
| **Add** | `<Type>.<event>.Add` | `in`, `receiver`, `handler` -> `then` | Adds the handler at the end; the event owns it from now on |
| **Remove** | `<Type>.<event>.Remove` | `in`, `receiver`, `handler` -> `then`, `result` (bool) | Removes the handler that is that delegate object and deletes it; `result` says whether the event held it |
| **Invoke** | `<Type>.<event>.Invoke` | `in`, `receiver`, `arg0`, `arg1`, ... -> `then` | Calls every handler in order with the inputs (each evaluated once); a handler may Remove itself (the next one is then skipped for this Invoke) |
| **Clear** | `<Type>.<event>.Clear` | `in`, `receiver` -> `then` | Deletes every handler |
| **Count** | `<Type>.<event>.Count` | `receiver` -> `result` (int) | A value node: the number of handlers |

**Ownership:** the event owns its handlers. Add takes a delegate made with Allocation construct (a Local one is
freed with its region, T2216); Remove and Clear delete the handlers they take out, and the owning object's
destructor deletes those still there (the event's storage is a struct field whose destructor runs with the
object). So a handler is made, added and forgotten; the one that may need removing is kept in a field or a local
until then. An event is not read or written with Get / Set (T2215). Only Count may be used in a Pure function or a
getter (T3041). The storage is the core type `Core.Event<D>` ([Core-Library.md](Core-Library.md)): a list of the
handlers; Invoke is compiled into a loop that calls each one.

Declare rules: the field's type is a delegate type returning nothing (T1074; Invoke has no one result to give) and
the field is an instance field of a class (T1075: a struct would copy its handlers, and a static event would keep
them past the program's end).

### 4.6 Constants

A field marked **const** is a **constant**: a value of its type that the compiler knows, not storage in an object.
It belongs to the type (static, whether the record says so or not), nothing Sets it (T2078) and it is not passed
to a `ref` input (T2231).

* **Value.** Its `init` is a **constant expression**: the Math Expression grammar ([5.6](#56-math-expression))
  over literals (numbers with their `f` / `d` suffixes, `true` / `false`, texts), other constants (`Rows` of the
  same type or its bases, `Game.Rows`, a C import set's `C.cstd.RAND_MAX`), enum cases (`.Red` where the type
  says which enum, `Color.Red`) and the Math functions that are plain arithmetic (Sqrt, Abs, Floor, Ceil, Round,
  Truncate, Sin, Cos, Exp, Log, Pow and `**`, Lerp, Sign, IsNaN, Min, Max, Clamp). Declare folds it once into one
  literal (constant folding, [Compiler.md](Compiler.md#2-type-table-and-binding)), the constants it names first.
* **Types.** A number, a bool, a character, a case of an enum without payloads, or a text (String, StringView, a
  C `char8*`); anything else is T1083. The value converts to the declared type as a literal does: to any number
  type it fits (`const uint8 Low = Mask & 0xFF`), never from a fraction to an integer; a value of another kind is
  T1084 (`const int Flag = true`). Integer arithmetic is checked: an overflow, a division by zero or a value outside
  the declared type is T1082 (a shift and `~` wrap as the machine does).
* **Problems.** T1080: the init is not constant (it reads a field or names something that is not a constant, a
  function that is not folded, a text that does not parse, with its column); T1081: constants whose inits name each
  other (the cycle is listed); T1082: out of range; T1083: a type a constant cannot have, `elements` on a field
  that is not a const array; T1084: a value of another kind.
* **Reading one.** A **Get** node (the Node menu offers Get only: a value, no Set) gives the value; Lower puts the
  literal where the Get is read (a text read as a String is a Local String, as a text literal is). A literal on any
  input may name a constant (`in count Rows`, `in color Palette.Main`): Bind reads its folded value. A constant has
  no storage until its address is taken (an `in` input, a C `T*` input): then it is a read-only global with its
  value.
* **Const arrays.** A const field of type `T[]` lists its values in an element list instead of an init
  (`elements 1, 2, Rows * 2 - 1`, [Graph-Format.md](Graph-Format.md#31-records)); each element is a constant
  expression of `T` (a number, bool, character, enum case or StringView text: an element is never an object, so not
  a String). Its Get gives a **`Span<T>`** over a read-only global `T[N]`, made with no allocation: Index, For Each
  and `Length` read it; writing through its pointer (unsafe) faults. A const array is not one value: another
  constant's expression does not name it.
* **Vector constants.** A constant of a vector type ([2.8](#28-vectors-simd)) is folded lane by lane:
  `const float4 Up = float4(0, 1, 0, 0)`, `const float4 Lifted = Up * 2 + 1`, `const int32x4 Ones = 1` (one number
  fills every lane); its literal lists the lanes (`0.0,1.0,0.0,0.0`). A value of another vector type is T1092.
* **C import sets.** A set's `cconst` is a constant like any other: the same folding gives its value, and constant
  expressions name it.

**Decision:** a const array reads as a `Span<T>`, not as a `T[]`. Reason: a `T[]` is an object made on the heap or
in a region and deleted; a constant is never made, and a Span over read-only memory reads the same way (Index,
For Each, Length) without an allocation.

### 4.7 Threads

Threads are core library types ([Core-Library.md](Core-Library.md), Threads; the design is [Threads.md](Threads.md)),
not nodes of their own: a **Thread** is Constructed (a name and a stack size are optional) and **Start**ed with a body,
a `delegate:void()`; **Join** waits for it. A **Mutex** is held for a region with a **Local LockGuard** (a struct whose
destructor unlocks: the region that owns the Local is the critical section, and every way out of it unlocks);
**Condition**, **WaitEvent**, **ThreadLocal\<T>**, **ThreadPool** and **Parallel** (`For`, `ForRange`, `ForEach`)
complete the set; the [Atomic Calls](#43-atomics) are the interlocked operations.

* **Ownership.** `Thread.Start` and `ThreadPool.Run` own the delegate they are given and delete it after it ran, on
  that thread: it must be made with Allocation **construct** (a Bind Function or Lambda node with Allocation local
  wired into `body` / `work` is error T2224; a Local delegate that reaches them another way stops a Debug run with a fatal
  error when Start or Run is called; a Lambda dragged from their input starts as Construct). A Parallel body runs only during the call
  and is usually a Local Lambda, by-reference captures included. Objects may be made on one thread and deleted on
  another; a Local never leaves its thread's region (a Parallel body is the exception: the call returns only when it
  is done with it).
* **Memory model.** C11's, through LLVM: two threads accessing one location, one of them writing, with no order
  between them (Start, Join, a Mutex, a Condition or WaitEvent, an Atomic release / acquire pair, Parallel's return)
  and not both Atomic, is a **data race**, undefined behaviour in Debug and Release. Debug does not detect races.
* **Debug.** The allocator's checks work across threads (each thread keeps its own live list once a second thread
  started, Threads.md 5); a leak or a fatal error on a thread other than the main one names the thread; the debugger lists the
  threads and shows any thread's call stack ([Debugging.md](Debugging.md)).

**Decision:** threads are library types over the runtime, not language nodes (no Spawn or Lock node). Reason: a Thread
is an object with a lifetime (Construct, Delete) and a few calls, which the existing nodes express; the one thing a
graph needs that a call cannot give, a lock held exactly for a region, is what a Local struct with a destructor
already is.

### 4.8 GPU kernels (experimental)

**Experimental, NVIDIA only, not in a release** ([GPU-Compute.md](GPU-Compute.md)). A static function marked
**`[Kernel]`** (`attr Kernel`) runs once per index of a dispatch: `Kernel.Index()` gives the index (and
`BlockIndex`, `ThreadInBlock`, `BlockSize` its block), its inputs are Spans, numbers, bools, vectors and structs of
them, it returns nothing and writes its results into Span inputs (`Span.SetAt`). Its Sheet is a subset of the
language, checked at Validate (T2340-T2348): no allocation, no objects, strings, delegates or static fields, no C,
virtual or recursive calls, only the core's Math (the transcendental functions on float and double, not on
vectors), Vector, Atomic, Pointer, Kernel and the core structs. `Kernel.Shared<T>(count)` (`set type <T>`, the
count typed on the node) is memory shared by one block's runs and `Kernel.Barrier()` waits for all of them; a kernel
that uses either runs in whole blocks (its count a multiple of the block size). A Call of **`Kernel.RunCpu`**,
**`Gpu.Dispatch`** or **`Gpu.DispatchAsync`** (on a `GpuStream`) names the kernel with `set kernel
<Type.Function>`, optionally the block size with `set block <n>` (256), and takes `count` and the kernel's inputs.
RunCpu runs it on the CPU over the thread pool with every Debug check; Dispatch on an NVIDIA GPU through the CUDA
driver (a Span input takes a `GpuBuffer<T>` there, which stays on the GPU until `Download`), and on the CPU when
there is no GPU, so a program behaves the same either way. A check that fails on the GPU stops the program at the
next wait with `fatal: GPU: <message> at <Type.Function> node <id>` (exit code 3).

## 5. Sheets: flow, value nodes, evaluation order

A Sheet has one **Entry** node (the function's parameters as outputs, a flow output), any number of
**Return** nodes, flow nodes, value nodes, local variables, comments and knots.

### 5.1 Flow nodes

A flow node has a flow input and one or more flow outputs. It runs when flow reaches it, then follows
exactly one flow output. Flow outputs are **next** outputs (`Then`, `Completed`, `True`, `False`) or **body**
outputs that own a region (`Body`, `Loop Body`, `Deferred`, `Then 0..n`, case outputs).

Pin and output names in this document are the labels the editor shows. The format stores every pin under a
stable lower-case name (`in`, `then`, `done` for Completed, `body` for Body and Loop Body, `deferred`,
`true` / `false`, `case:<label>`, `receiver` for the Receiver, arguments by parameter name);
[Graph-Format.md 3.2](Graph-Format.md#32-node-kinds-and-their-subjects) lists them per node kind.

| Node | Outputs | Semantics |
|---|---|---|
| **Branch** | True, False | Evaluates `Condition` once, follows one output |
| **Sequence** | Then 0..n | Runs each output's region in order, then continues after the last; a region may not jump into another |
| **While** / **Do While** | Loop Body, Completed | Condition re-evaluated each pass |
| **For** | Loop Body (with `Index` output), Completed | `Start`, `Count` (evaluated once at entry), `Step` |
| **For Each** | Loop Body (with `Element`, `Index`), Completed | Over arrays, `Span<T>`, `String` (chars), any type with `GetEnumerator`: the **enumerator protocol** is an instance `GetEnumerator()` returning an enumerator **struct** (an object would be left for no one to delete) with `MoveNext() -> bool` (Mutating) and a `Current` property with a getter; `MoveNext` runs before each pass, `Element` reads `Current` |
| **Break** / **Continue** | - | Leave / restart the innermost enclosing loop region; error outside one |
| **Return** | - | Leaves the function with `Value`; runs pending Defers and region destructors |
| **Switch** | one per case, Default, Completed | Over integers, chars, strings, enums; payload pins on enum cases. On a `String` or `StringView` each case label is the text itself (a word of the record format: `case go`), compared by length and bytes in the listed order |
| **Scope** | Body, Completed | A region of its own (a block) |
| **Gate** | Exit, Completed | Runs Exit while open (open at the start unless `set start-closed`); Open / Close / Toggle Gate nodes change state |
| **Do Once** | Once, Completed | Runs Once until Reset Do Once |
| **Do N** | Do (with `Counter`: this run's number, 1..N), Completed | Runs Do the first N times, until Reset Do N |
| **Flip Flop** | A, B (`Is A` output), Completed | Alternates, A first |
| **Multi Gate** | Out 0..n, Completed | Next output per call; after the last only Completed runs until Reset Multi Gate, unless `set loop` starts over; `set random` picks among the outputs not run yet |
| **Defer** | Deferred, Completed | Deferred runs at region exit |
| **Call** (non-pure) | Then (+ enum-expanded outputs when `[ExpandEnumAsFlow]`) | Evaluates inputs, calls |
| **Set** | Then | Assigns `Value` to `Variable` |
| **Construct / Local / Delete** | Then | [Section 3](#3-memory-model-and-ownership) |
| **Result: match** | Ok (with `Value`), Err (with `Error`), Completed | Branch on a `Result` |
| **Try** | Then (with `Value`) | On `Err`, returns the error from the enclosing function (the function must return a compatible `Result`) |
| **Fatal** | - | Aborts with a message |

**State of Gate / Do Once / Do N / Flip Flop / Multi Gate** lives in a hidden field of the enclosing type
(static when the function is static), exactly as the original editor writes `__doOnce_N` fields; here the compiler
makes the field and the format records only the node. Properties offers a visible field instead.
**Decision (milestone 2):** the hidden field is per node and per object, named after the node so it can
be shown and named: `__gate_<node>`, `__doOnce_<node>`, `__doN_<node>`, `__flipFlop_<node>`,
`__multiGate_<node>` (private, made by Declare from the Sheets). A Gate keeps a `bool` (open), a Do Once a
`bool` (done), a Flip Flop a `bool` (A ran last), a Do N an `int` (runs so far), a Multi Gate an `int` (the
next output; with `set random` the outputs run so far as bits, and a hidden static `__multiGateSeed_<node>`
drives the pick, so the order is the same on every run). `set state <field>` (the State Field row) names
a field of the type instead, which must have that type. An Open / Close / Toggle Gate or Reset node
changes the node its State Field names (a visible field or the hidden name); without one it changes the
only node of its kind in its Sheet, else in the type, and two candidates are an error. A struct's
non-static function keeps no hidden state (the value would carry it): it names a field and is Mutating.
Reason: per-object state is what the user of a member function expects, and a name per node lets the
Properties panel show the state and an action node name it.

**Merging flow.** A flow input accepts any number of wires (what node-graph scripting users expect). A node reached from two
arms of a Branch runs after either arm. Its **region** is the innermost region that dominates both paths
([5.3](#53-regions-and-scoped-lifetimes)). **Decision:** merges are allowed. Reason: this is how
people wire graphs in practice; the compiler lowers to a join block, and dominance gives every node one region. A
node that several arms of a Switch or a Result: match (or a Gate) flow into, and nothing outside them, stays
inside that node: the flow that ends after it continues to the node's Completed (`done`), as each arm's would.

A flow node that nothing runs into is **unreached**: compiled nowhere, drawn faded (the original editor's cue).

### 5.2 Value nodes and evaluation order

Value nodes (Get, operators, pure calls, Make, Break, Cast, Select, literals, This, Base, Lambda Sheet,
Math Expression) have no flow pins; a Cast, Bind or Lambda that allocates or branches is a flow node instead
([2.3](#23-conversions-and-cast), [4.2](#42-delegates-and-function-pointers)).

**Rule 1 (when).** When a flow node runs, its value inputs are evaluated **first**, in pin order (top to
bottom), each one depth-first through the value nodes feeding it. Then the node itself runs.

**Rule 2 (how often).** A value node is evaluated **once per flow node that consumes it, each time that flow
node runs**, however many of that flow node's inputs it feeds (a diamond into one flow node evaluates the
shared value node once). A pure call's result and its `out` pins are one evaluation: whichever of them a flow node
reads, the call runs once for it and the `out` values are the ones that run wrote. Two different flow nodes
consuming the same value node each evaluate it. Nothing is cached across flow nodes. To evaluate once and reuse,
store the value in a **local variable** with a Set node; the pin menu's **Make local variable** on a value output
does that in one step (a local, and a Set of it in the flow).

**Rule 3 (what it reads).** A value node that reads a flow node's output (a call result, a Local's object, an
`out` pin, a loop's `Index`) reads the value that flow node produced the last time it ran. Such a read is
legal only where that flow node has certainly run: the consumer's flow node must be **dominated** by the
producer in the flow graph. Otherwise: error on the reader, "may not have run".

**Rule 4 (short circuit).** `And` / `Or` nodes evaluate their second input only when needed. `Select`
evaluates only the chosen input. **Decision:** Select is lazy (some node-graph editors evaluate both inputs). Reason: pure calls can be
expensive and a lazy Select is what a Branch over values means.

**Rule 5 (order within a node).** Argument evaluation order is pin order; a Receiver is evaluated before the
arguments. Operators: left input, then right input.

These five rules replace the original editor's refusals ("a value evaluated twice", "read outside its scope"):
Treadle defines the behaviour instead of refusing the graph, and the editor shows the consequence (a
value-call node consumed by three flow nodes shows "evaluated 3x" in its subtitle). The count is the compiler's
(Check's evaluation plan, `FrontEndServices.EvaluationCount`), refreshed by Validate.

**Text literals.** A text literal on a `String` input is a Local `String` of the function: made from the text
when the node runs and freed when the function returns (there are no constant objects). On a `StringView` or
`char8*` input it is the text itself.

### 5.3 Regions and scoped lifetimes

A **region** is the set of flow nodes dominated by a body output pin (Loop Body, Then n, Body, Deferred, a
Switch case, True/False of a Branch) in the flow graph, plus the function body region (everything
dominated by Entry). Regions nest. Each flow node has exactly one region: the innermost one that
dominates it.

* A **Local** belongs to its node's region. Its object is constructed when the node runs and destroyed when
  control **leaves the region** by any route: falling through to the owner's Completed, Break, Continue,
  Return, or a Try that returns. In a loop body the Local is destroyed and re-created each pass.
* Reading a Local's `Object` output is legal only from nodes in the same region or nested regions
  (dominated by the Local). Storing it in a field is a **warning**; returning it is an **error**; passing it
  to a function is the author's responsibility (as in Beef).
* **Defer** bodies run at region exit, last Defer first, after the region's Locals are... **Decision:**
  Defers run **before** the region's Locals are destroyed (so a deferred call may still use them), in
  reverse order of the Defer nodes' execution. Same as Beef.
* A **Return** inside nested regions runs every enclosing region's Defers and destructors inward to outward.
* **Ends without a Return.** A function that returns a value must not let the flow end unwired where that
  ends the function (T3032). The check follows what can run: a Return, a Try's return and a Fatal end the
  flow; a Switch's, a Result: match's or a Scope's Completed runs only when one of its arms ends without a
  wire; a Sequence's next output only when the previous one ends; a While whose condition is the literal
  `true` completes only by a Break. So a Switch whose cases all Return, or a `While true` left by Return,
  needs no trailing Return or Fatal.

### 5.4 Local variables

Declared per function (Outline > LOCAL VARIABLES): name, type, initial value, ownership. They live in the
function body region, are zero-initialised (`default`) at entry unless an initial value is set, and are
read / written with Get / Set nodes. A local of a reference type with ownership "Owned" is deleted when the
function returns (Delete of `null` does nothing, so one never set is fine; reassigning it does not delete the old
object). A local of a struct type that has a destructor (or an Owned field, or such a struct field) is destroyed
when the function returns, and a Set that replaces its value destroys the old value first; a local starts as the
default value, so the first Set destroys that zero value too (a destructor must accept it, as for fields). A local
declared as a generic parameter `T` is left alone: generic code moves values through such locals (the core's
Sorting, List and Queue swap through `local t T`), and the elements they came from own them. Both

happen at every exit of the function, after the function region's Defers and Locals, the last declared local
first. A Return of such a local returns a copy of what is then
destroyed or deleted (T3064 warns for a struct). **Decision:** locals belong to the function, not to a region.
Reason: one place to find them, no "declared in a region, read after it" errors; Local *nodes* are the
region-scoped thing.

### 5.5 Variables, Get and Set

Get and Set nodes name a field, a static field, a property, a local, or a parameter. A Set on an `out`
parameter is how a function writes its further outputs (Return also has one input per output). A Get is a
value node; a Set is a flow node with the new value as a pass-through output. A compound Set (`set op += -= *= /=` and
the other binary operators) applies the operator to the variable and Value and stores the result: the operator is found
as the Operator node finds it, by the variable's type and Value's, so an operator of two input types works (`v *= 2`
on a Vec3 with a float, a Mat4 or a Color times a float); its result must be the variable's type (T2083: `m *= v` with
a Mat4 and a Vec4 gives a Vec4).

### 5.6 Math Expression

A **Math Expression** node computes a formula typed in its body (`set expr "a * b + 1"`): every name in it is
an input pin, and `result` is its value. It is a value node. The grammar, loosest first (the same parser serves
the node, the editor's field and constants' inits, [4.6](#46-constants)):

| Level | Form | Notes |
|---|---|---|
| Select | `c ? a : b` | Right-associative; only the chosen side is evaluated (Rule 4) |
| Or, And | `a \|\| b`, `a && b` | bools; `b` only when `a` does not decide (Rule 4) |
| Bit operators | `a \| b`, `a ^ b`, `a & b` | integers (and bools, flags enums) |
| Equality | `a == b`, `a != b` | give a bool |
| Comparison | `a < b`, `a <= b`, `a > b`, `a >= b` | give a bool |
| Shift | `a << b`, `a >> b` | the count keeps its own type |
| Sum | `a + b`, `a - b` | |
| Product | `a * b`, `a / b`, `a % b` | integer division truncates |
| Unary | `-a`, `+a`, `!a`, `~a` | `-2` is the literal -2 |
| Power | `a ** b` | Right-associative, binds tighter than a unary minus on its left (`-2 ** 2` is -4); `Math.Pow`, a double |
| Primary | `12`, `0x1F`, `1.5`, `.5`, `2e3`, `0.5f`, `2d`, `true`, `false`, `name`, `name.field`, `Sqrt(x)`, `Math.Max(a, b)`, `( ... )` | `f` is a float, `d` a double; a number with a point or an exponent is a double |

* **Types** follow the Operator node's rules: a literal takes the type of the other side (`x * 2` with a float
  `x` multiplies floats), two numbers of different types meet in the wider one (an int and a float give a float),
  a struct's own operators apply when both sides are that struct; comparisons and `&&` `||` `!` give a bool, `? :`
  follows the Select node. An expression that mixes types the operators do not combine is T2211.
* **Inputs** are typed by their wire; an input with only a literal by the literal (following the other side as a
  literal does); an unwired input by what the expression does with it (`a && b`: bools; `a + 1`: an int; `a * x`:
  `x`'s type), else a double. `a.x` reads the field `x` of a struct input (a class input's field through the
  reference, null-checked); a path that names no field is T2213.
* **Functions** are the static functions of `Core.Math` (`Sqrt`, `Abs`, `Min`, `Max`, `Clamp`, `Lerp`, `Sin`, `Cos`,
  `Floor`, `Ceil`, `Round`, `Pow`...; `Math.` or `Core.Math.` may lead, the case of the name is forgiven), chosen
  among their overloads by the inputs as a Call node chooses (Compiler.md 2, Overloads); none, or several equal, is
  T2212.
* **Evaluation** is that of the equivalent nodes (Rules 1 to 5): left to right, depth first, an input read where the
  expression names it. Lower makes exactly the ops those nodes make: an Operator per operator, a Select per `? :`, an
  And / Or per `&&` / `||`, a pure Call per function, a Break per field read (no op of its own).
* **Vectors** ([2.8](#28-vectors-simd)): `float4(a, b, c, d)` makes one (any vector type name; one input fills
  every lane), `v.x` reads a lane and `v.zyx`, `v.xxxx`, `(a + b).xy`, `Sqrt(v).x` swizzle (the letters `x y z w`;
  a letter the vector does not have is T2301); a scalar or a literal next to a vector fills every lane; comparisons
  give a lane mask and `c ? a : b` with a mask `c` picks lane by lane (both sides made); `&&` `||` on masks are
  T2300; the Math functions with a vector form take vectors (`Sqrt(v)`, `Dot(a, b)`, `Lerp(a, b, t)`).
* **Problems** carry the column where the text goes wrong (`unexpected '*' at 4`): T2210 a text that does not parse
  (the editor's field refuses it as it is typed), T2211 operands, T2212 functions, T2213 names and fields, T2214 a
  literal that does not fit the side it is on (`i & 1.5`).

## 6. Entry points

| Entry | Where | Semantics |
|---|---|---|
| **Program Start** | The project's entry type has a static function `Main` with `Args : String[]` in, `int` out (or nothing) | Called once by the runtime after static constructors |
| **Overrides** | Red entries in the Outline: a function overriding a base virtual (`Tick`, `OnEvent`...) | Called by whoever calls the virtual |
| **Event handlers** | A delegate (Bind Function or a Lambda) added to an event with **Add** ([4.5](#45-events)) | Called by the event's **Invoke** |
| **C callbacks** | A static function with a C calling convention, bound to a function pointer | Called by the C library |
| **Exported functions** | `[Export("name")]` static functions in a library project | Visible in the output DLL / .so with a C ABI; the library's user calls `treadle_init` first and `treadle_shutdown` last (built: Compiler.md 1.1, "Project kinds") |

A `windowed` project has the same Program Start as a `console` one (no window of its own, no console);
a `library` project has none: no `Main` is needed and an `entry` line is ignored.

**Build constants.** The project's config can `define NAME` or `NAME=value`
([Graph-Format.md 5](Graph-Format.md#5-project-file-namevproject)). The core's `Build.IsDefined("NAME")`
(`bool`) and `Build.Value("NAME")` (`StringView`, empty when the config gives no value) are Pure nodes whose
result is a constant of the build: a Branch on `Build.IsDefined("PROFILE")` takes the same arm in every run
of a Profile build, and an optimised build drops the other one. The name is typed on the node; a wired name
is an error (T4002), since a define is known when the program is built, not when it runs.

`Args` holds the command-line arguments after the program's name, one `String` each (UTF-8; never `null`, empty
when there are none); the runtime makes it before Main and frees it after. A `Main` with no inputs is a
Program Start too and gets no arguments ([Compiler.md 4](Compiler.md#4-sheet-ir), Program Start).

There is no host-specific "event" concept in the language. A framework (a game loop, a UI library) is an
ordinary class with virtual functions; its users derive and override.

## 7. Error handling

**Decision:** no exceptions. Errors are values: `Result<T, E>` and `Option<T>` (payload enums in the core
library), handled by **Result: match**, **Try** (propagate) and **Switch**. Unrecoverable conditions use
**Fatal** (message, aborts) and the debug runtime's checks. Reason: exceptions need unwinding tables, hidden
control flow across the graph, and interact badly with manual memory; Beef made the same choice.

A **Fatal** node writes its message to stderr, then the runtime's fatal line (`fatal: Fatal node`, in Debug
with `at <Type.Member> node <id>`), and ends the program with exit code 3.

`E` defaults to `void`: `Result<T>` is "value or failed". Functions that can fail return a `Result`; the
Node menu shows them with a split output and offers Result: match first when dragging off the pin.

## 8. Modules, visibility, attributes

* **Visibility:** `public`, `protected` (type and derived), `private` (type), `internal` (project). Types
  and members default to `public` (what a visual user expects); the Node menu shows only what is visible from
  the Sheet.
* **Dependencies:** a project lists other projects (graph libraries, compiled with it) and C import sets.
  Cycles between projects are an error; cycles between types inside a project are fine. The type files of
  a project are those in its `source` folders (none listed: the project folder); a `depends` project's
  types (its own `source` folders and dependencies, recursively) are compiled with it, and its `internal`
  members stay invisible to the depending project. A listed folder or project that is not there is a
  warning (when no `source` folder is there, the project folder is read instead).
* **Attributes** are structured records on declarations (`name` + typed arguments), not text:

| Attribute | On | Effect |
|---|---|---|
| `[CRepr]` | struct | C field layout and no reordering (always true for imported C structs) |
| `[Packed]`, `[Align(n)]` | struct | Layout |
| `[Inline]`, `[NoInline]` | function | LLVM hints |
| `[Export("name", conv)]` | static function | C-ABI symbol; built: read by the compiler (T1076 on a function that is not static or is generic), exported by a `library` project (the conv is the platform's C one on x64) |
| `[Import("lib", "name", conv)]` | static function without a Sheet | Calls a C symbol (what the C import layer generates) |
| `[Flags]` | enum | Bit flags; `Has Flag` node |
| `[ExpandEnumAsFlow]` | function returning an enum | One flow output per case at the call site (the original editor's attribute, kept) |
| `[Node(Category, DisplayName, Keywords, Advanced)]` | function, type | Node menu presentation (the original editor's `[Node]`, kept) |
| `[Obsolete("why")]` | anything | Warning on use |
| `[NoDiscard]` | function | Warning when the result is not read |
| `[Copyable]` | struct with a destructor | Copies are meant: no warning when one is copied (T3064) |
| `[Intrinsic("name")]` | core-library function | Implemented by the compiler |

As built, the compiler reads `CRepr`, `Packed`, `Flags`, `Copyable`, `Event` (4.5), `Obsolete` (warning T2005),
`ExpandEnumAsFlow` (outputs `case:<Case>`), `Intrinsic`, `Import` and the C import's `Variadic`. `NoDiscard` is read
but gives no warning yet; `Align` above 16 is refused (T1077, as is a C record that needs more than 16-byte
alignment: objects, Locals and array elements are at most 16-byte aligned) and 16 or less is not read yet;
`Inline` / `NoInline` (the `inline` member modifier is recorded only),

`Export` and `Node` are not read yet (the Node menu's categories come from the type and the field's `category`).

User-defined attributes are classes deriving from `Attribute`; they are stored for reflection-lite (type
info lists them) but have no comptime behaviour in the first version.

## 9. Core library (minimal)

Written in Treadle itself (graph files) with `[Intrinsic]` nodes for what needs the compiler, plus C imports
of the C runtime (the `crt` set). Every program depends on it implicitly; `Core.*` names need no `uses` line.
The API by type, who owns what and what is not there yet are in [Core-Library.md](Core-Library.md) (the user
page); how it is found, compiled and what is intrinsic is in [Compiler.md 10](Compiler.md#10-the-core-library).
Everything beyond it is a library on top or a C import.

## 10. Glossary

Kept from the original editor (same meaning): **Sheet**, **Outline**, **Type Settings**, **Properties**, **Project
Browser** / **Project Drawer** (Ctrl+Space), **Node menu**, **Receiver** / **`this`**, **This** node, **Base**
node, **Flow pins**, **Flow nodes**, **Overrides**, **Value call**, **Return**, **Find in Sheets**,
**All nodes for this Sheet**, **Problems**, **Output Log**, **Base Constructor** / **This Constructor**,
**Locals** / **Call Stack** / **Debug Output**, `[ExpandEnumAsFlow]`, `[Node]`.

New or changed for Treadle:

| Term | Meaning |
|---|---|
| **Type file** | The one file that holds a type and all its Sheets (`.treadle`) |
| **Layout file** | The file with node positions, comment boxes, knots (`layout/<Type>.layout`, outside the source folders) |
| **Value node** | Any node without flow pins (a Value call, an operator, a Get, Make / Break, Cast...) |
| **Value pin** / **Wire** / **Knot** | A typed data pin; a connection; a reroute point on a wire |
| **Construct** | Heap allocation; the caller owns the object and deletes it |
| **Local** | Allocation in the current region; freed when the region ends |
| **Region** | The nodes owned by a body output (a loop body, a Branch arm, a Scope); defines Local lifetimes |
| **Delete**, **Defer**, **Defer Delete** | Free now; run at region exit; both |
| **Appended** | A field stored inside its owner's memory |
| **Owned** | A field the owner deletes in its destructor |
| **Entry** | The first node of a Sheet (parameters out) |
| **Program Start** | The static `Main` of the project's entry type |
| **Make** / **Break** | Build a struct or tuple from fields; split one into fields. The struct Break always names its type (`Break Pair<int,int>`); the loop's **Break** ([5.1](#51-flow-nodes)) has none, which is how the two are told apart |
| **Split Struct Pin** / **Recombine Struct Pin** | Show a struct pin as one pin per field on the same node (the Make / Break it stands for), and back |
| **Make Case** / **Is Case** | Build a payload enum case; test for one |
| **Result: match**, **Try**, **Fatal** | Error handling nodes |
| **Is Valid** | An object, a `T?` or a pointer holds something: not null, and in Debug not deleted ([2.2](#22-values-vs-references)) |
| **Is Type** | An object is of a class or implements an interface (a class Cast that only tests, `set test`) |
| **Extract to Function** | Move the selected nodes into a new function and leave a Call in their place ("collapse to function" elsewhere) |
| **Collapse Nodes** / **node group** | Fold a selection into one group node with a pin per wire crossing its edge; a view only, the compiler ignores it |
| **Hide Unwired Pins** | Draw one node compact (its unwired pins hidden) |
| **Create variable** / **Create local variable** | From a pin: a new field / local of the pin's type with its Get or Set wired in (an output's readers move onto a Get) (the way to evaluate a value once, [5.2](#52-value-nodes-and-evaluation-order)) |
| **Pure** | A function with no side effects; its calls are value nodes |
| **Mutating** | A struct function that writes its own fields |
| **Unsafe** | A Sheet or block where pointer nodes are allowed |
| **Node library** | A static class whose functions are offered as nodes under its own category |
| **C import set** | A list of C headers made into types and nodes |
| **Lambda Sheet** | A nested Sheet used as a delegate value |
| **Bind Function** | Makes a function pointer (no Allocation) or a delegate (Construct / Local) of a function |
| **Invoke** | Calls a delegate or a function pointer with its inputs `arg0`, `arg1`, ... |
| **Lambda** | The node whose body is a Lambda Sheet; it gives a delegate (or a function pointer) and holds what the Sheet captures |
| **Atomic Load / Store / Add / ...** | The atomic Calls of `Core.Atomic` on a variable passed by ref, each with a memory order |
| **Fence** | `Core.Atomic.Fence`: orders memory with a memory order, on no variable |
| **Thread**, **Mutex**, **LockGuard** | A thread of its own (Start with a body, Join); a lock; a Local struct that holds a Mutex for its region ([4.7](#47-threads)) |
| **Parallel** | `For` / `ForRange` / `ForEach`: a body over a range of indices on the pool's threads and the caller at once ([4.7](#47-threads)) |
| **Extension** | A type file (kind `extension`) that adds members to another type; they are listed under that type ([4.4](#44-extensions)) |
| **Event** | A field marked Event: handlers (delegates) called in order; its nodes **Add**, **Remove**, **Invoke**, **Clear**, **Count** ([4.5](#45-events)) |
| **Handler** | A delegate added to an event; the event owns and deletes it |
| **C variable** | An `extern` variable of a C import set (`cvar`), a static field of `C.<set>` read with Get and written with Set |
| **Evaluated Nx** | The subtitle on a value node consumed by N flow nodes |

Rule kept from the original editor: no other node editor's product name or its own terms appear in the UI, the error
texts or the user pages (`audience: user`); tools Treadle works with (lldb, Visual Studio, SDL) are named where
needed. Developer pages name Beef, the original editor and other editors where the comparison is the point (UX-Audit.md,
the decisions here).
