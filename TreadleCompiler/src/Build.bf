using System;
using System.Collections;
using System.IO;
using System.Threading;
using Treadle.Model;
using Treadle.Document;

namespace Treadle.Compiler
{
	/// The front end's part of Build: the saved project folder through Declare, Bind, Check and
	/// Lower into the Sheet IR text the back end reads (its IRReader turns it into an IRProgram;
	/// the editor's IProgramSource adapter does that). Reads the files from disk, so it may run on
	/// the build thread.
	static class FrontEndBuild
	{
		/// One front end at a time: Build lowers on the build thread while the editor's Validate,
		/// type and catalogue queries compile on the UI thread (FrontEndServices.Current). Both take
		/// this lock, so the two never run the compiler (and the core's shared tables) together.
		public static Monitor Lock = new .() ~ delete _;

		/// Lowers the project in `workspace`. False (with the diagnostics in `outMessages`) when a
		/// Sheet has errors or there is no entry type. Takes `Lock`.
		public static bool WriteProgram(StringView workspace, StringView config, String outKir, List<Diagnostic> outMessages,
			List<String> outLinkInputs = null, List<String> outRunFiles = null, List<String> outInputs = null)
		{
			using (Lock.Enter())
				return WriteProgramLocked(workspace, config, outKir, outMessages, outLinkInputs, outRunFiles, outInputs);
		}

		/// The C runtime and the system libraries the toolchain links anyway: a `lib` naming one is
		/// not passed again.
		static StringView[?] sDefaultLibs = .("msvcrt", "ucrt", "ucrtbase", "kernel32", "c", "m");

		/// What the project's C import sets give the link and the program's folder (docs/C-Import.md,
		/// "Building with a set"): each `lib` (an import library's path, or a bare library name), each
		/// `bin` (a file copied next to the exe, a DLL); paths expand `${NAME}` and are relative to the
		/// set file (CImportSet.ResolvePath). `outSources` (may be null) gets the `csource` files
		/// alone.
		public static void LinkInputs(Compilation c, List<String> outLinkInputs, List<String> outRunFiles, List<String> outSources = null)
		{
			void AddPath(List<String> into, StringView token, StringView dir)
			{
				String path = scope .();
				CImportSet.ResolvePath(token, dir, path);
				for (let have in into)
					if (StringView.Compare(have, path, true) == 0)
						return;
				into.Add(new String(path));
			}
			for (let u in c.Units)
			{
				if (!u.IsCDecl || u.Set == null)
					continue;
				for (let line in u.Set.Libs)
					for (var tok in line.Split(' ', .RemoveEmptyEntries))
					{
						tok.Trim();
						bool isPath = tok.Contains('/') || tok.Contains('\\') || tok.EndsWith(".a") || tok.EndsWith(".lib");
						if (isPath)
						{
							if (outLinkInputs != null)
								AddPath(outLinkInputs, tok, u.SetDir);
							continue;
						}
						bool known = false;
						for (let d in sDefaultLibs)
							known |= StringView.Compare(tok, d, true) == 0;
						if (!known && outLinkInputs != null && !outLinkInputs.ContainsAlt(tok))
							outLinkInputs.Add(new String(tok));
					}
				if (u.Set.Extras.Inner == null)
					continue;
				// `bin <file>`: copied next to the exe; `csource <file>`: a C source compiled into
				// the program by the link's clang (same target and flags), e.g. what defines a `cvar`.
				for (let a in u.Set.Extras.Inner)
				{
					var line = StringView(a.Line);
					line.Trim();
					let isBin = line.StartsWith("bin ");
					let isSource = line.StartsWith("csource ");
					if (!isBin && !isSource)
						continue;
					var rest = line.Substring(isBin ? 4 : 8);
					rest.Trim();
					String unq = scope .();
					if (rest.StartsWith('"'))
						Treadle.Format.RecordText.Unquote(rest, unq);
					else
						unq.Set(rest);
					if (isBin && outRunFiles != null)
						AddPath(outRunFiles, unq, u.SetDir);
					else if (isSource)
					{
						if (outLinkInputs != null)
							AddPath(outLinkInputs, unq, u.SetDir);
						if (outSources != null)
							AddPath(outSources, unq, u.SetDir);
					}
				}
			}
		}

		/// What the program is made from besides what its Sheet IR says (Compiler.md 9): the project
		/// file, the `depends` project files, the C import set files and their declarations, the
		/// `csource` files (compiled by the link, so nothing else would notice them) and the core
		/// library, one `<path>|<time>` line each (the core: `core|<hash of its stamp>`). Build's link
		/// stamp lists them: a change to any of them links again.
		public static void InputStamps(Compilation c, StringView projectPath, List<String> outStamps)
		{
			List<String> sources = scope .();
			defer { ClearAndDeleteItems!(sources); }
			LinkInputs(c, null, null, sources);
			List<String> lines = scope .();
			defer { ClearAndDeleteItems!(lines); }
			void Stamp(StringView path)
			{
				int64 ticks = 0;
				if (File.GetLastWriteTime(path) case .Ok(let t))
					ticks = t.Ticks;
				String line = new $"{path}|{ticks}";
				if (lines.Contains(line))
					delete line;
				else
					lines.Add(line);
			}
			if (!projectPath.IsEmpty)
				Stamp(projectPath);
			for (let p in c.InputFiles)
				Stamp(p);
			for (let s in sources)
				Stamp(s);
			uint64 h = 1469598103934665603UL;
			for (let ch in CoreSource.CurrentStamp.RawChars)
			{
				h ^= (uint8)ch;
				h *= 1099511628211UL;
			}
			lines.Sort(scope (a, b) => String.Compare(a, b, false));
			for (let l in lines)
				outStamps.Add(new String(l));
			outStamps.Add(new $"core|{h:X16}");
		}

		static bool WriteProgramLocked(StringView workspace, StringView config, String outKir, List<Diagnostic> outMessages,
			List<String> outLinkInputs, List<String> outRunFiles, List<String> outInputs)
		{
			String projectPath = scope .();
			if (Directory.Exists(workspace))
				for (let e in Directory.EnumerateFiles(workspace))
				{
					let p = e.GetFilePath(.. scope String());
					if (Treadle.Format.FormatNames.IsProjectFile(p))
					{
						projectPath.Set(p);
						break;
					}
				}
			let project = projectPath.IsEmpty ? null : ProjectLoader.ReadProject(projectPath);
			defer delete project;
			let c = ProjectLoader.Make(workspace, null, null, project);
			defer delete c;
			// the config's flags (Graph-Format.md 5): `checks` and the `define`s the program reads
			// (Build.IsDefined / Build.Value); `optimize` is the back end's
			c.Settings = new .();
			List<String> bad = scope .();
			defer { ClearAndDeleteItems!(bad); }
			c.Settings.Resolve(project, config, bad);
			c.Debug = c.Settings.Checks;
			for (let b in bad)
			{
				CDiag d = scope .();
				d.Message.Set(b);
				d.File.Set(projectPath);
				outMessages.Add(ToDiagnostic(d, .Build));
			}
			if (!bad.IsEmpty)
				return false;
			if (c.Settings.Simd == "native")
			{
				// `simd native`: code for this machine's CPU only (SIMD-and-Vectors.md 1.7)
				CDiag d = scope .();
				d.Severity = .Warning;
				d.Code.Set("T1093");
				d.Message.AppendF("config {}: simd native compiles for this machine's CPU: the program may not start on another one; ship a build with a named level (x86-64-v2, x86-64-v3)", config);
				d.File.Set(projectPath);
				outMessages.Add(ToDiagnostic(d, .Build));
			}
			StringView kind = ProjectFile.KindConsole;
			if (project != null && !project.KindIs(out kind))
			{
				CDiag d = scope .();
				d.Message.AppendF("the project's kind '{}' is not console, windowed or library", project.Kind);
				d.File.Set(projectPath);
				outMessages.Add(ToDiagnostic(d, .Build));
				return false;
			}
			let library = kind == ProjectFile.KindLibrary;
			c.Run();
			String name = scope .();
			if (project != null && !project.Name.IsEmpty)
				name.Set(project.Name);
			else
				Path.GetFileName(workspace, name);
			String entry = scope .();
			if (project != null && project.Entry != null && !library)
				project.Entry.ToString(entry);
			if (entry.IsEmpty && !library)
			{
				CDiag d = scope .();
				d.Message.Set("the project names no entry type (`entry` in the project file): there is no Program Start");
				outMessages.Add(ToDiagnostic(d, .Build));
				return false;
			}
			if (library && !HasExports(c))
			{
				// not an error: the library still builds, with treadle_init / treadle_shutdown only
				CDiag d = scope .();
				d.Severity = .Warning;
				d.Message.Set("the project is a library (kind library) but no function has [Export(\"name\")]: the library exports nothing of its own");
				d.File.Set(projectPath);
				outMessages.Add(ToDiagnostic(d, .Build));
			}
			bool ok = c.Diags.ErrorCount == 0 && Lowering.WriteProgram(c, name, entry, outKir, kind);
			LinkInputs(c, outLinkInputs, outRunFiles);
			{
				// C import paths that leave the project folder (Security-Review.md finding 3): named on every
				// Build, so a project from someone else shows what it reaches before it is run
				List<String> outside = scope .();
				defer { ClearAndDeleteItems!(outside); }
				OutsidePaths(c, workspace, outside);
				if (!outside.IsEmpty)
				{
					CDiag d = scope .();
					d.Severity = .Warning;
					d.Message.Append("C import paths outside the project folder (a project from someone else can reach files anywhere through them: check them before you run it): ");
					for (let p in outside)
						d.Message.AppendF("{}{}", (@p.Index > 0) ? ", " : "", p);
					d.File.Set(projectPath);
					outMessages.Add(ToDiagnostic(d, .Build));
				}
			}
			if (outInputs != null)
				InputStamps(c, projectPath, outInputs);
			for (let d in c.Diags.Items)
				if (d.Severity != .Note)
					outMessages.Add(ToDiagnostic(d, .Build));
			return ok && c.Diags.ErrorCount == 0;
		}

		/// The paths of the project's C import sets (`include`, `header`, `lib`, `bin`, `csource`) that, with
		/// `${NAME}` expanded and `..` resolved, are not inside `workspace` (Security-Review.md finding 3).
		/// A bare header or library name (found on the include path or the linker's) is not a path. The
		/// core library's own set is not looked at.
		public static void OutsidePaths(Compilation c, StringView workspace, List<String> outPaths)
		{
			String root = scope .();
			Path.GetFullPath(workspace, root);
			root.Replace('\\', '/');
			while (root.Length > 1 && root.EndsWith('/'))
				root.RemoveFromEnd(1);
			void Check(StringView token, StringView dir, bool bareIsName)
			{
				var token;
				token.Trim();
				if (token.IsEmpty)
					return;
				String unq = scope .();
				if (token.StartsWith('"'))
					Treadle.Format.RecordText.Unquote(token, unq);
				else
					unq.Set(token);
				if (bareIsName && !unq.Contains('/') && !unq.Contains('\\') && !unq.Contains('$'))
					return;
				String resolved = scope .();
				CImportSet.ResolvePath(unq, dir, resolved);
				String full = scope .();
				Path.GetFullPath(resolved, full);
				full.Replace('\\', '/');
#if BF_PLATFORM_WINDOWS
				let inside = full.Length >= root.Length && StringView.Compare(full.Substring(0, root.Length), root, true) == 0 && (full.Length == root.Length || full[root.Length] == '/');
#else
				let inside = full.StartsWith(root) && (full.Length == root.Length || full[root.Length] == '/');
#endif
				if (inside)
					return;
				for (let have in outPaths)
					if (have == full)
						return;
				outPaths.Add(new String(full));
			}
			for (let u in c.Units)
			{
				if (!u.IsCDecl || u.Set == null || u.IsCore)
					continue;
				for (let line in u.Set.Includes)
					Check(line, u.SetDir, false);
				for (let line in u.Set.Headers)
					Check(line, u.SetDir, true);
				for (let line in u.Set.Libs)
					for (let tok in line.Split(' ', .RemoveEmptyEntries))
						Check(tok, u.SetDir, true);
				if (u.Set.Extras.Inner == null)
					continue;
				for (let a in u.Set.Extras.Inner)
				{
					var line = StringView(a.Line);
					line.Trim();
					if (line.StartsWith("bin "))
						Check(line.Substring(4), u.SetDir, false);
					else if (line.StartsWith("csource "))
						Check(line.Substring(8), u.SetDir, false);
				}
			}
		}

		/// A function of the project (not the core, not a C import) has `[Export]`.

		static bool HasExports(Compilation c)
		{
			for (let u in c.Units)
			{
				if (u.Sym == null || u.IsCore || u.IsCDecl)
					continue;
				for (let m in u.Sym.Members)
					if (m.ExportName != null)
						return true;
			}
			return false;
		}

		/// The editor's diagnostic for a compiler diagnostic (placed on its node by record id).
		public static Diagnostic ToDiagnostic(CDiag d, DiagnosticOrigin origin)
		{
			Diagnostic o = new .();
			o.Severity = (d.Severity == .Error) ? .Error : .Warning;
			o.Origin = origin;
			if (!d.Code.IsEmpty)
				o.Text.AppendF("{}: ", d.Code);
			o.Text.Append(d.Message);
			o.Path.Set(d.File);
			o.Line = d.Line;
			o.MethodKey.Set(d.Sheet);
			o.NodeKey.Set(d.Node);
			o.PinName.Set(d.Pin);
			o.Where.Set(d.Type);
			if (!d.Sheet.IsEmpty)
				o.Where.AppendF(" {}", d.Sheet);
			return o;
		}
	}
}
