// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The `editor` self test's collapsed node groups (NodeGroups.bf, GroupView.bf) on the Demo Sheet of the
	/// Extract to Function checks: Collapse Nodes with undo, the folded group's node and pins, opening it
	/// (the nodes exactly where they were), Ungroup with undo, the file and the layout keep it.
	extension EditorApp
	{
		/// The folded group's record id and its members' positions before folding ("key x y ...").
		String mGroupKey = new .() ~ delete _;
		List<(int32 id, float x, float y)> mGroupPlaces = new .() ~ delete _;

		void UX2Groups(int phase)
		{
			let doc = Doc;
			let demo = doc.FindSheetByName("Demo");
			if (demo == null)
			{
				SelfTestCheck(false, "editor: the Demo Sheet for the node groups");
				return;
			}
			if (CurrentMethod != demo)
				OpenTab(demo);
			let tab = CurrentTab;
			let g = demo.Graph;
			switch (phase)
			{
			case 0:
				// Set Armor, its + and the two Gets: one flow in (from Set mHealth), one flow out (to the Branch).
				tab.ClearSelection();
				mGroupPlaces.Clear();
				for (int i in int[?](1, 2, 3, 8))
				{
					let n = UX2Key(i);
					if (n == null)
						continue;
					tab.AddToSelection(n.Id);
					mGroupPlaces.Add((n.Id, n.X, n.Y));
				}
				int links = g.Links.Count;
				bool ok = CollapseSelectionToGroup(tab);
				let gr = g.Groups.IsEmpty ? null : g.Groups.Back;
				mGroupKey.Set((gr != null) ? (StringView)gr.Key : "");
				SelfTestCheck(ok && gr != null && gr.Nodes.Count == 4 && mGraphPanel.IsGroupCollapsed(tab, gr) && tab.SelectedNodes.Count == 1 && tab.SelectedNodes[0] == gr.Id && g.Links.Count == links,
					scope $"editor: Collapse Nodes folds four nodes into a group, the wires untouched {GroupRefusal}");
				doc.Undo();
				let g2 = demo.Graph;
				SelfTestCheck(g2.FindGroupByKey(mGroupKey) == null && g2.Groups.IsEmpty, "editor: one undo removes the group");
				doc.Redo();
				// Refused: a node in a group already.
				let again = demo.Graph;
				let s2 = UX2Key(1);
				if (s2 != null)
					tab.SelectOnly(s2.Id);
				SelfTestCheck(!CollapseSelectionToGroup(tab) && GroupRefusal.Contains("already") && again.Groups.Count == 1, scope $"editor: a node in a group already is refused ({GroupRefusal})");
				let gr3 = again.FindGroupByKey(mGroupKey);
				tab.ClearSelection();
				if (gr3 != null)
					tab.SelectedNodes.Add(gr3.Id);
			case 1:
				let gr = g.FindGroupByKey(mGroupKey);
				int ins = 0, outs = 0;
				bool drawn = gr != null && mGraphPanel.GroupPinCounts(gr.Id, out ins, out outs);
				bool hidden = true;
				for (let p in mGroupPlaces)
					hidden &= mGraphPanel.IsHiddenNode(p.id);
				SelfTestCheck(drawn && mGraphPanel.FoldedGroupsDrawn == 1 && ins == 1 && outs == 1 && hidden,
					scope $"editor: the folded group is one node with a pin for each wire crossing its edge ({ins} in, {outs} out), its nodes hidden");
				// Moved while folded: its nodes move with it.
				if (gr != null)
				{
					tab.SelectOnly(gr.Id);
					mGraphPanel.SetGroupCollapsed(tab, g, gr, false);
				}
			case 2:
				let gr = g.FindGroupByKey(mGroupKey);
				bool same = true;
				for (let p in mGroupPlaces)
				{
					let n = g.FindNode(p.id);
					same &= n != null && n.X == p.x && n.Y == p.y && !mGraphPanel.IsHiddenNode(p.id);
				}
				SelfTestCheck(gr != null && same && mGraphPanel.FoldedGroupsDrawn == 0 && mGraphPanel.OpenGroupFrames == 1,
					"editor: a double-click opens the group: its nodes exactly where they were, framed");
				// The file and the layout keep the group, folded.
				if (gr != null)
					mGraphPanel.SetGroupCollapsed(tab, g, gr, true);
				String text = scope .();
				String why = scope .();
				doc.WriteText(text, why);
				String layout = scope .();
				Language.Codec.WriteLayout(doc, layout, why);
				bool inFile = gr != null && text.Contains(scope $"group {gr.Key} \"Collapsed Nodes\"\n") && layout.Contains(scope $"\tcollapsed {gr.Key}\n") &&
					layout.Contains(scope $"\tnode {gr.Key} ");
				SelfTestCheck(inFile, "codec: the group record and its folded place are in the type file and the layout");
				// Ungroup: one undo step.
				bool ungrouped = gr != null && Ungroup(tab, gr);
				SelfTestCheck(ungrouped && demo.Graph.Groups.IsEmpty, "editor: Ungroup removes the group, its nodes stay");
				doc.Undo();
				let back = demo.Graph.FindGroupByKey(mGroupKey);
				SelfTestCheck(back != null && back.Nodes.Count == 4, "editor: undo brings the group back");
				// Validate is unchanged by a group (the compiler does not read it).
				Validate(true);
				String errs = scope .();
				if (mValidate != null)
					for (let d in mValidate.Messages)
						if (d.IsError && d.MethodKey == demo.Key)
							errs.AppendF(" [{}]", d.Text);
				SelfTestCheck(mValidate != null && errs.IsEmpty, scope $"editor: a Sheet with a group validates clean{errs}");
				let take = doc.FindSheetByName("TakeDamage");
				if (take != null)
					OpenTab(take);
			}
		}
	}
}
#endif
