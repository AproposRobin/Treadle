// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Format;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Checks for the fixes of docs/Security-Review.md, run by the `codec` and `cimport` self tests.
	extension EditorApp
	{
		/// `codec`: a type token nested deeper than TypeRef.MaxDepth reads as a Raw type (no stack
		/// overflow in the parser, ToString or the destructor); a project file whose `entry` is such a
		/// token reads and writes back.
		void SelfTestSecurityCodec()
		{
			for (let unit in StringView[?]("?", "*", "[]", "(", "A<", "function:A("))
			{
				String text = scope .("T");
				if (unit == "(" || unit == "A<" || unit == "function:A(")
					text.Clear();
				for (int i < 100000)
					text.Append(unit);
				let t = TypeRef.Parse(text);
				let raw = t.Kind == .Raw;
				String back = scope .();
				t.ToString(back);
				delete t;
				SelfTestCheck(raw && back == text, scope $"codec: a type token of 100000 '{unit}' reads as a Raw type");
			}
			String nested = scope .("A");
			for (int i < TypeRef.MaxDepth / 2)
				nested.Append("?");
			let ok = TypeRef.Parse(nested);
			SelfTestCheck(ok.Kind == .Nullable, scope $"codec: a type within TypeRef.MaxDepth still parses ({nested})");
			delete ok;

			// Under RecordText.MaxLineLength a deep token reads (as Raw) and writes back; past it the file is refused.
			for (let count in int[?](60000, 200000))
			{
				String project = new .("# tproj 1\nproject P\n\tkind console\n\tentry Main");
				defer delete project;
				for (int i < count)
					project.Append('?');
				project.Append("\n");
				ProjectFile p = scope .();
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				let read = ProjectCodec.ReadProject(project, p, errors);
				String written = scope .();
				if (read)
					ProjectCodec.WriteProject(p, written);
				if (count < RecordText.MaxLineLength)
					SelfTestCheck(read && written == project, scope $"codec: a project whose entry has {count} '?' reads and writes back");
				else
					SelfTestCheck(!read && !errors.IsEmpty, scope $"codec: a project line of {count} bytes is refused (longer than RecordText.MaxLineLength)");
			}

			// Layout numbers: NaN, infinity, past LayoutCodec.MaxCoord and a zoom of 0 are refused (they hung the canvas).
			for (let line in StringView[?]("\tnode a1 NaN 0", "\tnode a1 0 1e309", "\tnode a1 99999999999999999999999 0", "\tview 0 0 0", "\tnode a1 0 -inf"))
			{
				Treadle.Document.TypeDocument doc = scope .();
				List<FormatError> lerrors = scope .();
				defer { ClearAndDeleteItems!(lerrors); }
				let lok = LayoutCodec.Read(scope $"# treadle-layout 1\nsheet s1\n{line}\n", doc, lerrors);
				SelfTestCheck(!lok && !lerrors.IsEmpty, scope $"codec: the layout line '{StringView(line)..Trim()}' is refused");
			}
			{
				Treadle.Document.TypeDocument doc = scope .();
				List<FormatError> lerrors = scope .();
				defer { ClearAndDeleteItems!(lerrors); }
				SelfTestCheck(LayoutCodec.Read("# treadle-layout 1\nsheet s1\n\tnode a1 -9999999 120.5\n\tview -40 120 1.0\n", doc, lerrors),
					"codec: layout numbers within LayoutCodec.MaxCoord still read");
			}
		}

		List<String> mFuzzOpenDirs ~ DeleteContainerAndItems!(_);
		int mFuzzOpenIndex;
		int mFuzzOpenWait;

		/// `fuzzopen` (not in any default list): opens every sub-folder of TREADLE_FUZZ_OPEN in turn
		/// through the editor's own open path (OpenProjectNow: the scan, the project file, the type
		/// files and their layouts, the front end), focusing `Player.treadle` when there is one, and
		/// closes the project at the end. Each open is logged first (`[FUZZOPEN] open <n> <dir>`), so a
		/// crash or a hang names the input. Run with TREADLE_HOME set to a scratch folder: opening
		/// remembers the project in the recent list.
		bool SelfTestFuzzOpen()
		{
			if (mFuzzOpenDirs == null)
			{
				mFuzzOpenDirs = new .();
				String root = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_FUZZ_OPEN", root) case .Err || !System.IO.Directory.Exists(root))
				{
					SelfTestCheck(false, "fuzzopen: TREADLE_FUZZ_OPEN names no folder");
					return true;
				}
				for (let e in System.IO.Directory.EnumerateDirectories(root))
					mFuzzOpenDirs.Add(e.GetFilePath(.. new String()));
				mFuzzOpenDirs.Sort(scope (a, b) => a.CompareTo(b));
				String from = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_FUZZ_OPEN_FROM", from) case .Ok && (int.Parse(from) case .Ok(let n)))
					mFuzzOpenIndex = n; // resume after a hang the driver ended
			}
			if (mFuzzOpenWait > 0)
			{
				mFuzzOpenWait--;
				return false;
			}
			for (let d in mDocs)
				d.Modified = false;
			if (mFuzzOpenIndex >= mFuzzOpenDirs.Count)
			{
				OpenProjectNow("", "", true);
				SelfTestCheck(true, scope $"fuzzopen: {mFuzzOpenDirs.Count} projects opened and closed");
				return true;
			}
			let dir = mFuzzOpenDirs[mFuzzOpenIndex];
			Notify.Log(.Info, "SelfTest", scope $"[FUZZOPEN] open {mFuzzOpenIndex} {dir}");
			String file = scope $"{dir}/Player.treadle";
			OpenProjectNow(dir, System.IO.File.Exists(file) ? file : "", true);
			mFuzzOpenIndex++;
			mFuzzOpenWait = 6;
			return false;
		}

		/// `codec`: the tools, the runtime and the core are looked for beside the exe and, in a development
		/// build, in its source tree at the fixed build layout only (finding 8: no walk up the parent
		/// folders); a missing tool's message says where it was looked for.
		void SelfTestSecurityToolDirs()
		{
			String tree = scope .();
			let dev = Treadle.Language.ToolDirs.DevTree(tree);
			let package = Treadle.Language.ToolDirs.IsPackage();
			SelfTestCheck(package || (dev && System.IO.File.Exists(scope $"{tree}/BeefSpace.toml")),
				scope $"codec: a development build finds its source tree at the build layout ({(dev ? tree : "none")}{(package ? ", a package" : "")})");
			if (dev)
			{
				String core = scope .();
				Treadle.Compiler.CoreSource.FindFolder(core);
				core.Replace('\\', '/');
				String env = scope .();
				let coreEnv = Environment.GetEnvironmentVariable("TREADLE_CORE", env) case .Ok && !env.IsEmpty;
				SelfTestCheck(coreEnv || core.EndsWith("/TreadleCore/core"), scope $"codec: the core folder of a development build is its tree's TreadleCore/core ({core})");
			}
			String msg = scope .();
			Treadle.Language.ToolDirs.Missing("clang", "tools/llvm/bin/clang.exe", "tools/llvm-mingw/bin/clang.exe", "TREADLE_LLVM", msg);
			SelfTestCheck(msg.Contains("no parent folder is searched") && msg.Contains("TREADLE_LLVM") && (!dev || msg.Contains("llvm-mingw")),
				scope $"codec: a missing tool names where it was looked for: {msg}");
		}

		/// `cimport`: a set name cannot leave the output folder; Build's program and config names
		/// cannot leave the build folder.
		void SelfTestSecurityCImport()
		{
			for (let bad in StringView[?]("../x", "..", "a/b", "a\\b", "C:x", "", "a\nb"))
				SelfTestCheck(!Treadle.CImport.CImporter.IsSafeSetName(bad) && !Treadle.Backend.Driver.BackendBuildJob.IsPlainName(bad),
					scope $"cimport: '{bad}' is refused as a set name and as a program or config name");
			for (let good in StringView[?]("libc", "sdl2", "my-lib", "Debug", "M1"))
				SelfTestCheck(Treadle.CImport.CImporter.IsSafeSetName(good) && Treadle.Backend.Driver.BackendBuildJob.IsPlainName(good),
					scope $"cimport: '{good}' is a plain name");
			// Build names the C import paths that leave the project folder (finding 3): m2-sdl's SDL2 include,
			// import library and DLL do (tools/SDL2 or TREADLE_SDL2), m1's libc set (headers and a library by
			// name) does not.
			{
				String samples = scope .();
				if (FindSamples(samples))
				{
					for (let sample in StringView[?]("m2-sdl", "m1"))
					{
						let wantOutside = sample == "m2-sdl";
						String dir = scope $"{samples}/{sample}";
						String projectPath = scope .();
						for (let e in System.IO.Directory.EnumerateFiles(dir))
						{
							let p = e.GetFilePath(.. scope String());
							if (Treadle.Format.FormatNames.IsProjectFile(p))
								projectPath.Set(p);
						}
						let project = Treadle.Compiler.ProjectLoader.ReadProject(projectPath);
						let c = Treadle.Compiler.ProjectLoader.Make(dir, null, null, project);
						c.Run();
						List<String> outside = scope .();
						Treadle.Compiler.FrontEndBuild.OutsidePaths(c, dir, outside);
						String list = scope .();
						for (let p in outside)
							list.AppendF("{}{}", list.IsEmpty ? "" : ", ", p);
#if BF_PLATFORM_WINDOWS
						let sdlPaths = outside.Count == 3 && list.Contains("SDL2.dll") && list.Contains("include/SDL2") && list.Contains("libSDL2.dll.a");
#else
						let sdlPaths = outside.Count == 1 && list.Contains("include/SDL2"); // sdl2.linux.cimport links SDL2 by name
#endif
						SelfTestCheck(wantOutside ? sdlPaths : outside.IsEmpty,

							scope $"cimport: Build names the C import paths of {sample} outside the project ({outside.Count}): {list}");
						ClearAndDeleteItems!(outside);
						delete c;
						delete project;
					}
				}
			}
			// The tools an environment variable chose are named once per session (finding 8): one line per
			// variable that is set, and a second call says nothing.
			{
				List<String> lines = scope .();
				defer { ClearAndDeleteItems!(lines); }
				ToolSources(lines);
				int want = 0;
				for (let name in StringView[?]("TREADLE_LLVM", "TREADLE_LIBCLANG", "TREADLE_LLDB_DAP"))
				{
					String v = scope .();
					if (Environment.GetEnvironmentVariable(name, v) case .Ok && !v.IsEmpty)
						want++;
				}
				String all = scope .();
				for (let l in lines)
					all.AppendF("{}{}", all.IsEmpty ? "" : "; ", l);
				LogToolSourcesOnce();
				SelfTestCheck(lines.Count == want && !LogToolSourcesOnce() && (want == 0 || all.Contains(" from TREADLE_")),
					scope $"cimport: the tools chosen by environment variables are named once per session ({lines.Count}): {all}");
			}
			// Open (a C import file), Show in Explorer and the release page start system programs by their


			// full path, never a same-named file of the current folder (finding 9).
#if BF_PLATFORM_WINDOWS
			for (let name in StringView[?]("notepad.exe", "explorer.exe"))
#else
			for (let name in StringView[?]("xdg-open"))
#endif
			{
				let path = Desktop.SystemProgram(name, .. scope String());
				SelfTestCheck(System.IO.Path.IsPathRooted(path) || !System.IO.File.Exists(scope $"/usr/bin/{name}"), scope $"cimport: {name} is started as {path}");
			}
		}

	}
}
#endif
