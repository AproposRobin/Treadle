using System;
using System.Collections;
using Treadle.Language;

namespace Treadle.Graph
{
	/// Which control an unwired input pin shows for its value, by the pin's type.
	enum PinValueKind : uint8
	{
		/// Nothing to type: wire it (or construct a value).
		None,
		/// A type that is not known: plain expression text.
		Expr,
		Bool,
		/// A dropdown of the enum's members.
		Enum,
		/// A plain text field.
		Text,
		/// A numeric field that refuses what the type cannot hold.
		Number,
		/// A one-character field.
		Char,
		/// The pin's current value is not a plain literal of its type: shown read-only with a badge,
		/// edited as text in Properties.
		Custom,
		/// A vector (`float4`): one number field per lane up to 4 lanes (`x y z w`), one splat field above;
		/// stored as one token, `0,1,0,0` (a single number splats, `true,false,...` for a mask).
		Vector
	}

	/// The typed value rules of an unwired input pin, one place for the node canvas and the
	/// Properties panel. What a value *means* is the language's: every question goes to
	/// `ITypeSystem` (a seam); the shell only chooses the control from the answer. Without a type
	/// system every pin is expression text.
	static class PinValue
	{
		/// The control for a pin of `typeName` holding `def` (its value text).
		public static PinValueKind KindOf(StringView typeName, StringView def, StringView pinName, ITypeSystem types)
		{
			if (types == null)
				return .Expr;
			var tn = typeName;
			tn.Trim();
			if (tn.IsEmpty)
				return .Expr;
			// A vector's lanes (SIMD-and-Vectors.md 1.9), decided by its name: the type system may not know
			// the vector types yet. A value that is not a lane list (an expression) shows read-only.
			if (Treadle.Model.VectorTypes.LanesOf(tn) > 0)
				return (def.IsEmpty || def == "default" || SplitLanes(tn, def, null)) ? .Vector : .Custom;
			return types.ValueKind(tn, def, pinName);
		}

		/// The lanes of a vector literal (`0,1,0,0`; one value splats to every lane) into `outLanes` (may be
		/// null: only checked). False when it is not a literal of `vectorType`: a lane count other than 1 or
		/// N, a lane that is no number (no true / false for a mask), spaces.
		public static bool SplitLanes(StringView vectorType, StringView literal, List<String> outLanes)
		{
			String e = scope .();
			if (!Treadle.Model.VectorTypes.Info(vectorType, e, let n))
				return false;
			var t = literal;
			t.Trim();
			if (t.IsEmpty || t.Contains(' '))
				return false;
			int count = 0;
			for (var part in t.Split(','))
			{
				let ok = (e == "bool") ? (part == "true" || part == "false") : LooksNumeric(part);
				if (!ok)
					return false;
				count++;
			}
			if (count != 1 && count != n)
				return false;
			if (outLanes != null)
				for (int i < n)
				{
					int k = 0;
					for (var part in t.Split(','))
						if (count == 1 || k++ == i)
						{
							outLanes.Add(new String(part));
							break;
						}
				}
			return true;
		}

		/// Joins lane values into a vector literal: one value when all lanes are the same (a splat).
		public static void JoinLanes(List<String> lanes, String outLiteral)
		{
			bool same = true;
			for (let l in lanes)
				if (l != lanes[0])
					same = false;
			if (same && !lanes.IsEmpty)
			{
				outLiteral.Append(lanes[0]);
				return;
			}
			for (let l in lanes)
			{
				if (@l.Index > 0)
					outLiteral.Append(',');
				outLiteral.Append(l);
			}
		}

		/// The text the control shows for a stored value: a text literal without its quotes, a
		/// character without its apostrophes, an enum member without its leading dot; anything
		/// else as it is stored.
		public static void Display(PinValueKind kind, StringView typeName, StringView def, String outText)
		{
			switch (kind)
			{
			case .Text:
				if (Treadle.Format.RecordText.IsString(def))
				{
					Treadle.Format.RecordText.Unquote(def, outText);
					return;
				}
			case .Char:
				if (def.Length >= 3 && def.StartsWith('\'') && def.EndsWith('\''))
				{
					outText.Append(def.Substring(1, def.Length - 2));
					return;
				}
			case .Enum:
				if (def.StartsWith('.'))
				{
					outText.Append(def.Substring(1));
					return;
				}
			default:
			}
			outText.Append(def);
		}

		/// Turns what was typed into the stored value text (the format's literal token: a text
		/// is quoted, a character gets its apostrophes). `why` says why a value was refused.
		public static bool Write(PinValueKind kind, StringView typeName, StringView typed, bool optional, String outLiteral, String why)
		{
			var t = typed;
			if (kind != .Text)
				t.Trim();
			if (kind == .Text)
			{
				Treadle.Format.RecordText.Quote(t, outLiteral);
				return true;
			}
			if (t.IsEmpty)
			{
				if (!optional)
				{
					why?.Set("A value is needed.");
					return false;
				}
				return true;
			}
			if (kind == .Char)
			{
				var c = t;
				if (c.Length >= 3 && c.StartsWith('\'') && c.EndsWith('\''))
					c = c.Substring(1, c.Length - 2);
				if (c.Length != 1 && !(c.Length == 2 && c[0] == '\\'))
				{
					why?.Set(scope $"'{t}' is not one character.");
					return false;
				}
				outLiteral.AppendF("'{}'", c);
				return true;
			}
			if (kind == .Number && !LooksNumeric(t))
			{
				why?.Set(scope $"'{t}' is not a number.");
				return false;
			}
			if (kind == .Bool && t != "true" && t != "false")
			{
				why?.Set("A bool is true or false.");
				return false;
			}
			if (kind == .Vector && t != "default")
			{
				// `1, 2, 3, 4` as typed is `1,2,3,4` (the format's one token).
				String packed = scope .();
				for (let c in t.RawChars)
					if (c != ' ')
						packed.Append(c);
				if (!SplitLanes(typeName, packed, null))
				{
					let lanes = Treadle.Model.VectorTypes.LanesOf(typeName);
					why?.Set(scope $"'{t}' is not a {typeName}: {lanes} numbers separated by commas, or one for every lane.");
					return false;
				}
				outLiteral.Append(packed);
				return true;
			}
			outLiteral.Append(t);
			return true;
		}

		static bool LooksNumeric(StringView t)
		{
			int i = 0;
			if (i < t.Length && (t[i] == '-' || t[i] == '+'))
				i++;
			bool digits = false;
			bool dot = false;
			for (; i < t.Length; i++)
			{
				let c = t[i];
				if (c.IsDigit)
					digits = true;
				else if (c == '.' && !dot)
					dot = true;
				else if ((c == 'f' || c == 'F' || c == 'd' || c == 'D') && i == t.Length - 1)
					continue;
				else if ((c == 'e' || c == 'E') && digits && i + 1 < t.Length)
					continue;
				else
					return false;
			}
			return digits;
		}

		/// The members of an enum type (for the dropdown).
		public static void Members(StringView typeName, ITypeSystem types, List<String> outMembers)
		{
			if (types != null)
				types.EnumMembers(typeName, outMembers);
		}
	}
}
