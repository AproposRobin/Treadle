using System;
using System.Collections;
using ImGui;
using Treadle.Document;

namespace Treadle.Editor
{
	/// Ctrl+Tab: the list of open Sheets, most recently used first (the document switcher of other node
	/// editors). Ctrl+Tab opens it on the Sheet used before this one; Tab / Shift+Tab (Ctrl still held)
	/// move down / up; releasing Ctrl opens the highlighted Sheet; Esc closes the list; a click on a row
	/// opens that Sheet. A quick tap of Ctrl+Tab goes back and forth between the last two Sheets.
	extension EditorApp
	{
		/// Graph tab Uids in the order they were last in front (most recent first).
		List<int32> mTabMru = new .() ~ delete _;
		/// The list is up: its rows (tab Uids, most recent first) and the highlighted row.
		bool mSwitcherOpen;
		List<int32> mSwitcherRows = new .() ~ delete _;
		int mSwitcherIndex;
		double mSwitcherSince;
		/// The list is drawn once Ctrl has been held this long after Tab (a tap only switches).
		const double cSwitcherDelay = 0.12;
		/// Frames the list was drawn (the self test reads it).
		public int SwitcherDrawn;
		/// Captures: the list stays up without Ctrl held.
		public bool SwitcherPinned;

		/// Puts the tab in front at the head of the most-recently-used list (once per frame).
		void TrackTabMru()
		{
			let tab = CurrentTab;
			if (tab == null)
				return;
			if (!mTabMru.IsEmpty && mTabMru[0] == tab.Uid)
				return;
			mTabMru.Remove(tab.Uid);
			mTabMru.Insert(0, tab.Uid);
			if (mTabMru.Count > 64)
				mTabMru.RemoveAt(mTabMru.Count - 1);
		}

		GraphTab TabByUid(int32 uid)
		{
			for (let t in Tabs)
				if (t.Uid == uid)
					return t;
			return null;
		}

		/// The open Sheet tabs, most recently used first (tabs never in front come last, in bar order).
		public void SheetsByRecentUse(List<GraphTab> outTabs)
		{
			outTabs.Clear();
			for (let uid in mTabMru)
			{
				let t = TabByUid(uid);
				if (t != null && t.Doc != null && t.Doc.FindSheet(t.MethodKey) != null && !outTabs.Contains(t))
					outTabs.Add(t);
			}
			for (let t in Tabs)
				if (t.Doc != null && t.Doc.FindSheet(t.MethodKey) != null && !outTabs.Contains(t))
					outTabs.Add(t);
		}

		/// Ctrl+Tab (dir 1) / Ctrl+Shift+Tab (dir -1): opens the list on the Sheet used before this one
		/// (or the least recent one), or moves the highlight while it is open.
		public bool SheetSwitcherStep(int dir)
		{
			if (!mSwitcherOpen)
			{
				List<GraphTab> tabs = scope .();
				SheetsByRecentUse(tabs);
				if (tabs.Count < 2)
					return false;
				mSwitcherRows.Clear();
				for (let t in tabs)
					mSwitcherRows.Add(t.Uid);
				mSwitcherOpen = true;
				mSwitcherSince = Gui.igGetTime();
				mSwitcherIndex = (dir >= 0) ? 1 : tabs.Count - 1;
				return true;
			}
			let count = mSwitcherRows.Count;
			if (count == 0)
				return false;
			mSwitcherIndex = ((mSwitcherIndex + dir) % count + count) % count;
			return true;
		}

		/// Releasing Ctrl (or a click on a row): the highlighted Sheet comes to the front; the list closes.
		public bool SheetSwitcherCommit()
		{
			if (!mSwitcherOpen)
				return false;
			mSwitcherOpen = false;
			SwitcherPinned = false;
			if (mSwitcherIndex < 0 || mSwitcherIndex >= mSwitcherRows.Count)
				return false;
			let tab = TabByUid(mSwitcherRows[mSwitcherIndex]);
			let mg = (tab != null) ? tab.Doc.FindSheet(tab.MethodKey) : null;
			if (mg == null)
				return false;
			OpenTab(mg);
			return true;
		}

		public void SheetSwitcherCancel()
		{
			mSwitcherOpen = false;
			SwitcherPinned = false;
		}

		public bool SheetSwitcherOpen => mSwitcherOpen;

		/// The highlighted row's Sheet name (the self test).
		public void SheetSwitcherHighlighted(String outName)
		{
			if (!mSwitcherOpen || mSwitcherIndex < 0 || mSwitcherIndex >= mSwitcherRows.Count)
				return;
			let tab = TabByUid(mSwitcherRows[mSwitcherIndex]);
			if (tab != null)
				outName.Append(tab.Title);
		}

		/// The keys: called from HandleShortcuts while Ctrl is held (and once more when it is released).
		void SheetSwitcherKeys(bool ctrl)
		{
			TrackTabMru();
			if (mSwitcherOpen)
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
				{
					SheetSwitcherCancel();
					return;
				}
				if (!ctrl && !SwitcherPinned)
				{
					SheetSwitcherCommit();
					return;
				}
			}
			if (ctrl && !Gui.IsAltDown && Tabs.Count > 1)
			{
				// While Ctrl is held the Tab key is owned here, so ImGui's own Ctrl+Tab window switcher stays out
				// of the way (it reads the key's owner of the frame before).
				Gui.igSetKeyOwner(Key.Tab, cSheetTabsKeyOwner, 0);
				if (Gui.IsKeyPressed(Key.Tab, true) && (mSwitcherOpen || !Gui.igIsAnyItemActive()))
					SheetSwitcherStep(Gui.IsShiftDown ? -1 : 1);
			}
		}

		/// The list, centred over the Graph area, once Ctrl has been held a moment.
		void DrawSheetSwitcher()
		{
			if (!mSwitcherOpen)
				return;
			if (!SwitcherPinned && Gui.igGetTime() - mSwitcherSince < cSwitcherDelay)
				return;
			let vp = Gui.igGetMainViewport();
			float scale = Look.Scale;
			Gui.igSetNextWindowPos(.(vp.WorkPos.x + vp.WorkSize.x * 0.5f, vp.WorkPos.y + vp.WorkSize.y * 0.4f), Cond.Always, .(0.5f, 0.5f));
			Gui.igSetNextWindowSizeConstraints(.(320 * scale, 0), .(560 * scale, vp.WorkSize.y * 0.7f), null, null);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(10 * scale, 10 * scale));
			Gui.igPushStyleVar_Float(StyleVarX.WindowRounding, 6 * scale);
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Panel);
			Gui.igPushStyleColor_U32(Col.Border, Look.DropdownOutline);
			int32 flags = WindowFlags.NoTitleBar | WindowFlags.NoResize | WindowFlags.NoMove | WindowFlags.NoSavedSettings |
				WindowFlags.NoDocking | WindowFlags.AlwaysAutoResize | WindowFlags.NoScrollbar | WindowFlagsX.NoFocusOnAppearing | WindowFlagsX.NoNav;
			if (Gui.Begin("##sheetswitcher", null, flags))
			{
				SwitcherDrawn++;
				Gui.TextColored(Look.ForegroundDim, "OPEN SHEETS");
				Gui.SameLine();
				Gui.TextColored(Look.ForegroundDim, "   most recent first");
				Gui.igSeparator();
				int clicked = -1;
				float colX = 0;
				for (let uid in mSwitcherRows)
				{
					let tab = TabByUid(uid);
					if (tab != null)
						colX = Math.Max(colX, Gui.CalcTextSize(scope $"{Icon.Function}  {tab.Title}").x);
				}
				colX += Gui.igGetStyle().WindowPadding.x + 28 * scale;
				for (int i < mSwitcherRows.Count)
				{
					let tab = TabByUid(mSwitcherRows[i]);
					if (tab == null)
						continue;
					let mg = tab.Doc.FindSheet(tab.MethodKey);
					if (mg == null)
						continue;
					String type = scope .();
					tab.Doc.GetName(type);
					String row = scope $"{(mg.Role == .Lambda) ? Icon.SquareFunction : Icon.Function}  {tab.Title}";
					Gui.PushID((int32)i);
					bool hi = i == mSwitcherIndex;
					if (hi)
						Gui.igPushStyleColor_U32(Col.Header, Look.Primary);
					if (Gui.Selectable(row, hi, 0))
						clicked = i;
					if (hi)
						Gui.igPopStyleColor(1);
					// The type column lines up after the longest Sheet name.
					Gui.SameLine(colX);
					Gui.TextColored(hi ? Look.Foreground : Look.ForegroundDim, type);
					if (tab.Doc.Modified)
					{
						Gui.SameLine();
						Gui.TextColored(Look.ForegroundDim, "*");
					}
					Gui.PopID();
				}
				Gui.igSeparator();
				Gui.TextColored(Look.ForegroundDim, "Tab / Shift+Tab move, release Ctrl to open, Esc closes");
				if (clicked >= 0)
				{
					mSwitcherIndex = clicked;
					SheetSwitcherCommit();
				}
			}
			Gui.End();
			Gui.igPopStyleColor(2);
			Gui.igPopStyleVar(2);
		}
	}
}
