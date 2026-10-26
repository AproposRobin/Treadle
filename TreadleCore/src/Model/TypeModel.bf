using System;
using System.Collections;

namespace Treadle.Model
{
	/// Lines the reader kept but does not model: unknown property keys and `#` comments inside a
	/// record (each anchored after the known key that preceded it), comment lines before a record,
	/// and unknown records after it. They are written back in place (Graph-Format.md 2).
	class RecordExtras
	{
		public struct Anchored
		{
			/// The known property key the line followed ("" = right after the record line).
			public String AfterKey;
			/// The whole line without its line feed (with its leading tab).
			public String Line;
		}

		/// Comment lines (`# ...`) directly before the record.
		public List<String> Leading ~ DeleteContainerAndItems!(_);
		/// Unknown properties and comment lines inside the record.
		public List<Anchored> Inner ~ { if (_ != null) { for (let a in _) { delete a.AfterKey; delete a.Line; } delete _; } };
		/// Unknown records (with their property lines) that followed this record.
		public List<String> Trailing ~ DeleteContainerAndItems!(_);

		public bool IsEmpty => (Leading == null || Leading.IsEmpty) && (Inner == null || Inner.IsEmpty) && (Trailing == null || Trailing.IsEmpty);
		public bool HasUnknown => (Inner != null && !Inner.IsEmpty) || (Trailing != null && !Trailing.IsEmpty);

		public void AddLeading(StringView line)
		{
			if (Leading == null)
				Leading = new .();
			Leading.Add(new String(line));
		}

		public void AddInner(StringView afterKey, StringView line)
		{
			if (Inner == null)
				Inner = new .();
			Anchored a;
			a.AfterKey = new String(afterKey);
			a.Line = new String(line);
			Inner.Add(a);
		}

		public void AddTrailing(StringView line)
		{
			if (Trailing == null)
				Trailing = new .();
			Trailing.Add(new String(line));
		}

		public void CopyTo(RecordExtras dst)
		{
			if (Leading != null)
				for (let l in Leading)
					dst.AddLeading(l);
			if (Inner != null)
				for (let a in Inner)
					dst.AddInner(a.AfterKey, a.Line);
			if (Trailing != null)
				for (let l in Trailing)
					dst.AddTrailing(l);
		}
	}

	/// Visibility (Language.md 8). `Unset` = not written (the default, public).
	enum Access : uint8
	{
		Unset,
		Public,
		Protected,
		Private,
		Internal
	}

	enum TypeKind : uint8
	{
		Class,
		Struct,
		Interface,
		Enum,
		Delegate,
		Extension
	}

	/// An attribute on a declaration: `attr Name arg...` (Language.md 8). Arguments are format
	/// tokens (literals, strings, words).
	class AttrDecl
	{
		public String Name = new .() ~ delete _;
		public List<String> Args = new .() ~ DeleteContainerAndItems!(_);

		public AttrDecl Clone()
		{
			AttrDecl a = new .();
			a.Name.Set(Name);
			for (let s in Args)
				a.Args.Add(new String(s));
			return a;
		}
	}

	enum ConstraintKind : uint8
	{
		/// `IFoo`, `Base`: implements / derives from a type.
		Type,
		/// `class`, `struct`, `enum`, `interface`, `delete`, `new`.
		Keyword,
		/// `operator==`, `operator+`: the operator exists.
		Operator
	}

	struct GenericConstraint
	{
		public ConstraintKind Kind;
		/// Kind == Type.
		public TypeRef Type;
		/// Keyword / Operator: the word as written (`class`, `operator==`).
		public String Word;
	}

	/// `generic T [constraints...]` / `generic const N int` (Language.md 2.4).
	class GenericParam
	{
		public String Name = new .() ~ delete _;
		/// `const N int`: a compile-time value of ConstType.
		public bool IsConst;
		public TypeRef ConstType ~ delete _;
		public List<GenericConstraint> Constraints = new .() ~ { for (let c in _) { delete c.Type; delete c.Word; } delete _; };

		public static readonly String[] KeywordConstraints = new .("class", "struct", "enum", "interface", "delete", "new") ~ delete _;

		public void AddConstraint(StringView word)
		{
			GenericConstraint c = default;
			bool keyword = false;
			for (let k in KeywordConstraints)
				if (word == k)
					keyword = true;
			if (keyword)
			{
				c.Kind = .Keyword;
				c.Word = new String(word);
			}
			else if (word.StartsWith("operator"))
			{
				c.Kind = .Operator;
				c.Word = new String(word);
			}
			else
			{
				c.Kind = .Type;
				c.Type = TypeRef.Parse(word);
			}
			Constraints.Add(c);
		}

		public GenericParam Clone()
		{
			GenericParam g = new .();
			g.Name.Set(Name);
			g.IsConst = IsConst;
			g.ConstType = TypeRef.CloneOrNull(ConstType);
			for (let c in Constraints)
			{
				GenericConstraint d = default;
				d.Kind = c.Kind;
				d.Type = TypeRef.CloneOrNull(c.Type);
				d.Word = (c.Word != null) ? new String(c.Word) : null;
				g.Constraints.Add(d);
			}
			return g;
		}
	}

	/// The `type` record: the header of a type file (Graph-Format.md 3.1), what Type Settings edits.
	class TypeDecl
	{
		public String Name = new .() ~ delete _;
		public TypeKind Kind;
		public String Namespace = new .() ~ delete _;
		public List<String> Uses = new .() ~ DeleteContainerAndItems!(_);
		public TypeRef Base ~ delete _;
		public List<TypeRef> Implements = new .() ~ DeleteContainerAndItems!(_);
		public List<GenericParam> Generics = new .() ~ DeleteContainerAndItems!(_);
		public Access Access;
		public bool Abstract;
		public bool Sealed;
		public bool Static;
		/// Enum: the underlying integer type.
		public TypeRef Underlying ~ delete _;
		/// Extension: the type extended.
		public TypeRef Extends ~ delete _;
		/// Delegate: the signature (a Delegate TypeRef: return type and parameter types).
		public TypeRef Signature ~ delete _;
		public List<AttrDecl> Attrs = new .() ~ DeleteContainerAndItems!(_);
		/// null = no `doc` line.
		public String Doc ~ delete _;
		public RecordExtras Extras = new .() ~ delete _;

		/// `Namespace.Name` (or the name alone).
		public void GetFullName(String outName)
		{
			if (!Namespace.IsEmpty)
				outName.AppendF("{}.", Namespace);
			outName.Append(Name);
		}

		public TypeDecl Clone()
		{
			TypeDecl t = new .();
			t.Name.Set(Name);
			t.Kind = Kind;
			t.Namespace.Set(Namespace);
			for (let u in Uses)
				t.Uses.Add(new String(u));
			t.Base = TypeRef.CloneOrNull(Base);
			for (let i in Implements)
				t.Implements.Add(i.Clone());
			for (let g in Generics)
				t.Generics.Add(g.Clone());
			t.Access = Access;
			t.Abstract = Abstract;
			t.Sealed = Sealed;
			t.Static = Static;
			t.Underlying = TypeRef.CloneOrNull(Underlying);
			t.Extends = TypeRef.CloneOrNull(Extends);
			t.Signature = TypeRef.CloneOrNull(Signature);
			for (let a in Attrs)
				t.Attrs.Add(a.Clone());
			if (Doc != null)
				t.Doc = new String(Doc);
			Extras.CopyTo(t.Extras);
			return t;
		}
	}

	enum MemberKind : uint8
	{
		Field,
		Case,
		Property,
		Function,
		Ctor,
		Dtor,
		Operator
	}

	/// How a parameter passes its value. `Unset` = not written (value).
	enum ParamMode : uint8
	{
		Unset,
		Value,
		Ref,
		Out,
		In
	}

	/// Field and local ownership (Language.md 3). `Unset` = not written.
	enum Ownership : uint8
	{
		Unset,
		Owned,
		Ref,
		Appended,
		Pointer,
		Custom
	}

	enum CtorChain : uint8
	{
		None,
		Base,
		This
	}

	/// The Sheet kinds a member owns (Graph-Format.md 3.1, `sheet`).
	enum SheetRole : uint8
	{
		Body,
		Get,
		Set,
		/// The nested body of a Lambda node (`sheet lambda:<nodeid>`).
		Lambda
	}

	/// `param <name> <Type>` / `out <name> <Type>` / `payload <name> <Type>`.
	class ParamDecl
	{
		public String Name = new .() ~ delete _;
		public TypeRef Type ~ delete _;
		public ParamMode Mode;
		/// `default <token>`; null = none.
		public String Default ~ delete _;
		public RecordExtras Extras = new .() ~ delete _;

		public ParamDecl Clone()
		{
			ParamDecl p = new .();
			p.Name.Set(Name);
			p.Type = TypeRef.CloneOrNull(Type);
			p.Mode = Mode;
			if (Default != null)
				p.Default = new String(Default);
			Extras.CopyTo(p.Extras);
			return p;
		}
	}

	/// `local <name> <Type>`: a function's local variable (Language.md 5.4).
	class LocalDecl
	{
		public String Name = new .() ~ delete _;
		public TypeRef Type ~ delete _;
		/// `init <token>`; null = none (zero-initialised).
		public String Init ~ delete _;
		public Ownership Owner;
		public RecordExtras Extras = new .() ~ delete _;

		public LocalDecl Clone()
		{
			LocalDecl l = new .();
			l.Name.Set(Name);
			l.Type = TypeRef.CloneOrNull(Type);
			if (Init != null)
				l.Init = new String(Init);
			l.Owner = Owner;
			Extras.CopyTo(l.Extras);
			return l;
		}

		/// The type as the format spells it ("" when none).
		public void GetTypeText(String outText)
		{
			if (Type != null)
				Type.ToString(outText);
		}
	}

	/// A member of a type: field, enum case, property, function, constructor, destructor or
	/// operator (Graph-Format.md 3.1). Its Sheets live in the document (`Sheet.Member` points
	/// here); params, outs and locals are the member's.
	class MemberDecl
	{
		static int32 sNextSerial = 1;
		/// Runtime identity, kept by Clone (undo steps repoint Sheets by it). Not saved.
		public int32 Serial = System.Threading.Interlocked.Increment(ref sNextSerial) - 1;

		public MemberKind Kind;
		/// Property / function / ctor / dtor / operator: the record id. Empty for fields and cases.
		public String Id = new .() ~ delete _;
		/// Field / case / property / function name; operator: the symbol (`==`, `implicit`).
		public String Name = new .() ~ delete _;
		/// Field / property type; null for the others.
		public TypeRef Type ~ delete _;
		/// Function / operator: `returns`; null = void.
		public TypeRef Returns ~ delete _;

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
		public bool Inline;
		/// Property: an auto property (hidden field, no Sheets).
		public bool Auto;

		/// Field: `init <token>`; null = none. A `const` field's init is a constant expression (the
		/// rest of the line).
		public String Init ~ delete _;
		/// Const array field: `elements <expr>, <expr>, ...` (the rest of the line); null = none.
		public String Elements ~ delete _;
		public Ownership Owner;
		/// Case: the `= value` token; null = none.
		public String CaseValue ~ delete _;
		/// Case: payload fields.
		public List<ParamDecl> Payload = new .() ~ DeleteContainerAndItems!(_);
		/// Ctor: `chain base|this`.
		public CtorChain Chain;
		/// Function: `cconv cdecl|stdcall`; null = none.
		public String CallConv ~ delete _;
		public List<GenericParam> Generics = new .() ~ DeleteContainerAndItems!(_);
		public List<AttrDecl> Attrs = new .() ~ DeleteContainerAndItems!(_);
		public String Doc ~ delete _;
		/// Field: `category "text"`, the group the Outline and the Node menu list it under; null = none.
		public String Category ~ delete _;

		public List<ParamDecl> Params = new .() ~ DeleteContainerAndItems!(_);
		public List<ParamDecl> Outs = new .() ~ DeleteContainerAndItems!(_);
		public List<LocalDecl> Locals = new .() ~ DeleteContainerAndItems!(_);

		public RecordExtras Extras = new .() ~ delete _;

		/// Members that own Sheets (and carry a record id).
		public bool HasId => Kind == .Property || Kind == .Function || Kind == .Ctor || Kind == .Dtor || Kind == .Operator;
		public bool IsCallable => Kind == .Function || Kind == .Ctor || Kind == .Dtor || Kind == .Operator;

		public static StringView KindWord(MemberKind k)
		{
			switch (k)
			{
			case .Field: return "field";
			case .Case: return "case";
			case .Property: return "property";
			case .Function: return "function";
			case .Ctor: return "ctor";
			case .Dtor: return "dtor";
			case .Operator: return "operator";
			}
		}

		public LocalDecl FindLocal(StringView name)
		{
			for (let l in Locals)
				if (l.Name == name)
					return l;
			return null;
		}

		public ParamDecl FindParam(StringView name)
		{
			for (let p in Params)
				if (p.Name == name)
					return p;
			return null;
		}

		/// What the Outline and the tab show: `TakeDamage`, `Constructor(String)`, `operator ==`.
		public void GetDisplayName(String outName)
		{
			switch (Kind)
			{
			case .Ctor, .Dtor:
				outName.Append((Kind == .Ctor) ? (Static ? "Static Constructor" : "Constructor") : "Destructor");
				if (Kind == .Ctor)
				{
					outName.Append('(');
					for (let p in Params)
					{
						if (@p.Index > 0)
							outName.Append(", ");
						p.Type?.ToString(outName);
					}
					outName.Append(')');
				}
			case .Operator:
				outName.AppendF("operator {}", Name);
			default:
				outName.Append(Name);
			}
		}

		/// Takes over `src`'s content (an undo step restoring this member in place); `src` is
		/// left holding this member's old content. Serial stays.
		public void AssignFrom(MemberDecl src)
		{
			Kind = src.Kind;
			Swap!(Id, src.Id);
			Swap!(Name, src.Name);
			Swap!(Type, src.Type);
			Swap!(Returns, src.Returns);
			Access = src.Access;
			Static = src.Static;
			Const = src.Const;
			Readonly = src.Readonly;
			Virtual = src.Virtual;
			Abstract = src.Abstract;
			Override = src.Override;
			Sealed = src.Sealed;
			Pure = src.Pure;
			Unsafe = src.Unsafe;
			Mutating = src.Mutating;
			Inline = src.Inline;
			Auto = src.Auto;
			Swap!(Init, src.Init);
			Swap!(Elements, src.Elements);
			Owner = src.Owner;
			Swap!(CaseValue, src.CaseValue);
			Swap!(Payload, src.Payload);
			Chain = src.Chain;
			Swap!(CallConv, src.CallConv);
			Swap!(Generics, src.Generics);
			Swap!(Attrs, src.Attrs);
			Swap!(Doc, src.Doc);
			Swap!(Category, src.Category);
			Swap!(Params, src.Params);
			Swap!(Outs, src.Outs);
			Swap!(Locals, src.Locals);
			Swap!(Extras, src.Extras);
		}

		public MemberDecl Clone()
		{
			MemberDecl m = new .();
			m.Serial = Serial;
			m.Kind = Kind;
			m.Id.Set(Id);
			m.Name.Set(Name);
			m.Type = TypeRef.CloneOrNull(Type);
			m.Returns = TypeRef.CloneOrNull(Returns);
			m.Access = Access;
			m.Static = Static;
			m.Const = Const;
			m.Readonly = Readonly;
			m.Virtual = Virtual;
			m.Abstract = Abstract;
			m.Override = Override;
			m.Sealed = Sealed;
			m.Pure = Pure;
			m.Unsafe = Unsafe;
			m.Mutating = Mutating;
			m.Inline = Inline;
			m.Auto = Auto;
			if (Init != null)
				m.Init = new String(Init);
			if (Elements != null)
				m.Elements = new String(Elements);
			m.Owner = Owner;
			if (CaseValue != null)
				m.CaseValue = new String(CaseValue);
			for (let p in Payload)
				m.Payload.Add(p.Clone());
			m.Chain = Chain;
			if (CallConv != null)
				m.CallConv = new String(CallConv);
			for (let g in Generics)
				m.Generics.Add(g.Clone());
			for (let a in Attrs)
				m.Attrs.Add(a.Clone());
			if (Doc != null)
				m.Doc = new String(Doc);
			if (Category != null)
				m.Category = new String(Category);
			for (let p in Params)
				m.Params.Add(p.Clone());
			for (let p in Outs)
				m.Outs.Add(p.Clone());
			for (let l in Locals)
				m.Locals.Add(l.Clone());
			Extras.CopyTo(m.Extras);
			return m;
		}
	}

	/// Random record ids (Graph-Format.md 2, "Id"): 5 characters of Crockford base32 in lower case
	/// (no `i l o u`), so two branches adding nodes never collide on a counter.
	static class RecordIds
	{
		public const String Alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
		public const int Length = 5;
		static Random sRandom = new .() ~ delete _;
		static System.Threading.Monitor sLock = new .() ~ delete _;

		/// A fresh random id (any thread).
		public static void New(String outId)
		{
			using (sLock.Enter())
				for (int i < Length)
					outId.Append(Alphabet[sRandom.Next(0, Alphabet.Length)]);
		}

		/// A fresh id not in `used` (which gets it).
		public static void NewUnique(HashSet<String> used, String outId)
		{
			while (true)
			{
				let start = outId.Length;
				New(outId);
				let id = StringView(outId, start);
				if (!used.ContainsAlt(id))
				{
					used.Add(new String(id));
					return;
				}
				outId.RemoveToEnd(start);
			}
		}

		/// A word of 1-8 characters from `[a-z0-9]` (what the reader accepts).
		public static bool IsValid(StringView id)
		{
			if (id.IsEmpty || id.Length > 8)
				return false;
			for (let c in id.RawChars)
				if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')))
					return false;
			return true;
		}
	}
}
