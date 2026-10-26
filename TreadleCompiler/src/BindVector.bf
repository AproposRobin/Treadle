using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;

namespace Treadle.Compiler
{
	extension BNode
	{
		/// A Call of a vector function (Core.Vector, or a Core.Math function on vectors): which one;
		/// Subject is the vector type it works on (VectorRules.Functions).
		public VecFn VecFn;
		/// Swizzle / Shuffle: the lanes picked (0..N-1 the first input, N..2N-1 the second).
		public List<int> VecMask ~ delete _;
	}

	/// Binding of the vector primitives (docs/SIMD-and-Vectors.md 1): the Operator, Select, Cast,
	/// Make and Break nodes on vectors, the Swizzle and Shuffle nodes, and Calls of the vector
	/// functions. Each Try* returns false when the node does not involve a vector (the node's own
	/// binder goes on).
	extension SheetBinder
	{
		/// The type an input brings: its wire's, else its literal's when that is a plain scalar.
		KType VecIn(BNode b, StringView pin, out bool literal)
		{
			literal = false;
			let t = InType(b, pin);
			if (t != null)
				return t;
			let lit = Lit(b, pin);
			if (lit.IsEmpty)
				return null;
			literal = true;
			return Literals.TypeOf(lit, T);
		}

		/// The other side of a vector operand: a scalar that splats (a literal, or a value that converts
		/// to the lane type) or the same vector type. False with the message for T2320.
		bool VecSide(KType vec, KType other, bool literal, StringView lit, String why)
		{
			if (other == null || other.IsError || other == vec)
				return true;
			if (other.IsVector)
			{
				why.AppendF("{} and {} differ: Cast one of them (lane types and counts change through a Cast)", vec.Name, other.Name);
				return false;
			}
			if (literal)
			{
				String w = scope .();
				if (VectorRules.LiteralFits(lit, vec, T, w))
					return true;
				why.Append(w);
				return false;
			}
			if (T.CanConvert(other, vec.Element) != .Refused)
				return true;
			why.AppendF("{} does not splat into {} (its lanes are {}): Cast it first", TypeTable.WithArticle(other, .. scope .()), vec.Name, vec.Element.Name);
			return false;
		}

		/// An Operator node with a vector operand: element-wise, a scalar side splats, a comparison
		/// gives a lane mask, `&&` / `||` on masks are T2300 (`&`, `|` work lane by lane).
		bool TryBindVectorOperator(BNode b, StringView op, bool unary, bool logical, bool compare)
		{
			let ta = VecIn(b, "a", let litA);
			bool litB = false;
			KType tb = null;
			if (!unary)
				tb = VecIn(b, "b", out litB);
			if (!(ta != null && ta.IsVector) && !(tb != null && tb.IsVector))
				return false;
			b.Flow = false;
			let vec = (ta != null && ta.IsVector) ? ta : tb;
			if (op == "&&" || op == "||")
			{
				Err(b, "", "T2300", scope $"{op} works on bools: a lane mask ({vec.Name}) is combined with & or | (every lane), or tested with Vector.Any / Vector.All");
				b.AddIn("a", ta ?? T.Error, false, "A");
				b.AddIn("b", tb ?? T.Error, false, "B");
				b.AddOut("result", T.Error);
				return true;
			}
			String why = scope .();
			if (!unary)
			{
				let otherIsB = vec == ta;
				let other = otherIsB ? tb : ta;
				let shift = op == "<<" || op == ">>";
				if (!(shift && otherIsB && other != null && other.IsInteger && !litB) && !VecSide(vec, other, otherIsB ? litB : litA, Lit(b, otherIsB ? "b" : "a"), why))
					Err(b, otherIsB ? "b" : "a", "T2320", scope $"{op}: {why}");
			}
			if (!VectorRules.SupportsOperator(vec, op))
				Err(b, "", "T2321", scope $"{vec.Name} has no operator {op}{(vec.Element.Kind == .Float) ? " (float lanes have no bitwise operators)" : ((vec.IsMask) ? " (a lane mask has & | ^ ! == !=)" : "")}");
			b.OpImpl = .Builtin;
			b.OperandType = vec;
			// a wired scalar keeps its own type on its pin (Lower splats it); a literal is a vector literal
			KType PinType(KType t, bool lit) => (t == null || lit || t.IsVector) ? vec : t;
			b.AddIn("a", PinType(ta, litA), false, "A");
			if (!unary)
				b.AddIn("b", PinType(tb, litB), false, "B");
			b.AddOut("result", compare ? T.MaskOf(vec) : vec);
			return true;
		}

		/// A Select whose condition is a lane mask: lane by lane, both inputs made (no Rule 4 short cut).
		bool TryBindVectorSelect(BNode b)
		{
			let tc = InType(b, "condition");
			if (tc == null || !tc.IsMask)
				return false;
			b.Flow = false;
			let ta = VecIn(b, "true", let litA);
			let tb = VecIn(b, "false", let litB);
			KType t = (ta != null && ta.IsVector) ? ta : ((tb != null && tb.IsVector) ? tb : null);
			if (t == null)
			{
				Err(b, "condition", "T2322", scope $"Select: a lane mask ({tc.Name}) picks lanes of two vectors; True and False are not vectors (wire vectors, or test the mask with Vector.Any / Vector.All)");
				t = T.Error;
			}
			else
			{
				if (t.Length != tc.Length)
					Err(b, "condition", "T2322", scope $"Select: the mask has {tc.Length} lanes, {t.Name} has {t.Length}");
				String why = scope .();
				if (!VecSide(t, (t == ta) ? tb : ta, (t == ta) ? litB : litA, Lit(b, (t == ta) ? "false" : "true"), why))
					Err(b, (t == ta) ? "false" : "true", "T2322", scope $"Select: {why}");
			}
			KType PinType(KType p, bool lit) => (p == null || lit || p.IsVector || t.IsError) ? t : p;
			b.AddIn("condition", tc, false, "Condition");
			b.AddIn("true", PinType(ta, litA), false, "True");
			b.AddIn("false", PinType(tb, litB), false, "False");
			b.AddOut("result", t);
			return true;
		}

		/// A Cast to or from a vector: numeric (each lane as the scalar Cast; the lane counts agree) or
		/// `set kind bits` (Reinterpret: the same bytes as another vector of the same size).
		bool TryBindVectorCast(BNode b, KType to, KType from, StringView kind)
		{
			if (!(to != null && to.IsVector) && !(from != null && from.IsVector))
				return false;
			b.Flow = false;
			b.AddIn("value", from ?? T.Error, false, "Value");
			b.AddOut("result", to);
			if (from == null || from.IsError || to.IsError)
				return true;
			if (!from.IsVector || !to.IsVector)
			{
				Err(b, "value", "T2325", scope $"a vector Cast converts a vector to a vector ({from.Name} to {to.Name}); a scalar becomes a vector through Vector.Splat or Make");
				return true;
			}
			switch (kind)
			{
			case "", "numeric":
				b.Cast = (from == to) ? .Identity : .Numeric;
				if (from.Length != to.Length)
					Err(b, "value", "T2325", scope $"a numeric Cast keeps the lane count: {from.Name} has {from.Length} lanes, {to.Name} {to.Length} (Shuffle or Make picks lanes)");
			case "bits":
				// Reinterpret: the same bits as the other vector type
				b.Cast = .Unchecked;
				let fb = (int64)LaneBits(from.Element) * from.Length;
				let tbits = (int64)LaneBits(to.Element) * to.Length;
				if (from.IsMask || to.IsMask)
					Err(b, "value", "T2325", "a lane mask has no bits to reinterpret: Cast it to integer lanes (numeric)");
				else if (fb != tbits)
					Err(b, "value", "T2325", scope $"Reinterpret keeps the size: {from.Name} is {fb / 8} bytes, {to.Name} {tbits / 8}");
			default:
				Err(b, "", "T2325", scope $"'{kind}' is not a vector Cast (numeric, or bits to reinterpret)");
			}
			return true;
		}

		static int32 LaneBits(KType e) => (e.Kind == .Bool) ? 1 : e.Bits;

		/// Make / Break of a vector: one pin per lane (`x y z w`, `lane0 ...` above 4 lanes).
		bool TryBindVectorMake(BNode b, KType t)
		{
			if (!t.IsVector)
				return false;
			b.Flow = false;
			let isMake = b.Node.Kind == .Make;
			for (int i < t.Length)
			{
				String pin = scope .();
				VectorRules.LanePin((int)t.Length, i, pin);
				if (isMake)
					b.AddIn(pin, t.Element, true, pin);
				else
					b.AddOut(pin, t.Element);
			}
			if (isMake)
				b.AddOut("value", t);
			else
				b.AddIn("value", t, false, "Value");
			return true;
		}

		/// The Swizzle node (`set lanes zyx`): `value` -> `result`, the lanes the letters pick (one
		/// letter gives the lane's value).
		void BindSwizzle(BNode b)
		{
			b.Flow = false;
			let vt = InType(b, "value");
			StringView letters = b.Node.GetSetting("lanes");
			b.AddIn("value", vt ?? T.Error, false, "Value");
			if (vt == null || vt.IsError)
			{
				b.AddOut("result", T.Error);
				return;
			}
			if (!vt.IsVector)
			{
				Err(b, "value", "T2324", scope $"Swizzle picks lanes of a vector, not of {TypeTable.WithArticle(vt, .. scope .())}");
				b.AddOut("result", T.Error);
				return;
			}
			b.VecMask = new .();
			String code = scope .();
			String why = scope .();
			if (!VectorRules.Swizzle(letters, (int)vt.Length, b.VecMask, code, why))
			{
				Err(b, "", code, scope $"Swizzle: {why}");
				b.AddOut("result", T.Error);
				return;
			}
			b.Subject = vt;
			b.AddOut("result", (b.VecMask.Count == 1) ? vt.Element : T.Vector(vt.Element, b.VecMask.Count));
		}

		/// The Shuffle node (`set mask 0 4 1 5`): lanes of `a` (0..N-1) and `b` (N..2N-1), as many as
		/// the mask has numbers (2, 3, 4, 8, 16 ...).
		void BindShuffle(BNode b)
		{
			b.Flow = false;
			let ta = InType(b, "a");
			let tb = InType(b, "b");
			let vt = ta ?? tb;
			b.AddIn("a", vt ?? T.Error, false, "A");
			b.AddIn("b", vt ?? T.Error, true, "B");
			if (vt == null || vt.IsError)
			{
				b.AddOut("result", T.Error);
				return;
			}
			if (!vt.IsVector || (tb != null && ta != null && ta != tb))
			{
				Err(b, "", "T2323", scope $"Shuffle picks lanes of two vectors of one type, not {S!(ta)} and {S!(tb)}");
				b.AddOut("result", T.Error);
				return;
			}
			b.VecMask = new .();
			let limit = vt.Length * 2;
			StringView text = b.Node.GetSetting("mask");
			for (var part in text.Split(' '))
			{
				if (part.IsEmpty)
					continue;
				if (int.Parse(part) case .Ok(let i) && i >= 0 && i < limit)
					b.VecMask.Add(i);
				else
				{
					Err(b, "", "T2301", scope $"Shuffle: '{part}' is no lane: a mask number is 0..{vt.Length - 1} for a, {vt.Length}..{limit - 1} for b");
					b.AddOut("result", T.Error);
					return;
				}
			}
			let n = b.VecMask.Count;
			String spelled = scope .();
			VectorRules.LaneName(vt.Element, spelled);
			let laneName = scope String(spelled);
			spelled.Clear();
			VectorTypes.Spell(laneName, n, spelled);
			if (n < 2 || !VectorTypes.TryParse(spelled, ?, ?))
			{
				Err(b, "", "T2323", scope $"Shuffle: {n} lanes of {vt.Element.Name} make no vector type (2, 3, 4, 8 or 16 numbers in the mask)");
				b.AddOut("result", T.Error);
				return;
			}
			b.Subject = vt;
			b.AddOut("result", T.Vector(vt.Element, n));
		}

		/// A Call of a vector function: Core.Vector's, or a Core.Math function given a vector. False
		/// for any other call (BindCall goes on).
		bool TryBindVectorCall(BNode b, MemberRef mr)
		{
			if (mr.Owner != .Type || mr.Type == null)
				return false;
			let ownerName = mr.Type.Name;
			let isVector = ownerName == "Vector" || ownerName == "Core.Vector";
			let isMath = ownerName == "Math" || ownerName == "Core.Math";
			if (!isVector && !isMath)
				return false;
			let n = b.Node;
			KType setType = null;
			// the vector type a Load / Splat makes: `Core.Vector.Load<float4>`, or `set type float4`
			StringView fnName = mr.Name;
			StringView typeText = n.GetSetting("type");
			let lt = fnName.IndexOf('<');
			if (lt > 0 && fnName.EndsWith('>'))
			{
				typeText = fnName.Substring(lt + 1, fnName.Length - lt - 2);
				fnName = fnName.Substring(0, lt);
			}
			if (!typeText.IsEmpty)
			{
				let tr = TypeRef.Parse(typeText);
				defer delete tr;
				setType = c.Resolve(tr, Ctx(b));
			}
			if (isMath)
			{
				// a Math function takes the vector path only when it is given a vector
				bool any = setType != null && setType.IsVector;
				for (let p in n.Inputs)
					if (p.Kind == .Value)
					{
						let t = InType(b, p.Name);
						if (t != null && t.IsVector)
							any = true;
					}
				if (!any)
					return false;
			}
			let f = VectorRules.Find(fnName, isMath);
			if (f == null)
			{
				Err(b, "", "T2329", isVector ? scope $"Vector has no function {fnName}" : scope $"Math.{fnName} has no vector form");
				AddLooseFlow(b);
				AddLooseValues(b);
				return true;
			}
			b.VecFn = f.Fn;
			if (f.Unsafe)
				b.Unsafe = true;
			List<(StringView name, char8 kind)> pins = scope .();
			VectorRules.Pins(f, pins);
			// the vector type: `set type`, else the first vector (or mask) input
			KType vt = (setType != null && setType.IsVector) ? setType : null;
			if (vt == null)
				for (let p in pins)
					if (p.kind == 'V' || p.kind == 'M')
					{
						let t = InType(b, p.name);
						if (t != null && t.IsVector)
						{
							vt = t;
							break;
						}
					}
			if (vt == null && f.NeedsType)
				Err(b, "", "T2326", scope $"Vector.{f.Name}: name the vector type it makes (Core.Vector.{f.Name}<float4>, or set type float4)");
			else if (vt == null)
				Err(b, "", "T2329", scope $"{(isVector ? "Vector" : "Math")}.{f.Name}: wire a vector into it (the type follows the vector)");
			String why = scope .();
			if (vt != null && !VectorRules.LanesFit(f, vt, why))
				Err(b, "", (f.Fn == .Sum || f.Fn == .Product || f.Fn == .MinLane || f.Fn == .MaxLane || f.Fn == .And || f.Fn == .Or || f.Fn == .Xor) ? "T2328" : "T2329", why);
			let v = vt ?? T.Error;
			b.Subject = v;
			let e = vt?.Element ?? T.Error;
			for (let p in pins)
			{
				KType pt;
				switch (p.kind)
				{
				case 'V': pt = v;
				case 'M': pt = (vt != null) ? (vt.IsMask ? vt : T.MaskOf(vt)) : T.Error;
				case 'E': pt = e;
				case 'I': pt = T.Int;
				case 'S': pt = (T.SpanSym != null && vt != null) ? T.Named(T.SpanSym, scope KType[](e)) : T.Error;
				case 'P': pt = (vt != null) ? T.Pointer(e) : T.Error;
				case 'X':
					// a scalar splats (a literal is one; a wired lane value too)
					let wired = InType(b, p.name);
					pt = (wired != null && !wired.IsVector && vt != null && T.CanConvert(wired, e) != .Refused) ? wired : v;
				default: pt = T.Error;
				}
				b.AddIn(p.name, pt, false, p.name);
				if ((p.kind == 'V' || p.kind == 'M') && vt != null)
				{
					let w = InType(b, p.name);
					if (w != null && !w.IsError && w != pt)
						Err(b, p.name, "T2320", scope $"{p.name}: {f.Name} takes {pt.Name} here (the vector the node works on), not {S!(w)}");
				}
				if ((p.kind == 'S' || p.kind == 'P') && vt != null)
				{
					let w = InType(b, p.name);
					if (w != null && !w.IsError && T.CanConvert(w, pt) == .Refused)
						Err(b, p.name, "T2327", scope $"{p.name}: Vector.{f.Name} reads {e.Name} lanes, so it takes {S!(pt)}, not {S!(w)}");
				}
				if (p.kind == 'I' && (f.Fn == .GetLane || f.Fn == .WithLane) && vt != null)
				{
					let lit = Lit(b, p.name);
					if (!lit.IsEmpty && int64.Parse(lit) case .Ok(let li) && (li < 0 || li >= vt.Length))
						Err(b, p.name, "T2301", scope $"{f.Name}: lane {li} is outside {vt.Name} (0..{vt.Length - 1})");
				}
			}
			switch (f.Result)
			{
			case 'V': b.AddOut("result", v);
			case 'E': b.AddOut("result", e);
			case 'B': b.AddOut("result", T.Bool);
			case 'U': b.AddOut("result", T.Prim("uint"));
			default:
			}
			if (b.Flow)
			{
				b.AddIn("in", null);
				b.AddFlowOut("then");
			}
			else if (f.Flow)
				Err(b, "", "T2068", scope $"Vector.{f.Name} writes memory: it runs in the flow. Wire its flow pins.");
			return true;
		}
	}

	/// Vectors in a Math Expression and a constant's init (docs/SIMD-and-Vectors.md 1.8): `float4(a, b, c,
	/// d)` makes one (one input splats), `v.zyx` / `(a + b).xy` swizzle, a scalar or a literal splats where
	/// it meets a vector, comparisons give a lane mask, `c ? a : b` with a mask condition selects per lane,
	/// `&&` `||` on masks are T2300, the Math functions with a vector form take vectors.
	extension ExprTyper
	{
		KType VectorCommon(KType ta, KType tb)
		{
			if (ta.IsError)
				return tb;
			if (tb.IsError)
				return ta;
			if (ta == tb)
				return ta;
			if (ta.IsVector && tb.IsVector)
				return null;
			let v = ta.IsVector ? ta : tb;
			let s = ta.IsVector ? tb : ta;
			return (T.CanConvert(s, v.Element) != .Refused) ? v : null;
		}

		bool VectorNot(MathNode n)
		{
			let t = Type(n.A);
			if (t == null || !t.IsMask)
				return false;
			n.Operand = t;
			n.Type = t;
			return true;
		}

		bool VectorLogical(MathNode n)
		{
			let ta = Type(n.A);
			let tb = Type(n.B);
			if (!(ta != null && ta.IsVector) && !(tb != null && tb.IsVector))
				return false;
			Fail(n, .Mask, scope $"{n.Text} works on bools: lane masks combine with & or | (every lane), or are tested with Vector.Any / Vector.All");
			n.Type = T.Error;
			return true;
		}

		bool VectorTernary(MathNode n)
		{
			let tc = Type(n.A);
			if (tc == null || !tc.IsMask)
				return false;
			let ta = Type(n.B);
			let tb = Type(n.C);
			KType t = (ta != null && ta.IsVector) ? ta : ((tb != null && tb.IsVector) ? tb : null);
			if (t == null)
			{
				Fail(n, .Vector, scope $"a lane mask ({tc.Name}) picks lanes of two vectors: ? : needs vectors (or test the mask with Vector.Any / Vector.All)");
				n.Type = T.Error;
				return true;
			}
			for (let arm in StringView[?]("b", "c"))
			{
				let m = (arm == "b") ? n.B : n.C;
				if (m.Adopts)
					Adopt(m, t);
				else if (m.Type != null && m.Type != t && VectorCommon(m.Type, t) != t)
					Fail(m, .Vector, scope $"? : gives {t.Name}: {TypeTable.WithArticle(m.Type, .. scope .())} does not splat into it");
			}
			if (t.Length != tc.Length)
				Fail(n, .Vector, scope $"the mask has {tc.Length} lanes, {t.Name} has {t.Length}");
			n.Operand = t;
			n.Type = t;
			return true;
		}

		/// The lanes `letters` pick of a `vt`; the type it gives (one letter: the lane's), or Error.
		public KType SwizzleOf(MathNode at, KType vt, StringView letters)
		{
			let before = at.Lanes;
			defer delete before;
			at.Lanes = new .();
			String code = scope .();
			String why = scope .();
			if (!VectorRules.Swizzle(letters, (int)vt.Length, at.Lanes, code, why))
			{
				Fail(at, .Lanes, why);
				return T.Error;
			}
			// a swizzle of a swizzle on one path (`v.zyx.xy`): picked from the lanes the first one picked
			if (before != null)
				for (int i < at.Lanes.Count)
					at.Lanes[i] = before[at.Lanes[i]];
			return (at.Lanes.Count == 1) ? vt.Element : T.Vector(vt.Element, at.Lanes.Count);
		}

		void TypeSwizzle(MathNode n)
		{
			let t = Type(n.A);
			if (t == null || t.IsError)
			{
				n.Type = t;
				return;
			}
			if (!t.IsVector)
			{
				Fail(n, .Lanes, scope $".{n.Text}: {TypeTable.WithArticle(t, .. scope .())} has no lanes to swizzle");
				n.Type = T.Error;
				return;
			}
			DeleteAndNullify!(n.Lanes);
			n.Type = SwizzleOf(n, t, n.Text);
		}

		/// `float4(...)` and the Math functions given a vector; false for any other call.
		bool VectorCall(MathNode n, StringView path, List<MathNode> args)
		{
			n.VecFn = .None;
			n.VecMake = false;
			let vt = T.VectorByName(path);
			if (vt != null)
			{
				n.VecMake = true;
				n.Type = vt;
				n.Operand = vt;
				for (let a in args)
				{
					let t = Type(a);
					if (a.Adopts)
						Adopt(a, vt.Element);
					else if (t == null)
						AdoptDeep(a, vt.Element);
					else if (!t.IsError && !(args.Count == 1 && t == vt) && T.CanConvert(t, vt.Element) == .Refused)
						Fail(a, .Vector, scope $"{vt.Name}(...) takes {vt.Element.Name} lanes, not {TypeTable.WithArticle(t, .. scope .())}");
				}
				if (args.Count != 1 && args.Count != vt.Length)
					Fail(n, .Vector, scope $"{vt.Name}(...) takes {vt.Length} lanes or one value for all of them, not {args.Count}");
				return true;
			}
			var name = path;
			let dot = path.LastIndexOf('.');
			if (dot >= 0)
			{
				let owner = path.Substring(0, dot);
				if (owner != "Math" && owner != "Core.Math")
					return false;
				name = path.Substring(dot + 1);
			}
			KType vec = null;
			for (let a in args)
			{
				let t = Type(a);
				if (t != null && t.IsVector && vec == null)
					vec = t;
			}
			if (vec == null)
				return false;
			let f = VectorRules.Find(name, true);
			if (f == null)
			{
				Fail(n, .Function, scope $"Math.{name} has no vector form");
				n.Type = T.Error;
				return true;
			}
			List<(StringView name, char8 kind)> pins = scope .();
			VectorRules.Pins(f, pins);
			if (pins.Count != args.Count)
			{
				Fail(n, .Function, scope $"{name} takes {pins.Count} inputs here");
				n.Type = T.Error;
				return true;
			}
			String why = scope .();
			if (!VectorRules.LanesFit(f, vec, why))
				Fail(n, .Function, why);
			n.VecFn = f.Fn;
			n.Operand = vec;
			for (int i < args.Count)
			{
				let a = args[i];
				KType want;
				switch (pins[i].kind)
				{
				case 'V', 'X': want = vec;
				case 'M': want = vec.IsMask ? vec : T.MaskOf(vec);
				case 'E': want = vec.Element;
				case 'I': want = T.Int;
				default: want = T.Error;
				}
				if (a.Adopts)
					Adopt(a, (pins[i].kind == 'X') ? vec.Element : want);
				else if (a.Type == null)
					AdoptDeep(a, want);
				else if (!a.Type.IsError && a.Type != want && !(pins[i].kind == 'X' && T.CanConvert(a.Type, vec.Element) != .Refused) && T.CanConvert(a.Type, want) == .Refused)
					Fail(a, .Vector, scope $"{name} takes {TypeTable.WithArticle(want, .. scope .())} here, not {TypeTable.WithArticle(a.Type, .. scope .())}");
			}
			switch (f.Result)
			{
			case 'V': n.Type = vec;
			case 'E': n.Type = vec.Element;
			case 'B': n.Type = T.Bool;
			case 'U': n.Type = T.Prim("uint");
			default: n.Type = T.Error;
			}
			return true;
		}
	}
}
