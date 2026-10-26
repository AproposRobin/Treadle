using System;
using System.Collections;
using System.IO;

namespace Treadle.Document
{
	/// One graph file of the project.
	class IndexedFile
	{
		public String Path = new .() ~ delete _;
		/// The file name without its extension: what the Project Browser shows as the tile.
		public String Name = new .() ~ delete _;
		public DateTime Modified;
	}

	/// The project's files: every graph document under the open folder (build output, `recovery`
	/// and dot-folders are skipped). `Version` bumps on every change, so panels refresh their
	/// caches.
	///
	/// Seam: this replaces the symbol index of the language that was forked (types, members,
	/// namespaces read from source text). A language that wants the Project Browser and Find in
	/// Sheets to know what a document declares extends this index or installs its own next to it.
	class ProjectIndex
	{
		public String Root = new .() ~ delete _;
		public List<IndexedFile> Files = new .() ~ DeleteContainerAndItems!(_);
		public int32 Version;
		/// The extension of the files indexed (with the dot), from the graph codec.
		public String Extension = new .() ~ delete _;

		public const int MaxDepth = 12;
		public const int MaxFiles = 5000;

		public void Clear()
		{
			Root.Clear();
			ClearAndDeleteItems!(Files);
			Version++;
		}

		/// Reads the folder tree again.
		public void Build(StringView root, StringView ext)
		{
			Root.Set(root);
			Extension.Set(ext);
			ClearAndDeleteItems!(Files);
			Scan(root, 0);
			Version++;
		}

		/// Same as Build on the current root.
		public void Update()
		{
			if (Root.IsEmpty)
				return;
			Build(scope String(Root), scope String(Extension));
		}

		/// A file of the indexed kind: for type files the old extension too (FormatNames).
		bool Takes(StringView path)
		{
			if (Extension == Treadle.Format.FormatNames.TypeExt)
				return Treadle.Format.FormatNames.IsTypeFile(path);
			return path.EndsWith(Extension, .OrdinalIgnoreCase);
		}

		void Scan(StringView dir, int depth)
		{
			if (depth > MaxDepth || Files.Count >= MaxFiles)
				return;
			for (let e in Directory.EnumerateFiles(dir))
			{
				if (Files.Count >= MaxFiles)
					return;
				String path = scope .();
				e.GetFilePath(path);
				if (!Extension.IsEmpty && !Takes(path))
					continue;
				IndexedFile f = new .();
				f.Path.Set(path);
				Path.GetFileNameWithoutExtension(path, f.Name);
				f.Modified = e.GetLastWriteTime();
				Files.Add(f);
			}
			for (let e in Directory.EnumerateDirectories(dir))
			{
				String name = scope .();
				e.GetFileName(name);
				if (name.StartsWith('.') || name == "build" || name == "recovery" || name == "dist" || name == "format-history")
					continue;
				String path = scope .();
				e.GetFilePath(path);
				Scan(path, depth + 1);
			}
		}

		public IndexedFile FindFile(StringView path)
		{
			for (let f in Files)
				if (SamePath(f.Path, path))
					return f;
			return null;
		}

		/// Paths compared as the file system does on this platform (case-insensitive and
		/// separator-insensitive on Windows).
		public static bool SamePath(StringView a, StringView b)
		{
			if (a.Length != b.Length)
				return false;
			for (int i < a.Length)
			{
				var ca = a[i];
				var cb = b[i];
				if (ca == '\\') ca = '/';
				if (cb == '\\') cb = '/';
#if BF_PLATFORM_WINDOWS
				ca = ca.ToLower;
				cb = cb.ToLower;
#endif
				if (ca != cb)
					return false;
			}
			return true;
		}
	}
}
