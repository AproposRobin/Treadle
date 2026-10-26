using System;
using System.Collections;
using Treadle.Model;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	/// One type file the compilation reads: a project type, a core library type, or the
	/// declarations of a C import set (`<set>.cdecl`, the record format, Compiler.md 8).
	class SourceUnit
	{
		public TypeDocument Doc;
		public bool OwnsDoc;
		public String Path = new .() ~ delete _;
		public bool IsCore;
		/// The project it belongs to: "" for the compiled project, a `depends` project's name.
		public String Project = new .() ~ delete _;
		/// A C import set's declarations: Set is the `import` record.
		public bool IsCDecl;
		public CImportSet Set;
		/// The folder of the `.cimport` file (a set's `lib` and `bin` paths are relative to it).
		public String SetDir = new .() ~ delete _;
		public TypeSym Sym;

		public ~this()
		{
			if (OwnsDoc)
				delete Doc;
		}
	}

	/// One run of the front end over a project: Declare (the type table), Bind and Check (every
	/// Sheet), and on request Lower (the Sheet IR). The editor's Validate and the command line
	/// make one per run; the documents are the editor's own objects, read but never changed
	/// (except that pins get their types, which the writer never writes).
	class Compilation
	{
		public TypeTable Table = new .() ~ delete _;
		public DiagBag Diags = new .() ~ delete _;
		public List<SourceUnit> Units = new .() ~ DeleteContainerAndItems!(_);
		/// The project file, when the project has one (not owned).
		public ProjectFile Project;
		/// The project files of the `depends` projects (owned).
		public List<ProjectFile> DependProjects = new .() ~ DeleteContainerAndItems!(_);
		/// Debug build: Lower emits null and bounds checks.
		public bool Debug = true;
		/// The config being built (Build only; null for Validate and the editor's queries): its
		/// `define`s are what `Build.IsDefined` / `Build.Value` fold to.
		public Treadle.Model.BuildSettings Settings ~ delete _;
		/// The bound and checked Sheets, by Sheet.
		public Dictionary<Sheet, SheetResult> Results = new .() ~ { for (let kv in _) delete kv.value; delete _; };
		public List<SheetResult> ResultList = new .() ~ delete _;
		/// Generic instantiations asked for (Compiler.md 2, "Generics").
		public InstanceTable Instances = new .() ~ delete _;
		/// C import sets kept alive for their units.
		List<CImportFile> mImportFiles = new .() ~ DeleteContainerAndItems!(_);
		public bool Declared;
		/// The closure classes of the Lambda nodes, by full name (ClosureType).
		public Dictionary<String, TypeSym> Closures = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		/// The C record types the C import sets declare (cstruct / cunion / cenum / ctypedef), in
		/// the type table too.
		public List<TypeSym> CRecords = new .() ~ delete _;
		/// Symbols an incremental re-declare replaced (Incremental.bf). Kept until the compilation
		/// is deleted: interned types and bound results that were not redone may still point at them.
		public List<MemberSym> DeadMembers = new .() ~ DeleteContainerAndItems!(_);
		public List<GenericParamSym> DeadGenerics = new .() ~ DeleteContainerAndItems!(_);
		/// The files read besides the type files: the C import set files and their declarations, the
		/// `depends` project files (Build stamps them, FrontEndBuild.InputStamps).
		public List<String> InputFiles = new .() ~ DeleteContainerAndItems!(_);

		public this()
		{
		}

		// ------------------------------------------------------------------ inputs

		/// Reads the core library (CoreSource: its type files and its C import set `crt`) as units.
		public void AddCore()
		{
			CoreSource.Load();
			for (let cu in CoreSource.Units)
			{
				if (cu.Doc == null)
				{
					Diags.Add(.Error, .Load, "T0001", .("Core", "", "", cu.Path), "", "", scope $"core library file {cu.Name} does not read: {cu.Error}");
					continue;
				}
				SourceUnit u = new .();
				u.Doc = cu.Doc;
				u.OwnsDoc = false;
				u.IsCore = true;
				u.Path.Set(cu.Path);
				Units.Add(u);
			}
			if (CoreSource.CDecl == null || CoreSource.CSet == null)
			{
				Diags.Add(.Error, .Load, "T0001", .("Core"), "", "", scope $"the core library's C import set: {CoreSource.CError}");
				return;
			}
			SourceUnit u = new .();
			u.Doc = CoreSource.CDecl;
			u.OwnsDoc = false;
			u.IsCore = true;
			u.IsCDecl = true;
			u.Set = CoreSource.CSet;
			u.Path.Set(CoreSource.CDeclPath);
			Units.Add(u);
		}

		/// A project type file (the editor's document or one read from disk).
		public SourceUnit AddDocument(TypeDocument doc, StringView path, bool owns)
		{
			SourceUnit u = new .();
			u.Doc = doc;
			u.OwnsDoc = owns;
			u.Path.Set(path);
			Units.Add(u);
			return u;
		}

		/// A `.cimport` file: each `import` set needs its declarations, looked for in this order:
		/// `<set>.windows.cdecl` (Linux: `<set>.linux.cdecl`) next to the set file, `<set>.cdecl` next
		/// to it, then the same two under `build/cimport` of the project root (docs/C-Import.md).
		public void AddCImport(StringView path, StringView projectRoot)
		{
			String text = scope .();
			if (System.IO.File.ReadAllText(path, text, true) case .Err)
			{
				Diags.Add(.Error, .Load, "T0002", .("", "", "", path), "", "", scope $"cannot read {path}");
				return;
			}
			CImportFile f = new .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (!ProjectCodec.ReadCImport(text, f, errors))
			{
				String why = scope .();
				TreadleCodec.JoinErrors(errors, why);
				Diags.Add(.Error, .Load, "T0003", .("", "", "", path), "", "", why);
				delete f;
				return;
			}
			mImportFiles.Add(f);
			InputFiles.Add(new String(path));
			String dir = scope .();
			System.IO.Path.GetDirectoryPath(path, dir).IgnoreError();
			for (let set in f.Sets)
			{
				String found = scope .();
				for (let candidate in StringView[?](scope $"{dir}/{set.Name}{CImportFile.PlatformCDeclSuffix}", scope $"{dir}/{set.Name}.cdecl",
					scope $"{projectRoot}/build/cimport/{set.Name}{CImportFile.PlatformCDeclSuffix}", scope $"{projectRoot}/build/cimport/{set.Name}.cdecl"))
				{
					if (System.IO.File.Exists(candidate))
					{
						found.Set(candidate);
						break;
					}
				}
				if (found.IsEmpty)
				{
					Diags.Add(.Warning, .Load, "T0004", .(scope $"C.{set.Name}", "", "", path), "", "",
						scope $"the C import set '{set.Name}' has no declarations yet: write {set.Name}.cdecl next to the set file (the header import makes it later)");
					continue;
				}
				String decl = scope .();
				if (System.IO.File.ReadAllText(found, decl, true) case .Err)
					continue;
				InputFiles.Add(new String(found));
				TypeDocument doc = new .();
				ClearAndDeleteItems!(errors);
				if (!TreadleCodec.ReadAll(decl, doc, errors))
				{
					String why = scope .();
					TreadleCodec.JoinErrors(errors, why);
					Diags.Add(.Error, .Load, "T0005", .(scope $"C.{set.Name}", "", "", found), "", "", why);
					delete doc;
					continue;
				}
				SourceUnit u = new .();
				u.Doc = doc;
				u.OwnsDoc = true;
				u.Path.Set(found);
				u.IsCDecl = true;
				u.Set = set;
				u.SetDir.Set(dir);
				Units.Add(u);
			}
		}

		// ------------------------------------------------------------------ run

		/// Declare, then Bind and Check every Sheet of the project's own types. The core library's
		/// Sheets are bound when Lower reaches them (CoreSheet), or all of them with `withCore`
		/// (the `core` self test): a Validate does not pay for them.
		public void Run(bool withCore = false)
		{
			Declare();
			for (let u in Units)
			{
				if (u.Sym == null || u.IsCDecl || (u.IsCore && !withCore))
					continue;
				for (let s in u.Doc.Sheets)
				{
					if (s.Member == null)
						continue;
					// A Lambda node binds its Sheet first (it needs the captures).
					let r = ResultOf(s) ?? BindSheet(u, s);
					if (r != null && !r.Checked)
						CheckSheet(r);
				}
			}
		}

		/// A core library Sheet bound and checked (now, the first time Lower asks for it).
		public SheetResult CoreSheet(TypeSym t, Sheet s)
		{
			var r = ResultOf(s);
			if (r == null)
			{
				let u = FindUnit(t.Doc);
				if (u == null)
					return null;
				r = BindSheet(u, s);
			}
			if (r != null && !r.Checked)
				CheckSheet(r);
			return r;
		}

		public SheetResult ResultOf(Sheet s)
		{
			if (Results.TryGetValue(s, let r))
				return r;
			return null;
		}

		public TypeSym FindUnitType(TypeDocument doc)
		{
			for (let u in Units)
				if (u.Doc == doc)
					return u.Sym;
			return null;
		}

		public SourceUnit FindUnit(TypeDocument doc)
		{
			for (let u in Units)
				if (u.Doc == doc)
					return u;
			return null;
		}

		/// The member symbol of a record (null when Declare dropped it).
		public MemberSym MemberOf(TypeSym t, MemberDecl decl)
		{
			if (t == null)
				return null;
			for (let m in t.Members)
				if (m.Decl == decl)
					return m;
			return null;
		}

		public CDiag Error(StringView code, in DiagSite site, StringView node, StringView pin, StringView message, Stage stage = .Bind)
			=> Diags.Add(.Error, stage, code, site, node, pin, message);

		public CDiag Warning(StringView code, in DiagSite site, StringView node, StringView pin, StringView message, Stage stage = .Bind)
			=> Diags.Add(.Warning, stage, code, site, node, pin, message);
	}

	/// Generic instantiation requests (Compiler.md 2): a generic type or function with its
	/// arguments, memoised, with the node that first asked for it.
	class InstanceTable
	{
		public class Entry
		{
			/// The instance type (`Core.Pair<int,float>`) for type instances.
			public KType Type;
			/// Function instances: the function and its arguments.
			public MemberSym Function;
			public List<KType> Args = new .() ~ delete _;
			/// Where it was asked for: type, Sheet key and node.
			public String AskedBy = new .() ~ delete _;
			public String Node = new .() ~ delete _;
		}

		public List<Entry> Entries = new .() ~ DeleteContainerAndItems!(_);

		public Entry FindType(KType t)
		{
			for (let e in Entries)
				if (e.Type == t)
					return e;
			return null;
		}

		/// Records a type instance (only closed ones: no generic parameter left).
		public bool AddType(KType t, StringView askedBy, StringView node)
		{
			if (t == null || t.Kind != .Named || t.Args.IsEmpty || TypeTable.IsOpen(t) || FindType(t) != null)
				return false;
			Entry e = new .();
			e.Type = t;
			e.AskedBy.Set(askedBy);
			e.Node.Set(node);
			Entries.Add(e);
			return true;
		}

		public bool AddFunction(MemberSym f, Span<KType> args, StringView askedBy, StringView node)
		{
			for (let a in args)
				if (TypeTable.IsOpen(a))
					return false;
			for (let e in Entries)
			{
				if (e.Function != f || e.Args.Count != args.Length)
					continue;
				bool same = true;
				for (int i < args.Length)
					same &= e.Args[i] == args[i];
				if (same)
					return false;
			}
			Entry e = new .();
			e.Function = f;
			for (let a in args)
				e.Args.Add(a);
			e.AskedBy.Set(askedBy);
			e.Node.Set(node);
			Entries.Add(e);
			return true;
		}
	}
}
