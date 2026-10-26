using System;
using System.Collections;
using System.IO;
using Treadle.Model;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	/// Type files read from disk, kept between Validates while their time stamp holds.
	class DocCache
	{
		class Entry
		{
			public DateTime Time;
			public TypeDocument Doc ~ delete _;
			public String Error ~ delete _;
		}

		Dictionary<String, Entry> mFiles = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

		/// The document of `path` (read now, or the cached one when the file did not change).
		/// Null with `outError` when it does not read.
		public TypeDocument Get(StringView path, String outError)
		{
			DateTime time = default;
			if (File.GetLastWriteTime(path) case .Ok(let t))
				time = t;
			if (mFiles.TryGetValueAlt(path, let e) && e.Time == time)
			{
				if (e.Error != null)
					outError.Set(e.Error);
				return e.Doc;
			}
			if (mFiles.GetAndRemoveAlt(path) case .Ok(let old))
			{
				delete old.key;
				delete old.value;
			}
			Entry n = new .();
			n.Time = time;
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				n.Error = new String(scope $"cannot read {path}");
			else
			{
				TypeDocument doc = new .();
				doc.FilePath.Set(path);
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				if (TreadleCodec.ReadAll(text, doc, errors))
					n.Doc = doc;
				else
				{
					String why = scope .();
					TreadleCodec.JoinErrors(errors, why);
					n.Error = new String(why);
					delete doc;
				}
			}
			mFiles[new String(path)] = n;
			if (n.Error != null)
				outError.Set(n.Error);
			return n.Doc;
		}
	}

	/// Makes a Compilation of a project folder: every `.treadle` under it (the open documents in
	/// place of their files), the `.cimport` sets with their declarations, and the project file.
	static class ProjectLoader
	{
		public const int MaxDepth = 12;

		/// The type files, C import sets and the project file under `root` (build output, `recovery`,
		/// `dist` and dot-folders skipped, as ProjectIndex does).
		public static void Scan(StringView root, List<String> outTypes, List<String> outImports, String outProject, int depth = 0)
		{
			if (depth > MaxDepth || !Directory.Exists(root))
				return;
			for (let e in Directory.EnumerateFiles(root))
			{
				String path = scope .();
				e.GetFilePath(path);
				if (FormatNames.IsTypeFile(path))
					outTypes.Add(new String(path));
				else if (path.EndsWith(".cimport", .OrdinalIgnoreCase) && CImportFile.ScanTakes(path))
					outImports.Add(new String(path));
				else if (FormatNames.IsProjectFile(path) && outProject.IsEmpty)
					outProject.Set(path);
			}
			for (let e in Directory.EnumerateDirectories(root))
			{
				String name = scope .();
				e.GetFileName(name);
				if (name.StartsWith('.') || name == "build" || name == "recovery" || name == "dist" || name == "reading-order" || name == "format-history")
					continue;
				String path = scope .();
				e.GetFilePath(path);
				// A folder with its own project file is another project (samples/m1 under the samples).
				bool nested = false;
				for (let pattern in Treadle.Format.FormatNames.ProjectPatterns)
					for (let f in Directory.EnumerateFiles(path, pattern))
						nested = true;
				if (nested)
					continue;
				Scan(path, outTypes, outImports, outProject, depth + 1);
			}
		}

		/// The type files and C import sets of one project: its `source` folders (none: the
		/// project folder), then its `depends` projects' (Language.md 8; a cycle is an error). A
		/// `source` folder that is not there is a warning; when none of them is, the project
		/// folder is scanned instead. A `depends` project that is not there is a warning (its
		/// types are missing where they are used).
		static void ScanProject(Compilation c, StringView root, ProjectFile project, StringView projectPath, StringView projectName,
			List<(String path, String project)> outTypes, List<String> outImports, List<String> visiting)
		{
			List<String> types = scope .();
			defer { ClearAndDeleteItems!(types); }
			String unused = scope .();
			bool scanned = false;
			if (project != null && !project.Sources.IsEmpty)
			{
				for (let src in project.Sources)
				{
					String dir = scope .();
					Path.GetAbsolutePath(src, root, dir);
					if (!Directory.Exists(dir))
					{
						c.Diags.Add(.Warning, .Load, "T0012", .("", "", "", projectPath), "", "",
							scope $"the source folder '{src}' of the project file is not there");
						continue;
					}
					Scan(dir, types, outImports, unused);
					scanned = true;
				}
			}
			if (!scanned)
				Scan(root, types, outImports, unused);
			for (let t in types)
			{
				// Both names of one type file (`Player.vtype` beside `Player.treadle`, FormatNames): an error naming
				// both; the new name is the one read.
				String twin = scope .();
				if (Treadle.Format.FormatNames.NewNameOf(t, twin) && File.Exists(twin))
				{
					c.Diags.Add(.Error, .Load, "T0017", .("", "", "", t), "", "",
						scope $"both '{t}' and '{twin}' are here: one type file under its old and its new name; keep one (--format --migrate renames old names)");
					continue;
				}
				outTypes.Add((new String(t), new String(projectName)));
			}
			if (project == null)
				return;
			// The project file's `cimport` lines (Graph-Format.md 5): sets outside the source folders
			// too; one that is not there is a warning.
			for (let ci in project.CImports)
			{
				String path = scope .();
				Path.GetAbsolutePath(ci, root, path);
				CImportFile.ForPlatform(scope String(path), path);
				if (!File.Exists(path))
				{
					c.Diags.Add(.Warning, .Load, "T0016", .("", "", "", projectPath), "", "",
						scope $"the C import set file '{ci}' of the project file is not there: its declarations are missing");
					continue;
				}
				bool have = false;
				for (let i in outImports)
					if (ProjectIndex.SamePath(i, path))
						have = true;
				if (!have)
					outImports.Add(new String(path));
			}
			for (let dep in project.Depends)
			{
				String depPath = scope .();
				Path.GetAbsolutePath(dep, root, depPath);
				// The core library's own project: every program has it already (CoreSource).
				String coreDir = scope .();
				CoreSource.FindFolder(coreDir);
				if (!coreDir.IsEmpty && ProjectIndex.SamePath(depPath, scope $"{coreDir}/Core.tproj"))
					continue;
				// A dependency renamed by --format --migrate (or not yet): the other extension is the same project.
				String twinDep = scope .();
				if (!File.Exists(depPath) && Treadle.Format.FormatNames.TwinOf(depPath, twinDep) && File.Exists(twinDep))
					depPath.Set(twinDep);
				if (!File.Exists(depPath))
				{
					c.Diags.Add(.Warning, .Load, "T0013", .("", "", "", projectPath), "", "",
						scope $"the project '{dep}' it depends on is not there: its types are missing");
					continue;
				}
				bool cycle = false;
				for (let v in visiting)
					if (ProjectIndex.SamePath(v, depPath))
						cycle = true;
				if (cycle)
				{
					c.Diags.Add(.Error, .Load, "T0014", .("", "", "", projectPath), "", "",
						scope $"the projects depend on each other in a cycle ('{dep}'): a library project cannot depend on a project that uses it");
					continue;
				}
				let depProject = ReadProject(depPath);
				if (depProject == null)
				{
					c.Diags.Add(.Error, .Load, "T0015", .("", "", "", depPath), "", "", scope $"the project file '{dep}' does not read");
					continue;
				}
				c.DependProjects.Add(depProject);
				c.InputFiles.Add(new String(depPath));
				String depRoot = scope .();
				Path.GetDirectoryPath(depPath, depRoot).IgnoreError();
				String name = scope .(depProject.Name);
				if (name.IsEmpty)
					Path.GetFileNameWithoutExtension(depPath, name);
				visiting.Add(new String(depPath));
				ScanProject(c, depRoot, depProject, depPath, name, outTypes, outImports, visiting);
				delete visiting.PopBack();
			}
		}

		/// The project file in `root` ("" when none).
		public static void FindProjectFile(StringView root, String outPath)
		{
			if (!Directory.Exists(root))
				return;
			for (let e in Directory.EnumerateFiles(root))
			{
				let p = e.GetFilePath(.. scope String());
				if (FormatNames.IsProjectFile(p))
				{
					outPath.Set(p);
					return;
				}
			}
		}

		/// A compilation over the folder `root` (the core library included). `open`: documents
		/// that stand for their files (may be null); `cache`: disk documents kept between runs
		/// (may be null: they are read now and owned by the compilation). `extra`: more documents
		/// that are not in the folder (may be null).
		/// The core library's own files (the core folder opened as a project): the core has them.
		public static bool IsCoreFile(StringView path)
		{
			for (let cu in CoreSource.Units)
				if (ProjectIndex.SamePath(cu.Path, path))
					return true;
			if (!CoreSource.CDeclPath.IsEmpty && ProjectIndex.SamePath(CoreSource.CDeclPath, path))
				return true;
			String coreDir = scope .();
			CoreSource.FindFolder(coreDir);
			return !coreDir.IsEmpty && (ProjectIndex.SamePath(path, scope $"{coreDir}/crt.cimport") || ProjectIndex.SamePath(path, scope $"{coreDir}/crt.linux.cimport"));
		}

		/// The type files (with the name of the project each belongs to, "" for the project in
		/// `root`) and the C import set files a compilation of `root` reads, the core library's own
		/// files left out. The scan's Load warnings and errors go to `c`.
		public static void ListFiles(Compilation c, StringView root, ProjectFile project, List<(String path, String project)> outTypes, List<String> outImports)
		{
			if (root.IsEmpty)
				return;
			String projectPath = scope .();
			FindProjectFile(root, projectPath);
			List<String> visiting = scope .();
			defer { ClearAndDeleteItems!(visiting); }
			if (!projectPath.IsEmpty)
				visiting.Add(new String(projectPath));
			List<(String path, String project)> types = scope .();
			List<String> imports = scope .();
			ScanProject(c, root, project, projectPath, "", types, imports, visiting);
			for (let t in types)
			{
				if (IsCoreFile(t.path))
				{
					delete t.path;
					delete t.project;
				}
				else
					outTypes.Add(t);
			}
			for (let i in imports)
			{
				if (IsCoreFile(i))
					delete i;
				else
					outImports.Add(i);
			}
		}

		public static Compilation Make(StringView root, List<TypeDocument> open, DocCache cache, ProjectFile project = null, List<TypeDocument> extra = null,
			List<(String path, String project)> outTypes = null, List<String> outImports = null)
		{
			Compilation c = new .();
			c.Project = project;
			c.AddCore();
			List<(String path, String project)> types = scope .();
			List<String> imports = scope .();
			defer { for (let t in types) { delete t.path; delete t.project; } ClearAndDeleteItems!(imports); }
			ListFiles(c, root, project, types, imports);
			if (outTypes != null)
				for (let t in types)
					outTypes.Add((new String(t.path), new String(t.project)));
			if (outImports != null)
				for (let i in imports)
					outImports.Add(new String(i));
			List<TypeDocument> used = scope .();
			for (let (path, projectName) in types)
			{
				TypeDocument doc = null;
				if (open != null)
					for (let d in open)
						if (!d.FilePath.IsEmpty && ProjectIndex.SamePath(d.FilePath, path))
							doc = d;
				if (doc != null)
				{
					used.Add(doc);
					c.AddDocument(doc, path, false).Project.Set(projectName);
					continue;
				}
				String why = scope .();
				if (cache != null)
				{
					doc = cache.Get(path, why);
					if (doc != null)
						c.AddDocument(doc, path, false).Project.Set(projectName);
				}
				else
				{
					String text = scope .();
					if (File.ReadAllText(path, text, true) case .Ok)
					{
						doc = new TypeDocument();
						doc.FilePath.Set(path);
						List<FormatError> errors = scope .();
						defer { ClearAndDeleteItems!(errors); }
						if (TreadleCodec.ReadAll(text, doc, errors))
							c.AddDocument(doc, path, true).Project.Set(projectName);
						else
						{
							TreadleCodec.JoinErrors(errors, why);
							DeleteAndNullify!(doc);
						}
					}
					else
						why.Set("cannot be read");
				}
				if (doc == null)
					c.Diags.Add(.Error, .Load, "T0010", .("", "", "", path), "", "", scope $"{path}: {why}");
			}
			// Open documents outside the folder (an untitled one, a file from elsewhere).
			if (open != null)
				for (let d in open)
					if (!used.Contains(d) && d.FilePath.IsEmpty && !d.Header.Name.IsEmpty)
						c.AddDocument(d, "", false);
			if (extra != null)
				for (let d in extra)
					c.AddDocument(d, d.FilePath, false);
			for (let path in imports)
				if (!IsCoreFile(path))
					c.AddCImport(path, root);
			return c;
		}

		/// Reads a project file (null when it does not read).
		public static ProjectFile ReadProject(StringView path)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return null;
			ProjectFile p = new .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (!ProjectCodec.ReadProject(text, p, errors))
			{
				delete p;
				return null;
			}
			return p;
		}
	}
}
