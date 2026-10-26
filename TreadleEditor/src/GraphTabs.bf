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

		void CollectTabSlots(List<TabSlot> slots)
		{
			for (let t in Tabs)
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

		/// The Window menu's list of open Sheets: click one to bring it to the front.
		void DrawOpenSheetsMenu()
		{
			if (Tabs.IsEmpty)
				return;
			Gui.Separator();
			Gui.TextDisabled("Open Sheets");
			for (let tab in Tabs)
			{
				String label = scope .();
				label.AppendF("{}{}###opensheet{}", tab.Title, tab.Doc.Modified ? " *" : "", tab.Uid);
				if (IconItem(Icon.Function, label, "", tab == CurrentTab))
				{
					let mg = tab.Doc.FindSheet(tab.MethodKey);
					if (mg != null)
						OpenTab(mg);
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
}
