using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Catalog;
using Treadle.Document;
using Treadle.Language;

namespace Treadle.Compiler
{
	/// The front end as the editor's language services (FORK-NOTES.md, "Seams"): the type
	/// system, the Node menu's catalogue and the language rules over one Compilation of the
	/// workspace, rebuilt when a document, a Sheet or the project's files changed.
	///
	/// `Install` puts them into a LanguageContext; the context does not own them, this object
	/// does (the editor keeps it next to the context and deletes it after the documents).
	class FrontEndServices
	{
		LanguageContext mCtx;
		List<TypeDocument> mOpen;
		DocCache mCache = new .() ~ delete _;
		ProjectFile mProject ~ delete _;
		String mProjectPath = new .() ~ delete _;
		DateTime mProjectTime;
		Compilation mLast ~ delete _;
		uint64 mFingerprint;
		int32 mGeneration = 1;
		/// Bumps only when what the types declare may have changed (a full compile, or an incremental one that
		/// declared types again): an edit inside Sheets keeps the type table, so the catalogue and the type
		/// name answers built from it stay valid.
		int32 mDeclGeneration = 1;
		/// The last Refresh only bound edited Sheets again.
		bool mSheetsOnly;

		public TreadleTypeSystem Types ~ delete _;
		public TreadleCatalogSource Catalog ~ delete _;
		public TreadleRules Rules ~ delete _;

		public int32 Generation => mGeneration;
		public int32 DeclGeneration => mDeclGeneration;
		public LanguageContext Context => mCtx;

		/// `open`: the editor's open documents (the list is the editor's; read on every run).
		public this(LanguageContext ctx, List<TypeDocument> open)
		{
			mCtx = ctx;
			mOpen = open;
			Types = new .(this);
			Catalog = new .(this);
			Rules = new .(this);
			ctx.Types = Types;
			ctx.Catalog = Catalog;
			ctx.Rules = Rules;
		}

		uint64 Fingerprint()
		{
			uint64 h = 1469598103934665603UL;
			void Mix(uint64 v) mut
			{
				h ^= v;
				h *= 1099511628211UL;
			}
			let index = mCtx.Index;
			if (index != null)
			{
				Mix((uint64)index.Version);
				Mix((uint64)index.Root.GetHashCode());
			}
			if (mOpen != null)
				for (let d in mOpen)
				{
					Mix((uint64)(int)Internal.UnsafeCastToPtr(d));
					Mix((uint64)d.Version);
					Mix((uint64)d.FilePath.GetHashCode());
					for (let s in d.Sheets)
						if (s.IsBuilt)
						{
							Mix((uint64)s.Graph.Serial);
							Mix((uint64)s.Graph.Version);
							Mix((uint64)s.Graph.Nodes.Count);
							Mix((uint64)s.Graph.Links.Count);
						}
				}
			return h;
		}

		/// Incremental Validate (Compiler.md 9): an edit inside Sheets re-binds only those Sheets; a
		/// declaration change or a new type file declares the changed types and their dependents
		/// again and binds only the Sheets that can see it (Compilation.Redeclare); a change to the
		/// project file or the C import sets, or a type file that went away, compiles everything.
		public bool Incremental = true;
		/// The last refresh: milliseconds, whether it was incremental, how many Sheets it bound and
		/// how many types it declared.
		public double LastMs;
		public bool LastWasIncremental;
		public int LastSheets;
		public int LastTypes;
		Dictionary<TypeDocument, uint64> mDecls = new .() ~ delete _;
		Dictionary<Sheet, uint64> mSheetSigs = new .() ~ delete _;
		/// What the last compilation was made from: the folder and project file, the folder index's
		/// version, the files its scan listed (with its Load diagnostics) and the open documents.
		uint64 mProjectStamp;
		int32 mIndexVersion = -1;
		List<(String path, String project)> mTypePaths = new .() ~ { for (let t in _) { delete t.path; delete t.project; } delete _; };
		List<String> mImportPaths = new .() ~ DeleteContainerAndItems!(_);
		List<String> mScanDiags = new .() ~ DeleteContainerAndItems!(_);
		/// The open documents by address (a closed one may be gone: never read through these).
		HashSet<int> mWasOpen = new .() ~ delete _;

		/// The folder and its project file (path and time).
		uint64 ProjectStamp(StringView root)
		{
			uint64 h = 1469598103934665603UL;
			void Mix(uint64 v)
			{
				h ^= v;
				h *= 1099511628211UL;
			}
			Mix((uint64)root.GetHashCode());
			String path = scope .();
			ProjectLoader.FindProjectFile(root, path);
			Mix((uint64)path.GetHashCode());
			if (!path.IsEmpty && System.IO.File.GetLastWriteTime(path) case .Ok(let t))
				Mix((uint64)t.Ticks);
			return h;
		}

		static bool IsScanCode(StringView code) => code == "T0012" || code == "T0013" || code == "T0014" || code == "T0015" || code == "T0016";

		static void ScanDiags(Compilation c, List<String> outLines)
		{
			for (let d in c.Diags.Items)
				if (d.Stage == .Load && IsScanCode(d.Code))
					outLines.Add(new String(scope $"{d.Code} {d.File} {d.Message}"));
		}

		void Remember(StringView root)
		{
			mProjectStamp = ProjectStamp(root);
			mIndexVersion = (mCtx.Index != null) ? mCtx.Index.Version : -1;
			mDecls.Clear();
			mSheetSigs.Clear();
			mWasOpen.Clear();
			if (mOpen == null)
				return;
			for (let d in mOpen)
			{
				mWasOpen.Add((int)Internal.UnsafeCastToPtr(d));
				mDecls[d] = DeclSignature.Of(d);
				for (let s in d.Sheets)
					mSheetSigs[s] = DeclSignature.OfSheet(s);
			}
		}

		/// The folder index changed: lists the files again. False when the C import sets or the
		/// scan's own diagnostics differ (a full compile reads them).
		bool Rescan(StringView root)
		{
			Compilation scratch = scope .();
			List<(String path, String project)> types = scope .();
			List<String> imports = scope .();
			List<String> diags = scope .();
			defer { for (let t in types) { delete t.path; delete t.project; } ClearAndDeleteItems!(imports); ClearAndDeleteItems!(diags); }
			ProjectLoader.ListFiles(scratch, root, mProject, types, imports);
			ScanDiags(scratch, diags);
			if (imports.Count != mImportPaths.Count || diags.Count != mScanDiags.Count)
				return false;
			for (int i < imports.Count)
				if (!ProjectIndex.SamePath(imports[i], mImportPaths[i]))
					return false;
			for (int i < diags.Count)
				if (diags[i] != mScanDiags[i])
					return false;
			for (let t in mTypePaths)
			{
				delete t.path;
				delete t.project;
			}
			mTypePaths.Clear();
			mTypePaths.AddRange(types);
			types.Clear();
			return true;
		}

		/// Brings the last compilation up to date in place: the type documents a full compile would
		/// read now against the units it has. False when a full compile is needed.
		bool Refresh(StringView root)
		{
			if (mLast == null || mOpen == null || ProjectStamp(root) != mProjectStamp)
				return false;
			let version = (mCtx.Index != null) ? mCtx.Index.Version : -1;
			let rescan = version != mIndexVersion;
			if (rescan && !Rescan(root))
				return false;
			List<SourceUnit> have = scope .();
			for (let u in mLast.Units)
				if (!u.IsCore && !u.IsCDecl)
					have.Add(u);
			List<SourceUnit> order = scope .();
			List<SourceUnit> changed = scope .();
			List<SourceUnit> added = scope .();
			List<Sheet> edited = scope .();
			HashSet<SourceUnit> matched = scope .();
			bool owned = true;
			defer
			{
				if (owned)
					for (let n in added)
						delete n;
			}
			void Compare(SourceUnit u, TypeDocument doc)
			{
				matched.Add(u);
				order.Add(u);
				if (u.Doc != doc)
				{
					u.Doc = doc;
					changed.Add(u);
					return;
				}
				if (!mWasOpen.Contains((int)Internal.UnsafeCastToPtr(doc)))
					return;
				if (!mDecls.TryGetValue(doc, let decl) || decl != DeclSignature.Of(doc))
				{
					changed.Add(u);
					return;
				}
				for (let s in doc.Sheets)
					if (!mSheetSigs.TryGetValue(s, let old) || old != DeclSignature.OfSheet(s))
						edited.Add(s);
			}
			for (int i < mTypePaths.Count)
			{
				let path = mTypePaths[i].path;
				SourceUnit u = null;
				if (i < have.Count && ProjectIndex.SamePath(have[i].Path, path))
					u = have[i];
				else
					for (let h in have)
						if (ProjectIndex.SamePath(h.Path, path))
							u = h;
				TypeDocument doc = null;
				for (let d in mOpen)
					if (!d.FilePath.IsEmpty && ProjectIndex.SamePath(d.FilePath, path))
						doc = d;
				if (doc == null)
				{
					if (u != null && !rescan && !mWasOpen.Contains((int)Internal.UnsafeCastToPtr(u.Doc)))
						doc = u.Doc;
					else
						doc = mCache.Get(path, scope String());
				}
				if (doc == null)
					return false;
				if (u == null)
				{
					SourceUnit n = new .();
					n.Doc = doc;
					n.Path.Set(path);
					n.Project.Set(mTypePaths[i].project);
					added.Add(n);
					order.Add(n);
					continue;
				}
				Compare(u, doc);
			}
			// Open documents outside the folder (an untitled one): matched by the object.
			for (let d in mOpen)
			{
				if (!d.FilePath.IsEmpty || d.Header.Name.IsEmpty)
					continue;
				SourceUnit u = null;
				for (let h in have)
					if (h.Path.IsEmpty && h.Doc == d)
						u = h;
				if (u != null)
				{
					Compare(u, d);
					continue;
				}
				SourceUnit n = new .();
				n.Doc = d;
				added.Add(n);
				order.Add(n);
			}
			if (matched.Count != have.Count)
				return false;
			if (changed.IsEmpty && added.IsEmpty)
			{
				for (let s in edited)
					if (let u = mLast.FindUnit(s.Doc))
						mLast.Rebind(u, s);
				LastSheets = edited.Count;
				LastTypes = 0;
				mSheetsOnly = true;
				return true;
			}
			// The units in the order a full compile reads them: the core, the project's types, its C sets.
			List<SourceUnit> units = scope .(mLast.Units.Count + added.Count);
			for (let u in mLast.Units)
				if (u.IsCore)
					units.Add(u);
			units.AddRange(order);
			for (let u in mLast.Units)
				if (!u.IsCore && u.IsCDecl)
					units.Add(u);
			mLast.Units.Clear();
			mLast.Units.AddRange(units);
			// From here the new units belong to the compilation (deleted with it on a full compile).
			owned = false;
			if (!mLast.Redeclare(changed, added, edited, let types, let sheets))
				return false;
			LastSheets = sheets;
			LastTypes = types;
			return true;
		}

		/// The compilation of the workspace as it is now (cached while nothing changed). Takes
		/// FrontEndBuild.Lock: a Build may be lowering on its thread.
		public Compilation Current
		{
			get
			{
				using (FrontEndBuild.Lock.Enter())
					return Compute();
			}
		}

		Compilation Compute()
		{
			{
				let fp = Fingerprint();
				if (mLast != null && fp == mFingerprint)
					return mLast;
				let sw = scope System.Diagnostics.Stopwatch(true);
				let root = (mCtx.Index != null) ? (StringView)mCtx.Index.Root : "";
				mSheetsOnly = false;
				if (Incremental && Refresh(root))
				{
					if (!mSheetsOnly)
						mDeclGeneration++;
					Remember(root);
					LastWasIncremental = true;
					LastMs = sw.Elapsed.TotalMilliseconds;
					mFingerprint = fp;
					mGeneration++;
					return mLast;
				}
				delete mLast;
				mLast = null;
				LoadProject(root);
				for (let t in mTypePaths)
				{
					delete t.path;
					delete t.project;
				}
				mTypePaths.Clear();
				ClearAndDeleteItems!(mImportPaths);
				ClearAndDeleteItems!(mScanDiags);
				mLast = ProjectLoader.Make(root, mOpen, mCache, mProject, null, mTypePaths, mImportPaths);
				ScanDiags(mLast, mScanDiags);
				mLast.Run();
				Remember(root);
				LastWasIncremental = false;
				LastSheets = mLast.ResultList.Count;
				LastTypes = 0;
				for (let u in mLast.Units)
					if (u.Sym != null && !u.IsCore && !u.IsCDecl)
						LastTypes++;
				mDeclGeneration++;
				LastMs = sw.Elapsed.TotalMilliseconds;
				mFingerprint = fp;
				mGeneration++;
				return mLast;
			}
		}

		/// The last compilation without rebuilding (null before the first).
		public Compilation Last => mLast;

		void LoadProject(StringView root)
		{
			if (root.IsEmpty)
				return;
			List<String> types = scope .();
			List<String> imports = scope .();
			defer { ClearAndDeleteItems!(types); ClearAndDeleteItems!(imports); }
			String path = scope .();
			for (let e in System.IO.Directory.EnumerateFiles(root))
			{
				let p = e.GetFilePath(.. scope String());
				if (Treadle.Format.FormatNames.IsProjectFile(p))
				{
					path.Set(p);
					break;
				}
			}
			DateTime time = default;
			if (!path.IsEmpty && System.IO.File.GetLastWriteTime(path) case .Ok(let t))
				time = t;
			if (path == mProjectPath && time == mProjectTime)
				return;
			DeleteAndNullify!(mProject);
			mProjectPath.Set(path);
			mProjectTime = time;
			if (!path.IsEmpty)
				mProject = ProjectLoader.ReadProject(path);
		}

		/// The diagnostics of the Sheet whose graph is `g` (as the editor shows them).
		public void ReportOn(Graph g)
		{
			let comp = Current;
			SheetResult found = null;
			for (let r in comp.ResultList)
				if (r.Source == g)
					found = r;
			if (found == null)
				return;
			let doc = found.Sheet.Doc;
			bool firstSheet = doc.Sheets.Count > 0 && doc.Sheets[0] == found.Sheet;
			for (let d in comp.Diags.Items)
			{
				if (d.Severity == .Note)
					continue;
				Node node = null;
				if (d.Type == found.SiteType && d.Sheet == found.Sheet.Key)
					node = d.Node.IsEmpty ? null : DiagnosticMap.FindByKey(g, d.Node);
				else if (d.Type == found.SiteType && d.Sheet.IsEmpty && !d.Member.IsEmpty && d.Member == found.Member.Id)
					node = g.Entry;
				else if (d.Type == found.SiteType && d.Sheet.IsEmpty && d.Member.IsEmpty && firstSheet)
					node = g.Entry;
				else if (d.Type.IsEmpty && firstSheet && !d.File.IsEmpty && ProjectIndex.SamePath(d.File, doc.FilePath))
					node = g.Entry;
				else
					continue;
				if (d.Severity == .Error)
					g.AddError(node, d.Message);
				else
					g.AddWarning(node, d.Message);
			}
		}

		/// "evaluated Nx" for every value node of `g` (node id -> count; nodes evaluated by nothing are
		/// left out). False when the last compilation is not of the workspace as it is now or does
		/// not cover `g`; the editor then keeps its own count.
		public bool EvaluationCounts(Graph g, Dictionary<int32, int32> outCounts)
		{
			let comp = mLast;
			if (comp == null || Fingerprint() != mFingerprint)
				return false;
			for (let r in comp.ResultList)
				if (r.Source == g)
				{
					outCounts.Clear();
					for (let n in g.Nodes)
					{
						let b = r.Get(n);
						if (b != null && !b.Flow && b.EvalCount > 0)
							outCounts[n.Id] = (int32)b.EvalCount;
					}
					return true;
				}
			return false;
		}

		/// "evaluated Nx": the number of flow nodes that evaluate a value node (0 when it is not
		/// a value node or nothing evaluates it).
		public int EvaluationCount(Graph g, Node n)
		{
			let comp = mLast;
			if (comp == null)
				return 0;
			for (let r in comp.ResultList)
				if (r.Source == g)
				{
					let b = r.Get(n);
					return (b != null && !b.Flow) ? b.EvalCount : 0;
				}
			return 0;
		}
	}

	/// ILanguageRules: Validate = Declare + Bind + Check of the workspace; each Sheet gets its
	/// own diagnostics on its nodes.
	class TreadleRules : ILanguageRules
	{
		FrontEndServices mServices;

		public this(FrontEndServices s)
		{
			mServices = s;
		}

		public void Check(Graph g)
		{
			mServices.ReportOn(g);
		}

		public bool CheckExpression(StringView text, String outWhy)
		{
			String why = scope .();
			let tree = MathExpr.Build(text, why);
			if (tree == null)
			{
				outWhy?.Set(why);
				return false;
			}
			delete tree;
			return true;
		}
	}

	/// ITypeSystem over the compilation's type table. Names are the format's spelling with full
	/// names (`Game.Player`, `Core.` may be left out); a name the table does not know falls back
	/// to the generic rules (TypeRules).
	class TreadleTypeSystem : ITypeSystem
	{
		FrontEndServices mServices;
		Dictionary<String, KType> mNames = new .() ~ DeleteDictionaryAndKeys!(_);
		int32 mNamesGen = -1;

		public this(FrontEndServices s)
		{
			mServices = s;
		}

		public int32 Generation => mServices.DeclGeneration;

		Compilation Comp
		{
			get
			{
				if (mServices.Last == null)
					return mServices.Current;
				return mServices.Last;
			}
		}

		/// The type a name stands for (null when unknown).
		public KType Lookup(StringView name)
		{
			var name;
			name.Trim();
			if (name.IsEmpty)
				return null;
			let comp = Comp;
			if (mNamesGen != mServices.DeclGeneration)
			{
				for (let kv in mNames)
					delete kv.key;
				mNames.Clear();
				mNamesGen = mServices.DeclGeneration;
			}
			if (mNames.TryGetValueAlt(name, let cached))
				return cached;
			let tr = TypeRef.Parse(name);
			defer delete tr;
			NameCtx ctx = .(null, null, .(""));
			ctx.Quiet = true;
			var t = comp.Resolve(tr, ctx);
			if (t != null && t.IsError)
			{
				// A short name of a project type (`Player`): unique among the table.
				TypeSym only = null;
				int count = 0;
				for (let s in comp.Table.Types)
					if (s.Name == tr.Name)
					{
						only = s;
						count++;
					}
				t = (count == 1 && !only.IsGeneric && tr.Kind == .Named && (tr.Args == null || tr.Args.IsEmpty)) ? only.Self : null;
			}
			if (t != null && t.IsError)
				t = null;
			mNames[new String(name)] = t;
			return t;
		}

		public void KindOf(StringView typeName, String outKind)
		{
			let t = Lookup(typeName);
			if (t == null || t.Kind != .Named)
				return;
			switch (t.Sym.Kind)
			{
			case .Class: outKind.Append("class");
			case .Struct: outKind.Append("struct");
			case .Interface: outKind.Append("interface");
			case .Enum: outKind.Append("enum");
			case .Delegate: outKind.Append("delegate");
			case .Extension: outKind.Append("extension");
			}
		}

		public bool IsSubtype(StringView derived, StringView baseType)
		{
			let a = Lookup(derived);
			let b = Lookup(baseType);
			if (a == null || b == null || a == b)
				return false;
			return Comp.Table.IsSubclass(a, b) || Comp.Table.Implements(a, b);
		}

		public TypeFamily Family(StringView typeName)
		{
			let t = Lookup(typeName);
			if (t == null)
				return TypeRules.Family(typeName, this);
			let table = Comp.Table;
			switch (t.Kind)
			{
			case .Bool: return .Bool;
			case .Int: return .Int;
			case .Float: return .Float;
			case .Char: return .Char;
			case .Void: return .Void;
			case .Pointer, .Function: return .Pointer;
			case .Delegate: return .Delegate;
			case .Param: return .Wildcard;
			case .Vector: return TypeRules.Family(typeName, this); // the editor's rule for vector names (its Vector family)
			case .Array, .FixedArray: return TypeRules.Family(typeName, this);
			case .Nullable: return Family(t.Element.Name);
			case .Named:
				if (t.Sym == table.StringSym || t.Sym == table.StringViewSym)
					return .String;
				switch (t.Sym.Kind)
				{
				case .Class: return .Object;
				case .Struct: return .Struct;
				case .Interface: return .Interface;
				case .Enum: return .Enum;
				case .Delegate: return .Delegate;
				default: return .Unknown;
				}
			default: return .Unknown;
			}
		}

		public Conversion CanConvert(StringView from, StringView to, String outWhy)
		{
			let a = Lookup(from);
			let b = Lookup(to);
			if (a == null || b == null)
				return TypeRules.CanConvert(from, to, outWhy, this);
			if (a.Kind == .Param || b.Kind == .Param)
				return .Unchecked;
			switch (Comp.Table.CanConvert(a, b, outWhy))
			{
			case .Exact: return .Exact;
			case .Implicit: return .Implicit;
			case .Refused: return .Refused;
			}
		}

		public PinValueKind ValueKind(StringView typeName, StringView current, StringView pinName)
		{
			let t = Lookup(typeName);
			if (t == null)
				return .Expr;
			let table = Comp.Table;
			switch (t.Kind)
			{
			case .Bool: return .Bool;
			case .Int, .Float: return .Number;
			case .Char: return .Char;
			case .Pointer:
				return (t.Element.Kind == .Char) ? .Text : .None;
			case .Named:
				if (t.Sym == table.StringSym || t.Sym == table.StringViewSym)
					return .Text;
				if (t.Sym.Kind == .Enum && !t.Sym.HasPayload)
					return .Enum;
				// a core math struct: its fields inline (Vec3, Color, ...)
				let mk = PinValue.MathValueKind(t.Sym.FullName, current, pinName);
				if (mk != .None)
					return mk;
				return .None;
			default:
				return .None;
			}
		}

		public void EnumMembers(StringView typeName, List<String> outMembers)
		{
			let t = Lookup(typeName);
			if (t == null || !t.IsEnum)
				return;
			for (let m in t.Sym.Members)
				if (m.Kind == .Case)
					outMembers.Add(new String(m.Name));
		}

		public void DefaultValue(StringView typeName, String outValue)
		{
			let t = Lookup(typeName);
			if (t == null)
				return;
			switch (t.Kind)
			{
			case .Bool: outValue.Append("false");
			case .Int: outValue.Append("0");
			case .Float: outValue.Append("0.0");
			case .Named:
				if (t.Sym.Kind == .Enum && !t.Sym.HasPayload)
					for (let m in t.Sym.Members)
						if (m.Kind == .Case)
						{
							outValue.AppendF(".{}", m.Name);
							return;
						}
			default:
			}
		}
	}

	/// INodeCatalogSource: the callable members of the project's types, the core library and the
	/// C import sets (functions as Call / value Call, fields and properties as Get / Set). The
	/// built-in flow nodes are the Node menu's own; `FlowNodeKinds` lists the ones the language
	/// has, for menus that want them from here.
	class TreadleCatalogSource : INodeCatalogSource
	{
		FrontEndServices mServices;

		public this(FrontEndServices s)
		{
			mServices = s;
		}

		public int32 Generation => mServices.DeclGeneration;

		/// Flow and lifetime nodes of the language (Language.md 5.1, 3), for the menu's built-ins.
		public static NodeKind[?] FlowNodeKinds = .(.Branch, .Sequence, .While, .DoWhile, .For, .ForEach, .Break, .Continue, .Switch, .Scope,
			.Defer, .DeferDelete, .Construct, .Local, .Delete, .ResultMatch, .Try, .Fatal, .Return);

		static void Category(TypeSym t, String outCat)
		{
			if (t.IsCImport || t.IsCRecord)
			{
				outCat.Append(t.Category ?? "C");
				outCat.Replace(" / ", "|");
				return;
			}
			if (t.IsCore)
			{
				outCat.AppendF("Core|{}", t.Name);
				return;
			}
			if (t.Static)
			{
				outCat.AppendF("Libraries|{}", t.Name);
				return;
			}
			if (!t.Namespace.IsEmpty)
				outCat.AppendF("{}|", t.Namespace);
			outCat.Append(t.Name);
		}

		/// Node kinds with a type subject (Construct / Local per visible constructor, Make / Break of
		/// a struct, Switch / Make Case / Is Case of an enum), as the editor's stand-in gave them.
		void KindEntries(TypeSym t, List<NodeSpec> outSpecs)
		{
			if (t.IsCImport || t.Kind == .Interface || t.Kind == .Delegate || t.AliasRef != null || t.COpaque)
				return;
			NodeSpec NewSpec(NodeEntryKind kind, StringView label)
			{
				NodeSpec s = new .();
				s.Kind = kind;
				s.Label.Set(label);
				s.DisplayName.Set(label);
				Category(t, s.Category);
				s.Namespace.Set(t.Namespace);
				s.Subject.Set(t.FullName);
				s.Keywords.Append(t.Name);
				for (let gp in t.Generics)
					s.TypeGenerics.AppendF("{}{}", s.TypeGenerics.IsEmpty ? "" : ",", gp.Name);
				outSpecs.Add(s);
				return s;
			}
			void AddPin(NodeSpec s, ParamSym p, bool output)
			{
				PinSpec ps = new .();
				ps.Name.Set(p.Name);
				ps.Label.Set(p.Name);
				TypeTable.Show(p.Type, ps.Type);
				if (output)
					ps.Modifier.Set("out");
				s.Pins.Add(ps);
			}
			if ((t.Kind == .Class || t.Kind == .Struct) && !t.Static && !t.Abstract)
			{
				bool anyCtor = false;
				for (let m in t.Members)
				{
					if (m.Kind != .Ctor || m.Static || m.Access == .Private || m.Synthetic)
						continue;
					anyCtor = true;
					String args = scope .();
					for (let p in m.Params)
					{
						args.Append((@p.Index == 0) ? " (" : ", ");
						TypeTable.Show(p.Type, args);
					}
					if (!args.IsEmpty)
						args.Append(')');
					for (int i < 2)
					{
						let s = NewSpec(.Call, scope $"{(i == 1) ? "Local" : "Construct"} {t.Name}{args}");
						s.KindWord.Set((i == 1) ? "Local" : "Construct");
						s.ReturnType.Set(t.FullName);
						s.Tooltip.Set((i == 1) ? "Allocates in this region; freed when the region ends" : "Allocates on the heap; you delete it");
						for (let p in m.Params)
							AddPin(s, p, false);
					}
				}
				if (!anyCtor)
					for (int i < 2)
					{
						let s = NewSpec(.Call, scope $"{(i == 1) ? "Local" : "Construct"} {t.Name}");
						s.KindWord.Set((i == 1) ? "Local" : "Construct");
						s.ReturnType.Set(t.FullName);
					}
			}
			if (t.Kind == .Struct)
			{
				let make = NewSpec(.Pure, scope $"Make {t.Name}");
				make.KindWord.Set("Make");
				make.ReturnType.Set(t.FullName);
				make.Tooltip.AppendF("Builds a {} from its fields", t.Name);
				let brk = NewSpec(.Pure, scope $"Break {t.Name}");
				brk.KindWord.Set("Break");
				brk.Tooltip.AppendF("Splits a {} into its fields", t.Name);
				for (let m in t.Members)
				{
					if (m.Kind != .Field || m.Static || m.Const)
						continue;
					for (int i < 2)
					{
						PinSpec ps = new .();
						ps.Name.Set(m.Name);
						ps.Label.Set(m.Name);
						TypeTable.Show(m.Type, ps.Type);
						if (i == 1)
							ps.Modifier.Set("out");
						((i == 0) ? make : brk).Pins.Add(ps);
					}
				}
			}
			if (t.Kind == .Enum)
			{
				let sw = NewSpec(.Call, scope $"Switch on {t.Name}");
				sw.KindWord.Set("Switch");
				sw.Tooltip.AppendF("Runs the output of the {} case the value is", t.Name);
				for (let m in t.Members)
				{
					if (m.Kind != .Case)
						continue;
					sw.EnumCases.Add(new String(m.Name));
					let mk = NewSpec(.Pure, scope $"Make {t.Name}.{m.Name}");
					mk.KindWord.Set("MakeCase");
					mk.Subject.AppendF(".{}", m.Name);
					mk.ReturnType.Set(t.FullName);
					for (let p in m.Payload)
						AddPin(mk, p, false);
					let isc = NewSpec(.Pure, scope $"Is {t.Name}.{m.Name}");
					isc.KindWord.Set("IsCase");
					isc.Subject.AppendF(".{}", m.Name);
					isc.ReturnType.Set("bool");
					for (let p in m.Payload)
						AddPin(isc, p, true);
				}
			}
		}

		public void Entries(List<NodeSpec> outSpecs)
		{
			VectorCatalogSource.Entries(outSpecs); // VectorCatalogSource.bf: Core.Vector and the vector forms of Core.Math
			let comp = mServices.Current;
			for (let t in comp.Table.Types)
			{
				// The core's own C import set and its internal members are not offered.
				if (t.IsCore && t.IsCImport)
					continue;
				KindEntries(t, outSpecs);
				// An enum's rows are its cases (KindEntries), plus what extensions add to it.
				if (t.Kind == .Delegate || t.Kind == .Extension || (t.Kind == .Enum && t.Extensions == null))
					continue;
				for (let m in t.Members)
				{
					if (m.Access == .Private || m.Synthetic || (t.IsCore && m.Access == .Internal && m.Extension == null))
						continue;
					switch (m.Kind)
					{
					case .Function:
						outSpecs.Add(Function(t, m));
					case .Field, .Property:
						if (m.EventOf != null)
							EventEntries(t, m, outSpecs);
						else
						{
							outSpecs.Add(Variable(t, m, false));
							if (!m.Const && !m.Readonly && (m.Kind == .Field || m.HasSet))
								outSpecs.Add(Variable(t, m, true));
						}
					default:
					}
				}
			}
		}

		NodeSpec Function(TypeSym t, MemberSym m)
		{
			NodeSpec s = new .();
			s.Kind = m.Pure ? .Pure : .Call;
			s.Label.Set(m.Name);
			s.DisplayName.Set(m.Name);
			Category(t, s.Category);
			s.CallName.AppendF("{}.{}", t.FullName, m.Name);
			s.MemberName.Set(m.Name);
			s.OwnerType.Set(t.FullName);
			s.Namespace.Set(t.Namespace);
			s.IsStatic = m.Static;
			s.IsGeneric = m.IsGeneric || t.IsGeneric;
			s.IsVariadic = m.Variadic;
			if (!m.Returns.IsVoid)
				TypeTable.Show(m.Returns, s.ReturnType);
			for (let p in m.Params)
			{
				PinSpec ps = new .();
				ps.Name.Set(p.Name);
				ps.Label.Set(p.Name);
				TypeTable.Show(p.Type, ps.Type);
				if (p.Default != null)
					ps.Default.Set(p.Default);
				if (p.IsRef)
					ps.Modifier.Set("ref");
				s.Pins.Add(ps);
				if (@p.Index > 0)
					s.ParamsText.Append(", ");
				s.ParamsText.AppendF("{} {}", ps.Type, p.Name);
			}
			for (let p in m.Outs)
			{
				PinSpec ps = new .();
				ps.Name.Set(p.Name);
				ps.Label.Set(p.Name);
				TypeTable.Show(p.Type, ps.Type);
				ps.Modifier.Set("out");
				s.Pins.Add(ps);
			}
			if (m.IsImport)
				s.Keywords.Append("c import ");
			if (m.Intrinsic != null)
				s.Keywords.Append("core ");
			s.Keywords.Append(t.Name);
			String sig = scope .();
			m.GetFullName(sig);
			s.Tooltip.Set(sig);
			return s;
		}

		/// An event's nodes (Language.md 4, Event): Add, Remove, Invoke, Clear (flow Calls) and Count
		/// (a value node), each a Call of `<Type>.<event>.<node>` with the object as its Receiver.
		void EventEntries(TypeSym t, MemberSym m, List<NodeSpec> outSpecs)
		{
			let d = m.EventOf;
			for (let op in StringView[?]("Add", "Remove", "Invoke", "Clear", "Count"))
			{
				NodeSpec s = new .();
				s.Kind = (op == "Count") ? .Pure : .Call;
				switch (op)
				{
				case "Add": s.Label.AppendF("Add to {}", m.Name);
				case "Remove": s.Label.AppendF("Remove from {}", m.Name);
				case "Count": s.Label.AppendF("{} Count", m.Name);
				default: s.Label.AppendF("{} {}", op, m.Name);
				}
				s.DisplayName.Set(s.Label);
				Category(t, s.Category);
				s.CallName.AppendF("{}.{}.{}", t.FullName, m.Name, op);
				s.MemberName.AppendF("{}.{}", m.Name, op);
				s.OwnerType.Set(t.FullName);
				s.Namespace.Set(t.Namespace);
				s.IsStatic = m.Static;
				void Pin(StringView name, KType type, bool output)
				{
					PinSpec ps = new .();
					ps.Name.Set(name);
					ps.Label.Set(name);
					TypeTable.Show(type, ps.Type);
					if (output)
						ps.Modifier.Set("out");
					s.Pins.Add(ps);
				}
				switch (op)
				{
				case "Add":
					Pin("handler", d, false);
					s.Tooltip.AppendF("Adds a handler to {} (the event owns it: Remove or the destructor deletes it)", m.Name);
				case "Remove":
					Pin("handler", d, false);
					s.ReturnType.Set("bool");
					s.Tooltip.AppendF("Removes that handler from {} and deletes it; false when {} does not hold it", m.Name, m.Name);
				case "Invoke":
					for (int i < d.Args.Count)
						Pin(scope $"arg{i}", d.Args[i], false);
					s.Tooltip.AppendF("Calls every handler of {} in the order they were added", m.Name);
				case "Clear":
					s.Tooltip.AppendF("Deletes every handler of {}", m.Name);
				case "Count":
					s.ReturnType.Set("int");
					s.Tooltip.AppendF("The number of handlers of {}", m.Name);
				}
				s.Keywords.AppendF("{} event", t.Name);
				outSpecs.Add(s);
			}
		}

		NodeSpec Variable(TypeSym t, MemberSym m, bool set)
		{
			NodeSpec s = new .();
			s.Kind = set ? .Set : .Get;
			s.Label.AppendF("{}{}", set ? "Set " : "", m.Name);
			s.DisplayName.Set(m.Name);
			Category(t, s.Category);
			s.MemberName.Set(m.Name);
			s.OwnerType.Set(t.FullName);
			s.Namespace.Set(t.Namespace);
			s.IsStatic = m.Static;
			TypeTable.Show(m.Type, s.ReturnType);
			s.Keywords.Append(t.Name);
			return s;
		}

		/// Whether an entry fits a pin being dragged from (`fromOutput`: the pin is an output,
		/// so the entry needs an input of that type). Unknown types always fit.
		public bool Fits(NodeSpec spec, StringView pinType, bool fromOutput)
		{
			let types = mServices.Types;
			if (pinType.IsEmpty || types.Lookup(pinType) == null)
				return true;
			if (fromOutput)
			{
				if (!spec.IsStatic && !spec.OwnerType.IsEmpty && types.CanConvert(pinType, spec.OwnerType, null) != .Refused)
					return true;
				for (let p in spec.Pins)
					if (!p.IsOutput && types.CanConvert(pinType, p.Type, null) != .Refused)
						return true;
				return false;
			}
			if (!spec.ReturnType.IsEmpty && types.CanConvert(spec.ReturnType, pinType, null) != .Refused)
				return true;
			for (let p in spec.Pins)
				if (p.IsOutput && types.CanConvert(p.Type, pinType, null) != .Refused)
					return true;
			return false;
		}

		/// The entries that fit a pin (the Node menu's context list).
		public void EntriesFor(StringView pinType, bool fromOutput, List<NodeSpec> outSpecs)
		{
			List<NodeSpec> all = scope .();
			Entries(all);
			for (let s in all)
			{
				if (Fits(s, pinType, fromOutput))
					outSpecs.Add(s);
				else
					delete s;
			}
		}
	}
}
