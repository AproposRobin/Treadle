using System;
using System.Collections;
using System.IO;
using Treadle.Catalog;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Editor
{
	/// One type of the project as the editor knows it from its type file: the header and a copy of
	/// the members (no Sheets).
	class ProjectType
	{
		public String Name = new .() ~ delete _;
		public String FullName = new .() ~ delete _;
		public String Namespace = new .() ~ delete _;
		public String Path = new .() ~ delete _;
		public TypeKind Kind;
		public bool Static;
		public bool Abstract;
		public bool Sealed;
		public String Base = new .() ~ delete _;
		public List<String> Implements = new .() ~ DeleteContainerAndItems!(_);
		public List<String> Generics = new .() ~ DeleteContainerAndItems!(_);
		public List<MemberDecl> Members = new .() ~ DeleteContainerAndItems!(_);

		public void From(TypeDocument doc)
		{
			let h = doc.Header;
			Name.Set(h.Name);
			FullName.Clear();
			h.GetFullName(FullName);
			Namespace.Set(h.Namespace);
			Path.Set(doc.FilePath);
			Kind = h.Kind;
			Static = h.Static;
			Abstract = h.Abstract;
			Sealed = h.Sealed;
			Base.Clear();
			h.Base?.ToString(Base);
			ClearAndDeleteItems!(Implements);
			for (let t in h.Implements)
				Implements.Add(t.ToString(.. new String()));
			ClearAndDeleteItems!(Generics);
			for (let g in h.Generics)
				Generics.Add(new String(g.Name));
			ClearAndDeleteItems!(Members);
			for (let m in doc.Members)
				Members.Add(m.Clone());
		}

		/// What the type declares, as text: equal signatures mean the catalogue and the type
		/// answers did not change.
		public void Signature(String outSig)
		{
			outSig.AppendF("{}|{}|{}|{}|", FullName, (int)Kind, Base, Static);
			for (let i in Implements)
				outSig.AppendF("{},", i);
			for (let g in Generics)
				outSig.AppendF("<{}>", g);
			for (let m in Members)
			{
				outSig.AppendF(";{}:{}:{}:{}:{}:{}:", (int)m.Kind, m.Name, m.Type?.ToString(.. scope String()), m.Returns?.ToString(.. scope String()), m.Static, (int)m.Access);
				outSig.Append(m.Pure ? "p" : "");
				for (let p in m.Params)
					outSig.AppendF("({} {} {})", (int)p.Mode, p.Type?.ToString(.. scope String()), p.Name);
				for (let p in m.Outs)
					outSig.AppendF("[{} {}]", p.Type?.ToString(.. scope String()), p.Name);
				for (let p in m.Payload)
					outSig.AppendF("{{{} {}}}", p.Type?.ToString(.. scope String()), p.Name);
			}
		}

		/// The members a Sheet of another type can use (private ones are the type's own).
		public static bool Visible(MemberDecl m) => m.Access != .Private;
	}

	/// The project's types, read from its type files (open documents first, so unsaved edits
	/// count). What the editor answers type questions and fills the Node menu with until the
	/// front end's type table and catalogue source plug in through the seams (ITypeSystem,
	/// INodeCatalogSource): `ProjectTypeSystem` and `ProjectCatalogSource` below are installed
	/// only while the language's services are the null ones.
	class ProjectTypes
	{
		public List<ProjectType> Types = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, ProjectType> mByName = new .() ~ DeleteDictionaryAndKeys!(_);
		/// Types read from disk, by path, with the file time they were read at.
		Dictionary<String, (DateTime time, ProjectType type)> mDiskCache = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value.type; } delete _; };
		String mSignature = new .() ~ delete _;
		/// Bumps whenever what the types declare changed.
		public int32 Generation = 1;

		/// Reads the project's type files again where they changed. `openDocs` are used instead of
		/// their files (their unsaved edits count).
		public void Rescan(LanguageContext lang, ProjectIndex index, List<TypeDocument> openDocs)
		{
			List<ProjectType> fresh = scope .();
			HashSet<String> seenPaths = scope .();
			defer { for (let p in seenPaths) delete p; }
			for (let d in openDocs)
			{
				if (d.Header.Name.IsEmpty)
					continue;
				ProjectType t = new .();
				t.From(d);
				fresh.Add(t);
				if (!d.FilePath.IsEmpty)
					seenPaths.Add(Normal(d.FilePath, .. new String()));
			}
			if (index != null)
			{
				for (let f in index.Files)
				{
					String key = Normal(f.Path, .. scope String());
					if (seenPaths.Contains(key))
						continue;
					ProjectType cached = null;
					if (mDiskCache.TryGetValue(key, let entry) && entry.time == f.Modified)
						cached = entry.type;
					else
					{
						TypeDocument doc = scope .(lang);
						if (doc.Load(f.Path) case .Ok && doc.LastError.IsEmpty)
						{
							cached = new ProjectType();
							cached.From(doc);
							if (mDiskCache.GetAndRemove(key) case .Ok(let old))
							{
								delete old.key;
								delete old.value.type;
							}
							mDiskCache[new String(key)] = (f.Modified, cached);
						}
					}
					if (cached == null)
						continue;
					ProjectType t = new .();
					CopyType(cached, t);
					fresh.Add(t);
				}
			}
			String sig = scope .();
			for (let t in fresh)
				t.Signature(sig);
			if (sig == mSignature)
			{
				ClearAndDeleteItems!(fresh);
				return;
			}
			mSignature.Set(sig);
			ClearAndDeleteItems!(Types);
			for (let kv in mByName)
				delete kv.key;
			mByName.Clear();
			for (let t in fresh)
			{
				Types.Add(t);
				if (!mByName.ContainsKey(t.FullName))
					mByName[new String(t.FullName)] = t;
				if (!mByName.ContainsKey(t.Name))
					mByName[new String(t.Name)] = t;
			}
			Generation++;
		}

		static void CopyType(ProjectType src, ProjectType dst)
		{
			dst.Name.Set(src.Name);
			dst.FullName.Set(src.FullName);
			dst.Namespace.Set(src.Namespace);
			dst.Path.Set(src.Path);
			dst.Kind = src.Kind;
			dst.Static = src.Static;
			dst.Abstract = src.Abstract;
			dst.Sealed = src.Sealed;
			dst.Base.Set(src.Base);
			for (let i in src.Implements)
				dst.Implements.Add(new String(i));
			for (let g in src.Generics)
				dst.Generics.Add(new String(g));
			for (let m in src.Members)
				dst.Members.Add(m.Clone());
		}

		static void Normal(StringView path, String outKey)
		{
			outKey.Append(path);
			outKey.Replace('\\', '/');
			outKey.ToLower();
		}

		/// The type a name means: `Game.Player`, `Player`, `Pair<int,int>` (arguments dropped).
		public ProjectType Find(StringView typeName)
		{
			var t = typeName;
			t.Trim();
			int lt = t.IndexOf('<');
			if (lt > 0)
				t = t.Substring(0, lt);
			if (t.EndsWith('?'))
				t.RemoveFromEnd(1);
			if (t.IsEmpty)
				return null;
			if (mByName.TryGetValueAlt(t, let found))
				return found;
			return null;
		}

		public static StringView KindWord(TypeKind k) => Treadle.Format.TreadleCodec.TypeKindWord(k);
	}

	/// The stand-in type system: the generic name rules (TypeRules) with the project's types as
	/// the hierarchy, so a class pin is blue, a struct dark blue, an enum teal, a subclass wires
	/// into its base, enum pins get a dropdown and literal pins typed fields.
	class ProjectTypeSystem : ITypeSystem
	{
		ProjectTypes mTypes;

		public this(ProjectTypes types)
		{
			mTypes = types;
		}

		public void KindOf(StringView typeName, String outKind)
		{
			let t = mTypes.Find(typeName);
			if (t != null)
				outKind.Append(ProjectTypes.KindWord(t.Kind));
		}

		public bool IsSubtype(StringView derived, StringView baseType)
		{
			var t = mTypes.Find(derived);
			let target = mTypes.Find(baseType);
			StringView baseName = (target != null) ? (StringView)target.FullName : baseType;
			for (int depth = 0; t != null && depth < 32; depth++)
			{
				for (let i in t.Implements)
				{
					let it = mTypes.Find(i);
					if (i == baseType || (it != null && it.FullName == baseName))
						return true;
					if (it != null && it != t && IsSubtype(it.FullName, baseType))
						return true;
				}
				if (t.Base.IsEmpty)
					return false;
				let b = mTypes.Find(t.Base);
				if (t.Base == baseType || (b != null && b.FullName == baseName))
					return true;
				t = b;
			}
			return false;
		}

		public TypeFamily Family(StringView typeName) => TypeRules.Family(typeName, this);

		/// The generic rules, then what the project knows: they leave a value into a user type
		/// open (an implicit operator could exist); the project's type files say whether one does.
		public Conversion CanConvert(StringView from, StringView to, String outWhy)
		{
			let c = TypeRules.CanConvert(from, to, outWhy, this);
			if (c != .Unchecked)
				return c;
			String f = scope .();
			String t = scope .();
			TypeRules.Normalize(from, f);
			TypeRules.Normalize(to, t);
			if (TypeRules.IsWildcard(f) || TypeRules.IsWildcard(t))
				return c;
			let ft = mTypes.Find(f);
			let tt = mTypes.Find(t);
			bool fromPlain = TypeRules.IsPrimitive(f) || TypeRules.IsStringLike(f);
			bool toPlain = TypeRules.IsPrimitive(t) || TypeRules.IsStringLike(t);
			if (tt != null && fromPlain && !HasImplicit(tt))
			{
				outWhy?.Set(scope $"{f} is not a {t}");
				return .Refused;
			}
			if (ft != null && toPlain && !HasImplicit(ft))
			{
				outWhy?.Set(scope $"{f} is not a {t}: wire one of its members, or Cast To {t}");
				return .Refused;
			}
			if (ft != null && tt != null && ft != tt)
			{
				if (IsSubtype(ft.FullName, tt.FullName))
					return .Implicit;
				if (!HasImplicit(ft) && !HasImplicit(tt))
				{
					outWhy?.Set(scope $"{f} is not a {t} (Cast To {t} if it may be one)");
					return .Refused;
				}
			}
			return c;
		}

		/// The type declares a conversion operator (`operator implicit`).
		static bool HasImplicit(ProjectType t)
		{
			for (let m in t.Members)
				if (m.Kind == .Operator && m.Name == "implicit")
					return true;
			return false;
		}

		public PinValueKind ValueKind(StringView typeName, StringView current, StringView pinName)
		{
			String t = scope .();
			TypeRules.Normalize(typeName, t);
			if (t.IsEmpty || TypeRules.IsWildcard(t))
				return .Expr;
			PinValueKind kind;
			if (t == "bool")
				kind = .Bool;
			else if (TypeRules.IsNumeric(t))
				kind = .Number;
			else if (TypeRules.IsChar(t))
				kind = .Char;
			else if (t == "String" || t == "StringView")
				kind = .Text;
			else
			{
				let pt = mTypes.Find(t);
				let mk = (pt != null) ? PinValue.MathValueKind(pt.FullName, current, pinName) : PinValueKind.None;
				if (mk != .None)
					return mk; // a core math struct: its fields inline
				if (pt != null && pt.Kind == .Enum)
					kind = .Enum;
				else
					return current.IsEmpty ? .None : .Custom;
			}
			// A value that is not a plain literal of the type (an expression, `default`) shows read-only.
			if (!current.IsEmpty && !current.Equals("default"))
			{
				switch (kind)
				{
				case .Bool:
					if (current != "true" && current != "false")
						return .Custom;
				case .Text:
					if (!Treadle.Format.RecordText.IsString(current))
						return .Custom;
				case .Enum:
					if (!current.StartsWith('.'))
						return .Custom;
				default:
				}
			}
			return kind;
		}

		public void EnumMembers(StringView typeName, List<String> outMembers)
		{
			let t = mTypes.Find(typeName);
			if (t == null || t.Kind != .Enum)
				return;
			for (let m in t.Members)
				if (m.Kind == .Case)
					outMembers.Add(new String(m.Name));
		}

		public void DefaultValue(StringView typeName, String outValue)
		{
			String t = scope .();
			TypeRules.Normalize(typeName, t);
			if (t == "bool")
				outValue.Append("false");
			else if (t == "float")
				outValue.Append("0.0f");
			else if (t == "double")
				outValue.Append("0.0");
			else if (TypeRules.IsInt(t))
				outValue.Append("0");
			else if (t == "String" || t == "StringView")
				outValue.Append("\"\"");
		}

		public int32 Generation => mTypes.Generation;
	}

	/// The stand-in catalogue source: for every type of the project, Construct / Local (one per
	/// constructor), Make / Break of a struct, Make Case / Is Case / Switch of an enum, and its
	/// visible members (functions as Call, fields and properties as Get / Set). The front end's
	/// source replaces it (and adds the core library and the C import sets); the Node menu adds
	/// the built-in nodes and the open Sheet's own members, parameters and locals itself.
	class ProjectCatalogSource : INodeCatalogSource
	{
		ProjectTypes mTypes;

		public this(ProjectTypes types)
		{
			mTypes = types;
		}

		public int32 Generation => mTypes.Generation;

		static void Category(ProjectType t, String outCat)
		{
			if (!t.Namespace.IsEmpty)
				outCat.AppendF("{} | ", t.Namespace);
			outCat.Append(t.Name);
		}

		static NodeSpec NewSpec(List<NodeSpec> outSpecs, ProjectType t, NodeEntryKind kind, StringView label)
		{
			NodeSpec s = new .();
			s.Kind = kind;
			s.Label.Set(label);
			Category(t, s.Category);
			// OwnerType is set for member entries only (the catalog reads it as the Receiver's type).
			s.Namespace.Set(t.Namespace);
			outSpecs.Add(s);
			return s;
		}

		static void AddPin(NodeSpec s, StringView name, TypeRef type, StringView modifier = default, StringView def = default)
		{
			PinSpec p = new .();
			p.Name.Set(name);
			p.Label.Set(name);
			type?.ToString(p.Type);
			p.Modifier.Set(modifier);
			p.Default.Set(def);
			s.Pins.Add(p);
		}

		static void Signature(MemberDecl m, String outSig)
		{
			outSig.Append('(');
			for (let p in m.Params)
			{
				if (@p.Index > 0)
					outSig.Append(',');
				p.Type?.ToString(outSig);
			}
			outSig.Append(')');
		}

		public void Entries(List<NodeSpec> outSpecs)
		{
			for (let t in mTypes.Types)
			{
				bool canAllocate = (t.Kind == .Class || t.Kind == .Struct) && !t.Static && !t.Abstract;
				if (canAllocate)
				{
					bool anyCtor = false;
					for (let m in t.Members)
					{
						if (m.Kind != .Ctor || m.Static || !ProjectType.Visible(m))
							continue;
						anyCtor = true;
						AddAllocation(outSpecs, t, m);
					}
					if (!anyCtor)
						AddAllocation(outSpecs, t, null);
				}
				if (t.Kind == .Struct)
				{
					let make = NewSpec(outSpecs, t, .Pure, scope $"Make {t.Name}");
					make.KindWord.Set("Make");
					make.Subject.Set(t.FullName);
					make.ReturnType.Set(t.FullName);
					make.Tooltip.AppendF("Builds a {} from its fields", t.Name);
					let brk = NewSpec(outSpecs, t, .Pure, scope $"Break {t.Name}");
					brk.KindWord.Set("Break");
					brk.Subject.Set(t.FullName);
					brk.Tooltip.AppendF("Splits a {} into its fields", t.Name);
					for (let m in t.Members)
					{
						if (m.Kind != .Field || m.Static || m.Const)
							continue;
						AddPin(make, m.Name, m.Type);
						AddPin(brk, m.Name, m.Type, "out");
					}
				}
				if (t.Kind == .Enum)
				{
					let sw = NewSpec(outSpecs, t, .Call, scope $"Switch on {t.Name}");
					sw.KindWord.Set("Switch");
					sw.Subject.Set(t.FullName);
					sw.Tooltip.AppendF("Runs the output of the {} case the value is", t.Name);
					for (let m in t.Members)
					{
						if (m.Kind != .Case)
							continue;
						sw.EnumCases.Add(new String(m.Name));
						let mk = NewSpec(outSpecs, t, .Pure, scope $"Make {t.Name}.{m.Name}");
						mk.KindWord.Set("MakeCase");
						mk.Subject.AppendF("{}.{}", t.FullName, m.Name);
						mk.ReturnType.Set(t.FullName);
						for (let p in m.Payload)
							AddPin(mk, p.Name, p.Type);
						let isc = NewSpec(outSpecs, t, .Pure, scope $"Is {t.Name}.{m.Name}");
						isc.KindWord.Set("IsCase");
						isc.Subject.AppendF("{}.{}", t.FullName, m.Name);
						isc.ReturnType.Set("bool");
						for (let p in m.Payload)
							AddPin(isc, p.Name, p.Type, "out");
					}
				}
				for (let m in t.Members)
				{
					if (!ProjectType.Visible(m))
						continue;
					switch (m.Kind)
					{
					case .Field, .Property:
						String type = m.Type?.ToString(.. scope String()) ?? "";
						let get = NewSpec(outSpecs, t, .Get, scope $"Get {m.Name}");
						get.MemberName.Set(m.Name);
						get.OwnerType.Set(t.FullName);
						get.CallName.AppendF("{}.{}", t.FullName, m.Name);
						get.ReturnType.Set(type);
						get.IsStatic = m.Static || t.Static;
						get.Tooltip.AppendF("{} {}.{}", type, t.Name, m.Name);
						if (m.Const)
							continue;
						let set = NewSpec(outSpecs, t, .Set, scope $"Set {m.Name}");
						set.MemberName.Set(m.Name);
						set.OwnerType.Set(t.FullName);
						set.CallName.AppendF("{}.{}", t.FullName, m.Name);
						set.ReturnType.Set(type);
						set.IsStatic = m.Static || t.Static;
						set.Tooltip.AppendF("{}.{} = value", t.Name, m.Name);
					case .Function:
						bool pure = m.Pure;
						let call = NewSpec(outSpecs, t, pure ? .Pure : .Call, m.Name);
						call.MemberName.Set(m.Name);
						call.OwnerType.Set(t.FullName);
						String sig = Signature(m, .. scope String());
						if (m.Static || t.Static)
							call.CallName.AppendF("{}.{}{}", t.FullName, m.Name, sig);
						else
							call.CallName.AppendF("{}{}", m.Name, sig);
						call.IsStatic = m.Static || t.Static;
						m.Returns?.ToString(call.ReturnType);
						for (let p in m.Params)
						{
							StringView mod = (p.Mode == .Ref) ? "ref" : ((p.Mode == .Out) ? "out" : ((p.Mode == .In) ? "in" : ""));
							AddPin(call, p.Name, p.Type, mod, p.Default ?? "");
						}
						for (let p in m.Outs)
							AddPin(call, p.Name, p.Type, "out");
						call.Tooltip.AppendF("{}.{}{}", t.Name, m.Name, sig);
						if (m.Doc != null)
							call.Tooltip.AppendF("\n{}", m.Doc);
					default:
					}
				}
			}
		}

		static void AddAllocation(List<NodeSpec> outSpecs, ProjectType t, MemberDecl ctor)
		{
			String args = scope .();
			if (ctor != null && !ctor.Params.IsEmpty)
			{
				args.Append(" (");
				for (let p in ctor.Params)
				{
					if (@p.Index > 0)
						args.Append(", ");
					p.Type?.ToString(args);
				}
				args.Append(')');
			}
			for (int i < 2)
			{
				bool local = i == 1;
				let s = NewSpec(outSpecs, t, .Call, scope $"{(local ? "Local" : "Construct")} {t.Name}{args}");
				s.KindWord.Set(local ? "Local" : "Construct");
				s.Subject.Set(t.FullName);
				s.ReturnType.Set(t.FullName);
				s.Tooltip.Set(local ? "Allocates in this region; freed when the region ends" : "Allocates on the heap; you delete it");
				if (ctor != null)
					for (let p in ctor.Params)
						AddPin(s, p.Name, p.Type);
			}
		}
	}
}

namespace Treadle.Editor
{
	extension EditorApp
	{
		/// Reads the project's types again where they changed (open documents count with their
		/// unsaved edits). Cheap when nothing changed: the Node menu calls it on every open, the
		/// frame loop about twice a second.
		public void RefreshProjectTypes()
		{
			// Nothing to read again while the folder index and every open document are as they were at
			// the last rescan (the rescan copies every type's members: milliseconds at 200 types).
			uint64 stamp = 1469598103934665603UL;
			void Mix(uint64 v)
			{
				stamp ^= v;
				stamp *= 1099511628211UL;
			}
			Mix((uint64)Index.Version);
			Mix((uint64)Index.Root.GetHashCode());
			for (let d in mDocs)
			{
				Mix((uint64)(int)Internal.UnsafeCastToPtr(d));
				Mix((uint64)d.Version);
				Mix((uint64)d.FilePath.GetHashCode());
			}
			if (stamp == mProjectTypesStamp && mProjectTypesIndexVersion == Index.Version)
				return;
			List<TypeDocument> open = scope .();
			for (let d in mDocs)
				open.Add(d);
			ProjectTypes.Rescan(Language, Index, open);
			mProjectTypesIndexVersion = Index.Version;
			mProjectTypesStamp = stamp;
		}

		/// The index version and open documents (address, version, path) at the last rescan.
		uint64 mProjectTypesStamp;

		void TickProjectTypes()
		{
			if (++mProjectTypesFrame < 30 && mProjectTypesIndexVersion == Index.Version)
				return;
			mProjectTypesFrame = 0;
			RefreshProjectTypes();
		}
	}
}
