using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	/// Lowering of the core library's Sheets (docs/Core-Library.md, "How the core is compiled"):
	/// only what the program reaches. A core function is lowered when a call names it (Use), a core
	/// type's destructor and the functions its vtable and interface tables name when the type is
	/// used (Need), and `Core.String`'s `this(StringView)` and `View()` whenever String is used (the
	/// literal and conversion lowering and the back end's `args` call them by name). Each
	/// instance (List<int>, a generic function's arguments) gets its own functions, in the unit of
	/// the core type that defines them (`unit Core.List "List.treadle"`).
	class CoreLowering
	{
		ProgramLowerer M;

		class Request
		{
			public MemberSym Member;
			public KType Owner;
			public List<KType> MethodArgs ~ delete _;
			public SheetResult Result;
			public String Key = new .() ~ delete _;
		}

		/// Every request by funcref, so each function is lowered once.
		Dictionary<String, Request> mByKey = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		List<Request> mQueue = new .() ~ delete _;
		/// The lowered functions per core unit (the defining type's full name): (funcref, text).
		Dictionary<String, List<(String key, String text)>> mOut = new .() ~
			{
				for (let kv in _)
				{
					delete kv.key;
					for (let f in kv.value)
					{
						delete f.key;
						delete f.text;
					}
					delete kv.value;
				}
				delete _;
			};
		HashSet<KType> mTypesSeen = new .() ~ delete _;
		/// The static fields of the core types used (`global` lines), per unit.
		Dictionary<String, String> mGlobals = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

		public this(ProgramLowerer m)
		{
			M = m;
		}

		public bool Pending => !mQueue.IsEmpty;

		/// A call of `m` as a member of `owner` (with the function's own generic arguments).
		public void Use(MemberSym m, KType owner, List<KType> methodArgs)
		{
			if (m == null || !m.Owner.IsCore || m.IsImport || m.Intrinsic != null || m.Owner.IsCImport)
				return;
			let inst = M.InstanceOf(owner, m.Owner);
			// a member a core extension adds (MathFormat's String.Append overloads) has its Sheet there
			// (a project's extension of a core type is lowered with the project's units)
			if (m.Extension != null && !m.Extension.IsCore)
				return;
			let home = m.Extension ?? m.Owner;
			let doc = home.Doc;
			if (doc == null)
				return;
			for (let sheet in doc.Sheets)
			{
				if (sheet.Role == .Lambda)
					continue;
				if (sheet.Member == null || sheet.Member != m.Decl)
					continue;
				// Bound and checked the first time it is reached (Compilation.Run leaves the core's
				// Sheets alone).
				let r = M.C.CoreSheet(home, sheet);
				if (r == null || r.Member != m)
					continue;
				Request q = new .();
				q.Member = m;
				q.Owner = inst;
				if (methodArgs != null && !methodArgs.IsEmpty)
				{
					q.MethodArgs = new .();
					q.MethodArgs.AddRange(methodArgs);
				}
				q.Result = r;
				M.FuncRef(m, inst, q.MethodArgs, sheet.Role, q.Key);
				if (mByKey.ContainsKeyAlt(q.Key))
				{
					delete q;
					continue;
				}
				mByKey[new String(q.Key)] = q;
				mQueue.Add(q);
			}
		}

		/// A core type the program uses: its destructor and what its vtable and interface tables
		/// name, and for String the members other lowering calls by name.
		public void Need(KType t)
		{
			if (t == null || t.Kind != .Named || !t.Sym.IsCore || TypeTable.IsOpen(t) || !mTypesSeen.Add(t))
				return;
			let s = t.Sym;
			if (!s.IsGeneric)
				for (let m in s.Members)
				{
					if (m.Kind != .Field || !m.Static || m.Const)
						continue;
					String text;
					if (!mGlobals.TryGetValueAlt(s.FullName, out text))
					{
						text = new .();
						mGlobals[new String(s.FullName)] = text;
					}
					text.AppendF("\nglobal {}.{} ", t.Name, m.Name);
					KirWriter.Type(m.Type, text);
					if (m.Init != null)
					{
						text.Append(' ');
						if (m.Init == "default")
							text.Append("zero");
						else if (!Literals.HexToDecimal(m.Init, m.Type.Kind == .Int && !m.Type.Signed, text))
							text.Append(m.Init);
					}
					text.Append('\n');
				}
			if (s.Dtor != null && (s.Kind == .Class || s.Kind == .Struct))
				Use(s.Dtor, t, null);
			if (s.Kind == .Class)
			{
				for (let v in s.VTable)
					if (v.HasBody)
						Use(v, M.InstanceOf(t, v.Owner), null);
				List<KType> ifaces = scope .();
				M.T.InterfacesOf(t, ifaces);
				for (let i in ifaces)
					for (let im in i.Sym.ISlots)
					{
						let impl = M.C.FindImplementation(s, im, i);
						if (impl != null && impl.HasBody)
							Use(impl, M.InstanceOf(t, impl.Owner), null);
					}
			}
			if (s == M.T.StringSym)
				for (let m in s.Members)
					if ((m.Kind == .Ctor && m.Params.Count == 1 && m.Params[0].Type.Sym == M.T.StringViewSym) || (m.Kind == .Function && m.Name == "View"))
						Use(m, t, null);
		}

		/// Lowers the next requested function; false when none is left.
		public bool LowerNext()
		{
			if (mQueue.IsEmpty)
				return false;
			let q = mQueue.PopFront();
			let r = q.Result;
			if (r.HasErrors)
			{
				M.C.Diags.Add(.Error, .Lower, "T4001", r.Site, "", "", "the core library Sheet has errors: it is not compiled");
				M.Failed();
				return true;
			}
			Dictionary<GenericParamSym, KType> map = scope .();
			M.Map(q.Owner, map);
			if (q.MethodArgs != null)
				for (int i < Math.Min(q.Member.Generics.Count, q.MethodArgs.Count))
					map[q.Member.Generics[i]] = q.MethodArgs[i];
			let prevScope = M.ClosureScope;
			M.ClosureScope = (q.Member.Extension != null && q.Member.Extension.IsCore) ? q.Member.Extension : null;
			FnLowerer fl = scope .(M, r, q.Owner, map);
			fl.MethodArgs = q.MethodArgs;
			let f = fl.Run();
			String text = new .();
			KirWriter.Function(f, text);
			delete f;
			LowerLambdas(r, q.Member.Extension ?? q.Member.Owner, q.Owner, q.MethodArgs, map, text);
			M.ClosureScope = prevScope;
			let unitName = (q.Member.Extension ?? q.Member.Owner).FullName;
			List<(String key, String text)> list;
			if (!mOut.TryGetValueAlt(unitName, out list))
			{
				list = new .();
				mOut[new String(unitName)] = list;
			}
			list.Add((new String(q.Key), text));
			return true;
		}

		/// The Lambdas of a lowered core Sheet, and theirs (Lambdas in Lambdas), for the same
		/// instance: each delegate Lambda's closure class and each Lambda's function, written with the
		/// function in its unit. A generic function's Lambda is one per instance of the function
		/// (`Core.Parallel.$lambda_c3<int>`, ProgramLowerer.Closure).
		void LowerLambdas(SheetResult r, TypeSym home, KType owner, List<KType> methodArgs, Dictionary<GenericParamSym, KType> map, String text)
		{
			for (let b in r.Nodes)
			{
				if (b.Kind != .Lambda || b.LambdaSheet == null)
					continue;
				let lr = M.C.CoreSheet(home, b.LambdaSheet.Sheet);
				if (lr == null || lr.LambdaType == null || lr.LambdaType.IsError)
					continue;
				if (lr.HasErrors)
				{
					M.C.Diags.Add(.Error, .Lower, "T4001", lr.Site, "", "", "the core library Sheet has errors: it is not compiled");
					M.Failed();
					continue;
				}
				if (lr.LambdaType.Kind == .Delegate)
					M.ClosureDecl(lr, owner, map, text, methodArgs);
				FnLowerer fl = scope .(M, lr, owner, map);
				fl.MethodArgs = methodArgs;
				let f = fl.Run();
				KirWriter.Function(f, text);
				delete f;
				LowerLambdas(lr, home, owner, methodArgs, map, text);
			}
		}

		/// Global lines for the unit `name` (a core type's or a C import set's constants).
		public void AddGlobals(StringView name, StringView text)
		{
			if (!mGlobals.TryGetValueAlt(name, var have))
			{
				have = new .();
				mGlobals[new String(name)] = have;
			}
			have.Append(text);
		}

		/// The core units, by name, each function by funcref.
		public void Write(String o)
		{
			List<String> units = scope .();
			for (let kv in mOut)
				units.Add(kv.key);
			for (let kv in mGlobals)
				if (!mOut.ContainsKeyAlt(kv.key))
					units.Add(kv.key);
			units.Sort(scope (a, b) => a.CompareTo(b));
			for (let name in units)
			{
				mOut.TryGetValueAlt(name, let list);
				if (list != null)
					list.Sort(scope (a, b) => a.key.CompareTo(b.key));
				o.AppendF("\nunit {}", name);
				let sym = M.T.Find(name);
				if (sym != null)
				{
					let fileName = System.IO.Path.GetFileName(sym.Path, .. scope String());
					if (!fileName.IsEmpty)
					{
						o.Append(' ');
						KirWriter.Quote(fileName, o);
					}
				}
				o.Append('\n');
				if (mGlobals.TryGetValueAlt(name, let globals))
					o.Append(globals);
				if (list != null)
					for (let f in list)
						o.Append(f.text);
			}
		}
	}
}

namespace Treadle.Compiler
{
	extension ProgramLowerer
	{
		/// A member function the back end has no `this` for: one of the built-in StringView (no
		/// `type` record) or of an enum (Option, Result). It is lowered as a static function whose
		/// first parameter is the receiver's address (`StringView*`), which is what a call
		/// passes anyway.
		public bool ThisAsParam(MemberSym m, KType owner)
		{
			if (m == null || m.Static || owner == null || owner.Kind != .Named)
				return false;
			if (m.Kind != .Function && m.Kind != .Property)
				return false;
			return owner.Sym == T.StringViewSym || owner.Sym.Kind == .Enum;
		}
	}
}
