using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;

namespace Treadle.Compiler
{
	/// The `.tir` text of the vector ops (the back end's IRVector.bf form).
	extension KirWriter
	{
		/// After the result's name (Op wrote it): the mnemonic and the operands.
		static void VectorOp(IROp op, String o)
		{
			void V(int i)
			{
				if (i < op.Operands.Count)
				{
					o.Append(' ');
					op.Operands[i].Ref(o);
				}
			}
			if (op.Kind == .LaneCheck)
			{
				o.Append("lanecheck");
				V(0);
				o.AppendF(" {}", op.Index);
			}
			else
			{
				o.AppendF("vec.{}", op.Sub);
				if (op.Sub != "store" && op.Sub != "spancheck")
				{
					o.Append(' ');
					Type(op.Type, o);
				}
				switch (op.Sub)
				{
				case "get":
					V(0);
					if (op.Operands.Count == 2)
						V(1);
					else
						o.AppendF(" {}", op.Index);
				case "set":
					V(0);
					if (op.Operands.Count == 3)
					{
						V(1);
						V(2);
					}
					else
					{
						o.AppendF(" {}", op.Index);
						V(1);
					}
				case "shuffle":
					V(0);
					if (op.Operands.Count == 2)
						V(1);
					else
						o.Append(" poison");
					o.AppendF(" {}", op.Lit);
				case "reduce":
					o.AppendF(" {}", op.Lit);
					V(0);
				case "load":
					V(0);
					o.AppendF(" {}", op.Index);
				case "store", "spancheck":
					V(0);
					V(1);
					o.AppendF(" {}", op.Index);
				default:
					Values(op, 0, o);
				}
			}
			if (!op.Node.IsEmpty)
			{
				o.AppendF(" @{}", op.Node);
				if (!op.Pin.IsEmpty)
					o.AppendF(".{}", op.Pin);
			}
			o.Append('\n');
		}
	}

	/// Lowering of the vector primitives (docs/SIMD-and-Vectors.md 1.4): splats, the element-wise
	/// operators, Select per lane, Make / Break, Swizzle / Shuffle, the vector functions, Reinterpret.
	extension FnLowerer
	{
		IROp VecOp(StringView what, KType type, StringView node, StringView pin)
		{
			let op = E.Op(.Vec, type, node, pin);
			op.Sub = new String(what);
			return op;
		}

		/// A scalar in every lane of `vec` (converted to the lane type first).
		IRValue Splat(IRValue s, KType from, KType vec, StringView node, StringView pin)
		{
			let lane = Convert(s, from, vec.Element, node, pin);
			let op = VecOp("splat", vec, node, pin);
			op.Operands.Add(lane);
			return op;
		}

		/// `v` as a value of the vector type `to`: a scalar splats, a vector stays.
		IRValue AsVector(IRValue v, KType to, StringView node, StringView pin)
		{
			if (v.Type == to || v.Type == null || v.Type.IsError || v.Type.IsVector)
				return v;
			return Splat(v, v.Type, to, node, pin);
		}

		/// An operator on vectors (Operate for a vector operand): the scalar side splats; a
		/// comparison gives the mask type.
		IRValue VectorOperate(StringView op, KType operand, IRValue a, IRValue b, KType result, StringView node, StringView pin)
		{
			let va = AsVector(a, operand, node, pin);
			if (op == "neg")
			{
				let zero = E.Const("0", operand, node, pin);
				let r = E.Op(.Binop, operand, node, pin);
				r.Sub = new String("sub");
				r.Operands.Add(zero);
				r.Operands.Add(va);
				return r;
			}
			if (op == "!" || op == "~")
			{
				let ones = E.Const((op == "!") ? "true" : "-1", operand, node, pin);
				let r = E.Op(.Binop, operand, node, pin);
				r.Sub = new String("xor");
				r.Operands.Add(va);
				r.Operands.Add(ones);
				return r;
			}
			let vb = AsVector(b, operand, node, pin);
			let cmp = IsCompare(op);
			let r = E.Op(cmp ? .Cmp : .Binop, cmp ? T.MaskOf(operand) : operand, node, pin);
			r.Sub = new String(BinopWord(op));
			r.Operands.Add(va);
			r.Operands.Add(vb);
			return r;
		}

		/// A Select whose condition is a lane mask: both inputs, then `select` per lane.
		IRValue VectorSelectNode(BNode n)
		{
			let t = Sub(n.FindOut("result").Type);
			let c = EvalIn(n, "condition");
			let a = AsVector(EvalIn(n, "true"), t, n.Key, "result");
			let b = AsVector(EvalIn(n, "false"), t, n.Key, "result");
			let op = E.Op(.Select, t, n.Key, "result");
			op.Operands.Add(c);
			op.Operands.Add(a);
			op.Operands.Add(b);
			return op;
		}

		bool IsMaskSelect(BNode n)
		{
			let c = n.FindIn("condition");
			return c != null && c.Type != null && c.Type.IsMask;
		}

		/// Make of a vector: one value per lane (vec.make).
		IRValue VectorMakeNode(BNode n, KType t)
		{
			List<IRValue> lanes = scope .();
			for (int i < t.Length)
			{
				String pin = scope .();
				VectorRules.LanePin((int)t.Length, i, pin);
				lanes.Add(EvalIn(n, pin));
			}
			let op = VecOp("make", t, n.Key, "value");
			op.Operands.AddRange(lanes);
			return op;
		}

		/// Break of a vector: one lane (vec.get with the lane's constant index).
		IRValue VectorBreakValue(BNode n, KType t, StringView pin)
		{
			let v = EvalIn(n, "value");
			int lane = -1;
			for (int i < t.Length)
			{
				String name = scope .();
				VectorRules.LanePin((int)t.Length, i, name);
				if (name == pin)
					lane = i;
			}
			let op = VecOp("get", t.Element, n.Key, pin);
			op.Operands.Add(v);
			op.Index = (int32)Math.Max(lane, 0);
			return op;
		}

		/// The lanes `mask` picks from `a` (and `b`): one lane is vec.get, more a vec.shuffle.
		IRValue Pick(IRValue a, IRValue b, List<int> mask, KType result, StringView node, StringView pin)
		{
			if (mask.Count == 1 && b == null)
			{
				let op = VecOp("get", result, node, pin);
				op.Operands.Add(a);
				op.Index = (int32)mask[0];
				return op;
			}
			let op = VecOp("shuffle", result, node, pin);
			op.Operands.Add(a);
			if (b != null)
				op.Operands.Add(b);
			op.Lit = new String();
			for (let i in mask)
				op.Lit.AppendF("{}{}", (@i.Index > 0) ? " " : "", i);
			return op;
		}

		IRValue SwizzleValue(BNode n)
		{
			let o = n.FindOut("result");
			if (n.VecMask == null || o == null || o.Type == null || o.Type.IsError)
				return E.Const("zero", T.Int, n.Key, "result");
			let v = EvalIn(n, "value");
			return Pick(v, null, n.VecMask, Sub(o.Type), n.Key, "result");
		}

		IRValue ShuffleValue(BNode n)
		{
			let o = n.FindOut("result");
			if (n.VecMask == null || o == null || o.Type == null || o.Type.IsError)
				return E.Const("zero", T.Int, n.Key, "result");
			let a = EvalIn(n, "a");
			IRValue b = null;
			for (let i in n.VecMask)
				if (i >= n.Subject.Length)
					b = EvalIn(n, "b");
			if (b == null && n.VecMask.Count > 1)
				return Pick(a, null, n.VecMask, Sub(o.Type), n.Key, "result");
			return Pick(a, b, n.VecMask, Sub(o.Type), n.Key, "result");
		}

		/// A lane index: its constant (a literal) or -1 for a value known when the program runs.
		static int64 ConstLane(IRValue i)
		{
			if (let op = i as IROp)
				if (op.Kind == .Const && op.Lit != null && int64.Parse(op.Lit) case .Ok(let v))
					return v;
			return -1;
		}

		IRValue Intr(StringView what, KType type, StringView node, StringView pin, params IRValue[] args)
		{
			let op = E.Op(.Intrinsic, type, node, pin);
			op.Sub = new String(what);
			for (let a in args)
				op.Operands.Add(a);
			return op;
		}

		IRValue Reduce(StringView what, IRValue v, StringView node, StringView pin)
		{
			let op = VecOp("reduce", v.Type.Element, node, pin);
			op.Lit = new String(what);
			op.Operands.Add(v);
			return op;
		}

		IRValue Binop(StringView what, IRValue a, IRValue b, StringView node, StringView pin)
		{
			let op = E.Op(.Binop, a.Type, node, pin);
			op.Sub = new String(what);
			op.Operands.Add(a);
			op.Operands.Add(b);
			return op;
		}

		/// The base pointer and the length of a span (Core.Span<T>: `{ T* ptr, int length }`).
		IRValue SpanPart(IRValue span, int32 index, KType t, StringView node, StringView pin)
		{
			let ex = E.Op(.Extract, t, node, pin);
			ex.Operands.Add(span);
			ex.Index = index;
			return ex;
		}

		/// The address of span[index] after the Debug check that `lanes` lanes from there are inside.
		IRValue SpanLanes(IRValue span, IRValue index, KType e, int lanes, StringView node, StringView pin)
		{
			let ptr = SpanPart(span, 0, T.Pointer(e), node, pin);
			let len = SpanPart(span, 1, T.Int, node, pin);
			let chk = VecOp("spancheck", T.Void, node, pin);
			chk.Operands.Add(index);
			chk.Operands.Add(len);
			chk.Index = (int32)lanes;
			let addr = E.Op(.ElemAddr, T.Pointer(e), node, pin);
			addr.Operands.Add(ptr);
			addr.Operands.Add(index);
			return addr;
		}

		static int32 LaneAlign(KType e) => (e.Kind == .Bool) ? 1 : (int32)(e.Bits / 8);

		/// A Call of a vector function (Core.Vector, Core.Math on vectors).
		IRValue VectorCallNode(BNode n, StringView pin)
		{
			let vt = Sub(n.Subject);
			if (vt == null || !vt.IsVector)
				return E.Const("zero", T.Int, n.Key, pin);
			let resOut = n.FindOut("result");
			let rt = (resOut != null) ? Sub(resOut.Type) : T.Void;
			return VectorFnValue(n.VecFn, vt, rt, scope (name) => EvalIn(n, name), n.Key, pin);
		}

		/// The ops of a vector function on `vt` (`input` makes the value of an input by its pin name).
		IRValue VectorFnValue(VecFn fn, KType vt, KType rt, delegate IRValue(StringView name) input, StringView key, StringView pin)
		{
			let e = vt.Element;
			IRValue In(StringView name) => input(name);
			IRValue InV(StringView name) => AsVector(input(name), vt, key, pin);
			switch (fn)
			{
			case .Splat:
				return Splat(In("value"), e, vt, key, pin);
			case .GetLane, .WithLane:
				let v = In("v");
				let i = In("i");
				let s = (fn == .WithLane) ? In("s") : null;
				let ci = ConstLane(i);
				let op = VecOp((fn == .GetLane) ? "get" : "set", (fn == .GetLane) ? e : vt, key, pin);
				if (ci >= 0 && ci < vt.Length)
				{
					op.Operands.Add(v);
					op.Index = (int32)ci;
				}
				else
				{
					let chk = E.Op(.LaneCheck, T.Void, key, pin);
					chk.Operands.Add(i);
					chk.Index = (int32)vt.Length;
					// the check before the lane op that it guards
					E.Block.Ops.Remove(chk);
					E.Block.Ops.Insert(E.Block.Ops.IndexOf(op), chk);
					op.Operands.Add(v);
					op.Operands.Add(i);
				}
				if (s != null)
					op.Operands.Add(s);
				return op;
			case .Sum: return Reduce("add", In("v"), key, pin);
			case .Product: return Reduce("mul", In("v"), key, pin);
			case .MinLane: return Reduce("min", In("v"), key, pin);
			case .MaxLane: return Reduce("max", In("v"), key, pin);
			case .And: return Reduce("and", In("v"), key, pin);
			case .Or: return Reduce("or", In("v"), key, pin);
			case .Xor: return Reduce("xor", In("v"), key, pin);
			case .Any, .All, .Bitmask:
				let m = In("m");
				let op = VecOp((fn == .Any) ? "any" : ((fn == .All) ? "all" : "bitmask"), rt, key, pin);
				op.Operands.Add(m);
				return op;
			case .Equal:
				// the inputs first: an op may use only values emitted before it
				let ea = In("a");
				let eb = In("b");
				let eq = E.Op(.Cmp, T.MaskOf(vt), key, pin);
				eq.Sub = new String("eq");
				eq.Operands.Add(ea);
				eq.Operands.Add(eb);
				let op = VecOp("all", T.Bool, key, pin);
				op.Operands.Add(eq);
				return op;
			case .Load:
				let span = In("span");
				let idx = In("index");
				let addr = SpanLanes(span, idx, e, (int)vt.Length, key, pin);
				let op = VecOp("load", vt, key, pin);
				op.Operands.Add(addr);
				op.Index = LaneAlign(e);
				return op;
			case .Store:
				let v = In("v");
				let span = In("span");
				let idx = In("index");
				let addr = SpanLanes(span, idx, e, (int)vt.Length, key, pin);
				let op = VecOp("store", T.Void, key, pin);
				op.Operands.Add(addr);
				op.Operands.Add(v);
				op.Index = LaneAlign(e);
				return null;
			case .LoadPtr:
				let ptr = In("ptr");
				let op = VecOp("load", vt, key, pin);
				op.Operands.Add(ptr);
				op.Index = LaneAlign(e);
				return op;
			case .StorePtr:
				let v = In("v");
				let p = In("ptr");
				let op = VecOp("store", T.Void, key, pin);
				op.Operands.Add(p);
				op.Operands.Add(v);
				op.Index = LaneAlign(e);
				return null;
			case .Dot:
				return Reduce("add", Binop("mul", In("a"), In("b"), key, pin), key, pin);
			case .Length:
				let v = In("v");
				return Intr("sqrt", e, key, pin, Reduce("add", Binop("mul", v, v, key, pin), key, pin));
			case .Normalize:
				let v = In("v");
				let len = Intr("sqrt", e, key, pin, Reduce("add", Binop("mul", v, v, key, pin), key, pin));
				let q = Binop("div", v, Splat(len, e, vt, key, pin), key, pin);
				let zero = E.Const("0", e, key, pin);
				let isZero = E.Op(.Cmp, T.Bool, key, pin);
				isZero.Sub = new String("eq");
				isZero.Operands.Add(len);
				isZero.Operands.Add(zero);
				let zeros = E.Const("zero", vt, key, pin); // before the select that uses it
				let sel = E.Op(.Select, vt, key, pin);
				sel.Operands.Add(isZero);
				sel.Operands.Add(zeros);
				sel.Operands.Add(q);
				return sel;
			case .Cross:
				let a = In("a");
				let b = In("b");
				let four = vt.Length == 4;
				List<int> yzx = scope .() { 1, 2, 0 };
				List<int> zxy = scope .() { 2, 0, 1 };
				if (four)
				{
					yzx.Add(3);
					zxy.Add(3);
				}
				let l = Binop("mul", Pick(a, null, yzx, vt, key, pin), Pick(b, null, zxy, vt, key, pin), key, pin);
				let r = Binop("mul", Pick(a, null, zxy, vt, key, pin), Pick(b, null, yzx, vt, key, pin), key, pin);
				return Binop("sub", l, r, key, pin);
			case .Lerp:
				let a = In("a");
				let b = In("b");
				let t = InV("t");
				return Binop("add", a, Binop("mul", Binop("sub", b, a, key, pin), t, key, pin), key, pin);
			case .Sqrt: return Intr("sqrt", vt, key, pin, In("x"));
			case .Abs: return Intr((e.Kind == .Float) ? "fabs" : "abs", vt, key, pin, In("x"));
			case .Floor: return Intr("floor", vt, key, pin, In("x"));
			case .Ceil: return Intr("ceil", vt, key, pin, In("x"));
			case .Round: return Intr("round", vt, key, pin, In("x"));
			case .Truncate: return Intr("trunc", vt, key, pin, In("x"));
			case .Sin: return Intr("sin", vt, key, pin, In("x"));
			case .Cos: return Intr("cos", vt, key, pin, In("x"));
			case .Exp: return Intr("exp", vt, key, pin, In("x"));
			case .Log: return Intr("log", vt, key, pin, In("x"));
			case .Pow: return Intr("pow", vt, key, pin, In("x"), InV("y"));
			case .CopySign: return Intr("copysign", vt, key, pin, In("x"), InV("y"));
			case .Fma: return Intr("fma", vt, key, pin, In("a"), InV("b"), InV("c"));
			case .Min, .Max:
				let isMin = fn == .Min;
				StringView what = (e.Kind == .Float) ? (isMin ? "minnum" : "maxnum") : (e.Signed ? (isMin ? "smin" : "smax") : (isMin ? "umin" : "umax"));
				return Intr(what, vt, key, pin, In("a"), InV("b"));
			case .Clamp:
				let fl = e.Kind == .Float;
				let lo = InV("min");
				let hi = InV("max");
				let up = Intr(fl ? "maxnum" : (e.Signed ? "smax" : "umax"), vt, key, pin, In("x"), lo);
				return Intr(fl ? "minnum" : (e.Signed ? "smin" : "umin"), vt, key, pin, up, hi);
			default:
				return E.Const("zero", (rt != null && !rt.IsVoid) ? rt : T.Int, key, pin);
			}
		}

		/// Cast `set kind bits` between vectors: the same bytes (vec.bitcast).
		IRValue VectorBits(IRValue v, KType to, StringView node, StringView pin)
		{
			let op = VecOp("bitcast", to, node, pin);
			op.Operands.Add(v);
			return op;
		}

		// ---- Hash.Equal and Hash.Get of vectors; vectors in a Math Expression (SIMD-and-Vectors.md 1.8)

		/// Hash.Equal of two vectors: every lane == (a NaN lane is unequal, -0.0 equals 0.0).
		IRValue VectorEqual(IRValue a, IRValue b, StringView node, StringView pin)
		{
			let eq = Op2(.Cmp, "eq", T.MaskOf(a.Type), a, b, node, pin);
			let op = VecOp("all", T.Bool, node, pin);
			op.Operands.Add(eq);
			return op;
		}

		/// Hash.Get of a vector: FNV-1a over the bytes of its lanes, lane 0 first (-0.0 and 0.0 hash
		/// differently; a 3-lane vector hashes its 3 lanes).
		IRValue VectorHash(IRValue v, StringView node, StringView pin)
		{
			let vt = v.Type;
			let e = vt.Element;
			let bytes = (e.Kind == .Bool) ? 1 : e.Bits / 8;
			// the lanes as integers of their width (a mask's lanes as bytes)
			IRValue ints = v;
			KType intLane = (e.Kind == .Bool) ? T.UInt8 : ((e.Kind == .Int) ? e : T.Prim(scope String()..AppendF("uint{}", e.Bits)));
			let iv = T.Vector(intLane, (int)vt.Length);
			if (e.Kind == .Bool)
				ints = Op1(.Cast, iv, v, node, pin);
			else if (e.Kind == .Float)
				ints = VectorBits(v, iv, node, pin);
			IRValue h = E.Const("-3750763034362895579", T.Int, node, pin); // the FNV offset basis 14695981039346656037
			let prime = E.Const("1099511628211", T.Int, node, pin);
			let mask = E.Const("255", T.Int, node, pin);
			for (int lane < vt.Length)
			{
				let g = VecOp("get", intLane, node, pin);
				g.Operands.Add(ints);
				g.Index = (int32)lane;
				let w = Op1(.Cast, T.Int, Op1(.Cast, T.Prim("uint"), g, node, pin), node, pin);
				for (int k < bytes)
				{
					let sh = Op2(.Binop, "shr", T.Int, w, E.Const(scope String()..AppendF("{}", k * 8), T.Int, node, pin), node, pin);
					let byte = Op2(.Binop, "and", T.Int, sh, mask, node, pin);
					let x = Op2(.Binop, "xor", T.Int, h, byte, node, pin);
					h = Op2(.Binop, "mul", T.Int, x, prime, node, pin);
				}
			}
			return h;
		}

		IRValue MathVector(BNode n, MathNode m)
		{
			let key = n.Key;
			let vt = Sub(m.Operand);
			if (vt == null || !vt.IsVector)
				return E.Const("zero", T.Int, key, "result");
			let e = vt.Element;
			if (m.VecMake)
			{
				if (m.Args.Count == 1)
				{
					let a = m.Args[0];
					if (a.Type != null && Sub(a.Type) == vt)
						return MathValue(n, a, false);
					return Splat(MathAs(n, a, e), e, vt, key, "result");
				}
				List<IRValue> lanes = scope .();
				for (let a in m.Args)
					lanes.Add(MathAs(n, a, e));
				let op = VecOp("make", vt, key, "result");
				op.Operands.AddRange(lanes);
				return op;
			}
			let f = VectorRules.Of(m.VecFn);
			List<(StringView name, char8 kind)> pins = scope .();
			VectorRules.Pins(f, pins);
			IRValue Input(StringView name)
			{
				for (int i < pins.Count)
				{
					if (pins[i].name != name || i >= m.Args.Count)
						continue;
					let a = m.Args[i];
					KType want;
					switch (pins[i].kind)
					{
					case 'V': want = vt;
					case 'M': want = vt.IsMask ? vt : T.MaskOf(vt);
					case 'E': want = e;
					case 'I': want = T.Int;
					case 'X': want = (a.Type != null && a.Type.IsVector) ? vt : e;
					default: want = vt;
					}
					return MathAs(n, a, want);
				}
				return E.Const("zero", vt, key, "result");
			}
			return VectorFnValue(m.VecFn, vt, Sub(m.Type), scope (name) => Input(name), key, "result");
		}

		/// `c ? a : b` with a lane mask `c`: both arms, `select` per lane.
		IRValue MathMaskSelect(BNode n, MathNode m)
		{
			let t = Sub(m.Operand ?? m.Type);
			let c = MathValue(n, m.A, false);
			let a = AsVector(MathAs(n, m.B, (m.B.Type != null && m.B.Type.IsVector) ? t : t.Element), t, n.Key, "result");
			let b = AsVector(MathAs(n, m.C, (m.C.Type != null && m.C.Type.IsVector) ? t : t.Element), t, n.Key, "result");
			let op = E.Op(.Select, t, n.Key, "result");
			op.Operands.Add(c);
			op.Operands.Add(a);
			op.Operands.Add(b);
			return op;
		}
	}
}
