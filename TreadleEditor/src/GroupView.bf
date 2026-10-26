using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Editor
{
	/// Collapsed node groups on the canvas (Graph.Groups, Graph-Format.md 3.1 `group`): a folded group is
	/// one node in place of its members, with a pin for each pin of theirs that has a wire crossing the
	/// group's edge (its wires end there; dragging from it wires the member's pin); a double-click opens
	/// it. An open group is a frame around its nodes with a title bar: a double-click on the bar folds it,
	/// dragging the bar moves the group. Folding is layout (the sidecar's `collapsed <id>`); making and
	/// removing a group are edits of the Sheet (undo).
	extension GraphPanel
	{
		/// The node drawn for each folded group, by group id: its pin lists hold the members' pins
		/// (borrowed: emptied before the node is deleted).
		Dictionary<int32, Node> mGroupProxies = new .() ~ { for (let kv in _) { kv.value.Inputs.Clear(); kv.value.Outputs.Clear(); delete kv.value; } delete _; };
		/// Pin labels of the folded groups' nodes this frame.
		List<String> mGroupLabels = new .() ~ DeleteContainerAndItems!(_);
		/// The folded groups' node layouts this frame (owned by the layout pool).
		List<NodeLay> mGroupLays = new .() ~ delete _;
		/// The open groups this frame: id and frame (grid units, title bar included).
		List<(int32 id, float x0, float y0, float x1, float y1)> mGroupFrames = new .() ~ delete _;
		/// The open group whose title bar is under the pointer.
		int32 mHoverGroupFrame;
		/// The group the group menu is open for.
		int32 mCtxGroup;
		TextBuffer mGroupTitleBuf = new .(256) ~ delete _;
		/// Folded groups drawn last frame (the self test).
		public int FoldedGroupsDrawn;

		float GroupBarH => mFontSize + 12;

		/// The self test: the pins of a folded group's node last frame (false when it was not drawn).
		public bool GroupPinCounts(int32 groupId, out int ins, out int outs)
		{
			ins = 0;
			outs = 0;
			if (!mGroupProxies.TryGetValue(groupId, let proxy) || !mLayById.ContainsKey(groupId))
				return false;
			ins = proxy.Inputs.Count;
			outs = proxy.Outputs.Count;
			return true;
		}

		/// The self test: whether node `id` was hidden in a folded group last frame.
		public bool IsHiddenNode(int32 id) => mLayById.TryGetValue(id, let L) && L.Node != null && L.Node.Id == id && L.Hidden;

		/// The self test: open groups drawn last frame.
		public int OpenGroupFrames => mGroupFrames.Count;

		/// Whether the layout file folds the group (`collapsed <id>`).
		public bool IsGroupCollapsed(GraphTab tab, NodeGroup gr)
		{
			if (tab == null || tab.Doc == null || tab.Doc.Collapsed.IsEmpty)
				return false;
			String key = scope $"{tab.MethodKey}|{gr.Key}";
			for (let c in tab.Doc.Collapsed)
				if (c == key)
					return true;
			return false;
		}

		/// Folds or opens a group (layout only). Opening selects its nodes; folding selects the group.
		public void SetGroupCollapsed(GraphTab tab, Graph graph, NodeGroup gr, bool collapsed)
		{
			if (tab == null || gr == null || IsGroupCollapsed(tab, gr) == collapsed)
				return;
			String key = scope $"{tab.MethodKey}|{gr.Key}";
			if (collapsed)
				tab.Doc.Collapsed.Add(new String(key));
			else
			{
				for (let c in tab.Doc.Collapsed)
					if (c == key)
					{
						tab.Doc.Collapsed.Remove(c);
						delete c;
						break;
					}
			}
			tab.ClearSelection();
			if (collapsed)
				tab.SelectedNodes.Add(gr.Id);
			else
				for (let k in gr.Nodes)
				{
					let n = graph.FindNodeByKey(k);
					if (n != null)
						tab.AddToSelection(n.Id);
				}
			mApp.LayoutChanged();
		}

		/// The text a folded group's pin shows: the member pin's label (flow pins none, unless the side has
		/// several: then the member's title).
		void GroupPinLabel(Pin p, int flowOnSide, String outLabel)
		{
			if (p.Kind == .Flow)
			{
				if (flowOnSide > 1)
				{
					p.Owner.GetTitle(outLabel);
					if (!p.Label.IsEmpty)
						outLabel.AppendF(" {}", p.Label);
				}
				else
					outLabel.Append(p.Label);
				return;
			}
			outLabel.Append(p.Label.IsEmpty ? p.Name : p.Label);
		}

		/// After the nodes are laid out: each folded group's members are hidden and its node laid out (its
		/// pins take the members' pins' places for the wires); each open group's frame is measured.
		void LayoutGroups(GraphTab tab, Graph graph)
		{
			mGroupLays.Clear();
			mGroupFrames.Clear();
			ClearAndDeleteItems!(mGroupLabels);
			FoldedGroupsDrawn = 0;
			int index = graph.Nodes.Count;
			for (let gr in graph.Groups)
			{
				if (gr.Id == 0)
					gr.Id = -graph.NewId();
				HashSet<Node> members = scope .();
				for (let k in gr.Nodes)
				{
					let n = graph.FindNodeByKey(k);
					if (n != null && mLayById.ContainsKey(n.Id))
						members.Add(n);
				}
				if (members.IsEmpty)
					continue;
				if (!IsGroupCollapsed(tab, gr))
				{
					float x0 = float.MaxValue, y0 = float.MaxValue, x1 = float.MinValue, y1 = float.MinValue;
					for (let n in members)
					{
						let L = mLayById[n.Id];
						x0 = Math.Min(x0, n.X);
						y0 = Math.Min(y0, n.Y);
						x1 = Math.Max(x1, n.X + L.W);
						y1 = Math.Max(y1, n.Y + Math.Max(L.H, L.StripY + L.StripH));
					}
					const float pad = 16;
					mGroupFrames.Add((gr.Id, x0 - pad, y0 - pad - GroupBarH, x1 + pad, y1 + pad));
					continue;
				}
				for (let n in members)
				{
					let L = mLayById[n.Id];
					L.Hidden = true;
					L.Visible = false;
				}
				// The members' pins with a wire crossing the edge, in the members' order on the canvas.
				List<Pin> ins = scope .();
				List<Pin> outs = scope .();
				for (let l in graph.Links)
				{
					bool fromIn = members.Contains(l.From.Owner);
					bool toIn = members.Contains(l.To.Owner);
					if (fromIn == toIn)
						continue;
					let p = fromIn ? l.From : l.To;
					let list = p.IsInput ? ins : outs;
					if (!list.Contains(p))
						list.Add(p);
				}
				int Order(Pin a, Pin b)
				{
					int c = (a.Kind == .Flow ? 0 : 1) <=> (b.Kind == .Flow ? 0 : 1);
					if (c == 0) c = a.Owner.Y <=> b.Owner.Y;
					if (c == 0) c = a.Owner.X <=> b.Owner.X;
					if (c == 0)
					{
						let la = a.IsInput ? a.Owner.Inputs : a.Owner.Outputs;
						let lb = b.IsInput ? b.Owner.Inputs : b.Owner.Outputs;
						c = la.IndexOf(a) <=> lb.IndexOf(b);
					}
					return c;
				}
				ins.Sort(scope (a, b) => Order(a, b));
				outs.Sort(scope (a, b) => Order(a, b));

				if (!mGroupProxies.TryGetValue(gr.Id, var proxy))
				{
					proxy = new Node();
					proxy.Kind = .Unknown;
					proxy.KindWord = new String("Group");
					proxy.IsPure = true;
					mGroupProxies[gr.Id] = proxy;
				}
				proxy.Id = gr.Id;
				proxy.Key.Set(gr.Key);
				proxy.X = gr.X;
				proxy.Y = gr.Y;
				proxy.HasPos = true;
				proxy.Inputs.Clear();
				proxy.Outputs.Clear();
				proxy.Inputs.AddRange(ins);
				proxy.Outputs.AddRange(outs);

				while (mLayPool.Count <= index)
					mLayPool.Add(new NodeLay());
				let L = mLayPool[index++];
				L.Reset();
				L.Node = proxy;
				L.Shape = .Normal;
				L.Selected = mSelectedNow.Contains(gr.Id);
				L.Header = Theme.Mix(Theme.HeaderFlow, Look.AccentBlue, 0.45f);
				L.Title.Set(gr.Title.IsEmpty ? "Collapsed Nodes" : (StringView)gr.Title);
				L.Subtitle.AppendF("{} node{}  \u{00B7}  double-click to open", members.Count, (members.Count == 1) ? "" : "s");
				mLayById[gr.Id] = L;
				float fh = mFontSize;
				float rowH = RowH;
				L.HeaderH = fh + 10 + fh * 0.85f + 2;
				float startY = L.HeaderH + 6;
				int flowIn = 0;
				int flowOut = 0;
				for (let p in ins)
					if (p.Kind == .Flow)
						flowIn++;
				for (let p in outs)
					if (p.Kind == .Flow)
						flowOut++;
				float leftMax = 0;
				float rightMax = 0;
				int firstRight = 0;
				for (int side < 2)
				{
					let list = (side == 0) ? ins : outs;
					if (side == 1)
						firstRight = mPins.Count;
					for (let p in list)
					{
						String label = new .();
						GroupPinLabel(p, (side == 0) ? flowIn : flowOut, label);
						mGroupLabels.Add(label);
						PinLay pl = default;
						pl.Pin = p;
						pl.Node = L;
						pl.Visible = true;
						pl.RowY = startY + @p.Index * rowH;
						pl.LabelText = label;
						pl.LabelW = label.IsEmpty ? 0 : Gui.CalcTextSize(label).x;
						if (side == 0)
						{
							pl.Off = .(12, pl.RowY + rowH * 0.5f);
							pl.LabelX = 24;
							leftMax = Math.Max(leftMax, 24 + pl.LabelW + 10);
						}
						else
							rightMax = Math.Max(rightMax, 24 + pl.LabelW + 10);
						AddPin(pl);
					}
				}
				float iconW = HeaderIconW(proxy);
				L.W = Math.Max(leftMax + rightMax + 24, Gui.CalcTextSize(L.Title).x + 40 + iconW);
				L.W = Math.Max(L.W, Gui.CalcTextSize(L.Subtitle).x * 0.85f + 40 + iconW);
				L.W = Math.Max(L.W, 140);
				L.H = startY + Math.Max(Math.Max(ins.Count, outs.Count), 1) * rowH + 6;
				for (int i = firstRight; i < mPins.Count; i++)
				{
					var pl = ref mPins[i];
					pl.Off = .(L.W - 12, pl.RowY + rowH * 0.5f);
					pl.LabelX = L.W - 24;
				}
				mGroupLays.Add(L);
				FoldedGroupsDrawn++;
			}
			// Nodes of groups that are gone.
			List<int32> stale = scope .();
			for (let kv in mGroupProxies)
				if (graph.FindGroup(kv.key) == null)
					stale.Add(kv.key);
			for (let id in stale)
			{
				if (mGroupProxies.GetAndRemove(id) case .Ok(let kv))
				{
					kv.value.Inputs.Clear();
					kv.value.Outputs.Clear();
					delete kv.value;
				}
			}
		}

		/// The open groups: a tinted frame around the nodes with a title bar (under the wires and nodes).
		void DrawGroupFrames(GraphTab tab, Graph graph, ImDrawList* dl)
		{
			float z = tab.Zoom;
			float fh = mFontSize;
			for (let f in mGroupFrames)
			{
				let gr = graph.FindGroup(f.id);
				if (gr == null)
					continue;
				let p0 = tab.GridToScreen(f.x0, f.y0);
				let p1 = tab.GridToScreen(f.x1, f.y1);
				let bar1 = ImVec2(p1.x, p0.y + GroupBarH * z);
				bool selected = tab.IsSelected(f.id);
				bool hovered = mHoverGroupFrame == f.id;
				uint32 accent = Theme.Mix(Theme.HeaderFlow, Look.AccentBlue, 0.45f);
				Gui.ImDrawList_AddRectFilled(dl, p0, p1, Theme.WithAlpha(accent, 26), 6 * z, 0);
				Gui.ImDrawList_AddRectFilled(dl, p0, bar1, Theme.WithAlpha(accent, hovered ? 150 : 110), 6 * z, DrawFlags.RoundCornersTop);
				Gui.ImDrawList_AddRect(dl, p0, p1, selected ? Theme.NodeSelected : Theme.WithAlpha(accent, 200), 6 * z, selected ? Math.Max(1.5f, 2 * z) : Math.Max(1, 1.2f * z), 0);
				if (fh * z < 5)
					continue;
				float tx = p0.x + 8 * z;
				float ty = p0.y + (GroupBarH - fh) * 0.5f * z;
				if (Icon.Loaded)
				{
					Text(dl, .(tx, ty), fh * z, Theme.NodeTitle, Icon.Layers);
					tx += fh * 1.3f * z;
				}
				String title = scope .(gr.Title.IsEmpty ? "Collapsed Nodes" : (StringView)gr.Title);
				Text(dl, .(tx, ty), fh * z, Theme.NodeTitle, title);
				const String hint = "double-click to fold";
				float hw = Gui.CalcTextSize(hint).x * 0.85f * z;
				float tw = Gui.CalcTextSize(title).x * z;
				if (p1.x - 10 * z - hw > tx + tw + 16 * z)
					Text(dl, .(p1.x - 10 * z - hw, ty + fh * 0.1f * z), fh * 0.85f * z, Theme.WithAlpha(Theme.NodeTitle, 150), hint);
			}
		}

		/// The pointer over an open group's title bar (the topmost): mHoverGroupFrame. True when it is.
		bool HitGroupFrame(GraphTab tab, ImVec2 mouse)
		{
			for (int i = mGroupFrames.Count - 1; i >= 0; i--)
			{
				let f = mGroupFrames[i];
				let p0 = tab.GridToScreen(f.x0, f.y0);
				let p1 = tab.GridToScreen(f.x1, f.y0 + GroupBarH);
				if (Canvas.RectContains(p0, p1, mouse))
				{
					mHoverGroupFrame = f.id;
					return true;
				}
			}
			return false;
		}

		/// The group menu: Open / Fold, the title, Select Nodes, Ungroup, Delete.
		void DrawGroupPopup(GraphTab tab, Sheet mg)
		{
			let graph = mg.Graph;
			if (SelfTestPopupPos.x > -1e30f)
				Gui.igSetNextWindowPos(SelfTestPopupPos, Cond.Appearing, .(0, 0));
			if (!Gui.BeginPopup("##vbgroupctx"))
			{
				mGroupTitleBuf.Set("");
				return;
			}
			let gr = graph.FindGroup(mCtxGroup);
			if (gr == null)
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			bool folded = IsGroupCollapsed(tab, gr);
			Gui.TextDisabled(scope $"Group  \u{00B7}  {gr.Nodes.Count} node{(gr.Nodes.Count == 1) ? "" : "s"}");
			Gui.Separator();
			if (Gui.MenuItem(folded ? "Open Group" : "Fold Group", "Double-click"))
				SetGroupCollapsed(tab, graph, gr, !folded);
			// The title, typed in place (Enter applies it, one undo step).
			if (mGroupTitleBuf.View.IsEmpty)
				mGroupTitleBuf.Set(gr.Title);
			Gui.igSetNextItemWidth(220 * Look.Scale);
			if (Gui.igInputTextWithHint("##grouptitle", "Title", mGroupTitleBuf.Ptr, (.)mGroupTitleBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null))
			{
				var t = mGroupTitleBuf.View;
				t.Trim();
				if (t != gr.Title)
				{
					mApp.BeginEdit();
					gr.Title.Set(t);
					graph.Version++;
					mApp.CommitCurrent();
					mCommitted = true;
				}
				Gui.igCloseCurrentPopup();
			}
			if (Gui.MenuItem("Select Nodes"))
			{
				tab.ClearSelection();
				for (let k in gr.Nodes)
				{
					let n = graph.FindNodeByKey(k);
					if (n != null)
						tab.AddToSelection(n.Id);
				}
				if (folded)
					SetGroupCollapsed(tab, graph, gr, false);
			}
			if (Gui.MenuItem("Ungroup"))
			{
				if (mApp.Ungroup(tab, gr))
					mCommitted = true;
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("The group goes; its nodes stay where they are");
			if (Gui.MenuItem("Delete Group and Nodes", "Del"))
			{
				tab.SelectOnly(gr.Id);
				mApp.DeleteSelection(tab);
				mCommitted = true;
			}
			Gui.EndPopup();
		}
	}
}
