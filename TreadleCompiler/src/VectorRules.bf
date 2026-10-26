using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	// The vector primitives in the front end (docs/SIMD-and-Vectors.md 1): the type kind, its names
	// (`float4`, `int32x4`, `bool4`; `Vector<float,4>` read as the same type), operators, literals,
	// swizzle letters and the vector functions of Core.Vector and Core.Math (an intrinsic table:
	// the functions are generic over vector types and give the lane type back, which the core's
	// generics cannot state). BindVector.bf binds the nodes, LowerVector.bf lowers them.

	extension TypeTable
	{
		/// The vector of `lanes` lanes of `elem` (interned; its name is the short spelling).
		public KType Vector(KType elem, int lanes)
		{
			String name = scope .();
			VectorRules.LaneName(elem, name);
			let laneName = scope String(name);
			name.Clear();
			VectorTypes.Spell(laneName, lanes, name);
			let t = Intern(.Vector, scope String()..AppendF("V{}", name), name);
			if (t.Element == null)
			{
				t.Element = elem;
				t.Length = lanes;
			}
			return t;
		}

		/// The mask type of a vector (`bool4` for `float4`).
		public KType MaskOf(KType v) => Vector(Bool, (int)v.Length);

		/// The vector type a name spells (`float4`), or null.
		public KType VectorByName(StringView name)
		{
			if (!VectorTypes.TryParse(name, let elem, let lanes))
				return null;
			let e = Prim(elem);
			return (e != null) ? Vector(e, lanes) : null;
		}
	}

	/// The vector functions (Core.Vector, and the vector forms of Core.Math): Bind types their pins
	/// by the vector they take, Lower makes the vec.* / intrinsic ops.
	enum VecFn : uint8
	{
		None,
		Splat, GetLane, WithLane, Sum, Product, MinLane, MaxLane, And, Or, Xor, Any, All, Bitmask, Equal,
		Load, Store, LoadPtr, StorePtr, Dot, Length, Normalize, Cross, Lerp,
		Sqrt, Abs, Floor, Ceil, Round, Truncate, Sin, Cos, Exp, Log, Pow, Min, Max, Clamp, Fma, CopySign
	}

	static class VectorRules
	{
		/// One row of the function table: the pins (`name:kind`, kinds V vector, M lane mask, E a lane
		/// value, X a lane value or a vector (a scalar splats), I an index, S a Span of lanes, P a lane
		/// pointer), the result (V, E, B bool, U uint, - none) and what the lanes may be.
		public struct FnInfo
		{
			public VecFn Fn;
			public StringView Name;
			public StringView Pins;
			public char8 Result;
			/// `f` float lanes only, `n` numbers (float or integer), `i` integers, `m` masks, `a` any.
			public char8 Lanes;
			/// Core.Vector (`V`), Core.Math (`M`) or both (`B`).
			public char8 Owner;
			/// Writes memory: a flow node.
			public bool Flow;
			/// The vector type comes from `set type` (no vector input says it).
			public bool NeedsType;
			public bool Unsafe;
			public StringView Doc;
		}

		public static FnInfo[?] Functions = .(
			.() { Fn = .Splat, Name = "Splat", Pins = "value:E", Result = 'V', Lanes = 'a', Owner = 'V', NeedsType = true, Doc = "The value in every lane (set type: the vector type)" },
			.() { Fn = .GetLane, Name = "GetLane", Pins = "v:V,i:I", Result = 'E', Lanes = 'a', Owner = 'V', Doc = "Lane i (Debug: an index outside the lanes is a fatal error)" },
			.() { Fn = .WithLane, Name = "WithLane", Pins = "v:V,i:I,s:E", Result = 'V', Lanes = 'a', Owner = 'V', Doc = "The vector with lane i replaced by s" },
			.() { Fn = .Sum, Name = "Sum", Pins = "v:V", Result = 'E', Lanes = 'n', Owner = 'V', Doc = "The sum of the lanes (floats: a fixed pairwise order)" },
			.() { Fn = .Product, Name = "Product", Pins = "v:V", Result = 'E', Lanes = 'n', Owner = 'V', Doc = "The product of the lanes (floats: a fixed pairwise order)" },
			.() { Fn = .MinLane, Name = "MinLane", Pins = "v:V", Result = 'E', Lanes = 'n', Owner = 'V', Doc = "The smallest lane (a NaN lane is ignored)" },
			.() { Fn = .MaxLane, Name = "MaxLane", Pins = "v:V", Result = 'E', Lanes = 'n', Owner = 'V', Doc = "The largest lane (a NaN lane is ignored)" },
			.() { Fn = .And, Name = "And", Pins = "v:V", Result = 'E', Lanes = 'i', Owner = 'V', Doc = "The lanes and-ed together" },
			.() { Fn = .Or, Name = "Or", Pins = "v:V", Result = 'E', Lanes = 'i', Owner = 'V', Doc = "The lanes or-ed together" },
			.() { Fn = .Xor, Name = "Xor", Pins = "v:V", Result = 'E', Lanes = 'i', Owner = 'V', Doc = "The lanes xor-ed together" },
			.() { Fn = .Any, Name = "Any", Pins = "m:M", Result = 'B', Lanes = 'm', Owner = 'V', Doc = "True when any lane of the mask is true" },
			.() { Fn = .All, Name = "All", Pins = "m:M", Result = 'B', Lanes = 'm', Owner = 'V', Doc = "True when every lane of the mask is true" },
			.() { Fn = .Bitmask, Name = "Bitmask", Pins = "m:M", Result = 'U', Lanes = 'm', Owner = 'V', Doc = "The mask's lanes as bits (lane 0 the lowest)" },
			.() { Fn = .Equal, Name = "Equal", Pins = "a:V,b:V", Result = 'B', Lanes = 'a', Owner = 'V', Doc = "True when every lane of a equals b's" },
			.() { Fn = .Load, Name = "Load", Pins = "span:S,index:I", Result = 'V', Lanes = 'a', Owner = 'V', NeedsType = true, Doc = "N lanes from span[index] on (Debug: the span is checked)" },
			.() { Fn = .Store, Name = "Store", Pins = "v:V,span:S,index:I", Result = '-', Lanes = 'a', Owner = 'V', Flow = true, Doc = "Writes the lanes to span[index] on (Debug: the span is checked)" },
			.() { Fn = .LoadPtr, Name = "LoadPtr", Pins = "ptr:P", Result = 'V', Lanes = 'a', Owner = 'V', NeedsType = true, Unsafe = true, Doc = "N lanes from a pointer (unchecked)" },
			.() { Fn = .StorePtr, Name = "StorePtr", Pins = "v:V,ptr:P", Result = '-', Lanes = 'a', Owner = 'V', Flow = true, Unsafe = true, Doc = "Writes the lanes through a pointer (unchecked)" },
			.() { Fn = .Dot, Name = "Dot", Pins = "a:V,b:V", Result = 'E', Lanes = 'f', Owner = 'B', Doc = "The dot product (the lanes multiplied, then summed pairwise)" },
			.() { Fn = .Length, Name = "Length", Pins = "v:V", Result = 'E', Lanes = 'f', Owner = 'B', Doc = "The length: the square root of Dot(v, v)" },
			.() { Fn = .Normalize, Name = "Normalize", Pins = "v:V", Result = 'V', Lanes = 'f', Owner = 'B', Doc = "v divided by its length (a zero vector stays zero)" },
			.() { Fn = .Cross, Name = "Cross", Pins = "a:V,b:V", Result = 'V', Lanes = 'f', Owner = 'B', Doc = "The cross product of the x, y, z lanes (a 4th lane is 0)" },
			.() { Fn = .Lerp, Name = "Lerp", Pins = "a:V,b:V,t:X", Result = 'V', Lanes = 'f', Owner = 'B', Doc = "a + (b - a) * t per lane" },
			.() { Fn = .Sqrt, Name = "Sqrt", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "The square root of each lane" },
			.() { Fn = .Abs, Name = "Abs", Pins = "x:V", Result = 'V', Lanes = 'n', Owner = 'M', Doc = "The absolute value of each lane" },
			.() { Fn = .Floor, Name = "Floor", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "Each lane rounded down" },
			.() { Fn = .Ceil, Name = "Ceil", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "Each lane rounded up" },
			.() { Fn = .Round, Name = "Round", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "Each lane rounded to the nearest whole number (halves away from zero)" },
			.() { Fn = .Truncate, Name = "Truncate", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "Each lane rounded toward zero" },
			.() { Fn = .Sin, Name = "Sin", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "The sine of each lane" },
			.() { Fn = .Cos, Name = "Cos", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "The cosine of each lane" },
			.() { Fn = .Exp, Name = "Exp", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "e to the power of each lane" },
			.() { Fn = .Log, Name = "Log", Pins = "x:V", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "The natural logarithm of each lane" },
			.() { Fn = .Pow, Name = "Pow", Pins = "x:V,y:X", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "Each lane of x to the power of y's" },
			.() { Fn = .Min, Name = "Min", Pins = "a:V,b:X", Result = 'V', Lanes = 'n', Owner = 'M', Doc = "The smaller of each pair of lanes (a NaN lane takes the other)" },
			.() { Fn = .Max, Name = "Max", Pins = "a:V,b:X", Result = 'V', Lanes = 'n', Owner = 'M', Doc = "The larger of each pair of lanes (a NaN lane takes the other)" },
			.() { Fn = .Clamp, Name = "Clamp", Pins = "x:V,min:X,max:X", Result = 'V', Lanes = 'n', Owner = 'M', Doc = "Each lane kept between min and max" },
			.() { Fn = .Fma, Name = "Fma", Pins = "a:V,b:X,c:X", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "a * b + c per lane with one rounding (the only contraction: a * b + c is two)" },
			.() { Fn = .CopySign, Name = "CopySign", Pins = "x:V,y:X", Result = 'V', Lanes = 'f', Owner = 'M', Doc = "Each lane of x with the sign of y's" }
		);

		/// The row of `name` for an owner (`Vector` or `Math`); null when there is none.
		public static FnInfo* Find(StringView name, bool mathOwner)
		{
			for (var f in ref Functions)
			{
				if (f.Name != name)
					continue;
				if (mathOwner ? (f.Owner == 'M' || f.Owner == 'B') : (f.Owner == 'V' || f.Owner == 'B'))
					return &f;
			}
			return null;
		}

		public static FnInfo* Of(VecFn fn)
		{
			for (var f in ref Functions)
				if (f.Fn == fn)
					return &f;
			return null;
		}

		/// The pins of a row in order: (name, kind).
		public static void Pins(FnInfo* f, List<(StringView name, char8 kind)> outPins)
		{
			for (let p in f.Pins.Split(','))
			{
				let colon = p.IndexOf(':');
				outPins.Add((p.Substring(0, colon), p[colon + 1]));
			}
		}

		/// True when the lanes of `v` suit the row (`why` says why not).
		public static bool LanesFit(FnInfo* f, KType v, String why)
		{
			let e = v.Element;
			bool ok;
			switch (f.Lanes)
			{
			case 'f': ok = e.Kind == .Float;
			case 'n': ok = e.Kind == .Float || e.Kind == .Int;
			case 'i': ok = e.Kind == .Int;
			case 'm': ok = e.Kind == .Bool;
			default: ok = true;
			}
			if (!ok)
			{
				StringView what = (f.Lanes == 'f') ? "float lanes" : ((f.Lanes == 'n') ? "number lanes" : ((f.Lanes == 'i') ? "integer lanes" : "a mask (boolN)"));
				why?.AppendF("{} takes {}, not {}", f.Name, what, v.Name);
				return false;
			}
			if (f.Fn == .Cross && v.Length != 3 && v.Length != 4)
			{
				why?.AppendF("Cross takes a 3- or 4-lane vector, not {}", v.Name);
				return false;
			}
			return true;
		}

		/// The lane name of an element type (`int64` for int: vectors spell the width).
		public static void LaneName(KType elem, String outName)
		{
			if (elem.Kind == .Int && elem.Bits == 64)
			{
				outName.Append(elem.Signed ? "int64" : "uint64");
				return;
			}
			outName.Append(elem.Prim ?? elem.Name);
		}

		/// `float4`, `int32x4`: a vector type (T1090 for a name shaped like one that is none). False
		/// for any other name (Resolve goes on).
		public static bool TryResolveName(Compilation c, StringView name, in NameCtx ctx, out KType outType)
		{
			outType = null;
			String why = scope .();
			switch (VectorTypes.Classify(name, why))
			{
			case .NotVector:
				return false;
			case .Invalid:
				if (!ctx.Quiet)
					c.Diags.Add(.Error, ctx.Node.IsEmpty ? .Declare : .Bind, "T1090", ctx.Site, ctx.Node, ctx.Pin, scope $"{name} is not a vector type: {why}");
				outType = c.Table.Error;
				return true;
			case .Vector:
				VectorTypes.TryParse(name, let elem, let lanes);
				let e = c.Table.Prim(elem);
				if (e == null)
					return false;
				outType = c.Table.Vector(e, lanes);
				return true;
			}
		}

		/// `Vector<float,4>`: the canonical generic form of `float4` (T1091 when the arguments are no
		/// lane type and lane count). False for any other name.
		public static bool TryResolveGeneric(Compilation c, TypeRef r, in NameCtx ctx, out KType outType)
		{
			outType = null;
			if ((r.Name != "Vector" && r.Name != "Core.Vector") || r.Args == null || r.Args.Count != 2)
				return false;
			void Fail(StringView why)
			{
				if (!ctx.Quiet)
					c.Diags.Add(.Error, ctx.Node.IsEmpty ? .Declare : .Bind, "T1091", ctx.Site, ctx.Node, ctx.Pin, scope $"{r}: {why}");
			}
			String count = scope .();
			r.Args[1].ToString(count);
			let e = c.Table.Prim(r.Args[0].Name);
			if (e == null || (e.Kind != .Int && e.Kind != .Float && e.Kind != .Bool) || r.Args[0].Name == "int" || r.Args[0].Name == "uint")
			{
				Fail("the lane type is float, double, int8 ... int64, uint8 ... uint64 or bool");
				outType = c.Table.Error;
				return true;
			}
			if (!(int.Parse(count) case .Ok(let n)))
			{
				Fail("the lane count is a number (2, 3, 4, 8, 16; 32 or 64 for 8- and 16-bit lanes)");
				outType = c.Table.Error;
				return true;
			}
			String lane = scope .();
			LaneName(e, lane);
			String spelled = scope .();
			VectorTypes.Spell(lane, n, spelled);
			String why = scope .();
			if (VectorTypes.Classify(spelled, why) != .Vector)
			{
				Fail(why);
				outType = c.Table.Error;
				return true;
			}
			outType = c.Table.Vector(e, n);
			return true;
		}

		/// The operators a vector has (Language.md 2.1 grown by SIMD-and-Vectors.md 1.4): float lanes
		/// arithmetic and comparisons, integer lanes those and the bitwise ones, masks & | ^ ! == !=.
		public static bool SupportsOperator(KType t, StringView op)
		{
			let isEq = op == "==" || op == "!=";
			let isCmp = op == "<" || op == ">" || op == "<=" || op == ">=";
			let isArith = op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "neg";
			let isBits = op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == "~";
			switch (t.Element.Kind)
			{
			case .Float: return isEq || isCmp || isArith;
			case .Int: return isEq || isCmp || isArith || isBits;
			case .Bool: return isEq || op == "!" || op == "&" || op == "|" || op == "^";
			default: return false;
			}
		}

		/// A literal on a vector input: one value per lane separated by commas (no spaces), or one
		/// value that splats (`0,1,0,0`, `2`, `true,false,true,true`).
		public static bool LiteralFits(StringView tok, KType t, TypeTable table, String why)
		{
			if (tok == "default" || tok == "zero")
				return true;
			int count = 0;
			for (var part in tok.Split(','))
			{
				count++;
				String w = scope .();
				if (!Literals.Fits(part, t.Element, table, w))
				{
					why.AppendF("lane {} of {}: {}", count - 1, tok, w);
					return false;
				}
			}
			if (count != 1 && count != t.Length)
			{
				why.AppendF("{} has {} lanes; {} has {} (one value fills every lane)", tok, count, t.Name, t.Length);
				return false;
			}
			return true;
		}

		/// A vector literal for the IR: every lane in decimal (a hexadecimal lane written out).
		public static void LaneLiteral(StringView tok, KType t, String outLit)
		{
			for (var part in tok.Split(','))
			{
				if (!outLit.IsEmpty)
					outLit.Append(',');
				if (!Literals.HexToDecimal(part, t.Element.Kind == .Int && !t.Element.Signed, outLit))
					outLit.Append(part);
			}
		}

		/// The lane of a swizzle letter (`x y z w`; -1 for any other).
		public static int Letter(char8 c)
		{
			switch (c)
			{
			case 'x': return 0;
			case 'y': return 1;
			case 'z': return 2;
			case 'w': return 3;
			default: return -1;
			}
		}

		/// Swizzle letters on a vector of `lanes` lanes: the lanes picked; T2301 (`outCode`) for letters that
		/// are no swizzle and for a lane the vector does not have.
		public static bool Swizzle(StringView letters, int lanes, List<int> outMask, String outCode, String why)
		{
			if (letters.IsEmpty || letters.Length > 4)
			{
				outCode.Set("T2301");
				why.AppendF("a swizzle has 1 to 4 of the letters x y z w, not '{}'", letters);
				return false;
			}
			for (let c in letters.RawChars)
			{
				let i = Letter(c);
				if (i < 0)
				{
					outCode.Set("T2301");
					why.AppendF("'{}' is not a swizzle letter (x y z w) in '{}'", c, letters);
					return false;
				}
				if (i >= lanes)
				{
					outCode.Set("T2301");
					why.AppendF("{} reads lane {} ('{}'), but the vector has {} lanes", letters, i, c, lanes);
					return false;
				}
				outMask.Add(i);
			}
			return true;
		}

		/// True for a name that is only swizzle letters (`zyx`).
		public static bool IsSwizzleText(StringView s)
		{
			if (s.IsEmpty || s.Length > 4)
				return false;
			for (let c in s.RawChars)
				if (Letter(c) < 0)
					return false;
			return true;
		}

		/// The pins of a Make / Break of a vector: `x y z w` for 2 to 4 lanes, `lane0 ...` above.
		public static void LanePin(int lanes, int i, String outName)
		{
			if (lanes <= 4)
				outName.Append("xyzw"[i]);
			else
				outName.AppendF("lane{}", i);
		}

		/// The node kind word of a Swizzle / Shuffle node (Unknown to an editor that predates them).
		public static StringView NodeWord(Treadle.Graph.Node n)
		{
			if (n.Kind == .Unknown && n.KindWord != null)
				return n.KindWord;
			return Treadle.Graph.NodeKinds.Word(n.Kind);
		}

		public static bool IsSwizzleNode(Treadle.Graph.Node n) => NodeWord(n) == "Swizzle";
		public static bool IsShuffleNode(Treadle.Graph.Node n) => NodeWord(n) == "Shuffle";

		/// A C import or an [Export] function (SIMD-and-Vectors.md 1.6): a lane mask cannot cross the C
		/// boundary (C has no mask type: T2302); on Linux a 32-byte vector argument of an import at a level
		/// without AVX goes in memory, where C built with AVX passes it in a YMM register (T3090, a warning).
		public static void CheckCBoundary(Compilation c, MemberSym m, DiagSite site)
		{
			void Mask(KType t, StringView what)
			{
				if (t != null && t.IsMask)
					c.Diags.Add(.Error, .Declare, "T2302", site, "", "", scope $"{m.Name}: {what} is {t.Name}, a lane mask: C has no mask type (Cast it to integer lanes, int8xN / int32xN)");
			}
			Mask(m.Returns, "the result");
			for (let p in m.Params)
				Mask(p.Type, scope $"the parameter {p.Name}");
#if !BF_PLATFORM_WINDOWS
			let level = (c.Settings != null) ? (StringView)c.Settings.Simd : "x86-64-v2";
			if (m.IsImport && (level == "x86-64" || level == "x86-64-v2"))
				for (let p in m.Params)
					if (p.Type != null && p.Type.IsVector && (p.Type.Element.Bits / 8) * ((p.Type.Length == 3) ? 4 : p.Type.Length) == 32)
						c.Diags.Add(.Warning, .Declare, "T3090", site, "", "", scope $"{m.Name}: {p.Name} is {p.Type.Name}, 32 bytes: at simd {level} it is passed in memory, but C built with AVX takes it in a YMM register (set simd x86-64-v3, or pass a pointer)");
#endif
		}
	}

	/// Vector constants (docs/SIMD-and-Vectors.md 1.3, Language.md 4.6): `const float4 Up = float4(0, 1,
	/// 0, 0)` folded lane by lane into one literal token (`0.0,1.0,0.0,0.0`); a number splats; other vector
	/// constants, swizzles and + - * / (and & | ^ on integer lanes) apply per lane.
	extension ConstTyper
	{
		public bool FoldVector(MemberSym m, MathNode tree, KType t, KType target, String outTok)
		{
			if (t.IsVector && t != target)
			{
				let owner = m.Extension ?? m.Owner;
				c.Diags.Add(.Error, .Declare, "T1092", .(owner.FullName, "", "", owner.Path), "", "", scope $"{m.Name}: the value is {t.Name}, not {target.Name} (lane types and counts change through a Cast; one number fills every lane)");
				Failed = true;
				return false;
			}
			let e = target.Element;
			for (int lane < target.Length)
			{
				if (!EvalLane(tree, lane, target, var v))
					return false;
				if (!Convert(ref v, e, tree))
					return false;
				if (lane > 0)
					outTok.Append(',');
				Format(v, e, outTok);
			}
			return true;
		}

		/// Lane `lane` of the vector `n` gives (a scalar `n` is the same in every lane).
		bool EvalLane(MathNode n, int lane, KType vec, out ConstVal v)
		{
			v = .();
			let nt = n.Type;
			if (nt == null || !nt.IsVector)
			{
				if (n.Kind == .Number || n.Kind == .Bool || nt == null || !nt.IsVector)
					return Eval(n, out v);
			}
			switch (n.Kind)
			{
			case .Number, .Bool:
				return Eval(n, out v);
			case .Name:
				if (n.Member == null || n.Member.ConstValue == null)
					return false;
				var tok = StringView(n.Member.ConstValue);
				int i = 0;
				for (let part in tok.Split(','))
				{
					if (i == lane || (i == 0 && !tok.Contains(',')))
					{
						v = FromToken(part, nt.Element);
						return true;
					}
					i++;
				}
				return false;
			case .Call:
				if (!n.VecMake)
				{
					Fail(n, .NotConstant, scope $"{n.Text} on vectors is not computed at compile time");
					return false;
				}
				if (n.Args.Count == 1)
				{
					let a = n.Args[0];
					if (a.Type != null && a.Type.IsVector)
						return EvalLane(a, lane, vec, out v);
					return Eval(a, out v);
				}
				return (lane < n.Args.Count) && Eval(n.Args[lane], out v);
			case .Swizzle:
				if (n.Lanes == null || lane >= n.Lanes.Count)
					return false;
				return EvalLane(n.A, n.Lanes[lane], vec, out v);
			case .Unary:
				if (!EvalLane(n.A, lane, vec, out v))
					return false;
				switch (n.Text)
				{
				case "-":
					if (v.Kind == .Float)
						v.F = -v.F;
					else
						v.I = -v.I;
				case "!": v.B = !v.B;
				case "~": v.I = ~v.I;
				default:
				}
				return true;
			case .Binary:
				if (!EvalLane(n.A, lane, vec, var a))
					return false;
				if (!EvalLane(n.B, lane, vec, var b))
					return false;
				let isFloat = n.Operand != null && n.Operand.IsVector && n.Operand.Element.Kind == .Float;
				if (isFloat)
				{
					double x = (a.Kind == .Int) ? (double)a.I : a.F;
					double y = (b.Kind == .Int) ? (double)b.I : b.F;
					double rf;
					switch (n.Text)
					{
					case "+": rf = x + y;
					case "-": rf = x - y;
					case "*": rf = x * y;
					case "/": rf = x / y;
					default:
						Fail(n, .NotConstant, scope $"{n.Text} on vector lanes is not folded");
						return false;
					}
					v = .();
					v.Kind = .Float;
					v.F = rf;
					return true;
				}
				int64 r;
				switch (n.Text)
				{
				case "+": r = a.I + b.I;
				case "-": r = a.I - b.I;
				case "*": r = a.I * b.I;
				case "/", "%":
					if (b.I == 0)
						return Range(n, "division by zero");
					r = (n.Text == "/") ? a.I / b.I : a.I % b.I;
				case "&": r = a.I & b.I;
				case "|": r = a.I | b.I;
				case "^": r = a.I ^ b.I;
				default:
					Fail(n, .NotConstant, scope $"{n.Text} on vector lanes is not folded");
					return false;
				}
				v = .();
				v.Kind = .Int;
				v.I = r;
				return true;
			default:
				Fail(n, .NotConstant, "this is not folded lane by lane");
				return false;
			}
		}
	}
}
