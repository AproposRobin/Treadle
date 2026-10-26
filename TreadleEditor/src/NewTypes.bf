using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Making types (Editor-Model.md, "Making a type"): the Project Browser's New Class, New Struct, New
	/// Enum, New Interface, New Delegate and New Extension entries, Make Child Class and Duplicate. Each
	/// opens the Create Type dialog: the kind's icon and title, the folder,
	/// the name (proposed, selected), the file and namespace it makes, and for a class or a struct the
	/// Base Class and Interfaces dropdowns. Create writes the file from the kind's template and opens
	/// its first view.
	extension EditorApp
	{
		bool mOpenNewType;
		TypeKind mNtKind;
		String mNtFolder = new .() ~ delete _;
		TextBuffer mNtName = new .(256) ~ delete _;
		String mNtBase = new .() ~ delete _;
		List<String> mNtInterfaces = new .() ~ DeleteContainerAndItems!(_);
		/// Duplicate: the type file copied (empty: a new type from its template).
		String mNtSource = new .() ~ delete _;
		/// Make Child Class: the class the new one derives from (shown in the title).
		String mNtParent = new .() ~ delete _;
		bool mNtRefocus;
		/// Self tests: close the Create Type dialog on its next frame.
		public bool mNtCloseRequest;
		/// Captures: open the + Add menu on the next frame (SelfTestNewType.bf, `addmenu`).
		public bool mSpAddMenu;
		String mNtNsFolder = new .() ~ delete _;
		String mNtNs = new .() ~ delete _;

		public static StringView KindIcon(TypeKind kind)
		{
			switch (kind)
			{
			case .Class: return Icon.Class;
			case .Struct: return Icon.Struct;
			case .Enum: return Icon.Enum;
			case .Interface: return Icon.Interface;
			case .Delegate: return Icon.Link;
			case .Extension: return Icon.Plug;
			}
		}

		public static StringView KindTitle(TypeKind kind)
		{
			switch (kind)
			{
			case .Class: return "Class";
			case .Struct: return "Struct";
			case .Enum: return "Enum";
			case .Interface: return "Interface";
			case .Delegate: return "Delegate";
			case .Extension: return "Extension";
			}
		}

		public static uint32 KindColor(TypeKind kind)
		{
			switch (kind)
			{
			case .Class: return Gui.Color(45, 115, 225);
			case .Struct: return Gui.Color(40, 150, 200);
			case .Enum: return Gui.Color(30, 170, 150);
			case .Interface: return Gui.Color(150, 110, 220);
			case .Delegate: return Gui.Color(220, 140, 60);
			case .Extension: return Gui.Color(120, 160, 90);
			}
		}

		/// The project type whose file is `path`, else null.
		public ProjectType ProjectTypeAt(StringView path)
		{
			RefreshProjectTypes();
			for (let t in ProjectTypes.Types)
				if (ProjectIndex.SamePath(t.Path, path))
					return t;
			return null;
		}

		/// New Class, New Struct, ...: the Create Type dialog for `kind` in `folder`, the name proposed
		/// (`NewClass`, `NewClass1`... the first free one, or `proposed`), `baseType` pre-set.
		public void StartNewType(TypeKind kind, StringView folderIn, StringView baseType = "", StringView proposed = "")
		{
			if (!CheckWritable())
				return;
			StringView folder = folderIn.IsEmpty ? (mCBFolder.IsEmpty ? (StringView)mProjectRoot : (StringView)mCBFolder) : folderIn;
			if (folder.IsEmpty)
			{
				SetStatus("Open a project folder first (File > Open Project Folder)", .Info);
				return;
			}
			mNtKind = kind;
			mNtFolder.Set(folder);
			mNtBase.Set(baseType);
			ClearAndDeleteItems!(mNtInterfaces);
			mNtSource.Clear();
			mNtParent.Set(baseType);
			ProposeName(proposed.IsEmpty ? TypeDocument.TemplateName(kind) : proposed);
			mNtNsFolder.Clear();
			mOpenNewType = true;
		}

		/// Make Child Class (a class tile, the Outline's type header): a new class in the same folder
		/// whose base is that class, named `<Name>Child`.
		public void StartMakeChild(StringView path)
		{
			let t = ProjectTypeAt(path);
			if (t == null || t.Kind != .Class || t.Static || t.Sealed)
			{
				SetStatus("Only a class that is not sealed or static can have a child class", .Info);
				return;
			}
			String folder = scope .();
			Path.GetDirectoryPath(path, folder).IgnoreError();
			StartNewType(.Class, folder, t.FullName, scope $"{t.Name}Child");
		}

		/// Duplicate (any type tile): a copy of the type file under a new name (`<Name>2`), its
		/// members and Sheets included, opened.
		public void StartDuplicate(StringView path)
		{
			if (!CheckWritable())
				return;
			let t = ProjectTypeAt(path);
			String name = scope .();
			if (t != null)
				name.Set(t.Name);
			else
				Path.GetFileNameWithoutExtension(path, name);
			mNtKind = (t != null) ? t.Kind : .Class;
			mNtFolder.Clear();
			Path.GetDirectoryPath(path, mNtFolder).IgnoreError();
			mNtBase.Clear();
			mNtParent.Clear();
			ClearAndDeleteItems!(mNtInterfaces);
			mNtSource.Set(path);
			ProposeName(scope $"{name}2");
			mNtNsFolder.Clear();
			mOpenNewType = true;
		}

		/// `baseName`, else `baseName1`, `baseName2`... the first with no file in the folder.
		void ProposeName(StringView baseName)
		{
			String name = scope .(baseName);
			for (int n = 1; n < 100 && File.Exists(TypePathIn(mNtFolder, name, .. scope String())); n++)
			{
				name.Set(baseName);
				name.AppendF("{}", n);
			}
			mNtName.Set(name);
		}

		void TypePathIn(StringView folder, StringView name, String outPath)
		{
			JoinPath(folder, name, outPath);
			outPath.Append(GraphExtension);
		}

		/// A type name: a letter or `_` first, then letters, digits and `_`; no file of that name in the
		/// folder; no project type of that full name.
		public bool ValidateTypeName(StringView folder, StringView name, StringView ns, String outError)
		{
			if (name.IsEmpty)
			{
				outError.Set("Enter a name.");
				return false;
			}
			if (!(name[0].IsLetter || name[0] == '_'))
			{
				outError.Set("A type name starts with a letter or _.");
				return false;
			}
			for (let c in name.RawChars)
				if (!(c.IsLetterOrDigit || c == '_'))
				{
					outError.Set(scope $"A type name is letters, digits and _ only (not '{c}').");
					return false;
				}
			if (File.Exists(TypePathIn(folder, name, .. scope String())) || EntryExists(folder, scope $"{name}{GraphExtension}"))
			{
				outError.Set(scope $"{name}{GraphExtension} exists in this folder already.");
				return false;
			}
			String full = scope .();
			if (!ns.IsEmpty)
				full.AppendF("{}.", ns);
			full.Append(name);
			if (ProjectTypes.Find(full) != null)
			{
				outError.Set(scope $"The project has a type {full} already.");
				return false;
			}
			return true;
		}

		/// The Create Type dialog (one for every kind, Duplicate and Make Child Class).
		void DrawNewTypePopup()
		{
			if (mOpenNewType)
			{
				mOpenNewType = false;
				Gui.OpenPopup("Create Type");
			}
			if (!Gui.igBeginPopupModal("Create Type", null, WindowFlags.AlwaysAutoResize))
				return;
			mCBModalOpen = true;
			if (Gui.IsKeyPressed(Key.Escape, false) || mNtCloseRequest)
				{ mNtCloseRequest = false; Gui.igCloseCurrentPopup(); }
			bool dup = !mNtSource.IsEmpty;
			// Header: the kind's icon, "New Class" (or "Duplicate Dog", "Child Class of Animal"), the folder.
			{
				let p = Gui.igGetCursorScreenPos();
				float s = Gui.igGetFrameHeight() * 1.6f;
				Gui.igDummy(.(s, s));
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + s, p.y + s), Theme.WithAlpha(KindColor(mNtKind), 60), 6 * Look.Scale, 0);
				let gs = Gui.CalcTextSize(KindIcon(mNtKind));
				Gui.DrawText(dl, .(p.x + (s - gs.x) * 0.5f, p.y + (s - gs.y) * 0.5f), KindColor(mNtKind), KindIcon(mNtKind));
				Gui.SameLine();
				Gui.igBeginGroup();
				String title = scope .();
				if (dup)
					title.AppendF("Duplicate {}", Path.GetFileNameWithoutExtension(mNtSource, .. scope String()));
				else if (!mNtParent.IsEmpty)
					title.AppendF("New Child Class of {}", mNtParent);
				else
					title.AppendF("New {}", KindTitle(mNtKind));
				Gui.Text(title);
				String rel = scope .();
				RelativeToRoot(mNtFolder, rel);
				Gui.TextDisabled(scope $"in {rel}");
				Gui.igEndGroup();
			}
			Gui.igSpacing();
			Gui.Text("Type name (also the file name)");
			if (Gui.igIsWindowAppearing() || mNtRefocus)
				Gui.igSetKeyboardFocusHere(0);
			mNtRefocus = false;
			float fieldW = 380 * Look.Scale;
			Gui.igSetNextItemWidth(fieldW);
			bool enter = Gui.igInputText("##ntname", mNtName.Ptr, (.)mNtName.Capacity, InputTextFlags.EnterReturnsTrue | InputTextFlags.AutoSelectAll, null, null);
			String name = scope .(mNtName.View);
			name.Trim();
			if (mNtNsFolder != mNtFolder)
			{
				mNtNsFolder.Set(mNtFolder);
				mNtNs.Clear();
				if (dup && FindDoc(mNtSource) != null)
					mNtNs.Set(FindDoc(mNtSource).Header.Namespace);
				else if (dup && ProjectTypeAt(mNtSource) != null)
					mNtNs.Set(ProjectTypeAt(mNtSource).Namespace);
				else
					NamespaceFor(mNtFolder, mNtNs);
			}
			String err = scope .();
			bool valid = ValidateTypeName(mNtFolder, name, mNtNs, err);
			ErrorLine(err);
			if (valid)
				Gui.TextDisabled(scope $"Creates {name}{GraphExtension}  (namespace {(mNtNs.IsEmpty ? "none" : (StringView)mNtNs)})");
			if (!dup && (mNtKind == .Class || mNtKind == .Struct))
				DrawNewTypeInheritance(fieldW, name);
			Gui.igSpacing();
			Gui.igBeginDisabled(!valid);
			bool create = Gui.Button(dup ? "Duplicate" : "Create", .(120 * Look.Scale, 0)) || (enter && valid);
			if (enter && !valid)
				mNtRefocus = true; // keep typing after Enter on a bad name
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (create && valid)
			{
				Gui.igCloseCurrentPopup();
				if (dup)
					DuplicateType(mNtSource, name);
				else
					CreateType(mNtKind, mNtFolder, name, mNtBase, mNtInterfaces);
			}
			Gui.EndPopup();
		}

		/// The Base Class (classes) and Interfaces (classes and structs) of the Create Type dialog.
		void DrawNewTypeInheritance(float fieldW, StringView name)
		{
			Gui.igSpacing();
			String self = scope .();
			if (!mNtNs.IsEmpty)
				self.AppendF("{}.", mNtNs);
			self.Append(name);
			String v = scope .();
			if (mNtKind == .Class)
			{
				Gui.Text("Base Class");
				if (TypeComboFor("##ntbase", mNtBase, v, .BaseClass, "None (Object)", fieldW, self))
					mNtBase.Set(v);
			}
			Gui.Text("Interfaces");
			int removeAt = -1;
			for (let i in mNtInterfaces)
			{
				Gui.PushID((int32)@i.Index);
				Gui.TextColored(Theme.TypeColor(i), scope $"    {Icon.Interface}  {i}");
				Gui.SameLine();
				if (Gui.SmallButton(scope $"{Icon.X}##rm"))
					removeAt = @i.Index;
				Gui.PopID();
			}
			if (removeAt >= 0)
			{
				delete mNtInterfaces[removeAt];
				mNtInterfaces.RemoveAt(removeAt);
			}
			v.Clear();
			if (TypeComboFor("##ntiface", "", v, .Interface, "", fieldW, self, "Add an interface") && !v.IsEmpty && !mNtInterfaces.Contains(v))
				mNtInterfaces.Add(new String(v));
			String line = scope .();
			line.Append(name);
			bool first = true;
			if (!mNtBase.IsEmpty)
			{
				line.AppendF(" : {}", mNtBase);
				first = false;
			}
			for (let i in mNtInterfaces)
			{
				line.AppendF("{}{}", first ? " : " : ", ", i);
				first = false;
			}
			Gui.TextDisabled(line);
		}

		/// Writes the new type `name` of `kind` in `folder` from its template, with its base and
		/// interfaces, and opens it (NewDocument).
		public TypeDocument CreateType(TypeKind kind, StringView folder, StringView name, StringView baseType = "", List<String> interfaces = null)
		{
			String path = scope .();
			TypePathIn(folder, name, path);
			let doc = NewDocument(path, kind, baseType, interfaces);
			if (doc != null)
				SetStatus(scope $"Created the {scope String(KindTitle(kind))..ToLower()} {doc.Header.GetFullName(.. scope String())} in {name}{GraphExtension}");
			return doc;
		}

		/// The function signatures the interfaces (and the ones they extend) ask for: the project's
		/// from their files, the core library's and dependencies' from the front end. The caller deletes
		/// the items.
		public void InterfaceFunctions(StringView iface, List<MemberDecl> outFns)
		{
			RefreshProjectTypes();
			HashSet<String> seen = scope .();
			defer { for (let s in seen) delete s; }
			InterfaceFunctions(iface, outFns, seen);
		}

		void InterfaceFunctions(StringView iface, List<MemberDecl> outFns, HashSet<String> seen)
		{
			if (seen.ContainsAlt(iface))
				return;
			seen.Add(new String(iface));
			let pt = ProjectTypes.Find(iface);
			if (pt != null && pt.Kind == .Interface)
			{
				for (let m in pt.Members)
					if (m.Kind == .Function && !m.Static)
						outFns.Add(m.Clone());
				for (let i in pt.Implements)
					InterfaceFunctions(i, outFns, seen);
				return;
			}
			let comp = FrontEnd?.Last;
			if (comp == null)
				return;
			for (let s in comp.Table.Types)
			{
				if (s.FullName != iface || s.Kind != .Interface)
					continue;
				for (let m in s.Members)
					if (m.Decl != null && m.Decl.Kind == .Function && !m.Static)
						outFns.Add(m.Decl.Clone());
				for (let i in s.Interfaces)
					if (i.Sym != null)
						InterfaceFunctions(i.Sym.FullName, outFns, seen);
				return;
			}
		}

		/// A Base Constructor node wired from Entry on the constructor Sheet in front, when the base
		/// class declares constructors (its first one; Properties picks another). True when placed.
		bool PlaceBaseConstructorStub()
		{
			let mg = CurrentMethod;
			if (mg == null || mg.Member == null || mg.Member.Kind != .Ctor || !mg.IsBuilt || mg.Graph.Entry == null)
			{
				Notify.Log(.Info, "NewType", "No Base Constructor stub: the constructor's Sheet is not in front");
				return false;
			}
			RefreshProjectTypes();
			List<NodeMenu.OverloadChoice> choices = scope .();
			defer { ClearAndDeleteItems!(choices); }
			mNodeMenu.ChainChoices(mg, "base", choices);
			if (choices.IsEmpty || (choices.Count == 1 && choices[0].Signature == "()"))
				return false; // the base has only a constructor without inputs: it runs by itself
			let then = mg.Graph.Entry.FindOutput("then");
			if (then == null)
				return false;
			// The first of the base's constructors, wired from Entry (Properties lists the others).
			mActionTab = CurrentTab;
			mNodeMenu.SpawnPos = .(mg.Graph.Entry.X + 300, mg.Graph.Entry.Y);
			mNodeMenu.ContextPinId = then.Id;
			let placed = ExecuteAction(choices[0].Item);
			mNodeMenu.ContextPinId = 0;
			if (placed == null)
				Notify.Log(.Info, "NewType", scope $"No Base Constructor stub: {choices[0].Label} was not placed");
			return placed != null;
		}

		/// Duplicate: the copy of the type file at `sourcePath` named `name`, next to it (fresh member
		/// ids, the type's own name rewritten, the layout copied), opened.
		public TypeDocument DuplicateType(StringView sourcePath, StringView name)
		{
			if (!CheckWritable())
				return null;
			TypeDocument src = FindDoc(sourcePath);
			TypeDocument loaded = null;
			defer { delete loaded; }
			if (src == null)
			{
				loaded = new TypeDocument(Language);
				if (loaded.Load(sourcePath) case .Err)
				{
					ReportError(scope $"Could not read {sourcePath}: {loaded.LastError}");
					return null;
				}
				src = loaded;
			}
			String folder = scope .();
			Path.GetDirectoryPath(sourcePath, folder).IgnoreError();
			String path = scope .();
			TypePathIn(folder, name, path);
			if (File.Exists(path))
			{
				ReportError(scope $"{path} exists already.");
				return null;
			}
			String text = scope .();
			String layout = scope .();
			String why = scope .();
			if (!src.WriteDuplicate(name, text, layout, why))
			{
				ReportError(scope $"Could not duplicate {sourcePath}: {why}");
				return null;
			}
			if (FileSafety.AtomicWrite(path, text, false, why) case .Err)
			{
				ReportError(scope $"Could not write {path}: {why}");
				return null;
			}
			if (!layout.IsEmpty)
			{
				String layoutPath = scope .();
				TypeDocument.LayoutPathOf(path, layoutPath);
				FileSafety.AtomicWrite(layoutPath, layout, false, why).IgnoreError();
			}
			ScanProject();
			let doc = OpenFile(path);
			if (doc != null)
			{
				if (doc.Sheets.IsEmpty)
					SelectOutline(.TypeSettings);
				SetStatus(scope $"Duplicated {Path.GetFileName(sourcePath, .. scope String())} as {name}{GraphExtension} (delete the file to undo)");
			}
			return doc;
		}

		/// A menu row with the kind's glyph in its colour in front of `label`.
		bool KindMenuItem(TypeKind kind, StringView label)
		{
			String l = scope .();
			l.AppendF("      {}", label);
			bool r = Gui.MenuItem(l);
			let min = Gui.igGetItemRectMin();
			let max = Gui.igGetItemRectMax();
			float h = max.y - min.y;
			let gs = Gui.CalcTextSize(KindIcon(kind));
			Gui.DrawText(Gui.igGetWindowDrawList(), .(min.x + (h - gs.x) * 0.5f, min.y + (h - gs.y) * 0.5f), KindColor(kind), KindIcon(kind));
			return r;
		}

		/// The second line of a tile: the type's kind ("Class"), else what AssetStyle says.
		StringView TileKindLabel(CBItem item)
		{
			if (item.Kind == .Document)
			{
				let t = ProjectTypeAt(item.Path);
				if (t != null)
					return KindTitle(t.Kind);
			}
			return AssetStyle.KindLabel(item.Kind);
		}

		/// A type tile's tooltip lines: "Base: Animal", "Interfaces: IPet", "2 required overrides".
		void DrawTypeTooltipLines(StringView path)
		{
			let t = ProjectTypeAt(path);
			if (t == null)
				return;
			if (!t.Base.IsEmpty)
				Gui.TextDisabled(scope $"Base: {t.Base}");
			if (!t.Implements.IsEmpty)
			{
				String list = scope .();
				for (let i in t.Implements)
					list.AppendF("{}{}", (@i.Index > 0) ? ", " : "", i);
				Gui.TextDisabled(scope $"Interfaces: {list}");
			}
			let n = RequiredCountAt(path);
			if (n > 0)
				Gui.TextColored(Theme.Warning, scope $"{n} required override{(n == 1) ? "" : "s"} not implemented");
		}
	}
}
