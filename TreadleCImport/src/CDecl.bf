using System;
using System.Collections;

namespace Treadle.CImport
{
	// What one import set produces: the declarations the `.cdecl` file holds (docs/C-Import.md).
	// Every type is already a Treadle TypeRef in text form (`int32`, `char8*`, `SDL_Rect`,
	// `function:int32(void*,void*)`, `uint8[16]`).

	class CParam
	{
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
	}

	class CFunction
	{
		public String Name = new .() ~ delete _;
		/// null = void.
		public String Returns ~ delete _;
		public List<CParam> Params = new .() ~ DeleteContainerAndItems!(_);
		public bool Variadic;
		/// null = the C convention.
		public String CallConv ~ delete _;
	}

	class CField
	{
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public int64 Offset;
	}

	class CRecord
	{
		public String Name = new .() ~ delete _;
		public bool IsUnion;
		/// Declared but never defined: only pointers to it are usable.
		public bool Opaque;
		public int64 Size;
		public int64 Align;
		/// The packing (`#pragma pack`, `packed`) when the record is aligned below its fields; 0 = natural.
		public int64 Pack;
		public List<CField> Fields = new .() ~ DeleteContainerAndItems!(_);
	}

	class CEnum
	{
		public String Name = new .() ~ delete _;
		public String Underlying = new .() ~ delete _;
		public List<(String name, String value)> Values = new .() ~ { for (let v in _) { delete v.name; delete v.value; } delete _; };
	}

	class CTypedef
	{
		public String Name = new .() ~ delete _;
		public String Target = new .() ~ delete _;
		/// A function pointer typedef's convention when it is not the C one.
		public String CallConv ~ delete _;
	}

	/// A constant: an object-like macro with a literal or constant-expression value, or a constant
	/// of an anonymous enum.
	class CConst
	{
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		/// The value as a format token: a decimal integer, a float, or a quoted string.
		public String Value = new .() ~ delete _;
	}

	/// An extern variable (`extern int x;`), or an object-like macro that reads one through a
	/// function (`#define errno (*_errno())`, `#define stdout (__acrt_iob_func(1))`): then Via
	/// names the function, Arg its one integer argument (empty: none) and Deref whether the
	/// function gives the variable's address (`*f()`, which can be set too) or its value.
	class CVar
	{
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public String Via = new .() ~ delete _;
		public String Arg = new .() ~ delete _;
		public bool Deref;
	}

	/// The result of importing one set: the declarations, the warnings (each names the header
	/// and line of what was skipped or changed) and timings.
	class CDeclSet
	{
		public String Name = new .() ~ delete _;
		/// The `.cimport` file name (no folder), for the doc line.
		public String SourceFile = new .() ~ delete _;
		public List<CFunction> Functions = new .() ~ DeleteContainerAndItems!(_);
		public List<CRecord> Records = new .() ~ DeleteContainerAndItems!(_);
		public List<CEnum> Enums = new .() ~ DeleteContainerAndItems!(_);
		public List<CTypedef> Typedefs = new .() ~ DeleteContainerAndItems!(_);
		public List<CConst> Consts = new .() ~ DeleteContainerAndItems!(_);
		public List<CVar> Vars = new .() ~ DeleteContainerAndItems!(_);
		public List<String> Warnings = new .() ~ DeleteContainerAndItems!(_);
		/// Error diagnostics of the parse (the set is not written when there is one).
		public List<String> Errors = new .() ~ DeleteContainerAndItems!(_);
		public double ParseMs;
		public double WalkMs;

		public CFunction FindFunction(StringView name)
		{
			for (let f in Functions)
				if (f.Name == name)
					return f;
			return null;
		}

		public CRecord FindRecord(StringView name)
		{
			for (let r in Records)
				if (r.Name == name)
					return r;
			return null;
		}

		public CTypedef FindTypedef(StringView name)
		{
			for (let t in Typedefs)
				if (t.Name == name)
					return t;
			return null;
		}

		public CConst FindConst(StringView name)
		{
			for (let c in Consts)
				if (c.Name == name)
					return c;
			return null;
		}

		public CEnum FindEnum(StringView name)
		{
			for (let e in Enums)
				if (e.Name == name)
					return e;
			return null;
		}

		/// `12 functions, 3 records, ...` for summaries.
		public void Counts(String outText)
		{
			outText.AppendF("{} functions, {} structs/unions, {} enums, {} typedefs, {} constants, {} variables, {} warnings",
				Functions.Count, Records.Count, Enums.Count, Typedefs.Count, Consts.Count, Vars.Count, Warnings.Count);
		}
	}
}
