using System;
using System.Collections;
using Treadle.Model;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Compiler
{
	/// Declare (Compiler.md 1, 2): every type header and member header into the type table, no
	/// Sheets read. Then the class rules that need the whole table: bases, vtables, overrides,
	/// interface completeness, constructor chains, the entry point.
	extension Compilation
	{
		public void Declare()
		{
			if (Declared)
				return;
			Declared = true;
			// 1. Names.
			for (let u in Units)
				DeclareType(u);
			Table.ObjectSym = Table.Find("Core.Object");
			Table.StringSym = Table.Find("Core.String");
			Table.StringViewSym = Table.Find("Core.StringView");
			Table.SpanSym = Table.Find("Core.Span");
			Table.ResultSym = Table.Find("Core.Result");
			Table.OptionSym = Table.Find("Core.Option");
			List<TypeSym> dups = scope .();
			Table.FindDuplicates(dups);
			for (let d in dups)
				Error("T1010", .(d.FullName, "", "", d.Path), "", "", scope $"another type file already declares {d.FullName}", .Declare);
			// 2. Headers.
			for (let u in Units)
				if (u.Sym != null)
					DeclareHeader(u.Sym);
			for (let u in Units)
				if (u.Sym != null)
					CheckBaseCycle(u.Sym);
			// 3. Members.
			for (let u in Units)
				if (u.Sym != null && u.Sym.Kind != .Extension)
					DeclareMembers(u, u.Sym);
			DeclareCRecordMembers();
			// An extension's members join the extended type's, after that type's own (Language.md 4).
			for (let u in Units)
				if (u.Sym != null && u.Sym.Kind == .Extension && u.Sym.Extends != null)
					DeclareMembers(u, u.Sym.Extends, u.Sym);
			// 4. Layout, vtables, interface tables.
			LayoutCRecords();
			for (let u in Units)
				if (u.Sym != null)
					Layout(u.Sym);
			// 4b. Constants: every const field's value (Consts.bf).
			FoldConstants();
			// 5. The rules over the whole table.
			for (let u in Units)
			{
				if (u.Sym == null || u.IsCore || u.IsCDecl)
					continue;
				CheckInterfaces(u.Sym);
				CheckCtorChains(u.Sym);
			}
			CheckEntryPoint();
		}

		DiagSite SiteOf(TypeSym t, StringView member = "") => .(t.FullName, member, "", t.Path);

		/// Every variable of a member has a type (T1078, on the variable: `newVar needs a type`): a field's
		/// or property's, each input's and output's, each Local Variable's and each `const` generic
		/// parameter's. Without one the variable would reach the Sheet IR untyped (a slot of no type the
		/// back end cannot read); with the error the build stops at Validate.
		void NeedTypes(MemberDecl d, in NameCtx c)
		{
			void Need(TypeRef r, StringView kind, StringView name, StringView what, in NameCtx c)
			{
				if (r != null && !r.IsNone)
					return;
				let diag = Error("T1078", c.Site, "", "", scope $"{name} needs a type: choose one for the {what} in Properties", .Declare);
				diag?.Variable.Set(scope $"{kind}:{name}");
			}
			switch (d.Kind)
			{
			case .Field: Need(d.Type, "field", d.Name, "variable", c);
			case .Property: Need(d.Type, "field", d.Name, "property", c);
			default:
			}
			for (let p in d.Params)
				Need(p.Type, (p.Mode == .Out) ? "out" : "param", p.Name, (p.Mode == .Out) ? "output" : "input", c);
			for (let o in d.Outs)
				Need(o.Type, "out", o.Name, "output", c);
			for (let l in d.Locals)
				Need(l.Type, "local", l.Name, "Local Variable", c);
			for (let g in d.Generics)
				if (g.IsConst)
					Need(g.ConstType, "generic", g.Name, "generic parameter", c);
		}

		void DeclareType(SourceUnit u)
		{
			let h = u.Doc.Header;
			if (h.Name.IsEmpty)
			{
				Error("T1011", .("", "", "", u.Path), "", "", "the file has no type record", .Declare);
				return;
			}
			TypeSym t = new .();
			FillType(u, t);
			u.Sym = t;
			Table.AddType(t);
			if (u.IsCDecl)
				DeclareCRecords(u, t);
		}

		/// A symbol's fields from its unit's type record: a new symbol, or one that ResetType
		/// emptied (incremental Validate re-declares a type in place, Incremental.bf).
		void FillType(SourceUnit u, TypeSym t)
		{
			let h = u.Doc.Header;
			t.Name.Set(h.Name);
			t.Namespace.Set(h.Namespace);
			t.Kind = h.Kind;
			t.Decl = h;
			t.Doc = u.Doc;
			t.Path.Set(u.Path);
			t.IsCore = u.IsCore;
			t.Project.Set(u.IsCore ? "<core>" : (StringView)u.Project);
			t.Static = h.Static;
			t.Abstract = h.Abstract;
			t.Sealed = h.Sealed;
			for (let s in h.Uses)
				t.Uses.Add(new String(s));
			if (u.IsCDecl)
			{
				t.IsCImport = true;
				t.Namespace.Set("C");
				t.Name.Set(u.Set.Name);
				t.Kind = .Class;
				t.Static = true;
				if (!u.Set.Libs.IsEmpty)
					t.ImportLib = new String(u.Set.Libs[0]);
				t.Category = (u.Set.Category != null) ? new String(u.Set.Category) : new String(scope $"C | {u.Set.Name}");
			}
			t.FullName.Set(t.Namespace);
			if (!t.FullName.IsEmpty)
				t.FullName.Append('.');
			t.FullName.Append(t.Name);
			for (let a in h.Attrs)
			{
				if (a.Name == "CRepr")
					t.CRepr = true;
				else if (a.Name == "Flags")
					t.Flags = true;
				else if (a.Name == "Align" && !a.Args.IsEmpty)
				{
					// Objects, Locals and array elements are at most 16-byte aligned (the runtime's heap and
					// the Debug header): a larger alignment is refused rather than given silently wrong
					var arg = StringView(a.Args[0]);
					arg.Trim();
					while (arg.StartsWith('(') || arg.EndsWith(')'))
						arg = arg.StartsWith('(') ? arg.Substring(1) : arg.Substring(0, arg.Length - 1);
					if (int64.Parse(arg) case .Ok(let n) && n > 16)
						Error("T1077", SiteOf(t), "", "", scope $"[Align({n})]: an alignment above 16 bytes is not supported (objects, Locals and array elements are at most 16-byte aligned)", .Declare);
				}

			}
			for (let g in h.Generics)
			{
				GenericParamSym p = new .();
				p.Name.Set(g.Name);
				p.Index = (int32)t.Generics.Count;
				p.OwnerType = t;
				p.IsConst = g.IsConst;
				t.Generics.Add(p);
				p.AsType = Table.ParamType(p);
			}
			List<KType> args = scope .();
			for (let p in t.Generics)
				args.Add(p.AsType);
			t.Self = Table.Named(t, args);
		}

		void AddConstraints(GenericParamSym p, GenericParam g, in NameCtx c, Narrowing narrowing = null)
		{
			for (let k in g.Constraints)
			{
				switch (k.Kind)
				{
				case .Keyword:
					if (narrowing != null)
					{
						if (k.Word == "delete")
							narrowing.IsDelete = true;
						else if (k.Word == "class")
							narrowing.IsClass = true;
						break;
					}
					switch (k.Word)
					{
					case "class": p.IsClass = true;
					case "struct": p.IsStruct = true;
					case "enum": p.IsEnum = true;
					case "interface": p.IsInterface = true;
					case "delete": p.IsDelete = true;
					case "new": p.IsNew = true;
					case "vector": p.IsVector = true;
					}
				case .Operator:
					StringView op = k.Word;
					if (op.StartsWith("operator"))
						op = op.Substring(8);
					op.Trim();
					if (narrowing != null)
						narrowing.Operators.Add(new String(op));
					else
						p.Operators.Add(new String(op));
				case .Type:
					let t = Resolve(k.Type, c);
					// `vector float`: the lane type of a vector constraint (a number or bool after `vector`)
					if (t != null && narrowing == null && p.IsVector && p.VectorElement == null && (t.IsNumeric || t.Kind == .Bool))
					{
						p.VectorElement = t;
						break;
					}
					if (t != null && !t.IsError)
					{
						if (narrowing != null)
							narrowing.TypeConstraints.Add(t);
						else
							p.TypeConstraints.Add(t);
					}
				}
			}
			if (g.IsConst && g.ConstType != null)
				p.ConstType = Resolve(g.ConstType, c);
		}

		void DeclareHeader(TypeSym t)
		{
			let h = t.Decl;
			NameCtx c = .(t, null, SiteOf(t));
			for (int i < Math.Min(h.Generics.Count, t.Generics.Count))
				AddConstraints(t.Generics[i], h.Generics[i], c);
			switch (t.Kind)
			{
			case .Class:
				if (h.Base != null && !h.Base.IsNone)
				{
					let b = Resolve(h.Base, c);
					if (b != null && !b.IsError)
					{
						if (!b.IsClass)
							Error("T1012", c.Site, "", "", scope $"the base {TypeTable.Show(b, .. scope .())} is not a class", .Declare);
						else if (b.Sym.Sealed)
							Error("T1013", c.Site, "", "", scope $"{TypeTable.Show(b, .. scope .())} is sealed: no class may derive from it", .Declare);
						else if (b.Sym.Static)
							Error("T1014", c.Site, "", "", scope $"{TypeTable.Show(b, .. scope .())} is a static class (a node library): it cannot be a base", .Declare);
						else
							t.Base = b;
					}
				}
				else if (t != Table.ObjectSym && Table.ObjectSym != null && !t.IsCImport)
					t.Base = Table.ObjectSym.Self;
			case .Struct, .Interface, .Enum, .Delegate, .Extension:
				if (h.Base != null && !h.Base.IsNone)
					Error("T1015", c.Site, "", "", (t.Kind == .Interface) ? "an interface extends other interfaces through its implements lines, it has no base" : "only a class has a base type", .Declare);
			}
			for (let i in h.Implements)
			{
				let it = Resolve(i, c);
				if (it == null || it.IsError)
					continue;
				if (!it.IsInterface)
				{
					Error("T1016", c.Site, "", "", scope $"{TypeTable.Show(it, .. scope .())} is not an interface", .Declare);
					continue;
				}
				t.Interfaces.Add(it);
			}
			if (t.Kind == .Enum)
			{
				t.Underlying = (h.Underlying != null) ? Resolve(h.Underlying, c) : Table.Int;
				if (t.Underlying != null && !t.Underlying.IsError && !t.Underlying.IsInteger)
				{
					Error("T1017", c.Site, "", "", "the underlying type of an enum is an integer type", .Declare);
					t.Underlying = Table.Int;
				}
			}
			if (t.Kind == .Delegate && h.Signature != null)
				t.Signature = Resolve(h.Signature, c);
			if (t.Kind == .Extension)
				DeclareExtends(t, c);
		}

		/// An extension's `extends` line (Language.md 4, Extension): a class, struct or enum of the
		/// program (the project's, a dependency's, the core library's or a C record). Written with or
		/// without its generic parameters (`extends Core.List<T>` or `extends Core.List`); the
		/// extension's Sheets see them by the extended type's names.
		void DeclareExtends(TypeSym t, in NameCtx c)
		{
			let h = t.Decl;
			if (!h.Generics.IsEmpty)
				Error("T1070", c.Site, "", "", "an extension has no generic parameters of its own: it uses the extended type's", .Declare);
			if (h.Extends == null || h.Extends.IsNone || h.Extends.Kind != .Named || h.Extends.Name.IsEmpty)
			{
				Error("T1070", c.Site, "", "", "an extension names the type it extends (Type Settings > Extends)", .Declare);
				return;
			}
			List<TypeSym> amb = scope .();
			let sym = LookupType(h.Extends.Name, c, amb);
			if (amb.Count > 1)
			{
				Error("T1004", c.Site, "", "", scope $"'{h.Extends.Name}' is ambiguous", .Declare);
				return;
			}
			if (sym == null)
			{
				Error("T1070", c.Site, "", "", scope $"no type '{h.Extends.Name}' is visible here to extend (check the namespace and the uses lines)", .Declare);
				return;
			}
			StringView why = "";
			if (sym.Kind == .Extension)
				why = "an extension";
			else if (sym.Kind == .Interface)
				why = "an interface (its implementers get the members it declares)";
			else if (sym.Kind == .Delegate || sym.AliasRef != null)
				why = "a name for another type";
			else if (sym.IsCImport)
				why = "a C import set (its members are the imported functions)";
			else if (sym.COpaque)
				why = "an opaque C record (only pointers to it exist)";
			if (!why.IsEmpty)
			{
				Error("T1070", c.Site, "", "", scope $"{sym.FullName} is {why}: an extension adds members to a class, a struct or an enum", .Declare);
				return;
			}
			t.Extends = sym;
			if (sym.Extensions == null)
				sym.Extensions = new .();
			sym.Extensions.Add(t);
		}

		/// The extension belongs to the project that declares the extended type: it may add fields
		/// (and the hidden fields of auto properties and stateful nodes) only then.
		static bool OwnsExtended(TypeSym ext, TypeSym t) => !t.IsCore && !t.IsCRecord && !t.IsCImport && t.Project == ext.Project;

		static void WhoseType(TypeSym t, String outText)
		{
			if (t.IsCore)
				outText.AppendF("{} is a core library type", t.FullName);
			else if (t.IsCRecord)
				outText.AppendF("{} is an imported C record", t.FullName);
			else
				outText.AppendF("{} belongs to the project {}", t.FullName, t.Project.IsEmpty ? "being built" : (StringView)t.Project);
		}

		/// An event (Language.md 4, Event): a field of a delegate type marked `attr Event`. Its
		/// storage is a `Core.Event<D>` (the core's list of handlers, TreadleCore/core/Event.treadle)
		/// inside the object; its nodes are Calls on it (`Call this.OnHit.Add`, Bind.bf BindEvent).
		void DeclareEvent(MemberSym m, TypeSym t, in NameCtx c)
		{
			let d = m.Type;
			if (d == null || d.IsError)
				return;
			if (d.Kind != .Delegate)
			{
				Error("T1074", c.Site, "", "", scope $"the event {m.Name} needs a delegate type (a delegate type file or delegate:void(...)), not {TypeTable.Show(d, .. scope .())}", .Declare);
				return;
			}
			if (!d.Element.IsVoid)
			{
				Error("T1074", c.Site, "", "", scope $"the event {m.Name}: its delegate type returns nothing (Invoke calls every handler, there is no one result)", .Declare);
				return;
			}
			if (t.Kind != .Class || m.Static || m.Const)
			{
				Error("T1075", c.Site, "", "", scope $"the event {m.Name} is an instance field of a class: the object owns its handlers and its destructor deletes them", .Declare);
				return;
			}
			let es = Table.Find("Core.Event");
			if (es == null)
				return;
			List<KType> args = scope .();
			args.Add(d);
			m.EventOf = d;
			m.Type = Table.Named(es, args);
			Instances.AddType(m.Type, t.FullName, "");
		}

		/// The rules for a member an extension adds (Language.md 4, Extension).
		void CheckExtensionMember(MemberSym m, TypeSym t, TypeSym ext)
		{
			let site = SiteOf(ext, m.Id);
			switch (m.Kind)
			{
			case .Field:
				// A constant has no storage in the type: any extension may add one.
				if (!m.Const && !OwnsExtended(ext, t))
					Error("T1071", site, "", "", scope $"{m.Name}: an extension adds fields only to a type of its own project ({WhoseType(t, .. scope .())})", .Declare);
			case .Case:
				Error("T1072", site, "", "", scope $"{m.Name}: an extension cannot add enum cases", .Declare);
			case .Ctor, .Dtor:
				Error("T1072", site, "", "", "constructors and destructors stay in the type's own file: an extension adds functions, properties, operators and (to its own types) fields", .Declare);
			case .Function, .Operator:
				if (!m.HasBody)
					Error("T1073", site, "", "", scope $"{m.Name}: a function of an extension has a Sheet (it cannot be abstract)", .Declare);
				else if (m.Virtual || m.Override)
					Error("T1073", site, "", "", scope $"{m.Name}: a function of an extension binds statically (it cannot be virtual or override)", .Declare);
			default:
			}
		}

		void CheckBaseCycle(TypeSym t)
		{
			var b = t.BaseSym;
			int guard = 0;
			while (b != null && guard++ < 64)
			{
				if (b == t)
				{
					Error("T1018", SiteOf(t), "", "", scope $"{t.FullName} derives from itself through its base classes", .Declare);
					t.Base = null;
					return;
				}
				b = b.BaseSym;
			}
		}

		static bool MatchGlob(StringView pattern, StringView name)
		{
			if (pattern.EndsWith('*'))
				return name.StartsWith(pattern.Substring(0, pattern.Length - 1));
			if (pattern.StartsWith('*'))
				return name.EndsWith(pattern.Substring(1));
			return pattern == name;
		}

		static bool InWordList(List<String> list, StringView word)
		{
			for (let line in list)
				for (var w in line.Split(' '))
				{
					w.Trim();
					if (w == word)
						return true;
				}
			return false;
		}

		bool HasSheet(TypeDocument doc, MemberDecl d, SheetRole role)
		{
			for (let s in doc.Sheets)
				if (s.Member == d && s.Role == role)
					return true;
			return false;
		}

		/// The members of a type file. `ext`: the file is an extension of `t` (its members join t's).
		void DeclareMembers(SourceUnit u, TypeSym t, TypeSym ext = null)
		{
			int64 nextCase = 0;
			let firstNew = t.Members.Count;
			// The functions that read a `cvar` (`via _errno deref`) are declared whatever the set's
			// only / hide lines say, and kept out of the Node menu when those leave them out.
			List<String> via = scope .();
			if (u.IsCDecl)
				CVarFunctions(u.Doc, via);
			defer { ClearAndDeleteItems!(via); }
			for (let d in u.Doc.Members)
			{
				bool viaOnly = false;
				if (u.IsCDecl && d.Kind == .Function)
				{
					let set = u.Set;
					bool hidden = !set.Only.IsEmpty && !InWordList(set.Only, d.Name);
					for (let line in set.Hide)
						for (var w in line.Split(' '))
						{
							w.Trim();
							if (!w.IsEmpty && MatchGlob(w, d.Name))
								hidden = true;
						}
					if (hidden)
					{
						if (!via.ContainsAlt(d.Name))
							continue;
						viaOnly = true;
					}
				}
				MemberSym m = new .();
				m.Synthetic = viaOnly;
				m.Kind = d.Kind;
				m.Name.Set(d.Name);
				m.Id.Set(d.Id);
				m.Decl = d;
				m.Owner = t;
				m.Access = d.Access;
				// A constant belongs to the type (Language.md 4.6): it is static whether the record says so or not.
				m.Static = d.Static || (d.Const && d.Kind == .Field) || ((t.Static || t.IsCImport) && d.Kind != .Case);
				m.Const = d.Const;
				m.Readonly = d.Readonly;
				m.Virtual = d.Virtual;
				m.Abstract = d.Abstract;
				m.Override = d.Override;
				m.Sealed = d.Sealed;
				m.Pure = d.Pure;
				m.Unsafe = d.Unsafe;
				m.Mutating = d.Mutating;
				m.Ownership = d.Owner;
				m.Chain = d.Chain;
				m.Auto = d.Auto;
				if (d.Init != null)
					m.Init = new String(d.Init);
				if (d.Elements != null)
					m.Elements = new String(d.Elements);
				if (d.CallConv != null)
					m.CallConv = new String(d.CallConv);
				m.Extension = ext;
				t.Members.Add(m);
				for (let g in d.Generics)
				{
					GenericParamSym own = null;
					for (let tp in t.Generics)
						if (tp.Name == g.Name)
							own = tp;
					if (own != null)
					{
						Narrowing n = new .();
						n.Param = own;
						m.Narrowings.Add(n);
						NameCtx nc = .(t, m, SiteOf(ext ?? t, d.Id));
						nc.Lookup = ext;
						AddConstraints(own, g, nc, n);
						continue;
					}
					GenericParamSym p = new .();
					p.Name.Set(g.Name);
					p.Index = (int32)m.Generics.Count;
					p.OwnerMember = m;
					p.IsConst = g.IsConst;
					m.Generics.Add(p);
					p.AsType = Table.ParamType(p);
				}
				NameCtx c = .(t, m, SiteOf(ext ?? t, d.Id));
				c.Lookup = ext;
				for (int i < d.Generics.Count)
					for (let p in m.Generics)
						if (p.Name == d.Generics[i].Name)
							AddConstraints(p, d.Generics[i], c);
				for (let a in d.Attrs)
				{
					switch (a.Name)
					{
					case "Intrinsic":
						m.Intrinsic = new String(a.Args.IsEmpty ? (StringView)d.Name : (StringView)a.Args[0]);
						if (m.Intrinsic.StartsWith('"'))
							Treadle.Format.RecordText.Unquote(m.Intrinsic, m.Intrinsic..Clear());
					case "Import":
						m.IsImport = true;
						m.ImportLib = new String((a.Args.Count > 0) ? (StringView)a.Args[0] : "");
						m.ImportName = new String((a.Args.Count > 1) ? (StringView)a.Args[1] : (StringView)d.Name);
						if (a.Args.Count > 2 && m.CallConv == null)
							m.CallConv = new String(a.Args[2]);
					case "NoDiscard": m.NoDiscard = true;
					case "Obsolete": m.Obsolete = new String(a.Args.IsEmpty ? "" : (StringView)a.Args[0]);
					case "ExpandEnumAsFlow": m.ExpandAsFlow = true;
					case "Variadic": m.Variadic = true;
					case "Kernel": KernelRules.Mark(m, t, d.Name); // Kernel.bf (GPU-Compute.md)
					case "Export":
						// `[Export("name")]` (the C name; default the function's name), a second
						// argument (the calling convention) is the platform's C one on x64
						String name = scope .(a.Args.IsEmpty ? (StringView)d.Name : (StringView)a.Args[0]);
						if (name.StartsWith('"'))
						{
							String unq = scope .();
							Treadle.Format.RecordText.Unquote(name, unq);
							name.Set(unq);
						}
						String.NewOrSet!(m.ExportName, name);
					}
				}
				if (m.ExportName != null)
				{
					bool cName = !m.ExportName.IsEmpty && !m.ExportName[0].IsDigit;
					for (let ch in m.ExportName.RawChars)
						cName &= ch.IsLetterOrDigit || ch == '_';
					if (d.Kind != .Function || !(m.Static || t.Static) || !m.Generics.IsEmpty || !t.Generics.IsEmpty || m.IsImport)
						Error("T1076", c.Site, "", "", scope $"[Export] belongs on a static function that is not generic ({d.Name} is not one)", .Declare);
					else if (!cName)
						Error("T1076", c.Site, "", "", scope $"[Export] name '{m.ExportName}' is not a C name (letters, digits and _)", .Declare);
				}
				if (u.IsCDecl && d.Kind == .Function)
				{
					m.IsImport = true;
					if (m.ImportLib == null)
						m.ImportLib = new String((t.ImportLib != null) ? (StringView)t.ImportLib : "");
					if (m.ImportName == null)
						m.ImportName = new String(d.Name);
					if (m.CallConv == null)
						m.CallConv = new String("cdecl");
					if (InWordList(u.Set.Pure, d.Name))
						m.Pure = true;
				}
				if (!u.IsCDecl)
					NeedTypes(d, c);
				switch (d.Kind)
				{
				case .Field:
					m.Type = Resolve(d.Type, c) ?? Table.Error;
					if (m.Type.IsVoid)
						Error("T1020", c.Site, "", "", scope $"the field {d.Name} cannot be void", .Declare);
					if ((m.Ownership == .Owned || m.Ownership == .Appended) && !m.Type.IsError && !m.Type.IsReference)
						Error("T1021", c.Site, "", "", scope $"the field {d.Name} is a value ({TypeTable.Show(m.Type, .. scope .())}): only references can be owned or appended", .Declare);
					if (m.Ownership == .Pointer && !m.Type.IsPointer && !m.Type.IsError)
						Error("T1022", c.Site, "", "", scope $"the field {d.Name} is not a pointer", .Declare);
					if (t.Kind == .Interface)
						Error("T1023", c.Site, "", "", "an interface has no fields", .Declare);
					for (let a in d.Attrs)
						if (a.Name == "Event")
							DeclareEvent(m, t, c);
				case .Case:
					if (t.Kind != .Enum)
						Error("T1024", c.Site, "", "", scope $"the case {d.Name} belongs in an enum", .Declare);
					for (let pd in d.Payload)
					{
						let pt = Resolve(pd.Type, c) ?? Table.Error;
						if (pt.IsVoid)
							continue;
						ParamSym p = new .();
						p.Name.Set(pd.Name);
						p.Type = pt;
						m.Payload.Add(p);
						t.HasPayload = true;
					}
					if (d.CaseValue != null)
					{
						if (int64.Parse(d.CaseValue) case .Ok(let v))
							nextCase = v;
						else
							Error("T1025", c.Site, "", "", scope $"the value of the case {d.Name} is not a number", .Declare);
					}
					m.CaseValue = nextCase++;
					m.Static = true;
				case .Property:
					m.Type = Resolve(d.Type, c) ?? Table.Error;
					m.HasGet = HasSheet(u.Doc, d, .Get) || d.Auto;
					m.HasSet = HasSheet(u.Doc, d, .Set) || d.Auto;
					m.Pure = true;
				case .Function, .Operator, .Ctor, .Dtor:
					m.Returns = ((d.Kind == .Function || d.Kind == .Operator) ? Resolve(d.Returns, c) : null) ?? Table.Void;
					for (let pd in d.Params)
					{
						ParamSym p = new .();
						p.Name.Set(pd.Name);
						p.Type = Resolve(pd.Type, c) ?? Table.Error;
						p.Mode = (pd.Mode == .Unset) ? .Value : pd.Mode;
						if (pd.Default != null)
							p.Default = new String(pd.Default);
						if (p.Type.IsVoid)
							Error("T1026", c.Site, "", "", scope $"the parameter {pd.Name} cannot be void", .Declare);
						if (p.Mode == .Out)
							m.Outs.Add(p);
						else
							m.Params.Add(p);
					}
					for (let od in d.Outs)
					{
						ParamSym p = new .();
						p.Name.Set(od.Name);
						p.Type = Resolve(od.Type, c) ?? Table.Error;
						p.Mode = .Out;
						m.Outs.Add(p);
					}
					m.HasBody = HasSheet(u.Doc, d, .Body);
					if (m.IsImport || m.ExportName != null)
						VectorRules.CheckCBoundary(this, m, c.Site); // VectorRules.bf: masks (T2302), System V 32-byte vectors (T3090)
					if (d.Kind == .Operator)
						m.Static = true;
					if (d.Kind == .Function && !m.HasBody && m.Intrinsic == null && !m.IsImport && !u.IsCDecl)
					{
						m.Abstract = true;
						if (!m.Static)
							m.Virtual = true;
					}
					if (m.Abstract && !m.Static)
						m.Virtual = true;
					if (t.Kind == .Interface && d.Kind == .Function)
					{
						m.Virtual = true;
						m.Abstract = !m.HasBody;
					}
					if ((m.Virtual || m.Override) && t.Kind == .Struct)
						Error("T1027", c.Site, "", "", scope $"{d.Name}: a struct has no virtual functions (its calls bind statically)", .Declare);
					if ((m.Virtual || m.Override) && m.Static && d.Kind == .Function)
						Error("T1028", c.Site, "", "", scope $"{d.Name}: a static function cannot be virtual", .Declare);
					if (m.Mutating && t.Kind != .Struct)
						Error("T1029", c.Site, "", "", scope $"{d.Name}: Mutating is for struct functions", .Declare);
					if (d.Kind == .Ctor && t.Kind == .Interface)
						Error("T1030", c.Site, "", "", "an interface has no constructors", .Declare);
					if (d.Kind == .Ctor && m.Static && !m.Params.IsEmpty)
						Error("T1032", c.Site, "", "", "a static constructor takes no inputs (it runs once, before Program Start)", .Declare);
				}
				if (ext != null)
					CheckExtensionMember(m, t, ext);
			}
			// Two members with the same name and parameters (an extension's against everything before them).
			for (int i < t.Members.Count)
			{
				let a = t.Members[i];
				for (int j = Math.Max(i + 1, firstNew); j < t.Members.Count; j++)
				{
					let b = t.Members[j];
					if (a.Name != b.Name || a.Kind != b.Kind || a.Static != b.Static)
						continue;
					bool same = true;
					if (a.IsCallable)
					{
						same = a.Params.Count == b.Params.Count;
						for (int k = 0; same && k < a.Params.Count; k++)
							same = a.Params[k].Type == b.Params[k].Type;
					}
					if (same)
						Error("T1031", SiteOf(ext ?? t, b.Id), "", "", scope $"{t.Name} already has {b.GetSignature(.. scope .())}", .Declare);
				}
			}
			if (!u.IsCDecl)
			{
				let before = t.Members.Count;
				DeclareHiddenFields(u, t, ext);
				if (ext != null && t.Members.Count > before && !OwnsExtended(ext, t))
				{
					for (int i = before; i < t.Members.Count; i++)
						t.Members[i].Extension = ext;
					Error("T1071", SiteOf(ext), "", "", scope $"an auto property or a stateful node (Gate, Do Once...) of this extension needs a hidden field, and an extension adds fields only to a type of its own project ({WhoseType(t, .. scope .())})", .Declare);
				}
				else if (ext != null)
					for (int i = before; i < t.Members.Count; i++)
						t.Members[i].Extension = ext;
			}
		}

		/// The hidden field that keeps a Gate / Do Once / Do N / Flip Flop / Multi Gate's state
		/// (Language.md 5.1): `__gate_<node>`, `__doOnce_<node>`, `__doN_<node>`, `__flipFlop_<node>`,
		/// `__multiGate_<node>`; `__multiGateSeed_<node>` for a random Multi Gate.
		public static void StateFieldName(NodeKind kind, StringView node, String outName)
		{
			switch (kind)
			{
			case .Gate, .GateOpen, .GateClose, .GateToggle: outName.Append("__gate_");
			case .DoOnce, .ResetDoOnce: outName.Append("__doOnce_");
			case .DoN, .ResetDoN: outName.Append("__doN_");
			case .FlipFlop: outName.Append("__flipFlop_");
			default: outName.Append("__multiGate_");
			}
			outName.Append(node);
		}

		/// The state's type: a bool (Gate: open; Do Once: done; Flip Flop: A ran last) or an int
		/// (Do N: runs so far; Multi Gate: the next output, or the outputs run as bits when random).
		public KType StateType(NodeKind kind) => (kind == .DoN || kind == .MultiGate || kind == .ResetDoN || kind == .ResetMultiGate) ? Table.Int : Table.Bool;

		MemberSym AddHiddenField(TypeSym t, StringView name, KType type, bool isStatic, StringView init)
		{
			MemberSym f = new .();
			f.Kind = .Field;
			f.Name.Set(name);
			f.Owner = t;
			f.Type = type;
			f.Static = isStatic;
			f.Access = .Private;
			f.Synthetic = true;
			if (!init.IsEmpty)
				f.Init = new String(init);
			t.Members.Add(f);
			return f;
		}

		/// Fields the compiler makes: an auto property's (`__prop_<Name>`, Language.md 4) and the
		/// state of the stateful flow nodes that name no field of their own (`set state`).
		void DeclareHiddenFields(SourceUnit u, TypeSym t, TypeSym ext = null)
		{
			List<MemberSym> autos = scope .();
			for (let m in t.Members)
				if (m.Kind == .Property && m.Auto && m.Extension == ext)
					autos.Add(m);
			for (let m in autos)
			{
				if (t.Kind == .Interface)
				{
					Error("T1033", SiteOf(t, m.Id), "", "", scope $"{m.Name}: an interface property has no storage (it cannot be auto)", .Declare);
					continue;
				}
				let f = AddHiddenField(t, scope $"__prop_{m.Name}", m.Type, m.Static || t.Static, "");
				f.AutoOf = m;
			}
			for (let s in u.Doc.Sheets)
			{
				let owner = MemberOf(t, s.Member);
				if (owner == null)
					continue;
				let isStatic = owner.Static || t.Static;
				for (let n in s.Graph.Nodes)
				{
					if (!NodeKinds.IsStateful(n.Kind) || n.Disabled)
						continue;
					if (n.Kind == .MultiGate && n.HasSetting("random"))
						AddHiddenField(t, scope $"__multiGateSeed_{n.Key}", Table.Prim("uint"), true, "88172645463325252");
					if (n.HasSetting("state"))
						continue;
					// A struct's value would carry it: only static functions of a struct keep hidden state (Bind says so).
					if (t.Kind == .Struct && !isStatic)
						continue;
					String name = scope .();
					StateFieldName(n.Kind, n.Key, name);
					StringView init = "";
					if (n.Kind == .Gate)
						init = n.HasSetting("start-closed") ? "false" : "true";
					AddHiddenField(t, name, StateType(n.Kind), isStatic, init);
				}
			}
		}

		bool SameParams(MemberSym a, MemberSym b, Dictionary<GenericParamSym, KType> bMap)
		{
			if (a.Params.Count != b.Params.Count)
				return false;
			for (int i < a.Params.Count)
				if (a.Params[i].Type != Table.Subst(b.Params[i].Type, bMap) || a.Params[i].Mode != b.Params[i].Mode)
					return false;
			return true;
		}

		void Layout(TypeSym t)
		{
			if (t.LayoutState == 2)
				return;
			if (t.LayoutState == 1)
				return; // a base cycle, reported by CheckBaseCycle
			t.LayoutState = 1;
			let b = t.BaseSym;
			Dictionary<GenericParamSym, KType> baseMap = scope .();
			if (b != null)
			{
				Layout(b);
				Table.MapOf(t.Base, baseMap);
				for (let f in b.AllFields)
					t.AllFields.Add(f);
				for (let v in b.VTable)
					t.VTable.Add(v);
			}
			for (let m in t.Members)
			{
				if (m.Kind == .Field && !m.Static && !m.Const)
				{
					m.FieldIndex = (int32)t.AllFields.Count;
					t.AllFields.Add(m);
				}
			}
			if (t.Kind == .Class)
			{
				for (let m in t.Members)
				{
					if (m.Kind != .Function || m.Static)
						continue;
					int slot = -1;
					for (int i < t.VTable.Count)
					{
						let v = t.VTable[i];
						if (v.Name == m.Name && SameParams(m, v, baseMap))
							slot = i;
					}
					if (m.Override)
					{
						if (slot < 0)
						{
							Error("T1040", SiteOf(t, m.Id), "", "", scope $"{m.GetSignature(.. scope .())} overrides nothing: no base class has a virtual {m.GetSignature(.. scope .())}", .Declare);
							m.Override = false;
							m.Virtual = true;
							m.VSlot = (int32)t.VTable.Count;
							t.VTable.Add(m);
							continue;
						}
						let old = t.VTable[slot];
						if (old.Sealed)
							Error("T1041", SiteOf(t, m.Id), "", "", scope $"{old.Owner.FullName}.{old.Name} is sealed: it cannot be overridden", .Declare);
						if (Table.Subst(old.Returns, baseMap) != m.Returns)
							Error("T1042", SiteOf(t, m.Id), "", "", scope $"{m.Name} must return {TypeTable.Show(Table.Subst(old.Returns, baseMap), .. scope .())} like the function it overrides", .Declare);
						m.Overrides = old;
						m.Virtual = true;
						m.VSlot = (int32)slot;
						t.VTable[slot] = m;
					}
					else if (m.Virtual)
					{
						if (slot >= 0)
							Warning("T1043", SiteOf(t, m.Id), "", "", scope $"{m.GetSignature(.. scope .())} hides the base class's virtual function: mark it Override to replace it", .Declare);
						m.VSlot = (int32)t.VTable.Count;
						t.VTable.Add(m);
					}
				}
				for (let v in t.VTable)
					if (v.Abstract && !v.HasBody)
						t.Abstract = true;
				// A class not marked Abstract must override every abstract function of its bases
				// (the editor lists them under Required overrides).
				if (t.Decl != null && !t.Decl.Abstract)
					for (let v in t.VTable)
						if (v.Abstract && !v.HasBody && v.Owner != t)
							Error("T1053", SiteOf(t), "", "", scope $"{t.Name} does not override {v.Owner.Name}.{v.GetSignature(.. scope .())}, which is abstract: implement it (Outline > Required overrides) or mark {t.Name} Abstract", .Declare);
			}
			if (t.Kind == .Interface)
			{
				for (let it in t.Interfaces)
				{
					Layout(it.Sym);
					for (let s in it.Sym.ISlots)
						if (!t.ISlots.Contains(s))
							t.ISlots.Add(s);
				}
				for (let m in t.Members)
				{
					if (m.Kind != .Function || m.Static)
						continue;
					m.ISlot = (int32)t.ISlots.Count;
					t.ISlots.Add(m);
				}
			}
			t.LayoutState = 2;
		}

		/// The function of `t` (or its bases) that implements the interface member `im` of the
		/// interface instance `iface`, or null.
		public MemberSym FindImplementation(TypeSym t, MemberSym im, KType iface)
		{
			Dictionary<GenericParamSym, KType> map = scope .();
			Table.MapOf(iface, map);
			var c = t;
			int guard = 0;
			while (c != null && guard++ < 64)
			{
				for (let m in c.Members)
				{
					if (m.Kind != .Function || m.Static || m.Name != im.Name || m.Params.Count != im.Params.Count)
						continue;
					bool same = Table.Subst(im.Returns, map) == m.Returns;
					for (int i = 0; same && i < m.Params.Count; i++)
						same = Table.Subst(im.Params[i].Type, map) == m.Params[i].Type;
					if (same)
						return m;
				}
				c = c.BaseSym;
			}
			return null;
		}

		void AllInterfaces(KType t, List<KType> outIfaces)
		{
			List<KType> own = scope .();
			Table.InterfacesOf(t, own);
			for (let i in own)
			{
				if (!outIfaces.Contains(i))
					outIfaces.Add(i);
				AllInterfaces(i, outIfaces);
			}
		}

		void CheckInterfaces(TypeSym t)
		{
			if (t.Kind != .Class && t.Kind != .Struct)
				return;
			List<KType> ifaces = scope .();
			AllInterfaces(t.Self, ifaces);
			for (let i in ifaces)
			{
				for (let im in i.Sym.ISlots)
				{
					if (im.HasBody)
						continue;
					if (FindImplementation(t, im, i) == null)
						Error("T1050", SiteOf(t), "", "", scope $"{t.Name} does not implement {TypeTable.Show(i, .. scope .())}.{im.GetSignature(.. scope .())} (Type Settings > Problems > Implement Missing Members)", .Declare);
				}
			}
		}

		void CheckCtorChains(TypeSym t)
		{
			if (t.Kind != .Class || t.Static)
				return;
			let b = t.BaseSym;
			if (b == null)
				return;
			List<MemberSym> baseCtors = scope .();
			b.GetCtors(baseCtors);
			bool baseNeedsArgs = !baseCtors.IsEmpty;
			for (let bc in baseCtors)
				if (bc.Params.IsEmpty)
					baseNeedsArgs = false;
			if (!baseNeedsArgs)
				return;
			List<MemberSym> own = scope .();
			t.GetCtors(own);
			if (own.IsEmpty)
				Error("T1051", SiteOf(t), "", "", scope $"{t.Name} needs a constructor: its base {b.Name} has no constructor without parameters", .Declare);
			for (let c in own)
				if (c.Chain == .None)
					Error("T1052", SiteOf(t, c.Id), "", "", scope $"this constructor must chain to a constructor of {b.Name} (Base Constructor): {b.Name} has none without parameters", .Declare);
		}

		void CheckEntryPoint()
		{
			if (Project == null || Project.Entry == null || Project.Entry.IsNone)
				return;
			String name = scope .();
			Project.Entry.ToString(name);
			let t = Table.Find(name);
			if (t == null)
			{
				Error("T1060", .(""), "", "", scope $"the project's entry type {name} is not in the project", .Declare);
				return;
			}
			for (let m in t.Members)
			{
				if (m.Kind != .Function || m.Name != "Main")
					continue;
				bool argsOk = m.Params.IsEmpty || (m.Params.Count == 1 && m.Params[0].Type.Kind == .Array && m.Params[0].Type.Element.IsNamed && m.Params[0].Type.Element.Sym == Table.StringSym);
				bool retOk = m.Returns.IsVoid || m.Returns == Table.Int || m.Returns == Table.Int32;
				if (!m.Static || !argsOk || !retOk)
					Error("T1061", SiteOf(t, m.Id), "", "", "Program Start is a static Main with no parameters or Args : String[], returning int or nothing", .Declare);
				return;
			}
			Error("T1062", SiteOf(t), "", "", scope $"the entry type {name} has no static Main (Program Start)", .Declare);
		}
	}
}
