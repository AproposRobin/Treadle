---
audience: developer
title: SIMD and vectors
summary: The implementation spec for vector primitives (float4, int32x4, ...) and the core vector math library: spellings, layout, ABI, IR ops and their LLVM lowering, Debug checks, the editor's pins and nodes, the Vec/Mat/Quat API, fixtures, benchmarks and the plan.
order: 15
---

# SIMD and vectors

Treadle targets applications, games and engines, so SIMD is part of the language, not a library trick: vector
types are **primitives** that lower to LLVM vector types (`<4 x float>`) and to SSE/AVX registers, and the core
library builds its vector math (Vec3, Mat4, Quat, ...) on them. This page is the spec two implementation branches
follow; every **Decision** carries its reason. Problem codes are reserved as T1090-T1094 and T2300-T2319 (check
for a clash with other branches at merge).

## 1. Vector primitives

### 1.1 Spelling

| Element | Lanes | Names |
|---|---|---|
| `float`, `double` | 2, 3, 4, 8, 16 | `float2` ... `float16`, `double2` ... `double8` |
| `int8 int16 int32 int64`, `uint8 ... uint64` | 2, 3, 4, 8, 16 (8- and 16-bit: also 32, 64) | `int32x4`, `uint8x16`, `int64x2`, `int16x8`, `uint8x64` |
| `bool` (a lane mask) | as the vector it compares | `bool2` ... `bool64` |

* **Rule:** the element name followed by the lane count; when the element name ends in a digit an `x` separates
  them. A vector is at most **64 bytes** (`double16` and `int64x16` do not exist: T1090).
* **Decision:** no `int4` / `uint4`. Reason: Treadle's `int` is 64-bit, and `int4` means four 32-bit lanes in
  every shader language; the name would be a trap either way. `int4` is T1090 with the hint "int32x4 or
  int64x4". The same holds for `int`/`uint` elements in general.
* **Decision:** short names are primitives (in the type table like `float`), and **`Vector<T, N>`** is reserved
  as their canonical generic form (`float4` is `Vector<float,4>`), accepted when read but written short. Reason:
  pins and the Node menu stay short; generic code over widths (`const int N`) gets the long form later without a
  format change.
* Format: the name everywhere a type is written (`param dir float4`, `field mPos float4`, `split value float4`).
  IR text: the same names. Mangling: Itanium vendor vectors, `Dv4_f`, `Dv2_d`, `Dv4_i` (`int32x4`), `Dv16_h`
  (`uint8x16`), `Dv4_b` (`bool4`); lldb demangles them.

### 1.2 Layout and alignment

| | Size | Alignment | LLVM in memory |
|---|---|---|---|
| N = 2, 4, 8, 16, 32, 64 | N x element | min(size, 16) | `[N x T]` in struct types; loads/stores as `<N x T>` with that `align` |
| N = 3 | 4 x element (`float3` 16 bytes, `double3` 32) | min(size, 16) | `[4 x T]`, the 4th lane unused (zero when made) |
| `boolN` | N bytes (0 or 1 per lane) | min(N, 16) | `[N x i8]`; in SSA `<N x i1>`, `zext`/`trunc` at load/store |

* **Decision: alignment is capped at 16 bytes everywhere** (fields, arrays, Locals, Construct, the stack).
  Reason: `rt_alloc` and the Debug header give 16 (`treadle_rt.c`: Release ignores a larger `align`, the 48-byte
  Debug header keeps 16), so over-alignment would need an aligned free path and a type-dependent Delete; an
  unaligned 32-byte AVX load of 16-aligned data costs little on any AVX2 core. A `[Align(32)]` attribute is an
  open question (section 7).
* **Decision:** a vector field is stored as an LLVM array (`[4 x float]`), never as `<4 x float>` inside an LLVM
  struct type. Reason: LLVM gives `<8 x float>` an ABI alignment of 32 and would move the field; the array keeps
  Treadle's offsets, and each access is a vector load with an explicit `align`.
* Struct layout: fields in order, each at its alignment, struct size rounded to its largest alignment
  (`struct { float a; float4 v; }` is 32 bytes, `v` at 16). A class: the 8-byte header, then the first vector
  field at 16. `[Packed]`: alignment 1, unaligned vector accesses. Arrays `T[]`: elements start at offset 16 of
  the object, stride = size (`float3[]` strides 16). Fixed arrays `float4[N]`, `List<float4>`, `Span<float4>`:
  the same stride. Locals and slots: `alloca ... align 16`.

### 1.3 Values, conversions, constants

* Vectors are value types: copied, passed, stored, Make/Break-able, `T?`-able, usable as generic arguments
  (`List<float4>`), `IEquatable` (all lanes `==`) and `IHashable` (FNV-1a over the bytes; `-0.0` and `0.0`
  hash differently, documented).
* **Implicit conversions:** a scalar of the element type (or a literal) **splats** where it meets a vector in an
  Operator, a Math Expression or a literal on a vector input (`in scale 2`). Nothing else is implicit: lane
  types and counts change through Cast. **Decision:** no splat into a call argument. Reason: overload choice
  stays what the Call node shows; `v * k` (the common case) still works.
* **Cast** (numeric) between vectors of the same lane count converts each lane as the scalar Cast does
  (`sitofp`, `fptosi`, `fpext`, `fptrunc`, `sext`/`zext`/`trunc`; float to int is as undefined out of range as
  the scalar Cast). **Reinterpret** (`Cast set kind bits`) between vectors of equal size is a `bitcast`; safe,
  no pointers involved.
* **Literals and constants:** `in v 0,1,0,0` (one token, no spaces; a single number splats; `true,false,...`
  for masks). A constant of a vector type is allowed (Language.md 4.6 grows the list):
  `const float4 Up = float4(0, 1, 0, 0)`; `ConstTyper` folds lane by lane (integer lanes checked as scalars).

### 1.4 Operations and their lowering

Pure value nodes throughout. Sheet IR extends existing ops where the meaning is element-wise and adds `vec.*`
ops for the rest; `T` is a vector type, `E` its element, `M` its mask type `boolN`.

| What | Node / function | Sheet IR | LLVM |
|---|---|---|---|
| `+ - * / %` `& \| ^ << >>` `neg ~` | Operator | `binop T ...` | `fadd`/`add`... per element; signedness from `E`; division and shifts follow the scalar rules |
| `== != < <= > >=` | Operator | `cmp M ...` | `fcmp o..`/`une`, `icmp` -> `<N x i1>` |
| select per lane | Select with an `M` condition | `select T %m %a %b` | `select <N x i1>` (both sides evaluated: no Rule 4 short cut, documented) |
| make | Make `float4` (`x y z w`, or `lane0..laneN-1`) | `vec.make T %e...` | `insertelement` chain (a constant vector when all are constant) |
| splat | `Vector.Splat` | `vec.splat T %s` | `insertelement` + `shufflevector zeroinitializer` |
| lane read, constant | Break, `v.x` | `vec.get E %v <i>` | `extractelement` |
| lane read, variable | `Vector.GetLane(v, i)` | `vec.get E %v %i` | Debug `lanecheck` first; `extractelement` |
| lane write | `Vector.WithLane(v, i, s)` | `vec.set T %v %i %s` | `insertelement` (variable `i`: `lanecheck`) |
| swizzle | Swizzle node, `v.zyx` | `vec.shuffle T %v poison <m...>` | `shufflevector` |
| shuffle two | Shuffle node (`set mask 0 4 1 5`) | `vec.shuffle T %a %b <m...>` | `shufflevector` |
| reduce | `Vector.Sum / Product / MinLane / MaxLane / And / Or / Xor` | `vec.reduce E add\|mul\|min\|max\|and\|or\|xor %v` | ints: `llvm.vector.reduce.*`; floats `add`/`mul`: pairwise shuffle tree; `min`/`max`: `llvm.vector.reduce.fmin/fmax` |
| mask tests | `Vector.Any(m)`, `All(m)`, `Bitmask(m)` | `vec.any bool`, `vec.all bool`, `vec.bitmask uint` | `reduce.or`/`reduce.and` on `<N x i1>`; `bitcast <N x i1>` to `iN`, `zext` (x86 `movmsk`) |
| math | `Math.Sqrt Abs Floor Ceil Round Truncate Min Max Clamp Lerp Fma CopySign` on float vectors | `intrinsic T sqrt\|fabs\|...\|fma %a...` | `llvm.sqrt.v4f32` etc.; Round is `llvm.round` (halves away from zero, as scalar) |
| int math | `Math.Abs Min Max Clamp` on int vectors | `intrinsic T abs\|smin\|smax\|umin\|umax` | `llvm.abs`, `llvm.smin`... |
| transcendental | `Math.Sin Cos Exp Log Pow` on float vectors | `intrinsic` | `llvm.sin.v4f32` (scalarised to libm calls: correct, slow; section 7) |
| convert, reinterpret | Cast | `cast T`, `vec.bitcast T` | `sitofp`..., `bitcast` |
| load / store | `Vector.Load(span, index)`, `Vector.Store(v, span, index)` | `vec.load T %p <align>`, `vec.store %p %v <align>` | `load <N x E>, ptr, align alignof(E)`; Debug `rt_span_range` when `index + N > Length` |
| pointer load / store | unsafe `Vector.LoadPtr(E*)`, `StorePtr` | same ops | same |
| gather / scatter | later | | `llvm.masked.gather/scatter` |

* **Decision:** `==` on vectors gives a mask, not a bool. Reason: it is what SIMD code needs (`Select`,
  `Any`, `All`); `Vector.Equal(a, b)` (all lanes) and Hash.Equal give the whole answer. The core math structs
  (2.1) keep a `bool` `==`.
* **Decision:** float `Sum`/`Product` reduce in a fixed pairwise tree ((l0+l2)+(l1+l3) for 4 lanes, halving
  each step), not left to right. Reason: deterministic on every `simd` level and fast; strict order would be
  `N - 1` dependent adds.
* **Decision:** no floating-point contraction (`a * b + c` is two roundings); `Fma` is explicit. Reason: the
  same results at every `simd` level and in Debug; C's default `-ffp-contract=on` differs, so the C benchmark
  files pass `-ffp-contract=off`.
* `Min`/`Max` on floats keep the scalar `minnum`/`maxnum` meaning (a NaN lane takes the other operand).
* Mask lanes are `<N x i1>` in SSA; `&`, `|`, `^`, `!` work on masks; `&&`/`||` on masks are T2300.

### 1.5 Debug checks

| Check | Debug | Release |
|---|---|---|
| Variable lane index outside `[0, N)` (`GetLane`, `WithLane`) | `lanecheck %i <N>` -> `rt_bounds(site, i, N)` naming the node | unchecked (`extractelement` out of range is poison) |
| Constant lane index or swizzle letter beyond N (`v.w` on a `float3`) | T2301 at compile time, both configs | |
| `Vector.Load`/`Store` past the span | `rt_span_range(site, index, N, length)` | unchecked |
| Integer lane division by zero, shift count | as the scalar operators | as scalar |

The new op is `lanecheck %i <N>` (Debug only; Lower leaves it out in Release, like `boundscheck`).

### 1.6 ABI

* **Treadle to Treadle** (direct, virtual, interface, delegate, function pointer calls): vectors are first-class
  LLVM values in parameters and results, in registers; never `sret`. A struct holding vectors follows the
  aggregate rule of Compiler.md 6.3, a vector counting as one scalar unit and by its size.
* **C imports and exports** match clang's lowering of the same C prototype. **The rule for the implementation:
  for each case below, compile the C prototype with `clang -S -emit-llvm` for the target and emit the same IR
  shape**; fixture `vecabi` proves it with a C file on both sides. Checked with the toolchain's clang 23.1.3
  at v2 and v3 on 2026-10-25:

| Vector | win64 (x86_64-w64-windows-gnu) | SysV (x86_64-pc-linux-gnu) |
|---|---|---|
| 8 bytes (`float2`, `int32x2`) | `<2 x float>` direct in the IR | coerced to `double` (one XMM) |
| 16 bytes (`__m128`, `float3`, `int32x4`) | `<4 x float>` / `<3 x float>` direct | direct (XMM) |
| 32 bytes (`__m256`; 64 the same way) | direct | direct when the function's `target-cpu` has AVX; at v2 an argument is `ptr byval(<8 x float>) align 32`, a result stays direct |
| `boolN` | refused at a C boundary (T2302): C has no mask type | same |

* On win64 clang hands vectors to LLVM as they are, and LLVM's Win64 calling convention itself passes 128- and
  256-bit vector arguments by pointer to a copy and returns them in XMM0/YMM0: emitting the vector type is the
  whole job (unlike the aggregate rule). On SysV the emitter applies the two coercions above. T3090 warns when a
  Linux import takes a 32-byte vector at v2 (C built with AVX passes it in YMM).

* `__vectorcall` stays unsupported (skipped on import, as today).
* **C import:** `CXType_Vector` (and typedefs of it) maps by element and count: `__m128` -> `float4`,
  `__m128d` -> `double2`, `__m128i` -> `int64x2` (its declared element), `__m256` -> `float8`, `__m256i` ->
  `int64x4`, `__m512` -> `float16`; `float __attribute__((vector_size(16)))` -> `float4`;
  `ext_vector_type(3)` -> `float3`. A size Treadle has no name for stays skipped. The `.cdecl` writes the
  Treadle name. Header intrinsics (`_mm_add_ps`, `static inline`) remain uncallable; the portable ops above
  replace them.

### 1.7 Target selection

* A config key **`simd`**: `x86-64` (SSE2), `x86-64-v2` (SSE4.2, POPCNT), `x86-64-v3` (AVX2, FMA, BMI2),
  `x86-64-v4` (AVX-512), `native`. Default **`x86-64-v2`** in every config. Reason: every x86-64 CPU sold
  since 2009 has it; AVX2 is missing on CPUs still in use (Pentium and Celeron before 2020), so v3 is an
  explicit choice of a game or an engine. `native` refuses a `--package` build (T1093). Wider vectors still
  work at v2 (LLVM splits a `float8` into two SSE operations).
* **Decision:** the emitter writes `"target-cpu"="<level>"` on every function definition, and the runtime is
  compiled with `-march=<level>` (part of its cache key). Reason: with ThinLTO the code is generated at the
  link, where only function attributes carry the level; a command-line `-march` alone would be lost.
* A changed `simd` rebuilds every unit (it is in each unit's stamp). The project page gets a `simd` row.
* Runtime dispatch (one build, AVX2 paths chosen at start) is later: a `[TargetClones]` attribute and a
  resolver run by `rt_start`. Linux on aarch64 (NEON) maps the same types; its levels are added with the port.

### 1.8 Math Expression

* `float4(a, b, c, d)` makes a vector (any vector type name; one argument splats); `v.x` reads lane 0, `v.zyx`,
  `v.xxxx` swizzle (letters `x y z w`, 1 to 4 of them, within the lane count: T2301); wider lanes need GetLane.
* Operators follow 1.3 and 1.4: same-type vectors element-wise, a scalar or literal splats, comparisons give a
  mask, `? :` with a mask condition selects per lane (both sides evaluated), `&&` `||` on masks T2300.
* `Core.Math` functions with vector overloads apply (`Sqrt(v)`, `Dot(a, b)`, `Lerp(a, b, t)`).
* An unwired input is typed by what it meets (`a + v`: `v`'s type), as today. Constant inits use the same
  grammar (`const float4 Up = float4(0, 1, 0, 0)`).

### 1.9 Editor

* **Pin family `Vector`** (`ITypeSystem.Family`): the element's colour (float green, int cyan, bool red) with a
  **lanes** shape: a rounded square with N/4 inner bars (one bar for 2-4 lanes, two for 8, ...); the tooltip
  says `float4 (4 x float, 16 bytes)`. `TypeRules.bf` gets the name rule for `NullTypeSystem`.
* **Unwired input widget:** one number field per lane up to 4 lanes (`x y z w`), a single splat field above 4.
* **Make / Break:** pins `x y z w` for 2-4 lanes, `lane0 ... laneN-1` above. Split Vector Pin / Recombine Vector
  Pin (the pin menu) work on vector pins as on structs: one pin per lane on the node, `v.x` ... `v.w` (`v.lane0` ...
  above 4 lanes), kept as `split <pin> float4`; the compiler reads a split input as a Make of the vector fed by the
  lane pins and a split output as its Break (`SplitPins.Expand` puts the lanes on the Make / Break's own lane pins),
  so a lane with no wire and no value is 0.
* **New node kinds:** `Swizzle` (`value` -> `result`; `set lanes zyx`; title "Swizzle .zyx"; Properties: a lane
  picker) and `Shuffle` (`a`, `b` -> `result`; `set mask 0 4 1 5`; Properties: one dropdown per output lane).
  Everything else is a Call of `Core.Vector` or `Core.Math` (category `Math | Vector`).
* Debugger: DWARF `DW_TAG_array_type` with `DIFlagVector`; Locals and pin values show `(1, 2, 3, 4)`.
* Pixel pass: the new pins and both nodes at 1280/1920/125%, both themes.

## 2. The core vector math library

### 2.1 Layout decision

**Decision:** the math types are plain C-layout structs of `float` fields (alignment 4), and their functions
are Sheets that compute on vector primitives (Make `float3` from the fields, operate, Break). `Vec3` is
**12 bytes, packed**, not a `float4` with a spare lane. Reason: drop-in identical to C (`glm::vec3`, raylib
`Vector3`, `XMFLOAT3`), vertex buffers and files, no 25 % waste in arrays; LLVM turns the Make / Break around
the vector op into unaligned vector loads in Release (fixture `mathcodegen` checks the `.ll`/disassembly), and
code that wants 16-aligned SIMD storage uses `float4` directly. GPU buffers with std140/std430 rules (vec3
aligned 16) use `float4` or the `ToStd430` helpers. The same holds for Mat3 (36 bytes) and Mat4 (64 bytes,
columns of Vec4).

All types live in namespace `Core` (implicitly used), file `TreadleCore/core/Math*.treadle`; every function is
Pure unless marked (m) Mutating. Angles are radians. Conventions: right-handed, Y up, -Z forward (Vulkan/GL view
space); projections map depth to [0, 1] (Vulkan, D3D) with a `...GL` variant for [-1, 1].

### 2.2 API

**Vec2** (`X Y`), **Vec3** (`X Y Z`), **Vec4** (`X Y Z W`); **Vec2d / Vec3d / Vec4d** the same in `double`.
Shared by all (V is the type, S its element):
* static properties `Zero`, `One`, `UnitX`, `UnitY` (+ `UnitZ`, `UnitW` where they exist); `this(S all)` (splat
  constructor) besides Make.
* operators `+ -` (V, V), unary `-`, `*` (V, V), (V, S), (S, V), `/` (V, V), (V, S), `==` `!=` (exact, a `bool`).
* `Dot(V) -> S`, `Length() -> S`, `LengthSquared()`, `Distance(V)`, `DistanceSquared(V)`, `Normalized() -> V`
  (a zero-length vector gives zero), `Lerp(V to, S t)`, `Min(V)`, `Max(V)`, `Clamp(V lo, V hi)`, `Abs()`,
  `Floor()`, `Ceil()`, `Round()`, `Reflect(V normal)`, `ProjectOnto(V)`, `AngleTo(V) -> S`, `IsFinite() ->
  bool`, `ApproxEquals(V other, S epsilon = 1e-5) -> bool` (every component within `epsilon`, absolute),
  `ToVector()` (-> `float2` / `float3` / `float4`, `double...`) and static `FromVector(...)`.
* Vec2 only: `Perpendicular()` (`(-Y, X)`), `Cross(Vec2) -> S` (the z of the 3D cross), `Angle()` (atan2 of Y,
  X), static `FromAngle(S)`. Vec3 only: `Cross(Vec3)`, `XY()`; Vec4: `XYZ()`, static `FromVec3(Vec3, S w)`.

**Mat3** (columns `C0 C1 C2: Vec3`) and **Mat4** (columns `C0 C1 C2 C3: Vec4`), column-major like GLSL and
Vulkan, so `M * v` transforms a column vector and a Mat4 uploads to a shader as it is:
* static `Identity`, `Zero`; `Get(int row, int col)`, `Column(int)`, `Row(int)`, operators `*` (M, M),
  `*` (M, vector), `*` (M, S), `+`, `-`, `==`; `Transposed()`, `Determinant()`, `Inverted()` (a singular matrix
  gives zero), `TryInvert(out M result) -> bool`, `ApproxEquals(M, S epsilon = 1e-5)`.
* Mat4 static builders: `Translation(Vec3)`, `Scale(Vec3)`, `RotationX/Y/Z(float angle)`, `Rotation(Quat)`,
  `FromTRS(Vec3 t, Quat r, Vec3 s)`, `LookAt(Vec3 eye, Vec3 target, Vec3 up)`, `Perspective(float fovY, float
  aspect, float near, float far)`, `PerspectiveGL(...)`, `Orthographic(left, right, bottom, top, near, far)`,
  `OrthographicGL(...)`; `TransformPoint(Vec3)` (w = 1, no divide), `TransformVector(Vec3)` (w = 0),
  `TransformPerspective(Vec3)` (divides by w), `Upper3x3() -> Mat3`, `ToStd430(Span<float> into)` (no-op layout
  copy, for symmetry with Mat3).
* Mat3: `FromQuat(Quat)`, `Scale(Vec3)`, `RotationZ(angle)` (2D), `ToStd430(Span<float> into)` (three columns
  padded to 4 floats).

**Quat** (`X Y Z W`, W the real part): static `Identity`, `FromAxisAngle(Vec3 axis, float angle)`,
`FromEuler(float pitch, float yaw, float roll)` (applied roll about Z, then pitch about X, then yaw about Y),
`FromMat3(Mat3)`, `LookRotation(Vec3 forward, Vec3 up)`, `FromTo(Vec3 from, Vec3 to)`; operators `*` (Quat,
Quat: `a * b` applies `b` first), `*` (Quat, Vec3: rotates), `==`; `Rotate(Vec3)`, `Conjugate()`, `Inverse()`,
`Normalized()`, `Dot(Quat)`, `Length()`, `Slerp(Quat to, float t)` (shortest arc), `Nlerp(Quat to, float t)`,
`AngleTo(Quat)`, `ToMat3()`, `ToMat4()`, `ToAxisAngle(out Vec3 axis) -> float`, `ToEuler() -> Vec3` (pitch,
yaw, roll), `ApproxEquals(Quat, float epsilon = 1e-5)` (q and -q are equal).

**Color** (`R G B A: float`, linear): static `White Black Transparent Red Green Blue Yellow Cyan Magenta Gray`,
`FromRGBA8(uint8 r, g, b, a = 255)`, `FromHex(uint32 rrggbbaa)`, `FromSrgb(Color)`; `ToSrgb()`,
`ToColor32()`, `WithAlpha(float)`, `Premultiplied()`, `Lerp(Color, float t)`, operators `+`, `*` (Color,
Color), `*` (Color, float), `==`, `ApproxEquals`. **Color32** (`R G B A: uint8`, 4 bytes, sRGB as stored):
`FromHex(uint32)`, `ToHex() -> uint32`, `ToColor()` (decodes sRGB), `==`.

**Rect** (`X Y Width Height: float`) and **RectI** (`int32`, SDL_Rect's layout): `FromMinMax(Vec2, Vec2)`,
`Min()`, `Max()`, `Center()`, `Size()`, `Contains(Vec2)`, `Overlaps(Rect)`, `Intersection(Rect)` (empty: zero
size), `Union(Rect)`, `Expanded(float)`, `Translated(Vec2)`, `IsEmpty()`.

**AABB** (`Min Max: Vec3`): static `Empty` (Min +inf, Max -inf), `FromCenterExtents(Vec3, Vec3)`, `FromPoints(Span<Vec3>)`;
`Center()`, `Extents()`, `Size()`, `IsValid()`, `Contains(Vec3)`, `Overlaps(AABB)`, `Union(AABB)`,
`Encapsulate(Vec3)`, `Transformed(Mat4)` (Arvo's method), `ClosestPoint(Vec3)`.

**Plane** (`Normal: Vec3, D: float`, points p with `Dot(Normal, p) + D = 0`): `FromPointNormal(Vec3, Vec3)`,
`FromPoints(a, b, c)`, `DistanceTo(Vec3)`, `Normalized()`, `Project(Vec3)`.

**Ray** (`Origin Direction: Vec3`): `At(float t)`, `IntersectAABB(AABB, out float t) -> bool` (slabs),
`IntersectPlane(Plane, out float t) -> bool`, `IntersectSphere(Vec3 center, float radius, out float t) -> bool`,
`IntersectTriangle(Vec3 a, b, c, out float t) -> bool` (Moller-Trumbore, both faces).

**Transform** (`Translation: Vec3, Rotation: Quat, Scale: Vec3`): static `Identity`; `ToMat4()`,
`TransformPoint(Vec3)`, `TransformVector(Vec3)`, `Inverse()` (exact for uniform scale; non-uniform scale with
rotation loses the shear, documented), operator `*` (parent * child), `Lerp(Transform, float t)` (Slerp for
the rotation), `ApproxEquals`.

**Scalar Math additions** (needed above, intrinsics): `Tan`, `Asin`, `Acos`, `Atan`, `Atan2` (`llvm.tan`,
`llvm.asin`, `llvm.acos`, `llvm.atan`, `llvm.atan2`), `Fma`, `CopySign`, `Radians(deg)`, `Degrees(rad)`,
`SmoothStep(e0, e1, x)`, constant `Tau`; float and double overloads.

**Core.Vector** (static node library, intrinsics, generic over vector types): `Splat`, `GetLane`, `WithLane`,
`Sum`, `Product`, `MinLane`, `MaxLane`, `And`, `Or`, `Xor`, `Any`, `All`, `Bitmask`, `Equal` (all lanes),
`Load`, `Store`, `LoadPtr`, `StorePtr` (unsafe), `Dot(a, b)` (also in `Core.Math`, with `Length`, `Normalize`,
`Cross` for `float3`/`float4` (xyz, w = 0), `Lerp`). The generic parameter takes a constraint **`T : vector`**
(new constraint word; `T : vector float` narrows the element), which Language.md 2.4 adds.

**Formatting:** `String.Append` overloads (an extension in `MathFormat.treadle`) write vectors and math types as
`(1, 2, 3)` with each component as `Append(float)` writes it; Mat3/Mat4 as rows `[(..), (..)]`. AppendF and
Console.WriteLine pick them up through Append.

## 3. Fixtures and benchmarks

| Name | Kind | What it proves |
|---|---|---|
| `vecops` | `.tir` + compile corpus | every op of 1.4 on `float4`, `float3`, `double2`, `int32x4`, `uint8x16`, `bool4`, printed lane by lane; the C side computes the same with clang vector extensions |
| `veclayout` | compile + C | `sizeof`/`offsetof` of structs, classes, arrays with vector fields equal C's (with `alignas(16)` caps) |
| `vecabi` | `.tir` + C file, Windows and Linux | 1.6 both directions: imports and `[Export]`s taking and returning `float2`, `float4`, `float3`, `int32x4`, `float8` (at v2 and v3) |
| `veccheck` | checks set | `GetLane` index 4 on a `float4`, `Load` past a span: fatal errors naming the node (Debug) |
| `vecconst` | compile | vector constants folded; T1090/T2300/T2301 cases in the errors set |
| `mathlib` | compile + run | known answers for every 2.2 function (inverse * M = identity, Slerp halves, ray hits) against a C reference file |
| `mathcodegen` | Release `.ll` check | `Vec3 + Vec3` and `Mat4 * Mat4` lower to vector instructions after ThinLTO |

**Benchmarks** (added to `scripts\bench.ps1` and Performance.md; the C side gets `-ffp-contract=off` and the
same `-march` as the Treadle config; gate: **at most ~1.1x C**):
* **nbody**: 4,096 bodies, 20 steps, O(n^2) gravity; positions and masses as `float4` (xyz + mass) in a
  `float4[]`. C: SSE intrinsics (`_mm_*`), the same algorithm and rsqrt-free `sqrt` + divide. Rows at
  `x86-64-v2` and `x86-64-v3` (C: `_mm256_*`), plus a scalar Treadle `Vec3` version for the speed-up.
* **floatmath4**: the floatmath Mandelbrot with four pixels per `double4` (masked iterations, `Any` to leave);
  C: AVX2 intrinsics at v3, SSE2 `double2` at v2. The scalar floatmath row stays.

## 4. Implementation plan

Days are rough and include each part's docs. Order: A, then B and C together, then D; E and F once B lands.

| # | Part | Work | Days |
|---|---|---|---|
| A | Types | `TypeRef` vector kind; names of 1.1 and `Vector<T,N>` in the parser and name resolution; layout (size, alignment, storage) in the type table; `T : vector` constraint; mangling; `ITypeSystem.Family` | 1.5 |
| B | Bind / Check | Operators, splat, masks, Select per lane, Cast and bits, Make/Break lanes, Swizzle/Shuffle nodes, `Core.Vector` intrinsic table, Math overloads, Math Expression constructors and swizzles, constant folding, T-codes | 3 |
| C | IR + emitter | `vec.*`, `lanecheck`, vector forms of `binop`/`cmp`/`select`/`cast`/`intrinsic` in IR.bf, writer and reader; LLVM types, array storage, `align`s, reductions, Debug checks, DWARF vectors, `target-cpu` attributes, `simd` key, runtime `-march` and cache key | 3 |
| D | ABI + C import | 1.6 for `ccall` and `[Export]` wrappers on win64 and SysV; `CXType_Vector` in the importer and `.cdecl`; `vecabi` on both systems | 1 |
| E | Core | `Core.Vector` and Math additions (intrinsic), then the 2.2 Sheets (about 300 functions; written as `.treadle` files in canonical order, checked by `mathlib`), formatting | 5 |
| F | Editor | pin family and shape, lane widgets, Make/Break lane pins, Swizzle/Shuffle nodes and Properties, Node menu category, project-page `simd` row, pixel pass | 2.5 |
| G | Fixtures, bench, docs | section 3; Language.md 2.1/2.4/4.6/5.6, Compiler.md 4-6, Core-Library.md, Graph-Format.md 5, C-Import.md, Language-Guide.md (user page section) | 2 |

About **17-18 days of work**; the first useful slice (A-D with `vecops`/`vecabi`, a `float4` n-body in a sample)
is about 8.5.

## 5. Open questions (with recommendations)

1. **Default `simd` level.** v2 (recommended: runs everywhere a 64-bit Windows 11 runs) or v3 for new projects
   made from a game template? Recommend v2 default, v3 offered on the project page with a one-line warning.
2. **`[Align(32/64)]`** for fields and types (AVX-512 data, cache-line padding against false sharing between
   threads). Recommend: cache-line alignment arrives with Threads (it needs the aligned free path anyway); vector
   alignment stays capped.
3. **Fast vector Sin/Cos/Exp/Log.** LLVM scalarises them to libm. Recommend polynomial Sheets in the core
   (`Vector.FastSin`, documented error bound) after the alpha; correctness first.
4. **Double Mat/Quat** (`Mat4d`, `Quatd`) for large worlds. Recommend later, on demand; Vec*d now.
5. **Target intrinsics** (`pshufb`, `movemask` variants, `_mm_rsqrt_ps`): recommend a small `Core.Vector.X86`
   set later (`ShuffleBytes`, `RcpApprox`, `RsqrtApprox`), portable fallbacks per target.
6. **Denormals / flush-to-zero** for games (MXCSR FTZ/DAZ per thread). Recommend off by default; a
   `Vector.SetFlushDenormals(bool)` call per thread with Threads.
