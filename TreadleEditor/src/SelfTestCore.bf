// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Format;
using Treadle.Model;
using Treadle.Language;
using Treadle.Compiler;
using Treadle.Catalog;

namespace Treadle.Editor
{
	/// The `core` self test: the core library (TreadleCore/core, docs/Core-Library.md).
	///
	///  1. The core validates with no diagnostic (every Sheet bound and checked), from the folder
	///     on disk or the built-in copy; the built-in copy is the folder's; every type file reads
	///     and writes back byte for byte (canonical).
	///  2. The Node menu's catalogue offers the core types (category `Core|<Type>`, shown under the
	///     menu's Core group) and hides the core's C import set and internal members, and offers
	///     Sort with a comparer and by operator < on List, Arrays and Span (not the internal Core.Sorting).
	///  3. Each program of TreadleCompiler/fixtures/core (`<name>.treadle`, or a folder `<name>` of type files
	///     whose entry is the type named `...Main`; entry `Cx.<Type>`) validates
	///     clean, lowers, builds and runs in Debug and Release against `<name>.expected`; Debug
	///     reports leaks through the exit code, so a pass is leak-free.
	///  4. The m3-core, m3-files and m3-text samples validate clean and run in Debug against
	///     fixtures/core/<sample>.expected.
	extension EditorApp
	{
		bool SelfTestCore()
		{
			String samples = scope .();
			if (!FindSamples(samples))
			{
				SelfTestCheck(false, "core: the samples folder was not found (set TREADLE_SAMPLES)");
				return true;
			}
			String fixtures = scope .();
			if (!FindFixtures(samples, fixtures))
			{
				SelfTestCheck(false, "core: TreadleCompiler/fixtures was not found next to the samples");
				return true;
			}

			// 1. The core alone.
			{
				let sw = scope System.Diagnostics.Stopwatch(true);
				let c = ProjectLoader.Make("", null, null);
				defer delete c;
				c.Run(true);
				int types = 0;
				for (let t in c.Table.Types)
					if (t.IsCore && !t.IsCImport)
						types++;
				int sheets = 0;
				for (let r in c.ResultList)
					if (r.Type != null && r.Type.IsCore)
						sheets++;
				SelfTestCheck(c.Diags.Items.Count == 0 && types >= 25 && sheets >= 120,
					scope $"core: the core library validates with no diagnostics ({types} types, {sheets} Sheets, from {CoreSource.From}, {sw.Elapsed.TotalMilliseconds:0} ms)");
				if (c.Diags.Items.Count > 0)
					LogDiags(c);
			}
			String dir = scope .();
			CoreSource.FindFolder(dir);
			if (!dir.IsEmpty)
			{
				String why = scope .();
				SelfTestCheck(CoreSource.EmbeddedMatches(dir, why), scope $"core: the built-in copy of the core is {dir}{(why.IsEmpty ? "" : ": ")}{why}");
				// The core folder opened as a project (Core.tproj): its files are the core's, not
				// declared twice.
				{
					let project = ProjectLoader.ReadProject(scope $"{dir}/Core.tproj");
					let c = ProjectLoader.Make(dir, null, null, project);
					defer { delete c; delete project; }
					c.Run(true);
					SelfTestCheck(project != null && c.Diags.Items.Count == 0, scope $"core: the core folder opened as a project validates with no diagnostics ({c.Diags.Items.Count})");
					if (c.Diags.Items.Count > 0)
						LogDiags(c);
				}
				int files = 0;
				int same = 0;
				String first = scope .();
				for (let e in Directory.EnumerateFiles(dir))
				{
					let path = e.GetFilePath(.. scope String());
					if (!FormatNames.IsTypeFile(path) && !path.EndsWith(".cdecl"))
						continue;
					files++;
					String text = scope .();
					ReadFile(path, text);
					text.Replace("\r", "");
					TypeDocument doc = scope .(Language);
					List<FormatError> errs = scope .();
					defer { ClearAndDeleteItems!(errs); }
					String back = scope .();
					if (TreadleCodec.ReadAll(text, doc, errs))
						TypeFileWriter.Write(doc, back);
					if (back == text)
						same++;
					else
					{
						if (first.IsEmpty)
							Path.GetFileName(path, first);
						// The first line that differs.
						var a = text.Split('\n');
						var b = back.Split('\n');
						for (int line = 1; ; line++)
						{
							let la = a.GetNext();
							let lb = b.GetNext();
							if (la case .Err && lb case .Err)
								break;
							if (la.GetValueOrDefault() != lb.GetValueOrDefault())
							{
								Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      {path} line {line}: '{la.GetValueOrDefault()}' written back as '{lb.GetValueOrDefault()}'");
								break;
							}
						}
					}
				}
				SelfTestCheck(files > 0 && same == files, scope $"core: {same} of {files} core files write back byte for byte{(first.IsEmpty ? "" : ", not ")}{first}");
			}
			else
				Notify.Log(.Info, "SelfTest", "[SELFTEST] core: no TreadleCore/core above the exe: the built-in copy is used");

			// 2. The catalogue.
			{
				LanguageContext ctx = scope .();
				ProjectIndex index = scope .();
				index.Build(samples, FormatNames.TypeExt);
				ctx.Index = index;
				List<TypeDocument> open = scope .();
				FrontEndServices fe = scope .(ctx, open);
				List<NodeSpec> specs = scope .();
				defer { ClearAndDeleteItems!(specs); }
				fe.Catalog.Entries(specs);
				bool listAdd = false;
				bool dictTryGet = false;
				bool crt = false;
				bool internalShown = false;
				int listSorts = 0;
				int arraySorts = 0;
				int spanSorts = 0;
				bool sortingShown = false;
				for (let s in specs)
				{
					if (s.Category == "Core|List" && s.MemberName == "Add")
						listAdd = true;
					if (s.Category == "Core|Dictionary" && s.MemberName == "TryGet")
						dictTryGet = true;
					if (s.OwnerType == "C.crt")
						crt = true;
					if (s.OwnerType == "Core.StringView" && s.MemberName == "MatchesAt")
						internalShown = true;
					// Sort with a comparer and Sort by operator < on List, arrays and Span; the
					// introsort itself (Core.Sorting) is internal.
					if (s.MemberName == "Sort")
					{
						if (s.Category == "Core|List")
							listSorts++;
						else if (s.Category == "Core|Arrays")
							arraySorts++;
						else if (s.Category == "Core|Span")
							spanSorts++;
					}
					if (s.OwnerType == "Core.Sorting")
						sortingShown = true;
				}
				NodeItem item = scope .();
				item.Kind = .Catalog;
				item.Category.Set("Core|List");
				String group = scope .();
				NodeMenu.DisplayGroup(item, group);
				SelfTestCheck(listAdd && dictTryGet && !crt && !internalShown && group == "Core | List",
					scope $"core: the Node menu offers List.Add and Dictionary.TryGet under {group}, not C.crt or internal members ({specs.Count} entries)");
				SelfTestCheck(listSorts == 2 && arraySorts == 2 && spanSorts == 2 && !sortingShown,
					scope $"core: the Node menu offers Sort with a comparer and by operator < on List ({listSorts}), Arrays ({arraySorts}) and Span ({spanSorts}), not Core.Sorting");
			}

			// 3. The fixture programs.
			String work = scope .();
			Path.GetTempPath(work).IgnoreError();
			work.AppendF("/treadle-core-{}", (int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF);
			defer { Directory.DelTree(work).IgnoreError(); }
			Directory.CreateDirectory(work).IgnoreError();
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			for (let e in Directory.EnumerateFiles(scope $"{fixtures}/core"))
			{
				let p = e.GetFilePath(.. scope String());
				if (FormatNames.IsTypeFile(p))
					names.Add(Path.GetFileNameWithoutExtension(p, .. new String()));
			}
			// A folder is one program of several type files (fixtures/core/moves: a struct and its Main).
			for (let e in Directory.EnumerateDirectories(scope $"{fixtures}/core"))
				names.Add(e.GetFileName(.. new String()));
			names.Sort(scope (a, b) => a.CompareTo(b));
			SelfTestCheck(names.Count >= 8, scope $"core: {names.Count} core fixture programs found");
			for (let name in names)
			{
				// One type file, or every type file of the folder; the entry is the type named ...Main.
				List<String> files = scope .();
				defer { ClearAndDeleteItems!(files); }
				String folder = scope $"{fixtures}/core/{name}";
				if (Directory.Exists(folder))
				{
					for (let e in Directory.EnumerateFiles(folder))
					{
						let p = e.GetFilePath(.. new String());
						if (FormatNames.IsTypeFile(p))
							files.Add(p);
						else
							delete p;
					}
					files.Sort(scope (a, b) => a.CompareTo(b));
				}
				else
					files.Add(new $"{fixtures}/core/{name}.treadle");
				List<TypeDocument> docs = scope .();
				defer { ClearAndDeleteItems!(docs); }
				List<FormatError> errs = scope .();
				defer { ClearAndDeleteItems!(errs); }
				TypeDocument doc = null;
				for (let path in files)
				{
					String text = scope .();
					ReadFile(path, text);
					TypeDocument d = new .();
					d.FilePath.Set(path);
					docs.Add(d);
					TreadleCodec.ReadAll(text, d, errs);
					if (doc == null || d.Header.Name.EndsWith("Main"))
						doc = d;
				}
				let c = ProjectLoader.Make("", null, null, null, docs);
				defer delete c;
				c.Run();
				String kir = scope .();
				let lowered = c.Diags.Items.Count == 0 && Lowering.WriteProgram(c, name, scope $"Cx.{doc.Header.Name}", kir);
				if (!lowered)
				{
					SelfTestCheck(false, scope $"core: {name} validates clean and lowers");
					LogDiags(c);
					continue;
				}
				String kirPath = scope $"{work}/{name}.tir";
				File.WriteAllText(kirPath, kir).IgnoreError();
				String expected = scope .();
				ReadFile(scope $"{fixtures}/core/{name}.expected", expected);
				File.WriteAllText(scope $"{work}/{name}.expected", expected).IgnoreError();
				for (let config in StringView[?]("Debug", "Release"))
				{
					Treadle.Backend.Testing.FixtureResult r = scope .();
					Treadle.Backend.Testing.FixtureRunner.Run(kirPath, config, work, r);
					SelfTestCheck(r.Passed, scope $"core: {name} runs ({config}, {r.BuildMs:0} ms build): {r.Detail}");
					if (!r.Passed)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      stdout:\n{r.Stdout}\n      stderr:\n{r.Stderr}");
				}
			}

			// 4. The m3-core, m3-files and m3-text samples (m3-text: a stdout-prefix, its last line is the year).
			StringView[?] sampleNames = .("m3-core", "m3-files", "m3-text");
			StringView[?] sampleEntries = .("M3.Program", "M3Files.Program", "M3Text.Program");
			for (int si < sampleNames.Count)
			{
				let sample = sampleNames[si];
				let entry = sampleEntries[si];
				String m3 = scope $"{samples}/{sample}";
				String projectPath = scope .();
				ProjectLoader.FindProjectFile(m3, projectPath);
				let project = projectPath.IsEmpty ? null : ProjectLoader.ReadProject(projectPath);
				let c = ProjectLoader.Make(m3, null, null, project);
				defer { delete c; delete project; }
				c.Run();
				String kir = scope .();
				let lowered = project != null && c.Diags.Items.Count == 0 && Lowering.WriteProgram(c, sample, entry, kir);
				SelfTestCheck(lowered, scope $"core: {sample} validates with no diagnostics and lowers ({kir.Length} bytes of IR)");
				if (!lowered)
					LogDiags(c);
				else
				{
					String kirPath = scope $"{work}/{sample}.tir";
					File.WriteAllText(kirPath, kir).IgnoreError();
					String expected = scope .();
					ReadFile(scope $"{fixtures}/core/{sample}.expected", expected);
					File.WriteAllText(scope $"{work}/{sample}.expected", expected).IgnoreError();
					Treadle.Backend.Testing.FixtureResult r = scope .();
					Treadle.Backend.Testing.FixtureRunner.Run(kirPath, "Debug", work, r);
					SelfTestCheck(r.Passed, scope $"core: {sample} runs (Debug, no leaks): {r.Detail}");
					if (!r.Passed)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      stdout:\n{r.Stdout}\n      stderr:\n{r.Stderr}");
				}
			}
			return true;
		}
	}
}
#endif
