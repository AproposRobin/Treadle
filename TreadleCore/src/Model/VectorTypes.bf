using System;
using System.Collections;

namespace Treadle.Model
{
	/// The names of the vector primitives (docs/SIMD-and-Vectors.md 1.1): the element name followed by the
	/// lane count, with an `x` between them when the element name ends in a digit (`float4`, `double2`,
	/// `int32x4`, `uint8x16`, `bool4`). Elements: `float`, `double`, `int8` ... `int64`, `uint8` ... `uint64`,
	/// `bool` (a lane mask); lanes 2, 3, 4, 8, 16, 32, 64; a vector is at most 64 bytes, a 3-lane vector is
	/// stored as 4 lanes. `int` / `uint` are no elements (`int4` is T1090, "int32x4 or int64x4").
	/// `Vector<T,N>` is the reserved generic spelling of the same type: read, written short.
	///
	/// Only names: what a vector type means (layout, operations) is the compiler's.
	static class VectorTypes
	{
		public const int32 MaxBytes = 64;

		static StringView[11] sElements = .("float", "double", "int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "bool");
		static int32[11] sElementBytes = .(4, 8, 1, 2, 4, 8, 1, 2, 4, 8, 1);
		static int32[7] sLanes = .(2, 3, 4, 8, 16, 32, 64);

		/// The vector types the type picker and the Node menu list first (the rest are typed or searched).
		public static StringView[13] Common = .("float2", "float3", "float4", "double2", "double3", "double4", "int32x2", "int32x3", "int32x4",
			"uint8x16", "bool2", "bool3", "bool4");

		/// The size of one lane of `element` in bytes; 0 when it is no vector element.
		public static int32 ElementBytes(StringView element)
		{
			for (int i < sElements.Count)
				if (sElements[i] == element)
					return sElementBytes[i];
			return 0;
		}

		public static bool IsElement(StringView element) => ElementBytes(element) > 0;

		public static bool IsLaneCount(int lanes)
		{
			for (let l in sLanes)
				if (l == lanes)
					return true;
			return false;
		}

		/// Lanes in memory: a 3-lane vector takes 4.
		public static int32 StoredLanes(int lanes) => (lanes == 3) ? 4 : (int32)lanes;

		/// Bytes of a vector of `lanes` x `element` (0 for an unknown element).
		public static int32 Bytes(StringView element, int lanes) => ElementBytes(element) * StoredLanes(lanes);

		/// Whether `element` x `lanes` is a vector type of the language.
		public static bool Exists(StringView element, int lanes)
		{
			let b = Bytes(element, lanes);
			return b > 0 && IsLaneCount(lanes) && b <= MaxBytes;
		}

		/// The short spelling: `float` 4 -> `float4`, `int32` 4 -> `int32x4`.
		public static void Spell(StringView element, int lanes, String outName)
		{
			outName.Append(element);
			if (!element.IsEmpty && element[element.Length - 1].IsDigit)
				outName.Append('x');
			outName.AppendF("{}", lanes);
		}

		/// The scalar types whose names look like a vector spelling (`int32`, `uint8`).
		static bool IsScalarName(StringView name)
		{
			for (let s in StringView[?]("int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "char8", "char16", "char32"))
				if (name == s)
					return true;
			return false;
		}

		/// Splits a name by the spelling rule without checking that the type exists: `int32x4` -> (`int32`,
		/// 4), `float16` -> (`float`, 16), `int4` -> (`int`, 4). False for a name that does not have the shape
		/// (a scalar such as `int32`, a name without trailing digits).
		public static bool SplitName(StringView name, out StringView element, out int32 lanes)
		{
			element = default;
			lanes = 0;
			if (name.IsEmpty || IsScalarName(name) || name.Contains('.') || name.Contains('<'))
				return false;
			int end = name.Length;
			int start = end;
			while (start > 0 && name[start - 1].IsDigit)
				start--;
			if (start == end || start == 0 || end - start > 3)
				return false;
			if (!(int32.Parse(name.Substring(start)) case .Ok(out lanes)))
				return false;
			var head = name.Substring(0, start);
			if (head.EndsWith('x') && head.Length > 1 && head[head.Length - 2].IsDigit)
				head = head.Substring(0, head.Length - 1);
			else if (head[head.Length - 1].IsDigit)
				return false;
			for (let c in head.RawChars)
				if (!c.IsLetterOrDigit)
					return false;
			element = head;
			return true;
		}

		/// A vector spelling of an existing type: the element and the lane count. The spelling must be the
		/// canonical one (`int32x4`, not `int324`; `float4`, not `floatx4`).
		public static bool TryParse(StringView name, out StringView element, out int32 lanes)
		{
			if (!SplitName(name, out element, out lanes) || !Exists(element, lanes))
				return false;
			String canon = scope .();
			Spell(element, lanes, canon);
			return canon == name;
		}

		public static bool IsVectorName(StringView name) => TryParse(name, ?, ?);

		/// The short name of `Vector<T,N>` (spaces allowed after the comma) into `outName`; false when the
		/// text is not that form or names no vector type.
		public static bool LongForm(StringView text, String outName)
		{
			var t = text;
			t.Trim();
			if (t.StartsWith("Core."))
				t = t.Substring(5);
			if (!t.StartsWith("Vector<") || !t.EndsWith('>'))
				return false;
			let inner = t.Substring(7, t.Length - 8);
			let comma = inner.IndexOf(',');
			if (comma < 0)
				return false;
			var e = inner.Substring(0, comma);
			var n = inner.Substring(comma + 1);
			e.Trim();
			n.Trim();
			if (!(int32.Parse(n) case .Ok(let lanes)) || !Exists(e, lanes))
				return false;
			Spell(e, lanes, outName);
			return true;
		}

		/// The vector a type text names, short or long (`float4`, `Vector<float,4>`), as its short name;
		/// false for any other type.
		public static bool Canonical(StringView text, String outName)
		{
			var t = text;
			t.Trim();
			if (TryParse(t, ?, ?))
			{
				outName.Append(t);
				return true;
			}
			return LongForm(t, outName);
		}

		/// The element and lane count of a vector type text (short or long form).
		public static bool Info(StringView text, String outElement, out int32 lanes)
		{
			lanes = 0;
			String name = scope .();
			if (!Canonical(text, name))
				return false;
			if (!TryParse(name, let e, out lanes))
				return false;
			outElement.Append(e);
			return true;
		}

		/// Lane count of a vector type text; 0 for any other type.
		public static int32 LanesOf(StringView text)
		{
			String e = scope .();
			return Info(text, e, let lanes) ? lanes : 0;
		}

		/// T1090 for a name that has the vector shape but names no vector type: `int4` (no `int` element),
		/// `double16` (over 64 bytes), `float5` (no 5-lane vectors). True (nothing to say) for every other
		/// name, a vector or not.
		public static bool Check(StringView name, String outWhy)
		{
			String reason = scope .();
			if (Classify(name, reason) != .Invalid)
				return true;
			outWhy.AppendF("T1090: '{}' is not a vector type: {}", name, reason);
			return false;
		}

		/// What a name is as a vector spelling.
		public enum Shape
		{
			/// Not shaped like a vector name (an ordinary type name).
			NotVector,
			/// A vector type.
			Vector,
			/// Shaped like one, but no such vector exists (`int4`, `double16`, `float5`): T1090.
			Invalid
		}

		/// `name` as a vector spelling; for an Invalid one `outReason` gets why (the T1090 message without
		/// the code and the name). The compiler, the back end and the C importer share this.
		public static Shape Classify(StringView name, String outReason = null)
		{
			if (TryParse(name, ?, ?))
				return .Vector;
			if (!SplitName(name, let element, let lanes) || Exists(element, lanes))
				return .NotVector; // a non-canonical spelling of an existing vector (`floatx4`): an ordinary name
			if (element == "int" || element == "uint")
			{
				String a = scope .();
				String b = scope .();
				Spell(scope $"{element}32", lanes, a);
				Spell(scope $"{element}64", lanes, b);
				outReason?.AppendF("{} or {} (an {} is 64-bit, so the lane size is written)", a, b, element);
				return .Invalid;
			}
			if (!IsElement(element))
				return .NotVector; // `Vec3`, `Player2`: an ordinary name
			if (!IsLaneCount(lanes))
				outReason?.Append("a vector has 2, 3, 4, 8, 16, 32 or 64 lanes");
			else
				outReason?.AppendF("it would be {} bytes, a vector is at most {}", Bytes(element, lanes), MaxBytes);
			return .Invalid;
		}

		/// `float4 (4 x float, 16 bytes)`; a 3-lane vector names its stored size.
		public static void Describe(StringView text, String outText)
		{
			String e = scope .();
			if (!Info(text, e, let lanes))
			{
				outText.Append(text);
				return;
			}
			Spell(e, lanes, outText);
			outText.AppendF(" ({} x {}, {} bytes)", lanes, e, Bytes(e, lanes));
		}

		/// The mask type of a vector (`bool4` for `float4`, `int32x4`).
		public static void MaskOf(int lanes, String outName) => Spell("bool", lanes, outName);

		/// The name of lane `i` of an `lanes`-lane vector as Make / Break pins carry it: `x y z w` up to 4
		/// lanes, `lane0 ... laneN-1` above.
		public static void LaneName(int lanes, int i, String outName)
		{
			if (lanes <= 4 && i < 4)
				outName.Append("xyzw"[i]);
			else
				outName.AppendF("lane{}", i);
		}

		/// Every vector type, element by element (the full list for searches).
		public static void All(List<String> outNames)
		{
			for (let e in sElements)
				for (let l in sLanes)
					if (Exists(e, l))
						Spell(e, l, outNames.Add(.. new String()));
		}
	}
}
