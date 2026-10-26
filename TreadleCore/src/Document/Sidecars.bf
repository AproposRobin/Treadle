using System;
using System.IO;
using System.Collections;
using Treadle.Format;
using Treadle.Model;

namespace Treadle.Document
{
	/// Where the layout files and the backups of a project live (Graph-Format.md 4 and 5): under the
	/// project folder, `layout/<relative path of the source without its extension>.layout` and
	/// `backup/<relative path of the file>.bak`, so the sources stay clean and a graph can be run
	/// without its layout. The folder names are the project keys `layoutDir` and `backupDir`.
	/// A file with no project file above it keeps its sidecars beside it (`X.treadle.layout`,
	/// `X.treadle.bak`).
	class SidecarInfo
	{
		/// The project folder (forward slashes, no trailing slash).
		public String Root = new .() ~ delete _;
		/// The folder the layout files live in, and the one the backups live in (full paths).
		public String LayoutDir = new .() ~ delete _;
		public String BackupDir = new .() ~ delete _;

		static bool SamePrefix(StringView a, StringView b)
		{
#if BF_PLATFORM_WINDOWS
			return a.Equals(b, true);
#else
			return a == b;
#endif
		}

		/// `full` relative to the project folder (forward slashes); just the file name when it lies outside.
		public void RelOf(StringView full, String outRel)
		{
			String f = scope .(full);
			f.Replace('\\', '/');
			if (f.Length > Root.Length + 1 && f[Root.Length] == '/' && SamePrefix(f.Substring(0, Root.Length), Root))
				outRel.Append(f.Substring(Root.Length + 1));
			else
				Path.GetFileName(f, outRel);
		}

		/// `<layoutDir>/<relative path without extension>.layout` for the type file `source`.
		public void LayoutOf(StringView source, String outPath)
		{
			String rel = scope .();
			RelOf(source, rel);
			Sidecars.StripExtension(rel);
			outPath.AppendF("{}/{}.layout", LayoutDir, rel);
		}

		/// `<backupDir>/<relative path of the file><suffix>.bak`; the suffix is `` or `.v<old>`.
		public void BackupOf(StringView file, StringView suffix, String outPath)
		{
			String rel = scope .();
			RelOf(file, rel);
			outPath.AppendF("{}/{}{}.bak", BackupDir, rel, suffix);
		}

		public bool IsSidecarFolder(StringView dir)
		{
			String d = scope .(dir);
			d.Replace('\\', '/');
			return SamePrefix(d, LayoutDir) || SamePrefix(d, BackupDir);
		}
	}

	static class Sidecars
	{
		public const String DefaultLayoutDir = "layout";
		public const String DefaultBackupDir = "backup";

		// The last project file read (most saves and loads are in one project).
		static String sProjPath = new .() ~ delete _;
		static DateTime sProjTime;
		static String sProjLayout = new .() ~ delete _;
		static String sProjBackup = new .() ~ delete _;
		// Projects whose beside-the-source sidecars were already moved in this run.
		static HashSet<String> sMigrated = new .() ~ DeleteContainerAndItems!(_);
		static List<String> sMessages = new .() ~ DeleteContainerAndItems!(_);

		/// Drops what the cache and the migrated-once list remember (self tests reuse folders).
		public static void Forget()
		{
			sProjPath.Clear();
			ClearAndDeleteItems!(sMigrated);
			sMigrated.Clear();
		}

		/// Moves the messages the project migrations left (one line per project) to `into`.
		public static void TakeMessages(List<String> into)
		{
			for (let m in sMessages)
				into.Add(m);
			sMessages.Clear();
		}

		/// Removes the last `.ext` of a path's file name.
		public static void StripExtension(String path)
		{
			let slash = path.LastIndexOf('/');
			let dot = path.LastIndexOf('.');
			if (dot > slash + 0 && dot > 0)
				path.RemoveToEnd(dot);
		}

		static void FolderOf(StringView root, StringView setting, StringView fallback, String outDir)
		{
			String s = scope .(setting.IsEmpty ? fallback : setting);
			s.Replace('\\', '/');
			while (s.Length > 1 && s.EndsWith('/'))
				s.RemoveFromEnd(1);
			if (Path.IsPathRooted(s))
				outDir.Append(s);
			else
				outDir.AppendF("{}/{}", root, s);
		}

		static bool FindProjectFile(StringView dir, String outProj)
		{
			for (let pattern in FormatNames.ProjectPatterns)
			{
				for (let e in Directory.EnumerateFiles(dir, pattern))
				{
					e.GetFilePath(outProj);
					return true;
				}
			}
			return false;
		}

		/// Finds the project the file `source` belongs to (the nearest project file in its folder or
		/// above) and fills `info` with the project folder and the layout and backup folders. False
		/// when no project file is above the file: its sidecars then stay beside it. The first time a
		/// project is seen its old beside-the-source sidecars are moved (Migrate).
		public static bool Find(StringView source, SidecarInfo info)
		{
			String full = scope .();
			Path.GetFullPath(source, full);
			if (full.IsEmpty)
				return false;
			full.Replace('\\', '/');
			// The frozen format corpus keeps its layouts beside the files (never re-saved, never migrated).
			if (full.Contains(scope $"/{Canonical.HistoryFolder}/"))
				return false;
			String dir = scope .();
			Path.GetDirectoryPath(full, dir).IgnoreError();
			while (!dir.IsEmpty)
			{
				String proj = scope .();
				if (FindProjectFile(dir, proj))
				{
					proj.Replace('\\', '/');
					ReadKeys(proj);
					info.Root.Set(dir);
					while (info.Root.Length > 1 && info.Root.EndsWith('/'))
						info.Root.RemoveFromEnd(1);
					FolderOf(info.Root, sProjLayout, DefaultLayoutDir, info.LayoutDir);
					FolderOf(info.Root, sProjBackup, DefaultBackupDir, info.BackupDir);
					MigrateOnce(info);
					return true;
				}
				String parent = scope .();
				Path.GetDirectoryPath(dir, parent).IgnoreError();
				if (parent.IsEmpty || parent == dir)
					break;
				dir.Set(parent);
			}
			return false;
		}

		static void ReadKeys(StringView proj)
		{
			DateTime time = default;
			if (File.GetLastWriteTime(proj) case .Ok(let t))
				time = t;
			if (sProjPath == proj && sProjTime == time)
				return;
			sProjPath.Set(proj);
			sProjTime = time;
			sProjLayout.Clear();
			sProjBackup.Clear();
			String text = scope .();
			if (File.ReadAllText(proj, text, true) case .Err)
				return;
			ProjectFile pf = scope .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			ProjectCodec.ReadProject(text, pf, errors);
			sProjLayout.Set(pf.LayoutDir);
			sProjBackup.Set(pf.BackupDir);
		}

		/// The layout file of the type file `source`: `layout/<relative path>.layout` in its project,
		/// `<source>.layout` beside it when there is no project.
		public static void LayoutPathOf(StringView source, String outPath)
		{
			SidecarInfo info = scope .();
			if (Find(source, info))
				info.LayoutOf(source, outPath);
			else
				outPath.AppendF("{}.layout", source);
		}

		/// The backup of `file` (a source, a layout file or a project file): `backup/<relative path>.bak`
		/// in its project, `<file>.bak` beside it when there is no project. `oldVersion` > 0 names the
		/// once-only backup of a format migration (`.v<old>.bak`).
		public static void BackupPathOf(StringView file, int32 oldVersion, String outPath)
		{
			String suffix = scope .();
			if (oldVersion > 0)
				suffix.AppendF(".v{}", oldVersion);
			SidecarInfo info = scope .();
			if (Find(file, info))
				info.BackupOf(file, suffix, outPath);
			else
				outPath.AppendF("{}{}.bak", file, suffix);
		}

		/// The ordinary backup of `file` (no version).
		public static void BackupPathOf(StringView file, String outPath) => BackupPathOf(file, 0, outPath);

		static bool IsFormatName(StringView name)
		{
			for (let ext in StringView[?](".treadle", ".vtype", ".tproj", ".vproject", ".cimport", ".cdecl", ".layout"))
				if (name.EndsWith(ext, .OrdinalIgnoreCase))
					return true;
			return false;
		}

		static void MigrateOnce(SidecarInfo info)
		{
			if (FileSafety.ReadOnlyProject)
				return;
			String key = scope .(info.Root);
#if BF_PLATFORM_WINDOWS
			key.ToLower();
#endif
			if (sMigrated.Contains(key))
				return;
			sMigrated.Add(new String(key));
			int layouts = 0, backups = 0;
			List<String> notes = scope .();
			defer { ClearAndDeleteItems!(notes); }
			Migrate(info, ref layouts, ref backups, notes);
			if (layouts + backups > 0 || !notes.IsEmpty)
			{
				String ld = scope .(), bd = scope .();
				Path.GetFileName(info.LayoutDir, ld);
				Path.GetFileName(info.BackupDir, bd);
				sMessages.Add(new String(scope $"{info.Root}: moved {layouts} layout files and {backups} backups to {ld}/ and {bd}/"));
				for (let n in notes)
					sMessages.Add(new String(n));
			}
		}

		/// Moves the layout files and backups found beside the sources of the project (any depth) into
		/// the layout and backup folders: counts in `layouts` and `backups`, one line per conflict
		/// (the newer file is kept) in `notes`. Used on project load and by `--format --migrate`.
		public static void Migrate(SidecarInfo info, ref int layouts, ref int backups, List<String> notes)
		{
			Walk(info, info.Root, true, ref layouts, ref backups, notes);
		}

		static void Walk(SidecarInfo info, StringView dir, bool top, ref int layouts, ref int backups, List<String> notes)
		{
			List<String> files = scope .();
			List<String> dirs = scope .();
			defer { ClearAndDeleteItems!(files); ClearAndDeleteItems!(dirs); }
			for (let e in Directory.Enumerate(dir))
			{
				String full = e.GetFilePath(.. new String());
				full.Replace('\\', '/');
				if (e.IsDirectory)
					dirs.Add(full);
				else
					files.Add(full);
			}
			for (let f in files)
			{
				let name = Path.GetFileName(f, .. scope String());
				String dest = scope .();
				if (name.EndsWith(".treadle.layout", .OrdinalIgnoreCase) || name.EndsWith(".vtype.layout", .OrdinalIgnoreCase))
				{
					String source = scope .(f);
					source.RemoveFromEnd(".layout".Length);
					info.LayoutOf(source, dest);
					if (MoveKeepingNewer(f, dest, notes))
						layouts++;
				}
				else if (name.EndsWith(".bak", .OrdinalIgnoreCase))
				{
					String logical = scope .(f);
					logical.RemoveFromEnd(4);
					String suffix = scope .();
					// `<file>.v<old>` names a migration backup.
					let vdot = logical.LastIndexOf('.');
					if (vdot > 0 && vdot + 2 < logical.Length && logical[vdot + 1] == 'v')
					{
						bool digits = true;
						for (int i = vdot + 2; i < logical.Length; i++)
							if (!logical[i].IsDigit)
								digits = false;
						if (digits)
						{
							suffix.Set(logical.Substring(vdot));
							logical.RemoveToEnd(vdot);
						}
					}
					if (!IsFormatName(logical))
						continue;
					if (logical.EndsWith(".treadle.layout", .OrdinalIgnoreCase) || logical.EndsWith(".vtype.layout", .OrdinalIgnoreCase))
					{
						String source = scope .(logical);
						source.RemoveFromEnd(".layout".Length);
						String newLayout = scope .();
						info.LayoutOf(source, newLayout);
						info.BackupOf(newLayout, suffix, dest);
					}
					else
						info.BackupOf(logical, suffix, dest);
					if (MoveKeepingNewer(f, dest, notes))
						backups++;
				}
			}
			for (let d in dirs)
			{
				let name = Path.GetFileName(d, .. scope String());
				if (name.StartsWith('.') || name == "build" || name == Canonical.HistoryFolder || info.IsSidecarFolder(d))
					continue;
				String nested = scope .();
				if (FindProjectFile(d, nested)) // another project: its own sidecar folders
					continue;
				Walk(info, d, false, ref layouts, ref backups, notes);
			}
		}

		/// `--format --migrate` for a project folder or a file in one: moves the beside-the-source
		/// layout files and backups into the layout and backup folders (the run on first sight of the
		/// project did it already when it was not done before in this process). Lines for the report
		/// go to `outLines`; false when there is no project above `path`.
		public static bool MigrateAt(StringView path, List<String> outLines)
		{
			SidecarInfo info = scope .();
			String probe = scope .(path);
			if (Directory.Exists(path))
				probe.Append("/.probe");
			if (!Find(probe, info))
				return false;
			int layouts = 0, backups = 0;
			List<String> notes = scope .();
			defer { ClearAndDeleteItems!(notes); }
			if (!FileSafety.ReadOnlyProject)
				Migrate(info, ref layouts, ref backups, notes);
			TakeMessages(outLines);
			if (layouts + backups > 0)
			{
				String ld = scope .(), bd = scope .();
				Path.GetFileName(info.LayoutDir, ld);
				Path.GetFileName(info.BackupDir, bd);
				outLines.Add(new String(scope $"{info.Root}: moved {layouts} layout files and {backups} backups to {ld}/ and {bd}/"));
			}
			for (let n in notes)
				outLines.Add(new String(n));
			return true;
		}

		static bool MoveKeepingNewer(StringView src, StringView dest, List<String> notes)
		{
			String destDir = scope .();
			Path.GetDirectoryPath(dest, destDir).IgnoreError();
			Directory.CreateDirectory(destDir).IgnoreError();
			if (File.Exists(dest))
			{
				DateTime a = default, b = default;
				if (File.GetLastWriteTime(src) case .Ok(let t))
					a = t;
				if (File.GetLastWriteTime(dest) case .Ok(let t2))
					b = t2;
				if (a > b)
				{
					File.Delete(dest).IgnoreError();
					notes.Add(new String(scope $"{dest}: kept the newer file from {src}"));
				}
				else
				{
					File.Delete(src).IgnoreError();
					notes.Add(new String(scope $"{dest}: kept the newer file, dropped {src}"));
					return false;
				}
			}
			return File.Move(src, dest) case .Ok;
		}
	}
}
