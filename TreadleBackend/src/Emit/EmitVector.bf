using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.Emit
{
	// Vector primitives in the emitter (docs/SIMD-and-Vectors.md 1, Compiler.md 5 and 6): layout, the
	// memory form of a vector, the element-wise forms of binop / cmp / cast / intrinsic, the vec.* ops,
	// the Debug lane and span checks, vector constants, DWARF, the C ABI and the target CPU.
	//
	// A vector value is an LLVM `<N x T>` (a mask `<N x i1>`). In memory a vector takes N lanes (3 lanes
	// the room of 4) and is aligned to min(size, 16), never more: rt_alloc and the stack give 16. LLVM
	// would align a `<8 x float>` to 32 inside a struct, so the memory form of a vector over 16 bytes is
	// an array of 16-byte vectors (`[2 x <4 x float>]`), whose LLVM layout is exactly Treadle's; a mask's
	// lanes are bytes (`<4 x i8>`, `[2 x <16 x i8>]` for bool32). Loads and stores go through a pointer
	// with the vector type and an explicit `align`, so only aggregates (insertvalue / extractvalue of a
	// struct, tuple, nullable or fixed array holding a vector) convert between the two forms.

	extension Layout
	{
		/// Bytes of one lane (a mask lane is a byte in memory).
		public static int64 LaneBytes(IRType elem) => (elem.Kind == .Bool) ? 1 : elem.Bits / 8;

		void VectorLayout(IRType t)
		{
			let e = t.Elem;
			let es = LaneBytes(e);
			let lanes = t.Count;
			let size = es * ((lanes == 3) ? 4 : lanes);
			let align = Math.Min(size, 16);
			let lane = (e.Kind == .Bool) ? "i1" : LL(e);
			let memLane = (e.Kind == .Bool) ? "i8" : LL(e);
			Set(t, size, align, scope $"<{lanes} x {lane}>");
			String mem = scope .();
			if (size <= 16)
				mem.AppendF("<{} x {}>", lanes, memLane);
			else
				mem.AppendF("[{} x <{} x {}>]", size / 16, 16 / es, memLane);
			if (mem != t.LLVM)
				String.NewOrSet!(t.LLVMMem, mem);
		}

		/// The LLVM type of a value of this type stored inside an aggregate or behind a pointer (a
		/// vector's memory form; every other type's own LLVM type).
		public StringView Mem(IRType t)
		{
			Compute(t);
			return t.LLVMMem ?? t.LLVM;
		}

		/// A vector whose memory form is not its value type (a mask, a vector over 16 bytes).
		public bool MemDiffers(IRType t)
		{
			if (!t.IsVector)
				return false;
			Compute(t);
			return t.LLVMMem != null;
		}

		/// `<N x i8>` for a mask, else the value type: what a load or store through a pointer reads.
		public void AccessLL(IRType t, String outText)
		{
			Compute(t);
			if (t.Elem.Kind == .Bool)
				outText.AppendF("<{} x i8>", t.Count);
			else
				outText.Append(t.LLVM);
		}

		/// `v4f32`, `v16i8`, `v4i1`: the type suffix of an LLVM vector intrinsic.
		public static void IntrinsicSuffix(IRType t, String outText)
		{
			let e = t.Elem;
			if (e.Kind == .Bool)
				outText.AppendF("v{}i1", t.Count);
			else if (e.IsFloat)
				outText.AppendF("v{}f{}", t.Count, e.Bits);
			else
				outText.AppendF("v{}i{}", t.Count, e.Bits);
		}
	}

	extension UnitEmitter
	{
		/// The `"target-features"` clang gives a function at each `simd` level (clang 23.1.3,
		/// `-march=<level>`); "" for a CPU it is not listed for (LLVM derives them from the CPU).
		public static StringView FeaturesOf(StringView cpu)
		{
			switch (cpu)
			{
			case "x86-64": return "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87";
			case "x86-64-v2": return "+cmov,+crc32,+cx16,+cx8,+fxsr,+mmx,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87";
			case "x86-64-v3": return "+avx,+avx2,+bmi,+bmi2,+cmov,+crc32,+cx16,+cx8,+f16c,+fma,+fxsr,+lzcnt,+mmx,+movbe,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87,+xsave";
			case "x86-64-v4": return "+avx,+avx2,+avx512bw,+avx512cd,+avx512dq,+avx512f,+avx512vl,+bmi,+bmi2,+cmov,+crc32,+cx16,+cx8,+f16c,+fma,+fxsr,+lzcnt,+mmx,+movbe,+popcnt,+sahf,+sse,+sse2,+sse3,+sse4.1,+sse4.2,+ssse3,+x87,+xsave";
			default: return "";
			}
		}

		StringView Features
		{
			get
			{
				if (!E.Options.TargetFeatures.IsEmpty)
					return E.Options.TargetFeatures;
				return FeaturesOf(E.Options.TargetCpu);
			}
		}

		/// The CPU attributes of every function: the ones clang gives a C function compiled with
		/// `-march=<simd level>` (with ThinLTO the code is generated at the link, where only these
		/// attributes name the CPU; SIMD-and-Vectors.md 1.7).
		void TargetAttributes(String outText)
		{
			outText.AppendF("\"no-trapping-math\"=\"true\" \"target-cpu\"=\"{}\"", E.Options.TargetCpu);
			let f = Features;
			if (!f.IsEmpty)
				outText.AppendF(" \"target-features\"=\"{}\"", f);
			outText.Append(" \"tune-cpu\"=\"generic\"");
		}

		public bool HasAvx => Features.Contains("+avx,") || E.Options.TargetCpu == "x86-64-v3" || E.Options.TargetCpu == "x86-64-v4";
		public bool HasAvx512 => Features.Contains("+avx512f") || E.Options.TargetCpu == "x86-64-v4";

		/// The C ABI of a vector (a result, or an argument on its own; SIMD-and-Vectors.md 1.6): win64
		/// hands the vector type to LLVM as it is (its calling convention passes 128- and 256-bit
		/// arguments through a pointer to a copy by itself); System V passes an 8-byte vector as one
		/// double and the others in registers (32 and 64 bytes: see VectorInMemory).
		CAbi VectorAbi(IRType t)
		{
			if (!SysV)
				return .Direct;
			return (L.Size(t) == 8) ? .Coerce : .Direct;
		}

		/// System V: a 32-byte vector argument without AVX, or a 64-byte one without AVX-512, goes in
		/// memory (`ptr byval(<8 x float>) align 32`); its result stays direct.
		public bool VectorInMemory(IRType t)
		{
			if (!SysV || !t.IsVector)
				return false;
			let size = L.Size(t);
			if (size <= 16)
				return false;
			return (size <= 32) ? !HasAvx : !HasAvx512;
		}

		/// The alignment of a copy passed through memory (`Indirect`): a vector's own size (clang's
		/// byval alignment), else the type's (8 at least on System V).
		public int64 IndirectAlign(IRType t)
		{
			if (t.IsVector)
				return Math.Max(L.Size(t), 8);
			return Math.Max(L.Align(t), SysV ? 8 : 1);
		}

		/// `<float 1.0, float 2.0, ...>` from `1,2,3,4` (one number splats; `true,false,...` for a
		/// mask), `zeroinitializer` for `zero` / `null` / `0`.
		void VectorConstText(IRType t, StringView lit, String outText)
		{
			if (lit == "zero" || lit == "null")
			{
				outText.Append("zeroinitializer");
				return;
			}
			List<StringView> parts = scope .();
			for (var p in lit.Split(','))
			{
				p.Trim();
				parts.Add(p);
			}
			if (parts.Count != 1 && parts.Count != t.Count)
			{
				Error(scope $"the constant '{lit}' has {parts.Count} lanes; {t.Text} has {t.Count}");
				outText.Append("zeroinitializer");
				return;
			}
			let lane = (t.Elem.Kind == .Bool) ? "i1" : L.LL(t.Elem);
			outText.Append('<');
			for (int i < t.Count)
			{
				if (i > 0)
					outText.Append(", ");
				outText.AppendF("{} ", lane);
				ConstText(t.Elem, parts[(parts.Count == 1) ? 0 : i], false, outText);
			}
			outText.Append('>');
		}

		/// A vector constant in its memory form (globals: `const` vectors, constant arrays of them);
		/// `typed` puts the memory type in front ("[2 x <4 x float>] [...]").
		void VectorMemConst(IRType t, StringView lit, String outText, bool typed)
		{
			let mem = L.Mem(t);
			if (typed)
				outText.AppendF("{} ", mem);
			if (lit == "zero" || lit == "null" || lit.IsEmpty)
			{
				outText.Append("zeroinitializer");
				return;
			}
			if (!L.MemDiffers(t))
			{
				VectorConstText(t, lit, outText);
				return;
			}
			// the lanes as memory holds them: bytes for a mask, 16-byte pieces, a zero 4th lane
			List<String> lanes = scope .();
			defer { ClearAndDeleteItems!(lanes); }
			List<StringView> parts = scope .();
			for (var p in lit.Split(','))
			{
				p.Trim();
				parts.Add(p);
			}
			let isBool = t.Elem.Kind == .Bool;
			let laneLL = isBool ? "i8" : L.LL(t.Elem);
			let store = (t.Count == 3) ? 4 : t.Count;
			for (int i < store)
			{
				String s = scope .();
				if (i >= t.Count)
					s.Append(isBool ? "0" : (t.Elem.IsFloat ? "0.0" : "0"));
				else
				{
					let p = parts[(parts.Count == 1) ? 0 : Math.Min(i, parts.Count - 1)];
					if (isBool)
						s.Append((p == "true" || p == "1") ? "1" : "0");
					else
						ConstText(t.Elem, p, false, s);
				}
				lanes.Add(new $"{laneLL} {s}");
			}
			let size = L.Size(t);
			if (size <= 16)
			{
				outText.Append('<');
				for (let l in lanes)
					outText.AppendF("{}{}", (@l.Index > 0) ? ", " : "", l);
				outText.Append('>');
				return;
			}
			let cl = 16 / Layout.LaneBytes(t.Elem);
			outText.Append('[');
			for (int k < size / 16)
			{
				outText.AppendF("{}<{} x {}> <", (k > 0) ? ", " : "", cl, laneLL);
				for (int j < cl)
					outText.AppendF("{}{}", (j > 0) ? ", " : "", lanes[k * cl + j]);
				outText.Append('>');
			}
			outText.Append(']');
		}

		/// The DWARF type of a vector: an array of its lanes with DIFlagVector.
		int32 VectorDIType(IRType t)
		{
			let et = DIType(t.Elem);
			let sr = AddMeta(scope $"!DISubrange(count: {t.Count})");
			return AddMeta(scope $"!DICompositeType(tag: DW_TAG_array_type, baseType: !{et}, size: {L.Size(t) * 8}, flags: DIFlagVector, elements: !{{!{sr}}})");
		}
	}

	extension FunctionEmitter
	{
		/// The alignment of a vector access through `addr`: 1 for a field of a `[Packed]` struct or
		/// class, else the vector's own (min(size, 16)).
		int64 VectorAccessAlign(IRValue addr, IRType t)
		{
			let def = addr.Def;
			if (def != null && def.Kind == .FieldAddr && !def.Args.IsEmpty)
			{
				let ot = def.Args[0].Type;
				IRTypeDecl d = null;
				if (ot.IsClass)
					d = ot.Decl;
				else if ((ot.Kind == .Pointer || ot.Kind == .Ref) && ot.Elem.Kind == .Named)
					d = L.Decl(ot.Elem);
				if (d != null && d.Packed)
					return 1;
			}
			return L.Align(t);
		}

		/// `r = load` of a vector through `p` (a mask reads bytes and truncates them).
		void LoadVector(IRType t, StringView p, StringView r, int64 align)
		{
			let ll = L.LL(t);
			if (t.Elem.Kind == .Bool)
			{
				let b = T();
				I(scope $"%t{b} = load <{t.Count} x i8>, ptr {p}, align {align}");
				I(scope $"{r} = trunc <{t.Count} x i8> %t{b} to {ll}");
				return;
			}
			I(scope $"{r} = load {ll}, ptr {p}, align {align}");
		}

		/// `store` of a vector value `v` through `p` (a mask writes one byte, 0 or 1, per lane).
		void StoreVector(IRType t, StringView v, StringView p, int64 align)
		{
			let ll = L.LL(t);
			if (t.Elem.Kind == .Bool)
			{
				let b = T();
				I(scope $"%t{b} = zext {ll} {v} to <{t.Count} x i8>");
				I(scope $"store <{t.Count} x i8> %t{b}, ptr {p}, align {align}");
				return;
			}
			I(scope $"store {ll} {v}, ptr {p}, align {align}");
		}

		/// The vector value `v` in its memory form; `outName` gets the operand (no type).
		void ToMem(IRType t, StringView v, String outName)
		{
			let n = t.Count;
			let e = t.Elem;
			String cur = scope .(v);
			String laneLL = scope .();
			laneLL.Append((e.Kind == .Bool) ? "i8" : L.LL(e));
			if (e.Kind == .Bool)
			{
				let z = T();
				I(scope $"%t{z} = zext {L.LL(t)} {v} to <{n} x i8>");
				cur.Set(scope $"%t{z}");
			}
			let size = L.Size(t);
			if (size <= 16)
			{
				outName.Append(cur);
				return;
			}
			var lanes = n;
			if (n == 3)
			{
				// the 4th lane of the storage is zero
				let w = T();
				I(scope $"%t{w} = shufflevector <3 x {laneLL}> {cur}, <3 x {laneLL}> zeroinitializer, <4 x i32> <i32 0, i32 1, i32 2, i32 3>");
				cur.Set(scope $"%t{w}");
				lanes = 4;
			}
			let es = Layout.LaneBytes(e);
			let cl = 16 / es;
			let chunks = size / 16;
			let mem = L.Mem(t);
			String acc = scope .("poison");
			for (int64 k < chunks)
			{
				String mask = scope .();
				for (int64 j < cl)
					mask.AppendF("{}i32 {}", (j > 0) ? ", " : "", k * cl + j);
				let c = T();
				I(scope $"%t{c} = shufflevector <{lanes} x {laneLL}> {cur}, <{lanes} x {laneLL}> poison, <{cl} x i32> <{mask}>");
				let a = T();
				I(scope $"%t{a} = insertvalue {mem} {acc}, <{cl} x {laneLL}> %t{c}, {k}");
				acc.Set(scope $"%t{a}");
			}
			outName.Append(acc);
		}

		/// `r` = the vector value of `m`, a vector in its memory form.
		void FromMem(IRType t, StringView m, StringView r)
		{
			let n = t.Count;
			let e = t.Elem;
			String laneLL = scope .();
			laneLL.Append((e.Kind == .Bool) ? "i8" : L.LL(e));
			let size = L.Size(t);
			String cur = scope .(m);
			if (size > 16)
			{
				let es = Layout.LaneBytes(e);
				let cl = 16 / es;
				let chunks = size / 16;
				let mem = L.Mem(t);
				List<String> parts = scope .();
				defer { ClearAndDeleteItems!(parts); }
				for (int64 k < chunks)
				{
					let c = T();
					I(scope $"%t{c} = extractvalue {mem} {m}, {k}");
					parts.Add(new $"%t{c}");
				}
				// concatenate pairwise: [a b c d] -> [ab cd] -> [abcd]
				var width = cl;
				while (parts.Count > 1)
				{
					List<String> next = scope .();
					for (int i = 0; i < parts.Count; i += 2)
					{
						String mask = scope .();
						for (int64 j < width * 2)
							mask.AppendF("{}i32 {}", (j > 0) ? ", " : "", j);
						let c = T();
						I(scope $"%t{c} = shufflevector <{width} x {laneLL}> {parts[i]}, <{width} x {laneLL}> {parts[i + 1]}, <{width * 2} x i32> <{mask}>");
						next.Add(new $"%t{c}");
					}
					ClearAndDeleteItems!(parts);
					parts.AddRange(next);
					width *= 2;
				}
				cur.Set(parts[0]);
				if (n == 3)
				{
					let c = T();
					I(scope $"%t{c} = shufflevector <4 x {laneLL}> {cur}, <4 x {laneLL}> poison, <3 x i32> <i32 0, i32 1, i32 2>");
					cur.Set(scope $"%t{c}");
				}
			}
			if (e.Kind == .Bool)
			{
				I(scope $"{r} = trunc <{n} x i8> {cur} to {L.LL(t)}");
				return;
			}
			// copy into the result name (an add of zero would change -0.0: use a no-op shuffle)
			String mask = scope .();
			for (int64 j < n)
				mask.AppendF("{}i32 {}", (j > 0) ? ", " : "", j);
			I(scope $"{r} = shufflevector {L.LL(t)} {cur}, {L.LL(t)} poison, <{n} x i32> <{mask}>");
		}

		/// "T v" of an aggregate member: a vector in its memory form.
		void MakeOperand(IRValue a, String outText)
		{
			if (!L.MemDiffers(a.Type))
			{
				TV(a, outText);
				return;
			}
			String v = scope .();
			V(a, v);
			String m = scope .();
			ToMem(a.Type, v, m);
			outText.AppendF("{} {}", L.Mem(a.Type), m);
		}

		/// `binop` on vectors: the scalar instruction per lane (signedness from the element).
		void EmitVectorBinop(IROp op, StringView r)
		{
			let t = op.Type;
			let e = t.Elem;
			String a = scope .();
			V(op.Args[0], a);
			String b = scope .();
			V(op.Args[1], b);
			let f = e.IsFloat;
			let sgn = e.IsSignedInt;
			StringView inst;
			switch (op.Sub)
			{
			case "add": inst = f ? "fadd" : "add";
			case "sub": inst = f ? "fsub" : "sub";
			case "mul": inst = f ? "fmul" : "mul";
			case "div": inst = f ? "fdiv" : (sgn ? "sdiv" : "udiv");
			case "rem": inst = f ? "frem" : (sgn ? "srem" : "urem");
			case "and": inst = "and";
			case "or": inst = "or";
			case "xor": inst = "xor";
			case "shl": inst = "shl";
			case "shr": inst = sgn ? "ashr" : "lshr";
			default:
				Error(scope $"unknown binop '{op.Sub}'");
				inst = "add";
			}
			if (f && (inst == "and" || inst == "or" || inst == "xor" || inst == "shl" || inst == "shr" || inst == "lshr" || inst == "ashr"))
				Error(scope $"binop {op.Sub} on {t.Text}: float lanes have no bitwise operators");
			I(scope $"{r} = {inst} {L.LL(t)} {a}, {b}");
			Def(op.Result, r);
		}

		/// `cmp` on vectors: a lane mask (`fcmp` ordered, `une` for !=; `icmp` by signedness).
		void EmitVectorCmp(IROp op, StringView r)
		{
			let t = op.Args[0].Type;
			let e = t.Elem;
			String a = scope .();
			V(op.Args[0], a);
			String b = scope .();
			V(op.Args[1], b);
			if (e.IsFloat)
			{
				StringView pred = "oeq";
				switch (op.Sub)
				{
				case "eq": pred = "oeq";
				case "ne": pred = "une";
				case "lt": pred = "olt";
				case "le": pred = "ole";
				case "gt": pred = "ogt";
				case "ge": pred = "oge";
				default: Error(scope $"unknown cmp '{op.Sub}'");
				}
				I(scope $"{r} = fcmp {pred} {L.LL(t)} {a}, {b}");
			}
			else
			{
				let sgn = e.IsSignedInt;
				StringView pred = "eq";
				switch (op.Sub)
				{
				case "eq": pred = "eq";
				case "ne": pred = "ne";
				case "lt": pred = sgn ? "slt" : "ult";
				case "le": pred = sgn ? "sle" : "ule";
				case "gt": pred = sgn ? "sgt" : "ugt";
				case "ge": pred = sgn ? "sge" : "uge";
				default: Error(scope $"unknown cmp '{op.Sub}'");
				}
				I(scope $"{r} = icmp {pred} {L.LL(t)} {a}, {b}");
			}
			Def(op.Result, r);
		}

		/// `cast` between vectors of one lane count: each lane as the scalar Cast converts it.
		bool EmitVectorCast(IRValue v, IRType to, StringView r, String outAlias)
		{
			let from = v.Type;
			String a = scope .();
			V(v, a);
			if (!from.IsVector || !to.IsVector || from.Count != to.Count)
			{
				Error(scope $"cannot cast {from.Text} to {to.Text}: a vector Cast keeps the lane count");
				outAlias.Set("poison");
				return false;
			}
			if (from == to)
			{
				outAlias.Set(a);
				return false;
			}
			let fe = from.Elem;
			let te = to.Elem;
			let fromLL = L.LL(from);
			let toLL = L.LL(to);
			StringView inst;
			if (te.Kind == .Bool)
			{
				if (fe.IsFloat)
					I(scope $"{r} = fcmp une {fromLL} {a}, zeroinitializer");
				else
					I(scope $"{r} = icmp ne {fromLL} {a}, zeroinitializer");
				return true;
			}
			if (fe.Kind == .Bool)
				inst = te.IsFloat ? "uitofp" : "zext";
			else if (fe.IsFloat && te.IsFloat)
				inst = (te.Bits > fe.Bits) ? "fpext" : "fptrunc";
			else if (fe.IsFloat)
				inst = te.Signed ? "fptosi" : "fptoui";
			else if (te.IsFloat)
				inst = fe.Signed ? "sitofp" : "uitofp";
			else if (te.Bits == fe.Bits)
			{
				outAlias.Set(a); // int32x4 <-> uint32x4: the same bits
				return false;
			}
			else
				inst = (te.Bits < fe.Bits) ? "trunc" : (fe.Signed ? "sext" : "zext");
			I(scope $"{r} = {inst} {fromLL} {a} to {toLL}");
			return true;
		}

		/// `intrinsic` on vectors: the LLVM intrinsic of the vector type (`llvm.sqrt.v4f32`).
		void EmitVectorIntrinsic(IROp op, StringView r)
		{
			let t = op.Type;
			if (!t.IsVector)
			{
				Error(scope $"intrinsic {op.Sub} on a vector is typed {t.Text}");
				return;
			}
			let ll = L.LL(t);
			String sfx = scope .();
			Layout.IntrinsicSuffix(t, sfx);
			String args = scope .();
			for (let a in op.Args)
			{
				if (!args.IsEmpty)
					args.Append(", ");
				TV(a, args);
			}
			int arity;
			StringView name = op.Sub;
			switch (op.Sub)
			{
			case "sqrt", "fabs", "floor", "ceil", "trunc", "round", "sin", "cos", "exp", "log", "tan", "asin", "acos", "atan":
				arity = 1;
			case "pow", "minnum", "maxnum", "copysign", "atan2", "smin", "smax", "umin", "umax":
				arity = 2;
			case "fma":
				arity = 3;
			case "abs":
				// integer lanes: llvm.abs with "INT_MIN is poison" off (it stays INT_MIN, as the scalar)
				U.NeedIntrinsic(scope $"declare {ll} @llvm.abs.{sfx}({ll}, i1)");
				I(scope $"{r} = call {ll} @llvm.abs.{sfx}({args}, i1 false)");
				Def(op.Result, r);
				return;
			default:
				Error(scope $"unknown vector intrinsic '{op.Sub}'");
				return;
			}
			if (op.Args.Count != arity)
			{
				Error(scope $"intrinsic {op.Sub} takes {arity} values");
				return;
			}
			String ps = scope .();
			for (int i < arity)
				ps.AppendF("{}{}", (i > 0) ? ", " : "", ll);
			U.NeedIntrinsic(scope $"declare {ll} @llvm.{name}.{sfx}({ps})");
			I(scope $"{r} = call {ll} @llvm.{name}.{sfx}({args})");
			Def(op.Result, r);
		}

		void Mask(int64 from, int64 count, String outText)
		{
			for (int64 j < count)
				outText.AppendF("{}i32 {}", (j > 0) ? ", " : "", from + j);
		}

		/// The `vec.*` ops and `lanecheck` (IRVector.bf).
		void EmitVectorOp(IROp op, StringView r)
		{
			if (op.Kind == .LaneCheck)
			{
				if (mDbg)
					EmitLaneCheck(op);
				return;
			}
			IRValue A(int i) => op.Args[i];
			switch (op.Sub)
			{
			case "make":
				let t = op.Type;
				let ll = L.LL(t);
				let lane = (t.Elem.Kind == .Bool) ? "i1" : L.LL(t.Elem);
				String cur = scope .("poison");
				for (let a in op.Args)
				{
					String next = scope .();
					if (@a.Index == op.Args.Count - 1)
						next.Append(r);
					else
						next.AppendF("%t{}", T());
					String av = scope .();
					V(a, av);
					I(scope $"{next} = insertelement {ll} {cur}, {lane} {av}, i32 {@a.Index}");
					cur.Set(next);
				}
				Def(op.Result, r);
			case "splat":
				let t = op.Type;
				let ll = L.LL(t);
				String s = scope .();
				TV(A(0), s);
				let one = T();
				I(scope $"%t{one} = insertelement {ll} poison, {s}, i64 0");
				I(scope $"{r} = shufflevector {ll} %t{one}, {ll} poison, <{t.Count} x i32> zeroinitializer");
				Def(op.Result, r);
			case "get":
				String v = scope .();
				TV(A(0), v);
				if (op.Args.Count == 2)
				{
					String i = scope .();
					Index64(A(1), i);
					I(scope $"{r} = extractelement {v}, i64 {i}");
				}
				else
					I(scope $"{r} = extractelement {v}, i32 {op.Index}");
				Def(op.Result, r);
			case "set":
				String v = scope .();
				TV(A(0), v);
				String s = scope .();
				TV(A(op.Args.Count - 1), s);
				if (op.Args.Count == 3)
				{
					String i = scope .();
					Index64(A(1), i);
					I(scope $"{r} = insertelement {v}, {s}, i64 {i}");
				}
				else
					I(scope $"{r} = insertelement {v}, {s}, i32 {op.Index}");
				Def(op.Result, r);
			case "shuffle":
				let src = A(0).Type;
				String a = scope .();
				TV(A(0), a);
				String b = scope .();
				if (op.Args.Count == 2)
					TV(A(1), b);
				else
					b.AppendF("{} poison", L.LL(src));
				List<int> m = scope .();
				IRVector.Mask(op, m);
				String mask = scope .();
				for (let i in m)
					mask.AppendF("{}i32 {}", (@i.Index > 0) ? ", " : "", i);
				I(scope $"{r} = shufflevector {a}, {b}, <{m.Count} x i32> <{mask}>");
				Def(op.Result, r);
			case "reduce":
				EmitReduce(op, r);
			case "any", "all":
				let mt = A(0).Type;
				String sfx = scope .();
				Layout.IntrinsicSuffix(mt, sfx);
				let what = (op.Sub == "any") ? "or" : "and";
				U.NeedIntrinsic(scope $"declare i1 @llvm.vector.reduce.{what}.{sfx}({L.LL(mt)})");
				String m = scope .();
				TV(A(0), m);
				I(scope $"{r} = call i1 @llvm.vector.reduce.{what}.{sfx}({m})");
				Def(op.Result, r);
			case "bitmask":
				let mt = A(0).Type;
				String m = scope .();
				TV(A(0), m);
				let bits = T();
				I(scope $"%t{bits} = bitcast {m} to i{mt.Count}");
				let want = L.LL(op.Type);
				if (want == scope $"i{mt.Count}")
				{
					Def(op.Result, scope $"%t{bits}");
					return;
				}
				I(scope $"{r} = zext i{mt.Count} %t{bits} to {want}");
				Def(op.Result, r);
			case "bitcast":
				String v = scope .();
				TV(A(0), v);
				I(scope $"{r} = bitcast {v} to {L.LL(op.Type)}");
				Def(op.Result, r);
			case "load":
				String p = scope .();
				V(A(0), p);
				LoadVector(op.Type, p, r, Math.Max(op.Index, 1));
				Def(op.Result, r);
			case "store":
				String p = scope .();
				V(A(0), p);
				String v = scope .();
				V(A(1), v);
				StoreVector(A(1).Type, v, p, Math.Max(op.Index, 1));
			case "spancheck":
				if (mDbg)
					EmitSpanCheck(op);
			default:
				Error(scope $"unknown vector op 'vec.{op.Sub}'");
			}
		}

		/// `vec.reduce`: integer and mask lanes through `llvm.vector.reduce.*`; float min / max through
		/// `llvm.vector.reduce.fmin / fmax` (minnum's NaN rule); float add / mul in a fixed pairwise
		/// tree, (l0 + l2) + (l1 + l3) for four lanes, halving each step (the same result at every `simd`
		/// level; a 3-lane vector gets the identity, -0.0 or 1.0, as its 4th lane).
		void EmitReduce(IROp op, StringView r)
		{
			let vt = op.Args[0].Type;
			let e = vt.Elem;
			String v = scope .();
			V(op.Args[0], v);
			let ll = L.LL(vt);
			let ell = (e.Kind == .Bool) ? "i1" : L.LL(e);
			String sfx = scope .();
			Layout.IntrinsicSuffix(vt, sfx);
			if (e.IsFloat && (op.Lit == "add" || op.Lit == "mul"))
			{
				String cur = scope .(v);
				var n = vt.Count;
				if (n == 3)
				{
					String id = scope .();
					U.ConstText(e, (op.Lit == "add") ? "-0.0" : "1.0", false, id);
					let w = T();
					I(scope $"%t{w} = shufflevector {ll} {cur}, {ll} <{ell} {id}, {ell} {id}, {ell} {id}>, <4 x i32> <i32 0, i32 1, i32 2, i32 3>");
					cur.Set(scope $"%t{w}");
					n = 4;
				}
				let inst = (op.Lit == "add") ? "fadd" : "fmul";
				while (n > 1)
				{
					let h = n / 2;
					String lo = scope .();
					Mask(0, h, lo);
					String hi = scope .();
					Mask(h, h, hi);
					let a = T();
					I(scope $"%t{a} = shufflevector <{n} x {ell}> {cur}, <{n} x {ell}> poison, <{h} x i32> <{lo}>");
					let b = T();
					I(scope $"%t{b} = shufflevector <{n} x {ell}> {cur}, <{n} x {ell}> poison, <{h} x i32> <{hi}>");
					let s = T();
					I(scope $"%t{s} = {inst} <{h} x {ell}> %t{a}, %t{b}");
					cur.Set(scope $"%t{s}");
					n = h;
				}
				I(scope $"{r} = extractelement <1 x {ell}> {cur}, i32 0");
				Def(op.Result, r);
				return;
			}
			StringView what;
			switch (op.Lit)
			{
			case "add", "mul", "and", "or", "xor": what = op.Lit;
			case "min": what = e.IsFloat ? "fmin" : (e.IsSignedInt ? "smin" : "umin");
			case "max": what = e.IsFloat ? "fmax" : (e.IsSignedInt ? "smax" : "umax");
			default:
				Error(scope $"unknown reduction '{op.Lit}'");
				return;
			}
			U.NeedIntrinsic(scope $"declare {ell} @llvm.vector.reduce.{what}.{sfx}({ll})");
			I(scope $"{r} = call {ell} @llvm.vector.reduce.{what}.{sfx}({ll} {v})");
			Def(op.Result, r);
		}

		/// Debug `lanecheck %i <N>`: a lane index outside 0..N-1 is `rt_bounds(site, i, N)`, naming the node.
		void EmitLaneCheck(IROp op)
		{
			String i = scope .();
			Index64(op.Args[0], i);
			String site = scope .();
			Site(op, site);
			String bad = scope .();
			Label(bad);
			String ok = scope .();
			Label(ok);
			let c = T();
			I(scope $"%t{c} = icmp uge i64 {i}, {op.Index}");
			I(scope $"br i1 %t{c}, label %{bad}, label %{ok}");
			LabelLine(bad);
			I(scope $"call void @rt_bounds(ptr {site}, i64 {i}, i64 {op.Index})");
			I("unreachable");
			LabelLine(ok);
		}

		/// Debug `vec.spancheck %index %length <N>`: lanes index .. index + N - 1 must be inside the span,
		/// else `rt_span_range(site, index, N, length)`, naming the node.
		void EmitSpanCheck(IROp op)
		{
			String i = scope .();
			Index64(op.Args[0], i);
			String len = scope .();
			Index64(op.Args[1], len);
			String site = scope .();
			Site(op, site);
			String bad = scope .();
			Label(bad);
			String ok = scope .();
			Label(ok);
			let neg = T();
			I(scope $"%t{neg} = icmp slt i64 {i}, 0");
			let end = T();
			I(scope $"%t{end} = add i64 {i}, {op.Index}");
			let over = T();
			I(scope $"%t{over} = icmp sgt i64 %t{end}, {len}");
			let c = T();
			I(scope $"%t{c} = or i1 %t{neg}, %t{over}");
			I(scope $"br i1 %t{c}, label %{bad}, label %{ok}");
			LabelLine(bad);
			I(scope $"call void @rt_span_range(ptr {site}, i64 {i}, i64 {op.Index}, i64 {len})");
			I("unreachable");
			LabelLine(ok);
		}
	}
}
