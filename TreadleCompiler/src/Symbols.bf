using System;
using System.Collections;
using Treadle.Model;
using Treadle.Document;

namespace Treadle.Compiler
{
	/// A generic parameter of a type or a function (Language.md 2.4).
	class GenericParamSym
	{
		public String Name = new .() ~ delete _;
		public int32 Index;
		/// The type that declares it (null for a function's own parameter).
		public TypeSym OwnerType;
		/// The function that declares it (null for a type's parameter).
		public MemberSym OwnerMember;
		/// `T : IFoo`, `T : Base`.
		public List<KType> TypeConstraints = new .() ~ delete _;
		public bool IsClass;
		public bool IsStruct;
		public bool IsEnum;
		public bool IsInterface;
		public bool IsDelete;
		public bool IsNew;
		/// `T : vector` (SIMD-and-Vectors.md 2): T is a vector type; `T : vector float` also names its
		/// lane type (VectorElement).
		public bool IsVector;
		public KType VectorElement;
		/// `operator==`, `operator+`: the operator symbols the parameter supports.
		public List<String> Operators = new .() ~ DeleteContainerAndItems!(_);
		/// `generic const N int`.
		public bool IsConst;
		public KType ConstType;
		/// The type `T` itself.
		public KType AsType;

		public bool HasOperator(StringView op)
		{
			for (let o in Operators)
				if (o == op)
					return true;
			return false;
		}
	}

	class ParamSym
	{
		public String Name = new .() ~ delete _;
		public KType Type;
		public ParamMode Mode;
		/// `default <token>`; null = none.
		public String Default ~ delete _;

		public bool IsOut => Mode == .Out;
		public bool IsRef => Mode == .Ref;
	}

	/// What a member's generic narrowing adds for one of the type's parameters
	/// (`generic TFirst operator==` on an operator record: a `where` clause on the member).
	class Narrowing
	{
		public GenericParamSym Param;
		/// Kind constraints the member adds (`generic T delete` on the core List's DeleteAll).
		public bool IsDelete;
		public bool IsClass;
		public List<String> Operators = new .() ~ DeleteContainerAndItems!(_);
		public List<KType> TypeConstraints = new .() ~ delete _;
	}

	/// A member of a type (Language.md 4) with its resolved signature.
	class MemberSym
	{
		public MemberKind Kind;
		public String Name = new .() ~ delete _;
		/// The record id ("" for fields and cases).
		public String Id = new .() ~ delete _;
		public TypeSym Owner;
		/// The record (not owned; null for members the compiler makes).
		public MemberDecl Decl;
		/// Field / property: the type.
		public KType Type;
		/// Function / operator: the return type (void when none).
		public KType Returns;
		public List<ParamSym> Params = new .() ~ DeleteContainerAndItems!(_);
		public List<ParamSym> Outs = new .() ~ DeleteContainerAndItems!(_);
		/// Case: the payload fields.
		public List<ParamSym> Payload = new .() ~ DeleteContainerAndItems!(_);
		/// The function's own generic parameters.
		public List<GenericParamSym> Generics = new .() ~ DeleteContainerAndItems!(_);
		/// Narrowed constraints on the type's parameters for this member.
		public List<Narrowing> Narrowings = new .() ~ DeleteContainerAndItems!(_);
		public Access Access;
		public bool Static;
		public bool Const;
		public bool Readonly;
		public bool Virtual;
		public bool Abstract;
		public bool Override;
		public bool Sealed;
		public bool Pure;
		public bool Unsafe;
		public bool Mutating;
		public Ownership Ownership;
		/// `[Intrinsic("name")]`: implemented by the compiler / runtime; null = no.
		public String Intrinsic ~ delete _;
		/// `[Import(lib, name, conv)]` or a C import set member.
		public bool IsImport;
		public String ImportLib ~ delete _;
		public String ImportName ~ delete _;
		public String CallConv ~ delete _;
		/// The member has a `sheet body` (functions), `sheet get` / `sheet set` (properties).
		public bool HasBody;
		public bool HasGet;
		public bool HasSet;
		public bool Auto;
		/// Ctor: `chain base|this`.
		public CtorChain Chain;
		/// Field: `init <token>`; null = none.
		public String Init ~ delete _;
		/// Const array field: `elements` (the record's text); null = none.
		public String Elements ~ delete _;
		/// Const: 0 not folded yet, 1 folding (a cycle when met again), 2 folded, 3 failed.
		public uint8 ConstState;
		/// Const: the folded value as a literal token (`42`, `1.5`, `true`, `.Red`, `"text"`).
		public String ConstValue ~ delete _;
		/// Const array: the folded elements (its `Type` is `Span<T>`, ConstElement is `T`).
		public List<String> ConstElements ~ DeleteContainerAndItems!(_);
		public KType ConstElement;
		/// Const: the types whose constants its init names (incremental Validate re-declares it with them).
		public List<TypeSym> ConstRefs ~ delete _;
		/// Virtual functions: the vtable slot (base slots first); -1 = none.
		public int32 VSlot = -1;
		/// Interface members: the slot in the interface table.
		public int32 ISlot = -1;
		/// Override: the function it replaces.
		public MemberSym Overrides;
		/// Instance fields: the index among all instance fields, base class first.
		public int32 FieldIndex = -1;
		/// Case: its value (simple enums) or its index (payload enums).
		public int64 CaseValue;
		/// The compiler made it (a default constructor, a destructor for owned fields, the hidden
		/// field of an auto property or of a Gate / Do Once / Do N / Flip Flop / Multi Gate).
		public bool Synthetic;
		/// A hidden field: the auto property it stores (null otherwise).
		public MemberSym AutoOf;
		/// `[NoDiscard]`, `[Obsolete]`, `[ExpandEnumAsFlow]`.
		public bool NoDiscard;
		public String Obsolete ~ delete _;
		/// `[Export("name")]`: the C name a library exports the function under (Language.md 6).
		public String ExportName ~ delete _;
		public bool ExpandAsFlow;
		/// A C function with `...` (`attr Variadic`): extra inputs `va0`, `va1`, ... are passed after
		/// the fixed ones, with C's default promotions.
		public bool Variadic;
		/// Fields of an imported C record: the byte offset.
		public int64 COffset = -1;
		/// A member an extension adds (Language.md 4, Extension): the extension type that declares
		/// it (its file holds the Sheets; Owner is the extended type). Null for the type's own members.
		public TypeSym Extension;
		/// An event (`attr Event` on a field of a delegate type, Language.md 4): Type is its storage
		/// (`Core.Event<D>`), EventOf the delegate type `D` its handlers have.
		public KType EventOf;
		/// An extern C variable of a C import set (`cvar`): static, reached by its C name; read
		/// through a C function when CVarVia is set (`errno` = `*_errno()`: CVarDeref).
		public bool CVar;
		public String CVarVia ~ delete _;
		public String CVarArg ~ delete _;
		public bool CVarDeref;

		/// The project the member belongs to (`internal`): the extension's for an added member.
		public StringView Project => (Extension != null) ? (StringView)Extension.Project : (StringView)Owner.Project;

		public bool IsCallable => Kind == .Function || Kind == .Ctor || Kind == .Dtor || Kind == .Operator;
		public bool IsInstance => !Static && Kind != .Case;
		public bool IsGeneric => !Generics.IsEmpty;

		/// `TakeDamage(int)`, `ctor(String)`, `operator ==(...)`.
		public void GetSignature(String outText)
		{
			switch (Kind)
			{
			case .Ctor: outText.Append("ctor");
			case .Dtor: outText.Append("dtor");
			case .Operator: outText.AppendF("operator {}", Name);
			default: outText.Append(Name);
			}
			if (IsCallable)
			{
				outText.Append('(');
				for (let p in Params)
				{
					if (@p.Index > 0)
						outText.Append(',');
					if (p.Mode == .Ref || p.Mode == .Out || p.Mode == .In)
						outText.AppendF("{} ", (p.Mode == .Ref) ? "ref" : ((p.Mode == .Out) ? "out" : "in"));
					outText.Append(p.Type.Name);
				}
				outText.Append(')');
			}
		}

		/// `Game.Player.TakeDamage(int)`.
		public void GetFullName(String outText)
		{
			outText.AppendF("{}.", Owner.FullName);
			GetSignature(outText);
		}

		public ParamSym FindParam(StringView name)
		{
			for (let p in Params)
				if (p.Name == name)
					return p;
			for (let p in Outs)
				if (p.Name == name)
					return p;
			return null;
		}

		public Narrowing FindNarrowing(GenericParamSym p)
		{
			for (let n in Narrowings)
				if (n.Param == p)
					return n;
			return null;
		}
	}

	/// A declared type: a project type, a core library type or a C import set (Compiler.md 2).
	class TypeSym
	{
		public String Name = new .() ~ delete _;
		public String Namespace = new .() ~ delete _;
		public String FullName = new .() ~ delete _;
		public TypeKind Kind;
		public List<GenericParamSym> Generics = new .() ~ DeleteContainerAndItems!(_);
		/// Class: the base class (null for Core.Object).
		public KType Base;
		public List<KType> Interfaces = new .() ~ delete _;
		public List<MemberSym> Members = new .() ~ DeleteContainerAndItems!(_);
		/// The header record (not owned).
		public TypeDecl Decl;
		/// The type file (not owned; null for types the compiler makes).
		public TypeDocument Doc;
		public String Path = new .() ~ delete _;
		public List<String> Uses = new .() ~ DeleteContainerAndItems!(_);
		public bool IsCore;
		/// The project that declares it ("" = the compiled project; a `depends` project's name;
		/// `internal` members are visible within one project).
		public String Project = new .() ~ delete _;
		/// A C import set (`C.<set>`): every member is an imported C function.
		public bool IsCImport;
		public String ImportLib ~ delete _;
		public String Category ~ delete _;
		public bool Static;
		public bool Abstract;
		public bool Sealed;
		public bool CRepr;
		public bool Flags;
		/// Enum: the underlying integer type.
		public KType Underlying;
		/// Delegate: the signature (a Delegate KType).
		public KType Signature;
		/// The type with its own parameters as arguments (`Core.Pair<TFirst,TSecond>`).
		public KType Self;
		public bool HasPayload;
		/// Instance fields including the base class's, base first (computed in Declare).
		public List<MemberSym> AllFields = new .() ~ delete _;
		/// Virtual functions by slot, base slots first (computed in Declare).
		public List<MemberSym> VTable = new .() ~ delete _;
		/// Interface: its members in slot order (extended interfaces first).
		public List<MemberSym> ISlots = new .() ~ delete _;
		/// Declare progress: 0 not done, 1 in progress (base cycle detection), 2 done.
		public int32 LayoutState;
		/// A name that stands for another type (a `ctypedef` of a C import set): the type it names.
		/// Uses of the name resolve to it (and a named delegate type to its signature).
		public KType AliasOf;
		/// The alias's target as written (a `ctypedef` line; owned).
		public TypeRef AliasRef ~ delete _;
		public bool ResolvingAlias;
		/// An extension (a type file of kind `extension`): the type it adds members to. Its own
		/// member list stays empty; the members go to the extended type (MemberSym.Extension = this).
		public TypeSym Extends;
		/// The extensions of this type, in declaration order (not owned).
		public List<TypeSym> Extensions ~ delete _;
		/// A `cstruct` / `cunion` / `cenum` / `ctypedef` record of a C import set (Compiler.md 8):
		/// a value type with the imported layout.
		public bool IsCRecord;
		public bool IsCUnion;
		public bool COpaque;
		public int64 CSize;
		public int64 CAlign = 1;
		/// The fields do not lay out naturally in order (a union, overlapping or packed members, gaps):
		/// the back end gets opaque bytes of the record's size and alignment, fields are reached by
		/// byte offset.
		public bool CBlob;
		/// The record's lines in the `.cdecl` (the record line, then its property lines); for a
		/// C import set's own type: its `cconst` lines.
		public List<String> CLines ~ DeleteContainerAndItems!(_);

		public bool IsGeneric => !Generics.IsEmpty;
		public TypeSym BaseSym => (Base != null && Base.Kind == .Named) ? Base.Sym : null;

		public MemberSym FindOwnMember(StringView name)
		{
			for (let m in Members)
				if (m.Name == name && m.Kind != .Ctor && m.Kind != .Dtor)
					return m;
			return null;
		}

		public MemberSym FindCase(StringView name)
		{
			for (let m in Members)
				if (m.Kind == .Case && m.Name == name)
					return m;
			return null;
		}

		public MemberSym Dtor
		{
			get
			{
				for (let m in Members)
					if (m.Kind == .Dtor && !m.Static)
						return m;
				return null;
			}
		}

		public void GetCtors(List<MemberSym> outCtors)
		{
			for (let m in Members)
				if (m.Kind == .Ctor && !m.Static)
					outCtors.Add(m);
		}

		/// True when this type is `other` or derives from it (classes).
		public bool DerivesFrom(TypeSym other)
		{
			var t = this;
			int guard = 0;
			while (t != null && guard++ < 64)
			{
				if (t == other)
					return true;
				t = t.BaseSym;
			}
			return false;
		}
	}
}
