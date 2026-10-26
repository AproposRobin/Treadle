using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// Collapse Nodes (node menu, Ctrl+G): the selected nodes become a node group of the Sheet, folded
	/// behind one node (GroupView.bf draws it); Ungroup removes the group. Each is one undo step; folding
	/// and opening are layout.
	extension EditorApp
	{
		/// Why the last Collapse Nodes was refused ("" when it was not).
		public String GroupRefusal = new .() ~ delete _;

		/// The selected groups' nodes join the selection in their place (Delete, Copy, Duplicate, Disable
		/// and Extract to Function act on a group's nodes).
		public void ExpandGroupsInSelection(GraphTab tab, Graph g)
		{
			for (int i = tab.SelectedNodes.Count - 1; i >= 0; i--)
			{
				let id = tab.SelectedNodes[i];
				if (id >= 0)
					continue;
				tab.SelectedNodes.RemoveAt(i);
				let gr = g.FindGroup(id);
				if (gr == null)
					continue;
				for (let k in gr.Nodes)
				{
					let n = g.FindNodeByKey(k);
					if (n != null)
						tab.AddToSelection(n.Id);
				}
			}
		}

		/// Collapse Nodes: a group of the selected nodes (not the Entry, none already in a group), folded,
		/// drawn where they were. False with the reason in the status line and `GroupRefusal`.
		public bool CollapseSelectionToGroup(GraphTab tab)
		{
			GroupRefusal.Clear();
			let mg = (tab != null) ? tab.Doc.FindSheet(tab.MethodKey) : null;
			if (mg == null || !CheckWritable() || mg.Graph.ReadOnly)
				return false;
			let g = mg.Graph;
			List<Node> nodes = scope .();
			for (let id in tab.SelectedNodes)
			{
				let n = g.FindNode(id);
				if (n == null || n == g.Entry)
					continue;
				let other = g.GroupOf(n);
				if (other != null)
				{
					GroupRefusal.Set(scope $"{n.GetTitle(.. scope String())} is in the group {other.Title} already: ungroup it first");
					SetStatus(scope $"Collapse Nodes: {GroupRefusal}", .Warning);
					return false;
				}
				nodes.Add(n);
			}
			if (nodes.IsEmpty)
			{
				GroupRefusal.Set("select the nodes to fold first (the Entry stays out)");
				SetStatus(scope $"Collapse Nodes: {GroupRefusal}", .Warning);
				return false;
			}
			KeyAssigner.Assign(g);
			float minX = float.MaxValue, minY = float.MaxValue, maxX = float.MinValue;
			for (let n in nodes)
			{
				mGraphPanel.GetNodeSize(n.Id, var w, ?);
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + w);
			}
			BeginEdit();
			String key = scope .();
			mg.Doc.NewId(key);
			let gr = g.AddGroup(key, "Collapsed Nodes", nodes, minX, minY);
			CommitCurrent();
			mGraphPanel.SetGroupCollapsed(tab, g, gr, true);
			SetStatus(scope $"Folded {nodes.Count} node{(nodes.Count == 1) ? "" : "s"} into a group: double-click it to open it", .Info, false);
			return true;
		}

		/// Ungroup: the group goes, its nodes stay where they are (shown). One undo step.
		public bool Ungroup(GraphTab tab, NodeGroup gr)
		{
			let mg = (tab != null) ? tab.Doc.FindSheet(tab.MethodKey) : null;
			if (mg == null || gr == null || !CheckWritable())
				return false;
			let g = mg.Graph;
			mGraphPanel.SetGroupCollapsed(tab, g, gr, false);
			BeginEdit();
			g.RemoveGroup(gr);
			CommitCurrent();
			return true;
		}
	}
}
