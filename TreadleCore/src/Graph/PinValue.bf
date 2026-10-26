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
		Vector,
		/// A core math struct (`Vec2` / `Vec3` / `Vec4` and the double forms, `Quat`, `Color`, `Color32`, `Rect`,
		/// `RectI`; `PinValue.MathInfo`): one number field per field (`x y z w`, `r g b a`, `x y w h`), a colour
		/// swatch with a picker in front for `Color` / `Color32`; stored as one token, one value per field in
		/// declaration order, `1,2,3` (a struct literal, Graph-Format.md 2).
		Fields
	}

	/// The number type of a core math struct's fields (`PinValue.MathInfo`).
	enum MathFieldKind : uint8
	{
		Float,
		Double,
		Int,
		/// 0 to 255 (`Color32`).
		Byte
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

		/// The core math struct `typeName` names (`Core.Vec3`, or `Vec3` as a pin may spell it; the type
		/// system decides whether the short name is the core one, `MathValueKind`): its field count, one hint
		/// letter per field (`xyzw`, `rgba`, `xywh`) and the fields' number type. False for any other type.
		public static bool MathInfo(StringView typeName, out int count, out StringView hints, out MathFieldKind kind)
		{
			var n = typeName;
			n.Trim();
			if (n.StartsWith("Core."))
				n.RemoveFromStart(5);
			count = 0;
			hints = default;
			kind = .Float;
			switch (n)
			{
			case "Vec2": count = 2; hints = "xy";
			case "Vec3": count = 3; hints = "xyz";
			case "Vec4", "Quat": count = 4; hints = "xyzw";
			case "Vec2d": count = 2; hints = "xy"; kind = .Double;
			case "Vec3d": count = 3; hints = "xyz"; kind = .Double;
			case "Vec4d": count = 4; hints = "xyzw"; kind = .Double;
			case "Color": count = 4; hints = "rgba";
			case "Color32": count = 4; hints = "rgba"; kind = .Byte;
			case "Rect": count = 4; hints = "xywh";
			case "RectI": count = 4; hints = "xywh"; kind = .Int;
			default: return false;
			}
			return true;
		}

		/// Whether `typeName` is `Color` or `Color32` (the swatch and the picker).
		public static bool IsColor(StringView typeName) => MathInfo(typeName, ?, let hints, ?) && hints == "rgba";

		/// For a type system that resolved a pin's type to `fullName`: `.Fields` for a core math struct holding
		/// nothing, `default` or a literal of it; `.Custom` for one holding anything else; `.None` for any other
		/// type (the caller decides). A Receiver (`receiver`) takes a wire, not a literal: `.None`.
		public static PinValueKind MathValueKind(StringView fullName, StringView current, StringView pinName)
		{
			if (!fullName.StartsWith("Core.") || !MathInfo(fullName, ?, ?, ?) || pinName == "receiver")
				return .None;
			return (current.IsEmpty || current == "default" || SplitFields(fullName, current, null)) ? .Fields : .Custom;
		}

		/// The field values of a core math struct literal (`1,2,3`; one value per field, integers for `Color32`
		/// and `RectI`, 0 to 255 for `Color32`) into `outFields` (may be null: only checked). An empty value or
		/// `default` gives zeros.
		public static bool SplitFields(StringView typeName, StringView literal, List<String> outFields)
		{
			if (!MathInfo(typeName, let count, ?, let kind))
				return false;
			var t = literal;
			t.Trim();
			if (t.IsEmpty || t == "default")
			{
				if (outFields != null)
					for (int i < count)
						outFields.Add(new String("0"));
				return true;
			}
			if (t.Contains(' '))
				return false;
			int k = 0;
			for (var part in t.Split(','))
			{
				if (!LooksNumeric(part))
					return false;
				if (kind == .Int || kind == .Byte)
				{
					if (!(int64.Parse(part) case .Ok(let v)) || (kind == .Byte && (v < 0 || v > 255)))
						return false;
				}
				k++;
			}
			if (k != count)
				return false;
			if (outFields != null)
				for (var part in t.Split(','))
					outFields.Add(new String(part));
			return true;
		}

		/// Joins field values into a struct literal: every field, in order (`1,0,0`).
		public static void JoinFields(List<String> fields, String outLiteral)
		{
			for (let f in fields)
			{
				if (@f.Index > 0)
					outLiteral.Append(',');
				outLiteral.Append(f);
			}
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
			if (kind == .Number && IntegerBounds(typeName, let lo, let hi))
			{
				// An integer type takes a whole number in its range.
				var digits = t;
				if (digits.StartsWith('+'))
					digits = digits.Substring(1);
				bool neg = digits.StartsWith('-');
				bool whole = !digits.IsEmpty;
				for (int i = neg ? 1 : 0; i < digits.Length; i++)
					whole &= digits[i].IsDigit;
				if (!whole || (neg && digits.Length == 1))
				{
					why?.Set(scope $"'{t}' is not a whole number: a {typeName} holds whole numbers from {lo} to {hi}.");
					return false;
				}
				bool fits;
				if (neg)
					fits = (int64.Parse(digits) case .Ok(let v)) && lo != "0" && v >= int64.Parse(lo).GetValueOrDefault();
				else
					fits = (uint64.Parse(digits) case .Ok(let v)) && v <= uint64.Parse(hi).GetValueOrDefault();
				if (!fits)
				{
					why?.Set(scope $"'{t}' is out of range: a {typeName} holds {lo} to {hi}.");
					return false;
				}
				outLiteral.Append(digits);
				return true;
			}
			if (kind == .Bool && t != "true" && t != "false")
			{
				why?.Set("A bool is true or false.");
				return false;
			}
			if (kind == .Fields && t != "default")
			{
				// `1, 2, 3` as typed is `1,2,3` (the format's one token).
				String packed = scope .();
				for (let c in t.RawChars)
					if (c != ' ')
						packed.Append(c);
				if (!SplitFields(typeName, packed, null))
				{
					MathInfo(typeName, let count, ?, let mk);
					why?.Set(scope $"'{t}' is not a {typeName}: {count} {(mk == .Byte) ? "numbers from 0 to 255" : ((mk == .Int) ? "whole numbers" : "numbers")} separated by commas.");
					return false;
				}
				outLiteral.Append(packed);
				return true;
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

		/// The range of an integer type as text (`int8`: -128 to 127); false for any other type.
		public static bool IntegerBounds(StringView typeName, out StringView lo, out StringView hi)
		{
			switch (typeName)
			{
			case "int8": lo = "-128"; hi = "127";
			case "int16": lo = "-32768"; hi = "32767";
			case "int32": lo = "-2147483648"; hi = "2147483647";
			case "int", "int64": lo = "-9223372036854775808"; hi = "9223372036854775807";
			case "uint8": lo = "0"; hi = "255";
			case "uint16": lo = "0"; hi = "65535";
			case "uint32": lo = "0"; hi = "4294967295";
			case "uint", "uint64": lo = "0"; hi = "18446744073709551615";
			default:
				lo = default;
				hi = default;
				return false;
			}
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
