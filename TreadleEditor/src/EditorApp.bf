using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Language;

namespace Treadle.Editor
{
	/// An entry in the Outline panel that can be dragged into a graph.
	class MemberRef
	{
		public enum Kind { Variable, Function }
		public Kind MemberKind;
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public String Params = new .() ~ delete _;
		public String Owner = new .() ~ delete _;
		public bool IsStatic;
	}

	/// The editor: open documents and tabs, the commit queue, menus, settings, the shell's frame.
	/// Split over many files with `extension EditorApp`; this file holds the hub.
	class EditorApp
	{
		/// The workspace's language context: the seams (types, catalog, codec, rules) and the
		/// toolchain. Every document the editor opens gets it and passes it down to its graphs.
		public LanguageContext Language = new .() ~ delete _;
		/// The project's types read from their files: the stand-ins below answer type questions
		/// and fill the Node menu until the language installs its own services (ProjectTypes.bf).
		public ProjectTypes ProjectTypes = new .() ~ delete _;
		ProjectTypeSystem mTypesStandIn ~ delete _;
		ProjectCatalogSource mCatalogStandIn ~ delete _;
		int32 mProjectTypesIndexVersion = -1;
		int mProjectTypesFrame;
		/// Validate / Build / Run for the workspace (Language.Toolchain): the back end's driver.
		Treadle.Backend.Driver.BackendToolchain mToolchain = new .() ~ delete _;
		/// The compiler front end installed in Language: types, Node menu entries, Validate's checks.
		public Treadle.Compiler.FrontEndServices FrontEnd ~ delete _;
		/// Build's side of the front end (Lower to Sheet IR), set on mToolchain.FrontEnd.
		FrontEndProgramSource mProgramSource = new .() ~ delete _;
		/// The document the side panels show (follows the active graph tab).
		public TypeDocument Doc;
		/// Every file opened this session; all stay loaded so graphs in several files can be open.
		List<TypeDocument> mDocs = new .() ~ DeleteContainerAndItems!(_);
		TypeDocument mEmptyDoc = new .() ~ delete _;
		/// The graph files of the project folder.
		public ProjectIndex Index = new .() ~ delete _;
		GraphTab mLastActiveTab;
		public List<GraphTab> Tabs = new .() ~ DeleteContainerAndItems!(_);
		public int ActiveTab = -1;
		GraphPanel mGraphPanel ~ delete _;
		NodeMenu mNodeMenu ~ delete _;
		GraphTab mActionTab;
		NodeClip mClipboard ~ delete _;
		List<MemberRef> mMembers = new .() ~ DeleteContainerAndItems!(_);

		public bool QuitNow;
		bool mShowQuitModal;
		bool mShowDemo;
		String mStatus = new .() ~ delete _;
		double mStatusTime;
		bool mLayoutDirty;
		/// Documents whose save was refused because the file changed on disk (shown one at a time).
		List<TypeDocument> mConflicts = new .() ~ delete _;
		/// Errors waiting for the user to acknowledge (modal); creation / delete / save failures.
		List<String> mErrors = new .() ~ DeleteContainerAndItems!(_);

		// Project / files
		String mProjectRoot = new .() ~ delete _;
		List<String> mProjectFiles = new .() ~ DeleteContainerAndItems!(_);
		bool mShowSwitchModal;
		int mFrame;

		// Popups
		TextBuffer mPathBuf = new .(1024) ~ delete _;
		TextBuffer mNameBuf = new .(256) ~ delete _;
		bool mOpenFilePopup;
		bool mOpenFolderPopup;
		bool mOpenNewSheet;
		bool mOpenRenameSheet;
		String mRenameSheetKey = new .() ~ delete _;
		int32 mContextNode;
		bool mOpenNodeContext;
		String mBrowseDir = new .() ~ delete _;
		bool mDetailsEditPushed;
		bool mFocusCodeField;
		/// Captures: the File menu opens by itself (the start page's request).
		bool mSpFileMenu;
		ImFont* mMono;
		int32 mSourceVersion = -1;

		// Build and Validate
		BuildJob mBuild ~ delete _;
		/// The last Validate (Problems tags its rows "Validate").
		ValidateJob mValidate ~ delete _;
		bool mSelectResultsTab;

		/// Bumped when the default dock layout changes, so saved layouts are rebuilt once.
		const int32 cLayoutVersion = 7;
		int32 mLayoutVersion;
		/// Frames until the Project Browser tab is brought to front after a layout rebuild.
		int32 mFocusCBFrames;

		public this()
		{
			Language.Index = Index;
			Language.Toolchain = mToolchain;
			FrontEnd = new .(Language, mDocs);
			mToolchain.FrontEnd = mProgramSource;
			// Stand-ins while the language's type system and catalogue source are the null ones.
			mTypesStandIn = new .(ProjectTypes);
			mCatalogStandIn = new .(ProjectTypes);
			if (Language.Types is NullTypeSystem)
				Language.Types = mTypesStandIn;
			if (Language.Catalog is EmptyNodeCatalogSource)
				Language.Catalog = mCatalogStandIn;
			Theme.Language = Language;
			mEmptyDoc.Language = Language;
			Doc = mEmptyDoc;
			mGraphPanel = new GraphPanel(this);
			mNodeMenu = new NodeMenu(this);
			LoadSettings();
		}

		// ------------------------------------------------------------------ status & settings

		public void SetStatus(StringView text)
		{
			// Every status message also lands in the Output Log; failures get a toast too.
			bool failure = text.StartsWith("Could not") || text.StartsWith("Save failed") || text.Contains(" failed") ||
				text.StartsWith("Can't") || text.Contains("can't") || text.StartsWith("Not saved") || text.Contains("cancelled");
			SetStatus(text, failure ? .Warning : .Info, failure);
		}

		/// Status bar text plus an Output Log entry at an explicit level (toast when `toast`).
		public void SetStatus(StringView text, LogLevel level, bool toast = true)
		{
			mStatus.Set(text);
			mStatusTime = Gui.igGetTime();
			Notify.Post(level, "Editor", text, toast);
		}

		/// Shows a failure where it can't be missed (modal), logs it as an error and mirrors it
		/// in the status bar.
		public void ReportError(StringView msg)
		{
			SetStatus(msg, .Error, false); // the modal is the notification; no toast on top
			mErrors.Add(new String(msg));
		}

		/// False (with a warning) in a read-only project, or on a document saved by a newer format
		/// version (opened read-only; Shell.bf: DrawFormatNotice).
		public bool CheckWritable()
		{
			if (Doc != null && Doc.IsNewerFormat)
			{
				SetStatus(scope $"{Path.GetFileName(Doc.FilePath, .. scope String())}: {Treadle.Format.Migrations.NewerMessage(Doc.NewerVersion, .. scope String())}", .Warning);
				return false;
			}
			if (!FileSafety.ReadOnlyProject)
				return true;
			SetStatus(FileSafety.ReadOnlyMessage, .Warning);
			return false;
		}

		/// Session state from settings.json ("session"); see Settings.
		void LoadSettings()
		{
			Settings.Load();
			let s = Settings.Root.Get("session");
			if (s == null)
				return;
			mCBTileSize = (float)s.GetNumber("cbTile", mCBTileSize);
			mLayoutVersion = (int32)s.GetNumber("layoutVersion", mLayoutVersion);
			mBottomDockH = (float)s.GetNumber("bottomDockH", mBottomDockH);
			mBottomDockNode = (uint32)s.GetNumber("bottomDockNode", mBottomDockNode);
			if (!s.GetString("activeConfig").IsEmpty)
				mActiveConfig.Set(s.GetString("activeConfig"));
		}

		public void SaveSettings()
		{
			Settings.Load();
			let s = Settings.Session;
			s.Set("cbTile", Json.NewNumber((int)mCBTileSize));
			s.Set("layoutVersion", Json.NewNumber(mLayoutVersion));
			s.Set("bottomDockH", Json.NewNumber(mBottomDockH));
			s.Set("bottomDockNode", Json.NewNumber(mBottomDockNode));
			s.Set("activeConfig", Json.NewString(mActiveConfig));
			Settings.Save();
		}

		/// The command line, already parsed and resolved by Program (EditorArgs / ProjectContract): `root` is the
		/// project folder to open, `file` the file to focus (either may be empty).
		public void HandleArgs(EditorArgs args, StringView root, StringView file)
		{
			// Nothing to open: the start page (Recent projects, Open project, New project, Documentation) shows.
			if (args.IsEmpty)
				return;
			// --view: open read-only (nothing is ever written to the project).
			if (args.View)
				FileSafety.ReadOnlyProject = true;
			if (root.IsEmpty)
				return;
			// The root first, so opening the file does not adopt the file's own folder as the project.
			mProjectRoot.Set(root);
			if (!file.IsEmpty && File.Exists(file))
				OpenFile(scope String(file));
			else if (!file.IsEmpty)
				Notify.Log(.Warning, "Editor", scope $"{file} does not exist; opening the project only");
			ScanProject();
			RememberProject(root);
			EnsureStartSheet();
			Notify.Log(.Info, "Editor", scope $"Opened {root} (focus: {file})");
		}

		// ------------------------------------------------------------------ files

		/// The extension of graph documents (from the language's codec).
		public StringView GraphExtension => Language.Codec.Extension;

		/// True when `path` names a graph document of this language.
		public bool IsGraphFile(StringView path) => Treadle.Format.FormatNames.IsTypeFile(path); // old `.vtype` files open too (FormatNames)

		/// Re-indexes the project folder and rebuilds the Project Browser's folder tree. Frees
		/// every index string: never call it while something iterates the index.
		void ScanProject()
		{
			ClearAndDeleteItems!(mProjectFiles);
			TrimSeparators(mProjectRoot);
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
			{
				Index.Clear();
				BuildContentTree();
				mCBSignature = 0;
				return;
			}
			Index.Build(mProjectRoot, GraphExtension);
			// Layout files and backups moved out of the source folders on this project's first load (Sidecars).
			List<String> moved = scope .();
			defer { ClearAndDeleteItems!(moved); }
			Sidecars.TakeMessages(moved);
			for (let m in moved)
				Notify.Log(.Info, "Project", m);
			LoadProjectFile();
			for (let f in Index.Files)
				mProjectFiles.Add(new String(f.Path));
			BuildContentTree();
			mCBSignature = ComputeCBSignature();
			Notify.Log(.Info, "Index", scope $"Indexed {mProjectRoot}: {Index.Files.Count} file(s)");
		}

		public TypeDocument FindDoc(StringView path)
		{
			for (let d in mDocs)
				if (ProjectIndex.SamePath(d.FilePath, path))
					return d;
			return null;
		}

		public void RequestOpen(StringView path)
		{
			OpenFile(path);
		}

		/// Opens a file (or switches to it if it's already open) and shows its first Sheet.
		public TypeDocument OpenFile(StringView path, bool openFirstGraph = true)
		{
			var doc = FindDoc(path);
			if (doc == null)
			{
				doc = new TypeDocument(Language);
				if (doc.Load(path) case .Err)
				{
					SetStatus(scope $"Could not open {path}: {doc.LastError}");
					delete doc;
					return null;
				}
				if (!doc.LastError.IsEmpty)
					Notify.Log(.Warning, "Editor", scope $"{path}: {doc.LastError}");
				mDocs.Add(doc);
				doc.IndexedVersion = doc.Version;
				if (mProjectRoot.IsEmpty)
				{
					String dir = scope .();
					Path.GetDirectoryPath(path, dir).IgnoreError(); // a root has no parent: dir stays empty
					mProjectRoot.Set(dir);
					ScanProject();
					RememberProject(dir);
				}
			}
			Doc = doc;
			mSourceVersion = -1;
			if (openFirstGraph)
			{
				// An open type comes to the front with the Sheet last in front there; a type opened now shows its
				// first Sheet.
				let front = FrontTabOf(doc);
				if (front != null)
				{
					ActiveTab = Tabs.IndexOf(front);
					mSelectTab = front;
					mLastActiveTab = front;
				}
				else if (!doc.Sheets.IsEmpty)
					OpenTab(doc.Sheets[0]);
			}
			SyncTypeContexts();
			SetStatus(scope $"Opened {path}");
			SaveSettings();
			UpdateTitle();
			return doc;
		}

		/// Opens the Sheet named `sheetName` of a file, anywhere in the project.
		public bool OpenSheet(StringView filePathIn, StringView sheetName)
		{
			String filePath = scope .(filePathIn);
			let doc = OpenFile(filePath, false);
			if (doc == null)
				return false;
			var sheet = doc.FindSheetByName(sheetName);
			if (sheet == null)
				sheet = doc.FindSheet(sheetName);
			if (sheet == null)
				return false;
			OpenTab(sheet);
			return true;
		}

		/// A new type of `kind` at `path` from its template (TypeDocument.InitFromTemplate), written at
		/// once so the Project Browser lists it, then its first view: a class's constructor Sheet, else
		/// Type Settings on the kind's own section (an extension's Extends picker focused). A class or a
		/// struct takes `baseType` (classes) and `interfaces`: each interface function gets a Sheet to fill
		/// and a base with constructors a Base Constructor node in the constructor's Sheet; Type Settings
		/// then shows those rows. The template is where the type's undo history starts.
		public TypeDocument NewDocument(StringView path, Treadle.Model.TypeKind kind = .Class, StringView baseType = "", List<String> interfaces = null)
		{
			if (!CheckWritable())
				return null;
			if (File.Exists(path))
			{
				SetStatus(scope $"Could not create {path}: it exists already");
				return null;
			}
			let doc = new TypeDocument(Language);
			doc.FilePath.Set(path);
			String typeName = scope .();
			Path.GetFileNameWithoutExtension(path, typeName);
			String folder = scope .();
			Path.GetDirectoryPath(path, folder).IgnoreError();
			String ns = scope .();
			NamespaceFor(folder, ns);
			let first = doc.InitFromTemplate(typeName, kind, ns);
			bool inherits = false;
			if (kind == .Class && !baseType.IsEmpty)
			{
				doc.Header.Base = Treadle.Model.TypeRef.Parse(baseType);
				inherits = true;
			}
			if ((kind == .Class || kind == .Struct) && interfaces != null)
			{
				for (let i in interfaces)
				{
					doc.Header.Implements.Add(Treadle.Model.TypeRef.Parse(i));
					inherits = true;
				}
				// The interface functions the base chain does not provide yet: a Sheet each to fill (the
				// base's abstract ones stay under Required overrides).
				List<InheritedFn> req = scope .();
				defer { ClearAndDeleteItems!(req); }
				InheritedFunctions(doc.Header, doc.Members, req, null);
				for (let f in req)
					if (f.FromInterface)
						doc.AddFunctionLike(f.Fn, false);
			}
			String why = scope .();
			if (!doc.TrySave(why))
			{
				// No format installed: the document lives in the editor until a codec writes it.
				Notify.Log(.Warning, "Editor", scope $"{path} was not written: {why}");
				doc.Modified = true;
			}
			mDocs.Add(doc);
			Doc = doc;
			ScanProject();
			if (first != null)
			{
				OpenTab(first);
				SelectOutline(inherits ? OutlineSelection.TypeSettings : OutlineSelection.Member, inherits ? null : first.Member);
				if (inherits && PlaceBaseConstructorStub())
				{
					doc.TrySave(why..Clear());
					doc.Modified = false;
					// The placed node is not selected: Properties keeps Type Settings (the inheritance rows).
					CurrentTab?.ClearSelection();
					SelectOutline(.TypeSettings);
				}
			}
			else
			{
				SelectOutline(.TypeSettings);
				if (kind == .Extension)
					mFocusTsId.Set("##tsextends");
				Panels.Focus(Panels.PropertiesId);
			}
			doc.ClearHistory();
			SetStatus(scope $"Created {path}");
			UpdateTitle();
			return doc;
		}

		/// An in-memory document with one empty Sheet ("Main"), not written anywhere until it is
		/// saved under a name: what an empty project shows, so there is always a Sheet to draw on.
		public TypeDocument NewUntitledDocument()
		{
			let doc = new TypeDocument(Language);
			doc.InitType("Untitled", .Class, "");
			doc.AddSheet("Main");
			doc.Modified = false;
			mDocs.Add(doc);
			Doc = doc;
			OpenTab(doc.Sheets[0]);
			UpdateTitle();
			return doc;
		}

		/// After a project opened: an empty project (no graph documents, no tab) gets an untitled
		/// document with an empty Sheet.
		void EnsureStartSheet()
		{
			if (mProjectRoot.IsEmpty || !Tabs.IsEmpty || !Index.Files.IsEmpty)
				return;
			NewUntitledDocument();
		}

		bool SaveDoc(TypeDocument doc, bool force = false)
		{
			if (doc.FilePath.IsEmpty)
				return false;
			// Saved by a newer format version: read-only, never written (Shell.bf: DrawFormatNotice).
			if (doc.IsNewerFormat)
			{
				SetStatus(scope $"Not saved: {Path.GetFileName(doc.FilePath, .. scope String())}: {Treadle.Format.Migrations.NewerMessage(doc.NewerVersion, .. scope String())}", .Warning);
				return false;
			}
			if (!force && doc.CheckExternalChange())
			{
				if (!mConflicts.Contains(doc))
					mConflicts.Add(doc);
				SetStatus(scope $"Not saved: {doc.FilePath} changed on disk");
				return false;
			}
			// A document with errors saves too (Editor-Model.md 9): the graph is the program, an error is
			// a state of it. Build refuses while errors exist.
			String why = scope .();
			if (!doc.TrySave(why))
			{
				if (FileSafety.ReadOnlyProject)
					SetStatus(FileSafety.ReadOnlyMessage, .Warning);
				else
					ReportError(scope $"Save failed: {why}. The original file is untouched.");
				return false;
			}
			return true;
		}

		public void Save()
		{
			if (Doc.FilePath.IsEmpty)
			{
				StartSaveAs();
				return;
			}
			if (SaveDoc(Doc))
				SetStatus(scope $"Saved {Doc.FilePath}");
			mLayoutDirty = false;
			UpdateTitle();
		}

		/// Saves every modified file. False when any save was refused (conflict, read-only,
		/// failure): callers that go on regardless (build, quit) should stop.
		public bool SaveAll()
		{
			int count = 0;
			bool allOk = true;
			for (let d in mDocs)
			{
				if (d.NeedsSave)
				{
					if (SaveDoc(d))
						count++;
					else
						allOk = false;
				}
			}
			mLayoutDirty = false;
			if (allOk)
				SetStatus(scope $"Saved {count} file(s)");
			UpdateTitle();
			return allOk;
		}

		int ModifiedCount
		{
			get
			{
				int count = 0;
				for (let d in mDocs)
					if (d.NeedsSave)
						count++;
				return count;
			}
		}

		void ReloadFromDisk(TypeDocument doc)
		{
			String path = scope .(doc.FilePath);
			if (doc.Load(path) case .Err)
			{
				// Gone, locked or unreadable: the document stays as it is, nothing is lost.
				SetStatus(scope $"Could not reload {path}: the file cannot be read. Your edits are unchanged.", .Warning);
				return;
			}
			// Tabs on Sheets that are gone close themselves (DrawGraphArea).
			if (doc == Doc)
				mSourceVersion = -1;
			SetStatus(scope $"Reloaded {path} from disk");
		}

		void ReloadFromDisk()
		{
			if (!Doc.FilePath.IsEmpty)
				ReloadFromDisk(Doc);
		}

		void CheckExternalChange()
		{
			for (let doc in mDocs)
			{
				if (doc.FilePath.IsEmpty || doc.ExternalChange)
					continue;
				if (doc.CheckExternalChange())
				{
					// Unsaved edits: never reloaded on its own (the changed-on-disk banner asks).
					if (!doc.NeedsSave)
						ReloadFromDisk(doc);
				}
			}
		}

		/// The window title follows the active tab (see Shell.bf: UpdateWindowTitle).
		void UpdateTitle()
		{
			UpdateWindowTitle();
		}

		// ------------------------------------------------------------------ tabs & graphs

		public GraphTab CurrentTab => (ActiveTab >= 0 && ActiveTab < Tabs.Count) ? Tabs[ActiveTab] : null;

		public Sheet CurrentMethod
		{
			get
			{
				let tab = CurrentTab;
				if (tab == null)
					return null;
				return tab.Doc.FindSheet(tab.MethodKey);
			}
		}

		public void OpenTab(Sheet mg)
		{
			mSelDeclActive = false;
			for (let tab in Tabs)
			{
				if (tab.Doc == mg.Doc && tab.MethodKey == mg.Key)
				{
					ActiveTab = @tab.Index;
					tab.Open = true;
					mSelectTab = tab;
					mLastActiveTab = tab;
					Doc = tab.Doc;
					SyncTypeContexts();
					return;
				}
			}
			String title = scope .();
			AppendSheetName(title, mg);
			GraphTab tab = new .(mg.Doc, mg.Key, title);
			// A Lambda Sheet's tab goes right after its owner's (LambdaSheets.bf).
			let at = LambdaTabIndex(mg);
			Tabs.Insert(at, tab);
			ActiveTab = at;
			mSelectTab = tab;
			mLastActiveTab = tab;
			Doc = mg.Doc;
			// Opening a Sheet brings its type to the front (a type opened now gets its tab in the type strip).
			SyncTypeContexts();
		}
		GraphTab mSelectTab;

		/// A new Sheet in the current document, opened in a tab.
		public Sheet AddSheet(StringView name)
		{
			if (Doc == null || Doc == mEmptyDoc)
			{
				SetStatus("Open or create a type first (+ Add > New Class in the Project Browser)", .Info);
				return null;
			}
			if (!CheckWritable())
				return null;
			String n = scope .(name);
			n.Trim();
			if (n.IsEmpty)
				n.Set("Sheet");
			if (!BeginTypeEdit())
				return null;
			let s = Doc.AddSheet(n);
			EndTypeEdit();
			OpenTab(s);
			UpdateTitle();
			SetStatus(scope $"Added the Sheet {s.Name}");
			return s;
		}

		public bool RenameSheet(Sheet s, StringView name)
		{
			if (!CheckWritable())
				return false;
			// A member's Sheet: the member is renamed (one undo step; the nodes that name it follow).
			if (s.Member != null && s.Doc == Doc)
				return RenameMember(s.Member, name);
			if (!s.Doc.RenameSheet(s, name))
			{
				SetStatus(scope $"Can't rename to '{name}': the name is empty or taken", .Warning);
				return false;
			}
			for (let tab in Tabs)
				if (tab.Doc == s.Doc && tab.MethodKey == s.Key)
				{
					tab.Title.Clear();
					AppendSheetName(tab.Title, s);
				}
			UpdateTitle();
			return true;
		}

		public void DeleteSheet(Sheet s)
		{
			if (!CheckWritable())
				return;
			let doc = s.Doc;
			for (int i = Tabs.Count - 1; i >= 0; i--)
			{
				let tab = Tabs[i];
				if (tab.Doc == doc && tab.MethodKey == s.Key)
				{
					if (mLastActiveTab == tab)
						mLastActiveTab = null;
					if (mSelectTab == tab)
						mSelectTab = null;
					Tabs.RemoveAt(i);
					delete tab;
				}
			}
			if (ActiveTab >= Tabs.Count)
				ActiveTab = Tabs.Count - 1;
			String name = scope .(s.Name);
			doc.RemoveSheet(s);
			UpdateTitle();
			SetStatus(scope $"Deleted the Sheet {name}");
		}

		public void LayoutChanged()
		{
			EditDoc.LayoutTouched = true;
			mLayoutDirty = true;
		}

		/// Call before mutating a graph: records an undo step.
		public void BeginEdit()
		{
			EditDoc.PushUndo();
		}

		/// The document graph edits apply to: the active tab's file.
		public TypeDocument EditDoc => (CurrentTab != null) ? CurrentTab.Doc : Doc;

		bool mCommitPending;
		/// The Sheet the pending edit was made on (a pointer compare only: it may be gone by the commit).
		GraphTab mCommitTab;

		/// Marks the current graph as edited. The commit happens at the end of the frame, when no
		/// panel still uses the graph.
		public void CommitCurrent()
		{
			if (!mCommitPending)
				mCommitTab = CurrentTab;
			mCommitPending = true;
		}

		void DoCommit()
		{
			mCommitPending = false;
			// The edit goes to the Sheet it was made on. The tab strip can show another tab for a frame after a
			// selection (ImGui applies the selection a frame late), so the active tab at this point is not always it.
			GraphTab tab = CurrentTab;
			if (mCommitTab != null && mCommitTab != tab && Tabs.Contains(mCommitTab))
				tab = mCommitTab;
			mCommitTab = null;
			let mg = (tab != null) ? tab.Doc.FindSheet(tab.MethodKey) : null;
			if (tab == null || mg == null)
				return;
			KeyAssigner.Assign(mg.Graph);
			// A node group whose nodes are all gone goes too (NodeGroups.bf).
			mg.Graph.PruneGroups();
			ClearAndDeleteItems!(tab.ReselectKeys);
			for (let id in tab.SelectedNodes)
			{
				let n = mg.Graph.FindNode(id);
				if (n != null)
					tab.ReselectKeys.Add(new String(n.Key));
				let gr = (id < 0) ? mg.Graph.FindGroup(id) : null;
				if (gr != null)
					tab.ReselectKeys.Add(new String(gr.Key));
			}
			let doc = tab.Doc;
			String key = scope .(mg.Key);
			let graph = mg.Graph;
			// The checks and the front end's incremental pass run on every edit; what they find is shown only
			// after Validate / Build / Run, unless "Validate automatically after edits" is on (ValidationState.bf).
			CheckSheet(mg, true);
			if (Prefs.ValidateAfterEdits)
			{
				ReportGraphIssues(doc, key, graph);
				RefreshValidateRows(doc, key);
			}
			mDetailsEditPushed = false;
			UpdateTitle();
			SyncLambdaSheets(doc);
		}

		/// What the last commit reported, so the same problems are not logged again each edit.
		String mLastGraphIssues = new .() ~ delete _;
		/// Graphs (by Graph.Serial) already checked since they were built.
		HashSet<int32> mCheckedGraphs = new .() ~ delete _;

		/// Runs the graph checks on a graph the first time it is shown. What they find is shown (on the
		/// nodes, in the Output Log and in Problems) only when the workspace is validated as it is, or with
		/// "Validate automatically after edits" on; otherwise the Sheet keeps what it showed.
		public void EnsureChecked(Sheet mg)
		{
			let g = mg.Graph;
			if (g.ReadOnly || !mg.Graphable || !mCheckedGraphs.Add(g.Serial))
				return;
			// Split struct pins read from the file: the fields without a wire or a literal get their pins.
			EnsureSplitSubPins(mg);
			if (!Validated)
			{
				CheckSheet(mg, false);
				return;
			}
			mg.Doc.Validate(mg);
			if (!g.Errors.IsEmpty || !g.Warnings.IsEmpty)
				ReportGraphIssues(mg.Doc, mg.Key, g);
			RefreshValidateRows(mg.Doc, mg.Key);
		}

		/// Puts the graph checks' errors and warnings of a graph in the Output Log (the nodes show
		/// them too: red outline and ERROR badge, yellow WARNING badge, tooltips).
		void ReportGraphIssues(TypeDocument doc, StringView methodKey, Graph graph)
		{
			String sig = scope .();
			sig.AppendF("{}|", methodKey);
			for (let e in graph.Errors)
				sig.AppendF("E{}:{}\n", e.NodeId, e.Message);
			for (let e in graph.Warnings)
				sig.AppendF("W{}:{}\n", e.NodeId, e.Message);
			if (sig == mLastGraphIssues)
				return;
			mLastGraphIssues.Set(sig);
			void Log(LogLevel level, GraphError e)
			{
				let node = graph.FindNode(e.NodeId);
				String title = scope .();
				node?.GetTitle(title);
				Notify.LogAt(level, "Graph", scope $"{methodKey} - {title}: {e.Message}", doc.FilePath, 0);
			}
			for (let e in graph.Errors)
				Log(.Error, e);
			for (let e in graph.Warnings)
				Log(.Warning, e);
		}

		public void AddArgument(Node node)
		{
			let mg = CurrentMethod;
			if (mg == null)
				return;
			// A Call takes extra inputs only when it calls a C variadic function: `va0`, `va1`, ...
			// (what the front end reads, Language.md 2.7).
			if (node.Kind == .Call && !IsVariadicCall(node))
				return;
			BeginEdit();
			if (node.Kind == .Call)
				NodeFactory.AddVarArg(mg.Graph, node);
			else
				NodeFactory.AddArgument(mg.Graph, node);
			CommitCurrent();
		}

		public void RemoveArgument(Node node)
		{
			let mg = CurrentMethod;
			if (mg == null)
				return;
			BeginEdit();
			if (node.Kind == .Call)
				NodeFactory.RemoveLastVarArg(mg.Graph, node);
			else
				NodeFactory.RemoveLastArgument(mg.Graph, node);
			CommitCurrent();
		}

		public void DeleteSelection(GraphTab tab)
		{
			let mg = CurrentMethod;
			if (mg != null)
				ExpandGroupsInSelection(tab, mg.Graph);
			if (mg == null || (tab.SelectedNodes.IsEmpty && tab.SelectedLinks.IsEmpty))
				return;
			BeginEdit();
			let g = mg.Graph;
			for (let id in tab.SelectedLinks)
			{
				let l = g.FindLink(id);
				if (l != null)
					g.Disconnect(l);
			}
			bool chainGone = false;
			for (let id in tab.SelectedNodes)
			{
				let n = g.FindNode(id);
				if (n == null || n == g.Entry)
					continue;
				if (n.Kind == .ChainCtor)
					chainGone = true;
				// Keep the flow intact: reconnect the node's predecessor to its successor.
				let execIn = n.ExecIn;
				let then = n.Then;
				if (execIn != null && then != null)
				{
					let inLink = g.FindLinkTo(execIn);
					let next = g.ExecTarget(then);
					if (inLink != null && next != null && n.Outputs.Count > 0)
					{
						bool simple = true;
						for (let p in n.Outputs)
							if (p.Kind == .Flow && p.Name != "then" && g.ExecTarget(p) != null)
								simple = false;
						if (simple)
						{
							let from = inLink.From;
							g.RemoveNode(n);
							g.Connect(from, next.ExecIn);
							continue;
						}
					}
				}
				g.RemoveNode(n);
			}
			// The Base / This Constructor node gone: the constructor runs none first (`chain` cleared).
			if (chainGone && mg.Member != null && mg.Member.Kind == .Ctor && !mg.Key.StartsWith("lambda:"))
			{
				bool left = false;
				for (let n in g.Nodes)
					left |= n.Kind == .ChainCtor;
				if (!left)
					mg.Member.Chain = .None;
			}
			tab.ClearSelection();
			CommitCurrent();
		}

		public void CopySelection(GraphTab tab)
		{
			let mg = CurrentMethod;
			if (mg != null)
				ExpandGroupsInSelection(tab, mg.Graph);
			if (mg == null || tab.SelectedNodes.IsEmpty)
				return;
			List<Node> nodes = scope .();
			for (let id in tab.SelectedNodes)
			{
				let n = mg.Graph.FindNode(id);
				if (n != null && n != mg.Graph.Entry)
					nodes.Add(n);
			}
			if (nodes.IsEmpty)
				return;
			KeyAssigner.Assign(mg.Graph);
			delete mClipboard;
			mClipboard = NodeClip.Capture(mg.Graph, nodes);
			SetStatus(scope $"Copied {nodes.Count} node(s)");
		}

		/// Grid position at the centre of the visible canvas (where menu paste lands).
		public ImVec2 ViewCentre(GraphTab tab)
		{
			return tab.ScreenToGrid(.(tab.CanvasOrigin.x + tab.CanvasSize.x * 0.5f, tab.CanvasOrigin.y + tab.CanvasSize.y * 0.5f));
		}

		public void Paste(GraphTab tab, ImVec2 at)
		{
			let mg = CurrentMethod;
			if (mg == null || mClipboard == null || mClipboard.Nodes.IsEmpty)
				return;
			BeginEdit();
			float minX = float.MaxValue;
			float minY = float.MaxValue;
			for (let n in mClipboard.Nodes)
			{
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
			}
			List<Node> added = scope .();
			mClipboard.InjectInto(mg.Graph, at.x - minX, at.y - minY, added);
			// The pasted nodes are the selection (all of them, the old selection cleared), so they drag as a group.
			if (tab != null && !added.IsEmpty)
			{
				tab.ClearSelection();
				for (let n in added)
					tab.AddToSelection(n.Id);
			}
			CommitCurrent();
		}

		public void DuplicateSelection(GraphTab tab)
		{
			CopySelection(tab);
			let mg = CurrentMethod;
			if (mg == null || mClipboard == null || mClipboard.Nodes.IsEmpty)
				return;
			Paste(tab, .(mClipboard.Nodes[0].X + 40, mClipboard.Nodes[0].Y + 40));
		}

		/// The wire to keep drawing while the Node menu is up for a dragged pin: the source pin id and
		/// the grid point the new node will go to (false when no pin menu is showing on `tab`).
		public bool PendingWire(GraphTab tab, Graph graph, out int32 pinId, out ImVec2 gridPos)
		{
			pinId = 0;
			gridPos = default;
			if (tab == null || tab != mActionTab || !mNodeMenu.PinMenuActive || mNodeMenu.ContextGraph != (Object)graph)
				return false;
			pinId = mNodeMenu.ContextPinId;
			gridPos = mNodeMenu.SpawnPos;
			return graph.FindPin(pinId) != null;
		}

		public void OpenNodeMenu(GraphTab tab, ImVec2 gridPos, int32 pinId)
		{
			mActionTab = tab;
			mNodeMenu.Open(CurrentMethod, gridPos, pinId);
		}

		/// Node hotkeys and favorites (settings.json `editor.nodeHotkeys` / `editor.favorites`).
		public NodeMenuPrefs NodePrefs
		{
			get
			{
				mNodeMenu.Prefs.Load();
				return mNodeMenu.Prefs;
			}
		}

		/// Node hotkeys: places the node bound to `letter` at `gridPos` exactly as choosing it in the
		/// Node menu would, wired to the pin `pinId` when a wire was being dragged from it (0 = none).
		/// False when the letter has no node or this Sheet does not offer it (the status bar says why).
		public bool PlaceHotkeyNode(GraphTab tab, char8 letter, ImVec2 gridPos, int32 pinId)
		{
			let mg = CurrentMethod;
			if (tab == null || mg == null || !mg.Graphable || mg.Graph.ReadOnly)
				return false;
			let nodeKey = NodePrefs.Hotkeys.NodeOf(letter);
			if (nodeKey.IsEmpty)
				return false;
			let item = mNodeMenu.ItemForKey(mg, gridPos, pinId, nodeKey);
			if (item == null)
			{
				SetStatus(scope $"Node hotkey {letter.ToUpper}: {Treadle.Catalog.NodeHotkeys.LabelOf(nodeKey)} is not offered in this Sheet.");
				return false;
			}
			defer delete item;
			mActionTab = tab;
			ExecuteAction(item);
			return true;
		}

		public void OpenNodeContext(int32 nodeId)
		{
			mContextNode = nodeId;
			mOpenNodeContext = true;
		}

		public void NodeDoubleClicked(Node node)
		{
			if (node == null)
				return;
			if (node.Kind == .Call)
			{
				// Open the callee's Sheet: in the type the call names (its file opened from the project
				// when it is not open yet), else a Sheet of that name in this file, then in any open one.
				let calleeName = node.GetSubjectName(.. scope String());
				let mref = Treadle.Model.MemberRef.Parse(node.Text);
				defer delete mref;
				if (mref.Owner == .Type && mref.Type != null && !mref.IsCImport)
				{
					TypeDocument owner = null;
					String full = scope .();
					for (let d in mDocs)
					{
						full.Clear();
						d.Header.GetFullName(full);
						if (full == mref.Type.Name)
							owner = d;
					}
					if (owner == null)
					{
						RefreshProjectTypes();
						let t = ProjectTypes.Find(mref.Type.Name);
						if (t != null && !t.Path.IsEmpty && File.Exists(t.Path))
							owner = OpenFile(t.Path, false);
					}
					let mg = owner?.FindSheetByName(calleeName);
					if (mg != null && mg.Graphable)
					{
						Doc = owner;
						OpenTab(mg);
						return;
					}
				}
				let tabDoc = EditDoc;
				for (let mg in tabDoc.Sheets)
				{
					if (mg.Name == calleeName && mg.Graphable)
					{
						OpenTab(mg);
						return;
					}
				}
				for (let d in mDocs)
				{
					let mg = d.FindSheetByName(calleeName);
					if (mg != null)
					{
						OpenTab(mg);
						return;
					}
				}
				SetStatus(scope $"'{calleeName}' isn't a Sheet of an open document");
			}
			else if (node.Kind == .Lambda)
				OpenLambdaSheet(node);
			else if (node.Kind == .Math || node.Kind == .For)
				mFocusCodeField = true;
		}

		/// A `TREADLE_MEMBER` payload dropped on the Sheet at `pos` (grid), over pin `pinId` (0: none).
		/// A variable dropped on an input pin it fits places a Get wired into it, on an output pin a Set
		/// fed by it, with no key held (Ctrl still works); a pin it does not fit refuses with the reason.
		/// Elsewhere Ctrl places a Get, Alt a Set, and a plain drop asks (a Node menu row places what it says).
		public void DropMember(GraphTab tab, int32 index, ImVec2 pos, int32 pinId = 0, bool testPlain = false)
		{
			let m = DraggedRef(index);
			if (m == null)
				return;
			let mg = CurrentMethod;
			if (mg == null)
				return;
			bool asSet = Gui.IsAltDown && !testPlain;
			Pin onPin = (pinId != 0) ? mg.Graph.FindPin(pinId) : null;
			if (onPin != null && onPin.Kind != .Value)
				onPin = null;
			if (m.MemberKind == .Variable && onPin != null && !(Gui.IsAltDown && !testPlain))
			{
				// Onto a pin: what fits it, without asking.
				asSet = !onPin.IsInput;
				Node probe = asSet ? NodeFactory.Set(mg.Graph, m.Name, m.Type) : NodeFactory.Get(mg.Graph, m.Name, m.Type);
				Pin end = asSet ? probe.FindInput("value") : probe.Result;
				String why = scope .();
				bool fits = end != null && (asSet ? Graph.CanConnectTyped(Language, onPin, end, why) : Graph.CanConnectTyped(Language, end, onPin, why));
				mg.Graph.RemoveNode(probe);
				if (!fits)
				{
					SetStatus(scope $"{m.Name} does not fit this pin{(why.IsEmpty ? "" : ": ")}{why}", .Warning);
					return;
				}
			}
			// UX: Ctrl+drop = Get, Alt+drop = Set, a plain drop asks (Get / Set menu).
			else if (m.MemberKind == .Variable && (testPlain || (!Gui.IsCtrlDown && !Gui.IsAltDown)))
			{
				if (index != cMenuDragIndex)
				{
					mGraphPanel.ShowVariableDropMenu(m.Name, m.Type, pos);
					return;
				}
				asSet = mMenuDragIsSet;
			}
			BeginEdit();
			Node n;
			if (m.MemberKind == .Variable)
			{
				if (asSet)
					n = NodeFactory.Set(mg.Graph, m.Name, m.Type);
				else
					n = NodeFactory.Get(mg.Graph, m.Name, m.Type);
			}
			else
			{
				let own = mg.Doc.FindMember(m.Name);
				if (own != null && own.Kind == .Function)
					n = NodeMenu.CallOwn(mg.Graph, own, mg.Doc.Header.GetFullName(.. scope String()), !own.Pure);
				else
					n = CreateCallNode(mg, m.Name, m.Params, m.Type, true, false, m.Owner, m.IsStatic);
			}
			n.X = Canvas.SnapIf(pos.x);
			n.Y = Canvas.SnapIf(pos.y);
			n.HasPos = true;
			if (pinId != 0)
			{
				let pin = mg.Graph.FindPin(pinId);
				if (pin != null && n.Result != null && pin.IsInput && pin.Kind == .Value)
					mg.Graph.Connect(n.Result, pin);
				else if (pin != null && !pin.IsInput && pin.Kind == .Value && n.Kind == .Set && n.FindInput("value") != null)
					mg.Graph.Connect(pin, n.FindInput("value"));
			}
			tab.SelectOnly(n.Id);
			CommitCurrent();
		}

		/// A call node for a function known by name and parameter text ("int a, out int b = 2").
		///  - `memberCall`: a member function of `ownerType` with a Receiver pin (unconnected = self);
		///  - a dotted name ("Console.WriteLine"): a static call with that qualifier;
		///  - `ownerType` set: a function of the type being edited, static (`isStatic`, no Receiver)
		///    or a member call on self;
		///  - otherwise a call by name.
		/// `out` parameters become output pins, `ref` ones ref inputs, defaults go in the pins.
		Node CreateCallNode(Sheet mg, StringView name, StringView paramsText, StringView returnType, bool exec,
			bool memberCall = false, StringView ownerType = "", bool isStatic = false)
		{
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			List<StringView> mods = scope .();
			List<StringView> defaults = scope .();
			// Split on top-level commas only ("Dictionary<int, String> map, int count").
			List<StringView> parts = scope .();
			{
				int depth = 0;
				int segStart = 0;
				for (int i < paramsText.Length)
				{
					let c = paramsText[i];
					if (c == '<' || c == '(' || c == '[')
						depth++;
					else if (c == '>' || c == ')' || c == ']')
						depth--;
					else if (c == ',' && depth == 0)
					{
						parts.Add(paramsText.Substring(segStart, i - segStart));
						segStart = i + 1;
					}
				}
				parts.Add(paramsText.Substring(segStart));
			}
			for (var part in parts)
			{
				StringView def = default;
				int eq = part.IndexOf('=');
				if (eq > 0)
				{
					def = part.Substring(eq + 1);
					def.Trim();
					part = part.Substring(0, eq);
				}
				part.Trim();
				if (part.IsEmpty)
					continue;
				int space = part.LastIndexOf(' ');
				if (space > 0)
				{
					var t = part.Substring(0, space);
					t.Trim();
					NodeFactory.SplitModifier(t, let modifier, let type);
					types.Add(type);
					mods.Add(modifier);
					names.Add(part.Substring(space + 1));
				}
				else
				{
					names.Add(part);
					types.Add("");
					mods.Add("");
				}
				defaults.Add(def);
			}
			String ret = scope .(returnType);
			if (ret.IsEmpty)
				ret.Set("void");
			Node n;
			int dot = name.LastIndexOf('.');
			if (memberCall)
				n = NodeFactory.MemberCall(mg.Graph, name, ownerType, exec, names, types, ret, mods);
			else if (dot > 0)
				n = NodeFactory.StaticCall(mg.Graph, name.Substring(dot + 1), name.Substring(0, dot), exec, names, types, ret, mods);
			else if (!ownerType.IsEmpty && isStatic)
				n = NodeFactory.StaticCall(mg.Graph, name, ownerType, exec, names, types, ret, mods);
			else if (!ownerType.IsEmpty)
				n = NodeFactory.MemberCall(mg.Graph, name, ownerType, exec, names, types, ret, mods);
			else
				n = NodeFactory.Call(mg.Graph, name, exec, names, types, ret);
			for (int i < defaults.Count)
			{
				if (defaults[i].IsEmpty || i >= names.Count)
					continue;
				let p = n.FindInput(names[i]);
				if (p != null)
					p.Default.Set(defaults[i]);
			}
			return n;
		}

		/// After a wire or a typed value changed a call's inputs. Seam: a language with overloads
		/// re-fits the call here (the type system knows the candidates). Nothing to do without one.
		public bool RefitCall(Treadle.Graph.Graph g, Node n)
		{
			return false;
		}

		/// Places what a Node menu row makes at the menu's spawn point, wired to the pin the menu
		/// was dragged from (one undo step). Rows that change the document first (a new local, a
		/// new function) do that here; a Comment row makes a comment box, a Reroute row a knot.
		public Node ExecuteAction(NodeItem item)
		{
			let tab = mActionTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null || mg.Graph.ReadOnly)
				return null;
			let g = mg.Graph;
			if (item.Kind == .Comment)
			{
				mGraphPanel.CreateComment(tab, g);
				return null;
			}
			Pin contextPin = (mNodeMenu.ContextPinId != 0) ? g.FindPin(mNodeMenu.ContextPinId) : null;
			if (item.Kind == .Reroute)
			{
				if (contextPin != null)
					mGraphPanel.KnotFromPin(tab, g, contextPin, mNodeMenu.SpawnPos);
				return null;
			}
			BeginEdit();
			int32 maxIdBefore = 0;
			for (let o in g.Nodes)
				maxIdBefore = Math.Max(maxIdBefore, o.Id);
			bool wantExec = NodeMenu.WantFlow(item, contextPin);
			Node n = null;
			switch (item.Kind)
			{
			case .LocalVar:
				// A new local variable of the function (typed like the pin it was dragged from) and a Set of it.
				String varName = scope .();
				GraphPanel.UniqueLocalName(mg, "newVar", varName);
				String type = scope .();
				if (contextPin != null && contextPin.Kind == .Value)
					type.Set(contextPin.TypeName);
				NodeFactory.AddLocal(g, varName, type);
				n = NodeFactory.Set(g, varName, type);
			case .NewFunction:
				let s = mg.Doc.AddFunction("NewFunction");
				n = NodeMenu.CallOwn(g, s.Member, "", true);
				SetStatus(scope $"Added the function {s.Member.Name}: double-click the Call to open it");
			default:
				n = mNodeMenu.CreateNode(mg, g, item, wantExec, false);
			}
			if (n == null)
			{
				EditDoc.DropLastUndo();
				return null;
			}
			// A Base / This Constructor: the constructor says which one it runs first (`chain base|this`).
			if (n.Kind == .ChainCtor && mg.Member != null && mg.Member.Kind == .Ctor)
			{
				mg.Member.Chain = (n.Text == "this") ? .This : .Base;
				mg.Doc.Modified = true;
			}
			// Placed nodes snap to the grid like dragged ones.
			n.X = Canvas.SnapIf(mNodeMenu.SpawnPos.x);
			n.Y = Canvas.SnapIf(mNodeMenu.SpawnPos.y);
			n.HasPos = true;

			// Wired to the pin the user dragged from; dragged from an input, the node goes left of the mouse.
			if (contextPin != null)
			{
				if (contextPin.IsInput)
					n.X -= 240;
				NodeMenu.WireToContext(g, n, contextPin, item);
				if (n.Kind == .ResultMatch || n.Kind == .Construct || n.Kind == .Local)
					LifetimeWired(g, n);
				// A Lambda from a delegate input: its type, inputs, Allocation and Sheet follow the pin.
				if (n.Kind == .Lambda && g.IsLinked(contextPin))
					SetupLambdaFromPin(mg, n, contextPin);
			}
			// Companions a single row spawns (the Branch and Break of a loop with Break) are spaced
			// like Arrange does; the whole group then steps clear of existing nodes.
			LayeredArrange.SizeFn sizeOf = scope (nd, w, h) => mGraphPanel.GetNodeSize(nd.Id, out w, out h);
			List<Node> fresh = scope .();
			for (let o in g.Nodes)
				if (o.Id > maxIdBefore)
					fresh.Add(o);
			if (item.Kind == .LoopBreak)
				LayeredArrange.ArrangeFrom(g, n, fresh, sizeOf);
			LayeredArrange.AvoidOverlap(g, fresh, sizeOf);
			if (mActionTab != null)
				mActionTab.SelectOnly(n.Id);
			CommitCurrent();
			return n;
		}

		/// After auto-wiring a lifetime node: a Result node takes the type of the Result wired into
		/// it (and its payload the T); a `.()` Construct shows the type of the input it feeds.
		static void LifetimeWired(Treadle.Graph.Graph g, Node n)
		{
			if (n.Kind == .ResultMatch)
			{
				let v = n.FindInput("result");
				let link = (v != null) ? g.FindLinkTo(v) : null;
				if (link != null && !link.From.TypeName.IsEmpty)
				{
					v.SetTypeText(link.From.TypeName);
					NodeFactory.SetResultPayloadType(n);
				}
				return;
			}
			if (n.Text.IsEmpty && n.Result != null && n.Result.TypeName.IsEmpty)
			{
				let link = g.FindLinkFrom(n.Result);
				if (link != null)
					n.Result.SetTypeText(link.To.TypeName);
			}
		}

		// ------------------------------------------------------------------ validate, build, run

		/// Validate (Shift+F7, Build > Validate): asks the workspace's toolchain whether the program
		/// is right, without saving anything. Level 1 at once: the graph checks of every open Sheet.
		/// Level 2 (the language's own checks) when the toolchain has them. The results go to
		/// Problems, tagged "Validate". `quiet`: no toast, no Output Log line, Problems stays where it is.
		public void Validate(bool quiet = false)
		{
			let toolchain = Language.Toolchain;
			if (toolchain == null)
				return;
			List<TypeDocument> docs = scope .();
			if (!Doc.FilePath.IsEmpty)
				docs.Add(Doc);
			List<Sheet> sheets = scope .();
			for (let tab in Tabs)
			{
				let mg = tab.Doc?.FindSheet(tab.MethodKey);
				if (mg != null && !sheets.Contains(mg))
					sheets.Add(mg);
			}
			if (docs.IsEmpty && sheets.IsEmpty)
			{
				if (!quiet)
					SetStatus("Open a document or a Sheet first: Validate checks the open Sheets", .Info);
				return;
			}
			ValidateRequest request = .();
			request.Documents = docs;
			request.Sheets = sheets;
			request.Workspace = mProjectRoot;
			request.Config = "";
			request.Tool = "";
			request.OpenDocuments = mDocs;
			delete mValidate;
			mValidate = toolchain.Validate(request);
			mValidateQuiet = quiet;
			// Sheets shown earlier but not open now drop what they showed and are checked when shown again
			// (EnsureChecked): from here on, what a Sheet shows is of the workspace as validated.
			for (let d in mDocs)
				for (let s in d.Sheets)
					if (s.IsBuilt && !sheets.Contains(s) && mCheckedGraphs.Remove(s.Graph.Serial))
						s.Graph.ClearErrors();
			MarkValidated();
			// The checks may have changed what the nodes show: the Output Log gets them as after an edit.
			for (let mg in sheets)
				ReportGraphIssues(mg.Doc, mg.Key, mg.Graph);
			if (!quiet)
			{
				ShowCompilerResults = true;
				mSelectResultsTab = true;
			}
			ShowValidateStatus(quiet || mValidate.Running);
		}

		/// Validate's last call was quiet.
		bool mValidateQuiet;

		/// The status bar (and, unless `quiet`, the Output Log) gets Validate's summary.
		void ShowValidateStatus(bool quiet)
		{
			String summary = scope .();
			ValidateSummary(summary);
			let errors = mValidate.ErrorCount;
			let warnings = mValidate.WarningCount;
			if (quiet)
			{
				mStatus.Set(summary);
				mStatusTime = Gui.igGetTime();
				return;
			}
			SetStatus(summary, (errors > 0) ? .Error : ((warnings > 0) ? .Warning : .Success), errors > 0);
		}

		/// Level 2 of the last Validate came back (or gave up): the status bar gets the summary,
		/// the Output Log the note when it could not run.
		void OnValidateLevel2()
		{
			if (!mValidate.Note.IsEmpty && !mValidateQuiet)
				Notify.Log(.Warning, "Validate", mValidate.Note);
			ShowValidateStatus(mValidateQuiet);
		}

		/// "Validate: 2 errors, 1 warning in 3 Sheets (4 ms)".
		void ValidateSummary(String outText)
		{
			if (mValidate == null)
				return;
			let errors = mValidate.ErrorCount;
			let warnings = mValidate.WarningCount;
			outText.AppendF("Validate: {} error{}, {} warning{}", errors, (errors == 1) ? "" : "s", warnings, (warnings == 1) ? "" : "s");
			if (mValidate.Level >= 2)
			{
				outText.AppendF(" ({:0.00} s)", (mValidate.CompilerMs + mValidate.Ms) / 1000);
				return;
			}
			outText.AppendF(" in {} Sheet{}", mValidate.Sheets, (mValidate.Sheets == 1) ? "" : "s");
			outText.AppendF(" ({:0} ms)", mValidate.Ms);
			if (mValidate.Running)
				outText.Append("; the language's checks are running");
			else if (mValidate.Level2Asked && !mValidate.Note.IsEmpty)
				outText.Append("; the language's checks did not run");
		}

		/// After an edit (and when a Sheet is first checked) the Validate rows of that Sheet follow
		/// the graph's own checks, so Problems never shows an error the graph no longer has.
		void RefreshValidateRows(TypeDocument doc, StringView methodKey)
		{
			if (mValidate == null || doc.FilePath.IsEmpty)
				return;
			for (int i = mValidate.Messages.Count - 1; i >= 0; i--)
			{
				let d = mValidate.Messages[i];
				if (d.MethodKey == methodKey && ProjectIndex.SamePath(d.Path, doc.FilePath))
				{
					mValidate.Messages.RemoveAt(i);
					delete d;
				}
			}
			let mg = doc.FindSheet(methodKey);
			if (mg == null || !mg.Graphable || mg.Graph.ReadOnly)
				return;
			List<Sheet> one = scope .();
			one.Add(mg);
			ValidateRequest request = .();
			request.Sheets = one;
			let job = Language.Toolchain.Validate(request);
			defer delete job;
			for (let m in job.Messages)
				mValidate.Messages.Add(m);
			job.Messages.Clear();
		}

		/// Build (F7, Build > Build; Ctrl+F7 Force Build): saves every file, then runs the build
		/// through the workspace's toolchain.
		public void Build(StringView configOverride = default, bool force = false, bool lowerPriority = false)
		{
			StartBuild(configOverride, force, lowerPriority, false);
		}

		void StartBuild(StringView configOverride, bool force, bool lowerPriority, bool forRun)
		{
			let toolchain = Language.Toolchain;
			if (toolchain == null)
				return;
			if (Doc.FilePath.IsEmpty && mProjectRoot.IsEmpty)
			{
				SetStatus("Open a project first");
				return;
			}
			if (mBuild != null && mBuild.Running)
			{
				SetStatus("A build is already running (Build > Cancel Build stops it)", .Warning);
				return;
			}
			if (RefuseNewerFormat("Build"))
				return;
			// Build and Run show the problems of the workspace as Validate does (quietly: the build's own status
			// and panels follow), also when the build cannot start. Before the build: its thread holds the
			// front end's lock.
			Validate(true);
			if (!SaveAll())
			{
				SetStatus("Build cancelled: some files could not be saved.");
				return;
			}
			for (let d in mDocs)
				d.BuildVersion = d.Version;
			BuildRequest request = .();
			request.Workspace = mProjectRoot;
			request.Config = configOverride.IsEmpty ? ActiveConfig : configOverride;
			request.Tool = "";
			request.Carried = null;
			request.LowerPriority = lowerPriority;
			Result<BuildJob> started;
			if (forRun)
			{
				RunRequest run = .();
				run.Build = request;
				started = toolchain.Run(run);
			}
			else
				started = toolchain.Build(request);
			if (started case .Err)
			{
				SetStatus(NullToolchain.NoTool, .Warning);
				return;
			}
			delete mBuild;
			mBuild = started.Get();
			MarkBuilt(); // ValidationState.bf: the build state turns "Needs build" after the next edit
			// The bottom dock stays as it is: Problems comes forward when the build fails, the Output
			// Log when the program prints something.
			mBuildLogged = 0;
			mBuildCommandLogged = false;
			Notify.Log(.Info, "Build", scope $"Building {mProjectRoot}");
			LogToolSourcesOnce();
			SetStatus(scope $"Building {mProjectRoot}...");
		}

		static bool sToolSourcesLogged;

		/// The tools an environment variable chose instead of the packaged copy or the repository's tools
		/// folder (Security-Review.md finding 8): one line each, `toolchain from TREADLE_LLVM=<path>`,
		/// `libclang from TREADLE_LIBCLANG=<path>`, `lldb-dap from TREADLE_LLDB_DAP=<path>`.
		public static void ToolSources(List<String> outLines)
		{
			StringView[?] names = .("TREADLE_LLVM", "TREADLE_LIBCLANG", "TREADLE_LLDB_DAP");
			StringView[?] whats = .("toolchain", "libclang", "lldb-dap");
			for (int i < names.Count)
			{
				let name = names[i];
				let what = whats[i];
				String v = scope .();

				if (Environment.GetEnvironmentVariable(name, v) case .Ok && !v.IsEmpty)
					outLines.Add(new $"{what} from {name}={v}");
			}
		}

		/// Says once per session in the Output Log where the tools come from when an environment variable
		/// chose them (the first Build or Import C Headers). True when this call logged (or had nothing to say).
		public static bool LogToolSourcesOnce()
		{
			if (sToolSourcesLogged)
				return false;
			sToolSourcesLogged = true;
			List<String> lines = scope .();
			defer { ClearAndDeleteItems!(lines); }
			ToolSources(lines);
			for (let l in lines)
				Notify.Log(.Info, "Build", l);
			return true;
		}


		/// Build > Cancel Build, the toolbar's Cancel: ends the running build and everything it
		/// started. The frame that sees the end reports "Build cancelled".
		public void CancelBuild()
		{
			if (mBuild == null || !mBuild.Running)
				return;
			mBuild.Cancel();
			SetStatus("Cancelling the build...", .Warning);
		}

		// ------------------------------------------------------------------ frame

		public void Frame()
		{
			mFrame++;
			TrackFrameTime();
			TickProjectTypes();
			ShellBeginFrame();
			if (mMono == null)
			{
				mMono = Host.th_get_mono_font();
				PropertyGrid.MonoFont = mMono;
			}
			// Polling is time-based: the frame loop sleeps while idle (see Desktop.PaceFrame).
			let now = Desktop.Now;
			if (now - mExternalCheckTime > 1.0)
			{
				mExternalCheckTime = now;
				CheckExternalChange();
			}
			Autosave(now);
			Recovery.Tick(mDocs, now);
#if !BF_PLATFORM_WINDOWS
			CrashHandler.SetProject(mProjectRoot);
#endif
			Desktop.MaybeRaiseForTest();
			CrashHandler.MaybeCrashForTest(mFrame, scope () =>
			{
				if (Doc != null && Doc != mEmptyDoc)
					Doc.Modified = true;
			});
			UpdateTick();
			if (mValidate != null && mValidate.Running && mValidate.Update())
				OnValidateLevel2();
			ToolchainTick(now);
			RunProgramTick();
			if (mBuild != null && mBuild.Update() && !OnBuildStartFailed())
			{
				int errors = 0;
				int warnings = 0;
				for (let m in mBuild.Messages)
				{
					if (m.IsError)
						errors++;
					else
						warnings++;
				}
				mStatus.Set(mBuild.Cancelled ? "Build cancelled" : (mBuild.Succeeded ? "Build succeeded" : "Build failed"));
				mStatusTime = Gui.igGetTime();
				OnBuildFinished(errors, warnings);
			}
			UpdateProjectBrowser();
			UpdateDebugger();
			HandleShortcuts();
			DrawMainMenu();
			DrawToolbar();
			DrawUpdateBar();
			DrawStatusBar();
			SetupDockspace();
			DrawProjectBrowserWindows();
			if (mFocusCBFrames > 0 && --mFocusCBFrames == 0)
				Panels.Focus(Panels.ProjectBrowserId);
			DrawOutlinePanel();
			DrawGraphArea();
			DrawPropertiesPanel();
			DrawOutputLog();
			DrawCompilerResultsPanel();
			DrawFindResults();
			DrawDebugPanels();
			DrawHoodPanels(); // Memory and Disassembly: MemoryPanel.bf, DisassemblyPanel.bf
			DrawPopups();
			DrawStartPageAndDocs();
			DrawPreferences();
			DrawUpdatePanels(); // What changed, About (Updates.bf)
			if (mShowDemo)
				Gui.igShowDemoWindow(&mShowDemo);
			DrawDragGhost();
			DrawSheetSwitcher();
			SelfTestTick();
			BuildRunTick();
			ShellEndFrame();
			if (mCommitPending)
				DoCommit();
		}

		/// The toolchain's per-frame upkeep (its lines go to the Output Log).
		void ToolchainTick(double now)
		{
			let toolchain = Language.Toolchain;
			if (toolchain == null)
				return;
			List<String> lines = scope .();
			defer { ClearAndDeleteItems!(lines); }
			toolchain.Update(now, lines);
			for (let l in lines)
				Notify.Log(.Info, "Build", l);
		}

		double mExternalCheckTime;

		void HandleShortcuts()
		{
			bool ctrl = Gui.IsCtrlDown;
			if (ctrl && Gui.IsKeyPressed(Key.S, false))
			{
				if (Gui.IsShiftDown)
					SaveAll();
				else
					Save();
			}
			if (ctrl && Gui.IsKeyPressed(Key.O, false))
				OpenFileBrowser();
			if (ctrl && !Gui.IsShiftDown && !Gui.IsAltDown && Gui.IsKeyPressed(KeyX.W, false) && !Gui.igIsAnyItemActive())
				CloseActiveTab();
			// Ctrl+Tab / Ctrl+Shift+Tab: the list of open Sheets, most recent first; releasing Ctrl opens the
			// highlighted one (SheetSwitcher.bf).
			SheetSwitcherKeys(ctrl);
			// Ctrl+Page Down / Ctrl+Page Up: the next / previous Sheet tab of the type in front, in the bar's order;
			// with Shift: the next / previous open type (GraphTabs.bf).
			if (ctrl && !Gui.IsAltDown && !Gui.igIsAnyItemActive())
			{
				int dir = Gui.IsKeyPressed(Key.PageDown, true) ? 1 : (Gui.IsKeyPressed(Key.PageUp, true) ? -1 : 0);
				if (dir != 0 && Gui.IsShiftDown)
					CycleType(dir);
				else if (dir != 0 && Tabs.Count > 1)
					CycleSheetTab(dir);
			}
			// F7 Build (Ctrl+F7 Force Build), Shift+F7 Validate.
			if (Gui.IsKeyPressed(578 /* F7 */, false))
			{
				if (Gui.IsShiftDown && !ctrl)
					Validate();
				else
					Build(default, ctrl);
			}
			// F5 Start Debugging / Continue, Shift+F5 Stop, Ctrl+F5 Run Without Debugging.
			if (Gui.IsKeyPressed(576 /* F5 */, false) && !Gui.igIsAnyItemActive())
			{
				if (ctrl && !Gui.IsShiftDown)
					RunProgram();
				else if (Gui.IsShiftDown)
					Debug.Stop();
				else if (IsDebugStopped)
					Debug.Continue();
				else if (!IsDebugging)
					StartDebugging();
			}
			if (Gui.IsKeyPressed(572 /* F1 */, false))
				OpenDocumentation();
			if (ctrl && !Gui.IsShiftDown && Gui.IsKeyPressed(Key.B, false) && !Gui.igIsAnyItemActive())
				BrowseToCurrent();
			if (ctrl && Gui.IsShiftDown && Gui.IsKeyPressed(Key.F, false))
				OpenFindResults();
			if (ctrl && Gui.IsKeyPressed(Key.Space, false))
				ToggleProjectDrawer();
			if (!Gui.igIsAnyItemActive())
			{
				if (ctrl && Gui.IsKeyPressed(Key.Z, true))
				{
					if (Gui.IsShiftDown)
					{
						if (!RedoEntryChange()) // Set as entry point first (EntryPoint.bf)
							UndoDoc(true);
					}
					else if (!UndoEntryChange())
						UndoDoc(false);
					UpdateTitle();
				}
				if (ctrl && Gui.IsKeyPressed(Key.Y, true))
				{
					if (!RedoEntryChange())
						UndoDoc(true);
					UpdateTitle();
				}
			}
		}

		void OpenFolderPicker()
		{
			char8[4096] buf = default;
			let start = mProjectRoot.IsEmpty ? "" : mProjectRoot;
			int32 r = Host.th_native_dialog(1, scope String(start), &buf, 4096);
			if (r == 1)
			{
				RequestOpenProject(StringView(&buf));
				return;
			}
			if (r == 0)
				return;
			// No native dialog: fall back to the built-in one.
			mPathBuf.Set(mProjectRoot);
			mOpenFolderPopup = true;
		}

		void OpenFileBrowser()
		{
			{
				String start = scope .();
				if (!Doc.FilePath.IsEmpty)
					Path.GetDirectoryPath(Doc.FilePath, start).IgnoreError(); // a root has no parent: dir stays empty
				else
					start.Set(mProjectRoot);
				char8[4096] buf = default;
				int32 r = Host.th_native_dialog(0, start, &buf, 4096);
				if (r == 1)
				{
					OpenFile(StringView(&buf));
					return;
				}
				if (r == 0)
					return;
			}
			if (mBrowseDir.IsEmpty)
			{
				if (!Doc.FilePath.IsEmpty)
					Path.GetDirectoryPath(Doc.FilePath, mBrowseDir).IgnoreError(); // a root has no parent: browse dir stays empty and falls through
				else if (!mProjectRoot.IsEmpty)
					mBrowseDir.Set(mProjectRoot);
				else
					Directory.GetCurrentDirectory(mBrowseDir);
			}
			mPathBuf.Set(mBrowseDir);
			mOpenFilePopup = true;
		}

		/// Menu item with an icon in front.
		static bool IconItem(StringView icon, StringView label, StringView shortcut = "", bool selected = false, bool enabled = true)
		{
			String text = scope .();
			Icon.Label(text, icon, label);
			return Gui.MenuItem(text, shortcut, selected, enabled);
		}

		void DrawMainMenu()
		{
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(8 * Look.Scale, 6 * Look.Scale));
			bool open = Gui.igBeginMainMenuBar();
			Gui.igPopStyleVar(1);
			if (!open)
				return;
			// App mark at the start of the menu row.
			{
				let pos = Gui.igGetCursorScreenPos();
				float fs = Gui.igGetFontSize();
				Gui.DrawText(Gui.igGetWindowDrawList(), .(pos.x + 2, pos.y + (Gui.igGetFrameHeight() - fs * 1.2f) * 0.5f), Look.AccentBlue, Icon.Workflow, fs * 1.2f);
				Gui.igDummy(.(fs * 1.5f, 1));
				Gui.SameLine();
			}
			if (mSpFileMenu) // captures: the File menu open
			{
				mSpFileMenu = false;
				Gui.OpenPopup("File");
			}
			bool fileMenu = Gui.BeginMenu("File");
#if TREADLE_SELFTEST
			if (!fileMenu)
			{
				mFileMenuMin = Gui.igGetItemRectMin(); // the focus self test clicks it (SelfTestFocus.bf)
				mFileMenuMax = Gui.igGetItemRectMax();
			}
#endif
			if (fileMenu)
			{
				if (IconItem(Icon.Package, "New Project..."))
					StartNewProject();
				bool haveFolder = !mProjectRoot.IsEmpty && mCBTree != null;
				if (IconItem(Icon.Class, "New Class...", "", false, haveFolder))
					StartNewType(.Class, mCBFolder);
				if (IconItem(Icon.Function, "New Sheet...", "", false, Doc != null && Doc != mEmptyDoc))
				{
					mNameBuf.Set("Sheet");
					mOpenNewSheet = true;
				}
				if (IconItem(Icon.FolderPlus, "New Folder...", "", false, haveFolder))
					StartNewAsset(.Folder, mCBFolder);
				if (IconItem(Icon.FileCode, "Import C Headers", "", false, !mProjectRoot.IsEmpty)) ImportCHeaders(); // ImportHeader.bf
				Gui.Separator();
				if (IconItem(Icon.File, "Open File...", "Ctrl+O"))
					OpenFileBrowser();
				if (IconItem(Icon.FolderOpen, "Open Project Folder..."))
				{
					FileSafety.ReadOnlyProject = false;
					OpenFolderPicker();
				}
				if (IconItem(Icon.FolderLock, "Open Project (Read-only)..."))
				{
					FileSafety.ReadOnlyProject = true;
					OpenFolderPicker();
				}
				DrawOpenRecentMenu();
				if (IconItem(Icon.X, "Close Project", "", false, !mProjectRoot.IsEmpty))
					RequestCloseProject();
				Gui.Separator();
				if (IconItem(Icon.Lock, "Read-only (viewer) mode", "", FileSafety.ReadOnlyProject))
					FileSafety.ReadOnlyProject = !FileSafety.ReadOnlyProject;
				if (IconItem(Icon.History, "Keep .bak backup when saving", "", FileSafety.KeepBackup))
					FileSafety.KeepBackup = !FileSafety.KeepBackup;
				Gui.Separator();
				if (IconItem(Icon.Save, "Save", "Ctrl+S", false, Doc != mEmptyDoc))
					Save();
				if (IconItem(Icon.Save, "Save As...", "", false, Doc != mEmptyDoc))
					StartSaveAs();
				if (IconItem(Icon.SaveAll, "Save All", "Ctrl+Shift+S", false, ModifiedCount > 0))
					SaveAll();
				if (IconItem(Icon.RotateCcw, "Reload From Disk", "", false, !Doc.FilePath.IsEmpty))
					ReloadFromDisk();
				Gui.Separator();
				if (IconItem(Icon.LogOut, "Exit"))
					RequestQuit();
				Gui.EndMenu();
			}
			if (Gui.BeginMenu("Edit"))
			{
				if (IconItem(Icon.Undo2, "Undo", "Ctrl+Z", false, EditDoc.CanUndo || mEntryChange != null) && !UndoEntryChange())
					UndoDoc(false);
				if (IconItem(Icon.Redo2, "Redo", "Ctrl+Y", false, EditDoc.CanRedo || mEntryChange != null) && !RedoEntryChange())
					UndoDoc(true);
				Gui.Separator();
				let tab = CurrentTab;
				if (IconItem(Icon.Copy, "Copy", "Ctrl+C", false, tab != null))
					CopySelection(tab);
				if (IconItem(Icon.Clipboard, "Paste", "Ctrl+V", false, tab != null && mClipboard != null))
					Paste(tab, ViewCentre(tab));
				if (IconItem(Icon.CopyPlus, "Duplicate", "Ctrl+D", false, tab != null))
					DuplicateSelection(tab);
				if (IconItem(Icon.Trash2, "Delete", "Del", false, tab != null))
					DeleteSelection(tab);
				Gui.Separator();
				if (IconItem(Icon.Find, "Find in Sheets", "Ctrl+Shift+F", false, !mProjectRoot.IsEmpty))
					OpenFindResults();
				Gui.Separator();
				if (IconItem(Icon.Settings, "Editor Preferences..."))
					OpenPreferences();
				Gui.EndMenu();
			}
			if (Gui.BeginMenu("Graph"))
			{
				let tab = CurrentTab;
				bool haveGraph = tab != null && CurrentMethod != null;
				if (IconItem(Icon.Arrange, "Auto-Arrange (layered)", "", false, haveGraph))
					ArrangeCurrentGraph();
				if (Gui.BeginMenu(scope $"{Icon.AlignStartVertical}  Alignment", haveGraph))
				{
					DrawAlignItems(tab);
					Gui.EndMenu();
				}
				Gui.Separator();
				if (IconItem(Icon.Minimap, "Minimap", "M", Prefs.ShowMinimap, haveGraph))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
				if (IconItem(Icon.Magnet, "Snap to Grid", "", Prefs.GridSnap))
				{
					Prefs.GridSnap = !Prefs.GridSnap;
					Prefs.Save();
				}
				Gui.EndMenu();
			}
			DrawBuildMenu();
			DrawDebugMenu();
			if (Gui.BeginMenu("Window"))
			{
				if (IconItem(Icon.FolderOpen, "Project Drawer", "Ctrl+Space", mCBDrawerOpen))
					ToggleProjectDrawer();
				if (IconItem(Icon.Log, "Output Log", "", ShowOutputLog))
				{
					ShowOutputLog = !ShowOutputLog;
					mFocusOutputLog = ShowOutputLog;
				}
				if (IconItem(Icon.CircleX, "Problems", "", ShowCompilerResults))
					ShowCompilerResults = !ShowCompilerResults;
				if (IconItem(Icon.Find, "Find Results", "", ShowFindResults))
					ShowFindResults = !ShowFindResults;
				DrawHoodMenuItems(false); // Memory, Disassembly: DisassemblyPanel.bf
				if (IconItem(Icon.Minimap, "Graph Minimap", "M", Prefs.ShowMinimap, CurrentTab != null))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
				mGraphPanel.DrawViewsMenu(CurrentTab);
				DrawOpenSheetsMenu();
				Gui.Separator();
				if (IconItem(Icon.LayoutGrid, "Reset Layout"))
				{
					mLayoutVersion = 0;
					mDockBuilt = false;
				}
				// A black or frozen window after sleep, a lock or a display change: a new drawing context (GraphicsDevice.bf).
				if (IconItem(Icon.RefreshCw, "Restore Graphics", "Ctrl+Alt+R"))
					RestoreGraphics("Window > Restore Graphics");
				Gui.EndMenu();
			}
			if (Gui.BeginMenu("Help"))
			{
				if (IconItem(Icon.BookOpen, "Documentation", "F1"))
					OpenDocumentation();
				if (IconItem(Icon.Bug, "Report a Problem..."))
					OpenReportProblem();
				Gui.Separator();
				Gui.TextDisabled("Graph");
				Gui.Text("Right-click the graph: add nodes (type to search).");
				Gui.Text("Drag from a pin into empty space: add a connected node.");
				Gui.Text("Alt+click a pin or wire to break it.  Double-click a call to open its Sheet.");
				Gui.Text("Shift+W/S/A/D: align top/bottom/left/right.  Q: straighten.  M: minimap.");
				Gui.Text("Del: delete   Ctrl+C/V/D: copy/paste/duplicate   F: frame   Home: entry   Ctrl+1..9 / 1..9: save / go to view");
				Gui.TextDisabled("Editor");
				Gui.Text("F7: build   Shift+F7: validate   Ctrl+S: save   Ctrl+B: browse   Ctrl+Shift+F: find in Sheets");
				Gui.Text("Project Browser: double-click to open, F2 rename, Del delete, drag onto a folder to move.");
				Gui.Text("Ctrl+Space: Project Drawer.");
				Gui.Separator();
				bool updatesBusy = mUpdates == null || mUpdates.Busy;
				// A known new version reads "Update to X..." and runs the update flow; otherwise a check.
				bool offered = UpdateIsOffered;
				String updateLabel = scope .();
				if (offered)
					updateLabel.AppendF("Update to {}...", mUpdateView.LatestVersion);
				else
					updateLabel.Set("Check for Updates...");
				if (IconItem(Icon.ArrowDownToLine, updateLabel, "", false, offered || !updatesBusy))
				{
					if (offered)
						UpdateFromMenu();
					else
						CheckForUpdatesNow();
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(offered ? "Download and install the new release (Editor Preferences > Updates shows the progress)" : "Look for a new release now (Editor Preferences > Updates has the settings)");
				if (IconItem(Icon.Info, "About Treadle"))
					mShowAbout = true;
				Gui.Separator();
				Gui.MenuItem("Show ImGui Demo", "", mShowDemo);
				if (Gui.igIsItemClicked(0))
					mShowDemo = !mShowDemo;
				Gui.EndMenu();
			}
			// Project name and window controls share the title row (see TitleBar.bf).
			DrawTitleBarExtras();
			Gui.igEndMainMenuBar();
		}

		bool mDockBuilt;
		void SetupDockspace()
		{
			let viewport = Gui.igGetMainViewport();
			uint32 dockId = Gui.igGetID_Str("VBDock");
			if (!mDockBuilt)
			{
				mDockBuilt = true;
				if (Gui.igDockBuilderGetNode(dockId) == null || mLayoutVersion < cLayoutVersion)
				{
					// Default layout: Outline left, Properties right, the graph in the middle, Project
					// Browser / Output Log / Problems / Find Results tabbed along the bottom.
					mLayoutVersion = cLayoutVersion;
					mFocusCBFrames = 12;
					SaveSettings();
					Gui.igDockBuilderRemoveNode(dockId);
					Gui.igDockBuilderAddNode(dockId, 1 << 10);
					Gui.igDockBuilderSetNodeSize(dockId, viewport.WorkSize);
					uint32 left = 0;
					uint32 rest = 0;
					Gui.igDockBuilderSplitNode(dockId, Dir.Left, 0.18f, &left, &rest);
					uint32 right = 0;
					uint32 center = 0;
					Gui.igDockBuilderSplitNode(rest, Dir.Right, 0.24f, &right, &center);
					uint32 bottom = 0;
					uint32 graph = 0;
					Gui.igDockBuilderSplitNode(center, Dir.Down, BottomDockRatio(), &bottom, &graph);
					mBottomDockNode = bottom;
					SaveSettings();
					Gui.igDockBuilderDockWindow(Panels.OutlineId, left);
					Gui.igDockBuilderDockWindow(Panels.PropertiesId, right);
					Gui.igDockBuilderDockWindow(Panels.LocalsId, right);
					Gui.igDockBuilderDockWindow(Panels.CallStackId, right);
					Gui.igDockBuilderDockWindow(HoodPanels.MemoryId, bottom); Gui.igDockBuilderDockWindow(HoodPanels.DisassemblyId, graph); // MemoryPanel.bf
					Gui.igDockBuilderDockWindow(Panels.DebugOutputId, bottom);
					Gui.igDockBuilderDockWindow(Panels.ProjectBrowserId, bottom);
					Gui.igDockBuilderDockWindow(Panels.OutputLogId, bottom);
					Gui.igDockBuilderDockWindow(Panels.CompilerResultsId, bottom);
					Gui.igDockBuilderDockWindow(Panels.FindResultsId, bottom);
					Gui.igDockBuilderDockWindow(Panels.GraphId, graph);
					Gui.igDockBuilderFinish(dockId);
				}
			}
			// No ImGui dock-node menu triangle or node close button on any panel.
			Gui.igDockSpaceOverViewport(dockId, viewport, DockNodeFlagsX.NoWindowMenuButton | DockNodeFlagsX.NoCloseButton, null);
		}

		// ------------------------------------------------------------------ panels

		void AddMemberRef(MemberRef.Kind kind, StringView name, StringView type, StringView paramsText, StringView owner, bool isStatic)
		{
			MemberRef r = new .();
			r.MemberKind = kind;
			r.Name.Set(name);
			r.Type.Set(type);
			r.Params.Set(paramsText);
			r.Owner.Set(owner);
			r.IsStatic = isStatic;
			mMembers.Add(r);
		}

		void DrawGraphArea()
		{
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			// The graph tabs are the document tabs; the dock node's own "Graph" tab only shows
			// when another panel is docked with it.
			ImGuiWindowClass graphClass = .();
			graphClass.DockNodeFlagsOverrideSet = DockNodeFlagsX.AutoHideTabBar;
			Gui.igSetNextWindowClass(&graphClass);
			if (Gui.Begin(Panels.Graph, null, WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse))
			{
				Gui.igPopStyleVar(1);
				DrawFormatNotice();
				// One type in front (docs/Editor-Model.md, "Type context"): the type strip lists the open types,
				// the Sheet tabs under it are those of the type in front only (GraphTabs.bf).
				ApplyTabCloses();
				SyncTypeContexts(true);
				DrawTypeStrip();
				let typeCtx = FindTypeContext(Doc);
				DrawnSheetTabs = 0;
				bool anySheet = false;
				for (let t in Tabs)
					if (t.Doc == Doc)
						anySheet = true;
				if (!anySheet)
				{
					if (typeCtx != null)
						DrawDocumentHeader(null, null);
					Gui.igSetCursorPos(.(20, Gui.igGetCursorPos().y + 20));
					Gui.igPushTextWrapPos(Gui.igGetWindowWidth() - 20);
					if (Doc.FilePath.IsEmpty && mProjectRoot.IsEmpty && typeCtx == null)
						Gui.TextDisabled("Open a project folder or a type file (File menu, the Project Browser, or drop it on the window).");
					else if (typeCtx == null)
						Gui.TextDisabled("Double-click a type in the Project Browser to open it, or add one with + Add > New Class (New Struct, New Enum, ...).");
					else
						Gui.TextDisabled("No Sheet of this type is open: pick one in the Outline, or add one with its + button.");
					Gui.igPopTextWrapPos();
				}
				else if (Gui.igBeginTabBar(scope $"##graphs{typeCtx?.Uid ?? 0}", 1 << 0 /* Reorderable */))
				{
					for (int i = 0; i < Tabs.Count; i++)
					{
						let tab = Tabs[i];
						if (tab.Doc != Doc)
							continue;
						let mg = tab.Doc.FindSheet(tab.MethodKey);
						if (mg == null || !mg.Graphable)
						{
							// The Sheet was removed.
							Tabs.RemoveAt(i);
							delete tab;
							if (i < ActiveTab)
								ActiveTab--;
							if (ActiveTab >= Tabs.Count)
								ActiveTab = Tabs.Count - 1;
							i--;
							continue;
						}
						int32 flags = 0;
						if (mSelectTab == tab)
						{
							flags |= TabItemFlags.SetSelected;
							mSelectTab = null;
						}
						String label = scope .();
						label.AppendF("{}  {}{}###graphtab{}", Icon.Function, tab.Title, tab.Doc.Modified ? " *" : "", tab.Uid);
						bool open = true;
						bool tabShown = Gui.igBeginTabItem(label, &open, flags);
						DrawnSheetTabs++;
						TabItemInput(tab);
						if (tabShown)
						{
							ActiveTab = i;
							if (tab != mLastActiveTab)
							{
								// Switching tabs switches the side panels to that tab's file.
								mLastActiveTab = tab;
								Doc = tab.Doc;
							}
							if (typeCtx != null)
								typeCtx.ActiveTabUid = tab.Uid;
							DrawDocumentHeader(tab, mg);
							mGraphPanel.Draw(tab, mg);
							Gui.igEndTabItem();
						}
						if (!open)
						{
							if (mLastActiveTab == tab)
								mLastActiveTab = null;
							Tabs.RemoveAt(i);
							delete tab;
							if (i < ActiveTab)
								ActiveTab--;
							if (ActiveTab >= Tabs.Count)
								ActiveTab = Tabs.Count - 1;
							i--;
						}
					}
					DrawTabMenu();
					Gui.igEndTabBar();
				}
			}
			else
				Gui.igPopStyleVar(1);
			Gui.End();
		}

		/// A Sheet's name as its tab shows it.
		static void AppendSheetName(String into, Sheet mg)
		{
			into.Append(mg.Name);
			if (mg.Role == .Lambda)
				into.AppendF(" {}", mg.LambdaNode);
		}

		// ------------------------------------------------------------------ popups

		public void RequestQuit()
		{
			if (ModifiedCount > 0)
				mShowQuitModal = true;
			else
				QuitNow = true;
		}

		void DrawPopups()
		{
			// Node menu
			let chosen = mNodeMenu.Draw();
			if (chosen != null)
			{
				ExecuteAction(chosen);
				delete chosen;
			}

			// Node context menu
			if (mOpenNodeContext)
			{
				Gui.OpenPopup("##nodectx");
				mOpenNodeContext = false;
			}
			if (mGraphPanel.SelfTestPopupPos.x > -1e30f)
				Gui.igSetNextWindowPos(mGraphPanel.SelfTestPopupPos, Cond.Appearing, .(0, 0));
			if (Gui.BeginPopup("##nodectx"))
			{
				let mg = CurrentMethod;
				let node = (mg != null) ? mg.Graph.FindNode(mContextNode) : null;
				if (node == null)
					Gui.igCloseCurrentPopup();
				else
				{
					String title = scope .();
					node.GetTitle(title);
					Gui.TextDisabled(title);
					Gui.Separator();
					bool fixedNode = node == mg.Graph.Entry;
					if (!fixedNode && Gui.MenuItem("Delete", "Del"))
						DeleteSelection(CurrentTab);
					if (Gui.MenuItem("Break All Links"))
					{
						BeginEdit();
						for (let p in node.Inputs)
							mg.Graph.DisconnectPin(p);
						for (let p in node.Outputs)
							mg.Graph.DisconnectPin(p);
						CommitCurrent();
					}
					if (!fixedNode && Gui.MenuItem("Copy", "Ctrl+C"))
						CopySelection(CurrentTab);
					if (!fixedNode && Gui.MenuItem("Duplicate", "Ctrl+D"))
						DuplicateSelection(CurrentTab);
					if (Gui.MenuItem("Create Comment from Selection", "C"))
						mGraphPanel.CreateComment(CurrentTab, mg.Graph);
					if (!fixedNode && mg.Role != .Lambda)
					{
						if (Gui.MenuItem("Extract to Function", "Ctrl+Shift+E"))
							ExtractToFunction(CurrentTab);
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip("The selected nodes become a new function of this type and a Call of it takes their place");
					}
					if (!fixedNode)
					{
						if (Gui.MenuItem("Collapse Nodes", "Ctrl+G"))
							CollapseSelectionToGroup(CurrentTab);
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip("The selected nodes fold into one group node, with a pin for each wire in or out; double-click it to open it");
					}
					if (node.IsExecNode && node != mg.Graph.Entry && Gui.MenuItem((node.Comment != null && !node.Comment.IsEmpty) ? "Edit Comment" : "Add Comment"))
						mGraphPanel.BeginBubbleEdit(node.Id);
					if (node.Kind == .Call && Gui.MenuItem("Go To Sheet"))
						NodeDoubleClicked(node);
					if (node.Kind == .Call && IsVariadicCall(node) && Gui.MenuItem("Add Argument Pin"))
						AddArgument(node);
					if ((node.Kind == .Sequence || node.Kind == .MultiGate || node.Kind == .Switch) && Gui.MenuItem((node.Kind == .Switch) ? "Add Case" : "Add Pin", "", false, CanAddExecPin(node)))
						AddExecPin(node);
					if ((node.Kind == .Get || node.Kind == .Set || node.Kind == .Call || node == mg.Graph.Entry) && Gui.MenuItem("Rename...", "F2"))
						RenameSelection(CurrentTab);
					// "Collapse" in other node editors folds nodes into a sub-graph; this only hides pins.
					bool collapsed = mGraphPanel.IsCollapsed(CurrentTab, node);
					if (Gui.MenuItem(collapsed ? "Show All Pins" : "Hide Unwired Pins"))
						mGraphPanel.SetCollapsed(CurrentTab, node, !collapsed);
					if (!fixedNode && Gui.MenuItem(node.Disabled ? "Enable Node" : "Disable Node"))
						ToggleDisabled(CurrentTab);
					if (!fixedNode && Gui.igIsItemHovered(0))
						Gui.Tooltip("A disabled node stays in the file and is skipped when compiling");
					if ((node.Kind == .Construct || node.Kind == .Local) && Gui.MenuItem((node.Kind == .Local) ? "Change to Construct (heap)" : "Change to Local (this region)"))
					{
						BeginEdit();
						NodeFactory.SetLifetime(mg.Graph, node, node.Kind == .Construct);
						CommitCurrent();
					}
				}
				Gui.EndPopup();
			}

			DrawFileBrowser();
			DrawFolderPopup();
			DrawNewSheetPopup();
			DrawRenameSheetPopup();
			DrawSaveAsPopup();
			DrawProjectBrowserPopups();
			DrawReportProblem();
			DrawModals();
		}

		void DrawFileBrowser()
		{
			if (mOpenFilePopup)
			{
				Gui.OpenPopup("Open Document");
				mOpenFilePopup = false;
			}
			Gui.igSetNextWindowSize(.(640, 480), Cond.Appearing);
			if (Gui.igBeginPopupModal("Open Document", null, 0))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text(scope $"Path (a {GraphExtension} file or a folder):");
				Gui.igSetNextItemWidth(-90);
				bool enter = Gui.igInputText("##path", mPathBuf.Ptr, (.)mPathBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				Gui.SameLine();
				bool openClicked = Gui.Button("Open", .(80 * Look.Scale, 0));
				String typed = scope .(mPathBuf.View);
				if (enter || openClicked)
				{
					if (File.Exists(typed) && IsGraphFile(typed))
					{
						Gui.igCloseCurrentPopup();
						RequestOpen(typed);
					}
					else if (Directory.Exists(typed))
						mBrowseDir.Set(typed);
				}
				if (Directory.Exists(typed) && typed != mBrowseDir)
					mBrowseDir.Set(typed);

				Gui.Separator();
				if (Gui.igBeginChild_Str("##entries", .(0, -40), ChildFlags.Borders, 0))
				{
					if (Gui.Selectable(".. (up)"))
					{
						String parent = scope .();
						Path.GetDirectoryPath(mBrowseDir, parent).IgnoreError(); // a root has no parent: parent stays empty and is checked below
						if (!parent.IsEmpty)
						{
							mBrowseDir.Set(parent);
							mPathBuf.Set(parent);
						}
					}
					if (Directory.Exists(mBrowseDir))
					{
						List<String> dirs = scope .();
						List<String> files = scope .();
						for (let e in Directory.EnumerateDirectories(mBrowseDir))
						{
							String p = new .();
							e.GetFilePath(p);
							dirs.Add(p);
						}
						for (let e in Directory.EnumerateFiles(mBrowseDir))
						{
							String p = new .();
							e.GetFilePath(p);
							if (IsGraphFile(p))
								files.Add(p);
							else
								delete p;
						}
						dirs.Sort(scope (a, b) => String.Compare(a, b, true));
						files.Sort(scope (a, b) => String.Compare(a, b, true));
						for (let d in dirs)
						{
							String name = scope .();
							Path.GetFileName(d, name);
							if (Gui.Selectable(scope $"[dir] {name}"))
							{
								mBrowseDir.Set(d);
								mPathBuf.Set(d);
							}
						}
						for (let f in files)
						{
							String name = scope .();
							Path.GetFileName(f, name);
							if (Gui.Selectable(scope $"      {name}", false, SelectableFlags.AllowDoubleClick))
							{
								mPathBuf.Set(f);
								if (Gui.igIsMouseDoubleClicked_Nil(0))
								{
									Gui.igCloseCurrentPopup();
									RequestOpen(scope String(f));
								}
							}
						}
						ClearAndDeleteItems!(dirs);
						ClearAndDeleteItems!(files);
					}
					Gui.igEndChild();
				}
				if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.SameLine();
				Gui.TextDisabled("Tip: you can also drop a type file onto the window.");
				Gui.EndPopup();
			}
		}

		void DrawFolderPopup()
		{
			if (mOpenFolderPopup)
			{
				Gui.OpenPopup("Open Folder");
				mOpenFolderPopup = false;
			}
			if (Gui.igBeginPopupModal("Open Folder", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text("Folder to show in the Project Browser:");
				Gui.igSetNextItemWidth(520 * Look.Scale);
				bool enter = Gui.igInputText("##folder", mPathBuf.Ptr, (.)mPathBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (Gui.Button("Open", .(100 * Look.Scale, 0)) || enter)
				{
					String dir = scope .(mPathBuf.View);
					if (Directory.Exists(dir))
					{
						RequestOpenProject(dir);
						Gui.igCloseCurrentPopup();
					}
					else
						SetStatus("That folder doesn't exist");
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
		}

		/// A small modal asking for one name. Returns true when the name was accepted (Enter / OK).
		bool NamePopup(StringView title, StringView prompt, String outName)
		{
			bool accepted = false;
			if (Gui.igBeginPopupModal(scope String(title), null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text(prompt);
				Gui.igSetNextItemWidth(360 * Look.Scale);
				bool enter = Gui.igInputText("##name", mNameBuf.Ptr, (.)mNameBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				var typed = mNameBuf.View;
				typed.Trim();
				Gui.igBeginDisabled(typed.IsEmpty);
				bool ok = Gui.Button("OK", .(120 * Look.Scale, 0));
				Gui.igEndDisabled();
				if ((ok || enter) && !typed.IsEmpty)
				{
					outName.Set(typed);
					accepted = true;
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
			return accepted;
		}

		void DrawNewSheetPopup()
		{
			if (mOpenNewSheet)
			{
				mOpenNewSheet = false;
				Gui.OpenPopup("New Sheet");
			}
			String name = scope .();
			if (NamePopup("New Sheet", "Name of the new Sheet:", name))
				AddSheet(name);
		}

		/// Outline: rename the Sheet `key` of the current document.
		public void StartRenameSheet(Sheet s)
		{
			mRenameSheetKey.Set(s.Key);
			mNameBuf.Set(s.Name);
			mOpenRenameSheet = true;
		}

		void DrawRenameSheetPopup()
		{
			if (mOpenRenameSheet)
			{
				mOpenRenameSheet = false;
				Gui.OpenPopup("Rename Sheet");
			}
			String name = scope .();
			if (NamePopup("Rename Sheet", "New name of the Sheet:", name))
			{
				let s = Doc.FindSheet(mRenameSheetKey);
				if (s != null)
					RenameSheet(s, name);
			}
		}

		void DrawModals()
		{
			DrawRecoveryModal();
			if (mShowQuitModal)
			{
				Gui.OpenPopup("Unsaved Changes##quit");
				mShowQuitModal = false;
			}
			if (Gui.igBeginPopupModal("Unsaved Changes##quit", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text("These files have unsaved changes:");
				for (let d in mDocs)
				{
					if (!d.NeedsSave)
						continue;
					String name = scope .();
					Path.GetFileName(d.FilePath, name);
					Gui.TextColored(Theme.Warning, scope $"   {name}");
				}
				Gui.igSpacing();
				if (Gui.Button("Save All", .(100 * Look.Scale, 0)))
				{
					// Quit only when everything was written; a conflict keeps the editor open.
					if (SaveAll())
						QuitNow = true;
					else
						Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Don't Save", .(100 * Look.Scale, 0)))
					QuitNow = true;
				Gui.SameLine();
				if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}

			DrawSafetyModals();

			TypeDocument changed = null;
			for (let d in mDocs)
				if (d.ExternalChange)
					changed = d;
			if (changed != null)
			{
				Gui.igSetNextWindowPos(.(Gui.igGetMainViewport().WorkPos.x + 20, Gui.igGetMainViewport().WorkPos.y + 30), Cond.Always, .(0, 0));
				if (Gui.Begin("##extchange", null, WindowFlags.AlwaysAutoResize | WindowFlags.NoTitleBar | WindowFlags.NoDocking | WindowFlags.NoSavedSettings))
				{
					String name = scope .();
					Path.GetFileName(changed.FilePath, name);
					Gui.TextColored(Theme.Warning, scope $"{name} changed on disk while you have unsaved edits to it.");
					if (Gui.Button("Reload (lose my edits)"))
						ReloadFromDisk(changed);
					Gui.SameLine();
					if (Gui.Button("Keep mine"))
					{
						changed.ExternalChange = false;
						changed.MarkSavedFromDisk();
						changed.Modified = true;
					}
				}
				Gui.End();
			}
		}

		/// Save-conflict and error dialogs.
		void DrawSafetyModals()
		{
			for (int i = mConflicts.Count - 1; i >= 0; i--)
				if (!mDocs.Contains(mConflicts[i]))
					mConflicts.RemoveAt(i);
			if (!mConflicts.IsEmpty && !Gui.igIsPopupOpen_Str("File Changed on Disk##conflict", 0) && mErrors.IsEmpty)
				Gui.OpenPopup("File Changed on Disk##conflict");
			if (Gui.igBeginPopupModal("File Changed on Disk##conflict", null, WindowFlags.AlwaysAutoResize))
			{
				if (mConflicts.IsEmpty)
					Gui.igCloseCurrentPopup();
				else
				{
					let d = mConflicts[0];
					Gui.Text("This file was changed outside Treadle after you opened it:");
					Gui.TextColored(Theme.Warning, scope $"   {d.FilePath}");
					Gui.Text("Saving now would overwrite those changes.");
					Gui.igSpacing();
					if (Gui.Button("Overwrite", .(110 * Look.Scale, 0)))
					{
						mConflicts.RemoveAt(0);
						if (SaveDoc(d, true))
							SetStatus(scope $"Saved {d.FilePath} (overwrote the disk version)");
					}
					Gui.SameLine();
					if (Gui.Button("Reload", .(110 * Look.Scale, 0)))
					{
						mConflicts.RemoveAt(0);
						ReloadFromDisk(d);
					}
					Gui.SameLine();
					if (Gui.Button("Cancel", .(110 * Look.Scale, 0)))
						mConflicts.RemoveAt(0);
					Gui.igSpacing();
					Gui.TextDisabled("Overwrite keeps your version (the disk version goes to the .bak file). Reload discards your edits.");
				}
				Gui.EndPopup();
			}

			if (!mErrors.IsEmpty && !Gui.igIsPopupOpen_Str("Something went wrong##vberror", 0))
				Gui.OpenPopup("Something went wrong##vberror");
			if (Gui.igBeginPopupModal("Something went wrong##vberror", null, WindowFlags.AlwaysAutoResize))
			{
				if (mErrors.IsEmpty)
					Gui.igCloseCurrentPopup();
				else
				{
					Gui.TextColored(Theme.Warning, mErrors[0]);
					Gui.igSpacing();
					if (Gui.Button("OK", .(100 * Look.Scale, 0)) || Gui.IsKeyPressed(Key.Escape, false) || Gui.IsKeyPressed(Key.Enter, false))
					{
						delete mErrors[0];
						mErrors.RemoveAt(0);
						if (mErrors.IsEmpty)
							Gui.igCloseCurrentPopup();
					}
				}
				Gui.EndPopup();
			}
		}

		public void OnFileDropped(StringView path)
		{
			if (IsGraphFile(path))
				RequestOpen(path);
			else if (Directory.Exists(path))
				RequestOpenProject(path);
		}

	}
}
