using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	/// The shapes of a semantic type (Language.md 2.1).
	enum KTypeKind : uint8
	{
		/// A type that could not be resolved: it converts to and from everything, so one bad
		/// name gives one diagnostic, not a cascade.
		Error,
		Void,
		/// The type of the `null` literal.
		Null,
		Bool,
		Int,
		Float,
		Char,
		/// A declared type (class, struct, interface, enum, delegate), maybe with generic arguments.
		Named,
		/// A generic parameter (`T`).
		Param,
		/// `T[]`: an array object.
		Array,
		/// `T[N]`: a value array.
		FixedArray,
		/// `T?`
		Nullable,
		/// `T*`
		Pointer,
		/// `(A,B)`
		Tuple,
		/// `function:R(A,B)`: a raw function pointer.
		Function,
		/// `delegate:R(A,B)`: a delegate object.
		Delegate,
		/// A vector primitive (`float4`, `int32x4`, `bool4`; SIMD-and-Vectors.md 1): Element the lane type,
		/// Length the lane count (VectorRules.bf).
		Vector
	}

	/// A semantic type. Types are interned by the TypeTable: two KTypes are the same type exactly
	/// when they are the same object.
	class KType
	{
		public KTypeKind Kind;
		/// The identity text (unique per type).
		public String Key = new .() ~ delete _;
		/// The format's spelling with full names (`Core.Pair<int,float>`, `int[]`, `TFirst`).
		public String Name = new .() ~ delete _;
		/// Int / Float / Char: the width.
		public int32 Bits;
		/// Int: signed.
		public bool Signed;
		/// Primitives: the keyword (`int`, `uint8`, `double`).
		public String Prim ~ delete _;
		/// Named: the declaration.
		public TypeSym Sym;
		/// Named: generic arguments. Tuple: elements. Function / Delegate: parameter types. Not owned.
		public List<KType> Args = new .() ~ delete _;
		/// Array / FixedArray / Nullable / Pointer: the element. Function / Delegate: the return type.
		public KType Element;
		/// FixedArray: the length.
		public int64 Length;
		/// Param: the parameter.
		public GenericParamSym Param;

		public bool IsError => Kind == .Error;
		public bool IsVoid => Kind == .Void;
		public bool IsNumeric => Kind == .Int || Kind == .Float;
		public bool IsInteger => Kind == .Int;
		public bool IsNamed => Kind == .Named;
		public bool IsClass => Kind == .Named && Sym.Kind == .Class;
		public bool IsStruct => Kind == .Named && Sym.Kind == .Struct;
		public bool IsInterface => Kind == .Named && Sym.Kind == .Interface;
		public bool IsEnum => Kind == .Named && Sym.Kind == .Enum;
		public bool IsDelegateType => Kind == .Delegate || (Kind == .Named && Sym.Kind == .Delegate);
		public bool IsPointer => Kind == .Pointer;
		public bool IsVector => Kind == .Vector;
		/// A lane mask (`bool4`): what comparing two vectors gives.
		public bool IsMask => Kind == .Vector && Element.Kind == .Bool;

		/// A reference: may hold null, may be deleted (class, interface, delegate, array).
		public bool IsReference
		{
			get
			{
				switch (Kind)
				{
				case .Array, .Delegate, .Null: return true;
				case .Named: return Sym.Kind == .Class || Sym.Kind == .Interface || Sym.Kind == .Delegate;
				case .Param: return Param.IsClass;
				default: return false;
				}
			}
		}

		/// Values that are copied (struct, enum, primitives, pointers, tuples, fixed arrays, nullables).
		public bool IsValue => !IsReference && Kind != .Void && Kind != .Error;

		/// A payload enum or a simple one: its cases.
		public bool HasPayloadCases => IsEnum && Sym.HasPayload;

		public KType Arg(int i) => (i < Args.Count) ? Args[i] : null;

		public override void ToString(String outText) => outText.Append(Name);
	}

	/// The primitive types (Language.md 2.1).
	static class Prims
	{
		public struct Info
		{
			public StringView Name;
			public KTypeKind Kind;
			public int32 Bits;
			public bool Signed;
		}

		public static Info[?] All = .(
			.() { Name = "bool", Kind = .Bool, Bits = 1 },
			.() { Name = "int8", Kind = .Int, Bits = 8, Signed = true },
			.() { Name = "int16", Kind = .Int, Bits = 16, Signed = true },
			.() { Name = "int32", Kind = .Int, Bits = 32, Signed = true },
			.() { Name = "int64", Kind = .Int, Bits = 64, Signed = true },
			.() { Name = "int", Kind = .Int, Bits = 64, Signed = true },
			.() { Name = "uint8", Kind = .Int, Bits = 8 },
			.() { Name = "uint16", Kind = .Int, Bits = 16 },
			.() { Name = "uint32", Kind = .Int, Bits = 32 },
			.() { Name = "uint64", Kind = .Int, Bits = 64 },
			.() { Name = "uint", Kind = .Int, Bits = 64 },
			.() { Name = "float", Kind = .Float, Bits = 32 },
			.() { Name = "double", Kind = .Float, Bits = 64 },
			.() { Name = "char8", Kind = .Char, Bits = 8 },
			.() { Name = "char16", Kind = .Char, Bits = 16 },
			.() { Name = "char32", Kind = .Char, Bits = 32 },
			.() { Name = "void", Kind = .Void }
		);

		/// `usize` / `isize` are the C import layer's names for `uint` / `int`.
		public static StringView Alias(StringView name)
		{
			if (name == "usize")
				return "uint";
			if (name == "isize")
				return "int";
			return name;
		}
	}
}
