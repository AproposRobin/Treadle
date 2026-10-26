using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// One "Find in Sheets" result.
	class FindHit
	{
		public enum HitKind { Document, Sheet, Node }
		public HitKind Kind;
		public String Path = new .() ~ delete _;
		public String SheetKey = new .() ~ delete _;
		public String Where = new .() ~ delete _;
		public String Text = new .() ~ delete _;
		public int32 NodeId = -1;
	}

	/// Find in Sheets: project-wide search over document names, Sheet names and every node of the
	/// open documents (titles, pin labels, pin values). Clicking a result opens its Sheet with the
	/// node selected.
	///
	/// Seam: documents that are not open are matched by file name only; once the language's
	/// graph codec reads files (LanguageContext.Codec), this searches their Sheets too.
	extension EditorApp
	{
		TextBuffer mFindAllBuf = new .(256) ~ delete _;
		String mFindAllQuery = new .() ~ delete _;
		List<FindHit> mFindHits = new .() ~ DeleteContainerAndItems!(_);
		bool mFindFocusInput;
		bool mFindFocusWindow;
		bool mFindTruncated;
		int mFindFiles;
		const int cMaxFindHits = 2000;

		/// Edit > Find in Sheets (Ctrl+Shift+F): shows the panel with its search box focused.
		public void OpenFindResults()
		{
			ShowFindResults = true;
			mFindFocusInput = true;
			mFindFocusWindow = true;
		}

		void AddHit(FindHit.HitKind kind, StringView path, StringView sheetKey, StringView whereText, StringView text, int32 nodeId = -1)
		{
			if (mFindHits.Count >= cMaxFindHits)
			{
				mFindTruncated = true;
				return;
			}
			FindHit h = new .();
			h.Kind = kind;
			h.Path.Set(path);
			h.SheetKey.Set(sheetKey);
			h.Where.Set(whereText);
			h.Text.Set(text);
			h.NodeId = nodeId;
			mFindHits.Add(h);
		}

		static bool Matches(StringView text, StringView query) => !text.IsEmpty && text.Contains(query, true);

		void RunFind(StringView queryIn)
		{
			ClearAndDeleteItems!(mFindHits);
			mFindTruncated = false;
			mFindFiles = 0;
			var query = queryIn;
			query.Trim();
			mFindAllQuery.Set(query);
			if (query.IsEmpty)
				return;
			HashSet<String> seen = scope .();
			defer { for (let s in seen) delete s; }
			String name = scope .();
			String title = scope .();
			// Open documents: their Sheets and nodes.
			for (let doc in mDocs)
			{
				int before = mFindHits.Count;
				name.Clear();
				doc.GetName(name);
				if (Matches(name, query))
					AddHit(.Document, doc.FilePath, "", name, name);
				for (let s in doc.Sheets)
				{
					if (Matches(s.Name, query))
						AddHit(.Sheet, doc.FilePath, s.Key, name, s.Name);
					let g = s.Graph;
					for (let n in g.Nodes)
					{
						title.Clear();
						n.GetTitle(title);
						bool hit = Matches(title, query) || Matches(n.Text, query);
						for (let p in n.Inputs)
							hit |= Matches(p.Label, query) || Matches(p.Default, query);
						for (let p in n.Outputs)
							hit |= Matches(p.Label, query);
						if (hit)
							AddHit(.Node, doc.FilePath, s.Key, scope $"{name} > {s.Name}", title, n.Id);
					}
				}
				if (mFindHits.Count > before)
					mFindFiles++;
				if (!doc.FilePath.IsEmpty)
					seen.Add(new String(doc.FilePath));
			}
			// The rest of the project: by file name.
			for (let f in Index.Files)
			{
				bool open = false;
				for (let s in seen)
					if (ProjectIndex.SamePath(s, f.Path))
						open = true;
				if (open || !Matches(f.Name, query))
					continue;
				AddHit(.Document, f.Path, "", f.Name, f.Name);
				mFindFiles++;
			}
			Notify.Log(.Info, "Find", scope $"Find '{query}': {mFindHits.Count} result(s) in {mFindFiles} document(s)");
		}

		void OpenFindHit(FindHit h)
		{
			if (h.Path.IsEmpty)
				return;
			let doc = FindDoc(h.Path) ?? OpenFile(h.Path, false);
			if (doc == null)
				return;
			Doc = doc;
			let sheet = h.SheetKey.IsEmpty ? (doc.Sheets.IsEmpty ? null : doc.Sheets[0]) : doc.FindSheet(h.SheetKey);
			if (sheet == null)
				return;
			OpenTab(sheet);
			if (h.NodeId < 0)
				return;
			let node = sheet.Graph.FindNode(h.NodeId);
			let tab = CurrentTab;
			if (node != null && tab != null)
			{
				tab.SelectOnly(node.Id);
				tab.CenterOn(node.X + 100, node.Y + 40);
			}
		}

		void DrawFindResults()
		{
			if (!ShowFindResults)
				return;
			if (mFindFocusWindow)
			{
				mFindFocusWindow = false;
				Panels.Focus(Panels.FindResultsId);
			}
			if (!Gui.Begin(Panels.FindResults, &ShowFindResults))
			{
				Gui.End();
				return;
			}
			NoteBottomDock();
			if (mFindFocusInput)
			{
				mFindFocusInput = false;
				Gui.igSetKeyboardFocusHere(0);
			}
			Gui.igSetNextItemWidth(Math.Min(420 * Look.Scale, Gui.igGetContentRegionAvail().x - 100 * Look.Scale));
			bool enter = Gui.igInputTextWithHint("##findall", scope $"{Icon.Search}  Find in Sheets: names, nodes, values", mFindAllBuf.Ptr, (.)mFindAllBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
			Gui.SameLine();
			if (Gui.Button("Find") || enter)
				RunFind(mFindAllBuf.View);
			if (!mFindAllQuery.IsEmpty)
			{
				Gui.SameLine();
				Gui.TextDisabled(scope $"{mFindHits.Count}{mFindTruncated ? "+" : ""} result(s) in {mFindFiles} document(s)");
			}
			Gui.Separator();
			if (Gui.igBeginChild_Str("##findhits", .(0, 0), 0, 0))
			{
				if (mFindHits.IsEmpty)
					Gui.TextDisabled(mFindAllQuery.IsEmpty ? "Type a name and press Enter." : "Nothing found.");
				FindHit open = null;
				for (let h in mFindHits)
				{
					StringView kind;
					switch (h.Kind)
					{
					case .Document: kind = "Document";
					case .Sheet: kind = "Sheet";
					case .Node: kind = "Node";
					}
					Gui.PushID((int32)@h.Index);
					if (Gui.Selectable(scope $"{kind}  {h.Text}", false, 0))
						open = h;
					Gui.SameLine(Math.Max(Gui.igGetCursorPosX() + 20, 380 * Look.Scale));
					Gui.TextDisabled(h.Where);
					Gui.PopID();
				}
				if (open != null)
					OpenFindHit(open);
			}
			Gui.igEndChild();
			Gui.End();
		}
	}
}
