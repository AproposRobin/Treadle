using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Format
{
	/// The canonical form of the record files (Graph-Format.md 3.1 and 7, C-Import.md): what the
	/// codec writes for a type file (`.treadle`, `.cdecl`), a project file (`.tproj`) and a C import
	/// set (`.cimport`). `--format` rewrites files in it; the `codec` self test checks the samples
	/// and the core library are in it.
	static class Canonical
	{
		/// A file the codec writes: a type file, a C declarations file, a project file or a C import set
		/// (old extensions included: FormatNames).
		public static bool Handles(StringView path)
		{
			return FormatNames.IsTypeFile(path) || path.EndsWith(".cdecl") || FormatNames.IsProjectFile(path) || path.EndsWith(".cimport");
		}

		/// The canonical text of `text` (the contents of the file `path`, which names its kind). False
		/// with `outError` when it does not read (the file is then left alone).
		public static bool Normalize(StringView path, StringView text, String outText, String outError)
		{
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			bool ok;
			if (FormatNames.IsProjectFile(path))
			{
				ProjectFile p = scope .();
				ok = ProjectCodec.ReadProject(text, p, errors);
				if (ok)
					ProjectCodec.WriteProject(p, outText);
			}
			else if (path.EndsWith(".cimport"))
			{
				CImportFile f = scope .();
				ok = ProjectCodec.ReadCImport(text, f, errors);
				if (ok)
					ProjectCodec.WriteCImport(f, outText);
			}
			else
			{
				TypeDocument doc = scope .();
				ok = TreadleCodec.ReadAll(text, doc, errors);
				if (ok)
					TypeFileWriter.Write(doc, outText);
			}
			if (!ok)
			{
				TreadleCodec.JoinErrors(errors, outError);
				if (outError.IsEmpty)
					outError.Append("does not read");
			}
			return ok;
		}

		/// The frozen format corpus (`TreadleCore/samples/format-history/v<N>/`): never re-saved, so
		/// a folder walk skips it (name the folder or a file in it to format it anyway).
		public const String HistoryFolder = "format-history";

		/// The files `--format` takes from `path`: the file itself, or every file the codec writes
		/// under the folder, layout sidecars too with `layouts` (sorted; folders whose names start
		/// with '.', `build` folders and `format-history` are skipped).
		public static void Collect(StringView path, List<String> outFiles, bool layouts = false)
		{
			if (File.Exists(path))
			{
				outFiles.Add(new String(path));
				return;
			}
			if (!Directory.Exists(path))
				return;
			List<String> found = scope .();
			Walk(path, found, layouts);
			found.Sort(scope (a, b) => a.CompareTo(b));
			for (let f in found)
				outFiles.Add(f);
		}

		static void Walk(StringView dir, List<String> outFiles, bool layouts)
		{
			for (let e in Directory.Enumerate(dir))
			{
				String name = scope .();
				e.GetFileName(name);
				String full = scope .();
				e.GetFilePath(full);
				if (e.IsDirectory)
				{
					if (!name.StartsWith('.') && name != "build" && name != HistoryFolder)
						Walk(full, outFiles, layouts);
				}
				else if (Handles(name) || (layouts && FormatNames.IsLayoutFile(name)))
				{
					full.Replace('\\', '/');
					outFiles.Add(new String(full));
				}
			}
		}

		/// What `--format` did with one file.
		public enum FormatResult
		{
			/// Canonical and current: not written.
			Same,
			/// Not canonical: rewritten (or, with `check`, would be).
			Changed,
			/// Below the current version and not migrated (no `--migrate`, or `check`).
			Old,
			/// Migrated to the current version and written, with `<file>.v<old>.bak` beside it.
			Migrated,
			/// Newer than this build: refused, nothing written.
			Newer,
			/// Cannot be read, does not parse or cannot be written (`outError`).
			Failed
		}

		/// Formats one file (docs/Format-Stability.md 3.3). A file below the current version is
		/// migrated only with `migrate` (and not `check`), keeping its old text once as
		/// `<file>.v<old>.bak`; a layout sidecar is only migrated (its canonical form needs its type
		/// file). Nothing is written with `check`. `outError` says why for Old, Newer and Failed.
		public static FormatResult FormatFile(StringView path, bool check, bool migrate, String outError)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
			{
				outError.Set("cannot be read");
				return .Failed;
			}
			let kind = Migrations.KindOf(path);
			let version = Migrations.VersionOf(kind, text);
			let current = TreadleCodec.Current;
			if (version > current)
			{
				Migrations.NewerMessage(version, outError);
				return .Newer;
			}
			let old = version > 0 && version < current;
			if (old && (check || !migrate))
			{
				outError.Set(scope $"format version {version}, this build writes {current} (--format --migrate updates it)");
				return .Old;
			}
			String canon = scope .();
			if (kind == FormatNames.LayoutWord)
			{
				if (old)
					Migrations.Run(kind, text, version, canon);
				else
					FormatNames.RewriteHeaderWord(text, kind, canon); // an old header word becomes the current one
			}
			else if (!Normalize(path, text, canon, outError))
				return .Failed;
			if (migrate && kind == FormatNames.ProjectWord)
				MigrateProjectPaths(canon);
			if (canon == text)
				return .Same;
			if (check)
				return .Changed;
			if (old && !Migrations.BackupOnce(path, version))
			{
				outError.Set(scope $"the backup of {path} (.v{version}.bak) cannot be written");
				return .Failed;
			}
			if (File.WriteAllText(path, canon) case .Err)
			{
				outError.Set("cannot be written");
				return .Failed;
			}
			return old ? .Migrated : .Changed;
		}

		/// What `--format --migrate` does with a file name (FormatNames).
		public enum RenameResult
		{
			/// Not an old extension: nothing to do.
			None,
			/// Renamed to the new extension.
			Renamed,
			/// Would be renamed (`check`).
			WouldRename,
			/// The new name is taken or the rename failed (`outError`).
			Failed
		}

		/// Renames an old-extension file to its new name (FormatNames.Extensions: `Player.vtype` -> `Player.treadle`,
		/// `Player.vtype.layout` -> `Player.treadle.layout`, `.vproject` -> `.tproj`, `.kir` -> `.tir`);
		/// with `check` it only says so. `outPath` is the name the file has afterwards (or would have).
		/// A plain rename: in a git work tree, `git add -A` records it as a rename. Fails when a file
		/// with the new name exists (both are kept; the project reports the pair).
		public static RenameResult RenameOldExtension(StringView path, bool check, String outPath, String outError)
		{
			outPath.Set(path);
			String target = scope .();
			if (!FormatNames.NewNameOf(path, target))
				return .None;
			if (File.Exists(target))
			{
				outError.Set(scope $"both {path} and {target} exist; keep one");
				return .Failed;
			}
			if (check)
			{
				outPath.Set(target);
				return .WouldRename;
			}
			if (File.Move(path, target) case .Err)
			{
				outError.Set(scope $"cannot be renamed to {target}");
				return .Failed;
			}
			outPath.Set(target);
			return .Renamed;
		}

		/// A project file's `depends` lines that name an old-extension project file get the new
		/// extension (the same migration renames that file; the loader also finds either name).
		public static bool MigrateProjectPaths(String text)
		{
			String outText = scope .();
			bool any = false;
			bool first = true;
			for (let line in text.Split('\n'))
			{
				if (!first)
					outText.Append('\n');
				first = false;
				let quoted = line.EndsWith('"');
				let bare = quoted ? line.Substring(0, line.Length - 1) : line;
				String fixedName = scope .();
				if (line.StartsWith("depends ") && bare.EndsWith(FormatNames.OldProjectExt, .OrdinalIgnoreCase) && FormatNames.NewNameOf(bare, fixedName))
				{
					outText.Append(fixedName);
					if (quoted)
						outText.Append('"');
					any = true;
				}
				else
					outText.Append(line);
			}
			if (any)
				text.Set(outText);
			return any;
		}
	}
}
