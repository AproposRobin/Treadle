using System;
using System.Collections;

namespace Treadle.Compiler
{
	/// What went wrong in an expression; the Math Expression node and constants give each their
	/// own code.
	enum ExprProblem : uint8
	{
		/// The operands' types (no operator, cannot combine, not a bool...).
		Operand,
		/// An unknown, ambiguous or unfit Math function.
		Function,
		/// A path that names nothing (a field, a constant, a case).
		Name,
		/// A literal that does not fit the type it takes.
		Literal,
		/// Constants: something known only at run time.
		NotConstant,
		/// Constants: a value out of its type's range, a division by zero.
		Range,
		/// Vectors: `&&` `||` on a lane mask (T2300), swizzle letters (T2301), vectors that do not combine (T2320).
		Mask,
		Lanes,
		Vector
	}

	/// Types a Math Expression tree (Language.md 5.6) with the Operator node's rules: a literal
	/// takes the type of the other side, numbers of two types meet in the wider one, comparisons
	/// and `&&` `||` `!` give bool, `c ? a : b` is a Select, a function is one of Core.Math by its
	/// inputs (Compiler.md 2, Overloads). The Math Expression node and constant folding derive from
	/// it for their names and their messages.
	abstract class ExprTyper
	{
		protected Compilation c;
		protected TypeTable T;
		/// The member whose generic parameters' operator constraints count.
		protected MemberSym mCtxMember;
		/// The last pass: problems are reported (earlier passes only find the free inputs' types).
		public bool Report;
		public bool Failed;

		public this(Compilation comp)
		{
			c = comp;
			T = c.Table;
		}

		protected abstract void Problem(MathNode at, ExprProblem kind, StringView message);
		/// Types a Name (n.Type; null while it is a free input) and sets n.Adopts.
		protected abstract void BindName(MathNode n);
		/// A free input (or one with only a literal) takes `t`.
		protected virtual void TakeType(MathNode n, KType t) { n.Type = t; }
		/// Text literals are constants' only.
		protected virtual bool AllowText => false;
		/// A generic function or a user operator is used (Instances).
		protected virtual void UsesFunction(MemberSym f, List<KType> methodArgs) { }
		protected virtual void UsesType(KType t) { }

		protected void Fail(MathNode at, ExprProblem kind, StringView message)
		{
			Failed = true;
			if (Report)
				Problem(at, kind, scope $"{message} at {at.Pos + 1}");
		}

		mixin S(KType t)
		{
			TypeTable.Show(t, .. scope:mixin String())
		}

		static bool IsCompare(StringView op) => op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=";
		static bool IsLogical(StringView op) => op == "&&" || op == "||";

		/// The type of `n` (null: a free input or a sum of free inputs, typed by what it meets).
		public KType Type(MathNode n)
		{
			n.Adopts = false;
			n.Operand = null;
			switch (n.Kind)
			{
			case .Number:
				n.Adopts = true;
				n.Type = Literals.TypeOf(n.Text, T);
				if (n.Type == null)
				{
					Fail(n, .Literal, scope $"'{n.Text}' is not a number");
					n.Type = T.Error;
				}
			case .Bool:
				n.Type = T.Bool;
			case .Text:
				if (!AllowText)
				{
					Fail(n, .Operand, "a Math Expression computes with numbers and bools, not text");
					n.Type = T.Error;
				}
				else
				{
					n.Adopts = true;
					n.Type = (T.StringViewSym != null) ? T.StringViewSym.Self : T.Error;
				}
			case .Case:
				// `.Red`: the enum the other side has.
				n.Adopts = true;
				n.Type = null;
			case .Name:
				BindName(n);
			case .Call:
				Call(n, n.Text, n.Args);
			case .Unary:
				UnaryOp(n);
			case .Binary:
				if (n.Text == "**")
					Call(n, "Pow", n.Args);
				else
					BinaryOp(n);
			case .Ternary:
				TernaryOp(n);
			case .Swizzle:
				TypeSwizzle(n); // BindVector.bf
			}
			return n.Type;
		}

		/// `n` (a leaf that adopts) takes the type `t` of the other side.
		public void Adopt(MathNode n, KType t)
		{
			if (t == null || !n.Adopts)
				return;
			if (t.IsError)
			{
				n.Type = t;
				return;
			}
			switch (n.Kind)
			{
			case .Number, .Text:
				String why = scope .();
				if (Literals.Fits(n.Text, t, T, why))
					n.Type = t;
				else
				{
					Fail(n, .Literal, why);
					n.Type = T.Error;
				}
			case .Case:
				if (!t.IsEnum)
				{
					Fail(n, .Name, scope $".{n.Text} is a case, but the other side is {TypeTable.WithArticle(t, .. scope .())}");
					n.Type = T.Error;
					return;
				}
				let cs = t.Sym.FindCase(n.Text);
				if (cs == null || !cs.Payload.IsEmpty)
				{
					Fail(n, .Name, (cs == null) ? scope $"{S!(t)} has no case {n.Text}" : scope $"{n.Text} carries values: use a Make Case node");
					n.Type = T.Error;
					return;
				}
				n.Member = cs;
				n.Type = t;
			case .Name:
				TakeType(n, t);
			default:
			}
		}

		/// The free inputs of a sum of free inputs take `t` (`(a + b) * x`: a and b are x's type).
		void AdoptDeep(MathNode n, KType t)
		{
			if (n == null || t == null)
				return;
			switch (n.Kind)
			{
			case .Name:
				if (n.Adopts && n.Type == null)
					TakeType(n, t);
			case .Unary:
				if (n.Text == "-" || n.Text == "~")
					AdoptDeep(n.A, t);
			case .Binary:
				if (!IsCompare(n.Text) && !IsLogical(n.Text) && n.Text != "**")
				{
					AdoptDeep(n.A, t);
					if (n.Text != "<<" && n.Text != ">>")
						AdoptDeep(n.B, t);
				}
			case .Ternary:
				AdoptDeep(n.B, t);
				AdoptDeep(n.C, t);
			default:
			}
		}

		/// Both sides of an operator (or a Select's two arms) typed, a literal side taking the
		/// other's type; false when one is still free.
		bool Sides(MathNode a, MathNode b, out KType ta, out KType tb, StringView op = "")
		{
			ta = Type(a);
			tb = Type(b);
			// a number beside a type that declares `op` with a number on that side (`v * 2` with
			// Vec3 * float) takes that number type
			KType mixed = null;
			if (!op.IsEmpty && a.Adopts && !b.Adopts && tb != null && a.Kind == .Number && (mixed = c.MixedLiteralSide(op, tb, true, a.Text)) != null)
			{
				Adopt(a, mixed);
				ta = a.Type;
			}
			else if (!op.IsEmpty && b.Adopts && !a.Adopts && ta != null && b.Kind == .Number && (mixed = c.MixedLiteralSide(op, ta, false, b.Text)) != null)
			{
				Adopt(b, mixed);
				tb = b.Type;
			}
			else if (a.Adopts && !b.Adopts && tb != null)
			{
				Adopt(a, tb);
				ta = a.Type;
			}
			else if (b.Adopts && !a.Adopts && ta != null)
			{
				Adopt(b, ta);
				tb = b.Type;
			}
			else if (a.Adopts && b.Adopts)
			{
				// A free input meets a literal: it takes the literal's type (`a + 1`: a is an int).
				if (ta == null && tb != null && b.Kind != .Name)
				{
					Adopt(a, tb);
					ta = a.Type;
				}
				else if (tb == null && ta != null && a.Kind != .Name)
				{
					Adopt(b, ta);
					tb = b.Type;
				}
				else if (ta != null && tb != null && a.Kind == .Name && b.Kind != .Name)
				{
					// an input with only a literal next to a number: the number decides
					Adopt(a, tb);
					ta = a.Type;
				}
				else if (ta != null && tb != null && b.Kind == .Name && a.Kind != .Name)
				{
					Adopt(b, ta);
					tb = b.Type;
				}
			}
			if (ta == null && tb != null)
				AdoptDeep(a, tb);
			else if (tb == null && ta != null)
				AdoptDeep(b, ta);
			if (ta == null && a.Kind == .Case && tb == null && b.Kind == .Case)
			{
				Fail(a, .Name, "two cases: which enum they belong to cannot be told");
				ta = tb = T.Error;
			}
			return ta != null && tb != null;
		}

		/// The type two operands meet in (BindOperator's rule), or null.
		KType Common(KType ta, KType tb)
		{
			if (ta.IsVector || tb.IsVector)
				return VectorCommon(ta, tb); // BindVector.bf: a scalar splats into the vector
			if (ta.IsError || tb.IsError)
				return ta.IsError ? tb : ta;
			if (ta == tb)
				return ta;
			if (ta.IsNumeric && tb.IsNumeric)
				return T.CommonNumeric(ta, tb);
			if (T.CanConvert(tb, ta) != .Refused)
				return ta;
			if (T.CanConvert(ta, tb) != .Refused)
				return tb;
			return null;
		}

		/// A bool where one is needed (`&&`, `||`, `!`, a condition).
		void NeedBool(MathNode a, StringView what)
		{
			var t = Type(a);
			if (a.Adopts && (t == null || a.Kind == .Name))
			{
				Adopt(a, T.Bool);
				t = a.Type;
			}
			else if (t == null)
			{
				AdoptDeep(a, T.Bool);
				t = T.Error;
			}
			if (!t.IsError && t.Kind != .Bool)
				Fail(a, .Operand, scope $"{what} takes a bool, not {TypeTable.WithArticle(t, .. scope .())}");
		}

		void UnaryOp(MathNode n)
		{
			let a = n.A;
			if (n.Text == "!" && VectorNot(n)) // BindVector.bf: ! on a lane mask
				return;
			if (n.Text == "!")
			{
				NeedBool(a, "!");
				n.Operand = T.Bool;
				n.Type = T.Bool;
				return;
			}
			let op = (n.Text == "-") ? "neg" : (StringView)n.Text;
			var t = Type(a);
			if (t == null)
			{
				n.Type = null;
				return;
			}
			if (a.Kind == .Case)
			{
				Fail(a, .Name, scope $"which enum .{a.Text} belongs to cannot be told here");
				t = T.Error;
			}
			n.Operand = t;
			n.Type = t;
			if (t.IsError)
				return;
			let user = (t.Kind == .Named && !t.IsEnum) ? c.FindUserOperatorFor(t, op, t, null) : null;
			if (user != null)
			{
				n.Member = user;
				n.Owner = t;
				Dictionary<GenericParamSym, KType> map = scope .();
				T.MapOf(t, map);
				n.Type = T.Subst(user.Returns, map);
				UsesType(t);
			}
			else if (!c.SupportsOperator(t, op, mCtxMember))
			{
				Fail(n, .Operand, scope $"{S!(t)} has no operator {n.Text}");
				n.Type = T.Error;
			}
		}

		void BinaryOp(MathNode n)
		{
			StringView op = n.Text;
			n.Member = null;
			if (IsLogical(op) && VectorLogical(n)) // BindVector.bf: && and || on lane masks are T2300
				return;
			if (IsLogical(op))
			{
				NeedBool(n.A, op);
				NeedBool(n.B, op);
				n.Operand = T.Bool;
				n.Type = T.Bool;
				return;
			}
			if (!Sides(n.A, n.B, let ta, let tb, op))
			{
				n.Type = IsCompare(op) ? T.Bool : null;
				return;
			}
			let shift = op == "<<" || op == ">>";
			// a user operator whose inputs have different types (Vec3 * float, Mat4 * Vec4)
			if (!shift && ta != tb && !ta.IsVector && !tb.IsVector)
			{
				let mixed = c.FindMixedOperator(op, ta, tb, let owner);
				if (mixed != null)
				{
					n.Operand = owner;
					n.Member = mixed;
					n.Owner = owner;
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(owner, map);
					n.Type = T.Subst(mixed.Returns, map);
					UsesType(owner);
					return;
				}
			}
			KType operand = shift ? ta : Common(ta, tb);
			if (operand == null)
			{
				Fail(n, .Operand, scope $"{op} cannot combine {TypeTable.WithArticle(ta, .. scope .())} and {TypeTable.WithArticle(tb, .. scope .())}: Cast one of them");
				operand = T.Error;
			}
			n.Operand = operand;
			KType result = IsCompare(op) ? ((operand.IsVector) ? T.MaskOf(operand) : T.Bool) : operand; // vectors compare to a lane mask
			if (!operand.IsError)
			{
				let user = (operand.Kind == .Named && !(operand.IsEnum && !operand.Sym.HasPayload && (op == "==" || op == "!="))) ? c.FindUserOperatorFor(operand, op, operand, operand) : null;
				if (user != null && operand.Kind == .Named && !operand.IsEnum)
				{
					n.Member = user;
					n.Owner = operand;
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(operand, map);
					result = T.Subst(user.Returns, map);
					if (user.Params.Count != 2)
						Fail(n, .Operand, scope $"the operator {op} of {S!(operand)} takes {user.Params.Count} inputs");
					UsesType(operand);
				}
				else if (!c.SupportsOperator(operand, op, mCtxMember))
				{
					Fail(n, .Operand, scope $"{S!(operand)} has no operator {op}");
					result = IsCompare(op) ? T.Bool : T.Error;
				}
				if (shift && !tb.IsError && !tb.IsInteger)
					Fail(n.B, .Operand, scope $"a shift count is an integer, not {TypeTable.WithArticle(tb, .. scope .())}");
			}
			n.Type = result;
		}

		void TernaryOp(MathNode n)
		{
			if (VectorTernary(n)) // BindVector.bf: a lane mask selects lane by lane
				return;
			NeedBool(n.A, "the condition of ? :");
			if (!Sides(n.B, n.C, let ta, let tb))
			{
				n.Type = null;
				return;
			}
			var t = Common(ta, tb);
			if (t == null)
			{
				Fail(n, .Operand, scope $"? : gives {TypeTable.WithArticle(ta, .. scope .())} or {TypeTable.WithArticle(tb, .. scope .())}: they need one type");
				t = T.Error;
			}
			if (t.Kind == .Null)
				t = T.Error;
			n.Operand = t;
			n.Type = t;
		}

		/// The Core.Math type.
		public TypeSym MathSym => T.Find("Core.Math");

		/// `Sqrt(x)`, `Math.Max(a, b)`, `a ** b` (Pow): a static function of Core.Math chosen by
		/// its inputs as a Call node chooses an overload.
		void Call(MathNode n, StringView path, List<MathNode> args)
		{
			n.Member = null;
			DeleteAndNullify!(n.MethodArgs);
			if (VectorCall(n, path, args)) // BindVector.bf: `float4(a, b, c, d)`, Math functions on vectors
				return;
			var name = path;
			let dot = path.LastIndexOf('.');
			if (dot >= 0)
			{
				let owner = path.Substring(0, dot);
				name = path.Substring(dot + 1);
				if (owner != "Math" && owner != "Core.Math")
				{
					for (let a in args)
						Type(a);
					Fail(n, .Function, scope $"{path}: a Math Expression calls the functions of Math only");
					n.Type = T.Error;
					return;
				}
			}
			let ms = MathSym;
			List<MemberSym> cands = scope .();
			if (ms != null)
			{
				for (let m in ms.Members)
					if (m.Kind == .Function && m.Static && m.Name == name)
						cands.Add(m);
				if (cands.IsEmpty)
					for (let m in ms.Members)
						if (m.Kind == .Function && m.Static && m.Name.Equals(name, .OrdinalIgnoreCase))
							cands.Add(m);
			}
			List<KType> types = scope .();
			for (let a in args)
				types.Add(Type(a));
			if (cands.IsEmpty)
			{
				Fail(n, .Function, scope $"Math has no function {name}");
				n.Type = T.Error;
				return;
			}
			MemberSym best = null;
			int bestScore = int.MinValue;
			bool tie = false;
			for (let f in cands)
			{
				if (f.Params.Count != args.Count)
					continue;
				let score = Score(f, args);
				if (score > bestScore)
				{
					best = f;
					bestScore = score;
					tie = false;
				}
				else if (score == bestScore)
					tie = true;
			}
			if (best == null || bestScore < 0)
			{
				String list = scope .();
				for (let f in cands)
				{
					if (@f.Index > 0)
						list.Append(", ");
					f.GetSignature(list);
				}
				Fail(n, .Function, scope $"no {name} takes these inputs ({list})");
				n.Type = T.Error;
				return;
			}
			if (tie)
			{
				Fail(n, .Function, scope $"several overloads of {name} fit these inputs: Cast an input");
				n.Type = T.Error;
				return;
			}
			let f = best;
			n.Member = f;
			n.Owner = ms.Self;
			Dictionary<GenericParamSym, KType> map = scope .();
			if (f.IsGeneric)
			{
				List<GenericParamSym> infer = scope .();
				for (let g in f.Generics)
					infer.Add(g);
				// The typed inputs first, then the literals' own types.
				for (int pass < 2)
					for (int i < args.Count)
					{
						let t = args[i].Type;
						if (t == null || t.IsError || (args[i].Adopts != (pass == 1)))
							continue;
						if (pass == 1 && TypeTable.IsOpen(T.Subst(f.Params[i].Type, map)) == false)
							continue;
						T.Unify(f.Params[i].Type, t, map, infer);
					}
				n.MethodArgs = new .();
				for (let g in f.Generics)
				{
					if (!map.TryGetValue(g, let arg))
					{
						Fail(n, .Function, scope $"{name}: what {g.Name} is cannot be told from the inputs");
						map[g] = T.Error;
						n.MethodArgs.Add(T.Error);
						continue;
					}
					n.MethodArgs.Add(arg);
					String why = scope .();
					if (!arg.IsError && !c.Satisfies(arg, g, map, mCtxMember, why))
						Fail(n, .Function, scope $"{name}<{arg.Name}>: {why}");
				}
				UsesFunction(f, n.MethodArgs);
			}
			for (int i < args.Count)
			{
				let want = T.Subst(f.Params[i].Type, map);
				if (args[i].Adopts)
					Adopt(args[i], want);
				else if (args[i].Type == null)
					AdoptDeep(args[i], want);
				else if (!args[i].Type.IsError && T.CanConvert(args[i].Type, want) == .Refused)
					Fail(args[i], .Operand, scope $"{name} takes {TypeTable.WithArticle(want, .. scope .())} here, not {TypeTable.WithArticle(args[i].Type, .. scope .())}");
			}
			n.Type = T.Subst(f.Returns, map);
		}

		/// How well `f` fits the inputs (Bind's ScoreArgs, by position).
		int Score(MemberSym f, List<MathNode> args)
		{
			int score = 0;
			for (int i < args.Count)
			{
				let want = f.Params[i].Type;
				let a = args[i];
				let have = a.Type;
				if (TypeTable.IsOpen(want))
				{
					score += 1;
					continue;
				}
				if (have == null || have.IsError)
				{
					score += 1;
					continue;
				}
				if (a.Adopts && (a.Kind == .Number || a.Kind == .Text))
				{
					score += Literals.Fits(a.Text, want, T, scope .()) ? ((have == want) ? 4 : 3) : -100;
					continue;
				}
				switch (T.CanConvert(have, want))
				{
				case .Exact: score += 4;
				case .Implicit: score += 2;
				case .Refused: score -= 100;
				}
			}
			score *= 2;
			// An integer given to a float where a double overload fits as well goes to the double one.
			for (int i < args.Count)
				if (f.Params[i].Type == T.Float && args[i].Type != null && args[i].Type.IsInteger)
					score -= 1;
			return score;
		}
	}
}
