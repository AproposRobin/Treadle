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

		/// Set by BPSection when its `extraLabel` button (FUNCTIONS: Override...) was clicked.
		bool mBPExtraClicked;

		/// Category bar. Returns whether the section is open; `addClicked` reports the "+", and
		/// `mBPExtraClicked` the `extraLabel` button drawn before it.
		bool BPSection(StringView id, StringView title, int count, out bool addClicked, StringView addTip, bool startsClosed = false, StringView extraLabel = default, StringView extraTip = default, uint32 titleColor = 0)
		{
			addClicked = false;
			mBPExtraClicked = false;
			float h = Gui.igGetFrameHeight();
			let p = Gui.igGetCursorScreenPos();
			float w = Gui.igGetContentRegionAvail().x;
			float fs = Gui.igGetFontSize();
			float extraW = extraLabel.IsEmpty ? 0 : Gui.CalcTextSize(extraLabel).x + 12 * Look.Scale;
			String key = scope .(id);
			bool open = startsClosed ? mBPOpened.Contains(key) : !mBPClosed.Contains(key);
			Gui.PushID(id);
			bool clicked = Gui.igInvisibleButton("##sec", .(Math.Max(1, w - (addTip.IsEmpty ? 0 : h + 2) - (extraLabel.IsEmpty ? 0 : extraW + 2)), h), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + w, p.y + h), hovered ? Gui.Color(56, 56, 56) : Look.Header, 2 * Look.Scale, 0);
			float ty = p.y + (h - fs) * 0.5f;
			Gui.DrawText(dl, .(p.x + 4 * Look.Scale, ty), Look.ForegroundDim, open ? Icon.ChevronDown : Icon.ChevronRight);
			Gui.DrawText(dl, .(p.x + fs * 1.3f, ty), (titleColor != 0) ? titleColor : Gui.Color(215, 215, 215), title);
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
			if (!extraLabel.IsEmpty)
			{
				Gui.SameLine(0, 2);
				let xp = Gui.igGetCursorScreenPos();
				bool hit = Gui.igInvisibleButton("##extra", .(extraW, h), ButtonFlags.MouseButtonLeft);
				bool xh = Gui.igIsItemHovered(0);
				Gui.ImDrawList_AddRectFilled(dl, xp, .(xp.x + extraW, xp.y + h), xh ? Look.Primary : Theme.Mix(Look.Header, Gui.Color(255, 255, 255), 0.06f), 2 * Look.Scale, 0);
				Gui.DrawText(dl, .(xp.x + 6 * Look.Scale, ty), Gui.Color(215, 215, 215), extraLabel);
				if (xh && !extraTip.IsEmpty)
					Gui.Tooltip(extraTip);
				mBPExtraClicked = hit;
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
					// The document header: "Dog : Animal", the kind and the "N required" badge.
					let h = Doc.Header;
					String docName = scope .();
					if (h.Name.IsEmpty)
						Doc.GetName(docName);
					else
						InheritanceLine(h, docName);
					String header = scope .();
					// The kind's glyph is drawn over the blank start of the label in the kind's colour (TypeStyle).
					let kindGlyph = KindIcon(h.Kind);
					int pad = (int)Math.Ceiling(Gui.CalcTextSize(kindGlyph).x / Math.Max(1.0f, Gui.CalcTextSize(" ").x));
					header.Append(' ', pad);
					header.AppendF("  {}  ###outlinetype", docName);
					Gui.igPushStyleColor_U32(Col.Header, Theme.Mix(Look.Header, Look.AccentBlue, 0.35f));
					Gui.igPushStyleColor_U32(Col.HeaderHovered, Theme.Mix(Look.Dropdown, Look.AccentBlue, 0.35f));
					Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundHover);
					bool open = Gui.CollapsingHeader(header, TreeNodeFlags.DefaultOpen);
					Gui.igPopStyleColor(3);
					{
						let gmin = Gui.igGetItemRectMin();
						let gmax = Gui.igGetItemRectMax();
						float gfs = Gui.igGetFontSize();
						Gui.DrawText(Gui.igGetWindowDrawList(), .(gmin.x + gfs * 1.9f, gmin.y + (gmax.y - gmin.y - gfs) * 0.5f), TypeStyle.KindColor(h.Kind), kindGlyph);
					}
					List<InheritedFn> required = scope .();
					List<InheritedFn> overridable = scope .();
					defer { ClearAndDeleteItems!(required); ClearAndDeleteItems!(overridable); }
					InheritedFunctions(h, Doc.Members, required, overridable);
					{
						let min = Gui.igGetItemRectMin();
						let max = Gui.igGetItemRectMax();
						if (Gui.igIsItemHovered(0))
						{
							String tip = scope .();
							tip.AppendF("{} {}", KindTitle(h.Kind), h.GetFullName(.. scope String()));
							if (!required.IsEmpty)
								tip.AppendF("\n{} required override{} not implemented", required.Count, (required.Count == 1) ? "" : "s");
							Gui.Tooltip(tip);
						}
						let dl = Gui.igGetWindowDrawList();
						StringView k = Treadle.Format.TreadleCodec.TypeKindWord(h.Kind);
						float kw = Gui.CalcTextSize(k).x;
						float ty = min.y + (max.y - min.y - Gui.igGetFontSize()) * 0.5f;
						// Where the title ends (the arrow, then the text): the kind word and the badge never cover it.
						float fsz = Gui.igGetFontSize();
						float titleEnd = min.x + fsz * 1.9f + Gui.CalcTextSize(scope $"{KindIcon(h.Kind)}  {docName}").x;
						String badge = scope .();
						if (!required.IsEmpty)
							badge.AppendF("{} required", required.Count);
						float bw = badge.IsEmpty ? 0 : Gui.CalcTextSize(badge).x + 10 * Look.Scale;
						float right = max.x - kw - 8 * Look.Scale;
						bool showKind = right - (badge.IsEmpty ? 0 : bw + 8 * Look.Scale) > titleEnd + 6 * Look.Scale;
						if (showKind)
							Gui.DrawText(dl, .(right, ty), Look.ForegroundDim, k);
						else
							right = max.x - 4 * Look.Scale;
						if (!badge.IsEmpty)
						{
							if (right - bw - 8 * Look.Scale < titleEnd)
							{
								// No room for the words: the count alone.
								badge.Set(scope $"{required.Count}");
								bw = Gui.CalcTextSize(badge).x + 10 * Look.Scale;
							}
							float bx = right - bw - (showKind ? 8 * Look.Scale : 0);
							Gui.ImDrawList_AddRectFilled(dl, .(bx, ty - 1), .(bx + bw, ty + fsz + 1), Theme.WithAlpha(Theme.Warning, 70), 6 * Look.Scale, 0);
							Gui.DrawText(dl, .(bx + 5 * Look.Scale, ty), Theme.Warning, badge);
						}
					}
					if (Gui.igBeginPopupContextItem("##typehdr"))
					{
						if (h.Kind == .Class && !h.Static && !h.Sealed && !Doc.FilePath.IsEmpty && KindMenuItem(.Class, "Make Child Class..."))
							StartMakeChild(Doc.FilePath);
						if (!Doc.FilePath.IsEmpty && IconItem(Icon.Copy, "Duplicate..."))
							StartDuplicate(Doc.FilePath);
						if (IconItem(Icon.Settings, "Type Settings"))
							SelectOutline(.TypeSettings);
						Gui.EndPopup();
					}
					if (open)
					{
						// Type Settings: the header (name, kind, base, interfaces, generics...) in Properties.
						{
							bool selected = OutlineSel == .TypeSettings;
							if (Gui.Selectable(scope $"    {Icon.Settings}  Type Settings##typesettings", selected))
								SelectOutline(.TypeSettings);
							if (Gui.igIsItemHovered(0))
								Gui.Tooltip("Name, kind, namespace, base class, interfaces, generic parameters and attributes of the type");
						}
						// The sections that apply to the kind (Editor-Model.md, "Outline").
						bool changed = false;
						switch (h.Kind)
						{
						case .Enum:
							DrawOutlineCases();
							changed = DrawSheetRows(overridable);
							if (!changed)
							{
								Gui.igSpacing();
								DrawOutlineLocals();
							}
						case .Interface:
							changed = DrawSheetRows(overridable);
						case .Delegate:
							DrawOutlineSignature();
						default:
							changed = DrawRequiredOverrides(required) || DrawSheetRows(overridable);
							if (!changed)
							{
								Gui.igSpacing();
								DrawOutlineFields();
								Gui.igSpacing();
								DrawOutlineLocals();
							}
						}
						if (changed)
						{
							Gui.End();
							return; // the document changed: its lists are rebuilt next frame
						}
					}
					if (Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && !Gui.igIsAnyItemActive())
						OutlineKeys();
				}
			}
			Gui.End();
		}

		/// The Outline's keys (it has the focus, nothing is being typed): Delete removes the selected
		/// variable, function, case or local as its row's Delete does, F2 renames it (its Name field in
		/// Properties), Enter opens it (its Sheet, else its page in Properties). The canvas handles its
		/// own Delete only when it has the focus (GraphPanel.HandleKeyboard).
		void OutlineKeys()
		{
			bool member = OutlineSel == .Member && SelectedMember != null;
			bool local = OutlineSel == .Local && mSelLocalActive;
			if (Gui.IsKeyPressed(573 /* F2 */, false) && (member || local))
				StartOutlineRename();
			if (Gui.IsKeyPressed(Key.Delete, false) && (member || local))
				DeleteOutlineSelection();
			if (Gui.IsKeyPressed(Key.Enter, false) && member)
			{
				let m = SelectedMember;
				Sheet body = null;
				for (let s in Doc.Sheets)
					if (s.Member == m && s.Role != .Lambda && body == null)
						body = s;
				if (body != null)
					OpenTab(body);
				else
					Panels.Focus(Panels.PropertiesId);
			}
		}

		/// Delete on the Outline: the selected member (RemoveMember, one undo step) or the selected
		/// local of the Sheet in front (as its row's Delete Local Variable). True when something went.
		public bool DeleteOutlineSelection()
		{
			if (OutlineSel == .Member)
			{
				let m = SelectedMember;
				if (m == null)
					return false;
				RemoveMember(m);
				SelectOutline(.None);
				return true;
			}
			if (OutlineSel == .Local && mSelLocalActive)
			{
				let mg = OpenLocalsGraph();
				if (mg == null)
					return false;
				for (let l in mg.Graph.Locals)
				{
					if (l.Name != mSelLocalName)
						continue;
					BeginEdit();
					String why = scope .();
					if (!mg.Graph.RemoveLocal(l, why))
					{
						EditDoc.DropLastUndo();
						SetStatus(why, .Warning);
						return false;
					}
					CommitCurrent();
					mSelLocalActive = false;
					SelectOutline(.None);
					return true;
				}
			}
			return false;
		}

		/// REQUIRED OVERRIDES (a class or a struct): the abstract functions of its base chain and the
		/// interface functions nothing provides yet, each with Implement; the "+" implements them all.
		/// Not drawn when there are none. True when the document changed.
		bool DrawRequiredOverrides(List<InheritedFn> required)
		{
			if (required.IsEmpty)
				return false;
			bool all = false;
			bool open = BPSection("required", "REQUIRED OVERRIDES", required.Count, out all, "Implement all: a Sheet for each, with its signature", false, default, default, Theme.Warning);
			if (all)
			{
				ImplementAllRequired();
				return true;
			}
			if (!open)
				return false;
			float fs = Gui.igGetFontSize();
			for (let f in required)
			{
				Gui.PushID((int32)(50000 + @f.Index));
				String sig = scope .();
				SignatureText(f.Fn, sig);
				let rowPos = Gui.igGetCursorScreenPos();
				float bw = Gui.CalcTextSize("Implement").x + 14 * Look.Scale;
				float w = Gui.igGetContentRegionAvail().x;
				bool clicked = Gui.Selectable(scope $"##req{@f.Index}", false, 0, .(Math.Max(1, w - bw - 4 * Look.Scale), 0));
				let max = Gui.igGetItemRectMax();
				let dl = Gui.igGetWindowDrawList();
				float ty = rowPos.y + (max.y - rowPos.y - fs) * 0.5f;
				Gui.DrawText(dl, .(rowPos.x + 14 * Look.Scale, ty), Theme.Warning, Icon.Function);
				String fit = scope .();
				FitText(sig, Math.Max(0, max.x - rowPos.x - 14 * Look.Scale - fs * 1.5f), fit);
				Gui.DrawText(dl, .(rowPos.x + 14 * Look.Scale + fs * 1.5f, ty), Look.Foreground, fit);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{sig}\nRequired by {f.From} ({f.FromInterface ? "an interface function" : "an abstract function"}): Implement makes its Sheet");
				Gui.SameLine(0, 4 * Look.Scale);
				bool impl = Gui.SmallButton("Implement");
				Gui.PopID();
				if (clicked || impl)
				{
					ImplementInherited(f);
					return true;
				}
			}
			return false;
		}

		/// SIGNATURE (a delegate type): its result and inputs in one row; the row opens Type Settings
		/// on the Signature section.
		void DrawOutlineSignature()
		{
			bool add = false;
			let sigRef = Doc.Header.Signature;
			int inputs = (sigRef != null && sigRef.Args != null) ? sigRef.Args.Count : 0;
			bool open = BPSection("signature", "SIGNATURE", inputs, out add, "Edit the result and the inputs in Type Settings > Signature");
			if (add)
			{
				SelectOutline(.TypeSettings);
				Panels.Focus(Panels.PropertiesId);
			}
			if (!open)
				return;
			String sig = scope .();
			if (sigRef != null)
				sigRef.AppendSignature(sig);
			else
				sig.Append("void()");
			if (Gui.Selectable(scope $"    {Icon.Link}  {sig}##sig", OutlineSel == .TypeSettings))
			{
				SelectOutline(.TypeSettings);
				Panels.Focus(Panels.PropertiesId);
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("The result and the input types a delegate of this type has; edit them in Type Settings > Signature");
		}

		/// The context menu of a member row: rename (in Properties), a function's inheritance
		/// (a class: Normal / Virtual / Override / Abstract), move, delete. True when the member was
		/// removed (the caller stops using it).
		bool MemberRowMenu(MemberDecl m)
		{
			if (!Gui.igBeginPopupContextItem())
				return false;
			bool removed = false;
			if (IconItem(Icon.Pencil, "Rename...", "F2"))
			{
				SelectOutline(.Member, m);
				StartOutlineRename();
			}
			if (m.Kind == .Function && Doc.Header.Kind == .Class && !m.Static)
			{
				Gui.Separator();
				Gui.TextDisabled("INHERITANCE");
				let cur = FunctionInheritance(m);
				for (let k in FnInheritance[?](.Normal, .Virtual, .Override, .Abstract))
					if (Gui.MenuItem(FnInheritanceName(k), "", cur == k))
						SetFunctionInheritance(m, k);
				Gui.Separator();
			}
			if (IconItem(Icon.ChevronUp, "Move Up"))
				MoveMember(m, -1);
			if (IconItem(Icon.ChevronDown, "Move Down"))
				MoveMember(m, 1);
			EntryMenuItem(m); // a static Main: Set as entry point (EntryPoint.bf)
			if (m.Kind == .Function || m.Kind == .Ctor || m.Kind == .Dtor || m.Kind == .Operator) HoodFunctionMenuItem(m); // Disassembly: DisassemblyPanel.bf
			if (IconItem(Icon.Trash2, "Delete", "Del"))
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
		bool DrawSheetRows(List<InheritedFn> overridable)
		{
			let currentKey = (CurrentTab != null && CurrentTab.Doc == Doc) ? CurrentTab.MethodKey : "";
			bool addMember = false;
			bool iface = Doc.Header.Kind == .Interface;
			int count = Doc.Sheets.Count;
			for (let m in Doc.Members)
				if ((m.Kind == .Property && m.Auto) || (m.Kind == .Function && !HasSheet(m)))
					count++;
			bool canOverride = Doc.Header.Kind == .Class && !overridable.IsEmpty;
			bool open = BPSection("sheets", "FUNCTIONS", count, out addMember, iface ? "Add a function signature (an interface has no bodies)" : "Add a function, property, constructor or destructor",
				false, canOverride ? "Override..." : "", "Override a virtual or abstract function of the base classes: its Sheet, with the same signature");
			if (canOverride && mBPExtraClicked)
				Gui.OpenPopup("##override");
			if (Gui.BeginPopup("##override"))
			{
				Gui.TextDisabled("OVERRIDE A FUNCTION OF THE BASE CLASSES");
				for (let f in overridable)
				{
					String sig = scope .();
					SignatureText(f.Fn, sig);
					if (Gui.MenuItem(scope $"{sig}##ov{@f.Index}", f.From))
					{
						ImplementInherited(f);
						Gui.EndPopup();
						return true;
					}
				}
				Gui.EndPopup();
			}
			if (addMember)
				Gui.OpenPopup("##addmember");
			if (Gui.BeginPopup("##addmember"))
			{
				if (IconItem(Icon.Function, iface ? "Function (signature)" : "Function"))
				{
					if ((iface ? AddFunctionSignature("NewFunction") : AddFunctionMember("NewFunction")) != null)
						FocusNameField();
				}
				if (!iface && IconItem(Icon.Variable, "Property"))
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
				bool renamable = m != null && m.Kind == .Function && mg.Role == .Body;
				if (renamable && Gui.igIsItemHovered(0) && Gui.igIsMouseDoubleClicked_Nil(0))
					StartInlineRename(m);
				bool renaming = renamable && InlineRenaming(m);
				{
					// The row: an icon (red for an override) and the name (what is typed for it while it is renamed).
					let dl = Gui.igGetWindowDrawList();
					let max = Gui.igGetItemRectMax();
					float ty = rowPos.y + (max.y - rowPos.y - fs) * 0.5f;
					Gui.DrawText(dl, .(rowPos.x + 14 * Look.Scale, ty), overrides ? Theme.HeaderOverride : Look.ForegroundDim, Icon.Function);
					if (!renaming)
						Gui.DrawText(dl, .(rowPos.x + 14 * Look.Scale + fs * 1.5f, ty), selected ? Look.ForegroundHover : Look.Foreground,
							renamable ? LiveName(scope $"##mname{m.Serial}", mg.Name) : (StringView)mg.Name);
					if (m != null && m.Static)
					{
						float tw = Gui.CalcTextSize("static").x;
						Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, ty), Gui.Color(120, 120, 120), "static");
						DrawEntryGlyph(dl, m, max.x, ty); // Program Start: a play glyph (EntryPoint.bf)
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
				if (renaming)
					InlineRenameMemberRow(m, .(rowPos.x + 14 * Look.Scale + fs * 1.5f, rowPos.y), Gui.igGetContentRegionAvail().x - 20 * Look.Scale - fs * 1.5f);
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
			// Functions without a body (an interface's signatures, abstract ones): a row each, for their page.
			for (let m in Doc.Members)
			{
				if (m.Kind != .Function || HasSheet(m) || !BPMatches(m.Name))
					continue;
				Gui.PushID((int32)(45000 + @m.Index));
				bool selected = OutlineSel == .Member && mSelMemberSerial == m.Serial;
				String sig = scope .();
				SignatureText(m, sig);
				if (Gui.Selectable(scope $"    {Icon.Function}  {sig}##nobody", selected))
					SelectOutline(.Member, m);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(iface ? "A signature: each class that implements the interface gives it a Sheet" : "No Sheet: an abstract function (a derived class overrides it)");
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
			DrawInheritedFields(); // InheritedVariables.bf: the base classes' variables this class can use
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
			if (Gui.Selectable("##field", selected, SelectableFlags.AllowDoubleClick))
				SelectOutline(.Member, m);
			if (Gui.igIsItemHovered(0) && Gui.igIsMouseDoubleClicked_Nil(0))
				StartInlineRename(m);
			bool renaming = InlineRenaming(m);
			String type = scope .();
			m.Type?.ToString(type);
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), Theme.TypeColor(type), h * 0.3f, 0);
			if (!renaming)
				Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), selected ? Look.ForegroundHover : Look.Foreground, LiveName(scope $"##mname{m.Serial}", m.Name));
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
				StorageTip(m, null, tip); // Lives in: LivesIn.bf
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
			if (renaming)
				InlineRenameMemberRow(m, .(cur.x + 42 * Look.Scale, cur.y), Gui.igGetContentRegionAvail().x - 46 * Look.Scale - (cur.x - Gui.igGetCursorScreenPos().x));
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
				if (Gui.Selectable(scope $"##local{@local.Index}", selected, SelectableFlags.AllowDoubleClick))
				{
					mSelLocalActive = true;
					mSelLocalName.Set(local.Name);
					SelectOutline(.Local);
				}
				if (Gui.igIsItemHovered(0) && Gui.igIsMouseDoubleClicked_Nil(0))
					StartInlineRenameLocal(local.Name);
				bool renaming = InlineRenamingLocal(local.Name);
				let dl = Gui.igGetWindowDrawList();
				let col = Theme.TypeColor(local.GetTypeText(.. scope String()));
				Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), col, h * 0.3f, 0);
				if (!renaming)
					Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), selected ? Look.ForegroundHover : Look.Foreground, selected ? LiveName("##lname", local.Name) : (StringView)local.Name);
				{
					let max = Gui.igGetItemRectMax();
					String fit = scope .();
					float nameW = 42 * Look.Scale + Gui.CalcTextSize(local.Name).x + 12 * Look.Scale;
					FitText(local.GetTypeText(.. scope String()), Math.Max(0, max.x - cur.x - nameW), fit);
					float tw = Gui.CalcTextSize(fit).x;
					Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, cur.y), Gui.Color(120, 120, 120), fit);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{local.Name} : {local.GetTypeText(.. scope String())}{StorageTip(null, local, .. scope String())}\nDrag onto a pin to wire it, or onto the Sheet: Ctrl = Get, Alt = Set");
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
				if (renaming)
				{
					InlineRenameLocalRow(mg, local, .(cur.x + 42 * Look.Scale, cur.y), Gui.igGetContentRegionAvail().x - 46 * Look.Scale);
					if (mIrId.IsEmpty)
					{
						Gui.PopID();
						break; // committed: the next frame draws the renamed list
					}
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
