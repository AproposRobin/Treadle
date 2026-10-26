using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.CImport;
using Treadle.Format;
using Treadle.Model;
using Treadle.Document;
using ImGui;

namespace Treadle.Editor
{
	/// The C header import in the editor (docs/C-Import.md):
	///
	///  - `Treadle.exe --import-c <file.cimport> [--out <dir>]` imports every set of the file
	///    into `<dir>\<set>.cdecl` (`<set>.windows.cdecl` / `<set>.linux.cdecl` when the set file has a
	///    platform variant; default `<dir>` is `<project root>\build\cimport`), prints a summary and
	///    exits (0 = every set imported, 1 = a set failed, 2 = usage) without opening a window.
	///  - File > Import C Headers runs it on the project's `.cimport` files (its `cimport` lines,
	///    else every `.cimport` in the project folder) and rescans the project, so the Node
	///    menu's catalogue and Validate see the new declarations. A project with no set gets one
	///    for the header the user picks (CreateSet), listed in the project file.
	///  - The `cimport` self test.
	static class ImportHeader
	{
		public const String Switch = "--import-c";

		/// True when the command line asked for the import; `exitCode` is the process's.
		public static bool CommandLine(String[] args, out int exitCode)
		{
			exitCode = 0;
			int at = -1;
			for (int i < args.Count)
				if (args[i] == Switch)
					at = i;
			if (at < 0)
				return false;
			if (at + 1 >= args.Count)
			{
				Program.ConsoleOut("Treadle: --import-c needs a .cimport file\n\nusage: Treadle --import-c <file.cimport> [--out <dir>]", true);
				exitCode = 2;
				return true;
			}
			let file = args[at + 1];
			StringView outDir = "";
			for (int i < args.Count - 1)
				if (args[i] == "--out")
					outDir = args[i + 1];
			CImportReport report = scope .();
			let ok = CImporter.ImportFile(file, outDir, report);
			String text = scope .();
			report.Summary(text);
			text.AppendF("C import {} in {1:0.0} ms", ok ? "done" : "FAILED", report.TotalMs);
			Program.ConsoleOut(text, !ok);
			exitCode = ok ? 0 : 1;
			return true;
		}

		/// What a child import (ImportInChild) gave.
		public class ChildImport
		{
			public bool Ok;
			/// The child's summary for the Output Log (at most MaxWarningLines warnings), or the
			/// `import failed: <reason>` line.
			public List<String> Lines = new .() ~ DeleteContainerAndItems!(_);
			public int Sets;
			public int Warnings;
			public double Ms;
			public int ExitCode;
			/// Why it failed when the child did not end normally ("" otherwise).
			public String Reason = new .() ~ delete _;
		}

		public const int MaxWarningLines = 40;
		/// A child import that runs longer is ended (seconds; SDL.h takes well under one).
		public const int ChildTimeoutSeconds = 120;

		/// Imports a `.cimport` file in a child editor, `Treadle --import-c <file> --out <dir>`
		/// (Security-Review.md finding 26): libclang runs in the child, so a crash on a deeply nested
		/// or malformed header (a stack overflow in its parser) ends the child and the import fails
		/// with `import failed: <reason>` instead of taking the editor down. Exit code 0: every set
		/// imported; 1: a set failed (the summary says why); anything else, a timeout or a child that
		/// does not start: the reason. The caller deletes the result.
		public static ChildImport ImportInChild(StringView cimportPath, StringView outDir)
		{
			ChildImport r = new .();
			let sw = scope Stopwatch(true);
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new .(Switch));
			args.Add(new .(cimportPath));
			args.Add(new .("--out"));
			args.Add(new .(outDir));
			String outText = scope .();
			String errText = scope .();
			String cwd = scope .();
			Directory.GetCurrentDirectory(cwd);
			r.ExitCode = Treadle.Backend.Driver.RunningProcess.Run(exe, args, cwd, outText, errText, ChildTimeoutSeconds * 1000);
			r.Ms = sw.Elapsed.TotalMilliseconds;
			let timedOut = errText.EndsWith("timed out\n");
			int shownWarnings = 0;
			for (var line in outText.Split('\n'))
			{
				line.TrimEnd();
				if (line.IsEmpty)
					continue;
				if (line.StartsWith("set ") && line.Contains(": "))
					r.Sets++;
				if (line.StartsWith("  warning: "))
				{
					r.Warnings++;
					if (shownWarnings++ >= MaxWarningLines)
						continue;
				}
				r.Lines.Add(new .(line));
			}
			if (shownWarnings > MaxWarningLines)
				r.Lines.Add(new $"  ... and {shownWarnings - MaxWarningLines} more warnings");
			if (r.ExitCode == 0 && !timedOut)
			{
				r.Ok = true;
				return r;
			}
			if (r.ExitCode == 1 && !timedOut)
				return r; // a set failed: the summary names it
			if (timedOut)
				r.Reason.AppendF("the import did not finish in {} s and was stopped", ChildTimeoutSeconds);
			else if (r.ExitCode == -1)
				r.Reason.AppendF("the importer did not start ({})", errText..Trim());
			else
			{
				let code = (uint32)r.ExitCode;
				switch (code)
				{
				case 0xC00000FD, 0x80000001:
					r.Reason.Append("libclang ran out of stack (a header nested too deeply?)");
				case 0xC0000005:
					r.Reason.Append("libclang crashed with an access violation (a header nested too deeply or malformed?)");
				case 3:
					r.Reason.Append("a fatal error in the importer");
				default:
					r.Reason.Append("the importer ended abnormally");
				}
				r.Reason.AppendF(", exit code 0x{:X}", code);
				// the child's first fatal line, when it wrote one
				for (var line in errText.Split('\n'))
				{
					line.Trim();
					if (line.Contains("fatal", true) || line.StartsWith("[FATAL]"))
					{
						r.Reason.AppendF(": {}", line);
						break;
					}
				}
			}
			r.Lines.Add(new $"{cimportPath}: import failed: {r.Reason}");
			return r;
		}

		/// A C import set for one header (File > Import C Headers when the project has none):
		/// `<base>.cimport` in `projectRoot`, set `<base>` (the header's file name without its
		/// extension, made a name), `header <file name>`, and as `include` lines the header's folder
		/// and, when that folder sits in an `include` folder (`include/SDL2/SDL.h`), that one too;
		/// paths inside the project are written relative to it. `project` (may be null) gets the
		/// `cimport <base>.cimport` line (the caller saves it). A set file of that name already
		/// there is kept. False with `outWhy` when the header is not there or the file cannot be
		/// written.
		public static bool CreateSet(StringView projectRoot, ProjectFile project, StringView header, String outSetPath, String outWhy)
		{
			if (!File.Exists(header))
			{
				outWhy.AppendF("{} is not there", header);
				return false;
			}
			String fileName = scope .();
			Path.GetFileName(header, fileName);
			String stem = scope .();
			Path.GetFileNameWithoutExtension(header, stem);
			String name = scope .();
			for (let c in stem.RawChars)
				name.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
			if (name.IsEmpty || name[0].IsDigit)
				name.Insert(0, "c_");
			outSetPath.Set(scope $"{projectRoot}/{name}.cimport");
			if (!File.Exists(outSetPath))
			{
				String root = scope .(projectRoot);
				root.Replace('\\', '/');
				while (root.EndsWith('/'))
					root.RemoveFromEnd(1);
				void Relative(StringView dir, String outPath)
				{
					String d = scope .(dir);
					d.Replace('\\', '/');
					if (d.Length > root.Length && d[root.Length] == '/' && StringView.Compare(d.Substring(0, root.Length), root, true) == 0)
						outPath.Set(d.Substring(root.Length + 1));
					else if (StringView.Compare(d, root, true) == 0)
						outPath.Set(".");
					else
						outPath.Set(d);
				}
				String full = scope .();
				Path.GetFullPath(header, full);
				String dir = scope .();
				Path.GetDirectoryPath(full, dir).IgnoreError();
				CImportFile f = scope .();
				CImportSet set = new .();
				f.Sets.Add(set);
				set.Name.Set(name);
				set.Headers.Add(new String(fileName));
				set.Includes.Add(Relative(dir, .. new String()));
				String parent = scope .();
				String parentName = scope .();
				if (Path.GetDirectoryPath(dir, parent) case .Ok && !parent.IsEmpty)
				{
					Path.GetFileName(parent, parentName);
					if (StringView.Compare(parentName, "include", true) == 0)
						set.Includes.Add(Relative(parent, .. new String()));
				}
				String text = scope .();
				ProjectCodec.WriteCImport(f, text);
				if (File.WriteAllText(outSetPath, text) case .Err)
				{
					outWhy.AppendF("cannot write {}", outSetPath);
					return false;
				}
			}
			project?.AddCImport(scope $"{name}.cimport");
			return true;
		}
	}

	extension EditorApp
	{
		/// File > Import C Headers. `pickedHeader`: the header the file dialog would give when the
		/// project has no set yet (the tutorial case passes the one the page tells the reader to pick).
		void ImportCHeaders(StringView pickedHeader = "")
		{
			if (mProjectRoot.IsEmpty)
				return;
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			if (Project != null)
				for (let c in Project.CImports)
				{
					String path = scope .();
					if (Path.IsPathRooted(c))
						path.Set(c);
					else
						path.AppendF("{}/{}", mProjectRoot, c);
					files.Add(CImportFile.ForPlatform(path, .. new String()));
				}
			if (files.IsEmpty)
				for (let e in Directory.EnumerateFiles(mProjectRoot, "*.cimport"))
				{
					let path = e.GetFilePath(.. scope String());
					if (CImportFile.ScanTakes(path))
						files.Add(new String(path));
				}
			if (files.IsEmpty)
			{
				// No set yet: the header the user picks gets one (ImportHeader.CreateSet), named after
				// it, listed in the project file's `cimport` lines.
				if (!CheckWritable())
					return;
				String header = scope .(pickedHeader);
				if (header.IsEmpty)
				{
					char8[4096] buf = default;
					let picked = ImGui.Host.th_native_dialog(0, scope String(mProjectRoot), &buf, 4096);
					if (picked == -1)
						SetStatus("The project has no .cimport file, and there is no file dialog here to pick a header: write the set by hand (docs/C-Import.md).", .Warning);
					if (picked != 1)
						return;
					header.Set(StringView(&buf));
				}
				String setPath = scope .();
				String why = scope .();
				if (!ImportHeader.CreateSet(mProjectRoot, Project, header, setPath, why))
				{
					SetStatus(why, .Warning);
					return;
				}
				if (Project != null && !ProjectPath.IsEmpty)
					SaveProjectFile();
				Notify.Log(.Info, "C import", scope $"made the C import set {setPath}");
				files.Add(new String(setPath));
			}
			String outDir = scope $"{mProjectRoot}/build/cimport";
			LogToolSourcesOnce();
			int failed = 0, sets = 0, warnings = 0;

			double ms = 0;
			for (let f in files)
			{
				// in a child editor (`--import-c`): a libclang crash on a header fails this file only
				let r = ImportHeader.ImportInChild(f, outDir);
				defer delete r;
				for (let line in r.Lines)
					Notify.Log(r.Ok ? .Info : .Error, "C import", line);
				if (!r.Ok)
					failed++;
				sets += r.Sets;
				warnings += r.Warnings;
				ms += r.Ms;
			}
			ScanProject();
			if (failed > 0)
				SetStatus(scope $"C import: {failed} of {files.Count} file(s) failed (Output Log).", .Error);
			else
				SetStatus(scope $"C import: {sets} set(s) imported in {ms:0} ms, {warnings} warning(s) (Output Log).", .Info);
			LastCImportWarnings = warnings;
			LastCImportFailed = failed;
		}

		/// What the last File > Import C Headers (or Import Again) gave: the import's warnings and the
		/// files that failed (-1: none ran yet). The self test reads them.
		public int LastCImportWarnings = -1;
		public int LastCImportFailed = -1;

		// ------------------------------------------------------------------ the project page's C Imports

		/// The `.cimport` file a `cimport` line names, as this platform reads it (its variant when it has one).
		void CImportFilePath(StringView line, String outPath)
		{
			String path = scope .();
			if (Path.IsPathRooted(line))
				path.Set(line);
			else
				path.AppendF("{}/{}", mProjectRoot, line);
			CImportFile.ForPlatform(path, outPath);
			outPath.Replace('\\', '/');
		}

		/// Reads a `.cimport` file; false (with `outWhy`) when it is not there or does not read.
		static bool ReadCImportFile(StringView path, CImportFile outFile, String outWhy)
		{
			String text = scope .();
			if (File.ReadAllText(path, text) case .Err)
			{
				outWhy.AppendF("{} is not there", path);
				return false;
			}
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (!ProjectCodec.ReadCImport(text, outFile, errors))
			{
				outWhy.AppendF("{} does not read", path);
				if (!errors.IsEmpty)
					outWhy.AppendF(": line {}: {}", errors[0].Line, errors[0].Message);
				return false;
			}
			return true;
		}

		/// The `only` names of set `setName` in the `.cimport` file at `path` become `names` (empty:
		/// every symbol of its headers is offered), written back as one `only` line. True when the file
		/// changed.
		public bool SetCImportOnly(StringView path, StringView setName, List<String> names)
		{
			if (!CheckWritable())
				return false;
			CImportFile f = scope .();
			String why = scope .();
			if (!ReadCImportFile(path, f, why))
			{
				SetStatus(why, .Warning);
				return false;
			}
			CImportSet set = null;
			for (let s in f.Sets)
				if (s.Name == setName)
					set = s;
			if (set == null)
				return false;
			String line = scope .();
			for (let n in names)
				line.AppendF("{}{}", line.IsEmpty ? "" : " ", n);
			String old = scope .();
			for (let o in set.Only)
				for (let w in StringView(o).Split(' ', .RemoveEmptyEntries))
					old.AppendF("{}{}", old.IsEmpty ? "" : " ", w);
			if (old == line)
				return false;
			ClearAndDeleteItems!(set.Only);
			for (let n in names)
				set.Only.Add(new String(n)); // one word each: the writer puts them on one `only` line
			String text = scope .();
			ProjectCodec.WriteCImport(f, text);
			if (FileSafety.AtomicWrite(path, text, false, why) case .Err)
			{
				SetStatus(scope $"Could not save {path}: {why}", .Warning);
				return false;
			}
			SetStatus(scope $"Saved {path}: Import Again makes the set's nodes from it");
			return true;
		}

		/// Adds a C import set to the project: a `.cimport` file is listed (a path relative to the
		/// project folder when it is inside it); a header gets a set of its own (ImportHeader.CreateSet).
		/// The project file is saved. False (with a status line) when nothing was added.
		public bool AddProjectCImport(StringView file)
		{
			if (Project == null || mProjectRoot.IsEmpty || !CheckWritable())
				return false;
			if (file.EndsWith(".cimport", .OrdinalIgnoreCase))
			{
				String full = scope .();
				Path.GetFullPath(file, full);
				full.Replace('\\', '/');
				String root = scope .(mProjectRoot);
				root.Replace('\\', '/');
				while (root.EndsWith('/'))
					root.RemoveFromEnd(1);
				String rel = scope .(full);
				if (full.Length > root.Length && full[root.Length] == '/' && StringView.Compare(full.Substring(0, root.Length), root, true) == 0)
					rel.Set(full.Substring(root.Length + 1));
				if (!Project.AddCImport(rel))
				{
					SetStatus(scope $"The project lists {rel} already", .Info);
					return false;
				}
			}
			else
			{
				String setPath = scope .();
				String why = scope .();
				if (!ImportHeader.CreateSet(mProjectRoot, Project, file, setPath, why))
				{
					SetStatus(why, .Warning);
					return false;
				}
			}
			return SaveProjectFile();
		}

		/// Removes `cimport` line `index` from the project (the `.cimport` file stays). Saved.
		public bool RemoveProjectCImport(int index)
		{
			if (Project == null || index < 0 || index >= Project.CImports.Count || !CheckWritable())
				return false;
			delete Project.CImports[index];
			Project.CImports.RemoveAt(index);
			return SaveProjectFile();
		}

		/// Value text cut to leave `reserve` pixels at the right of the value column, where the cursor
		/// is left for the row's buttons.
		static void ValueBeforeButtons(StringView text, float reserve)
		{
			let avail = Gui.igGetContentRegionAvail().x;
			float textW = Math.Max(10, avail - reserve - 4 * Look.Scale);
			Gui.igAlignTextToFramePadding();
			String shown = scope .();
			bool cut = Look.EllipsizeMiddle(text, textW, shown);
			Gui.TextColored(Look.ForegroundDim, shown);
			if (cut && Gui.igIsItemHovered(0))
				Gui.Tooltip(text);
			// The buttons end where the column does, as the define rows' X.
			Gui.SameLine(0, 0);
			Gui.igDummy(.(Math.Max(0, textW - Gui.CalcTextSize(shown).x), 1));
			Gui.SameLine(0, 4 * Look.Scale);
		}

		/// Opens a `.cimport` file in the system's text editor.
		void OpenCImportFile(StringView path)
		{
			ProcessStartInfo psi = scope .();
			String args = scope .();
#if BF_PLATFORM_WINDOWS
			psi.SetFileName(Desktop.SystemProgram("notepad.exe", .. scope String()));
			String winPath = scope .(path);
			winPath.Replace('/', '\\');
			args.AppendF("\"{}\"", winPath);
#else
			psi.SetFileName(Desktop.SystemProgram("xdg-open", .. scope String()));
			args.AppendF("\"{}\"", path);
#endif
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
				SetStatus(scope $"Could not open {path}", .Warning);
		}

		/// The project page's C Imports section: per `cimport` line its file (Open, Remove), each set
		/// in it with its headers and its `only` names (one row each, an X removes it; a field adds
		/// names), then Add Set and Import Again. Edits of the project's lines save the project file
		/// (returns false: nothing left for the caller to save); `only` edits save the `.cimport` file.
		bool DrawCImportRows(ProjectFile p)
		{
			String v = scope .();
			for (int i < p.CImports.Count)
			{
				Gui.PushID((int32)(900 + i));
				String path = scope .();
				CImportFilePath(p.CImports[i], path);
				PropertyGrid.Row((i == 0) ? "Sets" : "", scope $"A C import set file: {path}");
				float bw = Gui.igGetFrameHeight();
				ValueBeforeButtons(p.CImports[i], 2 * bw + 4 * Look.Scale);
				bool open = Gui.Button(Icon.FileCode, .(bw, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Open the .cimport file in a text editor");
				Gui.SameLine(0, 4 * Look.Scale);
				bool remove = Gui.Button(Icon.X, .(bw, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Remove the set from the project (the file stays)");
				if (open)
					OpenCImportFile(path);
				if (remove)
				{
					Gui.PopID();
					RemoveProjectCImport(i);
					return false;
				}
				CImportFile f = scope .();
				String why = scope .();
				if (!ReadCImportFile(path, f, why))
				{
					PropertyGrid.InfoRow("", why, default, Look.Warning, 0, true);
					Gui.PopID();
					continue;
				}
				for (let set in f.Sets)
				{
					Gui.PushID((int32)@set.Index);
					String headers = scope .();
					for (let h in set.Headers)
						headers.AppendF("{}{}", headers.IsEmpty ? "" : ", ", h);
					PropertyGrid.InfoRow(scope $"    {set.Name}", headers.IsEmpty ? "(no header)" : headers, "The headers the set imports");
					List<String> only = scope .();
					defer { ClearAndDeleteItems!(only); }
					for (let o in set.Only)
						for (let w in StringView(o).Split(' ', .RemoveEmptyEntries))
							only.Add(new String(w));
					bool edited = false;
					for (int k < only.Count)
					{
						Gui.PushID((int32)k);
						PropertyGrid.Row((k == 0) ? "      Only" : "", "The symbols the set offers (only): the rest of its headers is not imported, so it does not warn either");
						ValueBeforeButtons(only[k], bw);
						if (Gui.Button(Icon.X, .(bw, 0)))
						{
							delete only[k];
							only.RemoveAt(k);
							edited = true;
						}
						else if (Gui.igIsItemHovered(0))
							Gui.Tooltip(scope $"Stop offering {only[k]}");
						Gui.PopID();
						if (edited)
							break;
					}
					v.Clear();
					if (!edited && TsText(only.IsEmpty ? "      Only" : "", scope $"##cionly{i}_{@set.Index}", "", v,
						only.IsEmpty ? "Offer only these symbols (only): empty imports everything the headers declare, with the warnings of all of it" : "Add symbols the set offers",
						only.IsEmpty ? "everything (type names)" : "add names"))
					{
						for (let w in v.Split(' ', .RemoveEmptyEntries))
							if (!only.ContainsAlt(w))
								only.Add(new String(w));
						edited = true;
					}
					Gui.PopID();
					if (edited)
					{
						SetCImportOnly(path, set.Name, only);
						Gui.PopID();
						return false;
					}
				}
				Gui.PopID();
			}
			if (p.CImports.IsEmpty)
				PropertyGrid.InfoRow("Sets", "none: Add Set imports a C header");
			if (PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Set...", "A .cimport file, or a C header (it gets a set of its own)"))
			{
				char8[4096] buf = default;
				let picked = ImGui.Host.th_native_dialog(0, scope String(mProjectRoot), &buf, 4096);
				if (picked == 1)
					AddProjectCImport(StringView(&buf));
				else if (picked == -1)
					SetStatus("There is no file dialog here: File > Import C Headers makes a set for a header", .Warning);
			}
			if (!p.CImports.IsEmpty && PropertyGrid.ButtonRow("", scope $"{Icon.RefreshCw} Import Again", "Imports every set again (after editing a set): the Node menu and Validate see the new declarations"))
				ImportCHeaders();
			return false;
		}

		// ------------------------------------------------------------------ self test
#if TREADLE_SELFTEST

		/// The repository folder above the exe that holds tools/probe/headers (TREADLE_SAMPLES's
		/// grandparent first).
		static bool FindRepoRoot(String outRoot)
		{
			String samples = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_SAMPLES", samples) case .Ok && !samples.IsEmpty)
			{
				String a = scope .();
				String b = scope .();
				if (Path.GetDirectoryPath(samples, a) case .Ok && Path.GetDirectoryPath(a, b) case .Ok && File.Exists(scope $"{b}/tools/probe/headers/small.h"))
				{
					outRoot.Set(b);
					return true;
				}
			}
			String dir = scope .();
			Environment.GetExecutableFilePath(dir);
			for (int up < 8)
			{
				String parent = scope .();
				if (Path.GetDirectoryPath(dir, parent) case .Err)
					break;
				dir.Set(parent);
				if (File.Exists(scope $"{dir}/tools/probe/headers/small.h"))
				{
					outRoot.Set(dir);
					return true;
				}
			}
			return false;
		}

		static void SelfTestNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      {text}");

		static String FunctionText(CFunction f, String outText)
		{
			outText.AppendF("{}(", f.Name);
			for (let p in f.Params)
			{
				if (@p.Index > 0)
					outText.Append(',');
				outText.Append(p.Type);
			}
			if (f.Variadic)
				outText.Append(f.Params.IsEmpty ? "..." : ",...");
			outText.AppendF(") {}", f.Returns ?? "void");
			return outText;
		}

		void CheckFunction(CDeclSet d, StringView want, StringView label)
		{
			let open = want.IndexOf('(');
			let f = d.FindFunction(want.Substring(0, open));
			String got = scope .();
			if (f != null)
				FunctionText(f, got);
			String what = scope $"cimport: {label} {want}";
			if (got != want)
				what.AppendF(" (got '{}')", got);
			SelfTestCheck(got == want, what);
		}

		/// `cimport`: libclang loads; the probe's small.h imports to the checked-in
		/// TreadleCImport/fixtures/small.cdecl (TREADLE_WRITE_FIXTURES=1 rewrites it), byte-identical
		/// on a second run and canonical for the type-file codec; <stdio.h> gives puts / printf / FILE;
		/// SDL.h gives SDL_Init / SDL_CreateWindow / SDL_Event with their sizes, and the time is logged.
		bool SelfTestCImport()
		{
			SelfTestSecurityCImport(); // SelfTestSecurity.bf
			SelfTestCheck(LibClang.Load(), scope $"cimport: libclang loads ({LibClang.Path}) {LibClang.Error}");
			if (!LibClang.IsLoaded)
				return true;
			SelfTestNote(scope $"{LibClang.Version}; builtin headers {LibClang.ResourceInclude}");
			String root = scope .();
			if (!FindRepoRoot(root))
			{
				SelfTestCheck(false, "cimport: tools/probe/headers not found above the exe (set TREADLE_SAMPLES)");
				return true;
			}

			// 1. small.h against the expected file
			let fixtures = scope String()..AppendF("{}/TreadleCImport/fixtures", root);
			let setPath = scope String()..AppendF("{}/small.cimport", fixtures);
			String setText = scope .();
			CImportFile setFile = scope .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (File.ReadAllText(setPath, setText, true) case .Err || !ProjectCodec.ReadCImport(setText, setFile, errors) || setFile.Sets.IsEmpty)
				SelfTestCheck(false, scope $"cimport: {setPath} reads");
			else
			{
				CDeclSet a = scope .();
				CDeclSet b = scope .();
				let okA = CImporter.ImportSet(setFile.Sets[0], fixtures, "small.cimport", a);
				let okB = CImporter.ImportSet(setFile.Sets[0], fixtures, "small.cimport", b);
				SelfTestCheck(okA && okB, scope $"cimport: small.h imports ({a.Errors.Count} errors)");
				for (let e in a.Errors)
					SelfTestNote(e);
				String textA = scope .();
				String textB = scope .();
				CDeclWriter.Write(a, textA);
				CDeclWriter.Write(b, textB);
				SelfTestCheck(textA == textB, "cimport: a second import of small.h gives the same bytes");
				let expectedPath = scope String()..AppendF("{}/small.cdecl", fixtures);
				String env = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_WRITE_FIXTURES", env) case .Ok && env == "1")
				{
					File.WriteAllText(expectedPath, textA).IgnoreError();
					SelfTestNote(scope $"wrote {expectedPath}");
				}
				String expected = scope .();
				if (File.ReadAllText(expectedPath, expected, true) case .Err)
					SelfTestCheck(false, scope $"cimport: {expectedPath} reads");
				else
				{
					SelfTestCheck(textA == expected, "cimport: small.h matches TreadleCImport/fixtures/small.cdecl");
					if (textA != expected)
						for (var line in textA.Split('\n'))
							SelfTestNote(line);
				}
				for (let w in a.Warnings)
					SelfTestNote(scope $"warning: {w}");
				// canonical for the codec: read + write gives the same bytes
				TypeDocument doc = scope .();
				ClearAndDeleteItems!(errors);
				let read = TreadleCodec.ReadAll(textA, doc, errors);
				String back = scope .();
				if (read)
					scope TreadleCodec().Write(doc, back, scope String());
				SelfTestCheck(read && back == textA, "cimport: the .cdecl reads and writes back byte for byte through the type-file codec");
			}

			// 1b. Extern variables (cvar): the m2 sample's cvars set gives small.h's treadle_counter, and
			//     errno / stdout, macros that read a variable through _errno() / __acrt_iob_func(1)
			//     (`via`), against the checked-in cvars.windows.cdecl. On Linux cvars.linux.cimport against
			//     cvars.linux.cdecl: glibc's errno is (*__errno_location ()), stdout a plain extern.
			{
				let dir = scope String()..AppendF("{}/TreadleCore/samples/m2-frontend/src", root);
#if BF_PLATFORM_WINDOWS
				let cvarsFile = "cvars.cimport";
				let cvarsCDecl = "cvars.windows.cdecl";
				let errnoVia = "cvar errno int32\n\tvia _errno deref\n";
				let stdoutVar = "cvar stdout FILE*\n\tvia __acrt_iob_func 1\n";
				let what = "errno via _errno deref, stdout via __acrt_iob_func 1";
#else
				let cvarsFile = "cvars.linux.cimport";
				let cvarsCDecl = "cvars.linux.cdecl";
				let errnoVia = "cvar errno int32\n\tvia __errno_location deref\n";
				let stdoutVar = "cvar stdout FILE*\n";
				let what = "errno via __errno_location deref, stdout a plain cvar";
#endif
				String text = scope .();
				CImportFile file = scope .();
				ClearAndDeleteItems!(errors);
				if (File.ReadAllText(scope $"{dir}/{cvarsFile}", text, true) case .Err || !ProjectCodec.ReadCImport(text, file, errors) || file.Sets.IsEmpty)
					SelfTestCheck(false, scope $"cimport: m2-frontend/src/{cvarsFile} reads");
				else
				{
					CDeclSet d = scope .();
					let ok = CImporter.ImportSet(file.Sets[0], dir, cvarsFile, d);
					String got = scope .();
					CDeclWriter.Write(d, got);
					let expectedPath = scope String()..AppendF("{}/{}", dir, cvarsCDecl);
					String env = scope .();
					if (Environment.GetEnvironmentVariable("TREADLE_WRITE_FIXTURES", env) case .Ok && env == "1")
						File.WriteAllText(expectedPath, got).IgnoreError();
					String expected = scope .();
					File.ReadAllText(expectedPath, expected, true).IgnoreError();
					let vars = got.Contains(errnoVia) && got.Contains(stdoutVar) && got.Contains("cvar treadle_counter int32\n");
					SelfTestCheck(ok && got == expected && vars, scope $"cimport: {cvarsFile} matches {cvarsCDecl}: treadle_counter, {what} {vars}");
					if (got != expected)
						for (var line in got.Split('\n'))
							SelfTestNote(line);
				}
			}

			// 1c. Platform names (--import-c): a set file with a platform variant writes
			//     <set>.windows.cdecl / <set>.linux.cdecl, one without <set>.cdecl; a shared <set>.cdecl
			//     with the same bytes is left as it is. cvars into an empty folder gives the checked-in
			//     platform file; sdl2 next to a copy of the checked-in (shared) sdl2.cdecl writes nothing.
			{
				let samples = scope String()..AppendF("{}/TreadleCore/samples", root);
				String cvarsName = scope .();
				CImporter.CDeclFileName(scope $"{samples}/m2-frontend/src/cvars.cimport", "cvars", cvarsName);
				String libcName = scope .();
				CImporter.CDeclFileName(scope $"{samples}/libc.cimport", "libc", libcName);
				let wantCvars = scope String()..AppendF("cvars{}", CImportFile.PlatformCDeclSuffix);
				SelfTestCheck(cvarsName == wantCvars && libcName == "libc.cdecl", scope $"cimport: the import names cvars {cvarsName} (a set with a platform variant) and libc {libcName}");
				String tmp = scope .();
				Path.GetTempPath(tmp);
				tmp.AppendF("treadle-cimport-{}", Platform.BfpSystem_GetTimeStamp());
				Directory.CreateDirectory(tmp).IgnoreError();
				CImportReport cr = scope .();
				let okC = CImporter.ImportFile(scope $"{samples}/m2-frontend/src/cvars.cimport", tmp, cr);
				String got = scope .();
				String want = scope .();
				File.ReadAllText(scope $"{tmp}/{wantCvars}", got, true).IgnoreError();
				File.ReadAllText(scope $"{samples}/m2-frontend/src/{wantCvars}", want, true).IgnoreError();
				SelfTestCheck(okC && !got.IsEmpty && got == want && !File.Exists(scope $"{tmp}/cvars.cdecl"),
					scope $"cimport: --import-c of cvars.cimport writes {wantCvars}, byte for byte the checked-in one");
				String sdlShared = scope .();
				File.ReadAllText(scope $"{samples}/m2-sdl/sdl2.cdecl", sdlShared, true).IgnoreError();
				File.WriteAllText(scope $"{tmp}/sdl2.cdecl", sdlShared).IgnoreError();
				CImportReport sr = scope .();
				let okS = CImporter.ImportFile(scope $"{samples}/m2-sdl/sdl2.cimport", tmp, sr);
				let unchanged = okS && sr.Sets.Count == 1 && sr.Sets[0].Unchanged && sr.Sets[0].OutPath.EndsWith("sdl2.cdecl");
				SelfTestCheck(unchanged && !File.Exists(scope $"{tmp}/sdl2{CImportFile.PlatformCDeclSuffix}"),
					"cimport: --import-c of sdl2.cimport gives the bytes of the shared sdl2.cdecl and writes no platform file");
				for (let s in sr.Sets)
					if (s.Decls != null)
						for (let e in s.Decls.Errors)
							SelfTestNote(e);
				for (let e in Directory.EnumerateFiles(tmp))
					File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
				Directory.Delete(tmp).IgnoreError();
			}

			// 2. <stdio.h>
			{
				CImportSet set = scope .();
				set.Name.Set("stdio");
				set.Headers.Add(new String("stdio.h"));
				CDeclSet d = scope .();
				let sw = scope Stopwatch(true);
				let ok = CImporter.ImportSet(set, fixtures, "stdio.cimport", d);
				let ms = sw.Elapsed.TotalMilliseconds;
				SelfTestCheck(ok, "cimport: <stdio.h> imports");
				for (let e in d.Errors)
					SelfTestNote(e);
				CheckFunction(d, "puts(char8*) int32", "stdio");
				CheckFunction(d, "printf(char8*,...) int32", "stdio");
				CheckFunction(d, "fopen(char8*,char8*) FILE*", "stdio");
				CheckFunction(d, "fclose(FILE*) int32", "stdio");
				let file = d.FindTypedef("FILE");
				let iobuf = (file != null) ? d.FindRecord(file.Target) : null;
				SelfTestCheck(iobuf != null, scope $"cimport: stdio FILE is a typedef of the struct {(file != null) ? (StringView)file.Target : "?"}");
				let eof = d.FindConst("EOF");
				SelfTestCheck(eof != null && eof.Value == "-1" && eof.Type == "int32", "cimport: stdio EOF = -1 (int32)");
				String counts = scope .();
				d.Counts(counts);
				SelfTestNote(scope $"stdio: {counts}; {ms:0.0} ms (parse {d.ParseMs:0.0}, walk {d.WalkMs:0.0})");
				int shown = 0;
				for (let w in d.Warnings)
					if (shown++ < 8)
						SelfTestNote(scope $"warning: {w}");
			}

			// 3. SDL.h
			{
				// The m2-sdl sample's rule: TREADLE_SDL2 is the SDL2 package root, else tools/SDL2-2.32.10
				// (Windows, the mingw package) or /usr (Linux, the distribution's libsdl2-dev).
				String sdl = scope .();
#if BF_PLATFORM_WINDOWS
				CImportSet.ExpandPath(scope $"${{TREADLE_SDL2:-{root}/tools/SDL2-2.32.10}}/x86_64-w64-mingw32/include/SDL2", sdl);
#else
				CImportSet.ExpandPath("${TREADLE_SDL2:-/usr}/include/SDL2", sdl);
#endif
				if (!File.Exists(scope $"{sdl}/SDL.h"))
					SelfTestCheck(false, scope $"cimport: SDL.h not found in {sdl} (TREADLE_SDL2)");
				else
				{
					CImportSet set = scope .();
					set.Name.Set("sdl2");
					set.Headers.Add(new String("SDL.h"));
					set.Includes.Add(new String(sdl));
					set.Defines.Add(new String("SDL_MAIN_HANDLED"));
					CDeclSet d = scope .();
					let sw = scope Stopwatch(true);
					let ok = CImporter.ImportSet(set, fixtures, "sdl2.cimport", d);
					let ms = sw.Elapsed.TotalMilliseconds;
					SelfTestCheck(ok, "cimport: SDL.h imports");
					for (let e in d.Errors)
						SelfTestNote(e);
					CheckFunction(d, "SDL_Init(uint32) int32", "SDL");
					CheckFunction(d, "SDL_CreateWindow(char8*,int32,int32,int32,int32,uint32) SDL_Window*", "SDL");
					CheckFunction(d, "SDL_PollEvent(SDL_Event*) int32", "SDL");
					let ev = d.FindRecord("SDL_Event");
					SelfTestCheck(ev != null && ev.IsUnion && ev.Size == 56 && ev.Align == 8, scope $"cimport: SDL_Event is a 56-byte union (got {(ev != null) ? ev.Size : -1})");
					let win = d.FindRecord("SDL_Window");
					SelfTestCheck(win != null && win.Opaque, "cimport: SDL_Window is opaque");
					let rect = d.FindRecord("SDL_Rect");
					SelfTestCheck(rect != null && rect.Size == 16 && rect.Fields.Count == 4 && rect.Fields[3].Name == "h" && rect.Fields[3].Offset == 12, "cimport: SDL_Rect has x y w h at 0 4 8 12");
					let flag = d.FindEnum("SDL_WindowFlags");
					SelfTestCheck(flag != null && flag.Values.Count > 10, "cimport: SDL_WindowFlags enum");
					let initVideo = d.FindConst("SDL_INIT_VIDEO");
					SelfTestCheck(initVideo != null && initVideo.Value == "32", "cimport: SDL_INIT_VIDEO = 32");
					let everything = d.FindConst("SDL_INIT_EVERYTHING");
					SelfTestCheck(everything != null && everything.Value == "62001", scope $"cimport: SDL_INIT_EVERYTHING = 62001 (got {(everything != null) ? (StringView)everything.Value : "none"})");
					String counts = scope .();
					d.Counts(counts);
					SelfTestNote(scope $"SDL.h: {counts}; {ms:0.0} ms (parse {d.ParseMs:0.0}, walk {d.WalkMs:0.0})");
					SelfTestCheck(ms < 5000, scope $"cimport: SDL.h in {ms:0} ms");
					int shown = 0;
					for (let w in d.Warnings)
						if (shown++ < 12)
							SelfTestNote(scope $"warning: {w}");
				}
			}

			// 4. File > Import C Headers, when the editor was opened on a project with C import sets:
			//    every set gets build/cimport/<set>.cdecl and the front end sees its functions.
			if (!mProjectRoot.IsEmpty && Project != null && !Project.CImports.IsEmpty)
			{
				ImportCHeaders();
				for (let ci in Project.CImports)
				{
					String text = scope .();
					CImportFile f = scope .();
					ClearAndDeleteItems!(errors);
					if (File.ReadAllText(scope $"{mProjectRoot}/{ci}", text, true) case .Err || !ProjectCodec.ReadCImport(text, f, errors))
					{
						SelfTestCheck(false, scope $"cimport: {ci} reads");
						continue;
					}
					for (let set in f.Sets)
					{
						String name = scope .();
						CImporter.CDeclFileName(scope $"{mProjectRoot}/{ci}", set.Name, name);
						SelfTestCheck(File.Exists(scope $"{mProjectRoot}/build/cimport/{name}") || File.Exists(scope $"{mProjectRoot}/build/cimport/{set.Name}.cdecl"),
							scope $"cimport: Import C Headers wrote build/cimport/{name}");
						let c = FrontEnd?.Current;
						let t = c?.Table.Find(scope $"C.{set.Name}");
						SelfTestCheck(t != null && !t.Members.IsEmpty, scope $"cimport: the front end declares C.{set.Name} ({(t != null) ? t.Members.Count : 0} functions)");
					}
				}
			}

			// 5. Import C Headers on a project with no set: a copy of small.h in <project>/include gets
			//    small.cimport (header small.h, include include) and the project file's `cimport` line;
			//    the import writes build/cimport/small.cdecl and the front end declares C.small.
			{
				String tmp = scope .();
				Path.GetTempPath(tmp);
				tmp.AppendF("treadle-newset-{}", Platform.BfpSystem_GetTimeStamp());
				tmp.Replace('\\', '/');
				Directory.CreateDirectory(scope $"{tmp}/include").IgnoreError();
				String small = scope .();
				File.ReadAllText(scope $"{root}/tools/probe/headers/small.h", small, true).IgnoreError();
				File.WriteAllText(scope $"{tmp}/include/small.h", small).IgnoreError();
				let projectText = "# tproj 1\nproject NewSet\n\tkind console\n";
				File.WriteAllText(scope $"{tmp}/NewSet.tproj", projectText).IgnoreError();
				ProjectFile project = scope .();
				ClearAndDeleteItems!(errors);
				ProjectCodec.ReadProject(projectText, project, errors);
				String newSetPath = scope .();
				String why = scope .();
				let made = ImportHeader.CreateSet(tmp, project, scope $"{tmp}/include/small.h", newSetPath, why);
				String newSetText = scope .();
				File.ReadAllText(newSetPath, newSetText, true).IgnoreError();
				String projectBack = scope .();
				ProjectCodec.WriteProject(project, projectBack);
				File.WriteAllText(scope $"{tmp}/NewSet.tproj", projectBack).IgnoreError();
				let wantSet = "# cimport 1\nimport small\n\theader small.h\n\tinclude include\n";
				SelfTestCheck(made && newSetText == wantSet && projectBack.Contains("cimport small.cimport\n"),
					scope $"cimport: a header with no set gets small.cimport (header small.h, include include) and the project's cimport line {why}");
				if (newSetText != wantSet)
					SelfTestNote(newSetText);
				CImportReport report = scope .();
				let imported = CImporter.ImportFile(newSetPath, "", report);
				let cdecl = File.Exists(scope $"{tmp}/build/cimport/small.cdecl");
				let project2 = Treadle.Compiler.ProjectLoader.ReadProject(scope $"{tmp}/NewSet.tproj");
				let c = Treadle.Compiler.ProjectLoader.Make(tmp, null, null, project2);
				c.Run();
				let t = c.Table.Find("C.small");
				let members = (t != null) ? t.Members.Count : 0;
				SelfTestCheck(imported && cdecl && members > 0, scope $"cimport: the new set imports to build/cimport/small.cdecl and the front end declares C.small ({members} members)");
				delete c;
				delete project2;
				for (let sub in StringView[?]("build/cimport", "build", "include", ""))
				{
					String dir = scope $"{tmp}/{sub}";
					if (!Directory.Exists(dir))
						continue;
					for (let e in Directory.EnumerateFiles(dir))
						File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
					Directory.Delete(dir).IgnoreError();
				}
			}

			// 6. Import C Headers runs `--import-c` in a child editor (Security-Review.md finding 26):
			//    small.h imports through it, and a header nested 20000 deep (a struct inside a struct, the
			//    review's fuzz crash, which overflows libclang's parser stack) fails the import with
			//    `import failed: <reason>` while this editor runs on.
			{
				String tmp = scope .();
				Path.GetTempPath(tmp);
				tmp.AppendF("treadle-childimport-{}", (int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF);
				tmp.Replace('\\', '/');
				Directory.CreateDirectory(tmp).IgnoreError();
				String small = scope .();
				File.ReadAllText(scope $"{root}/tools/probe/headers/small.h", small, true).IgnoreError();
				File.WriteAllText(scope $"{tmp}/small.h", small).IgnoreError();
				File.WriteAllText(scope $"{tmp}/small.cimport", "# cimport 1\nimport small\n\theader small.h\n").IgnoreError();
				String deep = scope .();
				deep.Append("int deep_f(void);\n");
				for (int i < 20000)
					deep.Append("struct A { ");
				deep.Append("int x; ");
				for (int i < 20000)
					deep.Append("};");
				deep.Append("\n");
				File.WriteAllText(scope $"{tmp}/deep.h", deep).IgnoreError();
				File.WriteAllText(scope $"{tmp}/deep.cimport", "# cimport 1\nimport deep\n\theader deep.h\n").IgnoreError();
				let good = ImportHeader.ImportInChild(scope $"{tmp}/small.cimport", scope $"{tmp}/out");
				SelfTestCheck(good.Ok && good.Sets == 1 && File.Exists(scope $"{tmp}/out/small.cdecl"),
					scope $"cimport: small.cimport imports in a child editor (exit {good.ExitCode}, {good.Sets} set, {good.Ms:0} ms) and writes small.cdecl");
				let bad = ImportHeader.ImportInChild(scope $"{tmp}/deep.cimport", scope $"{tmp}/out");
				let line = bad.Lines.IsEmpty ? "" : (StringView)bad.Lines.Back;
				SelfTestCheck(!bad.Ok && !bad.Reason.IsEmpty && line.Contains("import failed: "),
					scope $"cimport: a header nested 20000 deep fails in the child, the editor runs on: {line}");
				delete good;
				delete bad;
				for (let sub in StringView[?]("out", ""))
				{
					String dir = scope $"{tmp}/{sub}";
					if (!Directory.Exists(dir))
						continue;
					for (let e in Directory.EnumerateFiles(dir))
						File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
					Directory.Delete(dir).IgnoreError();
				}
			}
			return true;
		}
#endif
	}
}
