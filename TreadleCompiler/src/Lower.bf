using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	/// Lower (Compiler.md 1, 4): the bound and checked Sheets of a whole program into the Sheet IR
	/// in the back end's `.tir` form (docs/Follow-ups.md, "Back end -> front end").
	static class Lowering
	{
		/// The program as `.tir` text: `program`, `entry`, the C imports, one `unit` section per
		/// project type file (generic instances in their definition's unit), the core types it uses.
		/// False when a Sheet with errors was left out (the diagnostics say which).
		/// `kind` is the project's `console`, `windowed` or `library` (Graph-Format.md 5): the
		/// `program` line's word; a library has no entry (`entryType` "").
		public static bool WriteProgram(Compilation c, StringView name, StringView entryType, String outText, StringView kind = "console")
		{
			ProgramLowerer p = scope .(c);
			p.Kind = kind;
			return p.Run(name, entryType, outText);
		}
	}

	class ProgramLowerer
	{
		public Compilation C;
		public TypeTable T;

		class UnitOut
		{
			public TypeSym Sym;
			public String Text = new .() ~ delete _;
			/// Generic instances lowered into this unit, by type name.
			public List<(String name, String text)> Instances = new .() ~ { for (let i in _) { delete i.name; delete i.text; } delete _; };
		}

		List<UnitOut> mUnits = new .() ~ DeleteContainerAndItems!(_);
		/// Core types used by value (instances of Result / Option / Span, interfaces): unit-less.
		List<(String name, String text)> mShared = new .() ~ { for (let i in _) { delete i.name; delete i.text; } delete _; };
		/// `func ... import` lines by funcref.
		Dictionary<String, String> mImports = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		HashSet<KType> mSeen = new .() ~ delete _;
		List<KType> mQueue = new .() ~ delete _;
		/// The read-only globals of constants (LowerMath.bf, ConstGlobal): by the owner type's full
		/// name, and every global's name once.
		Dictionary<String, String> mConstGlobals = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		HashSet<String> mConstGlobalNames = new .() ~ DeleteContainerAndItems!(_);
		/// The core library's functions the program reaches (LowerCore.bf).
		public CoreLowering Core ~ delete _;
		/// While an extension's Sheets are lowered: the extension (its Lambdas' closure names).
		public TypeSym ClosureScope;
		/// The `program` line's kind word.
		public StringView Kind = "console";
		bool mOk = true;

		public void Failed() => mOk = false;

		public this(Compilation c)
		{
			C = c;
			T = c.Table;
			Core = new .(this);
		}

		UnitOut UnitOf(TypeSym s)
		{
			for (let u in mUnits)
				if (u.Sym == s)
					return u;
			UnitOut u = new .();
			u.Sym = s;
			mUnits.Add(u);
			return u;
		}

		public bool Run(StringView name, StringView entryType, String o)
		{
			List<TypeSym> types = scope .();
			for (let u in C.Units)
				if (u.Sym != null && !u.IsCore && !u.IsCDecl)
					types.Add(u.Sym);
			types.Sort(scope (a, b) => a.FullName.CompareTo(b.FullName));
			String entryRef = scope .();
			for (let t in types)
			{
				let uo = UnitOf(t);
				let fileName = System.IO.Path.GetFileName(t.Path, .. scope String());
				uo.Text.AppendF("\nunit {}", t.FullName);
				if (!fileName.IsEmpty)
				{
					uo.Text.Append(' ');
					KirWriter.Quote(fileName, uo.Text);
				}
				uo.Text.Append('\n');
				// An extension's unit holds its functions as members of the extended type (per
				// instance for a generic one, LowerExtensionsOf).
				if (t.Kind == .Extension)
				{
					if (t.Extends != null && !t.Extends.IsGeneric)
					{
						Need(t.Extends.Self);
						LowerExtension(t, t.Extends.Self, uo.Text);
					}
					continue;
				}
				if (t.IsGeneric)
					continue;
				Need(t.Self);
				LowerType(t.Self, uo.Text);
				if (t.FullName == entryType)
					Entry(t, entryRef);
			}
			// Generic instances (and the types they use) and the core functions reached, until
			// nothing new is asked for.
			while (!mQueue.IsEmpty || Core.Pending)
			{
				if (mQueue.IsEmpty)
				{
					Core.LowerNext();
					continue;
				}
				let inst = mQueue.PopFront();
				String text = new .();
				if (inst.Sym.IsCore)
				{
					Decl(inst, text);
					mShared.Add((new String(inst.Name), text));
					LowerExtensionsOf(inst);
					continue;
				}
				LowerType(inst, text);
				UnitOf(inst.Sym).Instances.Add((new String(inst.Name), text));
				LowerExtensionsOf(inst);
			}
			o.Append("# tir 1\n");
			o.AppendF("program {} {}\n", name, Kind);
			if (!entryRef.IsEmpty)
				o.AppendF("entry {}\n", entryRef);
			List<String> imports = scope .();
			for (let kv in mImports)
				imports.Add(kv.value);
			imports.Sort(scope (a, b) => a.CompareTo(b));
			for (let i in imports)
				o.AppendF("\n{}\n", i);
			mShared.Sort(scope (a, b) => a.name.CompareTo(b.name));
			for (let s in mShared)
				o.Append(s.text);
			// The constants' read-only globals: in their type's unit (a core type's or a C import
			// set's in its own unit, as its static fields).
			for (let kv in mConstGlobals)
			{
				UnitOut unit = null;
				for (let u in mUnits)
					if (u.Sym.FullName == kv.key)
						unit = u;
				if (unit != null)
					unit.Text.Append(kv.value);
				else
					Core.AddGlobals(kv.key, kv.value);
			}
			Core.Write(o);
			for (let u in mUnits)
			{
				o.Append(u.Text);
				u.Instances.Sort(scope (a, b) => a.name.CompareTo(b.name));
				for (let i in u.Instances)
					o.Append(i.text);
			}
			return mOk;
		}

		/// Program Start: the entry type's static `Main()` or `Main(Core.String[])` itself (the back
		/// end's `main` passes the command line as `args` to the second form).
		void Entry(TypeSym t, String outRef)
		{
			MemberSym main = null;
			for (let m in t.Members)
				if (m.Kind == .Function && m.Name == "Main" && m.Static)
					main = m;
			if (main == null)
				return;
			FuncRef(main, t.Self, null, .Body, outRef);
		}

		// ------------------------------------------------------------------ names

		public void Map(KType inst, Dictionary<GenericParamSym, KType> outMap) => T.MapOf(inst, outMap);

		void FullMap(MemberSym m, KType owner, List<KType> methodArgs, Dictionary<GenericParamSym, KType> map)
		{
			Map(owner, map);
			if (methodArgs != null)
				for (int i < Math.Min(m.Generics.Count, methodArgs.Count))
					map[m.Generics[i]] = methodArgs[i];
		}

		/// Parameter types (`ref` / `out` / `in` are `ref T`), without `this`.
		public void ParamTypes(MemberSym m, Dictionary<GenericParamSym, KType> map, List<(KType type, bool isRef)> outTypes, SheetRole role = .Body)
		{
			if (m.Kind == .Property)
			{
				if (role == .Set)
					outTypes.Add((T.Subst(m.Type, map), false));
				return;
			}
			for (let p in m.Params)
				outTypes.Add((T.Subst(p.Type, map), p.Mode != .Value && p.Mode != .Unset));
			for (let p in m.Outs)
				outTypes.Add((T.Subst(p.Type, map), true));
		}

		public KType ReturnOf(MemberSym m, Dictionary<GenericParamSym, KType> map, SheetRole role = .Body)
		{
			if (m.Kind == .Property)
				return (role == .Get) ? T.Subst(m.Type, map) : T.Void;
			return T.Subst(m.Returns ?? T.Void, map);
		}

		static void MemberName(MemberSym m, SheetRole role, String o)
		{
			switch (m.Kind)
			{
			case .Ctor: o.Append(m.Static ? "$sctor" : "this");
			case .Dtor: o.Append("~this");
			case .Property: o.AppendF("{}${}", (role == .Set) ? "set" : "get", m.Name);
			case .Operator:
				o.Append("op$");
				switch (m.Name)
				{
				case "==": o.Append("eq");
				case "!=": o.Append("ne");
				case "<": o.Append("lt");
				case ">": o.Append("gt");
				case "<=": o.Append("le");
				case ">=": o.Append("ge");
				case "+": o.Append("add");
				case "-": o.Append("sub");
				case "*": o.Append("mul");
				case "/": o.Append("div");
				case "%": o.Append("rem");
				case "&": o.Append("and");
				case "|": o.Append("or");
				case "^": o.Append("xor");
				case "<<": o.Append("shl");
				case ">>": o.Append("shr");
				case "!": o.Append("not");
				case "~": o.Append("compl");
				case "neg": o.Append("neg");
				case "[]": o.Append("index");
				default: o.Append(m.Name);
				}
			default: o.Append(m.Name);
			}
		}

		/// The funcref of `m` as a member of `owner` (`Core.Pair<int,float>.Swap()`).
		public void FuncRef(MemberSym m, KType owner, List<KType> methodArgs, SheetRole role, String o)
		{
			if (m.IsImport && m.Owner.IsCImport)
				o.Append(m.Owner.FullName);
			else
				KirWriter.Type(owner, o);
			o.Append('.');
			MemberName(m, role, o);
			if (methodArgs != null && !methodArgs.IsEmpty)
			{
				o.Append('<');
				for (let a in methodArgs)
				{
					if (@a.Index > 0)
						o.Append(',');
					KirWriter.Type(a, o);
				}
				o.Append('>');
			}
			Dictionary<GenericParamSym, KType> map = scope .();
			FullMap(m, owner, methodArgs, map);
			List<(KType type, bool isRef)> ps = scope .();
			ParamTypes(m, map, ps, role);
			o.Append('(');
			// The receiver as the first parameter (its address) where the back end has no `this` (LowerCore.bf).
			let thisParam = ThisAsParam(m, owner);
			if (thisParam)
				KirWriter.Type(T.Pointer(owner), o);
			for (let p in ps)
			{
				if (@p.Index > 0 || thisParam)
					o.Append(',');
				// A ref / out / in parameter is the variable's address, as its `param` line says.
				KirWriter.Type(p.isRef ? T.Pointer(p.type) : p.type, o);
			}
			if (m.Variadic)
				o.Append(ps.IsEmpty ? "..." : ",...");
			o.Append(')');
		}

		/// The function of a Lambda Sheet (Compiler.md 4, delegates): `<closure>.Invoke(<inputs>)`
		/// for a delegate Lambda (its `this` is the closure), `<Owner>.$lambda_<node>(<inputs>)` (static)
		/// for a function pointer Lambda.
		/// `owner` is the type instance the Sheet is lowered for (`Gen.Box<int>` in a generic type) and
		/// `lambdaType` the Lambda's type with that instance's arguments.
		public void LambdaKey(KType owner, StringView node, KType lambdaType, String o)
		{
			if (lambdaType.Kind == .Function)
			{
				KirWriter.Type(owner, o);
				o.AppendF(".$lambda_{}(", node);
			}
			else
				o.AppendF("{}.Invoke(", Closure(owner, node).FullName);
			for (let a in lambdaType.Args)
			{
				if (@a.Index > 0)
					o.Append(',');
				KirWriter.Type(a, o);
			}
			o.Append(')');
		}

		/// The closure class of a Lambda node for one instance of its owner: the class Bind made
		/// for a non-generic owner, else `<Owner<Args>>.$lambda_<node>`, one per generic instance
		/// (written in the definition's unit with the instance, so the back end shares it as it
		/// does the instance's own functions).
		public TypeSym Closure(KType owner, StringView node)
		{
			// An extension's Lambdas are named after the extension (its node ids are its own file's).
			let ext = ClosureScope;
			if (owner.Args.IsEmpty)
				return C.ClosureType(ext ?? owner.Sym, node);
			String stem = scope .();
			if (ext != null)
				stem.AppendF("$lambda_{}_{}", ext.Name, node);
			else
				stem.AppendF("$lambda_{}", node);
			String name = scope .();
			KirWriter.Type(owner, name);
			name.AppendF(".{}", stem);
			if (C.Closures.TryGetValue(name, let have))
				return have;
			TypeSym t = new .();
			t.Name.Append(stem);
			KirWriter.Type(owner, t.Namespace);
			t.FullName.Set(name);
			t.Kind = .Class;
			t.Project.Set(owner.Sym.Project);
			t.Self = T.Named(t, default);
			C.Closures[new String(name)] = t;
			return t;
		}

		/// The closure class of a Lambda node: `base Core.Delegate`, a field per capture (a pointer
		/// to the variable for a by-ref capture), the capture types with the instance's arguments.
		void ClosureDecl(SheetResult lr, KType inst, Dictionary<GenericParamSym, KType> map, String o)
		{
			let cl = Closure(inst, lr.Sheet.LambdaNode);
			o.AppendF("\ntype {} class\n\tbase Core.Delegate\n", cl.FullName);
			for (let cap in lr.Captures)
			{
				let t = (cap.What == .This) ? ThisType(inst) : T.Subst(cap.Type, map);
				Need(t);
				o.Append("\tfield ");
				cap.FieldName(o);
				o.Append(' ');
				KirWriter.Type(cap.ByRef ? T.Pointer(t) : t, o);
				o.Append('\n');
			}
		}

		/// The `type` record of a C record (`cstruct` / `cunion` / `cenum`): the fields when they lay
		/// out naturally, else opaque bytes of the record's size and alignment (Lower reaches the
		/// fields by offset).
		void CRecordDecl(KType t, String o)
		{
			let s = t.Sym;
			if (!s.CBlob)
			{
				Decl(t, o);
				return;
			}
			o.AppendF("\ntype {} struct\n", s.FullName);
			int64 align = Math.Clamp(s.CAlign, 1, 8);
			if (align == 3 || align > 4 && align < 8)
				align = 1;
			let word = (align == 8) ? "uint64" : ((align == 4) ? "uint32" : ((align == 2) ? "uint16" : "uint8"));
			o.AppendF("\tfield __bytes {}[{}]\n", word, Math.Max(1, (s.CSize + align - 1) / align));
		}

		/// `Game.Player.TakeDamage` (the name the back end shows).
		public void Display(MemberSym m, KType owner, SheetRole role, String o)
		{
			o.AppendF("{}.", m.Owner.FullName);
			MemberName(m, role, o);
		}

		/// The function a virtual call names: the one that declares the slot (Follow-ups: `<fn>` is
		/// the declaring function of the vslot).
		public MemberSym Declaring(MemberSym m)
		{
			var d = m;
			int guard = 0;
			while (d.Overrides != null && guard++ < 64)
				d = d.Overrides;
			return d;
		}

		/// `this` of a member of `owner`: the object reference (class) or a pointer (struct).
		public KType ThisType(KType owner) => (owner.Kind == .Named && (owner.Sym.Kind == .Struct || owner.Sym.Kind == .Enum)) ? T.Pointer(owner) : owner;

		/// The type a generic argument is at the IR level: int64 and uint64 are int and uint
		/// there (Core-Library.md), so `AppendSlot<int64>` and `AppendSlot<int>` (or `List<int64>`
		/// and `List<int>`) are one instance, lowered once. Diagnostics keep the spelled type.
		public KType IRCanon(KType t)
		{
			if (t == null)
				return t;
			switch (t.Kind)
			{
			case .Int:
				if (t.Bits == 64 && t.Prim != null && (t.Prim == "int64" || t.Prim == "uint64"))
					return T.Prim(t.Signed ? "int" : "uint");
				return t;
			case .Pointer:
				let e = IRCanon(t.Element);
				return (e == t.Element) ? t : T.Pointer(e);
			case .Array:
				let e = IRCanon(t.Element);
				return (e == t.Element) ? t : T.Array(e);
			case .Nullable:
				let e = IRCanon(t.Element);
				return (e == t.Element) ? t : T.Nullable(e);
			case .Named, .Tuple:
				if (t.Args.IsEmpty)
					return t;
				KType[] args = scope KType[t.Args.Count];
				bool changed = false;
				for (int i < t.Args.Count)
				{
					args[i] = IRCanon(t.Args[i]);
					changed |= args[i] != t.Args[i];
				}
				if (!changed)
					return t;
				return (t.Kind == .Tuple) ? T.Tuple(args) : T.Named(t.Sym, args);
			default:
				return t;
			}
		}

		/// A call target: imports get their `func ... import` line, generic instances are queued,
		/// core functions are lowered when used.
		public void Use(MemberSym m, KType owner, StringView funcRef, List<KType> methodArgs = null)
		{
			let canonOwner = IRCanon(owner);
			List<KType> canonArgs = null;
			if (methodArgs != null)
			{
				canonArgs = scope:: .();
				for (let a in methodArgs)
					canonArgs.Add(IRCanon(a));
			}
			Core.Use(m, canonOwner, canonArgs);
			Need(canonOwner);
			if (m.IsImport)
			{
				if (mImports.ContainsKeyAlt(funcRef))
					return;
				String line = new .();
				line.AppendF("func {} ", funcRef);
				Dictionary<GenericParamSym, KType> map = scope .();
				KirWriter.Type(ReturnOf(m, map), line);
				line.Append(" import ");
				KirWriter.Quote(m.ImportName ?? m.Name, line);
				if (m.CallConv != null && m.CallConv != "cdecl")
					line.AppendF(" cconv {}", m.CallConv);
				mImports[new String(funcRef)] = line;
			}
		}

		/// An extern C variable a Sheet reaches (`cvar`): `global C.<set>.<name> T import "<name>"`,
		/// the C symbol itself (written with the imported functions).
		public void ImportGlobal(MemberSym v)
		{
			String key = scope $"global {v.Owner.FullName}.{v.Name}";
			if (mImports.ContainsKeyAlt(key))
				return;
			Need(v.Type);
			String line = new .();
			line.AppendF("{} ", key);
			KirWriter.Type(v.Type, line);
			line.Append(" import ");
			KirWriter.Quote(v.ImportName ?? v.Name, line);
			mImports[new String(key)] = line;
		}

		/// A type the program uses: declarations for core instances, the lowering of project
		/// generic instances, the core String's bodies.
		public void Need(KType spelled)
		{
			if (spelled == null)
				return;
			let t = IRCanon(spelled);
			switch (t.Kind)
			{
			case .Pointer, .Array, .Nullable, .FixedArray:
				Need(t.Element);
				return;
			case .Tuple, .Function, .Delegate:
				for (let a in t.Args)
					Need(a);
				Need(t.Element);
				return;
			default:
			}
			if (t.Kind != .Named)
				return;
			if (TypeTable.IsOpen(t) || !mSeen.Add(t))
				return;
			for (let a in t.Args)
				Need(a);
			let s = t.Sym;
			Core.Need(t);
			if (s.IsCRecord)
			{
				String text = new .();
				CRecordDecl(t, text);
				mShared.Add((new String(t.Name), text));
				return;
			}
			if (s.IsCore)
			{
				if (s == T.ObjectSym || s == T.StringViewSym || s.Static)
					return;
				mQueue.Add(t);
				return;
			}
			if (!t.Args.IsEmpty)
				mQueue.Add(t);
		}

		// ------------------------------------------------------------------ types

		/// The constructor `Construct T` without arguments runs: a declared one without
		/// parameters (`declared`), or the one the compiler makes for a project class that
		/// declares none (true with `declared` null).
		public bool DefaultCtor(TypeSym s, out MemberSym declared)
		{
			declared = null;
			List<MemberSym> ctors = scope .();
			s.GetCtors(ctors);
			for (let k in ctors)
				if (k.Params.IsEmpty)
				{
					declared = k;
					return true;
				}
			return ctors.IsEmpty && s.Kind == .Class && !s.IsCore && !s.Static;
		}

		static StringView KindWord(TypeKind k)
		{
			switch (k)
			{
			case .Struct: return "struct";
			case .Enum: return "enum";
			case .Interface: return "interface";
			default: return "class";
			}
		}

		bool HasAttr(TypeSym s, StringView name)
		{
			if (s.Decl != null)
				for (let a in s.Decl.Attrs)
					if (a.Name == name)
						return true;
			return false;
		}

		/// The `type` record of an instance (or a non-generic type).
		void Decl(KType inst, String o)
		{
			let s = inst.Sym;
			Dictionary<GenericParamSym, KType> map = scope .();
			Map(inst, map);
			o.Append("\ntype ");
			KirWriter.Type(inst, o);
			o.AppendF(" {}", KindWord(s.Kind));
			if (s.Abstract && s.Kind == .Class)
				o.Append(" abstract");
			if (HasAttr(s, "Packed"))
				o.Append(" packed");
			o.Append('\n');
			let b = T.BaseOf(inst);
			if (b != null && b.Sym != T.ObjectSym)
			{
				o.Append("\tbase ");
				KirWriter.Type(b, o);
				o.Append('\n');
				Need(b);
			}
			if (s.Kind == .Enum && !s.HasPayload)
			{
				o.Append("\ttag ");
				KirWriter.Type(s.Underlying ?? T.Int, o);
				o.Append('\n');
			}
			for (let m in s.Members)
			{
				if (m.Kind == .Field && !m.Static && !m.Const)
				{
					let ft = T.Subst(m.Type, map);
					Need(ft);
					o.AppendF("\tfield {} ", m.Name);
					KirWriter.Type(ft, o);
					if (m.Ownership == .Owned)
						o.Append(" owned");
					o.Append('\n');
				}
				else if (m.Kind == .Case)
				{
					o.AppendF("\tcase {} = {}", m.Name, m.CaseValue);
					for (let p in m.Payload)
					{
						let pt = T.Subst(p.Type, map);
						Need(pt);
						o.Append(' ');
						KirWriter.Type(pt, o);
					}
					o.Append('\n');
				}
			}
			if (s.Kind == .Class)
			{
				for (let v in s.VTable)
				{
					let d = Declaring(v);
					o.Append("\tvslot ");
					FuncRef(d, InstanceOf(inst, d.Owner), null, .Body, o);
					o.Append(' ');
					if (v.Abstract && !v.HasBody)
						o.Append("abstract");
					else
						FuncRef(v, InstanceOf(inst, v.Owner), null, .Body, o);
					o.Append('\n');
				}
				List<KType> all = scope .();
				AllInterfaces(inst, all);
				for (let i in all)
				{
					Need(i);
					o.Append("\titable ");
					KirWriter.Type(i, o);
					for (let im in i.Sym.ISlots)
					{
						let impl = C.FindImplementation(s, im, i);
						o.Append(' ');
						if (impl != null)
							FuncRef(impl, InstanceOf(inst, impl.Owner), null, .Body, o);
						else
							o.Append("abstract");
					}
					o.Append('\n');
				}
			}
			if (s.Kind == .Interface)
			{
				for (let m in s.ISlots)
				{
					o.Append("\tislot ");
					FuncRef(m, (m.Owner == s) ? inst : m.Owner.Self, null, .Body, o);
					o.Append('\n');
				}
			}
			if (s.Dtor != null && (s.Kind == .Class || s.Kind == .Struct))
			{
				o.Append("\tdtor ");
				FuncRef(s.Dtor, inst, null, .Body, o);
				o.Append('\n');
			}
			// Functions without a body that slots name: abstract and interface functions.
			for (let m in s.Members)
			{
				if (m.Kind != .Function || m.HasBody || m.IsImport || m.Intrinsic != null)
					continue;
				o.Append("\nfunc ");
				FuncRef(m, inst, null, .Body, o);
				o.Append(' ');
				KirWriter.Type(ReturnOf(m, map), o);
				if (s.Kind == .Class)
					o.Append(" virtual");
				o.Append(" abstract\n");
			}
		}

		void AllInterfaces(KType t, List<KType> outList)
		{
			List<KType> own = scope .();
			T.InterfacesOf(t, own);
			for (let i in own)
			{
				if (!outList.Contains(i))
					outList.Add(i);
				AllInterfaces(i, outList);
			}
		}

		/// The instance of `sym` in the class chain of `inst`.
		public KType InstanceOf(KType inst, TypeSym sym)
		{
			var t = inst;
			int guard = 0;
			while (t != null && guard++ < 64)
			{
				if (t.Kind == .Named && t.Sym == sym)
					return t;
				t = T.BaseOf(t);
			}
			return sym.Self;
		}

		// ------------------------------------------------------------------ functions

		void LowerType(KType inst, String o)
		{
			let s = inst.Sym;
			Decl(inst, o);
			Dictionary<GenericParamSym, KType> map = scope .();
			Map(inst, map);
			for (let m in s.Members)
			{
				// A constant has no storage unless a Sheet needs one (ConstGlobal).
				if (m.Kind == .Field && m.Static && !m.Const)
				{
					o.AppendF("\nglobal {}.{} ", inst.Name, m.Name);
					KirWriter.Type(T.Subst(m.Type, map), o);
					if (m.Init != null)
					{
						o.Append(' ');
						if (m.Init == "default")
							o.Append("zero");
						else if (!Literals.HexToDecimal(m.Init, m.Type.Kind == .Int && !m.Type.Signed, o))
							o.Append(m.Init);
					}
					o.Append('\n');
				}
			}
			if (s.Doc != null && !s.IsCImport)
				LowerSheets(s.Doc, inst, map, o);
			for (let m in s.Members)
				if (m.Kind == .Field && m.AutoOf != null && m.Extension == null)
					AutoAccessors(inst, m, map, o);
			if (s.Kind == .Class && !s.Static)
			{
				List<MemberSym> ctors = scope .();
				s.GetCtors(ctors);
				if (ctors.IsEmpty)
					SynthCtor(inst, o);
			}
		}

		/// The functions of a type file's Sheets as members of `inst`: the closure classes of the
		/// delegate Lambdas first, then every Sheet (Lambda Sheets last, as the file has them).
		void LowerSheets(TypeDocument doc, KType inst, Dictionary<GenericParamSym, KType> map, String o)
		{
			for (let sheet in doc.Sheets)
			{
				let r = (sheet.Role == .Lambda) ? C.ResultOf(sheet) : null;
				if (r != null && !r.HasErrors && r.LambdaType != null && r.LambdaType.Kind == .Delegate)
					ClosureDecl(r, inst, map, o);
			}
			for (int pass < 2)
				for (let sheet in doc.Sheets)
				{
					if ((sheet.Role == .Lambda) != (pass == 1))
						continue;
					let r = C.ResultOf(sheet);
					if (r == null)
						continue;
					if (r.HasErrors)
					{
						C.Diags.Add(.Error, .Lower, "T4001", r.Site, "", "", "the Sheet has errors: it is not compiled");
						mOk = false;
						continue;
					}
					if (r.IsLambda && (r.LambdaType == null || r.LambdaType.IsError))
						continue;
					FnLowerer fl = scope .(this, r, inst, map);
					let f = fl.Run();
					KirWriter.Function(f, o);
					delete f;
				}
		}

		/// An extension's functions (Language.md 4, Extension) as members of `inst`, an instance of
		/// the extended type: its Sheets and the accessors of its auto properties, written in the
		/// extension's unit.
		void LowerExtension(TypeSym ext, KType inst, String o)
		{
			if (ext.Doc == null)
				return;
			Dictionary<GenericParamSym, KType> map = scope .();
			Map(inst, map);
			let prev = ClosureScope;
			ClosureScope = ext;
			LowerSheets(ext.Doc, inst, map, o);
			for (let m in inst.Sym.Members)
				if (m.Kind == .Field && m.AutoOf != null && m.Extension == ext)
					AutoAccessors(inst, m, map, o);
			ClosureScope = prev;
		}

		/// The extensions of a generic type, lowered for one of its instances (in each extension's unit).
		void LowerExtensionsOf(KType inst)
		{
			let s = inst.Sym;
			if (s.Extensions == null || inst.Args.IsEmpty || TypeTable.IsOpen(inst))
				return;
			for (let ext in s.Extensions)
			{
				String text = new .();
				LowerExtension(ext, inst, text);
				UnitOf(ext).Instances.Add((new String(inst.Name), text));
			}
		}

		/// An auto property's getter and setter over its hidden field `__prop_<Name>`
		/// (Language.md 4): `get$Name()` loads it, `set$Name(T)` stores `value`.
		void AutoAccessors(KType inst, MemberSym field, Dictionary<GenericParamSym, KType> map, String o)
		{
			let prop = field.AutoOf;
			let ft = T.Subst(field.Type, map);
			Need(ft);
			for (int pass < 2)
			{
				let role = (pass == 0) ? SheetRole.Get : SheetRole.Set;
				IRFunction f = scope .();
				FuncRef(prop, inst, null, role, f.Key);
				Display(prop, inst, role, f.Display);
				f.Ret = (pass == 0) ? ft : T.Void;
				f.Static = field.Static;
				IRValue thisV = null;
				if (!field.Static)
				{
					thisV = new .();
					thisV.Param = new String("this");
					thisV.Type = ThisType(inst);
					f.Params.Add(thisV);
				}
				IRValue valueV = null;
				if (pass == 1)
				{
					valueV = new .();
					valueV.Param = new String("value");
					valueV.Type = ft;
					f.Params.Add(valueV);
				}
				IRRegion r0 = new .();
				f.Regions.Add(r0);
				let b = f.NewBlock();
				OpEmitter e = scope .(f, b);
				IROp addr;
				if (field.Static)
				{
					addr = e.Op(.GlobalAddr, T.Pointer(ft), "", "");
					addr.Global = new String(scope $"{inst.Name}.{field.Name}");
				}
				else
				{
					addr = e.Op(.FieldAddr, T.Pointer(ft), "", "");
					addr.Operands.Add(thisV);
					addr.Sub = new String(field.Name);
				}
				if (pass == 0)
				{
					let ld = e.Op(.Load, ft, "", "");
					ld.Operands.Add(addr);
					b.Term = .Ret;
					b.RetVal = ld;
				}
				else
				{
					let st = e.Op(.Store, T.Void, "", "");
					st.Operands.Add(addr);
					st.Operands.Add(valueV);
					b.Term = .Ret;
				}
				KirWriter.Function(f, o);
			}
		}

		/// The constructor the compiler makes for a class that declares none: the base's default
		/// constructor, then the field initial values.
		void SynthCtor(KType inst, String o)
		{
			IRFunction f = scope .();
			KirWriter.Type(inst, f.Key);
			f.Key.Append(".this()");
			f.Display.AppendF("{}.this", inst.Sym.FullName);
			f.Ret = T.Void;
			IRValue thisV = new .();
			thisV.Param = new String("this");
			thisV.Type = ThisType(inst);
			f.Params.Add(thisV);
			IRRegion r0 = new .();
			f.Regions.Add(r0);
			let b = f.NewBlock();
			OpEmitter e = scope .(f, b);
			BaseDefaultCtor(e, inst, thisV, "");
			FieldInits(e, inst, thisV, "");
			e.Block.Term = .Ret;
			KirWriter.Function(f, o);
		}

		/// Calls the base class's default constructor (when it has one to run).
		public void BaseDefaultCtor(OpEmitter e, KType inst, IRValue thisV, StringView node)
		{
			let b = T.BaseOf(inst);
			if (b == null || b.Sym.IsCore)
				return;
			if (!DefaultCtor(b.Sym, let declared))
				return;
			String name = scope .();
			KirWriter.Type(b, name);
			name.Append(".this()");
			let up = e.Op(.Cast, b, node, "");
			up.Operands.Add(thisV);
			let call = e.Op(.Call, T.Void, node, "");
			call.Callee = new String(name);
			call.Operands.Add(up);
		}

		/// Stores the initial values of the type's own fields (`init <token>`).
		public void FieldInits(OpEmitter e, KType inst, IRValue thisV, StringView node)
		{
			Dictionary<GenericParamSym, KType> map = scope .();
			Map(inst, map);
			for (let m in inst.Sym.Members)
			{
				if (m.Kind != .Field || m.Static || m.Const || m.Init == null)
					continue;
				let ft = T.Subst(m.Type, map);
				let addr = e.Op(.FieldAddr, T.Pointer(ft), node, "");
				addr.Operands.Add(thisV);
				addr.Sub = new String(m.Name);
				let v = e.Const(m.Init, ft, node, "");
				let st = e.Op(.Store, T.Void, node, "");
				st.Operands.Add(addr);
				st.Operands.Add(v);
			}
		}
	}

	/// Appends ops to a block (the current insertion point).
	class OpEmitter
	{
		public IRFunction F;
		public IRBlock Block;

		public this(IRFunction f, IRBlock b)
		{
			F = f;
			Block = b;
		}

		public IROp Op(OpKind kind, KType type, StringView node, StringView pin)
		{
			IROp op = new .();
			op.Kind = kind;
			op.Type = type;
			if (type != null && !type.IsVoid)
				op.Id = F.NextValue++;
			op.Node.Set(node);
			op.Pin.Set(pin);
			Block.Ops.Add(op);
			return op;
		}

		/// A literal of `type` from a format token (`0`, `"text"`, `.Case`, `default`, `null`).
		public IROp Const(StringView token, KType type, StringView node, StringView pin)
		{
			let op = Op(.Const, type, node, pin);
			if (token.StartsWith('"'))
			{
				op.Lit = new String();
				RecordText.Unquote(token, op.Lit);
				op.LitIsString = true;
			}
			else if (type != null && type.IsVector && token != "default")
			{
				op.Lit = new String();
				VectorRules.LaneLiteral(token, type, op.Lit); // `1,2,3,4` (hexadecimal lanes as decimal)
			}
			else if (token == "default")
				op.Lit = new String("zero");
			else if (token.StartsWith('.'))
				op.Lit = new String(token.Substring(1));
			else if (token.StartsWith('\'') && token.Length >= 3)
				op.Lit = new String(scope $"{(int)token[1]}");
			else
			{
				// a hexadecimal number as decimal (the back end and LLVM read decimal)
				op.Lit = new String();
				if (!Literals.HexToDecimal(token, type != null && type.Kind == .Int && !type.Signed, op.Lit))
					op.Lit.Set(token);
			}
			return op;
		}

		public void Br(IRBlock to)
		{
			if (Block.Terminated)
				return;
			Block.Term = .Br;
			Block.Targets.Add(to);
		}
	}
}
