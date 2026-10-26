using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	/// Where a name is resolved: the type whose file it is in, the member (its own generic
	/// parameters), and where to report problems.
	struct NameCtx
	{
		public TypeSym Type;
		public MemberSym Member;
		public DiagSite Site;
		public StringView Node;
		public StringView Pin;
		/// No diagnostics (the editor's type questions).
		public bool Quiet;
		/// An extension's own scope (its namespace and uses lines), looked in before Type's; null
		/// for a type's own file.
		public TypeSym Lookup;

		public this(TypeSym type, MemberSym member, DiagSite site, StringView node = "", StringView pin = "")
		{
			Type = type;
			Member = member;
			Site = site;
			Node = node;
			Pin = pin;
			Quiet = false;
			Lookup = null;
		}
	}

	extension Compilation
	{
		void NameError(in NameCtx c, StringView code, StringView message)
		{
			if (!c.Quiet)
				Diags.Add(.Error, c.Node.IsEmpty ? .Declare : .Bind, code, c.Site, c.Node, c.Pin, message);
		}

		/// A type reference in the context's scope (Compiler.md 2, "Name resolution"). Null for
		/// a missing reference (`r` null or None); the Error type when it does not resolve (a
		/// diagnostic was reported).
		public KType Resolve(TypeRef r, in NameCtx c)
		{
			if (r == null || r.IsNone)
				return null;
			switch (r.Kind)
			{
			case .None:
				return null;
			case .Raw:
				NameError(c, "T1001", scope $"'{r.Name}' is not a type the format can spell");
				return Table.Error;
			case .Named:
				return ResolveNamed(r, c);
			case .Vector:
				// A vector primitive (`float4`; `Vector<float,4>` is read as it) resolves by its short name in
				// the type table, whose Prim knows the vector types (SIMD-and-Vectors.md 1.1, VectorRules.bf).
				let prim = Table.Prim(r.Name);
				if (prim != null)
					return prim;
				NameError(c, "T1090", scope $"{r.Name} is not a vector type");
				return Table.Error;
			case .Array:
				let e = Resolve(r.Element, c);
				return (e == null || e.IsError) ? Table.Error : Table.Array(e);
			case .FixedArray:
				let e = Resolve(r.Element, c);
				if (e == null || e.IsError)
					return Table.Error;
				if (int64.Parse(r.Size) case .Ok(let n))
					return Table.FixedArray(e, n);
				NameError(c, "T1002", scope $"the length of {r} must be a number (constant generic lengths come later)");
				return Table.Error;
			case .Nullable:
				let e = Resolve(r.Element, c);
				if (e == null || e.IsError)
					return Table.Error;
				if (e.IsReference)
				{
					NameError(c, "T1003", scope $"{r} is not needed: a {r.Element} reference can already be null");
					return e;
				}
				return Table.Nullable(e);
			case .Pointer:
				let e = Resolve(r.Element, c);
				return (e == null || e.IsError) ? Table.Error : Table.Pointer(e);
			case .Tuple:
				List<KType> els = scope .();
				if (r.Args != null)
					for (let a in r.Args)
						els.Add(Resolve(a, c) ?? Table.Error);
				return Table.Tuple(els);
			case .Function, .Delegate:
				let ret = (r.Element != null) ? (Resolve(r.Element, c) ?? Table.Void) : Table.Void;
				List<KType> ps = scope .();
				if (r.Args != null)
					for (let a in r.Args)
						ps.Add(Resolve(a, c) ?? Table.Error);
				return Table.Func(r.Kind == .Delegate, ret, ps);
			}
		}

		KType ResolveNamed(TypeRef r, in NameCtx c)
		{
			StringView name = r.Name;
			let hasArgs = r.Args != null && !r.Args.IsEmpty;
			if (!hasArgs && !name.Contains('.'))
			{
				let prim = Table.Prim(name);
				if (prim != null)
					return prim;
				if (VectorRules.TryResolveName(this, name, c, let vt)) // float4, int32x4 (T1090 for int4, double16)
					return vt;
				if (c.Member != null)
				{
					for (let g in c.Member.Generics)
						if (g.Name == name)
							return g.AsType;
				}
				if (c.Type != null)
				{
					for (let g in c.Type.Generics)
						if (g.Name == name)
							return g.AsType;
				}
			}
			if (hasArgs && VectorRules.TryResolveGeneric(this, r, c, let gv)) // Vector<float,4> is float4
				return gv;
			List<TypeSym> ambiguous = scope .();
			let sym = LookupType(name, c, ambiguous);
			if (ambiguous.Count > 1)
			{
				String list = scope .();
				for (let a in ambiguous)
				{
					if (@a.Index > 0)
						list.Append(", ");
					list.Append(a.FullName);
				}
				NameError(c, "T1004", scope $"'{name}' is ambiguous: {list}");
				return Table.Error;
			}
			if (sym == null)
			{
				NameError(c, "T1005", scope $"no type '{name}' is visible here (check the namespace and the uses lines)");
				return Table.Error;
			}
			// A C typedef names another type; a delegate type is its signature (two delegate types
			// with one signature are one type, Language.md 4.2).
			if (sym.AliasRef != null || (sym.Kind == .Delegate && !hasArgs))
			{
				let alias = AliasTarget(sym);
				if (alias != null)
					return alias;
			}
			List<KType> args = scope .();
			if (hasArgs)
				for (let a in r.Args)
					args.Add(Resolve(a, c) ?? Table.Error);
			if (sym == Table.ResultSym && args.Count == 1)
				args.Add(Table.Void);
			if (args.Count != sym.Generics.Count)
			{
				if (args.IsEmpty && c.Type == sym)
					return sym.Self;
				NameError(c, "T1006", scope $"{sym.FullName} takes {sym.Generics.Count} generic argument{(sym.Generics.Count == 1) ? "" : "s"}, not {args.Count}");
				return Table.Error;
			}
			for (let a in args)
				if (a.IsError)
					return Table.Error;
			let t = Table.Named(sym, args);
			if (!args.IsEmpty)
			{
				CheckConstraints(t, c);
				String asked = scope .(c.Site.Type);
				if (!c.Site.Sheet.IsEmpty)
					asked.AppendF(" {}", c.Site.Sheet);
				Instances.AddType(t, asked, c.Node);
			}
			return t;
		}

		/// Finds a type name: the own type, the type's namespace and its parents, the `uses`
		/// lines, the global namespace, then the core library. A level with several candidates
		/// is ambiguous (`outAmbiguous` gets them).
		public TypeSym LookupType(StringView name, in NameCtx c, List<TypeSym> outAmbiguous)
		{
			if (c.Type != null && !name.Contains('.') && c.Type.Name == name)
				return c.Type;
			// An extension's Sheets see the extension file's namespace and uses lines first, then the
			// extended type's.
			for (int pass < 2)
			{
				let t = (pass == 0) ? c.Lookup : c.Type;
				if (t == null || (pass == 1 && t == c.Lookup))
					continue;
				StringView ns = t.Namespace;
				while (!ns.IsEmpty)
				{
					let s = Table.Find(scope $"{ns}.{name}");
					if (s != null)
						return s;
					let dot = ns.LastIndexOf('.');
					ns = (dot >= 0) ? ns.Substring(0, dot) : "";
				}
				TypeSym found = null;
				for (let u in t.Uses)
				{
					let s = Table.Find(scope $"{u}.{name}");
					if (s != null && s != found)
					{
						if (found != null && outAmbiguous.IsEmpty)
							outAmbiguous.Add(found);
						if (found != null)
							outAmbiguous.Add(s);
						found = s;
					}
				}
				if (found != null)
					return found;
			}
			let g = Table.Find(name);
			if (g != null)
				return g;
			return Table.Find(scope $"Core.{name}");
		}

		/// The type an alias stands for: a `ctypedef`'s target, a delegate type's signature
		/// (resolved on first use, so aliases of aliases and records declared later work). Null
		/// when it is not an alias or its target does not resolve.
		public KType AliasTarget(TypeSym sym)
		{
			if (sym.AliasOf != null)
				return sym.AliasOf;
			if (sym.ResolvingAlias)
				return null;
			TypeRef target = sym.AliasRef;
			if (target == null && sym.Kind == .Delegate && sym.Decl != null)
				target = sym.Decl.Signature;
			if (target == null)
				return null;
			sym.ResolvingAlias = true;
			NameCtx c = .(sym, null, .(sym.FullName, "", "", sym.Path));
			if (sym.IsCRecord)
				c.Quiet = true;
			var t = Resolve(target, c);
			sym.ResolvingAlias = false;
			if (t == null || t.IsError)
				return null;
			// The format writes a delegate type's signature as `int(int)`: a function type here.
			if (sym.Kind == .Delegate && t.Kind == .Function)
				t = Table.Func(true, t.Element, t.Args);
			sym.AliasOf = t;
			if (sym.Kind == .Delegate)
				sym.Signature = t;
			return t;
		}

		/// Every constraint of a generic type instance holds; reports the first that does not on
		/// the node that asked (Language.md 2.4).
		public bool CheckConstraints(KType inst, in NameCtx c)
		{
			Dictionary<GenericParamSym, KType> map = scope .();
			Table.MapOf(inst, map);
			bool ok = true;
			for (int i < inst.Sym.Generics.Count)
			{
				let p = inst.Sym.Generics[i];
				String why = scope .();
				if (!Satisfies(inst.Args[i], p, map, c.Member, why))
				{
					NameError(c, "T1007", scope $"{TypeTable.Show(inst, .. scope .())}: {inst.Args[i].Name} does not satisfy the constraint on {p.Name}: {why}");
					ok = false;
				}
			}
			return ok;
		}

		/// Whether `arg` may stand for `p` (its kind, type and operator constraints).
		public bool Satisfies(KType arg, GenericParamSym p, Dictionary<GenericParamSym, KType> map, MemberSym ctxMember, String why)
		{
			if (arg == null || arg.IsError)
				return true;
			let argParam = (arg.Kind == .Param) ? arg.Param : null;
			if (p.IsClass && !(arg.IsReference || (argParam != null && argParam.IsClass)))
			{
				why.Append("it must be a class (a reference type)");
				return false;
			}
			if (p.IsStruct && !(arg.IsValue && arg.Kind != .Param || (argParam != null && argParam.IsStruct)))
			{
				why.Append("it must be a struct (a value type)");
				return false;
			}
			if (p.IsEnum && !(arg.IsEnum || (argParam != null && argParam.IsEnum)))
			{
				why.Append("it must be an enum");
				return false;
			}
			if (p.IsInterface && !(arg.IsInterface || (argParam != null && argParam.IsInterface)))
			{
				why.Append("it must be an interface");
				return false;
			}
			if (p.IsDelete && !(arg.IsReference || (argParam != null && (argParam.IsDelete || argParam.IsClass))))
			{
				why.Append("it must be something Delete takes (a class, an array or a delegate)");
				return false;
			}
			if (p.IsNew && !(argParam != null && argParam.IsNew) && !HasDefaultCtor(arg))
			{
				why.Append("it must be a class or a struct with a constructor that takes no inputs (the `new` constraint)");
				return false;
			}
			for (let ct in p.TypeConstraints)
			{
				let want = Table.Subst(ct, map);
				// Numbers, characters, bools and simple enums are hashable and equatable by value
				// (the core's Hash.Get / Hash.Equal; docs/Core-Library.md, Dictionary).
				if (want.Kind == .Named && want.Sym.IsCore && (want.Sym.Name == "IHashable" || want.Sym.Name == "IEquatable") &&
					(arg.IsInteger || arg.Kind == .Char || arg.Kind == .Bool || (arg.IsEnum && !arg.Sym.HasPayload) || arg.IsVector)) // vectors: every lane, the bytes (SIMD-and-Vectors.md 1.3)
					continue;
				// A struct that implements the interface satisfies it (its members bind statically;
				// Language.md 2.4, 2.5).
				if (arg.Kind == .Named && arg.Sym.Kind == .Struct && want.IsInterface && Table.Implements(arg, want))
					continue;
				if (Table.CanConvert(arg, want) == .Refused)
				{
					why.AppendF("it must be or implement {}", TypeTable.Show(want, .. scope .()));
					return false;
				}
			}
			for (let op in p.Operators)
			{
				if (!SupportsOperator(arg, op, ctxMember))
				{
					why.AppendF("it has no operator {}", op);
					return false;
				}
			}
			return true;
		}

		/// `new T` works: a class that is not abstract or static, or a struct, with a constructor
		/// without inputs (or none declared).
		public bool HasDefaultCtor(KType t)
		{
			if (t == null || t.IsError)
				return true;
			if (t.Kind != .Named)
				return false;
			let s = t.Sym;
			if (s.Kind == .Struct)
				return true;
			if (s.Kind != .Class || s.Abstract || s.Static || s.IsCImport)
				return false;
			List<MemberSym> ctors = scope .();
			s.GetCtors(ctors);
			if (ctors.IsEmpty)
				return !s.IsCore;
			for (let k in ctors)
				if (k.Params.IsEmpty && k.Access != .Private)
					return true;
			return false;
		}

		/// Whether values of `t` support the operator `op` (builtin rules, a user operator, or
		/// a generic parameter's operator constraint, narrowed by `ctxMember`).
		public bool SupportsOperator(KType t, StringView op, MemberSym ctxMember)
		{
			if (t == null || t.IsError)
				return true;
			let isEq = op == "==" || op == "!=";
			let isCmp = op == "<" || op == ">" || op == "<=" || op == ">=";
			let isArith = op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "neg";
			let isBits = op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == "~";
			switch (t.Kind)
			{
			case .Int: return isEq || isCmp || isArith || isBits;
			case .Float: return isEq || isCmp || isArith;
			case .Char: return isEq || isCmp;
			case .Bool: return isEq || op == "&&" || op == "||" || op == "!" || op == "&" || op == "|" || op == "^";
			case .Pointer, .Null, .Array, .Delegate, .Function: return isEq;
			case .Vector: return VectorRules.SupportsOperator(t, op); // VectorRules.bf
			case .Param:
				let p = t.Param;
				if (p.HasOperator(op))
					return true;
				if (ctxMember != null)
				{
					let n = ctxMember.FindNarrowing(p);
					if (n != null)
						for (let o in n.Operators)
							if (o == op)
								return true;
				}
				return isEq && p.IsClass;
			case .Named:
				if (t.Sym.Kind == .Enum)
				{
					if (isEq && !t.Sym.HasPayload)
						return true;
					if ((op == "&" || op == "|" || op == "^" || op == "~") && t.Sym.Flags)
						return true;
				}
				if (isEq && (t.Sym.Kind == .Class || t.Sym.Kind == .Interface || t.Sym.Kind == .Delegate))
					return true;
				return FindUserOperator(t, op) != null;
			default:
				return false;
			}
		}

		/// A user operator `op` declared by the named type of `t` (its operator records).
		public MemberSym FindUserOperator(KType t, StringView op)
		{
			if (t == null || t.Kind != .Named)
				return null;
			for (let m in t.Sym.Members)
				if (m.Kind == .Operator && m.Name == op)
					return m;
			return null;
		}

		/// The user operator `op` of `t` for operands of the types `ta` and `tb` (`tb` null for a
		/// unary operator): a type may declare one operator several times with other input types
		/// (`Vec3 * Vec3`, `Vec3 * float`, `float * Vec3`). The one whose inputs are exactly those
		/// types wins, else the first whose inputs take them; with a single declaration, that one.
		public MemberSym FindUserOperatorFor(KType t, StringView op, KType ta, KType tb)
		{
			if (t == null || t.Kind != .Named)
				return null;
			MemberSym first = null;
			MemberSym taking = null;
			int count = 0;
			Dictionary<GenericParamSym, KType> map = scope .();
			Table.MapOf(t, map);
			for (let m in t.Sym.Members)
			{
				if (m.Kind != .Operator || m.Name != op)
					continue;
				count++;
				first = first ?? m;
				if (ta == null || m.Params.Count != ((tb == null) ? 1 : 2))
					continue;
				let p0 = Table.Subst(m.Params[0].Type, map);
				let p1 = (tb == null) ? null : Table.Subst(m.Params[1].Type, map);
				if (p0 == ta && (tb == null || p1 == tb))
					return m;
				if (taking == null && (p0 == ta || Table.CanConvert(ta, p0) != .Refused) && (tb == null || p1 == tb || Table.CanConvert(tb, p1) != .Refused))
					taking = m;
			}
			return (count == 1) ? first : (taking ?? first);
		}

		/// A user operator `op` whose two inputs have different types (`Vec3 * float`, `Mat4 * Vec4`),
		/// declared by the named type on either side, that takes operands of the types `ta` and `tb`
		/// (exact types first); `outOwner` is the type that declares it. Null when there is none.
		public MemberSym FindMixedOperator(StringView op, KType ta, KType tb, out KType outOwner)
		{
			outOwner = null;
			if (ta == null || tb == null || ta.IsError || tb.IsError)
				return null;
			for (int pass < 2)
			{
				for (int side < 2)
				{
					let owner = (side == 0) ? ta : tb;
					if (owner.Kind != .Named || owner.IsEnum)
						continue;
					Dictionary<GenericParamSym, KType> map = scope .();
					Table.MapOf(owner, map);
					for (let m in owner.Sym.Members)
					{
						if (m.Kind != .Operator || m.Name != op || m.Params.Count != 2)
							continue;
						let p0 = Table.Subst(m.Params[0].Type, map);
						let p1 = Table.Subst(m.Params[1].Type, map);
						if (p0 == p1)
							continue;
						let fits = (pass == 0) ? (p0 == ta && p1 == tb) :
							((p0 == ta || Table.CanConvert(ta, p0) != .Refused) && (p1 == tb || Table.CanConvert(tb, p1) != .Refused));
						if (fits)
						{
							outOwner = owner;
							return m;
						}
					}
				}
			}
			return null;
		}

		/// The input type a literal takes beside a value of the named type `other` when `other`
		/// declares `op` with a number on the literal's side (`v * 2`: the float of `Vec3 * float`);
		/// null when it declares none (the literal then takes `other`'s type, as before).
		public KType MixedLiteralSide(StringView op, KType other, bool literalIsA, StringView literal)
		{
			if (other == null || other.Kind != .Named || other.IsEnum || literal.IsEmpty)
				return null;
			Dictionary<GenericParamSym, KType> map = scope .();
			Table.MapOf(other, map);
			for (let m in other.Sym.Members)
			{
				if (m.Kind != .Operator || m.Name != op || m.Params.Count != 2)
					continue;
				let mine = Table.Subst(m.Params[literalIsA ? 0 : 1].Type, map);
				let theirs = Table.Subst(m.Params[literalIsA ? 1 : 0].Type, map);
				if (theirs != other || mine == other || !mine.IsNumeric)
					continue;
				String why = scope .();
				if (Literals.Fits(literal, mine, Table, why))
					return mine;
			}
			return null;
		}
	}
}
