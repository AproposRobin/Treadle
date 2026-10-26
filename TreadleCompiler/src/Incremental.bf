using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Compiler
{
	extension Compilation
	{
		/// Binds and checks one Sheet again after an edit inside it (incremental Validate). Its
		/// old result and its Bind / Check diagnostics are dropped first. Valid only while the
		/// type table still holds: no declaration of any type changed (DeclSignature).
		public void Rebind(SourceUnit u, Sheet s)
		{
			int at = -1;
			if (Results.GetAndRemove(s) case .Ok(let kv))
			{
				at = ResultList.IndexOf(kv.value);
				if (at >= 0)
					ResultList.RemoveAt(at);
				delete kv.value;
			}
			if (u.Sym != null)
			{
				for (int i = Diags.Items.Count - 1; i >= 0; i--)
				{
					let d = Diags.Items[i];
					if ((d.Stage == .Bind || d.Stage == .Check) && d.Type == u.Sym.FullName && d.Sheet == s.Key)
					{
						Diags.Items.RemoveAt(i);
						delete d;
					}
				}
			}
			if (s.Member == null)
				return;
			let r = BindSheet(u, s);
			if (r == null)
				return;
			CheckSheet(r);
			// Keep the Sheets in file order (the services and Problems list them so).
			if (at >= 0 && at < ResultList.Count - 1)
			{
				ResultList.PopBack();
				ResultList.Insert(at, r);
			}
		}
	}

	/// Declaration-level incremental Validate (Compiler.md 9): the types whose declaration changed
	/// are declared again in place (their symbols keep their identity, so the interned types that
	/// name them stay valid), with their dependents; then only the Sheets that can see a difference
	/// are bound and checked again. Anything this does not cover returns false and the caller
	/// compiles the workspace from scratch (the compilation is then thrown away).
	extension Compilation
	{
		/// After this many replaced members the next declaration change compiles everything (the
		/// replaced symbols are kept until the compilation goes).
		const int MaxDeadMembers = 50000;

		static bool IsProjectUnit(SourceUnit u) => !u.IsCore && !u.IsCDecl;
		static bool IsProjectType(TypeSym t) => t != null && !t.IsCore && !t.IsCImport && !t.IsCRecord;

		/// `changed`: units whose declaration changed (their Doc is the document as it is now, maybe a
		/// different object than before); `added`: new units already in Units (no symbol yet);
		/// `edited`: Sheets edited inside (of units not in `changed`). The units are in the order a
		/// full compile would read them. False: a full compile is needed.
		public bool Redeclare(List<SourceUnit> changed, List<SourceUnit> added, List<Sheet> edited, out int outTypes, out int outSheets)
		{
			outTypes = 0;
			outSheets = 0;
			if (!Declared || DeadMembers.Count > MaxDeadMembers)
				return false;

			// 1. What a re-declare in place covers: no type renamed, removed, duplicated, or in a new
			//    namespace (those change name lookup everywhere).
			HashSet<String> names = scope .();
			HashSet<String> newTypeNames = scope .();
			defer { ClearAndDeleteItems!(names); ClearAndDeleteItems!(newTypeNames); }
			void Name(HashSet<String> set, StringView n)
			{
				if (!n.IsEmpty && !set.ContainsAlt(n))
					set.Add(new String(n));
			}
			for (let u in changed)
			{
				if (!IsProjectUnit(u) || u.Sym == null || u.Doc.Header.Name.IsEmpty || Table.Find(u.Sym.FullName) != u.Sym)
					return false;
				String full = scope .();
				u.Doc.Header.GetFullName(full);
				if (full != u.Sym.FullName)
					return false;
				Name(names, u.Sym.Name);
				let owner = (u.Sym.Kind == .Extension) ? u.Sym.Extends : u.Sym;
				if (owner != null)
					for (let m in owner.Members)
						if (owner == u.Sym || m.Extension == u.Sym)
							Name(names, m.Name);
				for (let m in u.Doc.Members)
					Name(names, m.Name);
			}
			for (let u in added)
			{
				let h = u.Doc.Header;
				if (!IsProjectUnit(u) || u.Sym != null || h.Name.IsEmpty)
					return false;
				String full = scope .();
				h.GetFullName(full);
				if (Table.Find(full) != null || newTypeNames.ContainsAlt(full) || (!h.Namespace.IsEmpty && !Table.IsNamespace(h.Namespace)))
					return false;
				newTypeNames.Add(new String(full));
				Name(names, h.Name);
				for (let m in u.Doc.Members)
					Name(names, m.Name);
			}
			// newTypeNames held full names for the duplicate test; the dependents match plain names.
			ClearAndDeleteItems!(newTypeNames);
			for (let u in added)
				Name(newTypeNames, u.Doc.Header.Name);

			Dictionary<TypeSym, SourceUnit> unitOf = scope .();
			List<TypeSym> projectTypes = scope .();
			for (let u in Units)
				if (IsProjectUnit(u) && u.Sym != null)
				{
					unitOf[u.Sym] = u;
					projectTypes.Add(u.Sym);
				}

			// 2. The types to declare again: the changed ones; an extension's target (and a changed
			//    extension's new target, found by name); every type whose declaration names a changed
			//    type, or a new type's name; then, transitively, the classes and interfaces that derive
			//    from one, and the extensions of one (their members live in the extended type).
			HashSet<TypeSym> redo = scope .();
			HashSet<TypeSym> changedSyms = scope .();
			List<TypeSym> spliced = scope .();
			for (let u in changed)
			{
				redo.Add(u.Sym);
				changedSyms.Add(u.Sym);
				let x = u.Sym.Extends;
				if (x != null)
				{
					if (IsProjectType(x))
						redo.Add(x);
					else if (!spliced.Contains(x))
						spliced.Add(x);
				}
			}
			for (let u in changed)
				ExtendsByName(u.Doc, projectTypes, redo);
			for (let u in added)
				ExtendsByName(u.Doc, projectTypes, redo);
			for (let y in projectTypes)
			{
				if (redo.Contains(y))
					continue;
				if (DeclMentions(y, changedSyms) || (!newTypeNames.IsEmpty && DocMentions(unitOf[y].Doc, newTypeNames)))
					redo.Add(y);
			}
			bool grew = true;
			while (grew)
			{
				grew = false;
				for (let y in projectTypes)
				{
					if (redo.Contains(y))
						continue;
					bool dep = (y.BaseSym != null && redo.Contains(y.BaseSym)) || (y.Extends != null && redo.Contains(y.Extends));
					for (let i in y.Interfaces)
						dep |= i.Kind == .Named && redo.Contains(i.Sym);
					if (y.Extensions != null)
						for (let e in y.Extensions)
							dep |= redo.Contains(e);
					if (dep)
					{
						redo.Add(y);
						grew = true;
					}
				}
			}
			// A type of the core library or a C record keeps its own members: a changed extension's
			// members are taken out and declared again (only when it is that type's one extension and
			// adds no fields or virtual functions, which would change the layout of every user).
			// The core's own extensions (MathFormat's String.Append overloads) never change during a
			// session and stay where they are.
			for (let x in spliced)
			{
				if (x.Extensions != null)
					for (let e in x.Extensions)
						if (!redo.Contains(e) && !e.IsCore)
							return false;
				for (let m in x.Members)
					if (m.Extension != null && redo.Contains(m.Extension) && (m.Kind == .Field || m.Virtual))
						return false;
			}

			// 3. The Sheets to bind again: those of the re-declared and new types, the edited ones, the
			//    ones whose bound result refers to a re-declared type or a member of one, and the ones
			//    that name a changed or new type or member (a name that did not resolve may now). A
			//    document with Lambda Sheets binds whole (a Lambda Sheet binds with its node).
			HashSet<SourceUnit> redoUnits = scope .();
			for (let u in Units)
				if (IsProjectUnit(u) && ((u.Sym != null && redo.Contains(u.Sym)) || added.Contains(u)))
					redoUnits.Add(u);
			HashSet<Sheet> sheets = scope .();
			for (let u in redoUnits)
				for (let s in u.Doc.Sheets)
					sheets.Add(s);
			for (let s in edited)
				sheets.Add(s);
			for (let r in ResultList)
				if (!redoUnits.Contains(r.Unit) && !sheets.Contains(r.Sheet) && Refers(r, redo))
					sheets.Add(r.Sheet);
			for (let u in Units)
			{
				if (!IsProjectUnit(u) || u.Sym == null || redoUnits.Contains(u))
					continue;
				for (let s in u.Doc.Sheets)
					if (!sheets.Contains(s) && SheetMentions(s, names))
						sheets.Add(s);
			}
			for (let u in Units)
			{
				if (!IsProjectUnit(u))
					continue;
				bool any = false;
				bool lambda = false;
				for (let s in u.Doc.Sheets)
				{
					any |= sheets.Contains(s);
					lambda |= s.Role == .Lambda;
				}
				if (any && lambda)
					for (let s in u.Doc.Sheets)
						sheets.Add(s);
			}

			// 4. Drop the old results and diagnostics. A re-declared unit's Sheets may belong to a
			//    document that is gone (replaced), so its diagnostics are found by the type's name.
			HashSet<String> redoNames = scope .();
			defer { ClearAndDeleteItems!(redoNames); }
			for (let t in redo)
				Name(redoNames, t.FullName);
			List<(String type, String sheet)> dropped = scope .();
			defer { for (let d in dropped) { delete d.type; delete d.sheet; } }
			for (int i = ResultList.Count - 1; i >= 0; i--)
			{
				let r = ResultList[i];
				let gone = redoUnits.Contains(r.Unit);
				if (!gone && !sheets.Contains(r.Sheet))
					continue;
				if (!gone)
					dropped.Add((new String(r.SiteType), new String(r.Sheet.Key)));
				ResultList.RemoveAt(i);
				for (let kv in Results)
					if (kv.value == r)
					{
						@kv.Remove();
						break;
					}
				delete r;
			}
			for (int i = Diags.Items.Count - 1; i >= 0; i--)
			{
				let d = Diags.Items[i];
				if (d.Stage == .Load)
					continue;
				bool drop = redoNames.ContainsAlt(d.Type) || d.Code == "T1060" || d.Code == "T1061" || d.Code == "T1062";
				for (let k in dropped)
					drop |= d.Type == k.type && d.Sheet == k.sheet;
				if (drop)
				{
					Diags.Items.RemoveAt(i);
					delete d;
				}
			}

			// 5. Empty the symbols (the members and generic parameters are kept aside, see DeadMembers)
			//    and declare them again in the order Declare does.
			HashSet<MemberSym> dead = scope .();
			for (let x in spliced)
			{
				for (int i = x.Members.Count - 1; i >= 0; i--)
				{
					let m = x.Members[i];
					if (m.Extension != null && redo.Contains(m.Extension))
					{
						x.Members.RemoveAt(i);
						dead.Add(m);
						DeadMembers.Add(m);
					}
				}
				if (x.Extensions != null)
					x.Extensions.RemoveAll(scope (e) => redo.Contains(e));
			}
			for (let t in redo)
				ResetType(t, dead);
			for (int i = Instances.Entries.Count - 1; i >= 0; i--)
			{
				let e = Instances.Entries[i];
				if (e.Function != null && dead.Contains(e.Function))
				{
					Instances.Entries.RemoveAt(i);
					delete e;
				}
			}
			for (let u in Units)
				if (u.Sym != null && redo.Contains(u.Sym))
					FillType(u, u.Sym);
			for (let u in added)
			{
				DeclareType(u);
				if (u.Sym == null)
					return false;
				redo.Add(u.Sym);
			}
			List<SourceUnit> order = scope .();
			for (let u in Units)
				if (u.Sym != null && redo.Contains(u.Sym))
					order.Add(u);
			for (let u in order)
				DeclareHeader(u.Sym);
			for (let u in order)
			{
				let x = u.Sym.Extends;
				if (u.Sym.Kind != .Extension || x == null || redo.Contains(x))
					continue;
				// A target found only now: a project type must have been re-declared with it.
				if (IsProjectType(x))
					return false;
				for (let e in x.Extensions)
					if (e != u.Sym && !e.IsCore)
						return false;
				for (let m in x.Members)
					if (m.Extension != null && m.Extension != u.Sym && !m.Extension.IsCore)
						return false;
			}
			for (let u in order)
				CheckBaseCycle(u.Sym);
			for (let u in order)
				if (u.Sym.Kind != .Extension)
					DeclareMembers(u, u.Sym);
			for (let u in order)
				if (u.Sym.Kind == .Extension && u.Sym.Extends != null)
				{
					let x = u.Sym.Extends;
					DeclareMembers(u, x, u.Sym);
					if (!redo.Contains(x))
						for (let m in x.Members)
							if (m.Extension == u.Sym && (m.Kind == .Field || m.Virtual))
								return false;
				}
			for (let u in order)
				Layout(u.Sym);
			FoldConstants();
			for (let u in order)
			{
				CheckInterfaces(u.Sym);
				CheckCtorChains(u.Sym);
			}
			CheckEntryPoint();
			outTypes = order.Count;

			// 6. Bind and check the Sheets again, in file order.
			for (let u in Units)
			{
				if (u.Sym == null || !IsProjectUnit(u))
					continue;
				for (let s in u.Doc.Sheets)
				{
					if (s.Member == null || !sheets.Contains(s))
						continue;
					var r = ResultOf(s);
					if (r == null)
					{
						r = BindSheet(u, s);
						if (r != null)
							outSheets++;
					}
					if (r != null && !r.Checked)
						CheckSheet(r);
				}
			}
			// The Sheets in file order again (the services and Problems list them so).
			List<SheetResult> sorted = scope .(ResultList.Count);
			HashSet<SheetResult> placed = scope .();
			for (let u in Units)
			{
				if (u.Sym == null || u.IsCDecl)
					continue;
				for (let s in u.Doc.Sheets)
				{
					let r = ResultOf(s);
					if (r != null && placed.Add(r))
						sorted.Add(r);
				}
			}
			for (let r in ResultList)
				if (placed.Add(r))
					sorted.Add(r);
			ResultList.Clear();
			ResultList.AddRange(sorted);
			return true;
		}

		/// Takes a symbol back to what DeclareType's `new` gives (its name stays); the old members and
		/// generic parameters go to DeadMembers / DeadGenerics.
		void ResetType(TypeSym t, HashSet<MemberSym> dead)
		{
			for (let m in t.Members)
			{
				dead.Add(m);
				DeadMembers.Add(m);
			}
			t.Members.Clear();
			for (let g in t.Generics)
				DeadGenerics.Add(g);
			t.Generics.Clear();
			t.Interfaces.Clear();
			t.AllFields.Clear();
			t.VTable.Clear();
			t.ISlots.Clear();
			ClearAndDeleteItems!(t.Uses);
			t.Base = null;
			t.Underlying = null;
			t.Signature = null;
			t.Self = null;
			t.HasPayload = false;
			t.LayoutState = 0;
			t.Extends = null;
			DeleteAndNullify!(t.Extensions);
			t.CRepr = false;
			t.Flags = false;
			t.Static = false;
			t.Abstract = false;
			t.Sealed = false;
		}

		/// Adds the project types a changed extension's `extends` line may name (by its last name).
		static void ExtendsByName(TypeDocument doc, List<TypeSym> projectTypes, HashSet<TypeSym> into)
		{
			let h = doc.Header;
			if (h.Kind != .Extension || h.Extends == null || h.Extends.Name.IsEmpty)
				return;
			StringView name = h.Extends.Name;
			let lt = name.IndexOf('<');
			if (lt >= 0)
				name = name.Substring(0, lt);
			let dot = name.LastIndexOf('.');
			if (dot >= 0)
				name = name.Substring(dot + 1);
			for (let t in projectTypes)
				if (t.Name == name)
					into.Add(t);
		}

		/// `t` names a type of `set` (generic arguments, elements, signatures and the owners of
		/// generic parameters included).
		static bool Mentions(KType t, HashSet<TypeSym> set, int depth = 0)
		{
			if (t == null || depth > 24)
				return false;
			switch (t.Kind)
			{
			case .Named:
				if (set.Contains(t.Sym))
					return true;
			case .Param:
				let p = t.Param;
				return p != null && ((p.OwnerType != null && set.Contains(p.OwnerType)) || (p.OwnerMember != null && set.Contains(p.OwnerMember.Owner)));
			default:
			}
			for (let a in t.Args)
				if (Mentions(a, set, depth + 1))
					return true;
			return Mentions(t.Element, set, depth + 1);
		}

		static bool MemberIn(MemberSym m, HashSet<TypeSym> set) => m != null && (set.Contains(m.Owner) || (m.Extension != null && set.Contains(m.Extension)));

		static bool ParamsMention(List<ParamSym> ps, HashSet<TypeSym> set)
		{
			for (let p in ps)
				if (Mentions(p.Type, set))
					return true;
			return false;
		}

		static bool GenericsMention(List<GenericParamSym> gs, HashSet<TypeSym> set)
		{
			for (let g in gs)
			{
				if (Mentions(g.ConstType, set))
					return true;
				for (let c in g.TypeConstraints)
					if (Mentions(c, set))
						return true;
			}
			return false;
		}

		/// The declaration of `t` (header, members' signatures) names a type of `set`.
		static bool DeclMentions(TypeSym t, HashSet<TypeSym> set)
		{
			if (Mentions(t.Base, set) || Mentions(t.Underlying, set) || Mentions(t.Signature, set) || Mentions(t.AliasOf, set) || GenericsMention(t.Generics, set))
				return true;
			if (t.Extends != null && set.Contains(t.Extends))
				return true;
			for (let i in t.Interfaces)
				if (Mentions(i, set))
					return true;
			for (let m in t.Members)
			{
				if (Mentions(m.Type, set) || Mentions(m.Returns, set) || Mentions(m.EventOf, set) || ParamsMention(m.Params, set) ||
					ParamsMention(m.Outs, set) || ParamsMention(m.Payload, set) || GenericsMention(m.Generics, set))
					return true;
				for (let n in m.Narrowings)
					for (let c in n.TypeConstraints)
						if (Mentions(c, set))
							return true;
				// a constant whose init names another type's constants is folded again with them
				if (m.ConstRefs != null)
					for (let x in m.ConstRefs)
						if (set.Contains(x))
							return true;
			}
			return false;
		}

		/// A Math Expression's functions, operators and fields belong to a type of `set`.
		static bool MathMentions(MathNode n, HashSet<TypeSym> set)
		{
			if (n == null)
				return false;
			if (MemberIn(n.Member, set) || Mentions(n.Type, set) || Mentions(n.Operand, set) || Mentions(n.Owner, set))
				return true;
			if (n.Fields != null)
				for (let f in n.Fields)
					if (MemberIn(f.field, set) || Mentions(f.owner, set))
						return true;
			for (let a in n.Args)
				if (MathMentions(a, set))
					return true;
			return false;
		}

		/// A bound Sheet refers to a type of `set` or a member of one (its nodes' members, subjects,
		/// pin types, generic maps).
		static bool Refers(SheetResult r, HashSet<TypeSym> set)
		{
			if (set.Contains(r.Type) || (r.Scope != null && set.Contains(r.Scope)) || MemberIn(r.Member, set) || Mentions(r.This, set) ||
				Mentions(r.Returns, set) || Mentions(r.LambdaType, set) || ParamsMention(r.LambdaParams, set))
				return true;
			for (let c in r.Captures)
				if (Mentions(c.Type, set))
					return true;
			for (let b in r.Nodes)
			{
				if (MemberIn(b.Member, set) || MemberIn(b.Case, set) || MemberIn(b.EnumMove, set) || MemberIn(b.EnumCurrent, set) || MemberIn(b.StateSeed, set) ||
					Mentions(b.Subject, set) || Mentions(b.Owner, set) || Mentions(b.OperandType, set) || Mentions(b.EnumType, set) ||
					(b.ParamVar != null && Mentions(b.ParamVar.Type, set)))
					return true;
				if (b.Map != null)
					for (let kv in b.Map)
						if ((kv.key.OwnerType != null && set.Contains(kv.key.OwnerType)) || Mentions(kv.value, set))
							return true;
				if (b.MethodArgs != null)
					for (let a in b.MethodArgs)
						if (Mentions(a, set))
							return true;
				if (b.ConstRefs != null)
					for (let m in b.ConstRefs)
						if (MemberIn(m, set))
							return true;
				if (MathMentions(b.MathTree, set))
					return true;
				for (let i in b.Ins)
					if (Mentions(i.Type, set))
						return true;
				for (let o in b.Outs)
					if (Mentions(o.Type, set))
						return true;
			}
			return false;
		}

		/// `text` holds a word of `names` (identifiers: letters, digits, `_`).
		static bool TextMentions(StringView text, HashSet<String> names)
		{
			int start = -1;
			for (int i <= text.Length)
			{
				let c = (i < text.Length) ? text[i] : ' ';
				let word = c.IsLetterOrDigit || c == '_';
				if (word && start < 0)
					start = i;
				else if (!word && start >= 0)
				{
					if (names.ContainsAlt(text.Substring(start, i - start)))
						return true;
					start = -1;
				}
			}
			return false;
		}

		static bool RefMentions(TypeRef t, HashSet<String> names)
		{
			if (t == null)
				return false;
			return TextMentions(t.ToString(.. scope String()), names);
		}

		static bool ParamDeclsMention(List<ParamDecl> ps, HashSet<String> names)
		{
			for (let p in ps)
				if (RefMentions(p.Type, names))
					return true;
			return false;
		}

		static bool GenericDeclsMention(List<GenericParam> gs, HashSet<String> names)
		{
			for (let g in gs)
			{
				if (RefMentions(g.ConstType, names))
					return true;
				for (let k in g.Constraints)
					if (RefMentions(k.Type, names))
						return true;
			}
			return false;
		}

		/// The type file's declaration (header and member signatures) names one of `names`.
		static bool DocMentions(TypeDocument doc, HashSet<String> names)
		{
			let h = doc.Header;
			if (RefMentions(h.Base, names) || RefMentions(h.Extends, names) || RefMentions(h.Underlying, names) || RefMentions(h.Signature, names) ||
				GenericDeclsMention(h.Generics, names))
				return true;
			for (let i in h.Implements)
				if (RefMentions(i, names))
					return true;
			for (let m in doc.Members)
				if (RefMentions(m.Type, names) || RefMentions(m.Returns, names) || ParamDeclsMention(m.Params, names) || ParamDeclsMention(m.Outs, names) ||
					ParamDeclsMention(m.Payload, names) || GenericDeclsMention(m.Generics, names))
					return true;
			return false;
		}

		/// The Sheet names one of `names`: in a node's subject, settings or literal inputs, or in its
		/// member's inputs, outputs and local variables.
		static bool SheetMentions(Sheet s, HashSet<String> names)
		{
			let m = s.Member;
			if (m != null)
			{
				if (RefMentions(m.Type, names) || RefMentions(m.Returns, names) || ParamDeclsMention(m.Params, names) || ParamDeclsMention(m.Outs, names))
					return true;
				for (let l in m.Locals)
					if (RefMentions(l.Type, names))
						return true;
			}
			for (let n in s.Graph.Nodes)
			{
				if (TextMentions(n.Text, names))
					return true;
				for (let st in n.Settings)
					if (TextMentions(st.Value, names))
						return true;
				for (let p in n.Inputs)
					if (!p.Default.IsEmpty && TextMentions(p.Default, names))
						return true;
			}
			return false;
		}
	}

	/// What makes a type file's declaration (Compiler.md 9, incremental Validate): the header, the
	/// members with everything Declare reads, the Sheet list, and the stateful nodes whose hidden
	/// fields Declare makes. Two equal signatures mean the type table is unchanged, so only the
	/// edited Sheets need Bind and Check again.
	static class DeclSignature
	{
		struct Hasher
		{
			public uint64 H = 1469598103934665603UL;

			public void Mix(StringView s) mut
			{
				for (let c in s.RawChars)
				{
					H ^= (uint8)c;
					H *= 1099511628211UL;
				}
				H ^= 0xff;
				H *= 1099511628211UL;
			}

			public void Mix(int64 v) mut
			{
				H ^= (uint64)v;
				H *= 1099511628211UL;
			}

			public void Mix(bool b) mut => Mix(b ? 1 : 0);

			public void Mix(TypeRef t) mut
			{
				if (t == null)
					Mix("-");
				else
					Mix(t.ToString(.. scope String()));
			}

			public void Mix(String s) mut
			{
				if (s == null)
					Mix((StringView)"<null>");
				else
					Mix((StringView)s);
			}

			public void Attrs(List<AttrDecl> attrs) mut
			{
				Mix(attrs.Count);
				for (let a in attrs)
				{
					Mix(a.Name);
					for (let x in a.Args)
						Mix(x);
				}
			}

			public void Generics(List<GenericParam> gens) mut
			{
				Mix(gens.Count);
				for (let g in gens)
				{
					Mix(g.Name);
					Mix(g.IsConst);
					Mix(g.ConstType);
					for (let k in g.Constraints)
					{
						Mix((int)k.Kind);
						Mix(k.Type);
						Mix(k.Word);
					}
				}
			}

			public void Params(List<ParamDecl> ps) mut
			{
				Mix(ps.Count);
				for (let p in ps)
				{
					Mix(p.Name);
					Mix(p.Type);
					Mix((int)p.Mode);
					Mix(p.Default);
				}
			}
		}

		public static uint64 Of(TypeDocument doc)
		{
			Hasher h = .();
			let t = doc.Header;
			h.Mix(t.Name);
			h.Mix((int)t.Kind);
			h.Mix(t.Namespace);
			for (let u in t.Uses)
				h.Mix(u);
			h.Mix(t.Base);
			for (let i in t.Implements)
				h.Mix(i);
			h.Generics(t.Generics);
			h.Mix((int)t.Access);
			h.Mix(t.Abstract);
			h.Mix(t.Sealed);
			h.Mix(t.Static);
			h.Mix(t.Underlying);
			h.Mix(t.Extends);
			h.Mix(t.Signature);
			h.Attrs(t.Attrs);
			h.Mix(doc.Members.Count);
			for (let m in doc.Members)
			{
				h.Mix((int)m.Kind);
				h.Mix(m.Id);
				h.Mix(m.Name);
				h.Mix(m.Type);
				h.Mix(m.Returns);
				h.Mix((int)m.Access);
				h.Mix(m.Static);
				h.Mix(m.Const);
				h.Mix(m.Readonly);
				h.Mix(m.Virtual);
				h.Mix(m.Abstract);
				h.Mix(m.Override);
				h.Mix(m.Sealed);
				h.Mix(m.Pure);
				h.Mix(m.Unsafe);
				h.Mix(m.Mutating);
				h.Mix(m.Inline);
				h.Mix(m.Auto);
				h.Mix(m.Init);
				h.Mix(m.Elements);
				h.Mix((int)m.Owner);
				h.Mix(m.CaseValue);
				h.Params(m.Payload);
				h.Mix((int)m.Chain);
				h.Mix(m.CallConv);
				h.Generics(m.Generics);
				h.Attrs(m.Attrs);
				h.Params(m.Params);
				h.Params(m.Outs);
				h.Mix(m.Locals.Count);
				for (let l in m.Locals)
				{
					h.Mix(l.Name);
					h.Mix(l.Type);
					h.Mix(l.Init);
					h.Mix((int)l.Owner);
				}
			}
			h.Mix(doc.Sheets.Count);
			for (let s in doc.Sheets)
			{
				h.Mix(s.Key);
				h.Mix((int)s.Role);
				h.Mix((s.Member != null) ? (StringView)s.Member.Id : "");
				// A Lambda Sheet and its node bind together (the captures, the signature): an edit
				// in either compiles everything again.
				if (s.Role == .Lambda && s.Graph != null)
					h.Mix((int64)OfSheet(s));
				// Stateful nodes get hidden fields (Declare): which ones, and their settings.
				for (let n in s.Graph.Nodes)
				{
					if (n.Kind == .Lambda)
					{
						h.Mix(n.Key);
						for (let st in n.Settings)
						{
							h.Mix(st.Key);
							h.Mix(st.Value);
						}
					}
					if (!NodeKinds.IsStateful(n.Kind))
						continue;
					h.Mix(n.Key);
					h.Mix((int)n.Kind);
					h.Mix(n.Disabled);
					h.Mix(n.GetSetting("state"));
					h.Mix(n.HasSetting("random"));
					h.Mix(n.HasSetting("start-closed"));
				}
			}
			return h.H;
		}

		/// What an edit inside a Sheet changes (its nodes, wires and settings).
		public static uint64 OfSheet(Sheet s)
		{
			if (!s.IsBuilt)
				return 0;
			let g = s.Graph;
			uint64 h = 1469598103934665603UL;
			for (let v in int64[?]((int64)g.Serial, g.Version, g.Nodes.Count, g.Links.Count))
			{
				h ^= (uint64)v;
				h *= 1099511628211UL;
			}
			return h;
		}
	}
}
