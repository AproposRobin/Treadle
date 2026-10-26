using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	/// How a value of one type reaches a pin of another (Language.md 2.3).
	enum Conv : uint8
	{
		Refused,
		Implicit,
		Exact
	}

	/// The type table (Compiler.md 2): every declared type by its full name, the namespaces, and
	/// the interned semantic types. Two KTypes are the same type exactly when they are the same
	/// object.
	class TypeTable
	{
		public List<TypeSym> Types = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, TypeSym> mByName = new .() ~ delete _;
		/// Every namespace and its parents ("Game", "Game.Core", "C").
		HashSet<String> mNamespaces = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, KType> mInterned = new .() ~ { for (let kv in _) delete kv.value; delete _; };
		Dictionary<String, KType> mPrims = new .() ~ delete _;

		public KType Error;
		public KType Void;
		public KType Null;
		public KType Bool;
		public KType Int;
		public KType Int32;
		public KType UInt8;
		public KType Float;
		public KType Double;
		public KType Char8;

		public TypeSym ObjectSym;
		public TypeSym StringSym;
		public TypeSym StringViewSym;
		public TypeSym SpanSym;
		public TypeSym ResultSym;
		public TypeSym OptionSym;

		public this()
		{
			Error = Make(.Error, "!error", "?");
			Void = Make(.Void, "void", "void");
			Null = Make(.Null, "null", "null");
			for (let p in Prims.All)
			{
				if (p.Kind == .Void)
				{
					mPrims[Void.Name] = Void;
					Void.Prim = new String("void");
					continue;
				}
				let t = Make(p.Kind, p.Name, p.Name);
				t.Bits = p.Bits;
				t.Signed = p.Signed;
				t.Prim = new String(p.Name);
				mPrims[t.Name] = t;
			}
			Bool = Prim("bool");
			Int = Prim("int");
			Int32 = Prim("int32");
			UInt8 = Prim("uint8");
			Float = Prim("float");
			Double = Prim("double");
			Char8 = Prim("char8");
		}

		KType Make(KTypeKind kind, StringView key, StringView name)
		{
			KType t = new .();
			t.Kind = kind;
			t.Key.Set(key);
			t.Name.Set(name);
			mInterned[t.Key] = t;
			return t;
		}

		/// A primitive by keyword (`usize` / `isize` included), or null.
		public KType Prim(StringView name)
		{
			if (mPrims.TryGetValueAlt(Prims.Alias(name), let t))
				return t;
			return VectorByName(name); // float4, int32x4: the vector primitives are primitives too (VectorRules.bf)
		}

		// ------------------------------------------------------------------ declared types

		public void AddType(TypeSym sym)
		{
			Types.Add(sym);
			if (!mByName.ContainsKey(sym.FullName))
				mByName[sym.FullName] = sym;
			StringView ns = sym.Namespace;
			while (!ns.IsEmpty)
			{
				if (!mNamespaces.ContainsAlt(ns))
					mNamespaces.Add(new String(ns));
				let dot = ns.LastIndexOf('.');
				ns = (dot >= 0) ? ns.Substring(0, dot) : "";
			}
		}

		/// The type with that full name, or null.
		public TypeSym Find(StringView fullName)
		{
			if (mByName.TryGetValueAlt(fullName, let s))
				return s;
			return null;
		}

		public bool IsNamespace(StringView name) => mNamespaces.ContainsAlt(name);

		/// Types sharing the full name of another (reported by Declare).
		public void FindDuplicates(List<TypeSym> outDups)
		{
			for (let t in Types)
				if (mByName.TryGetValue(t.FullName, let first) && first != t)
					outDups.Add(t);
		}

		// ------------------------------------------------------------------ interning

		KType Intern(KTypeKind kind, String key, String name)
		{
			if (mInterned.TryGetValue(key, let t))
				return t;
			KType n = new .();
			n.Kind = kind;
			n.Key.Set(key);
			n.Name.Set(name);
			mInterned[n.Key] = n;
			return n;
		}

		public KType Named(TypeSym sym, Span<KType> args)
		{
			if (args.IsEmpty && sym.IsGeneric && sym.Self != null)
			{
				// A generic type named without arguments is its own Self only inside itself; the
				// callers pass arguments. Bare use is an error the caller reports.
			}
			String key = scope $"N{sym.FullName}";
			String name = scope .(sym.FullName);
			if (!args.IsEmpty)
			{
				key.Append('<');
				name.Append('<');
				for (int i < args.Length)
				{
					if (i > 0)
					{
						key.Append(',');
						name.Append(',');
					}
					key.Append(args[i].Key);
					name.Append(args[i].Name);
				}
				key.Append('>');
				name.Append('>');
			}
			let t = Intern(.Named, key, name);
			if (t.Sym == null)
			{
				t.Sym = sym;
				for (let a in args)
					t.Args.Add(a);
			}
			return t;
		}

		public KType ParamType(GenericParamSym p)
		{
			String owner = scope .();
			if (p.OwnerType != null)
				owner.Append(p.OwnerType.FullName);
			else if (p.OwnerMember != null)
				owner.AppendF("{}.{}#{}", p.OwnerMember.Owner.FullName, p.OwnerMember.Name, p.OwnerMember.Id);
			let t = Intern(.Param, scope $"P{owner}.{p.Name}", scope String(p.Name));
			t.Param = p;
			return t;
		}

		KType Wrap(KTypeKind kind, StringView tag, KType e, StringView suffix)
		{
			let t = Intern(kind, scope $"{tag}({e.Key})", scope $"{e.Name}{suffix}");
			t.Element = e;
			return t;
		}

		public KType Array(KType e) => Wrap(.Array, "A", e, "[]");
		public KType Nullable(KType e) => Wrap(.Nullable, "Q", e, "?");
		public KType Pointer(KType e) => Wrap(.Pointer, "R", e, "*");

		public KType FixedArray(KType e, int64 n)
		{
			let t = Intern(.FixedArray, scope $"F({e.Key}){n}", scope $"{e.Name}[{n}]");
			t.Element = e;
			t.Length = n;
			return t;
		}

		public KType Tuple(Span<KType> elems)
		{
			String key = scope .("T(");
			String name = scope .("(");
			for (int i < elems.Length)
			{
				if (i > 0)
				{
					key.Append(',');
					name.Append(',');
				}
				key.Append(elems[i].Key);
				name.Append(elems[i].Name);
			}
			key.Append(')');
			name.Append(')');
			let t = Intern(.Tuple, key, name);
			if (t.Args.IsEmpty)
				for (let e in elems)
					t.Args.Add(e);
			return t;
		}

		public KType Func(bool isDelegate, KType ret, Span<KType> ps)
		{
			String key = scope .(isDelegate ? "d(" : "f(");
			String name = scope .(isDelegate ? "delegate:" : "function:");
			key.Append(ret.Key);
			key.Append(';');
			name.Append(ret.Name);
			name.Append('(');
			for (int i < ps.Length)
			{
				if (i > 0)
				{
					key.Append(',');
					name.Append(',');
				}
				key.Append(ps[i].Key);
				name.Append(ps[i].Name);
			}
			key.Append(')');
			name.Append(')');
			let t = Intern(isDelegate ? .Delegate : .Function, key, name);
			if (t.Element == null)
			{
				t.Element = ret;
				for (let p in ps)
					t.Args.Add(p);
			}
			return t;
		}

		// ------------------------------------------------------------------ substitution

		/// Replaces generic parameters by `map` (deep).
		public KType Subst(KType t, Dictionary<GenericParamSym, KType> map)
		{
			if (t == null || map == null || map.IsEmpty)
				return t;
			switch (t.Kind)
			{
			case .Param:
				if (map.TryGetValue(t.Param, let r))
					return r;
				return t;
			case .Named:
				if (t.Args.IsEmpty)
					return t;
				KType[] args = scope KType[t.Args.Count];
				bool changed = false;
				for (int i < t.Args.Count)
				{
					args[i] = Subst(t.Args[i], map);
					changed |= args[i] != t.Args[i];
				}
				return changed ? Named(t.Sym, args) : t;
			case .Array: return Array(Subst(t.Element, map));
			case .Nullable: return Nullable(Subst(t.Element, map));
			case .Pointer: return Pointer(Subst(t.Element, map));
			case .FixedArray: return FixedArray(Subst(t.Element, map), t.Length);
			case .Tuple:
				KType[] els = scope KType[t.Args.Count];
				for (int i < t.Args.Count)
					els[i] = Subst(t.Args[i], map);
				return Tuple(els);
			case .Function, .Delegate:
				KType[] ps = scope KType[t.Args.Count];
				for (int i < t.Args.Count)
					ps[i] = Subst(t.Args[i], map);
				return Func(t.Kind == .Delegate, Subst(t.Element, map), ps);
			default:
				return t;
			}
		}

		/// The generic map of a named type instance: its declaration's parameters to its arguments.
		public void MapOf(KType t, Dictionary<GenericParamSym, KType> outMap)
		{
			if (t == null || t.Kind != .Named)
				return;
			for (int i < Math.Min(t.Sym.Generics.Count, t.Args.Count))
				outMap[t.Sym.Generics[i]] = t.Args[i];
		}

		/// True when `t` mentions a generic parameter.
		public static bool IsOpen(KType t)
		{
			if (t == null)
				return false;
			switch (t.Kind)
			{
			case .Param: return true;
			case .Named, .Tuple:
				for (let a in t.Args)
					if (IsOpen(a))
						return true;
				return false;
			case .Function, .Delegate:
				for (let a in t.Args)
					if (IsOpen(a))
						return true;
				return IsOpen(t.Element);
			case .Array, .Nullable, .Pointer, .FixedArray: return IsOpen(t.Element);
			default: return false;
			}
		}

		/// Binds the parameters of `infer` that `pattern` mentions to the matching parts of
		/// `actual` (generic function argument inference). False on a contradiction.
		public bool Unify(KType pattern, KType actual, Dictionary<GenericParamSym, KType> map, List<GenericParamSym> infer)
		{
			if (pattern == null || actual == null || actual.IsError || actual.Kind == .Null)
				return true;
			if (pattern.Kind == .Param && infer.Contains(pattern.Param))
			{
				if (map.TryGetValue(pattern.Param, let bound))
					return bound == actual || CanConvert(actual, bound) != .Refused;
				map[pattern.Param] = actual;
				return true;
			}
			if (pattern.Kind != actual.Kind)
				return true; // a conversion may still apply; the argument check reports it
			switch (pattern.Kind)
			{
			case .Named:
				if (pattern.Sym != actual.Sym)
					return true;
				for (int i < Math.Min(pattern.Args.Count, actual.Args.Count))
					if (!Unify(pattern.Args[i], actual.Args[i], map, infer))
						return false;
			case .Array, .Nullable, .Pointer, .FixedArray:
				return Unify(pattern.Element, actual.Element, map, infer);
			case .Tuple, .Function, .Delegate:
				for (int i < Math.Min(pattern.Args.Count, actual.Args.Count))
					if (!Unify(pattern.Args[i], actual.Args[i], map, infer))
						return false;
				if (pattern.Element != null)
					return Unify(pattern.Element, actual.Element, map, infer);
			default:
			}
			return true;
		}

		// ------------------------------------------------------------------ hierarchy

		/// The base class of a class instance (generic arguments applied), or null.
		public KType BaseOf(KType t)
		{
			if (t == null || t.Kind != .Named || t.Sym.Base == null)
				return null;
			if (t.Args.IsEmpty)
				return t.Sym.Base;
			Dictionary<GenericParamSym, KType> map = scope .();
			MapOf(t, map);
			return Subst(t.Sym.Base, map);
		}

		/// The interfaces a named type lists (generic arguments applied).
		public void InterfacesOf(KType t, List<KType> outIfaces)
		{
			if (t == null || t.Kind != .Named)
				return;
			Dictionary<GenericParamSym, KType> map = scope .();
			MapOf(t, map);
			for (let i in t.Sym.Interfaces)
				outIfaces.Add(Subst(i, map));
		}

		/// `from` is `to` or one of its base classes reaches it.
		public bool IsSubclass(KType from, KType to)
		{
			var t = from;
			int guard = 0;
			while (t != null && guard++ < 64)
			{
				if (t == to)
					return true;
				t = BaseOf(t);
			}
			return false;
		}

		/// `from` (a class or interface) implements or extends the interface `iface`, through its
		/// base classes and the interfaces' own bases.
		public bool Implements(KType from, KType iface, int depth = 0)
		{
			if (from == null || depth > 32)
				return false;
			if (from == iface)
				return true;
			List<KType> list = scope .();
			InterfacesOf(from, list);
			for (let i in list)
				if (Implements(i, iface, depth + 1))
					return true;
			let b = BaseOf(from);
			return b != null && Implements(b, iface, depth + 1);
		}

		// ------------------------------------------------------------------ conversions

		/// Language.md 2.3: widening numbers, `T` to `T?`, a class to its base or its interfaces,
		/// `null` to references, `T[]` to `Span<T>`, `String` to `StringView`, pointers to
		/// `void*`. Everything else needs a Cast node. `unsafeOk`: pointer to `void*` allowed.
		public Conv CanConvert(KType from, KType to, String outWhy = null, bool unsafeOk = true)
		{
			if (from == null || to == null || from.IsError || to.IsError)
				return .Implicit;
			if (from == to)
				return .Exact;
			Conv Refuse(StringView why)
			{
				outWhy?.Set(why);
				return .Refused;
			}
			if (from.IsVoid)
				return Refuse("it has no value (the function returns nothing)");
			if (to.IsVoid)
				return Refuse("the pin takes no value");
			if (from.Kind == .Null)
			{
				if (to.IsReference || to.Kind == .Pointer || to.Kind == .Nullable || to.Kind == .Function)
					return .Implicit;
				return Refuse(scope $"null is not {WithArticle(to, .. scope .())}: it is a value type");
			}
			if (from.Kind == .Int && to.Kind == .Int)
			{
				if (from.Bits == to.Bits && from.Signed == to.Signed)
					return .Implicit; // int and int64
				if (from.Signed == to.Signed && from.Bits < to.Bits)
					return .Implicit;
				if (!from.Signed && to.Signed && from.Bits < to.Bits)
					return .Implicit;
				return Refuse(scope $"{from.Name} does not fit in {to.Name} without a Cast");
			}
			if ((from.Kind == .Int || from.Kind == .Float) && to.Kind == .Float)
			{
				if (from.Kind == .Float && from.Bits > to.Bits)
					return Refuse(scope $"{from.Name} to {to.Name} loses precision: use a Cast");
				return .Implicit;
			}
			if (from.Kind == .Char && to.Kind == .Char && from.Bits <= to.Bits)
				return .Implicit;
			if (to.Kind == .Nullable)
			{
				if (from == to.Element || CanConvert(from, to.Element, null, unsafeOk) != .Refused && from.IsValue)
					return .Implicit;
			}
			if (from.Kind == .Named && to.Kind == .Named)
			{
				if (from.Sym.Kind == .Class && to.Sym.Kind == .Class && IsSubclass(from, to))
					return .Implicit;
				if (to.Sym == ObjectSym && (from.Sym.Kind == .Class || from.Sym.Kind == .Interface || from.Sym.Kind == .Delegate))
					return .Implicit;
				if (to.Sym.Kind == .Interface && (from.Sym.Kind == .Class || from.Sym.Kind == .Interface) && Implements(from, to))
					return .Implicit;
				if (from.Sym == StringSym && to.Sym == StringViewSym)
					return .Implicit;
				if (from.Sym.Kind == .Struct && to.Sym.Kind == .Interface && Implements(from, to))
					return Refuse("a struct reaches an interface only through a Box node (it allocates)");
			}
			if (from.Kind == .Array && to.Kind == .Named && to.Sym == SpanSym && to.Args.Count == 1 && to.Args[0] == from.Element)
				return .Implicit;
			if ((from.Kind == .Array || from.Kind == .Delegate) && to.Kind == .Named && to.Sym == ObjectSym)
				return .Implicit;
			if (from.Kind == .Pointer && to.Kind == .Pointer && to.Element.IsVoid)
			{
				if (unsafeOk)
					return .Implicit;
				return Refuse("a pointer becomes void* only in an Unsafe Sheet or block");
			}
			if (from.Kind == .Param)
			{
				let p = from.Param;
				if (to.Kind == .Named && to.Sym == ObjectSym && p.IsClass)
					return .Implicit;
				for (let c in p.TypeConstraints)
					if (c == to || CanConvert(c, to, null, unsafeOk) == .Implicit)
						return .Implicit;
				return Refuse(scope $"{from.Name} is a generic parameter: only {from.Name} pins take it");
			}
			if (from.Kind == .Named && from.Sym.Kind == .Enum && to.Kind == .Int)
				return Refuse(scope $"an enum becomes a number through a Cast (Enum to Integer)");
			if (from.IsReference && to.Kind == .Named && to.Sym.Kind == .Class && IsSubclass(to, from))
				return Refuse(scope $"{Show(from, .. scope .())} is not always a {Show(to, .. scope .())}: use a Class Cast");
			return Refuse(scope $"{WithArticle(from, .. scope .())} is not {WithArticle(to, .. scope .())}");
		}

		/// The type both operands of an arithmetic operator convert to, or null.
		public KType CommonNumeric(KType a, KType b)
		{
			if (a == null || b == null)
				return null;
			if (a.IsError)
				return b;
			if (b.IsError)
				return a;
			if (a == b && (a.IsNumeric || a.Kind == .Char))
				return a;
			if (!a.IsNumeric || !b.IsNumeric)
				return null;
			if (a.Kind == .Float || b.Kind == .Float)
			{
				if (a.Kind == .Float && b.Kind == .Float)
					return (a.Bits >= b.Bits) ? a : b;
				return (a.Kind == .Float) ? a : b;
			}
			if (CanConvert(a, b) != .Refused)
				return b;
			if (CanConvert(b, a) != .Refused)
				return a;
			return null;
		}

		/// `a String`, `an int`.
		public static void WithArticle(KType t, String outText)
		{
			String name = scope .();
			Show(t, name);
			let c = name.IsEmpty ? 'x' : name[0].ToLower;
			outText.Append((c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u') ? "an " : "a ");
			outText.Append(name);
		}

		/// The name as the user reads it: `Core.` dropped (`String`, `Pair<int,float>`).
		public static void Show(KType t, String outText)
		{
			if (t == null)
			{
				outText.Append("?");
				return;
			}
			String name = scope .(t.Name);
			name.Replace("Core.", "");
			outText.Append(name);
		}
	}
}
