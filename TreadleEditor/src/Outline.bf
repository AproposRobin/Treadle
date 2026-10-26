using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The Outline panel: a search box, the document header, and category bars (SHEETS / LOCAL
	/// VARIABLES) with a count and a "+" on the right; rows open a Sheet or drag a variable into
	/// the graph. Lists live here, on the left; the right column (Properties) holds the details of
	/// the selection.
	extension EditorApp
	{
		TextBuffer mBPSearch = new .(128) ~ delete _;
		HashSet<String> mBPClosed = new .() ~ DeleteContainerAndItems!(_);
		/// Sections that start collapsed and that the user opened.
		HashSet<String> mBPOpened = new .() ~ DeleteContainerAndItems!(_);
		/// The Sheet whose Properties page is shown without opening it (none today: every Sheet opens).
		bool mSelDeclActive;
		String mSelDeclKey = new .() ~ delete _;
		/// A Local Variable row of the Outline is selected (Properties shows it).
		bool mSelLocalActive;
		String mSelLocalName = new .() ~ delete _;

		/// Category bar. Returns whether the section is open; `addClicked` reports the "+".
		bool BPSection(StringView id, StringView title, int count, out bool addClicked, StringView addTip, bool startsClosed = false)
		{
			addClicked = false;
			float h = Gui.igGetFrameHeight();
			let p = Gui.igGetCursorScreenPos();
			float w = Gui.igGetContentRegionAvail().x;
			String key = scope .(id);
			bool open = startsClosed ? mBPOpened.Contains(key) : !mBPClosed.Contains(key);
			Gui.PushID(id);
			bool clicked = Gui.igInvisibleButton("##sec", .(w - (addTip.IsEmpty ? 0 : h + 2), h), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + w, p.y + h), hovered ? Gui.Color(56, 56, 56) : Look.Header, 2 * Look.Scale, 0);
			float fs = Gui.igGetFontSize();
			float ty = p.y + (h - fs) * 0.5f;
			Gui.DrawText(dl, .(p.x + 4 * Look.Scale, ty), Look.ForegroundDim, open ? Icon.ChevronDown : Icon.ChevronRight);
			Gui.DrawText(dl, .(p.x + fs * 1.3f, ty), Gui.Color(215, 215, 215), title);
			float tw = Gui.CalcTextSize(title).x;
			Gui.DrawText(dl, .(p.x + fs * 1.3f + tw + 8 * Look.Scale, ty), Look.ForegroundDim, scope $"{count}");
			if (clicked)
			{
				let set = startsClosed ? mBPOpened : mBPClosed;
				// A section that starts open is remembered when closed; one that starts closed, when opened.
				if (open != startsClosed)
					set.Add(new String(key));
				else if (set.GetAndRemove(key) case .Ok(let s))
					delete s;
				open = !open;
			}
			if (addTip.IsEmpty)
			{
				Gui.PopID();
				return open;
			}
			Gui.SameLine(0, 2);
			// The "+" is drawn by hand, centred on the glyph's measured size.
			let bp = Gui.igGetCursorScreenPos();
			bool addHit = Gui.igInvisibleButton("##add", .(h, h), ButtonFlags.MouseButtonLeft);
			bool addHovered = Gui.igIsItemHovered(0);
			Gui.ImDrawList_AddRectFilled(dl, bp, .(bp.x + h, bp.y + h), addHovered ? Look.Primary : Look.Header, 2 * Look.Scale, 0);
			let gs = Gui.CalcTextSize(Icon.Plus);
			Gui.DrawText(dl, .(bp.x + (h - gs.x) * 0.5f, bp.y + (h - gs.y) * 0.5f), Gui.Color(215, 215, 215), Icon.Plus);
			if (addHit)
				addClicked = true;
			if (addHovered)
				Gui.Tooltip(addTip);
			Gui.PopID();
			return open;
		}

		bool BPMatches(StringView name)
		{
			var s = mBPSearch.View;
			s.Trim();
			return s.IsEmpty || name.IndexOf(s, true) >= 0;
		}

		void DrawOutlinePanel()
		{
			ClearAndDeleteItems!(mMembers);
			if (Gui.Begin(Panels.Outline))
			{
				if (Doc == null || Doc == mEmptyDoc)
					Gui.TextDisabled("Open a type to see its functions.");
				else
				{
					Gui.igSetNextItemWidth(-1);
					Gui.igInputTextWithHint("##bpsearch", scope $"{Icon.Search}  Search", mBPSearch.Ptr, (.)mBPSearch.Capacity, 0, null, null);
					Gui.igSpacing();
					// The document header.
					String docName = scope .();
					Doc.Header.GetFullName(docName);
					if (docName.IsEmpty)
						Doc.GetName(docName);
					String header = scope .();
					header.AppendF("{}  {}  ", Icon.FileCode, docName);
					Gui.igPushStyleColor_U32(Col.Header, Theme.Mix(Look.Header, Look.AccentBlue, 0.35f));
					Gui.igPushStyleColor_U32(Col.HeaderHovered, Theme.Mix(Look.Dropdown, Look.AccentBlue, 0.35f));
					Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundHover);
					bool open = Gui.CollapsingHeader(header, TreeNodeFlags.DefaultOpen);
					Gui.igPopStyleColor(3);
					{
						let min = Gui.igGetItemRectMin();
						let max = Gui.igGetItemRectMax();
						StringView k = Treadle.Format.TreadleCodec.TypeKindWord(Doc.Header.Kind);
						float kw = Gui.CalcTextSize(k).x;
						Gui.DrawText(Gui.igGetWindowDrawList(), .(max.x - kw - 8 * Look.Scale, min.y + (max.y - min.y - Gui.igGetFontSize()) * 0.5f), Look.ForegroundDim, k);
					}
					if (open)
					{
						// Type Settings: the header (name, kind, base, interfaces, generics...) in Properties.
						{
							bool selected = OutlineSel == .TypeSettings;
							if (Gui.Selectable(scope $"    {Icon.Settings}  Type Settings##typesettings", selected))
								SelectOutline(.TypeSettings);
							if (Gui.igIsItemHovered(0))
								Gui.Tooltip("Name, kind, namespace, base type, interfaces, generic parameters and attributes of the type");
						}
						if (DrawSheetRows())
						{
							Gui.End();
							return; // the document changed: its lists are rebuilt next frame
						}
						Gui.igSpacing();
						DrawOutlineFields();
						DrawOutlineCases();
						Gui.igSpacing();
						DrawOutlineLocals();
					}
					// F2: the selected member or local is renamed through its Name field in Properties.
					if (Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && !Gui.igIsAnyItemActive() && Gui.IsKeyPressed(573 /* F2 */, false)
						&& (OutlineSel == .Member || OutlineSel == .Local))
						FocusNameField();
				}
			}
			Gui.End();
		}

		/// The context menu of a member row: rename (in Properties), move, delete. True when the
		/// member was removed (the caller stops using it).
		bool MemberRowMenu(MemberDecl m)
		{
			if (!Gui.igBeginPopupContextItem())
				return false;
			bool removed = false;
			if (IconItem(Icon.Pencil, "Rename...", "F2"))
			{
				SelectOutline(.Member, m);
				FocusNameField();
			}
			if (IconItem(Icon.ChevronUp, "Move Up"))
				MoveMember(m, -1);
			if (IconItem(Icon.ChevronDown, "Move Down"))
				MoveMember(m, 1);
			if (IconItem(Icon.Trash2, "Delete"))
			{
				RemoveMember(m);
				removed = true;
			}
			Gui.EndPopup();
			return removed;
		}

		/// FUNCTIONS: one row per Sheet (functions, constructors, the destructor, property get /
		/// set), then the auto properties; "+" adds a function, a property, a constructor or the
		/// destructor. A row opens its Sheet, shows its page in Properties, and drags as a Call.
		/// True when the document changed (a member was removed) and the caller must stop.
		bool DrawSheetRows()
		{
			let currentKey = (CurrentTab != null && CurrentTab.Doc == Doc) ? CurrentTab.MethodKey : "";
			bool addMember = false;
			int count = Doc.Sheets.Count;
			for (let m in Doc.Members)
				if (m.Kind == .Property && m.Auto)
					count++;
			bool open = BPSection("sheets", "FUNCTIONS", count, out addMember, "Add a function, property, constructor or destructor");
			if (addMember)
				Gui.OpenPopup("##addmember");
			if (Gui.BeginPopup("##addmember"))
			{
				if (IconItem(Icon.Function, "Function"))
				{
					if (AddFunctionMember("NewFunction") != null)
						FocusNameField();
				}
				if (IconItem(Icon.Variable, "Property"))
				{
					if (AddProperty("NewProperty", "int") != null)
						FocusNameField();
				}
				if (Doc.Header.Kind == .Class || Doc.Header.Kind == .Struct)
				{
					if (IconItem(Icon.Box, "Constructor"))
						AddCtorOrDtor(false);
					if (Doc.Header.Kind == .Class && IconItem(Icon.Trash2, "Destructor"))
						AddCtorOrDtor(true);
				}
				Gui.EndPopup();
			}
			if (!open)
				return false;
			float fs = Gui.igGetFontSize();
			for (let mg in Doc.Sheets)
			{
				// A Lambda Sheet is drawn under its owner's row (LambdaSheets.bf).
				if (mg.Role == .Lambda && LambdaOwner(Doc, mg) != null)
					continue;
				if (!BPMatches(mg.Name))
					continue;
				Gui.PushID((int32)@mg.Index);
				String label = scope .();
				let m = mg.Member;
				bool overrides = m != null && m.Override;
				label.AppendF("    {}  {}", Icon.Function, mg.Name);
				bool selected = mg.Key == currentKey;
				let rowPos = Gui.igGetCursorScreenPos();
				if (Gui.Selectable(scope $"##sheet{@mg.Index}", selected, SelectableFlags.AllowDoubleClick))
				{
					mSelLocalActive = false;
					OpenTab(mg);
					if (m != null)
						SelectOutline(.Member, m);
				}
				{
					// The row: an icon (red for an override) and the name.
					let dl = Gui.igGetWindowDrawList();
					let max = Gui.igGetItemRectMax();
					float ty = rowPos.y + (max.y - rowPos.y - fs) * 0.5f;
					Gui.DrawText(dl, .(rowPos.x + 14 * Look.Scale, ty), overrides ? Theme.HeaderOverride : Look.ForegroundDim, Icon.Function);
					Gui.DrawText(dl, .(rowPos.x + 14 * Look.Scale + fs * 1.5f, ty), selected ? Look.ForegroundHover : Look.Foreground, mg.Name);
					if (m != null && m.Static)
					{
						float tw = Gui.CalcTextSize("static").x;
						Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, ty), Gui.Color(120, 120, 120), "static");
					}
					if (mg.IsBuilt && !mg.Graph.Errors.IsEmpty)
					{
						float nameW = 14 * Look.Scale + fs * 1.5f + Gui.CalcTextSize(mg.Name).x + 8 * Look.Scale;
						Gui.DrawText(dl, .(rowPos.x + nameW, ty), Theme.NodeError, Icon.Error);
					}
				}
				if (Gui.igIsItemHovered(0))
				{
					int nodes = mg.IsBuilt ? mg.Graph.Nodes.Count : 0;
					Gui.Tooltip(scope $"{mg.Name}: {nodes} node{(nodes == 1) ? "" : "s"}\nDrag onto the Sheet to place a Call");
				}
				if (m != null && m.Kind == .Function && mg.Role == .Body)
				{
					String sig = scope .();
					for (let p in m.Params)
					{
						if (@p.Index > 0)
							sig.Append(", ");
						sig.AppendF("{} {}", p.Type?.ToString(.. scope String()), p.Name);
					}
					AddMemberRef(.Function, m.Name, m.Returns?.ToString(.. scope String()) ?? "", sig, Doc.Header.Name, m.Static);
					if (Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
					{
						int32 idx = (int32)mMembers.Count - 1;
						Gui.igSetDragDropPayload("TREADLE_MEMBER", &idx, sizeof(int32), 0);
						Gui.igEndDragDropSource();
					}
				}
				if (m != null && m.Kind != .Property && mg.Role != .Lambda)
				{
					if (MemberRowMenu(m))
					{
						Gui.PopID();
						return true;
					}
				}
				else if (Gui.igBeginPopupContextItem())
				{
					// A Lambda Sheet whose node is gone (it is listed here, not under an owner).
					if (mg.Role == .Lambda && IconItem(Icon.Trash2, "Delete Lambda Sheet"))
					{
						DeleteSheet(mg);
						Gui.EndPopup();
						Gui.PopID();
						return true;
					}
					if (mg.Role != .Lambda && IconItem(Icon.Pencil, "Rename...", "F2"))
						StartRenameSheet(mg);
					if (m != null && mg.Role != .Lambda && IconItem(Icon.Trash2, "Delete Property"))
					{
						RemoveMember(m);
						Gui.EndPopup();
						Gui.PopID();
						return true;
					}
					Gui.EndPopup();
				}
				Gui.PopID();
				if (mg.Role != .Lambda)
					DrawLambdaRows(mg, currentKey, 0);
			}
			// Auto properties have no Sheet: a row each, for their page.
			for (let m in Doc.Members)
			{
				if (m.Kind != .Property || !m.Auto || !BPMatches(m.Name))
					continue;
				Gui.PushID((int32)(40000 + @m.Index));
				bool selected = OutlineSel == .Member && mSelMemberSerial == m.Serial;
				if (Gui.Selectable(scope $"    {Icon.Variable}  {m.Name}  (auto property)", selected))
					SelectOutline(.Member, m);
				if (MemberRowMenu(m))
				{
					Gui.PopID();
					return true;
				}
				Gui.PopID();
			}
			return false;
		}

		/// VARIABLES: the type's fields (name, type pill); "+" adds one. A row shows its page in
		/// Properties and drags like a variable (Get / Set).
		void DrawOutlineFields()
		{
			int count = 0;
			for (let m in Doc.Members)
				if (m.Kind == .Field)
					count++;
			bool add = false;
			bool open = BPSection("fields", "VARIABLES", count, out add, (Doc.Header.Kind == .Enum || Doc.Header.Kind == .Interface) ? "" : "Add a variable");
			if (add)
			{
				if (AddField("NewVar", "int") != null)
					FocusNameField();
			}
			if (!open)
				return;
			// Fields without a Category first, then one collapsible header per Category (in the order the
			// categories first appear) with its fields under it.
			List<StringView> categories = scope .();
			for (let m in Doc.Members)
				if (m.Kind == .Field && m.Category != null && !categories.Contains(m.Category))
					categories.Add(m.Category);
			OutlineCategoryRows = 0;
			for (int ci = -1; ci < categories.Count; ci++)
			{
				float indent = 0;
				if (ci >= 0)
				{
					let cat = categories[ci];
					int inCat = 0;
					for (let m in Doc.Members)
						if (m.Kind == .Field && m.Category == cat && BPMatches(m.Name))
							inCat++;
					if (inCat == 0)
						continue;
					OutlineCategoryRows++;
					if (!CategoryHeader(cat, inCat))
						continue;
					indent = 14 * Look.Scale;
				}
				for (let m in Doc.Members)
				{
					if (m.Kind != .Field || !BPMatches(m.Name))
						continue;
					if ((ci < 0) ? (m.Category != null) : (m.Category != categories[ci]))
						continue;
					if (DrawFieldRow(m, indent))
						return;
				}
			}
		}

		/// How many Category headers the VARIABLES section drew last frame (the self test).
		public int OutlineCategoryRows;

		/// A Category's header under VARIABLES: a chevron, the name and the count; a click folds it.
		/// Returns whether it is open.
		bool CategoryHeader(StringView cat, int count)
		{
			String key = scope $"cat:{cat}";
			bool open = !mBPClosed.Contains(key);
			Gui.PushID(key);
			let p = Gui.igGetCursorScreenPos();
			bool clicked = Gui.Selectable("##cathead", false);
			let dl = Gui.igGetWindowDrawList();
			float x = p.x + 8 * Look.Scale;
			Gui.DrawText(dl, .(x, p.y), Look.ForegroundDim, open ? Icon.ChevronDown : Icon.ChevronRight);
			x += Gui.CalcTextSize(Icon.ChevronDown).x + 6 * Look.Scale;
			Gui.DrawText(dl, .(x, p.y), Look.Foreground, cat);
			x += Gui.CalcTextSize(cat).x + 8 * Look.Scale;
			Gui.DrawText(dl, .(x, p.y), Look.ForegroundDim, scope $"{count}");
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(scope $"Category {cat}: {count} variable{(count == 1) ? "" : "s"} (set in a variable's Properties)");
			if (clicked)
			{
				if (open)
					mBPClosed.Add(new String(key));
				else if (mBPClosed.GetAndRemove(key) case .Ok(let s))
					delete s;
				open = !open;
			}
			Gui.PopID();
			return open;
		}

		/// One VARIABLES row (name, type pill, type), indented under its Category. True when the member
		/// was removed (the caller stops).
		bool DrawFieldRow(MemberDecl m, float indent)
		{
			float h = Gui.igGetTextLineHeight();
			Gui.PushID((int32)(20000 + Doc.Members.IndexOf(m)));
			let cur = Gui.igGetCursorScreenPos() + ImVec2(indent, 0);
			bool selected = OutlineSel == .Member && mSelMemberSerial == m.Serial;
			if (Gui.Selectable("##field", selected))
				SelectOutline(.Member, m);
			String type = scope .();
			m.Type?.ToString(type);
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), Theme.TypeColor(type), h * 0.3f, 0);
			Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), selected ? Look.ForegroundHover : Look.Foreground, m.Name);
			{
				let max = Gui.igGetItemRectMax();
				String fit = scope .();
				float nameW = 42 * Look.Scale + Gui.CalcTextSize(m.Name).x + 12 * Look.Scale;
				FitText(type, Math.Max(0, max.x - cur.x - nameW), fit);
				float tw = Gui.CalcTextSize(fit).x;
				Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, cur.y), Gui.Color(120, 120, 120), fit);
			}
			if (Gui.igIsItemHovered(0))
			{
				String tip = scope $"{m.Name} : {type}{(m.Static ? " (static)" : "")}";
				if (m.Category != null)
					tip.AppendF("\nCategory: {}", m.Category);
				tip.Append("\nDrag onto a pin to wire it, or onto the Sheet: Ctrl = Get, Alt = Set");
				Gui.Tooltip(tip);
			}
			AddMemberRef(.Variable, m.Name, type, "", Doc.Header.Name, m.Static);
			if (Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
			{
				int32 idx = (int32)mMembers.Count - 1;
				Gui.igSetDragDropPayload("TREADLE_MEMBER", &idx, sizeof(int32), 0);
				Gui.igEndDragDropSource();
			}
			if (MemberRowMenu(m))
			{
				Gui.PopID();
				return true;
			}
			Gui.PopID();
			return false;
		}

		/// CASES: an enum's cases with their values and payload fields; "+" adds one.
		void DrawOutlineCases()
		{
			if (Doc.Header.Kind != .Enum)
				return;
			int count = 0;
			for (let m in Doc.Members)
				if (m.Kind == .Case)
					count++;
			bool add = false;
			bool open = BPSection("cases", "CASES", count, out add, "Add a case");
			if (add)
			{
				if (AddCase("NewCase") != null)
					FocusNameField();
			}
			if (!open)
				return;
			for (let m in Doc.Members)
			{
				if (m.Kind != .Case || !BPMatches(m.Name))
					continue;
				String label = scope .();
				label.AppendF("    {}", m.Name);
				if (m.CaseValue != null)
					label.AppendF(" = {}", m.CaseValue);
				if (!m.Payload.IsEmpty)
				{
					label.Append(" (");
					for (let p in m.Payload)
					{
						if (@p.Index > 0)
							label.Append(", ");
						label.AppendF("{} {}", p.Type?.ToString(.. scope String()), p.Name);
					}
					label.Append(")");
				}
				Gui.PushID((int32)(30000 + @m.Index));
				bool selected = OutlineSel == .Member && mSelMemberSerial == m.Serial;
				if (Gui.Selectable(label, selected))
					SelectOutline(.Member, m);
				if (MemberRowMenu(m))
				{
					Gui.PopID();
					return;
				}
				Gui.PopID();
			}
		}

		/// The Sheet in front when it can have locals, else null.
		Sheet OpenLocalsGraph()
		{
			let mg = CurrentMethod;
			if (mg == null || mg.Doc != Doc || !mg.Graphable || mg.Graph == null || mg.Graph.ReadOnly)
				return null;
			return mg;
		}

		/// LOCAL VARIABLES: the locals of the Sheet in front (Graph.Locals), each a draggable
		/// variable row; "+" adds one.
		void DrawOutlineLocals()
		{
			let mg = OpenLocalsGraph();
			int count = (mg != null) ? mg.Graph.Locals.Count : 0;
			bool add = false;
			bool open = BPSection("locals", "LOCAL VARIABLES", count, out add, (mg != null) ? "Add a local variable to this Sheet" : "");
			if (add && mg != null)
				AddLocalVariable(mg);
			if (!open)
				return;
			if (mg == null)
			{
				Gui.TextDisabled("    Open a Sheet to see its locals");
				return;
			}
			float h = Gui.igGetTextLineHeight();
			for (let local in mg.Graph.Locals)
			{
				if (!BPMatches(local.Name))
					continue;
				Gui.PushID((int32)(10000 + @local.Index));
				let cur = Gui.igGetCursorScreenPos();
				bool selected = mSelLocalActive && OutlineSel == .Local && mSelLocalName == local.Name;
				if (Gui.Selectable(scope $"##local{@local.Index}", selected))
				{
					mSelLocalActive = true;
					mSelLocalName.Set(local.Name);
					SelectOutline(.Local);
				}
				let dl = Gui.igGetWindowDrawList();
				let col = Theme.TypeColor(local.GetTypeText(.. scope String()));
				Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), col, h * 0.3f, 0);
				Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), selected ? Look.ForegroundHover : Look.Foreground, local.Name);
				{
					let max = Gui.igGetItemRectMax();
					String fit = scope .();
					float nameW = 42 * Look.Scale + Gui.CalcTextSize(local.Name).x + 12 * Look.Scale;
					FitText(local.GetTypeText(.. scope String()), Math.Max(0, max.x - cur.x - nameW), fit);
					float tw = Gui.CalcTextSize(fit).x;
					Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, cur.y), Gui.Color(120, 120, 120), fit);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{local.Name} : {local.GetTypeText(.. scope String())}\nDrag onto a pin to wire it, or onto the Sheet: Ctrl = Get, Alt = Set");
				AddMemberRef(.Variable, local.Name, local.GetTypeText(.. scope String()), "", "", false);
				if (Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
				{
					int32 idx = (int32)mMembers.Count - 1;
					Gui.igSetDragDropPayload("TREADLE_MEMBER", &idx, sizeof(int32), 0);
					Gui.igEndDragDropSource();
				}
				if (Gui.igBeginPopupContextItem())
				{
					if (IconItem(Icon.Trash2, "Delete Local Variable"))
					{
						BeginEdit();
						String why = scope .();
						if (!mg.Graph.RemoveLocal(local, why))
						{
							EditDoc.DropLastUndo();
							SetStatus(why, .Warning);
						}
						else
							CommitCurrent();
						Gui.EndPopup();
						Gui.PopID();
						return;
					}
					Gui.EndPopup();
				}
				Gui.PopID();
			}
		}

		/// A new local of the Sheet, with a fresh name; selected in the Outline.
		public void AddLocalVariable(Sheet mg)
		{
			if (!CheckWritable())
				return;
			String name = scope .();
			GraphPanel.UniqueLocalName(mg, "newVar", name);
			BeginEdit();
			NodeFactory.AddLocal(mg.Graph, name, "");
			mSelLocalActive = true;
			mSelLocalName.Set(name);
			SelectOutline(.Local);
			CommitCurrent();
			FocusNameField();
		}
	}
}
