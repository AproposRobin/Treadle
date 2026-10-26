using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Program Start in the editor (Language.md 6): the project's `entry` type and its static Main.
	/// The status bar names it ("Entry: Program.Main", a click opens it), the Outline marks it with a
	/// play glyph, a static Main's row menu offers "Set as entry point" (undoable with Ctrl+Z), and a
	/// build that fails for want of one offers "Create Main" in Problems.
	extension EditorApp
	{
		/// The last "Set as entry point": undone and redone with the document it was made in, while
		/// nothing else was edited there since.
		class EntryChange
		{
			public TypeDocument Doc;
			public int32 Stamp;
			public String Before = new .() ~ delete _;
			public String After = new .() ~ delete _;
			public bool Undone;
		}
		EntryChange mEntryChange ~ delete _;

		/// Whether the project has a Program Start at all (not a library, a project is open).
		bool WantsEntry
		{
			get
			{
				if (Project == null)
					return false;
				StringView kind;
				Project.KindIs(out kind);
				return kind != ProjectFile.KindLibrary;
			}
		}

		/// "Program.Main": the entry type's short name and Main; "" when the project names none.
		public void EntryLabel(String outText)
		{
			if (Project == null)
				return;
			String t = scope .();
			Project.EntryTypeName(t);
			if (t.IsEmpty)
				return;
			outText.AppendF("{}.Main", Node.ShortTypeName(t, .. scope String()));
		}

		/// `doc` is the project's entry type.
		public bool IsEntryType(TypeDocument doc)
		{
			if (Project == null || doc == null)
				return false;
			String t = scope .();
			Project.EntryTypeName(t);
			if (t.IsEmpty)
				return false;
			String full = scope .();
			doc.Header.GetFullName(full);
			return Treadle.Catalog.NodeCatalog.SameOwner(full, t);
		}

		/// `m` of `doc` is Program Start: the static Main of the entry type.
		public bool IsEntryFunction(TypeDocument doc, MemberDecl m)
		{
			return m != null && m.Kind == .Function && m.Static && m.Name == "Main" && IsEntryType(doc);
		}

		/// The entry type's document: open already, else opened from its file (without a tab); null
		/// when the project names no entry type or it is not in the project.
		TypeDocument FindEntryDoc()
		{
			if (Project == null)
				return null;
			String t = scope .();
			Project.EntryTypeName(t);
			if (t.IsEmpty)
				return null;
			for (let d in mDocs)
				if (IsEntryType(d))
					return d;
			RefreshProjectTypes();
			let pt = ProjectTypes.Find(t);
			if (pt == null || pt.Path.IsEmpty || !File.Exists(pt.Path))
				return null;
			return OpenFile(pt.Path, false);
		}

		/// The status bar's entry item: opens Program Start's Sheet.
		public void OpenEntry()
		{
			let doc = FindEntryDoc();
			let sheet = doc?.FindSheetByName("Main");
			if (sheet == null)
			{
				SetStatus("The project has no entry point: Build > Create Main makes Program.Main", .Warning);
				return;
			}
			OpenTab(sheet);
		}

		/// Outline > a static function's menu > Set as entry point: the project's `entry` becomes this
		/// type (its static Main is Program Start). One undo step of the open document.
		public void SetEntryPoint(TypeDocument doc, MemberDecl m)
		{
			if (Project == null || doc == null || m == null || !CheckWritable())
				return;
			String before = scope .();
			Project.EntryTypeName(before);
			String full = scope .();
			doc.Header.GetFullName(full);
			if (!Project.SetEntryType(full))
				return;
			if (!SaveProjectFile())
			{
				Project.SetEntryType(before);
				return;
			}
			delete mEntryChange;
			mEntryChange = new .();
			mEntryChange.Doc = EditDoc;
			mEntryChange.Stamp = EditDoc.UndoStamp;
			mEntryChange.Before.Set(before);
			mEntryChange.After.Set(full);
			SetStatus(scope $"Entry point: {Node.ShortTypeName(full, .. scope String())}.{m.Name} (Ctrl+Z undoes it)");
		}

		/// Ctrl+Z: undoes the last Set as entry point when it is the last edit of the document in
		/// front. True when it did (the document's own undo is left alone then).
		public bool UndoEntryChange()
		{
			let c = mEntryChange;
			if (c == null || c.Undone || c.Doc != EditDoc || EditDoc.UndoStamp != c.Stamp || Project == null)
				return false;
			Project.SetEntryType(c.Before);
			SaveProjectFile();
			c.Undone = true;
			String label = scope .();
			EntryLabel(label);
			SetStatus(label.IsEmpty ? "Undone: the project has no entry point again" : scope $"Undone: the entry point is {label} again");
			return true;
		}

		/// Ctrl+Y / Ctrl+Shift+Z after UndoEntryChange.
		public bool RedoEntryChange()
		{
			let c = mEntryChange;
			if (c == null || !c.Undone || c.Doc != EditDoc || EditDoc.UndoStamp != c.Stamp || Project == null)
				return false;
			Project.SetEntryType(c.After);
			SaveProjectFile();
			c.Undone = false;
			String label = scope .();
			EntryLabel(label);
			SetStatus(scope $"Entry point: {label}");
			return true;
		}

		/// The Outline's row menu of a function: "Set as entry point" for a static Main.
		void EntryMenuItem(MemberDecl m)
		{
			if (m == null || m.Kind != .Function || !m.Static || !WantsEntry)
				return;
			bool already = IsEntryFunction(Doc, m);
			bool can = m.Name == "Main" && !already;
			if (IconItem(Icon.Play, "Set as entry point", "", already, can))
				SetEntryPoint(Doc, m);
			if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
			{
				if (already)
					Gui.Tooltip("This is the entry point: the program starts here");
				else if (m.Name != "Main")
					Gui.Tooltip("Only a static function named Main can be the entry point (Program Start).\nCall this function from Main, or rename it to Main.");
				else
					Gui.Tooltip("The program starts here: writes `entry` in the project file (Ctrl+Z undoes it)");
			}
		}

		/// The Outline row's glyph for Program Start, drawn left of the "static" word.
		void DrawEntryGlyph(ImDrawList* dl, MemberDecl m, float rightX, float ty)
		{
			if (!IsEntryFunction(Doc, m))
				return;
			float tw = Gui.CalcTextSize("static").x + Gui.CalcTextSize(Icon.Play).x + 10 * Look.Scale;
			Gui.DrawText(dl, .(rightX - tw, ty), Look.Success, Icon.Play);
		}

		// ---------------------------------------------------------------- status bar

		void EntryStatusText(String outText, out bool missing)
		{
			missing = false;
			if (!WantsEntry)
				return;
			String label = scope .();
			EntryLabel(label);
			if (label.IsEmpty)
			{
				missing = true;
				outText.Append("No entry point");
			}
			else
				outText.AppendF("Entry: {}", label);
		}

		/// The width the status bar keeps for the entry item (0 = none).
		float EntryStatusWidth()
		{
			String text = scope .();
			EntryStatusText(text, ?);
			if (text.IsEmpty)
				return 0;
			return Gui.CalcTextSize(text).x + Gui.igGetFontSize() * 1.6f + 24 * Look.Scale;
		}

		/// Draws the entry item at `p` (the status bar's right side, before the build state) and
		/// moves `p` past it. A click opens Program Start's Sheet, or offers Create Main when there is none.
		void DrawEntryStatus(ImDrawList* dl, ref ImVec2 p, float ty)
		{
			String text = scope .();
			bool missing;
			EntryStatusText(text, out missing);
			if (text.IsEmpty)
				return;
			float fs = Gui.igGetFontSize();
			float w = Gui.CalcTextSize(text).x + fs * 1.6f;
			let keep = Gui.igGetCursorPos();
			Gui.igSetCursorScreenPos(.(p.x, ty - fs * 0.2f));
			bool clicked = Gui.igInvisibleButton("##entrystatus", .(w, fs * 1.4f), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			Gui.igSetCursorPos(keep);
			uint32 col = missing ? Look.Warning : (hovered ? Look.ForegroundHover : Look.Foreground);
			Gui.DrawText(dl, .(p.x, ty), missing ? Look.Warning : Look.Success, Icon.Play);
			Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), col, text);
			if (hovered)
				Gui.Tooltip(missing ? "The program has no entry point (Program Start): click to create Program.Main" : "Where the program starts (Program Start): click to open it");
			if (clicked)
			{
				if (missing)
					CreateMain();
				else
					OpenEntry();
			}
			p.x += w + 24 * Look.Scale;
		}

		// ---------------------------------------------------------------- Create Main

		/// The last build failed because there is no Program Start (no `entry`, an entry type that is
		/// not in the project, or one without a static Main).
		public bool BuildMissesEntry()
		{
			if (mBuild == null || mBuild.Running || mBuild.Succeeded || !WantsEntry)
				return false;
			for (let m in mBuild.Messages)
				if (m.Text.Contains("no entry type") || m.Text.Contains("T1060") || m.Text.Contains("T1062") ||
					m.Text.Contains("has no static Main") || (m.Text.Contains("entry type") && m.Text.Contains("is not in the project")))
					return true;
			return false;
		}

		/// The entry type has a static Main (from the open documents and the project's types; opens nothing).
		public bool HasEntryMain()
		{
			if (Project == null)
				return false;
			String t = scope .();
			Project.EntryTypeName(t);
			if (t.IsEmpty)
				return false;
			for (let d in mDocs)
				if (IsEntryType(d))
				{
					let m = d.FindMember("Main");
					return m != null && m.Kind == .Function && m.Static;
				}
			let pt = ProjectTypes.Find(t);
			if (pt == null)
				return false;
			for (let m in pt.Members)
				if (m.Kind == .Function && m.Static && m.Name == "Main")
					return true;
			return false;
		}

		/// Build > Create Main (enabled while there is no entry point).
		void DrawCreateMainItem()
		{
			if (!WantsEntry)
				return;
			if (Gui.MenuItem(scope $"{Icon.Play}  Create Main", "", false, !HasEntryMain()))
				CreateMain();
			if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip("Makes Program.Main, where the program starts, when the project has no entry point");
		}

		/// Problems: a line with Create Main when the build failed for want of an entry point.
		void DrawEntryFix()
		{
			if (!BuildMissesEntry())
				return;
			Gui.TextColored(Look.Warning, Icon.Warning);
			Gui.SameLine();
			Gui.Text("The program has no entry point (Program Start): a static Main of the project's entry type.");
			Gui.SameLine();
			if (Gui.Button(scope $"{Icon.Play}  Create Main"))
				CreateMain();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Makes Program.Main (a static class Program with a static Main) and names Program as the entry type in the project file");
		}

		/// Build > Create Main, the Problems button and the status bar's "No entry point": the project's
		/// Program type gets a static Main (a new Source/Program type when there is none), Program becomes
		/// the entry type, and Main opens.
		public void CreateMain()
		{
			if (Project == null || ProjectPath.IsEmpty || !CheckWritable())
			{
				SetStatus("Open a project first", .Warning);
				return;
			}
			String ns = scope .(Project.Namespace);
			if (ns.IsEmpty)
				IdentifierOf(Project.Name, ns);
			// An existing Program type: the open one, else the project's file.
			TypeDocument prog = null;
			for (let d in mDocs)
				if (d.Header.Name == "Program")
					prog = d;
			if (prog == null)
			{
				RefreshProjectTypes();
				for (let t in ProjectTypes.Types)
					if (t.Name == "Program" && !t.Path.IsEmpty && File.Exists(t.Path))
					{
						prog = OpenFile(t.Path, false);
						break;
					}
			}
			String why = scope .();
			if (prog == null)
			{
				// A new Source/Program type, as New Project makes it.
				String src = scope .();
				let folder = Project.Sources.IsEmpty ? StringView("Source") : (StringView)Project.Sources[0];
				JoinPath(mProjectRoot, folder, src);
				Directory.CreateDirectory(src).IgnoreError();
				String path = scope .();
				JoinPath(src, scope $"Program{GraphExtension}", path);
				if (File.Exists(path))
				{
					SetStatus(scope $"Create Main: {path} exists but does not read as a type", .Warning);
					return;
				}
				let doc = scope TypeDocument(Language);
				doc.FilePath.Set(path);
				ProgramTemplate(doc, Project.Name, ns);
				if (!doc.TrySave(why))
				{
					SetStatus(scope $"Create Main: could not write {path}: {why}", .Warning);
					return;
				}
				prog = OpenFile(path, false);
				if (prog == null)
					return;
			}
			else
			{
				let main = prog.FindMember("Main");
				if (main == null || main.Kind != .Function)
				{
					prog.PushUndo();
					let s = prog.AddFunction("Main");
					s.Member.Static = true;
					prog.Modified = true;
					if (!prog.TrySave(why))
					{
						SetStatus(scope $"Create Main: could not save {prog.FilePath}: {why}", .Warning);
						return;
					}
				}
				else if (!main.Static)
				{
					SetStatus("Program has a Main that is not static: tick Static on its page in Properties", .Warning);
					OpenTab(prog.FindSheetByName("Main"));
					SelectOutline(.Member, main);
					return;
				}
			}
			String full = scope .();
			prog.Header.GetFullName(full);
			Project.SetEntryType(full);
			SaveProjectFile();
			OpenEntry();
			SetStatus(scope $"Created the entry point {Node.ShortTypeName(full, .. scope String())}.Main: Run (Ctrl+F5) starts the program here");
		}
	}
}
