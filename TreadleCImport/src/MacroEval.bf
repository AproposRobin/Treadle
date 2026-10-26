using System;
using System.Collections;

namespace Treadle.CImport
{
	/// A constant value of a macro: an integer of a C type (bits + signedness), a float, or a
	/// string.
	struct CValue
	{
		public enum Kind : uint8 { Int, Float, String }

		public Kind ValueKind;
		/// Int: the value's bits (sign-extended for signed types).
		public uint64 Bits;
		public int32 Width;
		public bool Unsigned;
		/// Float: the value; Width 32 = float, 64 = double.
		public double F;

		public static CValue Int(uint64 bits, int32 width, bool isUnsigned)
		{
			CValue v = default;
			v.ValueKind = .Int;
			v.Width = width;
			v.Unsigned = isUnsigned;
			v.Bits = Normalize(bits, width, isUnsigned);
			return v;
		}

		public static CValue Float(double f, int32 width)
		{
			CValue v = default;
			v.ValueKind = .Float;
			v.F = f;
			v.Width = width;
			return v;
		}

		/// Truncates to `width` bits, then sign-extends when signed.
		public static uint64 Normalize(uint64 bits, int32 width, bool isUnsigned)
		{
			if (width >= 64)
				return bits;
			let mask = (1UL << width) - 1;
			var b = bits & mask;
			if (!isUnsigned && (b & (1UL << (width - 1))) != 0)
				b |= ~mask;
			return b;
		}

		public bool IsTrue => (ValueKind == .Float) ? F != 0 : Bits != 0;
		public double AsDouble => (ValueKind == .Float) ? F : (Unsigned ? (double)Bits : (double)(int64)Bits);

		/// The Treadle type of the value: `int32`, `uint64`, `double`, ...
		public void TypeName(String outText)
		{
			if (ValueKind == .Float)
			{
				outText.Append((Width == 32) ? "float" : "double");
				return;
			}
			outText.AppendF("{}int{}", Unsigned ? "u" : "", Width);
		}

		public void ValueText(String outText)
		{
			if (ValueKind == .Float)
			{
				let start = outText.Length;
				F.ToString(outText);
				let s = StringView(outText, start);
				if (!s.Contains('.') && !s.Contains('E') && !s.Contains('e') && !s.Contains('N') && !s.Contains('I'))
					outText.Append(".0");
				return;
			}
			if (Unsigned)
				outText.AppendF("{}", Bits);
			else
				outText.AppendF("{}", (int64)Bits);
		}
	}

	/// Evaluates object-like macros: one literal, adjacent string literals, or a constant
	/// expression over integer / float literals, other accepted macros, enum constants, casts to
	/// integer or float types, unary + - ~ !, the binary arithmetic, shift, comparison, bitwise
	/// and logical operators, and `?:`. Anything else (function-like macros, sizeof, pointers,
	/// keywords such as `__cdecl`) is not a constant and the macro is skipped with a warning.
	class MacroEval
	{
		public struct Tok
		{
			public int32 Kind;
			public String Text;
		}

		/// Object-like macro bodies by name (owned lists of owned token texts).
		public Dictionary<String, List<Tok>> Bodies = new .() ~
			{
				for (let kv in _)
				{
					delete kv.key;
					for (let t in kv.value)
						delete t.Text;
					delete kv.value;
				}
				delete _;
			};
		/// Enum constant values by name.
		public Dictionary<String, int64> EnumConsts = new .() ~ DeleteDictionaryAndKeys!(_);
		/// Typedefs of arithmetic types, for casts: width, unsigned, float.
		public Dictionary<String, (int32 width, bool isUnsigned, bool isFloat)> ArithTypedefs = new .() ~ DeleteDictionaryAndKeys!(_);

		Dictionary<String, CValue> mDone = new .() ~ DeleteDictionaryAndKeys!(_);
		Dictionary<String, String> mStrings = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		HashSet<String> mFailed = new .() ~ DeleteContainerAndItems!(_);
		HashSet<String> mActive = new .() ~ delete _;

		public void AddBody(StringView name, List<Tok> tokens)
		{
			if (Bodies.ContainsKeyAlt(name))
			{
				for (let t in tokens)
					delete t.Text;
				delete tokens;
				return;
			}
			Bodies[new String(name)] = tokens;
		}

		public enum Outcome { Empty, Value, String, NotConstant }

		/// Evaluates the macro `name`. `outString` gets a string constant's text.
		public Outcome Evaluate(StringView name, out CValue value, String outString)
		{
			value = default;
			if (!Bodies.TryGetAlt(name, var key, var body))
				return .NotConstant;
			if (body.IsEmpty)
				return .Empty;
			if (mStrings.TryGetAlt(name, var matchedKey, var s))
			{
				outString.Append(s);
				return .String;
			}
			if (body.Count == 1 && body[0].Kind == CXTokenKind.Identifier && Bodies.ContainsKeyAlt(body[0].Text) && !mActive.Contains(key))
			{
				// `#define P_tmpdir _P_tmpdir`: an alias of another macro
				mActive.Add(key);
				let r = Evaluate(body[0].Text, var aliased, outString);
				mActive.Remove(key);
				value = aliased;
				return r;
			}
			if (AllStrings(body))
			{
				String text = scope .();
				for (let t in body)
					if (!UnquoteC(t.Text, text))
						return .NotConstant;
				mStrings[new String(name)] = new String(text);
				outString.Append(text);
				return .String;
			}
			if (Value(name, out value))
				return .Value;
			return .NotConstant;
		}

		static bool AllStrings(List<Tok> body)
		{
			for (let t in body)
				if (t.Kind != CXTokenKind.Literal || !t.Text.EndsWith('"') || !(t.Text.StartsWith('"') || t.Text.StartsWith("u8\"")))
					return false;
			return true;
		}

		bool Value(StringView name, out CValue value)
		{
			value = default;
			if (mDone.TryGetAlt(name, var matchedKey, out value))
				return true;
			if (mFailed.ContainsAlt(name))
				return false;
			if (!Bodies.TryGetAlt(name, var key, var body) || body.IsEmpty)
				return false;
			if (mActive.Contains(key))
				return false;
			mActive.Add(key);
			Parser p = scope .(this, body);
			let ok = p.Expr(out value) && p.AtEnd;
			mActive.Remove(key);
			if (ok)
				mDone[new String(name)] = value;
			else
				mFailed.Add(new String(name));
			return ok;
		}

		/// A C string literal's text (escapes resolved) appended to `outText`.
		public static bool UnquoteC(StringView token, String outText)
		{
			var t = token;
			if (t.StartsWith("u8"))
				t = t.Substring(2);
			if (t.Length < 2 || t[0] != '"' || t[t.Length - 1] != '"')
				return false;
			let inner = t.Substring(1, t.Length - 2);
			for (int i = 0; i < inner.Length; i++)
			{
				let c = inner[i];
				if (c != '\\')
				{
					outText.Append(c);
					continue;
				}
				if (i + 1 >= inner.Length)
					return false;
				let e = inner[++i];
				switch (e)
				{
				case 'n': outText.Append('\n');
				case 't': outText.Append('\t');
				case 'r': outText.Append('\r');
				case 'a': outText.Append('\a');
				case 'b': outText.Append('\b');
				case 'f': outText.Append('\f');
				case 'v': outText.Append('\v');
				case '\\', '"', '\'', '?': outText.Append(e);
				case 'x':
					uint32 v = 0;
					int n = 0;
					while (i + 1 < inner.Length && IsHex(inner[i + 1]))
					{
						v = v * 16 + (uint32)HexValue(inner[++i]);
						n++;
					}
					if (n == 0 || v > 0xFF)
						return false;
					outText.Append((char8)(uint8)v);
				default:
					if (e >= '0' && e <= '7')
					{
						uint32 v = (uint32)(e - '0');
						int n = 1;
						while (n < 3 && i + 1 < inner.Length && inner[i + 1] >= '0' && inner[i + 1] <= '7')
						{
							v = v * 8 + (uint32)(inner[++i] - '0');
							n++;
						}
						if (v > 0xFF)
							return false;
						outText.Append((char8)(uint8)v);
					}
					else
						return false;
				}
			}
			return true;
		}

		static bool IsHex(char8 c) => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

		static int HexValue(char8 c)
		{
			if (c >= '0' && c <= '9')
				return c - '0';
			if (c >= 'a' && c <= 'f')
				return c - 'a' + 10;
			return c - 'A' + 10;
		}

		/// An integer or float literal token.
		public static bool ParseNumber(StringView token, out CValue value)
		{
			value = default;
			var t = token;
			if (t.Contains('\''))
			{
				// C23 digit separators
				String s = scope:: .();
				for (let c in t.RawChars)
					if (c != '\'')
						s.Append(c);
				t = s;
			}
			bool hex = t.StartsWith("0x") || t.StartsWith("0X");
			bool bin = t.StartsWith("0b") || t.StartsWith("0B");
			bool isFloat = !bin && (t.Contains('.') || (!hex && (t.Contains('e') || t.Contains('E'))) || (hex && (t.Contains('p') || t.Contains('P'))));
			if (isFloat)
			{
				var body = t;
				int32 width = 64;
				if (body.EndsWith('f') || body.EndsWith('F'))
				{
					if (hex)
						return false;
					width = 32;
					body = body.Substring(0, body.Length - 1);
				}
				else if (body.EndsWith('l') || body.EndsWith('L'))
					return false; // long double: no Treadle type
				if (hex)
					return false;
				if (double.Parse(body) case .Ok(let d))
				{
					value = CValue.Float(width == 32 ? (double)(float)d : d, width);
					return true;
				}
				return false;
			}
			// suffix
			int end = t.Length;
			bool u = false;
			int longs = 0;
			while (end > 0)
			{
				let c = t[end - 1];
				if (c == 'u' || c == 'U')
					u = true;
				else if (c == 'l' || c == 'L')
					longs++;
				else
					break;
				end--;
			}
			var digits = t.Substring(0, end);
			int radix = 10;
			if (hex || bin)
			{
				radix = hex ? 16 : 2;
				digits = digits.Substring(2);
			}
			else if (digits.Length > 1 && digits[0] == '0')
			{
				radix = 8;
				digits = digits.Substring(1);
			}
			if (digits.IsEmpty)
				return false;
			uint64 v = 0;
			for (let c in digits.RawChars)
			{
				int d;
				if (c >= '0' && c <= '9')
					d = c - '0';
				else if (c >= 'a' && c <= 'f')
					d = c - 'a' + 10;
				else if (c >= 'A' && c <= 'F')
					d = c - 'A' + 10;
				else
					return false;
				if (d >= radix)
					return false;
				let next = v * (uint64)radix + (uint64)d;
				if (next / (uint64)radix != v)
					return false; // too large for 64 bits
				v = next;
			}
			bool decimal = radix == 10;
			// LLP64: long is 32 bits, so `l` changes nothing and `ll` means 64.
			int32 width = (longs >= 2) ? 64 : 32;
			bool uns = u;
			if (width == 32)
			{
				if (!uns && v <= (uint64)int32.MaxValue)
				{
				}
				else if ((uns || !decimal) && v <= (uint64)uint32.MaxValue)
					uns = true;
				else
					width = 64;
			}
			if (width == 64 && !uns && v > (uint64)int64.MaxValue)
			{
				if (decimal && !u)
					return false; // does not fit any signed type
				uns = true;
			}
			value = CValue.Int(v, width, uns);
			return true;
		}

		/// A character literal: 'a', '\n', '\x41'.
		public static bool ParseChar(StringView token, out CValue value)
		{
			value = default;
			if (token.Length < 3 || token[0] != '\'' || token[token.Length - 1] != '\'')
				return false;
			String text = scope .();
			String quoted = scope .();
			quoted.Append('"');
			quoted.Append(token.Substring(1, token.Length - 2));
			quoted.Append('"');
			if (!UnquoteC(quoted, text) || text.Length != 1)
				return false;
			value = CValue.Int((uint64)(int64)(int8)(uint8)text[0], 32, false);
			return true;
		}

		/// Recursive descent over one macro body.
		class Parser
		{
			MacroEval mOwner;
			List<Tok> mToks;
			int mPos;

			public this(MacroEval owner, List<Tok> toks)
			{
				mOwner = owner;
				mToks = toks;
			}

			public bool AtEnd => mPos >= mToks.Count;

			bool Is(StringView punct) => mPos < mToks.Count && mToks[mPos].Kind == CXTokenKind.Punctuation && mToks[mPos].Text == punct;

			bool Accept(StringView punct)
			{
				if (!Is(punct))
					return false;
				mPos++;
				return true;
			}

			public bool Expr(out CValue v)
			{
				if (!Binary(1, out v))
					return false;
				if (Accept("?"))
				{
					CValue a = default, b = default;
					if (!Expr(out a))
						return false;
					if (!Accept(":"))
						return false;
					if (!Expr(out b))
						return false;
					v = v.IsTrue ? a : b;
				}
				return true;
			}

			static int Prec(StringView op)
			{
				switch (op)
				{
				case "*", "/", "%": return 10;
				case "+", "-": return 9;
				case "<<", ">>": return 8;
				case "<", ">", "<=", ">=": return 7;
				case "==", "!=": return 6;
				case "&": return 5;
				case "^": return 4;
				case "|": return 3;
				case "&&": return 2;
				case "||": return 1;
				default: return -1;
				}
			}

			bool Binary(int minPrec, out CValue v)
			{
				if (!Unary(out v))
					return false;
				while (mPos < mToks.Count && mToks[mPos].Kind == CXTokenKind.Punctuation)
				{
					let op = mToks[mPos].Text;
					let p = Prec(op);
					if (p < minPrec)
						break;
					mPos++;
					if (!Binary(p + 1, var rhs))
						return false;
					let lhs = v;
					if (!Apply(op, lhs, rhs, out v))
						return false;
				}
				return true;
			}

			static CValue Promote(CValue v)
			{
				if (v.ValueKind == .Int && v.Width < 32)
					return CValue.Int(v.Bits, 32, false);
				return v;
			}

			static bool Apply(StringView op, CValue a0, CValue b0, out CValue r)
			{
				r = default;
				let a = Promote(a0);
				let b = Promote(b0);
				bool cmp = op == "<" || op == ">" || op == "<=" || op == ">=" || op == "==" || op == "!=";
				if (op == "&&" || op == "||")
				{
					let t = (op == "&&") ? (a.IsTrue && b.IsTrue) : (a.IsTrue || b.IsTrue);
					r = CValue.Int(t ? 1 : 0, 32, false);
					return true;
				}
				if (a.ValueKind == .Float || b.ValueKind == .Float)
				{
					let x = a.AsDouble;
					let y = b.AsDouble;
					let w = (a.ValueKind == .Float && b.ValueKind == .Float && a.Width == 32 && b.Width == 32) ? 32 : 64;
					double f;
					switch (op)
					{
					case "*": f = x * y;
					case "/": f = x / y;
					case "+": f = x + y;
					case "-": f = x - y;
					case "<": r = CValue.Int((x < y) ? 1 : 0, 32, false); return true;
					case ">": r = CValue.Int((x > y) ? 1 : 0, 32, false); return true;
					case "<=": r = CValue.Int((x <= y) ? 1 : 0, 32, false); return true;
					case ">=": r = CValue.Int((x >= y) ? 1 : 0, 32, false); return true;
					case "==": r = CValue.Int((x == y) ? 1 : 0, 32, false); return true;
					case "!=": r = CValue.Int((x != y) ? 1 : 0, 32, false); return true;
					default: return false;
					}
					r = CValue.Float(f, (int32)w);
					return true;
				}
				if (op == "<<" || op == ">>")
				{
					let count = b.Unsigned ? b.Bits : (uint64)(int64)b.Bits;
					if ((int64)count < 0 || count >= (uint64)a.Width)
						return false;
					if (op == "<<")
						r = CValue.Int(a.Bits << (int)count, a.Width, a.Unsigned);
					else if (a.Unsigned)
						r = CValue.Int((a.Bits & (a.Width >= 64 ? ~0UL : ((1UL << a.Width) - 1))) >> (int)count, a.Width, true);
					else
						r = CValue.Int((uint64)((int64)a.Bits >> (int)count), a.Width, false);
					return true;
				}
				let w = Math.Max(a.Width, b.Width);
				let uns = (a.Unsigned && a.Width == w) || (b.Unsigned && b.Width == w);
				let x = CValue.Normalize(a.Bits, w, uns);
				let y = CValue.Normalize(b.Bits, w, uns);
				if (cmp)
				{
					bool t;
					if (uns)
					{
						let ux = (w >= 64) ? x : (x & ((1UL << w) - 1));
						let uy = (w >= 64) ? y : (y & ((1UL << w) - 1));
						switch (op)
						{
						case "<": t = ux < uy;
						case ">": t = ux > uy;
						case "<=": t = ux <= uy;
						case ">=": t = ux >= uy;
						case "==": t = ux == uy;
						default: t = ux != uy;
						}
					}
					else
					{
						let sx = (int64)x;
						let sy = (int64)y;
						switch (op)
						{
						case "<": t = sx < sy;
						case ">": t = sx > sy;
						case "<=": t = sx <= sy;
						case ">=": t = sx >= sy;
						case "==": t = sx == sy;
						default: t = sx != sy;
						}
					}
					r = CValue.Int(t ? 1 : 0, 32, false);
					return true;
				}
				uint64 res;
				switch (op)
				{
				case "*": res = x * y;
				case "+": res = x + y;
				case "-": res = x - y;
				case "&": res = x & y;
				case "|": res = x | y;
				case "^": res = x ^ y;
				case "/", "%":
					if (y == 0)
						return false;
					if (uns)
					{
						let ux = (w >= 64) ? x : (x & ((1UL << w) - 1));
						let uy = (w >= 64) ? y : (y & ((1UL << w) - 1));
						res = (op == "/") ? ux / uy : ux % uy;
					}
					else
					{
						let sx = (int64)x;
						let sy = (int64)y;
						if (sx == int64.MinValue && sy == -1)
							return false;
						res = (uint64)((op == "/") ? sx / sy : sx % sy);
					}
				default: return false;
				}
				r = CValue.Int(res, w, uns);
				return true;
			}

			/// `( type-name )` at the cursor: the cast's width / signedness. False (cursor kept)
			/// when the parentheses hold an expression.
			bool TryCast(out int32 width, out bool isUnsigned, out bool isFloat, out bool notConstant)
			{
				width = 32;
				isUnsigned = false;
				isFloat = false;
				notConstant = false;
				if (!Is("("))
					return false;
				int i = mPos + 1;
				int words = 0;
				bool sawUnsigned = false, sawSigned = false, sawChar = false, sawShort = false, sawFloat = false, sawDouble = false, sawBool = false;
				int longs = 0;
				(int32 width, bool isUnsigned, bool isFloat) typedefType = default;
				bool typedefSeen = false;
				while (i < mToks.Count)
				{
					let t = mToks[i];
					if (t.Kind == CXTokenKind.Keyword)
					{
						switch (t.Text)
						{
						case "unsigned": sawUnsigned = true;
						case "signed": sawSigned = true;
						case "int":
						case "long": longs++;
						case "short": sawShort = true;
						case "char": sawChar = true;
						case "float": sawFloat = true;
						case "double": sawDouble = true;
						case "_Bool", "bool": sawBool = true;
						case "const", "volatile":
						default: return false;
						}
						words++;
						i++;
						continue;
					}
					if (t.Kind == CXTokenKind.Identifier && words == 0 && mOwner.ArithTypedefs.TryGetAlt(t.Text, var matchedKey, out typedefType))
					{
						typedefSeen = true;
						words++;
						i++;
						continue;
					}
					break;
				}
				if (words == 0 || i >= mToks.Count || mToks[i].Kind != CXTokenKind.Punctuation)
					return false;
				if (mToks[i].Text == "*")
				{
					// a cast to a pointer: not a constant Treadle can hold
					notConstant = true;
					return false;
				}
				if (mToks[i].Text != ")")
					return false;
				if (typedefSeen)
				{
					width = typedefType.width;
					isUnsigned = typedefType.isUnsigned;
					isFloat = typedefType.isFloat;
				}
				else if (sawFloat || sawDouble)
				{
					isFloat = true;
					width = sawFloat ? 32 : 64;
				}
				else
				{
					width = sawBool ? 8 : sawChar ? 8 : sawShort ? 16 : (longs >= 2) ? 64 : 32;
					isUnsigned = sawUnsigned || sawBool;
					if (sawChar && !sawUnsigned && !sawSigned)
						isUnsigned = false;
				}
				mPos = i + 1;
				return true;
			}

			bool Unary(out CValue v)
			{
				v = default;
				if (mPos >= mToks.Count)
					return false;
				let t = mToks[mPos];
				if (t.Kind == CXTokenKind.Punctuation)
				{
					if (t.Text == "+" || t.Text == "-" || t.Text == "~" || t.Text == "!")
					{
						mPos++;
						if (!Unary(var a))
							return false;
						let p = Promote(a);
						switch (t.Text)
						{
						case "+": v = p;
						case "-":
							if (p.ValueKind == .Float)
								v = CValue.Float(-p.F, p.Width);
							else
								v = CValue.Int(0UL - p.Bits, p.Width, p.Unsigned);
						case "~":
							if (p.ValueKind == .Float)
								return false;
							v = CValue.Int(~p.Bits, p.Width, p.Unsigned);
						default:
							v = CValue.Int(p.IsTrue ? 0 : 1, 32, false);
						}
						return true;
					}
					if (TryCast(var width, var isUnsigned, var isFloat, var notConstant))
					{
						if (!Unary(var a))
							return false;
						if (isFloat)
							v = CValue.Float(a.AsDouble, width);
						else if (a.ValueKind == .Float)
							v = CValue.Int((uint64)(int64)a.F, width, isUnsigned);
						else
							v = CValue.Int(a.Bits, width, isUnsigned);
						return true;
					}
					if (notConstant)
						return false;
					if (t.Text == "(")
					{
						mPos++;
						if (!Expr(out v) || !Accept(")"))
							return false;
						return true;
					}
					return false;
				}
				mPos++;
				if (t.Kind == CXTokenKind.Literal)
				{
					if (t.Text.StartsWith('\''))
						return ParseChar(t.Text, out v);
					return ParseNumber(t.Text, out v);
				}
				if (t.Kind == CXTokenKind.Identifier)
				{
					if (mOwner.EnumConsts.TryGetAlt(t.Text, var matchedKey, var e))
					{
						v = (e >= int32.MinValue && e <= int32.MaxValue) ? CValue.Int((uint64)e, 32, false) : CValue.Int((uint64)e, 64, false);
						return true;
					}
					return mOwner.Value(t.Text, out v);
				}
				return false;
			}
		}
	}
}
