using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Editor
{
	/// Moving around a Sheet: saved views 1-9 (Ctrl+digit saves, digit jumps, kept per function in the
	/// layout file as `#view` lines), Home (the entry node at 1:1, or the whole graph when there is
	/// none), Fit all, the small Home / Fit buttons in the upper right of the canvas, and the
	/// one-second toast that confirms a view.
	extension GraphPanel
	{
		/// ImGui's key code of the digit 0; the digit n is KeyDigit0 + n.
		const int32 KeyDigit0 = 536;

		/// Self-test captures: where the pointer is taken to be (x < -1e30 = the real pointer).
		public ImVec2 SelfTestMouse = .(-3e38f, -3e38f);

		String mNavToast = new .() ~ delete _;
		double mNavToastUntil;
		/// How long a toast stays (seconds); a self-test capture raises it.
		public double NavToastHold = 1.0;

		/// Room the Home / Fit buttons take at the top of the canvas (the zoom label sits below them).
		float NavButtonsHeight => 34 * Look.Scale;

		void NavToast(StringView text)
		{
			mNavToast.Set(text);
			mNavToastUntil = Gui.igGetTime() + NavToastHold;
			GraphTab.sAnimUntil = Math.Max(GraphTab.sAnimUntil, mNavToastUntil + 0.1);
			Desktop.Wake();
		}

		/// The toast currently shown (empty when none): for the self-test.
		public StringView NavToastText => (Gui.igGetTime() < mNavToastUntil) ? mNavToast : "";

		void DrawNavToast(GraphTab tab, ImDrawList* dl)
		{
			double left = mNavToastUntil - Gui.igGetTime();
			if (left <= 0 || mNavToast.IsEmpty)
				return;
			float s = Look.Scale;
			float fa = (float)Math.Clamp(left / 0.25, 0, 1);
			float fs = Gui.igGetFontSize() * 1.15f;
			let tw = Gui.CalcTextSize(mNavToast).x * 1.15f;
			float padX = 14 * s;
			float padY = 8 * s;
			let p0 = ImVec2(tab.CanvasOrigin.x + (tab.CanvasSize.x - tw) * 0.5f - padX, tab.CanvasOrigin.y + tab.CanvasSize.y - fs - padY * 2 - 36 * s);
			let p1 = ImVec2(p0.x + tw + padX * 2, p0.y + fs + padY * 2);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, Gui.Color(18, 18, 22, (uint8)(225 * fa)), 8 * s, 0);
			Gui.ImDrawList_AddRect(dl, p0, p1, Gui.Color(120, 126, 140, (uint8)(200 * fa)), 8 * s, 1, 0);
			Gui.DrawText(dl, .(p0.x + padX, p0.y + padY), Gui.Color(240, 242, 248, (uint8)(255 * fa)), mNavToast, fs);
		}

		static int32 NearestZoomLevel(float zoom)
		{
			int32 best = 0;
			float bestD = float.MaxValue;
			for (int32 i < Canvas.ZoomLevels.Count)
			{
				float d = Math.Abs(Canvas.ZoomLevels[i] - zoom);
				if (d < bestD)
				{
					bestD = d;
					best = i;
				}
			}
			return best;
		}

		/// Ctrl+digit: remembers the current pan and zoom as view `n` of this function.
		public void SaveView(GraphTab tab, int n)
		{
			if (n < 1 || n > 9 || tab.CanvasSize.x <= 0)
				return;
			let c = tab.ViewCenter;
			tab.Doc.SetView(tab.MethodKey, n, c.x, c.y, tab.Zoom);
			mApp.LayoutChanged();
			NavToast(scope $"View {n} saved");
		}

		/// digit: eases to view `n` (about 150 ms), or says it is not set.
		public bool JumpToView(GraphTab tab, int n)
		{
			let v = (n >= 1 && n <= 9) ? tab.Doc.FindView(tab.MethodKey, n) : null;
			if (v == null)
			{
				NavToast(scope $"View {n} is not set (Ctrl+{n} saves it)");
				return false;
			}
			tab.AnimateTo(v.X, v.Y, NearestZoomLevel(v.Zoom));
			NavToast(scope $"View {n}");
			return true;
		}

		/// Clears one saved view (n = 0: all of this function's views).
		public int ClearSavedViews(GraphTab tab, int n)
		{
			int removed = tab.Doc.ClearViews(tab.MethodKey, n);
			if (removed > 0)
				mApp.LayoutChanged();
			return removed;
		}

		/// Home: the entry node at zoom 1 (eased), or the whole graph when the Sheet has no entry node.
		public void GoHome(GraphTab tab, Graph graph)
		{
			if (graph.Entry == null)
			{
				FrameNodes(tab, graph, false);
				return;
			}
			let level = Canvas.DefaultZoomLevel;
			float z = Canvas.ZoomLevels[level];
			// The same placement as the first view of a Sheet: the entry node near the left, a quarter down.
			tab.AnimateTo(CanvasHalf(tab).x / z + graph.Entry.X - 60, CanvasHalf(tab).y / z + graph.Entry.Y - tab.CanvasSize.y * 0.25f, level);
		}

		static ImVec2 CanvasHalf(GraphTab tab) => .(tab.CanvasSize.x * 0.5f, tab.CanvasSize.y * 0.5f);

		/// Fit all: zoom and pan so the whole graph is in view.
		public void FitAll(GraphTab tab, Graph graph)
		{
			FrameNodes(tab, graph, false);
		}

		bool NavButton(ImDrawList* dl, StringView id, StringView icon, StringView tip, float size)
		{
			float s = Look.Scale;
			let pos = Gui.igGetCursorScreenPos();
			Gui.PushID(id);
			bool clicked = Gui.igInvisibleButton("##nb", .(size, size), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			bool held = Gui.igIsItemActive();
			Gui.PopID();
			uint32 bg = held ? Look.PrimaryPress : (hovered ? Look.Dropdown : Gui.Color(24, 25, 30, 190));
			Gui.ImDrawList_AddRectFilled(dl, pos, pos + ImVec2(size, size), bg, 5 * s, 0);
			Gui.ImDrawList_AddRect(dl, pos, pos + ImVec2(size, size), Gui.Color(110, 114, 124, hovered ? (uint8)230 : (uint8)130), 5 * s, 1, 0);
			// Centred on the glyph's own pixels (Icon.DrawCentered), not on its text box.
			Icon.DrawCentered(dl, pos + ImVec2(size * 0.5f, size * 0.5f), size * 0.62f, hovered ? Look.ForegroundHover : Look.Foreground, icon);
			if (hovered)
			{
				mNavOver = true;
				Gui.Tooltip(tip);
			}
			return clicked;
		}

		/// The Home and Fit all buttons in the upper right of the canvas.
		void DrawNavButtons(GraphTab tab, Sheet mg, Graph graph)
		{
			mNavOver = false;
			float s = Look.Scale;
			float bs = 26 * s;
			float gap = 4 * s;
			if (tab.CanvasSize.x < 260 * s || tab.CanvasSize.y < 120 * s)
				return;
			let p = ImVec2(tab.CanvasOrigin.x + tab.CanvasSize.x - 8 * s - (bs * 2 + gap), tab.CanvasOrigin.y + 8 * s);
			Gui.igSetCursorScreenPos(p);
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(0, 0, 0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(gap, 0));
			if (Gui.igBeginChild_Str("##vbnavbtns", .(bs * 2 + gap, bs), 0, WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse))
			{
				let dl = Gui.igGetWindowDrawList();
				bool popup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
				if (NavButton(dl, "home", Icon.House, "Go to the entry node (Home)", bs) && !popup)
					GoHome(tab, graph);
				Gui.SameLine();
				if (NavButton(dl, "fit", Icon.Maximize, "Fit the whole graph", bs) && !popup)
					FitAll(tab, graph);
			}
			Gui.igEndChild();
			Gui.igPopStyleVar(2);
			Gui.igPopStyleColor(1);
		}

		/// Height the breadcrumbs took this frame (0 when not drawn): the find bar sits under them.
		float mCrumbsH;
		/// The crumbs drawn last frame, for the self test ("Player > TakeDamage > Lambda b12").
		public String CrumbsText = new .() ~ delete _;

		/// The breadcrumbs in the upper left of the canvas: the type, then each Sheet from the function
		/// down to the one in front (a Lambda's Sheet under the Sheet that holds its node). The type opens
		/// Type Settings, a Sheet before the last one opens that Sheet.
		void DrawBreadcrumbs(GraphTab tab, Sheet mg)
		{
			mCrumbsH = 0;
			CrumbsText.Clear();
			float s = Look.Scale;
			if (mg == null || tab.CanvasSize.x < 260 * s || tab.CanvasSize.y < 120 * s)
				return;
			List<Sheet> chain = scope .();
			mApp.SheetChain(mg, chain);
			List<String> labels = scope .();
			defer { ClearAndDeleteItems!(labels); }
			labels.Add(new String(mg.Doc.Header.Name));
			for (let sh in chain)
				labels.Add((sh.Role == .Lambda) ? new $"Lambda {sh.LambdaNode}" : new String(sh.Name));
			for (let l in labels)
				CrumbsText.AppendF("{}{}", CrumbsText.IsEmpty ? "" : " > ", l);
			float h = 24 * s;
			float padX = 9 * s;
			float sepW = 18 * s;
			float w = padX * 2;
			for (let l in labels)
				w += Gui.CalcTextSize(l).x + ((@l.Index > 0) ? sepW : 0);
			// Leaves room for the Home / Fit buttons on the right.
			w = Math.Min(w, tab.CanvasSize.x - 100 * s);
			let p = ImVec2(tab.CanvasOrigin.x + 8 * s, tab.CanvasOrigin.y + 8 * s);
			Gui.igSetCursorScreenPos(p);
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(0, 0, 0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(0, 0));
			if (Gui.igBeginChild_Str("##vbcrumbs", .(w, h), 0, WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse))
			{
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRectFilled(dl, p, p + ImVec2(w, h), Theme.WithAlpha(Theme.CanvasBg, 200), 5 * s, 0);
				Gui.ImDrawList_AddRect(dl, p, p + ImVec2(w, h), Gui.Color(110, 114, 124, 110), 5 * s, 1, 0);
				bool popup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
				float fs = Gui.igGetFontSize();
				float x = p.x + padX;
				float ty = p.y + (h - fs) * 0.5f;
				for (let l in labels)
				{
					int i = @l.Index;
					if (i > 0)
					{
						Icon.DrawCentered(dl, .(x + sepW * 0.5f, p.y + h * 0.5f), fs * 0.8f, Theme.TextDim, Icon.ChevronRight);
						x += sepW;
					}
					float lw = Gui.CalcTextSize(l).x;
					bool last = i == labels.Count - 1;
					bool clicked = false;
					bool hovered = false;
					if (!last)
					{
						Gui.igSetCursorScreenPos(.(x, p.y));
						Gui.PushID((int32)i);
						clicked = Gui.igInvisibleButton("##crumb", .(Math.Max(lw, 1), h), ButtonFlags.MouseButtonLeft);
						hovered = Gui.igIsItemHovered(0);
						Gui.PopID();
					}
					uint32 col = last ? Look.Foreground : (hovered ? Look.ForegroundHover : Theme.TextDim);
					Gui.DrawText(dl, .(x, ty), col, l, fs);
					if (hovered)
					{
						Gui.ImDrawList_AddLine(dl, .(x, ty + fs + 1), .(x + lw, ty + fs + 1), col, 1);
						Gui.Tooltip((i == 0) ? "Type Settings" : scope $"Open {l}");
					}
					if (clicked && !popup)
					{
						if (i == 0)
							mApp.SelectOutline(.TypeSettings);
						else
							mApp.OpenTab(chain[i - 1]);
					}
					x += lw;
				}
				if (Gui.igIsWindowHovered(0))
					mNavOver = true;
			}
			Gui.igEndChild();
			Gui.igPopStyleVar(2);
			Gui.igPopStyleColor(1);
			mCrumbsH = h + 6 * s;
		}

		/// Window > Saved Views: this Sheet's views (go to one, clear one) and Clear All.
		public void DrawViewsMenu(GraphTab tab)
		{
			if (!Gui.BeginMenu("Saved Views", tab != null))
				return;
			int count = 0;
			for (int n = 1; n <= 9; n++)
			{
				let v = tab.Doc.FindView(tab.MethodKey, n);
				String label = scope .();
				if (v != null)
				{
					count++;
					label.AppendF("View {}  (x {}, y {}, zoom {})", n, (int)v.X, (int)v.Y, v.Zoom);
				}
				else
					label.AppendF("View {}  (not set)", n);
				if (Gui.BeginMenu(label, true))
				{
					if (Gui.MenuItem("Go to", scope $"{n}", false, v != null))
						JumpToView(tab, n);
					if (Gui.MenuItem("Save here", scope $"Ctrl+{n}"))
						SaveView(tab, n);
					if (Gui.MenuItem("Clear", "", false, v != null))
						ClearSavedViews(tab, n);
					Gui.EndMenu();
				}
			}
			Gui.Separator();
			if (Gui.MenuItem("Clear All Views", "", false, count > 0))
				ClearSavedViews(tab, 0);
			Gui.EndMenu();
		}
	}
}
