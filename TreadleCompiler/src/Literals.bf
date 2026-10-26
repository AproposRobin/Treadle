using System;
using Treadle.Format;

namespace Treadle.Compiler
{
	enum LitKind : uint8
	{
		None,
		Int,
		Float,
		Bool,
		String,
		Null,
		Default,
		/// `.Case`: an enum case of the pin's type.
		Case,
		Char,
		/// A token that is no literal of the language.
		Bad
	}

	/// The literal tokens of `in <pin> <token>` lines and Literal nodes (Graph-Format.md 3.1):
	/// numbers, `true` / `false`, strings, `null`, `default`, `.Case`, `'c'`.
	static class Literals
	{
		/// A hexadecimal integer token (`0xFF`, `-0x10`) as the decimal the back end reads
		/// (Graph-Format.md keeps the spelling; the Sheet IR has decimal numbers only). False and
		/// nothing written for any other token. Up to 16 digits; past int64 the bits are kept
		/// (`0xFFFFFFFFFFFFFFFF` is 18446744073709551615 on an unsigned type, -1 on a signed one).
		public static bool HexToDecimal(StringView tok, bool unsignedType, String outText)
		{
			StringView t = tok;
			bool neg = t.StartsWith('-');
			if (neg)
				t = t.Substring(1);
			if (!(t.StartsWith("0x") || t.StartsWith("0X")) || t.Length < 3 || t.Length > 18)
				return false;
			uint64 v = 0;
			for (let c in t.Substring(2).RawChars)
			{
				int d = c.IsDigit ? c - '0' : ((c >= 'a' && c <= 'f') ? c - 'a' + 10 : ((c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1));
				if (d < 0)
					return false;
				v = v * 16 + (uint64)d;
			}
			if (neg)
				outText.AppendF("{}", -(int64)v);
			else if (unsignedType)
				outText.AppendF("{}", v);
			else
				outText.AppendF("{}", (int64)v);
			return true;
		}

		public static LitKind Classify(StringView tok, out int64 i, out double f)
		{
			i = 0;
			f = 0;
			if (tok.IsEmpty)
				return .None;
			if (tok == "true" || tok == "false")
				return .Bool;
			if (tok == "null")
				return .Null;
			if (tok == "default")
				return .Default;
			if (tok.StartsWith('"'))
				return RecordText.IsString(tok) ? .String : .Bad;
			if (tok.StartsWith('\''))
				return (tok.Length >= 3 && tok.EndsWith('\'')) ? .Char : .Bad;
			if (tok.StartsWith('.') && tok.Length > 1 && (tok[1].IsLetter || tok[1] == '_'))
				return .Case;
			StringView t = tok;
			bool neg = false;
			if (t.StartsWith('-'))
			{
				neg = true;
				t = t.Substring(1);
			}
			if (t.StartsWith("0x") || t.StartsWith("0X"))
			{
				if (int64.Parse(t.Substring(2), .HexNumber) case .Ok(let v))
				{
					i = neg ? -v : v;
					return .Int;
				}
				return .Bad;
			}
			bool digits = !t.IsEmpty;
			bool dot = false;
			for (let c in t.RawChars)
			{
				if (c == '.' || c == 'e' || c == 'E' || c == 'f' || c == 'F' || c == 'd' || c == 'D' || c == '+' || c == '-')
					dot = true;
				else if (!c.IsDigit)
					digits = false;
			}
			if (!digits || t.IsEmpty || !t[0].IsDigit)
				return .Bad;
			if (!dot)
			{
				if (int64.Parse(tok) case .Ok(let v))
				{
					i = v;
					return .Int;
				}
				return .Bad;
			}
			StringView ft = tok;
			if (ft.EndsWith('f') || ft.EndsWith('F') || ft.EndsWith('d') || ft.EndsWith('D'))
				ft = ft.Substring(0, ft.Length - 1);
			if (double.Parse(ft) case .Ok(let v))
			{
				f = v;
				return .Float;
			}
			return .Bad;
		}

		/// The type a literal has on its own (no pin type to adapt to), or null.
		public static KType TypeOf(StringView tok, TypeTable table)
		{
			switch (Classify(tok, var i, var f))
			{
			case .Int: return table.Int;
			case .Float: return (tok.EndsWith('f') || tok.EndsWith('F')) ? table.Float : table.Double;
			case .Bool: return table.Bool;
			case .String: return (table.StringSym != null) ? table.StringSym.Self : table.Error;
			case .Null: return table.Null;
			case .Char: return table.Char8;
			default: return null;
			}
		}

		/// Whether the literal can stand for a value of `t`; `why` says why not.
		public static bool Fits(StringView tok, KType t, TypeTable table, String why)
		{
			if (t == null || t.IsError)
				return true;
			if (t.IsVector)
				return VectorRules.LiteralFits(tok, t, table, why); // `0,1,0,0`, or one value that splats
			let kind = Classify(tok, var i, var f);
			KType target = t;
			if (t.Kind == .Nullable && kind != .Null && kind != .Default)
				target = t.Element;
			switch (kind)
			{
			case .None:
				return true;
			case .Bad:
				why.AppendF("{} is not a literal (a number, true / false, a \"string\", null, default or .Case)", tok);
				return false;
			case .Default:
				return true;
			case .Null:
				if (t.IsReference || t.Kind == .Pointer || t.Kind == .Nullable || t.Kind == .Function)
					return true;
				why.AppendF("null is not {}: it is a value type", TypeTable.WithArticle(t, .. scope .()));
				return false;
			case .Bool:
				if (target.Kind == .Bool)
					return true;
			case .Int:
				if (target.Kind == .Int)
				{
					if (FitsBits(i, target.Bits, target.Signed))
						return true;
					why.AppendF("{} does not fit in {}", tok, target.Name);
					return false;
				}
				if (target.Kind == .Float)
					return true;
				if (target.Kind == .Char && i >= 0 && FitsBits(i, target.Bits, false))
					return true;
			case .Float:
				if (target.Kind == .Float)
					return true;
			case .String:
				if (target.Kind == .Named && (target.Sym == table.StringSym || target.Sym == table.StringViewSym))
					return true;
				if (target.Kind == .Pointer && target.Element.Kind == .Char && target.Element.Bits == 8)
					return true;
			case .Char:
				if (target.Kind == .Char)
					return true;
			case .Case:
				if (target.IsEnum)
				{
					let c = target.Sym.FindCase(tok.Substring(1));
					if (c == null)
					{
						why.AppendF("{} has no case {}", TypeTable.Show(target, .. scope .()), tok.Substring(1));
						return false;
					}
					if (!c.Payload.IsEmpty)
					{
						why.AppendF("{} carries values: use a Make Case node", tok.Substring(1));
						return false;
					}
					return true;
				}
			}
			why.AppendF("{} is not {}", tok, TypeTable.WithArticle(t, .. scope .()));
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
	}
}
