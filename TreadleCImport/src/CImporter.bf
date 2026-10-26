using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Format;
using Treadle.Model;

namespace Treadle.CImport
{
	/// One set's outcome in a CImportReport.
	class CImportSetReport
	{
		public String Name = new .() ~ delete _;
		/// The `.cdecl` written (or that would have been).
		public String OutPath = new .() ~ delete _;
		public CDeclSet Decls ~ delete _;
		public bool Ok;
		/// The file already held these bytes, so it was left alone.
		public bool Unchanged;
		public double Ms;
	}

	class CImportReport
	{
		public List<CImportSetReport> Sets = new .() ~ DeleteContainerAndItems!(_);
		/// Set when nothing could run (no libclang, unreadable file).
		public String Error = new .() ~ delete _;
		public double TotalMs;

		public bool Ok
		{
			get
			{
				if (!Error.IsEmpty)
					return false;
				for (let s in Sets)
					if (!s.Ok)
						return false;
				return true;
			}
		}

		/// The command line's summary: per set the counts, timing, output file, then errors and
		/// warnings (each with its header and line).
		public void Summary(String outText, int maxWarnings = int.MaxValue)
		{
			if (!Error.IsEmpty)
			{
				outText.AppendF("C import failed: {}\n", Error);
				return;
			}
			outText.AppendF("libclang: {} ({})\n", LibClang.Version, LibClang.Path);
			for (let s in Sets)
			{
				if (s.Decls == null)
					continue;
				let d = s.Decls;
				outText.AppendF("set {}: ", s.Name);
				if (s.Ok)
				{
					d.Counts(outText);
					outText.AppendF("; parse {0:0.0} ms, walk {1:0.0} ms, total {2:0.0} ms\n", d.ParseMs, d.WalkMs, s.Ms);
					outText.AppendF("  -> {}{}\n", s.OutPath, s.Unchanged ? " (unchanged)" : "");
				}
				else
					outText.Append("FAILED\n");
				for (let e in d.Errors)
					outText.AppendF("  error: {}\n", e);
				for (let w in d.Warnings)
				{
					if (@w.Index >= maxWarnings)
					{
						outText.AppendF("  ... and {} more warnings\n", d.Warnings.Count - maxWarnings);
						break;
					}
					outText.AppendF("  warning: {}\n", w);
				}
			}
		}
	}

	/// The C header import (docs/C-Import.md): `.cimport` set -> libclang -> `.cdecl`.
	static class CImporter
	{
		/// `<project root>\build\cimport` for a `.cimport` file: the project root is the nearest
		/// folder at or above the file that holds a `.tproj`, else the file's own folder.
		public static void DefaultOutDir(StringView cimportPath, String outDir)
		{
			String dir = scope .();
			Path.GetDirectoryPath(cimportPath, dir).IgnoreError();
			if (dir.IsEmpty)
				dir.Set(".");
			String probe = scope .(dir);
			for (int i < 6)
			{
				bool hasProject = false;
				if (Directory.Exists(probe))
					for (let e in Directory.EnumerateFiles(probe))
						if (Treadle.Format.FormatNames.IsProjectFile(e.GetFilePath(.. scope String())))
							hasProject = true;
				if (hasProject)
				{
					dir.Set(probe);
					break;
				}
				String parent = scope .();
				if (Path.GetDirectoryPath(probe, parent) case .Err || parent.IsEmpty || parent == probe)
					break;
				probe.Set(parent);
			}
			outDir.AppendF("{0}{1}build{1}cimport", dir, Path.DirectorySeparatorChar);
		}

		/// Imports one set; `baseDir` resolves relative `header` / `include` paths. Fills `outDecls`
		/// (warnings and errors included). False when libclang is missing or the parse fails.
		public static bool ImportSet(CImportSet set, StringView baseDir, StringView sourceFile, CDeclSet outDecls)
		{
			outDecls.Name.Set(set.Name);
			outDecls.SourceFile.Set(sourceFile);
			// a platform variant names its base file: both write the same .cdecl
			for (let suffix in StringView[?](".linux.cimport", ".windows.cimport"))
				if (outDecls.SourceFile.EndsWith(suffix, .OrdinalIgnoreCase))
				{
					outDecls.SourceFile.RemoveFromEnd(suffix.Length);
					outDecls.SourceFile.Append(".cimport");
				}
			if (!LibClang.Load())
			{
				outDecls.Errors.Add(new String(LibClang.Error));
				return false;
			}
			SetImporter imp = scope .(set, baseDir, outDecls);
			let ok = imp.Run();
			imp.Dispose();
			return ok;
		}

		/// The set file has a platform variant: it is one (`<name>.linux.cimport`,
		/// `<name>.windows.cimport`), or one is next to it.
		public static bool HasPlatformVariant(StringView cimportPath)
		{
			if (!cimportPath.EndsWith(".cimport", .OrdinalIgnoreCase))
				return false;
			if (cimportPath.EndsWith(CImportFile.PlatformSuffix, .OrdinalIgnoreCase) || cimportPath.EndsWith(CImportFile.OtherSuffix, .OrdinalIgnoreCase))
				return true;
			let stem = cimportPath.Substring(0, cimportPath.Length - ".cimport".Length);
			return File.Exists(scope $"{stem}{CImportFile.PlatformSuffix}") || File.Exists(scope $"{stem}{CImportFile.OtherSuffix}");
		}

		/// A set name is written into a file name (`<set>.cdecl` in the output folder): false for an
		/// empty name, one with a folder separator, a drive colon, `..` or a control character.
		public static bool IsSafeSetName(StringView name)
		{
			if (name.IsEmpty || name.Contains(".."))
				return false;
			for (let c in name.RawChars)
				if (c == '/' || c == '\\' || c == ':' || (uint8)c < 0x20)
					return false;
			return true;
		}

		/// The file an import of `setName` from `cimportPath` writes: `<set>.windows.cdecl` on Windows
		/// and `<set>.linux.cdecl` on Linux when the set file has a platform variant, else
		/// `<set>.cdecl` (the front end reads them in that order, Compilation.AddCImport).
		public static void CDeclFileName(StringView cimportPath, StringView setName, String outName)
		{
			outName.Append(setName);
			outName.Append(HasPlatformVariant(cimportPath) ? CImportFile.PlatformCDeclSuffix : ".cdecl");
		}

		/// Imports every set of a `.cimport` file (this platform's variant of it, CImportFile.ForPlatform)
		/// into `<outDir>\<set>.cdecl`, or `<set>.windows.cdecl` / `<set>.linux.cdecl` when the file has
		/// a platform variant (CDeclFileName; outDir "" = DefaultOutDir). A file whose bytes would not
		/// change is not rewritten; nor is a platform file when `<set>.cdecl` in outDir already has the
		/// same bytes (both platforms share it).
		public static bool ImportFile(StringView cimportPath, StringView outDir, CImportReport report)
		{
			let total = scope Stopwatch(true);
			defer { report.TotalMs = total.Elapsed.TotalMilliseconds; }
			String full = scope .();
			Path.GetFullPath(cimportPath, full);
			CImportFile.ForPlatform(scope String(full), full);
			String text = scope .();
			if (File.ReadAllText(full, text, true) case .Err)
			{
				report.Error.AppendF("cannot read {}", full);
				return false;
			}
			CImportFile f = scope .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (!ProjectCodec.ReadCImport(text, f, errors))
			{
				String why = scope .();
				TreadleCodec.JoinErrors(errors, why);
				report.Error.AppendF("{}: {}", full, why);
				return false;
			}
			if (!LibClang.Load())
			{
				report.Error.Set(LibClang.Error);
				return false;
			}
			String baseDir = scope .();
			Path.GetDirectoryPath(full, baseDir).IgnoreError();
			String fileName = scope .();
			Path.GetFileName(full, fileName);
			String dest = scope .();
			if (outDir.IsEmpty)
				DefaultOutDir(full, dest);
			else
				Path.GetFullPath(outDir, dest);
			bool all = true;
			for (let set in f.Sets)
			{
				let sw = scope Stopwatch(true);
				CImportSetReport sr = new .();
				report.Sets.Add(sr);
				sr.Name.Set(set.Name);
				sr.Decls = new .();
				if (!IsSafeSetName(set.Name))
				{
					// the name becomes a file name in the output folder: no folder part, no `..`
					sr.Decls.Errors.Add(new $"the set name '{set.Name}' is not a plain name (no '/', '\\', ':', '..' or control characters)");
					all = false;
					continue;
				}
				String outName = scope .();
				CDeclFileName(full, set.Name, outName);
				sr.OutPath.AppendF("{}{}{}", dest, Path.DirectorySeparatorChar, outName);
				sr.Ok = ImportSet(set, baseDir, fileName, sr.Decls);
				if (sr.Ok)
				{
					String outText = scope .();
					CDeclWriter.Write(sr.Decls, outText);
					String old = scope .();
					String shared = scope $"{dest}{Path.DirectorySeparatorChar}{set.Name}.cdecl";
					if (File.ReadAllText(sr.OutPath, old, true) case .Ok && old == outText)
						sr.Unchanged = true;
					else if (shared != sr.OutPath && !File.Exists(sr.OutPath) && File.ReadAllText(shared, old..Clear(), true) case .Ok && old == outText)
					{
						// the shared file already says this (the headers agree on both platforms)
						sr.OutPath.Set(shared);
						sr.Unchanged = true;
					}
					else
					{
						Directory.CreateDirectory(dest).IgnoreError();
						if (File.WriteAllText(sr.OutPath, outText) case .Err)
						{
							sr.Decls.Errors.Add(new $"cannot write {sr.OutPath}");
							sr.Ok = false;
						}
					}
				}
				sr.Ms = sw.Elapsed.TotalMilliseconds;
				all &= sr.Ok;
			}
			return all;
		}
	}
}
