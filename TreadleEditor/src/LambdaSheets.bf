using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using ImGui;

namespace Treadle.Editor
{
	/// What a delegate or function pointer type takes and gives (Language.md 4.2): the type texts
	/// of its inputs and of its result, and whether it is a function pointer (a C callback: no
	/// object, no captures).
	class LambdaSignature
	{
		public String Returns = new .() ~ delete _;
		public List<String> Params = new .() ~ DeleteContainerAndItems!(_);
		public bool IsFunction;

		public void Clear()
		{
			Returns.Clear();
			ClearAndDeleteItems!(Params);
			IsFunction = false;
		}

		/// `int(int, int)`; with `names`, `int(int a, int b)`.
		public void ToText(String outText, Span<StringView> names = default)
		{
			outText.AppendF("{}(", Returns.IsEmpty ? "void" : (StringView)Returns);
			for (int i < Params.Count)
			{
				if (i > 0)
					outText.Append(", ");
				outText.Append(Params[i]);
				if (i < names.Length && !names[i].IsEmpty)
					outText.AppendF(" {}", names[i]);
			}
			outText.Append(')');
		}

		/// The type as the format spells it: `delegate:int(int,int)` or `function:...`.
		public void ToTypeText(String outText)
		{
			outText.Append(IsFunction ? "function:" : "delegate:");
			outText.Append(Returns.IsEmpty ? "void" : (StringView)Returns);
			outText.Append('(');
			for (int i < Params.Count)
			{
				if (i > 0)
					outText.Append(',');
				outText.Append(Params[i]);
			}
			outText.Append(')');
		}
	}

	/// Lambda Sheets in the editor (Language.md 4.2, Graph-Format.md 3.1 `sheet lambda:<node>`): a
	/// Lambda node's nested Sheet is made when the node is placed (or pasted) and removed with the
	/// node, inside the edit's undo step; double-clicking the node opens it; it sits under its owner
	/// in the Outline and right after its owner's tab.
	extension EditorApp
	{
		/// The Sheet that holds the Lambda node of `lambda` (null when the node is gone).
		public static Sheet LambdaOwner(TypeDocument doc, Sheet lambda)
		{
			for (let s in doc.Sheets)
			{
				if (s == lambda || s.Member != lambda.Member)
					continue;
				let n = s.Graph.FindNodeByKey(lambda.LambdaNode);
				if (n != null && n.Kind == .Lambda)
					return s;
			}
			return null;
		}

		/// The Lambda Sheet of the node `nodeKey` in `owner` (null when it has none yet).
		public static Sheet FindLambdaSheet(TypeDocument doc, Sheet owner, StringView nodeKey)
		{
			for (let s in doc.Sheets)
				if (s.Role == .Lambda && s.Member == owner.Member && s.LambdaNode == nodeKey)
					return s;
			return null;
		}

		/// After an edit (DoCommit): a Lambda node without a Sheet gets one, a Lambda Sheet whose node
		/// is gone goes (its tab closes). The edit's undo snapshot was taken before, so undo brings
		/// the Sheets back as they were.
		void SyncLambdaSheets(TypeDocument doc)
		{
			if (doc == null)
				return;
			bool any = false;
			for (let s in doc.Sheets)
			{
				if (s.Role == .Lambda)
					any = true;
				else if (s.IsBuilt)
					for (let n in s.Graph.Nodes)
						any |= n.Kind == .Lambda;
			}
			if (!any)
				return;
			List<(Sheet owner, String key)> missing = scope .();
			defer { for (let m in missing) delete m.key; }
			for (let s in doc.Sheets)
			{
				if (!s.IsBuilt || s.Member == null)
					continue;
				for (let n in s.Graph.Nodes)
					if (n.Kind == .Lambda && !n.Key.IsEmpty && FindLambdaSheet(doc, s, n.Key) == null)
						missing.Add((s, new String(n.Key)));
			}
			for (let m in missing)
			{
				doc.NewSheet(m.owner.Member, .Lambda, m.key);
				doc.Modified = true;
				doc.Version++;
			}
			// A removed Lambda Sheet may hold Lambda nodes of its own: go until none is left.
			while (true)
			{
				Sheet orphan = null;
				for (let s in doc.Sheets)
					if (s.Role == .Lambda && LambdaOwner(doc, s) == null)
						orphan = s;
				if (orphan == null)
					break;
				DeleteSheet(orphan);
			}
		}

		/// Double-click on a Lambda node: its Sheet in a tab (made first when the node has none).
		void OpenLambdaSheet(Node node)
		{
			let tab = CurrentTab;
			let owner = (tab != null) ? tab.Doc.FindSheet(tab.MethodKey) : null;
			if (owner == null || owner.Member == null)
				return;
			let doc = owner.Doc;
			if (node.Key.IsEmpty)
				KeyAssigner.Assign(owner.Graph);
			var ls = FindLambdaSheet(doc, owner, node.Key);
			if (ls == null)
			{
				if (!CheckWritable())
					return;
				doc.PushUndo();
				ls = doc.NewSheet(owner.Member, .Lambda, node.Key);
				doc.Modified = true;
				doc.Version++;
			}
			OpenTab(ls);
		}

		/// Where a new tab for `mg` goes: after its owner's tab (and the owner's other Lambda tabs)
		/// for a Lambda Sheet whose owner is open, else at the end.
		int LambdaTabIndex(Sheet mg)
		{
			if (mg.Role != .Lambda)
				return Tabs.Count;
			let owner = LambdaOwner(mg.Doc, mg);
			if (owner == null)
				return Tabs.Count;
			for (int i < Tabs.Count)
			{
				if (Tabs[i].Doc != mg.Doc || Tabs[i].MethodKey != owner.Key)
					continue;
				int at = i + 1;
				while (at < Tabs.Count && Tabs[at].Doc == mg.Doc && Tabs[at].MethodKey.StartsWith("lambda:"))
					at++;
				return at;
			}
			return Tabs.Count;
		}

		/// The Outline's rows of the Lambda Sheets `owner` holds, indented under its row (and theirs
		/// under them). A row opens the Sheet.
		void DrawLambdaRows(Sheet owner, StringView currentKey, int depth)
		{
			if (depth > 8 || !owner.IsBuilt)
				return;
			for (let n in owner.Graph.Nodes)
			{
				if (n.Kind != .Lambda || n.Key.IsEmpty)
					continue;
				let ls = FindLambdaSheet(Doc, owner, n.Key);
				if (ls == null)
					continue;
				Gui.PushID(scope $"lambda:{ls.LambdaNode}");
				String pad = scope .();
				for (int i < depth + 2)
					pad.Append("    ");
				bool selected = ls.Key == currentKey;
				if (Gui.Selectable(scope $"{pad}{Icon.SquareFunction}  Lambda {ls.LambdaNode}", selected, SelectableFlags.AllowDoubleClick))
				{
					mSelLocalActive = false;
					OpenTab(ls);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"The body of the Lambda node {ls.LambdaNode} in {owner.Name}");
				Gui.PopID();
				DrawLambdaRows(ls, currentKey, depth + 1);
			}
		}
	}
}
