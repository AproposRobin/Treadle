using System;
using System.Collections;

namespace Treadle.Compiler
{
	enum MathKind : uint8
	{
		/// A number: `12`, `0x1F`, `1.5`, `2e3`, `0.5f`, `2d` (Text is the token; a leading `-` is
		/// folded in when the minus applies to the number alone).
		Number,
		/// `true` / `false`.
		Bool,
		/// A text literal `"..."` (constants only; Text keeps the quotes).
		Text,
		/// `.Case`: a case of the enum the other side (or the constant) has.
		Case,
		/// A name or a dotted path: an input and its fields (`a`, `a.x`) on a Math Expression node,
		/// a constant (`Width`, `Game.Width`, `Color.Red`) in a constant's init.
		Name,
		/// `Sqrt(x)`, `Math.Max(a, b)`: a function of Core.Math (Text is the name as written).
		Call,
		/// `-a`, `!a`, `~a` (Text: the operator; `+a` is `a`).
		Unary,
		/// `a op b` (Text: the operator, `**` for the power).
		Binary,
		/// `c ? a : b`.
		Ternary,
		/// `(a + b).xy`, `Sqrt(v).x`: lanes of a vector the expression before the dot gives (Text: the
		/// letters; a name's own swizzle, `v.zyx`, is a Name path).
		Swizzle
	}

	/// One node of a Math Expression or a constant's init (Language.md 5.6): what the parser read,
	/// and what binding found (types, members) for Lower and for constant folding.
	class MathNode
	{
		public MathKind Kind;
		/// The token, the name path, the operator or the function as written.
		public String Text = new .() ~ delete _;
		/// Where it starts in the text (0-based; messages say `at <Pos + 1>`).
		public int32 Pos;
		public List<MathNode> Args = new .() ~ DeleteContainerAndItems!(_);

		// ---- bound
		/// The value's type.
		public KType Type;
		/// Unary / Binary: the type the operands convert to; Ternary: the arms' type.
		public KType Operand;
		/// Call: the function; Binary / Unary: a user operator; Name: the constant (constants).
		public MemberSym Member;
		/// Call: the owner (Core.Math); a user operator's type.
		public KType Owner;
		/// Call: the function's own generic arguments.
		public List<KType> MethodArgs ~ delete _;
		/// Name on a Math Expression node: the fields of the path after the input, each with the
		/// instance it is read from.
		public List<(MemberSym field, KType owner)> Fields ~ delete _;
		/// A leaf whose type follows the other side of its operator (a number, `.Case`, an input
		/// with only a literal or nothing yet), as a literal on an Operator node's pin does.
		public bool Adopts;
		/// Vectors (SIMD-and-Vectors.md 1.8): the lanes a swizzle picks (a Name path ending in letters,
		/// a Swizzle), and the vector function or constructor a Call is (`float4(...)`, `Dot(a, b)`).
		public List<int> Lanes ~ delete _;
		public VecFn VecFn;
		public bool VecMake;

		public MathNode A => (Args.Count > 0) ? Args[0] : null;
		public MathNode B => (Args.Count > 1) ? Args[1] : null;
		public MathNode C => (Args.Count > 2) ? Args[2] : null;

		/// The input a Name reads (its first segment).
		public StringView Root
		{
			get
			{
				let dot = Text.IndexOf('.');
				return (dot < 0) ? (StringView)Text : Text.Substring(0, dot);
			}
		}
	}

	/// The Math Expression grammar (Language.md 5.6), one parser for the Math Expression node, the
	/// editor's field (ILanguageRules.CheckExpression) and constants' inits:
	///
	///   expr    := or ('?' expr ':' expr)?
	///   or      := and ('||' and)*            and    := bitor ('&&' bitor)*
	///   bitor   := bitxor ('|' bitxor)*       bitxor := bitand ('^' bitand)*
	///   bitand  := eq ('&' eq)*               eq     := rel (('==' | '!=') rel)*
	///   rel     := shift (('<' | '<=' | '>' | '>=') shift)*
	///   shift   := sum (('<<' | '>>') sum)*   sum    := product (('+' | '-') product)*
	///   product := unary (('*' | '/' | '%') unary)*
	///   unary   := ('-' | '+' | '!' | '~') unary | power
	///   power   := primary ('**' unary)?
	///   primary := number | true | false | "text" | .Case | path | (path '(' args ')' | '(' expr ')') ('.' letters)?
	///   path    := name ('.' name)*          (a vector's last segment may be swizzle letters: `v.zyx`)
	static class MathExpr
	{
		struct Reader
		{
			public StringView Text;
			public int Pos;
			public String Why;

			public void Skip() mut
			{
				while (Pos < Text.Length && Text[Pos].IsWhiteSpace)
					Pos++;
			}

			public char8 Peek() mut
			{
				Skip();
				return (Pos < Text.Length) ? Text[Pos] : 0;
			}

			public char8 PeekAt(int ahead) => (Pos + ahead < Text.Length) ? Text[Pos + ahead] : 0;

			/// Takes `op` when the text continues with it and the character after it is none of `notFollowedBy`.
			public bool Take(StringView op, StringView notFollowedBy = "") mut
			{
				Skip();
				if (Pos + op.Length > Text.Length || Text.Substring(Pos, op.Length) != op)
					return false;
				let next = PeekAt(op.Length);
				for (let c in notFollowedBy.RawChars)
					if (next == c)
						return false;
				Pos += op.Length;
				return true;
			}

			public void Fail(StringView message, int at) mut
			{
				if (Why.IsEmpty)
					Why.AppendF("{} at {}", message, at + 1);
			}
		}

		/// The names the expression reads as inputs (the first segment of each path; functions
		/// left out), in order of first use. False with `why` when the text does not parse.
		public static bool Parse(StringView text, List<String> outNames, String why)
		{
			let tree = Build(text, why);
			if (tree == null)
				return false;
			Collect(tree, outNames);
			delete tree;
			return true;
		}

		public static void Collect(MathNode n, List<String> outNames)
		{
			if (n == null)
				return;
			if (n.Kind == .Name)
			{
				let root = n.Root;
				bool have = false;
				for (let s in outNames)
					if (s == root)
						have = true;
				if (!have)
					outNames.Add(new String(root));
			}
			for (let a in n.Args)
				Collect(a, outNames);
		}

		/// The tree (the caller deletes it), or null with `why` ("unexpected ')' at 5").
		public static MathNode Build(StringView text, String why)
		{
			Reader r = .();
			r.Text = text;
			r.Why = why;
			why.Clear();
			if (text.IsEmpty || text.IsWhiteSpace)
			{
				why.Set("the expression is empty");
				return null;
			}
			let n = Expr(ref r);
			if (n == null)
				return null;
			if (r.Peek() != 0)
			{
				r.Fail(scope $"unexpected '{r.Text[r.Pos]}'", r.Pos);
				delete n;
				return null;
			}
			return n;
		}

		/// A comma-separated list of expressions (a constant array's `elements`); false with `why`.
		public static bool BuildList(StringView text, List<MathNode> outList, String why)
		{
			Reader r = .();
			r.Text = text;
			r.Why = why;
			why.Clear();
			if (text.IsWhiteSpace)
				return true;
			while (true)
			{
				let n = Expr(ref r);
				if (n == null)
					return false;
				outList.Add(n);
				if (r.Peek() == ',')
				{
					r.Pos++;
					continue;
				}
				if (r.Peek() != 0)
				{
					r.Fail(scope $"unexpected '{r.Text[r.Pos]}' (elements are separated by commas)", r.Pos);
					return false;
				}
				return true;
			}
		}

		static MathNode Node(MathKind kind, StringView text, int pos)
		{
			MathNode n = new .();
			n.Kind = kind;
			n.Text.Set(text);
			n.Pos = (int32)pos;
			return n;
		}

		static MathNode Join(MathKind kind, StringView op, int pos, MathNode a, MathNode b, MathNode c = null)
		{
			let n = Node(kind, op, pos);
			n.Args.Add(a);
			if (b != null)
				n.Args.Add(b);
			if (c != null)
				n.Args.Add(c);
			return n;
		}

		static MathNode Expr(ref Reader r)
		{
			let cond = Level(ref r, 0);
			if (cond == null)
				return null;
			if (r.Peek() != '?')
				return cond;
			let at = r.Pos;
			r.Pos++;
			let yes = Expr(ref r);
			if (yes == null)
			{
				delete cond;
				return null;
			}
			if (r.Peek() != ':')
			{
				r.Fail("a ':' is missing (c ? a : b)", r.Pos);
				delete cond;
				delete yes;
				return null;
			}
			r.Pos++;
			let no = Expr(ref r);
			if (no == null)
			{
				delete cond;
				delete yes;
				return null;
			}
			return Join(.Ternary, "?", at, cond, yes, no);
		}

		/// The binary operators by level, loosest first; within a level the longer ones first.
		static StringView[?] cLevels = .("||", "&&", "|", "^", "&", "== !=", "<= >= < >", "<< >>", "+ -", "* / %");

		/// What an operator may not be followed by (`&` is not `&&`, `<` not `<<` or `<=`, `*` not `**`).
		static StringView NotAfter(StringView op)
		{
			switch (op)
			{
			case "&": return "&";
			case "|": return "|";
			case "<": return "<=";
			case ">": return ">=";
			case "*": return "*";
			default: return "";
			}
		}

		/// One left-associative level: `next (op next)*`.
		static MathNode Level(ref Reader r, int level)
		{
			if (level >= cLevels.Count)
				return Unary(ref r);
			var left = Level(ref r, level + 1);
			while (left != null)
			{
				r.Skip();
				let at = r.Pos;
				StringView found = default;
				for (let op in cLevels[level].Split(' '))
					if (r.Take(op, NotAfter(op)))
					{
						found = op;
						break;
					}
				if (found.IsEmpty)
					break;
				let right = Level(ref r, level + 1);
				if (right == null)
				{
					delete left;
					return null;
				}
				left = Join(.Binary, found, at, left, right);
			}
			return left;
		}

		static MathNode Unary(ref Reader r)
		{
			let c = r.Peek();
			let at = r.Pos;
			if ((c == '-' || c == '+' || c == '!' || c == '~') && !(c == '!' && r.PeekAt(1) == '='))
			{
				r.Pos++;
				let a = Unary(ref r);
				if (a == null)
					return null;
				if (c == '+')
					return a;
				if (c == '-' && a.Kind == .Number && !a.Text.StartsWith('-'))
				{
					// `-2` is the literal -2 (as an `in` line writes it); `-2 ** 2` is -(2 ** 2).
					a.Text.Insert(0, '-');
					a.Pos = (int32)at;
					return a;
				}
				return Join(.Unary, scope String()..Append(c), at, a, null);
			}
			return Power(ref r);
		}

		static MathNode Power(ref Reader r)
		{
			let b = Primary(ref r);
			if (b == null)
				return null;
			r.Skip();
			let at = r.Pos;
			if (!r.Take("**"))
				return b;
			// Right-associative, and its right side may be negative: 2 ** -1, 2 ** 3 ** 2.
			let e = Unary(ref r);
			if (e == null)
			{
				delete b;
				return null;
			}
			return Join(.Binary, "**", at, b, e);
		}

		/// `(a + b).xy`, `Sqrt(v).x`: a swizzle after a parenthesised expression or a call (vectors,
		/// SIMD-and-Vectors.md 1.8; Typing checks the letters).
		static MathNode Postfix(ref Reader r, MathNode n)
		{
			if (r.Pos + 1 >= r.Text.Length || r.Text[r.Pos] != '.' || !IsNameStart(r.Text[r.Pos + 1]))
				return n;
			let at = r.Pos;
			r.Pos++;
			let start = r.Pos;
			while (r.Pos < r.Text.Length && IsNameChar(r.Text[r.Pos]))
				r.Pos++;
			let s = Node(.Swizzle, r.Text.Substring(start, r.Pos - start), at);
			s.Args.Add(n);
			return s;
		}

		static bool IsNameStart(char8 c) => c.IsLetter || c == '_';
		static bool IsNameChar(char8 c) => c.IsLetterOrDigit || c == '_';

		static MathNode Primary(ref Reader r)
		{
			let c = r.Peek();
			let start = r.Pos;
			if (c == '(')
			{
				r.Pos++;
				let n = Expr(ref r);
				if (n == null)
					return null;
				if (r.Peek() != ')')
				{
					r.Fail("a ')' is missing", r.Pos);
					delete n;
					return null;
				}
				r.Pos++;
				return Postfix(ref r, n);
			}
			if (c.IsDigit || (c == '.' && r.PeekAt(1).IsDigit))
				return Number(ref r);
			if (c == '"')
			{
				r.Pos++;
				while (r.Pos < r.Text.Length && r.Text[r.Pos] != '"')
					r.Pos += (r.Text[r.Pos] == '\\') ? 2 : 1;
				if (r.Pos >= r.Text.Length)
				{
					r.Fail("a text has no closing quote", start);
					return null;
				}
				r.Pos++;
				return Node(.Text, r.Text.Substring(start, r.Pos - start), start);
			}
			if (c == '.' && IsNameStart(r.PeekAt(1)))
			{
				r.Pos++;
				while (r.Pos < r.Text.Length && IsNameChar(r.Text[r.Pos]))
					r.Pos++;
				return Node(.Case, r.Text.Substring(start + 1, r.Pos - start - 1), start);
			}
			if (IsNameStart(c))
			{
				while (true)
				{
					while (r.Pos < r.Text.Length && IsNameChar(r.Text[r.Pos]))
						r.Pos++;
					if (r.Pos + 1 < r.Text.Length && r.Text[r.Pos] == '.' && IsNameStart(r.Text[r.Pos + 1]))
					{
						r.Pos++;
						continue;
					}
					break;
				}
				let path = r.Text.Substring(start, r.Pos - start);
				if (path == "true" || path == "false")
					return Node(.Bool, path, start);
				if (r.Peek() == '(')
				{
					r.Pos++;
					let call = Node(.Call, path, start);
					if (r.Peek() == ')')
					{
						r.Pos++;
						return Postfix(ref r, call);
					}
					while (true)
					{
						let a = Expr(ref r);
						if (a == null)
						{
							delete call;
							return null;
						}
						call.Args.Add(a);
						let s = r.Peek();
						if (s == ',')
						{
							r.Pos++;
							continue;
						}
						if (s == ')')
						{
							r.Pos++;
							return Postfix(ref r, call);
						}
						r.Fail(scope $"a ')' is missing after the inputs of {path}", r.Pos);
						delete call;
						return null;
					}
				}
				return Node(.Name, path, start);
			}
			if (c == 0)
				r.Fail("the expression ends too early", r.Pos);
			else
				r.Fail(scope $"unexpected '{c}'", r.Pos);
			return null;
		}

		/// `12`, `0x1F`, `1.5`, `.5`, `2e-3`, `1.5f`, `2d`.
		static MathNode Number(ref Reader r)
		{
			let start = r.Pos;
			let t = r.Text;
			if (t[r.Pos] == '0' && (r.PeekAt(1) == 'x' || r.PeekAt(1) == 'X'))
			{
				r.Pos += 2;
				while (r.Pos < t.Length && (t[r.Pos].IsDigit || (t[r.Pos] >= 'a' && t[r.Pos] <= 'f') || (t[r.Pos] >= 'A' && t[r.Pos] <= 'F')))
					r.Pos++;
			}
			else
			{
				while (r.Pos < t.Length && t[r.Pos].IsDigit)
					r.Pos++;
				if (r.Pos < t.Length && t[r.Pos] == '.' && r.PeekAt(1).IsDigit)
				{
					r.Pos++;
					while (r.Pos < t.Length && t[r.Pos].IsDigit)
						r.Pos++;
				}
				if (r.Pos < t.Length && (t[r.Pos] == 'e' || t[r.Pos] == 'E'))
				{
					int p = r.Pos + 1;
					if (p < t.Length && (t[p] == '+' || t[p] == '-'))
						p++;
					if (p < t.Length && t[p].IsDigit)
					{
						r.Pos = p;
						while (r.Pos < t.Length && t[r.Pos].IsDigit)
							r.Pos++;
					}
				}
				if (r.Pos < t.Length && (t[r.Pos] == 'f' || t[r.Pos] == 'F' || t[r.Pos] == 'd' || t[r.Pos] == 'D'))
					r.Pos++;
			}
			if (r.Pos < t.Length && IsNameChar(t[r.Pos]))
			{
				r.Fail(scope $"'{t.Substring(start, r.Pos - start + 1)}' is not a number", start);
				return null;
			}
			let text = t.Substring(start, r.Pos - start);
			if (text.StartsWith('.'))
				return Node(.Number, scope $"0{text}", start);
			return Node(.Number, text, start);
		}

		/// The Math Expression of a node: `set expr "..."` (the node's text when the setting is missing).
		public static void TextOf(Treadle.Graph.Node n, String outText)
		{
			let s = n.GetSetting("expr");
			if (!s.IsEmpty)
				Treadle.Format.RecordText.Unquote(s, outText);
			else
				outText.Append(n.Text);
		}
	}
}
