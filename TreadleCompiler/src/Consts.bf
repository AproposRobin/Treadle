using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	/// Constants (Language.md 4.6): a `const` field's init is a constant expression (the Math
	/// Expression grammar over literals, other constants, enum cases and texts) that Declare folds
	/// into one literal; a `const` field of type `T[]` lists its values in `elements` and reads as a
	/// `Span<T>` over a read-only global. Lower puts the value where a Get reads it.
	extension Compilation
	{
		static DiagSite ConstSite(MemberSym m)
		{
			let t = m.Extension ?? m.Owner;
			return .(t.FullName, "", "", t.Path);
		}

		/// What a constant can be: a number, a bool, a character, a case of an enum without
		/// payloads, a text (String, StringView, or a C `char8*`); a const array's elements the same
		/// but String (an array element is never an object).
		bool ConstType(KType t, bool element)
		{
			switch (t.Kind)
			{
			case .Int, .Float, .Bool, .Char, .Vector:
				return true;
			case .Named:
				if (t.IsEnum)
					return !t.Sym.HasPayload;
				return t.Sym == Table.StringViewSym || (!element && t.Sym == Table.StringSym);
			case .Pointer:
				return !element && t.Element.Kind == .Char && t.Element.Bits == 8;
			default:
				return false;
			}
		}

		/// Folds every constant not folded yet (all of them after Declare; the re-declared ones after
		/// an incremental Validate). A C import set's `cconst` is a constant like any other.
		public void FoldConstants()
		{
			for (let t in Table.Types)
				for (let m in t.Members)
				{
					if (m.Kind != .Field)
						continue;
					if (!m.Const)
					{
						if (m.Elements != null && m.ConstState == 0)
						{
							m.ConstState = 3;
							Error("T1083", ConstSite(m), "", "", scope $"{m.Name}: elements are for a const array (a const field of type T[])", .Declare);
						}
						continue;
					}
					if (m.ConstState == 0)
						FoldConst(m);
				}
		}

		/// Folds `m` (and the constants its init names first). False when it has no value.
		public bool FoldConst(MemberSym m, List<MemberSym> stack = null)
		{
			switch (m.ConstState)
			{
			case 2: return true;
			case 3: return false;
			case 1:
				// Met again while its own init is folded: a cycle.
				String chain = scope .();
				int from = (stack != null) ? stack.IndexOf(m) : -1;
				if (stack != null && from >= 0)
					for (int i = from; i < stack.Count; i++)
						chain.AppendF("{} -> ", stack[i].Name);
				chain.Append(m.Name);
				Error("T1081", ConstSite(m), "", "", scope $"{m.Name}: the constant's value depends on itself ({chain})", .Declare);
				m.ConstState = 3;
				return false;
			default:
			}
			m.ConstState = 1;
			var stack;
			if (stack == null)
				stack = scope:: .();
			stack.Add(m);
			let ok = FoldConstBody(m, stack);
			stack.PopBack();
			if (m.ConstState == 1)
				m.ConstState = ok ? 2 : 3;
			return m.ConstState == 2;
		}

		bool FoldConstBody(MemberSym m, List<MemberSym> stack)
		{
			NameCtx ctx = .(m.Owner, m, ConstSite(m));
			ctx.Lookup = m.Extension;
			ctx.Quiet = true;
			let t = m.Type;
			if (t == null || t.IsError)
				return false;
			String why = scope .();
			if (t.Kind == .Array)
			{
				let et = t.Element;
				if (!ConstType(et, true))
				{
					Error("T1083", ConstSite(m), "", "", scope $"{m.Name}: a const array holds numbers, bools, characters, enum cases or StringView texts, not {TypeTable.Show(et, .. scope .())}", .Declare);
					return false;
				}
				if (m.Elements == null || m.Elements.IsWhiteSpace)
				{
					Error("T1083", ConstSite(m), "", "", scope $"{m.Name}: a const array lists its values (elements 1, 2, 3)", .Declare);
					return false;
				}
				if (m.Init != null)
				{
					Error("T1083", ConstSite(m), "", "", scope $"{m.Name}: a const array has elements, not an init", .Declare);
					return false;
				}
				List<MathNode> list = scope .();
				defer { ClearAndDeleteItems!(list); }
				if (!MathExpr.BuildList(m.Elements, list, why))
				{
					Error("T1080", ConstSite(m), "", "", scope $"{m.Name}: elements: {why}", .Declare);
					return false;
				}
				List<String> values = new .();
				bool ok = true;
				for (let e in list)
				{
					String tok = scope .();
					if (FoldExpr(m, e, et, ctx, stack, tok))
						values.Add(new String(tok));
					else
						ok = false;
				}
				if (!ok)
				{
					DeleteContainerAndItems!(values);
					return false;
				}
				DeleteContainerAndItems!(m.ConstElements);
				m.ConstElements = values;
				m.ConstElement = et;
				KType[1] args = .(et);
				m.Type = Table.Named(Table.SpanSym, args);
				return true;
			}
			if (m.Elements != null)
			{
				Error("T1083", ConstSite(m), "", "", scope $"{m.Name}: elements are for a const array (a const field of type T[])", .Declare);
				return false;
			}
			if (!ConstType(t, false))
			{
				Error("T1083", ConstSite(m), "", "", scope $"{m.Name}: a constant is a number, a bool, a character, an enum case or a text, not {TypeTable.WithArticle(t, .. scope .())}", .Declare);
				return false;
			}
			if (m.Init == null || m.Init.IsWhiteSpace)
			{
				Error("T1080", ConstSite(m), "", "", scope $"{m.Name}: a constant needs a value (its init)", .Declare);
				return false;
			}
			if (m.Init == "default" && !t.IsEnum && t.Kind != .Named && t.Kind != .Pointer)
			{
				DeleteAndNullify!(m.ConstValue);
				m.ConstValue = new String((t.Kind == .Bool) ? "false" : ((t.Kind == .Float) ? "0.0" : "0"));
				return true;
			}
			let tree = MathExpr.Build(m.Init, why);
			if (tree == null)
			{
				Error("T1080", ConstSite(m), "", "", scope $"{m.Name}: {why}", .Declare);
				return false;
			}
			defer delete tree;
			String tok = scope .();
			if (!FoldExpr(m, tree, t, ctx, stack, tok))
				return false;
			DeleteAndNullify!(m.ConstValue);
			m.ConstValue = new String(tok);
			return true;
		}

		/// One value of `m` (its init or an element) folded to a literal of `target`.
		bool FoldExpr(MemberSym m, MathNode tree, KType target, in NameCtx ctx, List<MemberSym> stack, String outTok)
		{
			ConstTyper ty = scope .(this, m, ctx, stack);
			ty.Report = true;
			var t = ty.Type(tree);
			if (tree.Adopts)
			{
				ty.Adopt(tree, target);
				t = tree.Type;
			}
			if (ty.Failed)
				return false;
			if (t == null || t.IsError)
				return false;
			if (target.IsVector)
				return ty.FoldVector(m, tree, t, target, outTok); // VectorRules.bf: lane by lane
			// A constant's value converts to any number type it fits (`const uint8 Low = Mask & 0xFF`),
			// as a literal does; a fraction never becomes an integer.
			let narrows = t.IsNumeric && target.IsNumeric && !(t.Kind == .Float && target.Kind == .Int);
			if (!narrows && Table.CanConvert(t, target) == .Refused)
			{
				Error("T1084", ConstSite(m), "", "", scope $"{m.Name}: the value is {TypeTable.WithArticle(t, .. scope .())}, not {TypeTable.WithArticle(target, .. scope .())}", .Declare);
				return false;
			}
			if (!ty.Eval(tree, var v))
				return false;
			if (!ty.Convert(ref v, target, tree))
				return false;
			ConstTyper.Format(v, target, outTok);
			return true;
		}

		/// The constant or enum case a path names (`Width`: of `self` or its bases; `Game.Width`,
		/// `Color.Red`, `C.sdl2.SDL_INIT_VIDEO`): a field (constant or not) or a case; null with `why`.
		public MemberSym FindConstPath(StringView path, in NameCtx ctx, TypeSym self, String why)
		{
			let dot = path.LastIndexOf('.');
			StringView name = (dot >= 0) ? path.Substring(dot + 1) : path;
			TypeSym owner = self;
			if (dot >= 0)
			{
				let ownerText = path.Substring(0, dot);
				List<TypeSym> amb = scope .();
				owner = LookupType(ownerText, ctx, amb);
				if (owner == null)
				{
					why.AppendF("'{}' names no type", ownerText);
					return null;
				}
			}
			var t = (owner != null) ? owner.Self : null;
			int guard = 0;
			while (t != null && t.Kind == .Named && guard++ < 64)
			{
				for (let m in t.Sym.Members)
					if ((m.Kind == .Field || m.Kind == .Case) && m.Name == name)
						return m;
				t = Table.BaseOf(t);
			}
			if (owner == null)
				why.AppendF("'{}' names no constant", path);
			else
				why.AppendF("{} has no constant {}", owner.Name, name);
			return null;
		}

		/// A literal input that names a constant (`in count Rows`, `in color Palette.Main`): the
		/// constant, folded; null when the token is no name or names no single-valued constant.
		public MemberSym PinConst(StringView token, in NameCtx ctx, TypeSym self)
		{
			if (token.IsEmpty || !(token[0].IsLetter || token[0] == '_') || token == "true" || token == "false" || token == "null" || token == "default")
				return null;
			for (let ch in token.RawChars)
				if (!(ch.IsLetterOrDigit || ch == '_' || ch == '.'))
					return null;
			String why = scope .();
			let m = FindConstPath(token, ctx, self, why);
			if (m == null || m.Kind != .Field || !m.Const || !FoldConst(m) || m.ConstValue == null)
				return null;
			return m;
		}
	}

	enum ConstKind : uint8
	{
		Int,
		Float,
		Bool,
		Case,
		Text
	}

	/// A folded value.
	struct ConstVal
	{
		public ConstKind Kind;
		public int64 I;
		public double F;
		public bool B;
		public MemberSym Case;
		public StringView Text;
	}

	/// Types a constant's init (names are constants and enum cases) and folds it.
	class ConstTyper : ExprTyper
	{
		MemberSym mOf;
		NameCtx mCtx;
		List<MemberSym> mStack;

		public this(Compilation comp, MemberSym of, NameCtx ctx, List<MemberSym> stack) : base(comp)
		{
			mOf = of;
			mCtx = ctx;
			mStack = stack;
			mCtxMember = of;
		}

		protected override bool AllowText => true;

		protected override void Problem(MathNode at, ExprProblem kind, StringView message)
		{
			StringView code;
			switch (kind)
			{
			case .Operand: code = "T1084";
			case .Literal, .Range: code = "T1082";
			default: code = "T1080";
			}
			let t = mOf.Extension ?? mOf.Owner;
			c.Error(code, .(t.FullName, "", "", t.Path), "", "", scope $"{mOf.Name}: {message}", .Declare);
		}

		protected override void BindName(MathNode n)
		{
			n.Adopts = false;
			n.Member = null;
			String why = scope .();
			let m = c.FindConstPath(n.Text, mCtx, mOf.Owner, why);
			if (m == null)
			{
				Fail(n, .Name, why);
				n.Type = T.Error;
				return;
			}
			if (m.Kind == .Case)
			{
				if (!m.Payload.IsEmpty)
				{
					Fail(n, .Name, scope $"{n.Text} carries values: a constant names a case without them");
					n.Type = T.Error;
					return;
				}
				n.Member = m;
				n.Type = m.Owner.Self;
				return;
			}
			if (!m.Const)
			{
				Fail(n, .NotConstant, scope $"{n.Text} is not a constant (a field's value is known at run time)");
				n.Type = T.Error;
				return;
			}
			if (!c.FoldConst(m, mStack))
			{
				// its own problem is reported on it
				Failed = true;
				n.Type = T.Error;
				return;
			}
			if (m.ConstElements != null)
			{
				Fail(n, .Operand, scope $"{n.Text} is a const array: an expression reads single values");
				n.Type = T.Error;
				return;
			}
			n.Member = m;
			n.Type = m.Type;
			if (m.Owner != mOf.Owner)
			{
				if (mOf.ConstRefs == null)
					mOf.ConstRefs = new .();
				if (!mOf.ConstRefs.Contains(m.Owner))
					mOf.ConstRefs.Add(m.Owner);
			}
		}

		// ------------------------------------------------------------------ folding

		bool Range(MathNode at, StringView message)
		{
			Fail(at, .Range, message);
			return false;
		}

		static bool FitsBits(int64 v, int32 bits, bool signed)
		{
			if (bits >= 64)
				return signed || v >= 0;
			if (signed)
			{
				let lim = (int64)1 << (bits - 1);
				return v >= -lim && v < lim;
			}
			return v >= 0 && v < ((int64)1 << bits);
		}

		/// `v` as a value of `t` within its range (a shift or `~` wraps as the machine does).
		static int64 Wrap(int64 v, int32 bits, bool signed)
		{
			if (bits >= 64)
				return v;
			let mask = ((int64)1 << bits) - 1;
			var w = v & mask;
			if (signed && (w & ((int64)1 << (bits - 1))) != 0)
				w |= ~mask;
			return w;
		}

		/// `v` converted to `to` (int to float; the range of an integer; float precision).
		public bool Convert(ref ConstVal v, KType to, MathNode at)
		{
			if (to == null || to.IsError)
				return true;
			switch (to.Kind)
			{
			case .Float:
				if (v.Kind == .Int)
				{
					v.F = (double)v.I;
					v.Kind = .Float;
				}
				if (v.Kind != .Float)
					return true;
				if (to.Bits == 32)
				{
					if (Math.Abs(v.F) > float.MaxValue && !v.F.IsInfinity)
						return Range(at, scope $"{v.F} does not fit in a float");
					v.F = (double)(float)v.F;
				}
				if (v.F.IsNaN || v.F.IsInfinity)
					return Range(at, "the value is not a finite number");
			case .Int, .Char:
				if (v.Kind == .Int && !FitsBits(v.I, to.Bits, to.Kind == .Int && to.Signed))
					return Range(at, scope $"{v.I} does not fit in {to.Name}");
			default:
			}
			return true;
		}

		static ConstVal Int(int64 i) { ConstVal v = .(); v.Kind = .Int; v.I = i; return v; }
		static ConstVal Float(double f) { ConstVal v = .(); v.Kind = .Float; v.F = f; return v; }
		static ConstVal Bool(bool b) { ConstVal v = .(); v.Kind = .Bool; v.B = b; return v; }

		/// A folded constant's token back as a value of `t`.
		ConstVal FromToken(StringView tok, KType t)
		{
			ConstVal v = .();
			switch (Literals.Classify(tok, var i, var f))
			{
			case .Int: v = Int(i);
			case .Float: v = Float(f);
			case .Bool: v = Bool(tok == "true");
			case .String:
				v.Kind = .Text;
				v.Text = tok;
			case .Case:
				v.Kind = .Case;
				if (t != null && t.IsEnum)
					v.Case = t.Sym.FindCase(tok.Substring(1));
			case .Char:
				v = Int((int64)(uint8)tok[1]);
			default:
				v = Int(0);
			}
			return v;
		}

		public bool Eval(MathNode n, out ConstVal v)
		{
			v = .();
			switch (n.Kind)
			{
			case .Number:
				switch (Literals.Classify(n.Text, var i, var f))
				{
				case .Int: v = Int(i);
				case .Float: v = Float(f);
				default: return Range(n, scope $"'{n.Text}' is not a number");
				}
				return Convert(ref v, n.Type, n);
			case .Bool:
				v = Bool(n.Text == "true");
			case .Text:
				v.Kind = .Text;
				v.Text = n.Text;
			case .Case:
				v.Kind = .Case;
				v.Case = n.Member;
			case .Name:
				if (n.Member == null)
					return false;
				if (n.Member.Kind == .Case)
				{
					v.Kind = .Case;
					v.Case = n.Member;
					return true;
				}
				v = FromToken(n.Member.ConstValue, n.Member.Type);
			case .Call:
				return Call(n, n.Args, out v);
			case .Unary:
				return UnaryValue(n, out v);
			case .Binary:
				if (n.Text == "**")
					return Call(n, n.Args, out v);
				return BinaryValue(n, out v);
			case .Swizzle:
				Fail(n, .NotConstant, "a swizzle is folded only inside a vector constant");
				return false;
			case .Ternary:
				if (!Eval(n.A, var cond))
					return false;
				let arm = cond.B ? n.B : n.C;
				if (!Eval(arm, out v))
					return false;
				return Convert(ref v, n.Operand, arm);
			}
			return true;
		}

		bool UnaryValue(MathNode n, out ConstVal v)
		{
			v = .();
			if (n.Member != null)
			{
				Fail(n, .NotConstant, scope $"the operator {n.Text} of {n.Owner.Name} runs at run time");
				return false;
			}
			if (!Eval(n.A, out v) || !Convert(ref v, n.Operand, n.A))
				return false;
			let t = n.Operand;
			switch (n.Text)
			{
			case "!":
				v.B = !v.B;
			case "-":
				if (v.Kind == .Float)
					v.F = -v.F;
				else
				{
					if (v.I == int64.MinValue)
						return Range(n, scope $"-{v.I} does not fit in {t.Name}");
					v.I = -v.I;
				}
			case "~":
				v.I = Wrap(~v.I, t.Bits, t.Signed);
			}
			return Convert(ref v, n.Type, n);
		}

		static bool IsCompare(StringView op) => op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=";

		bool BinaryValue(MathNode n, out ConstVal v)
		{
			v = .();
			StringView op = n.Text;
			if (n.Member != null)
			{
				Fail(n, .NotConstant, scope $"the operator {op} of {n.Owner.Name} runs at run time");
				return false;
			}
			if (op == "&&" || op == "||")
			{
				if (!Eval(n.A, var a))
					return false;
				if ((op == "&&") != a.B)
				{
					v = Bool(a.B);
					return true;
				}
				return Eval(n.B, out v);
			}
			let t = n.Operand;
			if (!Eval(n.A, var a) || !Convert(ref a, t, n.A))
				return false;
			let shift = op == "<<" || op == ">>";
			if (!Eval(n.B, var b) || (!shift && !Convert(ref b, t, n.B)))
				return false;
			if (IsCompare(op))
			{
				int cmp = 0;
				bool ordered = true;
				switch (a.Kind)
				{
				case .Int: cmp = a.I <=> b.I;
				case .Float:
					ordered = !a.F.IsNaN && !b.F.IsNaN;
					cmp = a.F <=> b.F;
				case .Bool: cmp = (a.B == b.B) ? 0 : 1;
				case .Case: cmp = ((a.Case != null) ? a.Case.CaseValue : 0) <=> ((b.Case != null) ? b.Case.CaseValue : 0);
				case .Text: cmp = (a.Text == b.Text) ? 0 : 1;
				}
				bool r;
				switch (op)
				{
				case "==": r = ordered && cmp == 0;
				case "!=": r = !ordered || cmp != 0;
				case "<": r = ordered && cmp < 0;
				case ">": r = ordered && cmp > 0;
				case "<=": r = ordered && cmp <= 0;
				default: r = ordered && cmp >= 0;
				}
				v = Bool(r);
				return true;
			}
			if (a.Kind == .Bool)
			{
				// & | ^ on bools
				switch (op)
				{
				case "&": v = Bool(a.B && b.B);
				case "|": v = Bool(a.B || b.B);
				default: v = Bool(a.B != b.B);
				}
				return true;
			}
			if (a.Kind == .Float)
			{
				double r;
				switch (op)
				{
				case "+": r = a.F + b.F;
				case "-": r = a.F - b.F;
				case "*": r = a.F * b.F;
				case "/": r = a.F / b.F;
				default: r = a.F % b.F;
				}
				v = Float(r);
				return Convert(ref v, n.Type, n);
			}
			if (a.Kind != .Int)
			{
				Fail(n, .NotConstant, scope $"{op} on these values is not folded");
				return false;
			}
			int64 x = a.I;
			int64 y = b.I;
			int64 r = 0;
			switch (op)
			{
			case "+":
				r = (int64)((uint64)x + (uint64)y);
				if (((x ^ r) & (y ^ r)) < 0)
					return Range(n, scope $"{x} + {y} overflows {t.Name}");
			case "-":
				r = (int64)((uint64)x - (uint64)y);
				if (((x ^ y) & (x ^ r)) < 0)
					return Range(n, scope $"{x} - {y} overflows {t.Name}");
			case "*":
				if (x != 0 && ((x == -1 && y == int64.MinValue) || (y == -1 && x == int64.MinValue)))
					return Range(n, scope $"{x} * {y} overflows {t.Name}");
				r = (int64)((uint64)x * (uint64)y);
				if (x != 0 && r / x != y)
					return Range(n, scope $"{x} * {y} overflows {t.Name}");
			case "/", "%":
				if (y == 0)
					return Range(n, "division by zero");
				if (x == int64.MinValue && y == -1)
					return Range(n, scope $"{x} {op} {y} overflows {t.Name}");
				r = (op == "/") ? x / y : x % y;
			case "&": r = x & y;
			case "|": r = x | y;
			case "^": r = x ^ y;
			case "<<", ">>":
				if (y < 0 || y >= t.Bits)
					return Range(n.B, scope $"a shift of {y} is out of range for {t.Name}");
				let count = (int)y;
				if (op == "<<")
					r = Wrap(x << count, t.Bits, t.Signed);
				else if (t.Signed)
					r = x >> count;
				else
					r = (int64)((uint64)Wrap(x, t.Bits, false) >> count);
			}
			v = Int(r);
			return Convert(ref v, n.Type, n);
		}

		/// A Math function at compile time (the ones whose value is plain arithmetic).
		bool Call(MathNode n, List<MathNode> args, out ConstVal v)
		{
			v = .();
			let f = n.Member;
			if (f == null)
				return false;
			Dictionary<GenericParamSym, KType> map = scope .();
			if (n.MethodArgs != null)
				for (int i < Math.Min(f.Generics.Count, n.MethodArgs.Count))
					map[f.Generics[i]] = n.MethodArgs[i];
			List<ConstVal> vals = scope .();
			for (int i < args.Count)
			{
				if (!Eval(args[i], var a) || !Convert(ref a, T.Subst(f.Params[i].Type, map), args[i]))
					return false;
				vals.Add(a);
			}
			let rt = n.Type;
			bool isInt = rt != null && rt.Kind == .Int;
			double X(int i)
			{
				return (vals[i].Kind == .Int) ? (double)vals[i].I : vals[i].F;
			}
			int Cmp(ConstVal a, ConstVal b)
			{
				if (a.Kind == .Int && b.Kind == .Int)
					return a.I <=> b.I;
				let da = (a.Kind == .Int) ? (double)a.I : a.F;
				let db = (b.Kind == .Int) ? (double)b.I : b.F;
				return da <=> db;
			}
			switch (f.Name)
			{
			case "Sqrt": v = Float(Math.Sqrt(X(0)));
			case "Abs":
				if (vals[0].Kind == .Int)
				{
					if (vals[0].I == int64.MinValue)
						return Range(n, "Abs overflows");
					v = Int(Math.Abs(vals[0].I));
				}
				else
					v = Float(Math.Abs(X(0)));
			case "Floor": v = Float(Math.Floor(X(0)));
			case "Ceil": v = Float(Math.Ceiling(X(0)));
			case "Truncate": v = Float((X(0) < 0) ? -Math.Floor(-X(0)) : Math.Floor(X(0)));
			case "Round": v = Float((X(0) < 0) ? -Math.Floor(-X(0) + 0.5) : Math.Floor(X(0) + 0.5));
			case "Sin": v = Float(Math.Sin(X(0)));
			case "Cos": v = Float(Math.Cos(X(0)));
			case "Exp": v = Float(Math.Exp(X(0)));
			case "Log": v = Float(Math.Log(X(0)));
			case "Pow": v = Float(Math.Pow(X(0), X(1)));
			case "Lerp": v = Float(X(0) + (X(1) - X(0)) * X(2));
			case "IsNaN": v = Bool(X(0).IsNaN);
			case "Sign":
				let x = X(0);
				v = Int((x > 0) ? 1 : ((x < 0) ? -1 : 0));
			case "Min", "Max", "Clamp":
				// Over T: integers exactly, floats as doubles.
				if (f.Name == "Clamp")
					v = (Cmp(vals[0], vals[1]) < 0) ? vals[1] : ((Cmp(vals[0], vals[2]) > 0) ? vals[2] : vals[0]);
				else if (f.Name == "Min")
					v = (Cmp(vals[1], vals[0]) < 0) ? vals[1] : vals[0];
				else
					v = (Cmp(vals[1], vals[0]) > 0) ? vals[1] : vals[0];
			default:
				Fail(n, .NotConstant, scope $"Math.{f.Name} is not computed at compile time");
				return false;
			}
			if (isInt && v.Kind == .Float)
				v = Int((int64)v.F);
			return Convert(ref v, rt, n);
		}

		/// The literal token of a folded value of `t`.
		public static void Format(ConstVal v, KType t, String outTok)
		{
			switch (v.Kind)
			{
			case .Int:
				if (t != null && t.Kind == .Float)
					FormatFloat((double)v.I, outTok);
				else
					outTok.AppendF("{}", v.I);
			case .Float:
				FormatFloat(v.F, outTok);
			case .Bool:
				outTok.Append(v.B ? "true" : "false");
			case .Case:
				outTok.AppendF(".{}", (v.Case != null) ? (StringView)v.Case.Name : "");
			case .Text:
				outTok.Append(v.Text);
			}
		}

		/// A double as a token that reads back to the same value (`0.5`, `3.0`, `1E+20`).
		public static void FormatFloat(double f, String outTok)
		{
			let start = outTok.Length;
			f.ToString(outTok);
			bool hasPoint = false;
			for (int i = start; i < outTok.Length; i++)
			{
				let ch = outTok[i];
				if (ch == '.' || ch == 'e' || ch == 'E')
					hasPoint = true;
			}
			if (!hasPoint)
				outTok.Append(".0");
		}
	}
}
