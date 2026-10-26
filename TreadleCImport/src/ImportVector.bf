using System;
using Treadle.Model;

namespace Treadle.CImport
{
	/// C vector types (docs/SIMD-and-Vectors.md 1.6, C import): `CXType_Vector` (`__m128`, `__m128d`,
	/// `__m128i`, `__m256`, `__attribute__((vector_size(N)))`) and `CXType_ExtVector`
	/// (`ext_vector_type(3)`) map by their declared lane type and count to the Treadle vector of that
	/// shape: `__m128` -> float4, `__m128d` -> double2, `__m128i` -> int64x2, `__m256` -> float8,
	/// `__m256i` -> int64x4, `__m512` -> float16. A shape Treadle has no name for is skipped (the
	/// declaration that uses it is left out with the reason, as for any type it cannot spell).
	extension SetImporter
	{
		bool MapVector(CXType t0, String outText, String outWhy)
		{
			var t = t0;
			CXType elem = default;
			LibClang.getElementType(&elem, &t);
			let lanes = LibClang.getNumElements(&t);
			String e = scope .();
			String why = scope .();
			if (!MapType(elem, .Field, e, why))
			{
				outWhy.AppendF("is a vector of a lane type Treadle has no type for ({})", why);
				return false;
			}
			// a `char` lane is a byte (int8): Treadle's char8 is a UTF-8 code unit, no vector lane
			if (e == "char8")
				e.Set("int8");
			String name = scope .();
			VectorTypes.Spell(e, (int)lanes, name);
			if (!VectorTypes.TryParse(name, ?, ?))
			{
				outWhy.AppendF("is a vector of {} x {}, which Treadle has no vector type for", lanes, e);
				return false;
			}
			// a 3-lane Treadle vector takes the room of 4; a C vector of 3 lanes without that padding
			// (`vector_size(6)` of short) has another layout
			if (SizeOf(t0) != VectorTypes.Bytes(e, (int)lanes))
			{
				outWhy.AppendF("is a vector of {} x {} in {} bytes; Treadle's {} takes {}", lanes, e, SizeOf(t0), name, VectorTypes.Bytes(e, (int)lanes));
				return false;
			}
			outText.Append(name);
			return true;
		}
	}
}
