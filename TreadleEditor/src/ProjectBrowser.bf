using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using ImGui;
using Treadle.Document;

namespace Treadle.Editor
{
	/// What a Project Browser tile stands for: a folder or a graph document (a file of the
	/// program). A language that wants richer tiles (one per declared type) extends this.
	enum AssetKind
	{
		Folder,
		Document,
		/// The project file (`.tproj`): the root folder's first tile, with the active config.
		Project
	}

	/// One tile of the asset grid. Built fresh each frame from the folder tree; every string is a
	/// copy, so the tree can be rebuilt while these are alive.
	class CBItem
	{
		public AssetKind Kind;
		public String Name = new .() ~ delete _;
		/// Folder path or document path.
		public String Path = new .() ~ delete _;
		/// Selection key: "D|path" (folder) or "F|path" (document).
		public String Key = new .() ~ delete _;
		public bool Modified;

		public CBItem Clone()
		{
			CBItem c = new .();
			c.Kind = Kind;
			c.Name.Set(Name);
			c.Path.Set(Path);
			c.Key.Set(Key);
			c.Modified = Modified;
			return c;
		}

		/// `name` is not part of the key (kept so callers that know a name need not drop it).
		public static void MakeKey(AssetKind kind, StringView path, StringView name, String outKey)
		{
			outKey.Clear();
			switch (kind)
			{
			case .Folder: outKey.AppendF("D|{}", path);
			case .Document: outKey.AppendF("F|{}", path);
			case .Project: outKey.AppendF("P|{}", path);
			}
		}
	}

	/// A folder of the project on disk (build output, recovery and dot folders skipped).
	class CBDir
	{
		public String Name = new .() ~ delete _;
		public String Path = new .() ~ delete _;
		public CBDir Parent;
		public List<CBDir> Dirs = new .() ~ DeleteContainerAndItems!(_);
		/// Graph documents directly in this folder.
		public List<String> Files = new .() ~ DeleteContainerAndItems!(_);

		public int CountFilesRecursive()
		{
			int n = Files.Count;
			for (let d in Dirs)
				n += d.CountFilesRecursive();
			return n;
		}
	}

	/// Colours, labels and draw-list icons of the asset kinds.
	static class AssetStyle
	{
		public static uint32 KindColor(AssetKind k)
		{
			switch (k)
			{
			case .Document: return Gui.Color(45, 115, 225);
			case .Folder: return Gui.Color(196, 166, 108);
			case .Project: return Gui.Color(232, 142, 44);
			}
		}

		public static StringView KindLabel(AssetKind k)
		{
			switch (k)
			{
			case .Document: return "Type";
			case .Folder: return "Folder";
			case .Project: return "Project";
			}
		}

		public static void Text(ImDrawList* dl, StringView text, ImVec2 pos, float size, uint32 col)
		{
			Gui.ImDrawList_AddText_FontPtr(dl, Gui.igGetFont(), size, pos, col, text.Ptr, text.Ptr + text.Length, 0, null);
		}

		public static ImVec2 TextSize(StringView text, float size)
		{
			let s = Gui.CalcTextSize(text);
			let f = size / Math.Max(1.0f, Gui.igGetFontSize());
			return .(s.x * f, s.y * f);
		}

		/// Draws the kind's glyph centred on `c`, about `s` pixels across.
		public static void DrawIcon(ImDrawList* dl, AssetKind kind, ImVec2 c, float s, uint32 col)
		{
			float u = s / 100.0f;
			uint32 dark = Gui.Color(14, 14, 14, 240);
			switch (kind)
			{
			case .Document:
				// A little node: coloured header, flow and value pins.
				ImVec2 a = .(c.x - 40 * u, c.y - 30 * u);
				ImVec2 b = .(c.x + 40 * u, c.y + 32 * u);
				Gui.ImDrawList_AddRectFilled(dl, a, b, dark, 7 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, a, .(b.x, a.y + 18 * u), col, 7 * u, DrawFlags.RoundCornersTop);
				Gui.ImDrawList_AddRect(dl, a, b, Gui.Color(0, 0, 0, 255), 7 * u, 1.5f * u, 0);
				float ey = c.y + 2 * u;
				Gui.ImDrawList_AddTriangleFilled(dl, .(c.x - 32 * u, ey - 6 * u), .(c.x - 32 * u, ey + 6 * u), .(c.x - 22 * u, ey), Gui.Color(235, 235, 235));
				Gui.ImDrawList_AddTriangleFilled(dl, .(c.x + 22 * u, ey - 6 * u), .(c.x + 22 * u, ey + 6 * u), .(c.x + 32 * u, ey), Gui.Color(235, 235, 235));
				Gui.ImDrawList_AddCircleFilled(dl, .(c.x - 27 * u, c.y + 20 * u), 5 * u, Gui.Color(31, 227, 175), 12);
				Gui.ImDrawList_AddCircleFilled(dl, .(c.x + 27 * u, c.y + 20 * u), 5 * u, Gui.Color(160, 250, 68), 12);
				Gui.ImDrawList_AddLine(dl, .(c.x - 14 * u, ey), .(c.x + 14 * u, ey), Gui.Color(90, 90, 90), 2 * u);
			case .Folder:
				float x0 = c.x - 40 * u;
				float x1 = c.x + 40 * u;
				uint32 back = Theme.Mix(col, Gui.Color(0, 0, 0), 0.25f);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, c.y - 32 * u), .(x0 + 32 * u, c.y - 18 * u), back, 4 * u, DrawFlags.RoundCornersTop);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, c.y - 22 * u), .(x1, c.y + 30 * u), back, 4 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, c.y - 12 * u), .(x1, c.y + 30 * u), col, 4 * u, 0);
				Gui.ImDrawList_AddLine(dl, .(x0 + 2 * u, c.y - 12 * u), .(x1 - 2 * u, c.y - 12 * u), Theme.Mix(col, Gui.Color(255, 255, 255), 0.4f), 1.5f * u);
			case .Project:
				// A package: a box with its lid and a band across.
				ImVec2 a = .(c.x - 36 * u, c.y - 18 * u);
				ImVec2 b = .(c.x + 36 * u, c.y + 32 * u);
				Gui.ImDrawList_AddRectFilled(dl, a, b, Theme.Mix(col, Gui.Color(0, 0, 0), 0.2f), 4 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, .(c.x - 40 * u, c.y - 32 * u), .(c.x + 40 * u, c.y - 14 * u), col, 4 * u, 0);
				Gui.ImDrawList_AddRectFilled(dl, .(c.x - 7 * u, c.y - 32 * u), .(c.x + 7 * u, c.y + 32 * u), Theme.Mix(col, Gui.Color(255, 255, 255), 0.45f), 0, 0);
				Gui.ImDrawList_AddRect(dl, a, b, dark, 4 * u, 1.5f * u, 0);
			}
		}
	}

	/// The Project Browser (docked) and the Project Drawer (Ctrl+Space): the project folder's
	/// tree on the left, the current folder's folders and graph documents as tiles on the right.
	extension EditorApp
	{
		// ------------------------------------------------------------------ state

		String mCBFolder = new .() ~ delete _;
		CBDir mCBTree ~ delete _;
		List<String> mCBSelected = new .() ~ DeleteContainerAndItems!(_);
		String mCBAnchor = new .() ~ delete _;
		String mCBScrollTo = new .() ~ delete _;
		TextBuffer mCBSearch = new .(256) ~ delete _;
		float mCBTileSize = 92;
		bool mCBDrawerOpen;
		int32 mCBDrawerFrames;
		bool mCBReveal = true;
		bool mCBItemCtxRequest;
		bool mCBRefocus;
		int64 mCBSignature;
		CBItem mCBOpenRequest ~ delete _;
		String mCBNavigateRequest = new .() ~ delete _;
		/// The tile being dragged (the drag ghost draws it). Moving tiles by drag is not wired up yet.
		CBItem mCBDragItem ~ delete _;

		// Create / rename / delete modals
		bool mOpenCBNewFolder;
		String mCBNewFolder = new .() ~ delete _;
		TextBuffer mCBNameBuf = new .(256) ~ delete _;
		bool mOpenCBRename;
		CBItem mCBRenameItem ~ delete _;
		bool mOpenCBDelete;
		List<CBItem> mCBDeleteItems = new .() ~ DeleteContainerAndItems!(_);
		/// A create / rename / delete dialog is open (keeps the Project Drawer from closing under it).
		bool mCBModalOpen;

		// New Project modal
		bool mOpenNewProject;
		TextBuffer mNPName = new .(256) ~ delete _;
		TextBuffer mNPLocation = new .(2048) ~ delete _;
		String mNPError = new .() ~ delete _;

		const float cTreeWidth = 210;

		// ------------------------------------------------------------------ paths

		static char8 PreferredSep(StringView path)
		{
			if (path.Contains('\\'))
				return '\\';
			if (path.Contains('/'))
				return '/';
			return Path.DirectorySeparatorChar;
		}

		public static void JoinPath(StringView dir, StringView name, String outPath)
		{
			outPath.Append(dir);
			if (!outPath.IsEmpty && !outPath.EndsWith('/') && !outPath.EndsWith('\\'))
				outPath.Append(PreferredSep(dir));
			outPath.Append(name);
		}

		/// True when `path` is inside `dir` (not equal to it).
		public static bool IsUnder(StringView path, StringView dir)
		{
			if (dir.IsEmpty || path.Length <= dir.Length)
				return false;
			if (!ProjectIndex.SamePath(path.Substring(0, dir.Length), dir))
				return false;
			let c = path[dir.Length];
			return c == '/' || c == '\\' || dir.EndsWith('/') || dir.EndsWith('\\');
		}

		static void TrimSeparators(String path)
		{
			while (path.Length > 1 && (path.EndsWith('/') || path.EndsWith('\\')) && !(path.Length == 3 && path[1] == ':'))
				path.RemoveFromEnd(1);
		}

		void RelativeToRoot(StringView path, String outRel)
		{
			if (IsUnder(path, mProjectRoot))
			{
				var rel = path.Substring(mProjectRoot.Length);
				while (rel.StartsWith('/') || rel.StartsWith('\\'))
					rel.RemoveFromStart(1);
				outRel.Append(rel);
			}
			else if (ProjectIndex.SamePath(path, mProjectRoot))
				Path.GetFileName(mProjectRoot, outRel);
			else
				outRel.Append(path);
		}

		/// Case-insensitive "does a file or folder with this name exist in `folder`" (so a project
		/// made on Linux still works on Windows).
		static bool EntryExists(StringView folder, StringView name)
		{
			if (!Directory.Exists(folder))
				return false;
			String n = scope .();
			for (let e in Directory.EnumerateFiles(folder))
			{
				n.Clear();
				e.GetFileName(n);
				if (StringView.Compare(n, name, true) == 0)
					return true;
			}
			for (let e in Directory.EnumerateDirectories(folder))
			{
				n.Clear();
				e.GetFileName(n);
				if (StringView.Compare(n, name, true) == 0)
					return true;
			}
			return false;
		}

		static bool SkipFolder(StringView name) => name.StartsWith(".") || name == "build" || name == "recovery";

		/// A file or folder name the file systems of every platform accept.
		public static bool ValidateFileName(StringView name, String outError)
		{
			if (name.IsEmpty)
			{
				outError.Set("Enter a name.");
				return false;
			}
			for (let c in name.RawChars)
			{
				if (c < ' ' || "<>:\"/\\|?*".Contains(c))
				{
					outError.Set(scope $"A name can't contain '{c}'.");
					return false;
				}
			}
			if (name.EndsWith('.') || name.EndsWith(' ') || name.StartsWith(' '))
			{
				outError.Set("A name can't start with a space or end with a space or a dot.");
				return false;
			}
			String upper = scope .(name);
			upper.ToUpper();
			let dot = upper.IndexOf('.');
			if (dot >= 0)
				upper.RemoveToEnd(dot);
			for (let reserved in StringView[?]("CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3"))
			{
				if (upper == reserved)
				{
					outError.Set(scope $"'{name}' is a reserved name on Windows.");
					return false;
				}
			}
			return true;
		}

		// ------------------------------------------------------------------ folder tree

		void BuildContentTree()
		{
			delete mCBTree;
			mCBTree = null;
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
				return;
			mCBTree = new .();
			mCBTree.Path.Set(mProjectRoot);
			Path.GetFileName(mProjectRoot, mCBTree.Name);
			if (mCBTree.Name.IsEmpty)
				mCBTree.Name.Set(mProjectRoot);
			ScanContentDir(mCBTree, 0);
			// Keep the current folder (or its nearest surviving parent).
			String folder = scope .(mCBFolder);
			while (!folder.IsEmpty && FindCBDir(folder) == null)
			{
				String parent = scope .();
				if (Path.GetDirectoryPath(folder, parent) case .Err || parent.IsEmpty || parent == folder)
					break;
				folder.Set(parent);
			}
			if (folder.IsEmpty || FindCBDir(folder) == null)
				folder.Set(mProjectRoot);
			mCBFolder.Set(FindCBDir(folder).Path);
		}

		void ScanContentDir(CBDir dir, int depth)
		{
			if (depth > ProjectIndex.MaxDepth)
				return;
			for (let e in Directory.EnumerateFiles(dir.Path))
			{
				String path = new .();
				e.GetFilePath(path);
				if (IsGraphFile(path))
					dir.Files.Add(path);
				else
					delete path;
			}
			for (let e in Directory.EnumerateDirectories(dir.Path))
			{
				String name = scope .();
				e.GetFileName(name);
				if (SkipFolder(name))
					continue;
				CBDir sub = new .();
				sub.Name.Set(name);
				e.GetFilePath(sub.Path);
				sub.Parent = dir;
				dir.Dirs.Add(sub);
				ScanContentDir(sub, depth + 1);
			}
			dir.Files.Sort(scope (a, b) => StringView.Compare(a, b, true));
			dir.Dirs.Sort(scope (a, b) => StringView.Compare(a.Name, b.Name, true));
		}

		CBDir FindCBDir(StringView path) => (mCBTree != null) ? FindCBDir(mCBTree, path) : null;

		static CBDir FindCBDir(CBDir dir, StringView path)
		{
			if (ProjectIndex.SamePath(dir.Path, path))
				return dir;
			if (!IsUnder(path, dir.Path))
				return null;
			for (let d in dir.Dirs)
			{
				let found = FindCBDir(d, path);
				if (found != null)
					return found;
			}
			return null;
		}

		/// Cheap fingerprint of the folders and graph documents (names + write times) to notice
		/// changes made outside the editor.
		int64 ComputeCBSignature()
		{
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
				return 0;
			int64 h = (int64)0xCBF29CE484222325;
			HashDir(mProjectRoot, 0, ref h);
			return h;
		}

		static void HashStr(StringView s, ref int64 h)
		{
			for (let c in s)
			{
				h ^= (uint8)c;
				h = (int64)((uint64)h * 0x100000001B3UL);
			}
			h ^= 0x7F;
		}

		void HashDir(StringView dir, int depth, ref int64 h)
		{
			if (depth > ProjectIndex.MaxDepth)
				return;
			String name = scope .();
			for (let e in Directory.EnumerateFiles(dir))
			{
				name.Clear();
				e.GetFileName(name);
				if (!IsGraphFile(name))
					continue;
				HashStr(name, ref h);
				h ^= e.GetLastWriteTimeUtc().Ticks;
				h = (int64)((uint64)h * 0x100000001B3UL);
			}
			for (let e in Directory.EnumerateDirectories(dir))
			{
				name.Clear();
				e.GetFileName(name);
				if (SkipFolder(name))
					continue;
				HashStr(name, ref h);
				String path = scope .();
				e.GetFilePath(path);
				HashDir(path, depth + 1, ref h);
			}
		}

		/// Called at the start of every frame: picks up files created, deleted or edited outside
		/// the editor (polled about every 1.5 s).
		void UpdateProjectBrowser()
		{
			if (mProjectRoot.IsEmpty || mFrame % 90 != 45)
				return;
			if (Gui.igIsAnyItemActive() || Gui.igIsMouseDown_Nil(0))
				return;
			let sig = ComputeCBSignature();
			if (sig != mCBSignature)
				ScanProject();
		}

		/// Re-reads the project folder now (Refresh, F5 in the browser).
		void RequestRescan()
		{
			ScanProject();
			SetStatus("Project folder re-read", .Info, false);
		}

		// ------------------------------------------------------------------ items

		void AddDocumentItem(StringView path, List<CBItem> outItems)
		{
			CBItem item = new .();
			item.Kind = .Document;
			item.Path.Set(path);
			Path.GetFileNameWithoutExtension(path, item.Name);
			CBItem.MakeKey(.Document, path, item.Name, item.Key);
			let doc = FindDoc(path);
			item.Modified = doc != null && doc.Modified;
			outItems.Add(item);
		}

		/// The project file's tile (the root folder's first tile, and a search match on its name).
		void AddProjectItem(List<CBItem> outItems)
		{
			if (Project == null || ProjectPath.IsEmpty)
				return;
			CBItem item = new .();
			item.Kind = .Project;
			item.Path.Set(ProjectPath);
			item.Name.Set(Project.Name.IsEmpty ? "Project" : (StringView)Project.Name);
			CBItem.MakeKey(.Project, ProjectPath, item.Name, item.Key);
			outItems.Add(item);
		}

		void AddFolderItem(CBDir d, List<CBItem> outItems)
		{
			CBItem item = new .();
			item.Kind = .Folder;
			item.Name.Set(d.Name);
			item.Path.Set(d.Path);
			CBItem.MakeKey(.Folder, d.Path, d.Name, item.Key);
			outItems.Add(item);
		}

		void AddMatches(CBDir dir, StringView search, List<CBItem> outItems)
		{
			String name = scope .();
			for (let d in dir.Dirs)
			{
				if (d.Name.Contains(search, true))
					AddFolderItem(d, outItems);
				AddMatches(d, search, outItems);
			}
			for (let f in dir.Files)
			{
				name.Clear();
				Path.GetFileNameWithoutExtension(f, name);
				if (name.Contains(search, true))
					AddDocumentItem(f, outItems);
			}
		}

		/// The tiles: the current folder's folders and documents, or every match in the project
		/// while searching. In-memory documents of this folder (not written yet) are listed too.
		void CollectCBItems(StringView searchIn, List<CBItem> outItems)
		{
			var search = searchIn;
			search.Trim();
			if (!search.IsEmpty)
			{
				if (Project != null && Project.Name.Contains(search, true))
					AddProjectItem(outItems);
				if (mCBTree != null)
					AddMatches(mCBTree, search, outItems);
				return;
			}
			let dir = FindCBDir(mCBFolder);
			if (dir == null)
				return;
			if (dir == mCBTree)
				AddProjectItem(outItems);
			for (let d in dir.Dirs)
				AddFolderItem(d, outItems);
			for (let f in dir.Files)
				AddDocumentItem(f, outItems);
			String docDir = scope .();
			for (let d in mDocs)
			{
				if (d.FilePath.IsEmpty || File.Exists(d.FilePath))
					continue;
				docDir.Clear();
				if (Path.GetDirectoryPath(d.FilePath, docDir) case .Ok && ProjectIndex.SamePath(docDir, dir.Path))
					AddDocumentItem(d.FilePath, outItems);
			}
		}

		bool IsCBSelected(StringView key)
		{
			for (let s in mCBSelected)
				if (s == key)
					return true;
			return false;
		}

		void CBSelectOnly(StringView key)
		{
			ClearAndDeleteItems!(mCBSelected);
			if (!key.IsEmpty)
				mCBSelected.Add(new String(key));
			mCBAnchor.Set(key);
		}

		void CBToggle(StringView key)
		{
			for (int i < mCBSelected.Count)
			{
				if (mCBSelected[i] == key)
				{
					delete mCBSelected[i];
					mCBSelected.RemoveAt(i);
					return;
				}
			}
			mCBSelected.Add(new String(key));
			mCBAnchor.Set(key);
		}

		void NavigateCB(StringView path)
		{
			String p = scope .(path);
			let dir = FindCBDir(p);
			if (dir == null)
				return;
			mCBFolder.Set(dir.Path);
			mCBReveal = true;
			CBSelectOnly("");
			SaveSettings();
		}

		// ------------------------------------------------------------------ drawing

		void DrawProjectBrowserWindows()
		{
			if (Gui.Begin(Panels.ProjectBrowser))
			{
				NoteBottomDock();
				DrawCBBody(false);
			}
			Gui.End();

			if (mCBDrawerOpen)
			{
				let vp = Gui.igGetMainViewport();
				float h = Math.Max(220, vp.WorkSize.y * 0.42f);
				Gui.igSetNextWindowPos(.(vp.WorkPos.x, vp.WorkPos.y + vp.WorkSize.y - h), Cond.Always, .(0, 0));
				Gui.igSetNextWindowSize(.(vp.WorkSize.x, h), Cond.Always);
				if (mCBDrawerFrames == 0)
					Gui.igSetNextWindowFocus();
				bool open = true;
				if (Gui.Begin("Project Drawer", &open, WindowFlags.NoDocking | WindowFlags.NoCollapse | WindowFlags.NoSavedSettings | WindowFlags.NoMove | WindowFlags.NoResize))
				{
					DrawCBBody(true);
					// Closes when you click elsewhere (not while one of its dialogs is up).
					bool focused = Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows);
					bool anyPopup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
					bool dialogBusy = mCBModalOpen || mOpenCBNewFolder || mOpenCBRename || mOpenCBDelete || mOpenNewProject;
					if (mCBDrawerFrames > 2 && !focused && !anyPopup && !dialogBusy)
						open = false;
					if (Gui.IsKeyPressed(Key.Escape, false) && !anyPopup && !Gui.igIsAnyItemActive() && !dialogBusy)
						open = false;
				}
				Gui.End();
				mCBDrawerFrames++;
				if (!open)
					mCBDrawerOpen = false;
			}
			ProcessCBRequests();
		}

		public void ToggleProjectDrawer()
		{
			mCBDrawerOpen = !mCBDrawerOpen;
			mCBDrawerFrames = 0;
		}

		void ProcessCBRequests()
		{
			if (!mCBNavigateRequest.IsEmpty)
			{
				String path = scope .(mCBNavigateRequest);
				mCBNavigateRequest.Clear();
				NavigateCB(path);
			}
			if (mCBOpenRequest != null)
			{
				let item = mCBOpenRequest;
				mCBOpenRequest = null;
				OpenAsset(item);
				delete item;
			}
		}

		static bool GreenButton(StringView label)
		{
			Gui.igPushStyleColor_U32(Col.Button, Gui.Color(36, 120, 40));
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(52, 150, 56));
			Gui.igPushStyleColor_U32(Col.ButtonActive, Gui.Color(30, 100, 34));
			bool r = Gui.Button(label);
			Gui.igPopStyleColor(3);
			return r;
		}

		void DrawCBBody(bool drawer)
		{
			if (mProjectRoot.IsEmpty || mCBTree == null)
			{
				if (mProjectRoot.IsEmpty)
					Gui.TextDisabled("No project folder open.");
				else
					Gui.TextDisabled(scope $"Folder not found: {mProjectRoot}");
				if (Gui.Button("Open Project Folder..."))
					OpenFolderPicker();
				Gui.SameLine();
				if (Gui.Button("New Project..."))
					StartNewProject();
				return;
			}

			// ---- toolbar: + Add, Save All | up, breadcrumb ............ search
			if (GreenButton("+ Add"))
				Gui.OpenPopup("##cbadd");
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Create a folder or a type");
			if (Gui.BeginPopup("##cbadd"))
			{
				DrawAddMenu(mCBFolder);
				Gui.EndPopup();
			}
			Gui.SameLine();
			if (Gui.Button(scope $"{Icon.SaveAll}  Save All"))
				SaveAll();
			Gui.SameLine(0, 16);
			let dir = FindCBDir(mCBFolder);
			Gui.igBeginDisabled(dir == null || dir.Parent == null);
			if (Gui.igArrowButton("##cbup", Dir.Up) && dir?.Parent != null)
				mCBNavigateRequest.Set(dir.Parent.Path);
			Gui.igEndDisabled();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Up one folder");
			Gui.SameLine();
			DrawBreadcrumb(dir);

			// Right-aligned search box; on a narrow panel it shrinks rather than covering the breadcrumb.
			float afterCrumb = Gui.igGetItemRectMax().x - Gui.igGetWindowPos().x + 12 * Look.Scale;
			float rightPad = 40 * Look.Scale;
			float searchW = Math.Min(260 * Look.Scale, Gui.igGetWindowSize().x * 0.3f);
			searchW = Math.Max(Math.Min(searchW, Gui.igGetWindowSize().x - afterCrumb - rightPad), 90 * Look.Scale);
			Gui.SameLine(Math.Max(afterCrumb, Gui.igGetWindowSize().x - searchW - rightPad));
			Gui.igSetNextItemWidth(searchW);
			Gui.igInputTextWithHint("##cbsearch", scope $"{Icon.Search}  Search assets", mCBSearch.Ptr, (.)mCBSearch.Capacity, 0, null, null);
			Gui.SameLine();
			if (Gui.SmallButton("...##cbopts"))
				Gui.OpenPopup("##cbopts");
			if (Gui.BeginPopup("##cbopts"))
			{
				Gui.Text("Tile size");
				Gui.igSetNextItemWidth(180 * Look.Scale);
				Gui.igSliderFloat("##tilesize", &mCBTileSize, 56, 160, "%.0f", 0);
				if (Gui.MenuItem("Refresh", "F5"))
					RequestRescan();
				Gui.EndPopup();
			}
			Gui.Separator();

			// ---- folder tree | asset grid
			if (Gui.igBeginChild_Str("##cbtree", .(cTreeWidth, 0), ChildFlags.ResizeX, 0))
			{
				if (mCBTree != null)
					DrawCBTreeRow(mCBTree, true);
				mCBReveal = false;
			}
			Gui.igEndChild();
			Gui.SameLine();
			Gui.igBeginGroup();
			float footer = Gui.igGetFrameHeight();
			List<CBItem> items = scope .();
			defer { ClearAndDeleteItems!(items); }
			CollectCBItems(mCBSearch.View, items);
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(21, 21, 21));
			if (Gui.igBeginChild_Str("##cbgrid", .(0, -footer), 0, 0))
				DrawCBGrid(items, drawer);
			Gui.igEndChild();
			Gui.igPopStyleColor(1);
			int selectedCount = 0;
			for (let it in items)
				if (IsCBSelected(it.Key))
					selectedCount++;
			String foot = scope .();
			foot.AppendF("{} item{}", items.Count, (items.Count == 1) ? "" : "s");
			if (selectedCount > 0)
				foot.AppendF(" ({} selected)", selectedCount);
			if (!mCBSearch.View.IsEmpty)
				foot.Append("   - searching the whole project");
			Gui.TextDisabled(foot);
			Gui.igEndGroup();
		}

		void DrawBreadcrumb(CBDir dir)
		{
			List<CBDir> chain = scope .();
			for (var d = dir; d != null; d = d.Parent)
				chain.Insert(0, d);
			Gui.igPushStyleColor_U32(Col.Button, 0);
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(255, 255, 255, 30));
			for (let d in chain)
			{
				if (@d.Index > 0)
				{
					Gui.SameLine(0, 2);
					Gui.TextDisabled(">");
					Gui.SameLine(0, 2);
				}
				Gui.PushID((int32)@d.Index);
				bool last = @d.Index == chain.Count - 1;
				Gui.igPushStyleColor_U32(Col.Text, last ? Gui.Color(255, 255, 255) : Gui.Color(170, 170, 170));
				if (Gui.Button(d.Name) && !last)
					mCBNavigateRequest.Set(d.Path);
				Gui.igPopStyleColor(1);
				if (@d.Index == 0 && Gui.igIsItemHovered(0))
					Gui.Tooltip(mProjectRoot);
				Gui.PopID();
			}
			Gui.igPopStyleColor(2);
		}

		/// One row of the folder tree and its children.
		void DrawCBTreeRow(CBDir dir, bool isRoot)
		{
			var d = dir;
			String name = scope .(d.Name);
			bool chainSelected = ProjectIndex.SamePath(d.Path, mCBFolder);
			if (!isRoot)
			{
				// Collapse single-folder chains ("Game/src") like an IDE does.
				while (d.Files.IsEmpty && d.Dirs.Count == 1)
				{
					d = d.Dirs[0];
					name.AppendF("/{}", d.Name);
					if (ProjectIndex.SamePath(d.Path, mCBFolder))
						chainSelected = true;
				}
			}
			int32 flags = TreeNodeFlags.OpenOnArrow | TreeNodeFlags.SpanAvailWidth | (1 << 6) /* OpenOnDoubleClick */;
			if (d.Dirs.IsEmpty)
				flags |= TreeNodeFlags.Leaf;
			if (chainSelected)
				flags |= TreeNodeFlags.Selected;
			if (isRoot)
				flags |= TreeNodeFlags.DefaultOpen;
			if (mCBReveal && IsUnder(mCBFolder, d.Path))
				Gui.igSetNextItemOpen(true, Cond.Always);
			String label = scope .();
			label.AppendF("{}  {}##{}", isRoot ? Icon.Package : Icon.Folder, name, d.Path);
			Gui.igPushStyleColor_U32(Col.Text, isRoot ? Gui.Color(235, 235, 235) : Gui.Color(205, 190, 160));
			bool open = Gui.TreeNode(label, flags);
			Gui.igPopStyleColor(1);
			if (Gui.igIsItemHovered(1 << 12 /* ForTooltip */))
			{
				String rel = scope .();
				RelativeToRoot(d.Path, rel);
				Gui.Tooltip(scope $"{rel}\n{d.CountFilesRecursive()} type file(s)");
			}
			if (Gui.igIsItemClicked(0) && !Gui.igIsItemToggledOpen())
				mCBNavigateRequest.Set(d.Path);
			if (Gui.igBeginPopupContextItem(scope $"##ctx{d.Path}", PopupFlags.MouseButtonRight))
			{
				DrawAddMenu(d.Path);
				Gui.EndPopup();
			}
			if (open)
			{
				for (let sub in d.Dirs)
					DrawCBTreeRow(sub, false);
				Gui.TreePop();
			}
		}

		/// Text in a table cell: cut to the cell with "..." (a tooltip carries the whole text).
		/// `color` 0 draws it in the normal text colour; `dim` in the disabled one.
		static void CellText(StringView text, uint32 color = 0, bool dim = false)
		{
			String fit = scope .();
			FitText(text, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fit);
			if (color != 0)
				Gui.TextColored(color, fit);
			else if (dim)
				Gui.TextDisabled(fit);
			else
				Gui.Text(fit);
		}

		/// A full-row Selectable whose text is cut to the cell with "..." (the id stays the same as
		/// the text changes with the width).
		static bool CellSelectable(StringView text, int32 flags, StringView id)
		{
			String fit = scope .();
			FitText(text, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fit);
			fit.AppendF("###{}", id);
			return Gui.Selectable(fit, false, flags);
		}

		static void FitText(StringView text, float maxW, String outText)
		{
			outText.Set(text);
			if (Gui.CalcTextSize(outText).x <= maxW)
				return;
			while (outText.Length > 1)
			{
				outText.RemoveFromEnd(1);
				String probe = scope .(outText);
				probe.Append("...");
				if (Gui.CalcTextSize(probe).x <= maxW)
				{
					outText.Set(probe);
					return;
				}
			}
		}

		/// Splits a name over at most two lines (breaking at a word / camel-case boundary when
		/// possible); the second line gets "..." when it still doesn't fit.
		static void WrapName(StringView text, float maxW, String line1, String line2)
		{
			if (Gui.CalcTextSize(text).x <= maxW)
			{
				line1.Set(text);
				return;
			}
			int fit = 1;
			while (fit < text.Length && Gui.CalcTextSize(text.Substring(0, fit + 1)).x <= maxW)
				fit++;
			int brk = -1;
			for (int i = fit; i > fit / 2; i--)
			{
				let c = text[i];
				let prev = text[i - 1];
				if ((c.IsUpper && !prev.IsUpper) || prev == '_' || prev == '-' || prev == '.' || prev == ' ')
				{
					brk = i;
					break;
				}
			}
			if (brk < 0)
			{
				FitText(text, maxW, line1);
				return;
			}
			line1.Set(text.Substring(0, brk));
			FitText(text.Substring(brk), maxW, line2);
		}

		void DrawCBGrid(List<CBItem> items, bool drawer)
		{
			let search = mCBSearch.View;
			float tile = Math.Clamp(mCBTileSize, 56, 160);
			float fontH = Gui.igGetFontSize();
			float labelH = fontH * 3 + 8;
			float spacing = 10;
			Gui.igSetCursorPos(.(Gui.igGetCursorPos().x + 6, Gui.igGetCursorPos().y + 6));
			float availW = Gui.igGetContentRegionAvail().x - 6;
			int cols = Math.Max(1, (int)((availW + spacing) / (tile + spacing)));
			let dl = Gui.igGetWindowDrawList();
			float startX = Gui.igGetCursorPos().x;

			if (items.IsEmpty)
			{
				Gui.igSetCursorPos(.(startX + 8, Gui.igGetCursorPos().y + 8));
				if (!search.IsEmpty)
					Gui.TextDisabled("No assets match the search.");
				else
				{
					Gui.TextDisabled("This folder is empty.");
					Gui.igSetCursorPos(.(startX + 8, Gui.igGetCursorPos().y));
					Gui.TextDisabled("Right-click or use + Add to create a type or a folder.");
				}
			}

			for (let item in items)
			{
				int i = @item.Index;
				if (i % cols != 0)
					Gui.SameLine(0, spacing);
				else if (i > 0)
					Gui.igSetCursorPos(.(startX, Gui.igGetCursorPos().y + 4));
				Gui.PushID(item.Key);
				Gui.igInvisibleButton("##tile", .(tile, tile + labelH), ButtonFlags.MouseButtonLeft | ButtonFlags.MouseButtonRight);
				bool hovered = Gui.igIsItemHovered(0);
				bool selected = IsCBSelected(item.Key);
				if (mCBScrollTo == item.Key)
				{
					Gui.igSetScrollHereY(0.5f);
					mCBScrollTo.Clear();
				}
				if (Gui.igIsItemClicked(0))
				{
					if (Gui.IsCtrlDown)
						CBToggle(item.Key);
					else if (Gui.IsShiftDown && !mCBAnchor.IsEmpty)
					{
						int anchor = -1;
						for (let other in items)
							if (other.Key == mCBAnchor)
								anchor = @other.Index;
						if (anchor < 0)
							CBSelectOnly(item.Key);
						else
						{
							ClearAndDeleteItems!(mCBSelected);
							for (int k = Math.Min(anchor, i); k <= Math.Max(anchor, i); k++)
								mCBSelected.Add(new String(items[k].Key));
						}
					}
					else
						CBSelectOnly(item.Key);
					if (item.Kind == .Project && mCBSelected.Count == 1)
						SelectProjectSettings();
				}
				if (hovered && Gui.igIsMouseDoubleClicked_Nil(0))
				{
					delete mCBOpenRequest;
					mCBOpenRequest = item.Clone();
				}
				if (Gui.igIsItemClicked(1))
				{
					if (!selected)
						CBSelectOnly(item.Key);
					mCBItemCtxRequest = true;
				}
				selected = IsCBSelected(item.Key);
				DrawTile(dl, item, Gui.igGetItemRectMin(), tile, labelH, hovered, selected);
				if (Gui.igIsItemHovered(1 << 12 /* ForTooltip */))
					DrawTileTooltip(item);
				Gui.PopID();
			}
			Gui.igDummy(.(0, 8));

			// Click on empty space clears the selection.
			if (Gui.igIsWindowHovered(0) && !Gui.igIsAnyItemHovered() && Gui.igIsMouseClicked_Bool(0, false))
				CBSelectOnly("");

			// Keyboard: F2 rename, Del delete, Enter open, F5 refresh, Ctrl+A select all.
			if (Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && !Gui.igIsAnyItemActive())
			{
				List<CBItem> sel = scope .();
				for (let it in items)
					if (IsCBSelected(it.Key))
						sel.Add(it);
				if (Gui.IsKeyPressed(573 /* F2 */, false) && sel.Count == 1)
					StartRename(sel[0]);
				if (Gui.IsKeyPressed(Key.Delete, false) && !sel.IsEmpty)
					StartDelete(sel);
				if (Gui.IsKeyPressed(Key.Enter, false) && sel.Count == 1)
				{
					delete mCBOpenRequest;
					mCBOpenRequest = sel[0].Clone();
				}
				if (Gui.IsKeyPressed(Key.F5, false))
					RequestRescan();
				if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.A, false))
				{
					ClearAndDeleteItems!(mCBSelected);
					for (let it in items)
						mCBSelected.Add(new String(it.Key));
				}
			}

			// Item context menu (opened from a tile right-click).
			if (mCBItemCtxRequest)
			{
				mCBItemCtxRequest = false;
				Gui.OpenPopup("##cbitemctx");
			}
			if (Gui.BeginPopup("##cbitemctx"))
			{
				List<CBItem> sel = scope .();
				for (let it in items)
					if (IsCBSelected(it.Key))
						sel.Add(it);
				if (sel.IsEmpty)
					Gui.igCloseCurrentPopup();
				else
					DrawItemMenu(sel);
				Gui.EndPopup();
			}
			// Empty-space context menu: the + Add menu.
			if (Gui.igBeginPopupContextWindow("##cbvoidctx", PopupFlags.MouseButtonRight | PopupFlags.NoOpenOverItems))
			{
				DrawAddMenu(mCBFolder);
				Gui.EndPopup();
			}
		}

		void DrawTile(ImDrawList* dl, CBItem item, ImVec2 p0, float tile, float labelH, bool hovered, bool selected)
		{
			ImVec2 p1 = .(p0.x + tile, p0.y + tile + labelH);
			let kc = AssetStyle.KindColor(item.Kind);
			float fontH = Gui.igGetFontSize();
			String name = scope .(item.Name);
			if (item.Modified)
				name.Append('*');
			String line1 = scope .();
			String line2 = scope .();
			if (item.Kind == .Folder)
			{
				if (selected)
					Gui.ImDrawList_AddRectFilled(dl, p0, .(p1.x, p1.y - fontH + 4), Theme.WithAlpha(Look.Primary, 120), 5, 0);
				else if (hovered)
					Gui.ImDrawList_AddRectFilled(dl, p0, .(p1.x, p1.y - fontH + 4), Gui.Color(255, 255, 255, 20), 5, 0);
				AssetStyle.DrawIcon(dl, .Folder, .(p0.x + tile / 2, p0.y + tile * 0.52f), tile * 0.82f, kc);
				WrapName(name, tile - 4, line1, line2);
				float w1 = Gui.CalcTextSize(line1).x;
				AssetStyle.Text(dl, line1, .(p0.x + (tile - w1) / 2, p0.y + tile + 2), fontH, Gui.Color(225, 225, 225));
				if (!line2.IsEmpty)
				{
					float w2 = Gui.CalcTextSize(line2).x;
					AssetStyle.Text(dl, line2, .(p0.x + (tile - w2) / 2, p0.y + tile + 2 + fontH), fontH, Gui.Color(225, 225, 225));
				}
				return;
			}
			uint32 card = selected ? Theme.Mix(Look.Header, Look.Primary, 0.35f) : (hovered ? Gui.Color(56, 56, 56) : Gui.Color(40, 40, 40));
			Gui.ImDrawList_AddRectFilled(dl, .(p0.x + 3, p0.y + 4), .(p1.x + 3, p1.y + 4), Gui.Color(0, 0, 0, 90), 6, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, card, 6, 0);
			// Thumbnail: dark gradient tinted with the kind's colour, icon in the middle.
			ImVec2 t0 = .(p0.x + 1, p0.y + 1);
			ImVec2 t1 = .(p1.x - 1, p0.y + tile - 3);
			uint32 top = Theme.Mix(Gui.Color(26, 26, 26), kc, hovered ? 0.36f : 0.26f);
			uint32 bottom = Gui.Color(14, 14, 14);
			Gui.ImDrawList_AddRectFilled(dl, t0, t1, top, 6, DrawFlags.RoundCornersTop);
			Gui.ImDrawList_AddRectFilledMultiColor(dl, .(t0.x, t0.y + 6), t1, top, top, bottom, bottom);
			// The project tile leaves room for its config pill above the icon.
			bool pill = item.Kind == .Project;
			AssetStyle.DrawIcon(dl, item.Kind, .(p0.x + tile / 2, p0.y + (tile - 3) / 2 + (pill ? tile * 0.08f : 0)), tile * (pill ? 0.58f : 0.7f), kc);
			// Kind strip.
			Gui.ImDrawList_AddRectFilled(dl, .(p0.x, p0.y + tile - 3), .(p1.x, p0.y + tile), kc, 0, 0);
			// Name (up to two lines) and kind at the bottom.
			WrapName(name, tile - 10, line1, line2);
			uint32 nameCol = item.Modified ? Theme.Warning : Gui.Color(235, 235, 235);
			AssetStyle.Text(dl, line1, .(p0.x + 5, p0.y + tile + 3), fontH, nameCol);
			if (!line2.IsEmpty)
				AssetStyle.Text(dl, line2, .(p0.x + 5, p0.y + tile + 3 + fontH), fontH, nameCol);
			if (item.Kind == .Project)
			{
				// The active config as a pill on the thumbnail (the context menu and Properties switch it).
				let cfg = ActiveConfig;
				float fs = fontH * 0.8f;
				float pw = AssetStyle.TextSize(cfg, fs).x + 10;
				ImVec2 c0 = .(p0.x + 5, p0.y + 5);
				ImVec2 c1 = .(Math.Min(p1.x - 5, c0.x + pw), c0.y + fs + 4);
				Gui.ImDrawList_AddRectFilled(dl, c0, c1, Gui.Color(14, 14, 14, 220), (c1.y - c0.y) * 0.5f, 0);
				Gui.ImDrawList_AddRect(dl, c0, c1, kc, (c1.y - c0.y) * 0.5f, 1, 0);
				String cfgFit = scope .();
				if (c0.x + pw <= p1.x - 5)
					cfgFit.Set(cfg);
				else
					FitText(cfg, (c1.x - c0.x - 10) / 0.8f, cfgFit);
				AssetStyle.Text(dl, cfgFit, .(c0.x + 5, c0.y + 2), fs, Gui.Color(240, 220, 190));
			}
			String kindText = scope .();
			FitText((item.Kind == .Project) ? scope $"Project \u{00B7} {ActiveConfig}" : AssetStyle.KindLabel(item.Kind), tile - 10, kindText);
			AssetStyle.Text(dl, kindText, .(p0.x + 5, p1.y - fontH * 0.86f - 4), fontH * 0.86f, Gui.Color(140, 140, 140));
			if (selected)
				Gui.ImDrawList_AddRect(dl, p0, p1, Look.Primary, 6, 2, 0);
			else if (hovered)
				Gui.ImDrawList_AddRect(dl, p0, p1, Look.Hover2, 6, 1, 0);
		}

		void DrawTileTooltip(CBItem item)
		{
			if (!Gui.igBeginTooltip())
				return;
			Gui.Text(item.Name);
			Gui.TextColored(AssetStyle.KindColor(item.Kind), AssetStyle.KindLabel(item.Kind));
			String rel = scope .();
			RelativeToRoot(item.Path, rel);
			Gui.TextDisabled(rel);
			if (item.Kind == .Document && !File.Exists(item.Path))
				Gui.TextColored(Theme.Warning, "Not written yet");
			if (item.Kind == .Project)
				Gui.TextDisabled(scope $"Active config: {ActiveConfig} (right-click to switch)");
			if (item.Modified)
				Gui.TextColored(Theme.Warning, "Unsaved changes");
			Gui.igEndTooltip();
		}

		void MenuIcon(AssetKind kind)
		{
			let min = Gui.igGetItemRectMin();
			let max = Gui.igGetItemRectMax();
			float h = max.y - min.y;
			AssetStyle.DrawIcon(Gui.igGetWindowDrawList(), kind, .(min.x + h * 0.5f, min.y + h * 0.5f), h * 0.85f, AssetStyle.KindColor(kind));
		}

		bool IconMenuItem(AssetKind kind, StringView label, StringView shortcut = "")
		{
			String l = scope .();
			l.AppendF("      {}", label);
			bool r = Gui.MenuItem(l, shortcut);
			MenuIcon(kind);
			return r;
		}

		/// The "+ Add" / right-click menu, acting on `folder`.
		void DrawAddMenu(StringView folderIn)
		{
			String folder = scope .(folderIn);
			Gui.TextDisabled("CREATE");
			if (IconMenuItem(.Folder, "New Folder..."))
				StartNewAsset(.Folder, folder);
			if (IconMenuItem(.Document, "New Type..."))
				StartNewAsset(.Document, folder);
			Gui.Separator();
			if (Gui.MenuItem("Show in Explorer"))
				ShowInExplorer(folder, false);
			if (Gui.MenuItem("Copy Path"))
				Gui.igSetClipboardText(folder);
			if (Gui.MenuItem("Refresh", "F5"))
				RequestRescan();
		}

		/// Right-click menu of the selected tiles.
		void DrawItemMenu(List<CBItem> sel)
		{
			let first = sel[0];
			if (sel.Count == 1)
			{
				Gui.TextColored(AssetStyle.KindColor(first.Kind), AssetStyle.KindLabel(first.Kind));
				Gui.SameLine();
				Gui.Text(first.Name);
			}
			else
				Gui.Text(scope $"{sel.Count} items");
			Gui.Separator();
			if (sel.Count == 1 && first.Kind == .Project && Project != null)
			{
				Gui.TextDisabled("ACTIVE CONFIG");
				for (let c in Project.Configs)
					if (Gui.MenuItem(scope $"{c.Name}##cfg{@c.Index}", "", c.Name == ActiveConfig))
						SetActiveConfig(c.Name);
				Gui.Separator();
				if (Gui.MenuItem("Project Settings", "Enter"))
				{
					SelectProjectSettings();
					Panels.Focus(Panels.PropertiesId);
				}
			}
			else
			{
				if (sel.Count == 1 && Gui.MenuItem("Open", "Enter"))
				{
					delete mCBOpenRequest;
					mCBOpenRequest = first.Clone();
				}
				if (sel.Count == 1 && Gui.MenuItem("Rename", "F2"))
					StartRename(first);
			}
			bool anyProject = false;
			for (let it in sel)
				anyProject |= it.Kind == .Project;
			if (!anyProject && Gui.MenuItem("Delete", "Del"))
				StartDelete(sel);
			Gui.Separator();
			if (Gui.MenuItem("Copy Path"))
			{
				String paths = scope .();
				for (let it in sel)
				{
					if (@it.Index > 0)
						paths.Append('\n');
					paths.Append(it.Path);
				}
				Gui.igSetClipboardText(paths);
			}
			if (sel.Count == 1 && Gui.MenuItem("Show in Explorer"))
				ShowInExplorer(first.Path, first.Kind != .Folder);
		}

		void ShowInExplorer(StringView path, bool isFile)
		{
			ProcessStartInfo psi = scope .();
			String args = scope .();
#if BF_PLATFORM_WINDOWS
			psi.SetFileName(Desktop.SystemProgram("explorer.exe", .. scope String()));
			String winPath = scope .(path);
			winPath.Replace('/', '\\');
			if (isFile)
				args.AppendF("/select,\"{}\"", winPath);
			else
				args.AppendF("\"{}\"", winPath);
#else
			psi.SetFileName(Desktop.SystemProgram("xdg-open", .. scope String()));
			String dir = scope .(path);
			if (isFile)
			{
				dir.Clear();
				Path.GetDirectoryPath(path, dir).IgnoreError(); // a root has no parent: dir stays empty
			}
			args.AppendF("\"{}\"", dir);
#endif
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
				SetStatus("Could not open the file browser");
		}

		// ------------------------------------------------------------------ open, create

		void OpenAsset(CBItem item)
		{
			switch (item.Kind)
			{
			case .Folder:
				NavigateCB(item.Path);
			case .Project:
				SelectProjectSettings();
				Panels.Focus(Panels.PropertiesId);
			case .Document:
				let open = FindDoc(item.Path);
				if (open != null && !open.Sheets.IsEmpty)
				{
					Doc = open;
					OpenTab(open.Sheets[0]);
				}
				else
					OpenFile(item.Path);
			}
		}

		void StartNewAsset(AssetKind kind, StringView folder)
		{
			if (!CheckWritable())
				return;
			if (kind == .Document)
			{
				StartNewDocument(folder);
				return;
			}
			mCBNewFolder.Set(folder.IsEmpty ? (StringView)mProjectRoot : folder);
			String name = scope .("NewFolder");
			for (int n = 1; n < 100 && EntryExists(mCBNewFolder, name); n++)
			{
				name.Set("NewFolder");
				name.AppendF("{}", n);
			}
			mCBNameBuf.Set(name);
			mOpenCBNewFolder = true;
		}

		void CreateFolder(StringView parent, StringView name)
		{
			if (!CheckWritable())
				return;
			String path = scope .();
			JoinPath(parent, name, path);
			if (Directory.CreateDirectory(path) case .Err)
			{
				ReportError(scope $"Could not create the folder {path}");
				return;
			}
			ScanProject();
			NavigateCB(path);
			SetStatus(scope $"Created folder {name}");
		}

		// ------------------------------------------------------------------ rename, delete

		void StartRename(CBItem item)
		{
			if (item.Kind == .Project)
				return; // the project's name is a setting (Properties); its file keeps its name
			delete mCBRenameItem;
			mCBRenameItem = item.Clone();
			mCBNameBuf.Set(item.Name);
			mOpenCBRename = true;
		}

		/// The name on disk a tile gets when renamed to `newName` (documents keep their extension).
		void RenamedFileName(CBItem item, StringView newName, String outName)
		{
			outName.Set(newName);
			if (item.Kind == .Document && !IsGraphFile(outName))
				outName.Append(GraphExtension);
		}

		bool ValidateRename(CBItem item, StringView newName, String outError)
		{
			var n = newName;
			if (item.Kind == .Document && n.EndsWith(GraphExtension, .OrdinalIgnoreCase))
				n.RemoveFromEnd(GraphExtension.Length);
			if (!ValidateFileName(n, outError))
				return false;
			String parent = scope .();
			Path.GetDirectoryPath(item.Path, parent).IgnoreError();
			String full = scope .();
			RenamedFileName(item, n, full);
			String oldName = scope .();
			Path.GetFileName(item.Path, oldName);
			if (StringView.Compare(full, oldName, true) != 0 && EntryExists(parent, full))
			{
				outError.Set("Something with that name already exists here.");
				return false;
			}
			return true;
		}

		/// Points open documents at their new paths after a file or folder moved.
		void RemapDocPaths(StringView oldPath, StringView newPath, bool isFolder)
		{
			for (let d in mDocs)
			{
				if (ProjectIndex.SamePath(d.FilePath, oldPath))
					d.FilePath.Set(newPath);
				else if (isFolder && IsUnder(d.FilePath, oldPath))
				{
					String p = scope .(newPath);
					p.Append(StringView(d.FilePath, oldPath.Length));
					d.FilePath.Set(p);
				}
			}
			if (isFolder && (ProjectIndex.SamePath(mCBFolder, oldPath) || IsUnder(mCBFolder, oldPath)))
			{
				String p = scope .(newPath);
				p.Append(StringView(mCBFolder, oldPath.Length));
				mCBFolder.Set(p);
			}
		}

		void RenameAsset(CBItem item, StringView newNameIn)
		{
			if (!CheckWritable())
				return;
			String newName = scope .(newNameIn);
			newName.Trim();
			String err = scope .();
			if (!ValidateRename(item, newName, err))
			{
				ReportError(err);
				return;
			}
			String parent = scope .();
			Path.GetDirectoryPath(item.Path, parent).IgnoreError();
			String fileName = scope .();
			RenamedFileName(item, newName, fileName);
			String newPath = scope .();
			JoinPath(parent, fileName, newPath);
			bool onDisk = (item.Kind == .Folder) ? Directory.Exists(item.Path) : File.Exists(item.Path);
			if (onDisk)
			{
				let moved = (item.Kind == .Folder) ? Directory.Move(item.Path, newPath) : File.Move(item.Path, newPath);
				if (moved case .Err)
				{
					ReportError(scope $"Could not rename {item.Path}");
					return;
				}
			}
			RemapDocPaths(item.Path, newPath, item.Kind == .Folder);
			ScanProject();
			String key = scope .();
			CBItem.MakeKey(item.Kind, newPath, newName, key);
			CBSelectOnly(key);
			mCBScrollTo.Set(key);
			UpdateTitle();
			SetStatus(scope $"Renamed {item.Name} to {newName}");
		}

		void CloseDoc(TypeDocument doc)
		{
			for (int i = Tabs.Count - 1; i >= 0; i--)
			{
				let tab = Tabs[i];
				if (tab.Doc != doc)
					continue;
				if (mSelectTab == tab)
					mSelectTab = null;
				if (mLastActiveTab == tab)
					mLastActiveTab = null;
				if (mActionTab == tab)
					mActionTab = null;
				Tabs.RemoveAt(i);
				delete tab;
			}
			if (ActiveTab >= Tabs.Count)
				ActiveTab = Tabs.Count - 1;
			mDocs.Remove(doc);
			mConflicts.Remove(doc);
			if (Doc == doc)
			{
				Doc = (CurrentTab != null) ? CurrentTab.Doc : mEmptyDoc;
				mSourceVersion = -1;
			}
			delete doc;
		}

		void CloseDocsUnder(StringView path, bool isFolder)
		{
			for (int i = mDocs.Count - 1; i >= 0; i--)
			{
				let d = mDocs[i];
				if (ProjectIndex.SamePath(d.FilePath, path) || (isFolder && IsUnder(d.FilePath, path)))
					CloseDoc(d);
			}
		}

		void StartDelete(List<CBItem> sel)
		{
			ClearAndDeleteItems!(mCBDeleteItems);
			for (let it in sel)
				if (it.Kind != .Project) // the project file is not deleted from the Project Browser
					mCBDeleteItems.Add(it.Clone());
			mOpenCBDelete = !mCBDeleteItems.IsEmpty;
		}

		void DeleteAssets(List<CBItem> items)
		{
			if (!CheckWritable())
				return;
			int count = 0;
			String err = scope .();
			for (let it in items)
			{
				bool isFolder = it.Kind == .Folder;
				bool onDisk = isFolder ? Directory.Exists(it.Path) : File.Exists(it.Path);
				if (onDisk)
				{
					err.Clear();
					// Recycle Bin / Trash or nothing: if it can't be moved there, it stays.
					if (FileSafety.MoveToRecycleBin(it.Path, err) case .Err)
					{
						ReportError(err);
						continue;
					}
				}
				CloseDocsUnder(it.Path, isFolder);
				count++;
			}
			ScanProject();
			CBSelectOnly("");
			UpdateTitle();
			SaveSettings();
			SetStatus(scope $"Deleted {count} item{(count == 1) ? "" : "s"} (moved to the {FileSafety.TrashName})");
		}

		// ------------------------------------------------------------------ modals

		void DrawProjectBrowserPopups()
		{
			DrawNewFolderPopup();
			DrawRenameAssetPopup();
			DrawDeleteAssetsPopup();
			DrawNewProjectPopup();
		}

		static void ErrorLine(StringView err)
		{
			if (err.IsEmpty)
				Gui.TextDisabled(" ");
			else
				Gui.TextColored(Gui.Color(255, 110, 100), err);
		}

		/// A modal with one name field: true on the frame the user accepts a valid name.
		bool CBNameModal(StringView title, StringView prompt, StringView button, delegate bool(StringView name, String outError) validate, String outName)
		{
			if (!Gui.igBeginPopupModal(scope String(title), null, WindowFlags.AlwaysAutoResize))
				return false;
			bool accepted = false;
			if (Gui.IsKeyPressed(Key.Escape, false))
				Gui.igCloseCurrentPopup();
			Gui.Text(prompt);
			if (Gui.igIsWindowAppearing() || mCBRefocus)
				Gui.igSetKeyboardFocusHere(0);
			mCBRefocus = false;
			Gui.igSetNextItemWidth(380 * Look.Scale);
			bool enter = Gui.igInputText("##cbname", mCBNameBuf.Ptr, (.)mCBNameBuf.Capacity, InputTextFlags.EnterReturnsTrue | InputTextFlags.AutoSelectAll, null, null);
			String name = scope .(mCBNameBuf.View);
			name.Trim();
			String err = scope .();
			bool valid = validate(name, err);
			ErrorLine(err);
			Gui.igBeginDisabled(!valid);
			bool go = Gui.Button(scope String(button), .(120 * Look.Scale, 0)) || (enter && valid);
			if (enter && !valid)
				mCBRefocus = true; // keep typing after Enter on a bad name
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (go && valid)
			{
				Gui.igCloseCurrentPopup();
				outName.Set(name);
				accepted = true;
			}
			Gui.EndPopup();
			return accepted;
		}

		void DrawNewFolderPopup()
		{
			if (mOpenCBNewFolder)
			{
				Gui.OpenPopup("New Folder");
				mOpenCBNewFolder = false;
			}
			String rel = scope .();
			RelativeToRoot(mCBNewFolder, rel);
			String name = scope .();
			if (CBNameModal("New Folder", scope $"Name of the new folder in {rel}:", "Create", scope (n, err) =>
				{
					if (!ValidateFileName(n, err))
						return false;
					if (EntryExists(mCBNewFolder, n))
					{
						err.Set("Something with that name already exists here.");
						return false;
					}
					return true;
				}, name))
				CreateFolder(mCBNewFolder, name);
		}

		void DrawRenameAssetPopup()
		{
			if (mOpenCBRename)
			{
				Gui.OpenPopup("Rename Asset");
				mOpenCBRename = false;
			}
			if (mCBRenameItem == null)
				return;
			let item = mCBRenameItem;
			String name = scope .();
			if (CBNameModal("Rename Asset", scope $"Rename {AssetStyle.KindLabel(item.Kind)} '{item.Name}'", "Rename", scope (n, err) => ValidateRename(item, n, err), name))
			{
				mCBRenameItem = null;
				RenameAsset(item, name);
				delete item;
			}
		}

		void DrawDeleteAssetsPopup()
		{
			if (mOpenCBDelete)
			{
				Gui.OpenPopup("Delete Assets");
				mOpenCBDelete = false;
			}
			if (!Gui.igBeginPopupModal("Delete Assets", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mCBDeleteItems.IsEmpty)
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			Gui.Text(scope $"Delete {mCBDeleteItems.Count} item{(mCBDeleteItems.Count == 1) ? "" : "s"}?");
			Gui.igSpacing();
			for (let it in mCBDeleteItems)
			{
				Gui.TextColored(AssetStyle.KindColor(it.Kind), scope $"  {AssetStyle.KindLabel(it.Kind)}");
				Gui.SameLine(150 * Look.Scale);
				String rel = scope .();
				RelativeToRoot(it.Path, rel);
				if (it.Kind == .Folder)
				{
					let dir = FindCBDir(it.Path);
					int files = (dir != null) ? dir.CountFilesRecursive() : 0;
					Gui.Text(scope $"{rel}/  - the folder and everything in it ({files} type file{(files == 1) ? "" : "s"})");
				}
				else
					Gui.Text(rel);
				let doc = FindDoc(it.Path);
				if (doc != null && doc.Modified)
				{
					Gui.SameLine();
					Gui.TextColored(Theme.Warning, "(unsaved changes)");
				}
			}
			Gui.igSpacing();
			Gui.TextDisabled(scope $"Files and folders go to the {FileSafety.TrashName}.");
			Gui.igSpacing();
			Gui.igPushStyleColor_U32(Col.Button, Gui.Color(150, 40, 40));
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(185, 55, 55));
			bool go = Gui.Button("Delete", .(120 * Look.Scale, 0));
			Gui.igPopStyleColor(2);
			Gui.SameLine();
			if (Gui.igIsWindowAppearing())
				Gui.igSetKeyboardFocusHere(0);
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (go)
			{
				Gui.igCloseCurrentPopup();
				List<CBItem> items = scope .();
				for (let it in mCBDeleteItems)
					items.Add(it);
				mCBDeleteItems.Clear();
				DeleteAssets(items);
				ClearAndDeleteItems!(items);
			}
			Gui.EndPopup();
		}

		// ------------------------------------------------------------------ new project

		/// File > New Project / the start page: a folder named after the project in the chosen
		/// location with its `.tproj` and first type (`CreateProjectFiles`), which then becomes
		/// the open project with that type in front (ProjectSwitch keeps the location setting).
		public void StartNewProject(StringView location = "")
		{
			mNPName.Set("");
			mNPLocation.Set(location.IsEmpty ? NewProjectLocation() : location);
			mNPError.Clear();
			mOpenNewProject = true;
		}

		bool ValidateNewProject(StringView name, StringView location, String outError)
		{
			if (!ValidateFileName(name, outError))
				return false;
			if (location.IsEmpty || !Directory.Exists(location))
			{
				outError.Set("Choose a location that exists.");
				return false;
			}
			if (EntryExists(location, name))
			{
				outError.Set("A folder with that name already exists there.");
				return false;
			}
			return true;
		}

		void DrawNewProjectPopup()
		{
			if (mOpenNewProject)
			{
				Gui.OpenPopup("New Project");
				mOpenNewProject = false;
			}
			if (!Gui.igBeginPopupModal("New Project", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false))
				Gui.igCloseCurrentPopup();
			if (Gui.igIsWindowAppearing())
				Gui.igSetKeyboardFocusHere(0);
			Gui.Text("Name");
			Gui.igSetNextItemWidth(420 * Look.Scale);
			bool enter = Gui.igInputText("##npname", mNPName.Ptr, (.)mNPName.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
			Gui.Text("Location");
			Gui.igSetNextItemWidth(420 * Look.Scale);
			Gui.igInputText("##nploc", mNPLocation.Ptr, (.)mNPLocation.Capacity, 0, null, null);
			String name = scope .(mNPName.View);
			name.Trim();
			String location = scope .(mNPLocation.View);
			location.Trim();
			TrimSeparators(location);
			String err = scope .();
			bool valid = ValidateNewProject(name, location, err);
			if (name.IsEmpty)
				err.Clear();
			String target = scope .();
			if (valid)
			{
				JoinPath(location, name, target);
				Gui.TextDisabled(scope $"Creates {target}");
			}
			else
				ErrorLine(err.IsEmpty ? mNPError : err);
			Gui.igBeginDisabled(!valid);
			bool go = Gui.Button("Create", .(120 * Look.Scale, 0)) || (enter && valid);
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (go && valid)
			{
				String typePath = scope .();
				String why = scope .();
				if (Directory.CreateDirectory(target) case .Err)
					mNPError.Set(scope $"Could not create {target}");
				else if (!CreateProjectFiles(target, name, typePath, why))
					mNPError.Set(scope $"Could not write the project: {why}");
				else
				{
					Gui.igCloseCurrentPopup();
					SaveNewProjectLocation(location);
					FileSafety.ReadOnlyProject = false;
					RequestOpenProject(target, typePath);
					SetStatus(scope $"Created project {name}");
				}
			}
			Gui.EndPopup();
		}
	}
}
