using System;
using System.Collections;
using ImGui;
using Treadle.Document;

namespace Treadle.Editor
{
	/// Closing and listing the tabs of the Graph area: the middle mouse button, Ctrl+W, the tab's context menu (Close,
	/// Close Others, Close All, Close to the Right) and the Window menu's list of open Sheets (docs/Editor-UI.md, Layout).
	/// A close is asked for here and done at the start of the next draw of the tab bar, never in the middle of its loop.
	extension EditorApp
	{
		/// One tab of the bar, with where it was drawn last frame (tabs can be reordered).
		struct TabSlot
		{
			public GraphTab Graph;
			public float X;

			public bool Is(TabSlot o) => Graph == o.Graph;
		}

		enum TabCloseKind
		{
			This,
			Others,
			All,
			ToTheRight
		}

		/// Tabs to close at the next draw, by their Uid (a tab that is gone by then is skipped).
		List<int32> mCloseGraphUids = new .() ~ delete _;
		/// The tab the context menu is open for.
		int32 mTabMenuGraphUid;
		bool mTabMenuOpen;
		/// A capture opens the menu under its tab, where a right-click would have the pointer.
		bool mTabMenuPinned;
		ImVec2 mTabMenuPos;

		/// The Sheet tabs of the type in front (the strip shows only those), in the order they are drawn.
		void CollectTabSlots(List<TabSlot> slots)
		{
			for (let t in Tabs)
				if (t.Doc == Doc)
					slots.Add(TabSlot() { Graph = t, X = t.BarX });
			slots.Sort(scope (a, b) => a.X <=> b.X);
		}

		void RequestClose(TabSlot s)
		{
			if (s.Graph != null)
				mCloseGraphUids.Add(s.Graph.Uid);
		}

		public void RequestCloseGraphTab(GraphTab tab)
		{
			if (tab != null)
				mCloseGraphUids.Add(tab.Uid);
		}

		/// Ctrl+W: the tab in front.
		void CloseActiveTab()
		{
			if (CurrentTab != null)
				mCloseGraphUids.Add(CurrentTab.Uid);
		}

		void RequestCloseTabs(TabSlot anchor, TabCloseKind kind)
		{
			List<TabSlot> slots = scope .();
			CollectTabSlots(slots);
			bool after = false;
			for (let s in slots)
			{
				bool isAnchor = s.Is(anchor);
				bool close = false;
				switch (kind)
				{
				case .This: close = isAnchor;
				case .Others: close = !isAnchor;
				case .All: close = true;
				case .ToTheRight: close = after;
				}
				if (isAnchor)
					after = true;
				if (close)
					RequestClose(s);
			}
		}

		/// Takes out what was asked to close. Called before the tab bar is drawn.
		void ApplyTabCloses()
		{
			if (mCloseGraphUids.IsEmpty)
				return;
			for (let uid in mCloseGraphUids)
			{
				for (int i = 0; i < Tabs.Count; i++)
				{
					let tab = Tabs[i];
					if (tab.Uid != uid)
						continue;
					if (mLastActiveTab == tab)
						mLastActiveTab = null;
					if (mSelectTab == tab)
						mSelectTab = null;
					Tabs.RemoveAt(i);
					delete tab;
					break;
				}
			}
			mCloseGraphUids.Clear();
			if (ActiveTab >= Tabs.Count)
				ActiveTab = Tabs.Count - 1;
		}

		/// Right after a tab item is submitted: remembers where it is, takes the middle button and opens its menu.
		void TabItemInput(GraphTab graphTab)
		{
			let x = Gui.igGetItemRectMin().x;
			graphTab.BarX = x;
			if (Gui.igIsItemHovered(0) && Gui.igIsMouseClicked_Bool(2, false))
				mCloseGraphUids.Add(graphTab.Uid);
			if (Gui.igIsItemClicked(1))
			{
				mTabMenuGraphUid = graphTab.Uid;
				// Opened by DrawTabMenu: inside a visible tab ImGui has the tab's id on the id stack, outside it has not.
				mTabMenuOpen = true;
			}
		}

		/// The tab context menu (called inside the tab bar, where TabItemInput opened it).
		void DrawTabMenu()
		{
			if (mTabMenuOpen)
			{
				mTabMenuOpen = false;
				Gui.OpenPopup("##graphtabmenu");
			}
			if (mTabMenuPinned && Gui.igIsPopupOpen_Str("##graphtabmenu", 0))
				Gui.igSetNextWindowPos(mTabMenuPos, Cond.Always, .(0, 0));
			if (!Gui.BeginPopup("##graphtabmenu"))
				return;
			TabSlot anchor = default;
			for (let t in Tabs)
				if (t.Uid == mTabMenuGraphUid)
					anchor.Graph = t;
			if (anchor.Graph == null)
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			List<TabSlot> slots = scope .();
			CollectTabSlots(slots);
			bool anyRight = false;
			bool seen = false;
			for (let s in slots)
			{
				if (s.Is(anchor))
					seen = true;
				else if (seen)
					anyRight = true;
			}
			if (Gui.MenuItem("Close", "Ctrl+W"))
				RequestCloseTabs(anchor, .This);
			if (Gui.MenuItem("Close Others", "", false, slots.Count > 1))
				RequestCloseTabs(anchor, .Others);
			if (Gui.MenuItem("Close All"))
				RequestCloseTabs(anchor, .All);
			if (Gui.MenuItem("Close to the Right", "", false, anyRight))
				RequestCloseTabs(anchor, .ToTheRight);
			Gui.EndPopup();
		}

		/// The Window menu's list of open Sheets under the name of their type: click one to bring it (and its type)
		/// to the front.
		void DrawOpenSheetsMenu()
		{
			if (Tabs.IsEmpty)
				return;
			Gui.Separator();
			Gui.TextDisabled("Open Sheets");
			for (let ctx in TypeContexts)
			{
				bool any = false;
				for (let tab in Tabs)
					if (tab.Doc == ctx.Doc)
						any = true;
				if (!any)
					continue;
				String type = scope .();
				ctx.Doc.GetName(type);
				let kind = ctx.Doc.Header.Kind;
				Gui.TextColored(TypeStyle.KindColor(kind), scope $"{TypeStyle.KindIcon(kind)}  {type}");
				for (let tab in Tabs)
				{
					if (tab.Doc != ctx.Doc)
						continue;
					String label = scope .();
					label.AppendF("  {}{}###opensheet{}", tab.Title, tab.Doc.Modified ? " *" : "", tab.Uid);
					if (IconItem(Icon.Function, label, "", tab == CurrentTab))
					{
						let mg = tab.Doc.FindSheet(tab.MethodKey);
						if (mg != null)
							OpenTab(mg);
					}
				}
			}
			Gui.Separator();
			if (IconItem(Icon.X, "Close Tab", "Ctrl+W", false, CurrentTab != null))
				CloseActiveTab();
			if (IconItem(Icon.X, "Close All Tabs", "", false, !Tabs.IsEmpty))
			{
				List<TabSlot> slots = scope .();
				CollectTabSlots(slots);
				for (let s in slots)
					RequestClose(s);
			}
		}
	}

	/// One open type in the Graph area (docs/Editor-Model.md, "Type context"): its document, the Sheet tab
	/// last in front there and where its tab of the type strip was drawn. The Sheet tabs themselves stay in
	/// EditorApp.Tabs; the strip under the type strip shows those of the type in front only.
	class TypeContext
	{
		static int32 sNextUid;
		public int32 Uid = ++sNextUid;
		public TypeDocument Doc;
		public int32 ActiveTabUid;
		/// Where its type tab was drawn last frame (the strip can be reordered); not drawn yet: after the rest.
		public float BarX = float.MaxValue;
	}

	/// The type strip over the Sheet tabs: one tab per open type (kind icon, name, closable, reorderable), the
	/// type in front highlighted in its kind's colour. `Doc` is the type in front: the Sheet tabs, the header
	/// strip, the Outline and Properties follow it. Ctrl+Shift+Page Down / Up cycle the types.
	extension EditorApp
	{
		/// The open types in the order they were opened (TypeContext.BarX holds the order the strip shows).
		public List<TypeContext> TypeContexts = new .() ~ DeleteContainerAndItems!(_);
		/// The type seen in front last (a pointer compare only: the document may be gone).
		TypeDocument mFrontType;
		/// Type contexts to close at the next draw of the strip, by Uid.
		List<int32> mCloseTypeUids = new .() ~ delete _;
		/// A click on a type tab, applied after the strip is drawn (0: none).
		int32 mActivateTypeUid;
		int32 mTypeMenuUid;
		bool mTypeMenuOpen;
		/// A drag from the Outline resting on another type's tab brings that type to the front after a moment.
		int32 mTypeHoverUid;
		double mTypeHoverSince;
		/// The dragged Outline row, kept when a drag switches the type in front: the Outline then lists the
		/// other type, whose rows the payload's index would point into (DragGhost.bf: DraggedRef).
		public MemberRef HeldDrag ~ delete _;
		public int32 HeldDragIndex;
		/// The self test holds the row without a mouse drag.
		public bool HeldDragPinned;
		const double cTypeHoverDelay = 0.4;
		/// Sheet tabs submitted to the strip last frame (the self test: only the type in front's).
		public int DrawnSheetTabs;

		/// Keeps the member dragged as Outline row `index` for the rest of the drag (another type comes to the
		/// front while it is dragged; dropping it on that type's Sheet places a Call or a Get / Set of it).
		public void HoldDragAcrossTypes(int32 index)
		{
			let m = DraggedRef(index);
			if (m == null || m == HeldDrag)
				return;
			let copy = new MemberRef();
			copy.MemberKind = m.MemberKind;
			copy.Name.Set(m.Name);
			copy.Type.Set(m.Type);
			copy.Params.Set(m.Params);
			copy.Owner.Set(m.Owner);
			copy.IsStatic = m.IsStatic;
			delete HeldDrag;
			HeldDrag = copy;
			HeldDragIndex = index;
		}

		/// The drag ended: the kept row goes.
		void ReleaseHeldDrag()
		{
			if (HeldDrag == null || HeldDragPinned || mSelfTestDrag != null || DragNative.Active("TREADLE_MEMBER") != null)
				return;
			DeleteAndNullify!(HeldDrag);
		}

		public TypeContext FindTypeContext(TypeDocument doc)
		{
			for (let c in TypeContexts)
				if (c.Doc == doc)
					return c;
			return null;
		}

		TypeContext TypeContextByUid(int32 uid)
		{
			for (let c in TypeContexts)
				if (c.Uid == uid)
					return c;
			return null;
		}

		/// A document the editor holds (pointer compare only, so a deleted one is never read).
		bool IsLoadedDoc(TypeDocument doc)
		{
			if (doc == null || doc == mEmptyDoc)
				return false;
			for (let d in mDocs)
				if (d == doc)
					return true;
			return false;
		}

		TypeContext EnsureTypeContext(TypeDocument doc)
		{
			var ctx = FindTypeContext(doc);
			if (ctx == null)
			{
				ctx = new TypeContext();
				ctx.Doc = doc;
				TypeContexts.Add(ctx);
			}
			return ctx;
		}

		/// The open types in the order the strip shows them.
		public void CollectTypeSlots(List<TypeContext> outList)
		{
			outList.Clear();
			outList.AddRange(TypeContexts);
			outList.Sort(scope (a, b) => (a.BarX == b.BarX) ? (a.Uid <=> b.Uid) : (a.BarX <=> b.BarX));
		}

		/// The Sheet tab most recently in front among those of `doc` (bar order when none was), or null.
		GraphTab FrontTabOf(TypeDocument doc)
		{
			let ctx = FindTypeContext(doc);
			if (ctx != null)
				for (let t in Tabs)
					if (t.Doc == doc && t.Uid == ctx.ActiveTabUid)
						return t;
			for (let uid in mTabMru)
				for (let t in Tabs)
					if (t.Uid == uid && t.Doc == doc)
						return t;
			GraphTab first = null;
			for (let t in Tabs)
				if (t.Doc == doc && (first == null || t.BarX < first.BarX))
					first = t;
			return first;
		}

		/// Keeps the type contexts and the Sheet tab in front in step with `Doc`, the type in front: every type
		/// with an open Sheet and Doc have a context, contexts of documents that were closed go, and the tab in
		/// front is one of Doc's (the one last in front there) or none. `frame`: the once-per-frame call, which
		/// also restores and saves the per-project layout (DocumentHeader.bf).
		void SyncTypeContexts(bool frame = false)
		{
			if (frame)
			{
				SyncTypeLayoutProject();
				ReleaseHeldDrag();
			}
			for (int i = TypeContexts.Count - 1; i >= 0; i--)
			{
				if (!IsLoadedDoc(TypeContexts[i].Doc))
				{
					delete TypeContexts[i];
					TypeContexts.RemoveAt(i);
				}
			}
			for (let t in Tabs)
				if (IsLoadedDoc(t.Doc))
					EnsureTypeContext(t.Doc);
			if (IsLoadedDoc(Doc))
				EnsureTypeContext(Doc);
			else if (Doc == mEmptyDoc && !TypeContexts.IsEmpty)
			{
				// The type in front was closed (its file deleted, the project switched): the one used last.
				TypeDocument pick = null;
				for (let uid in mTabMru)
				{
					let t = TabByUid(uid);
					if (t != null && FindTypeContext(t.Doc) != null)
					{
						pick = t.Doc;
						break;
					}
				}
				Doc = pick ?? TypeContexts.Back.Doc;
			}
			let ctx = FindTypeContext(Doc);
			let cur = (ActiveTab >= 0 && ActiveTab < Tabs.Count) ? Tabs[ActiveTab] : null;
			if (ctx == null)
			{
				if (cur != null && cur.Doc != Doc)
					ActiveTab = -1;
			}
			else if (cur == null || cur.Doc != Doc)
			{
				let pick = FrontTabOf(Doc);
				ActiveTab = (pick != null) ? Tabs.IndexOf(pick) : -1;
				if (pick != null)
				{
					mSelectTab = pick;
					mLastActiveTab = pick;
					ctx.ActiveTabUid = pick.Uid;
				}
			}
			else
				ctx.ActiveTabUid = cur.Uid;
			if (Doc != mFrontType)
			{
				// Another type came to the front: the Outline and Properties show it (a local's page belonged to
				// a Sheet of the other type).
				mFrontType = Doc;
				if (OutlineSel == .Local)
					OutlineSel = .None;
				mSelLocalActive = false;
				mSourceVersion = -1;
			}
			if (frame)
				SaveTypeLayoutIfChanged();
		}

		/// Brings a type to the front with the Sheet that was last in front there.
		public void ActivateType(TypeDocument doc)
		{
			if (!IsLoadedDoc(doc))
				return;
			if (doc != Doc)
			{
				mSelDeclActive = false;
				Doc = doc;
			}
			SyncTypeContexts();
		}

		/// Ctrl+Shift+Page Down / Up: the next / previous type in the strip's order (wrapping).
		public bool CycleType(int dir)
		{
			List<TypeContext> order = scope .();
			CollectTypeSlots(order);
			if (order.Count < 2)
				return false;
			int at = 0;
			for (let c in order)
				if (c.Doc == Doc)
					at = @c.Index;
			ActivateType(order[(at + dir + order.Count) % order.Count].Doc);
			return true;
		}

		public void RequestCloseType(TypeDocument doc)
		{
			let ctx = FindTypeContext(doc);
			if (ctx != null && !mCloseTypeUids.Contains(ctx.Uid))
				mCloseTypeUids.Add(ctx.Uid);
		}

		/// Takes out the types asked to close (before the strip is drawn).
		void ApplyTypeCloses()
		{
			if (mCloseTypeUids.IsEmpty)
				return;
			for (let uid in mCloseTypeUids)
			{
				let ctx = TypeContextByUid(uid);
				if (ctx != null)
					CloseType(ctx.Doc);
			}
			mCloseTypeUids.Clear();
		}

		/// Closes a type: its Sheet tabs close (the document stays loaded with any unsaved edits, as closing a
		/// tab never saves or discards); the type next to it in the strip comes to the front.
		public void CloseType(TypeDocument doc)
		{
			let ctx = FindTypeContext(doc);
			if (ctx == null)
				return;
			List<TypeContext> order = scope .();
			CollectTypeSlots(order);
			let at = order.IndexOf(ctx);
			for (int i = Tabs.Count - 1; i >= 0; i--)
			{
				let tab = Tabs[i];
				if (tab.Doc != doc)
					continue;
				if (mLastActiveTab == tab)
					mLastActiveTab = null;
				if (mSelectTab == tab)
					mSelectTab = null;
				if (mActionTab == tab)
					mActionTab = null;
				if (i == ActiveTab)
					ActiveTab = -1;
				else if (i < ActiveTab)
					ActiveTab--;
				Tabs.RemoveAt(i);
				delete tab;
			}
			order.Remove(ctx);
			TypeContexts.Remove(ctx);
			delete ctx;
			if (Doc == doc)
			{
				Doc = order.IsEmpty ? mEmptyDoc : order[Math.Clamp(at, 0, order.Count - 1)].Doc;
				ActiveTab = -1;
			}
			SyncTypeContexts();
		}

		/// The type strip (drawn at the top of the Graph area, over the Sheet tabs).
		void DrawTypeStrip()
		{
			ApplyTypeCloses();
			if (TypeContexts.IsEmpty)
				return;
			float s = Look.Scale;
			float fs = Gui.igGetFontSize();
			let dl = Gui.igGetWindowDrawList();
			let p0 = Gui.igGetCursorScreenPos();
			let padY = Math.Round(fs * 0.38f);
			let rowH = fs + padY * 2;
			// The strip sits on the title colour, a step darker than the Sheet tabs under it.
			Gui.ImDrawList_AddRectFilled(dl, p0, .(p0.x + Gui.igGetContentRegionAvail().x, p0.y + rowH + 1), Look.Title, 0, 0);
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(10 * s, padY));
			Gui.igPushStyleColor_U32(ColX.Tab, Look.Title);
			Gui.igPushStyleColor_U32(ColX.TabDimmed, Look.Title);
			String pad = scope .();
			let iconW = Gui.CalcTextSize(Icon.Class).x + 6 * s;
			while (Gui.CalcTextSize(pad).x < iconW)
				pad.Append(' ');
			if (Gui.igBeginTabBar("##types", 1 << 0 /* Reorderable */ | 1 << 5 /* NoTooltip */ | 1 << 6 /* DrawSelectedOverline */))
			{
				for (let ctx in TypeContexts)
				{
					let kind = ctx.Doc.Header.Kind;
					let accent = TypeStyle.KindColor(kind);
					bool front = ctx.Doc == Doc;
					String name = scope .();
					ctx.Doc.GetName(name);
					String label = scope .();
					label.AppendF("{}{}{}###type{}", pad, name, ctx.Doc.Modified ? " *" : "", ctx.Uid);
					Gui.igPushStyleColor_U32(ColX.TabSelectedOverline, accent);
					Gui.igPushStyleColor_U32(ColX.TabDimmedSelectedOverline, accent);
					Gui.igPushStyleColor_U32(ColX.TabSelected, Theme.Mix(Look.Panel, accent, 0.30f));
					Gui.igPushStyleColor_U32(ColX.TabDimmedSelected, Theme.Mix(Look.Panel, accent, 0.30f));
					bool open = true;
					bool shown = Gui.igBeginTabItem(label, &open, front ? TabItemFlags.SetSelected : 0);
					Gui.igPopStyleColor(4);
					let rmin = Gui.igGetItemRectMin();
					let rmax = Gui.igGetItemRectMax();
					ctx.BarX = rmin.x;
					bool hovered = Gui.igIsItemHovered(0);
					if (hovered && Gui.igIsMouseClicked_Bool(0, false) && !front)
						mActivateTypeUid = ctx.Uid;
					// A variable or function dragged from the Outline and held over this tab: the type comes to the
					// front, so the drag can end on one of its Sheets (a Call / Get / Set of the dragged member).
					if (!front && Gui.igIsItemHovered(HoveredFlags.AllowWhenBlockedByActiveItem))
					{
						let payload = DragNative.Active("TREADLE_MEMBER");
						if (payload != null && payload.Data != null && payload.DataSize >= sizeof(int32))
						{
							if (mTypeHoverUid != ctx.Uid)
							{
								mTypeHoverUid = ctx.Uid;
								mTypeHoverSince = Gui.igGetTime();
							}
							else if (Gui.igGetTime() - mTypeHoverSince > cTypeHoverDelay)
							{
								HoldDragAcrossTypes(*(int32*)payload.Data);
								mActivateTypeUid = ctx.Uid;
								mTypeHoverUid = 0;
							}
						}
					}
					else if (mTypeHoverUid == ctx.Uid)
						mTypeHoverUid = 0;
					if (hovered && Gui.igIsMouseClicked_Bool(2, false))
						RequestCloseType(ctx.Doc);
					if (Gui.igIsItemClicked(1))
					{
						mTypeMenuUid = ctx.Uid;
						mTypeMenuOpen = true;
					}
					if (hovered && !Gui.igIsMouseDragging(0, -1))
					{
						String tip = scope .();
						TypeTitle(ctx.Doc, tip);
						tip.AppendF("\n{} {}", TypeStyle.KindWord(kind), ctx.Doc.Header.Namespace.IsEmpty ? "(no namespace)" : (StringView)ctx.Doc.Header.Namespace);
						if (!ctx.Doc.FilePath.IsEmpty)
							tip.AppendF("\n{}", ctx.Doc.FilePath);
						Gui.Tooltip(tip);
					}
					Gui.DrawText(dl, .(rmin.x + 10 * s, rmin.y + (rmax.y - rmin.y - fs) * 0.5f), front ? accent : Theme.Mix(accent, Look.Title, 0.35f), TypeStyle.KindIcon(kind));
					if (shown)
						Gui.igEndTabItem();
					if (!open)
						RequestCloseType(ctx.Doc);
				}
				DrawTypeMenu();
				Gui.igEndTabBar();
			}
			Gui.igPopStyleColor(2);
			Gui.igPopStyleVar(1);
			if (mActivateTypeUid != 0)
			{
				let ctx = TypeContextByUid(mActivateTypeUid);
				mActivateTypeUid = 0;
				if (ctx != null)
					ActivateType(ctx.Doc);
			}
		}

		/// The type tab's context menu.
		void DrawTypeMenu()
		{
			if (mTypeMenuOpen)
			{
				mTypeMenuOpen = false;
				Gui.OpenPopup("##typetabmenu");
			}
			if (!Gui.BeginPopup("##typetabmenu"))
				return;
			let ctx = TypeContextByUid(mTypeMenuUid);
			if (ctx == null)
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			if (IconItem(Icon.Settings, "Type Settings"))
			{
				ActivateType(ctx.Doc);
				SelectOutline(.TypeSettings);
				Panels.Focus(Panels.PropertiesId);
			}
			if (IconItem(Icon.Browse, "Show in Project Browser", "", false, !ctx.Doc.FilePath.IsEmpty))
			{
				ActivateType(ctx.Doc);
				BrowseToCurrent();
			}
			Gui.Separator();
			if (Gui.MenuItem("Close"))
				RequestCloseType(ctx.Doc);
			if (Gui.MenuItem("Close Other Types", "", false, TypeContexts.Count > 1))
				for (let c in TypeContexts)
					if (c != ctx)
						RequestCloseType(c.Doc);
			if (Gui.MenuItem("Close All Types"))
				for (let c in TypeContexts)
					RequestCloseType(c.Doc);
			Gui.EndPopup();
		}
	}
}
