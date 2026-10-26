using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;
using ImGui;

namespace Treadle.Editor
{
	/// Node-graph habits a user of other node editors brings along (docs/UX-Audit.md): the Add pin
	/// button of a Sequence / Multi Gate / Switch and the pin menu's Remove Pin. Each edit is one undo step.
	extension EditorApp
	{
		/// Whether a Call calls a C variadic function: only then does it show "+ arg" (extra inputs `va0`,
		/// `va1`, ... after its own, as the front end reads them).
		public bool IsVariadicCall(Node node) => mNodeMenu.IsVariadicCall(node);

		/// Whether the node draws an "Add pin" button: a Sequence or Multi Gate always, a Switch while
		/// there is a case left to add (an enum Switch stops when every member has its case).
		public bool CanAddExecPin(Node node)
		{
			if (node == null)
				return false;
			if (node.Kind == .Sequence || node.Kind == .MultiGate)
				return FlowMacros.ArmCount(node) < 64;
			if (node.Kind == .Switch)
				return NextSwitchCase(node, scope String());
			return false;
		}

		/// The label of the case Add Case / Add pin gives a Switch: the first enum member without a
		/// case, else the first number without one (an integer, char or String Switch). False when an
		/// enum Switch has every member already.
		public bool NextSwitchCase(Node node, String outLabel)
		{
			outLabel.Clear();
			List<String> members = scope .();
			defer { ClearAndDeleteItems!(members); }
			Language.Types.EnumMembers(NodeFactory.SwitchType(node), members);
			if (!members.IsEmpty)
			{
				for (let mbr in members)
					if (node.FindOutput(scope $"case:{mbr}") == null)
					{
						outLabel.Set(mbr);
						return true;
					}
				return false;
			}
			for (int i = 0; outLabel.IsEmpty; i++)
				if (node.FindOutput(scope $"case:{i}") == null)
					outLabel.AppendF("{}", i);
			return true;
		}

		/// Add pin: one more output (a Sequence's Then, a Multi Gate's Out, a Switch's case).
		public bool AddExecPin(Node node)
		{
			let mg = CurrentMethod;
			if (mg == null || node == null || mg.Graph.FindNode(node.Id) != node || !CheckWritable() || !CanAddExecPin(node))
				return false;
			BeginEdit();
			if (node.Kind == .Switch)
			{
				String label = scope .();
				NextSwitchCase(node, label);
				NodeFactory.AddCase(mg.Graph, node, label);
			}
			else
				FlowMacros.AddArm(mg.Graph, node);
			CommitCurrent();
			return true;
		}

		/// Whether the pin menu offers Remove Pin for `pin`: an arm of a Sequence / Multi Gate that has
		/// more than one, or a case of a Switch.
		public static bool IsRemovableExecPin(Pin pin)
		{
			if (pin == null || pin.IsInput || pin.Kind != .Flow)
				return false;
			let n = pin.Owner;
			if (n.Kind == .Sequence || n.Kind == .MultiGate)
				return pin.Name != "done" && FlowMacros.ArmCount(n) > 1;
			if (n.Kind == .Switch)
				return pin.Name.StartsWith("case:");
			return false;
		}

		/// The struct pin's split: the Node menu row that takes the pin apart (an output: Break <Type>)
		/// or builds its value (an input: Make <Type>), as its key ("Category\tLabel") and label.
		/// False when the pin is not a struct or the menu has no such row for it.
		public bool StructRowForPin(Sheet mg, Pin pin, String outKey, String outLabel)
		{
			outKey.Clear();
			outLabel.Clear();
			if (mg == null || pin == null || pin.Kind != .Value || pin.TypeName.IsEmpty)
				return false;
			// Structs only (a generic struct the type system does not resolve, Pair, reads as an object:
			// the Make / Break rows decide then).
			switch (Language.Types.Family(pin.TypeName))
			{
			case .Struct, .Vector, .Object, .Unknown:
			default: return false;
			}
			// The type's short name: `Core.Pair<int, float>` -> `Pair`.
			StringView shortName = pin.TypeName;
			let lt = shortName.IndexOf('<');
			if (lt > 0)
				shortName = shortName.Substring(0, lt);
			let dot = shortName.LastIndexOf('.');
			if (dot >= 0)
				shortName = shortName.Substring(dot + 1);
			if (shortName.IsEmpty)
				return false;
			let want = scope String()..AppendF("{} {}", pin.IsInput ? "Make" : "Break", shortName);
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.ListFor(mg, 0, want, rows);
			for (let r in rows)
			{
				bool kindOk = (r.Kind == (pin.IsInput ? MenuEntryKind.Make : MenuEntryKind.BreakStruct)) || r.Kind == .Catalog;
				bool labelOk = r.Label == want || r.Label.StartsWith(scope $"{want}<") || r.Label.StartsWith(scope $"{want} (");
				if (kindOk && labelOk)
				{
					outKey.AppendF("{}\t{}", r.Category, r.Label);
					outLabel.Set(r.Label);
					return true;
				}
			}
			return false;
		}

		/// Places the Node menu row `key` beside `pin`, wired to it (left of an input, right of an
		/// output), as choosing it in the menu dragged from that pin would. One undo step.
		public Node PlaceRowFromPin(GraphTab tab, Sheet mg, Pin pin, StringView key)
		{
			if (tab == null || mg == null || pin == null || !CheckWritable())
				return null;
			let owner = pin.Owner;
			mGraphPanel.GetNodeSize(owner.Id, let ow, ?);
			ImVec2 at = pin.IsInput ? ImVec2(owner.X - 300, owner.Y) : ImVec2(owner.X + Math.Max(ow, 120) + 80, owner.Y);
			let item = mNodeMenu.ItemForKey(mg, at, pin.Id, key);
			if (item == null)
				return null;
			defer delete item;
			mActionTab = tab;
			return ExecuteAction(item);
		}

		/// The Sheets from the function down to `mg` (a Lambda's Sheet comes after the Sheet holding its
		/// node, nested Lambdas likewise): what the breadcrumbs show.
		public void SheetChain(Sheet mg, List<Sheet> outChain)
		{
			outChain.Clear();
			var s = mg;
			for (int depth = 0; s != null && depth < 16; depth++)
			{
				outChain.Insert(0, s);
				s = (s.Role == .Lambda) ? LambdaOwner(s.Doc, s) : null;
			}
		}

		/// The key owner id Ctrl+Tab claims the Tab key with (any id that is not ImGui's own).
		const uint32 cSheetTabsKeyOwner = 0x4B535442;

		/// Ctrl+Page Down / Ctrl+Page Up: the next / previous Sheet tab in the tab bar's order (wrapping).
		public bool CycleSheetTab(int dir)
		{
			List<TabSlot> slots = scope .();
			CollectTabSlots(slots);
			if (slots.Count < 2 || CurrentTab == null)
				return false;
			int at = 0;
			for (let s in slots)
				if (s.Graph == CurrentTab)
					at = @s.Index;
			let next = slots[(at + dir + slots.Count) % slots.Count].Graph;
			let mg = next.Doc.FindSheet(next.MethodKey);
			if (mg == null)
				return false;
			OpenTab(mg);
			return true;
		}

		/// F2 on the Sheet: a selected comment box gets its title edited in place; a Get / Set / Call of
		/// this type's own variable or function, a local's Get / Set, the Entry node or nothing selected
		/// open that member's (or local's, or this function's) page with its Name field focused.
		public bool RenameSelection(GraphTab tab)
		{
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return false;
			if (tab.SelectedNodes.IsEmpty && tab.SelectedComments.Count == 1)
			{
				mGraphPanel.BeginCommentRename(tab, tab.SelectedComments[0]);
				return true;
			}
			let g = mg.Graph;
			let n = (tab.SelectedNodes.Count == 1) ? g.FindNode(tab.SelectedNodes[0]) : null;
			MemberDecl m = null;
			if (tab.SelectedNodes.IsEmpty || n == g.Entry)
				m = (mg.Role == .Lambda) ? null : mg.Member;
			else if (n != null && (n.Kind == .Get || n.Kind == .Set))
			{
				StringView subject = n.Text;
				if (subject.StartsWith("local:"))
				{
					let name = subject.Substring(6);
					if (g.FindLocal(name) == null)
						return false;
					mSelLocalActive = true;
					mSelLocalName.Set(name);
					SelectOutline(.Local);
					FocusNameField();
					return true;
				}
				let dot = subject.LastIndexOf('.');
				let owner = (dot > 0) ? subject.Substring(0, dot) : "";
				if (owner == "this" || owner == mg.Doc.Header.GetFullName(.. scope String()))
					m = mg.Doc.FindMember(subject.Substring(dot + 1));
			}
			else if (n != null && n.Kind == .Call)
			{
				let mref = Treadle.Model.MemberRef.Parse(n.Text);
				defer delete mref;
				bool own = mref.Owner != .Type || (mref.Type != null && mref.Type.Name == mg.Doc.Header.GetFullName(.. scope String()));
				if (own)
					m = mg.Doc.FindMember(mref.Name);
			}
			if (m == null || m.Kind == .Ctor || m.Kind == .Dtor)
			{
				SetStatus("F2 renames a comment box, a variable or function of this type, a local, or this function (nothing selected)", .Info, false);
				return false;
			}
			if (Doc != mg.Doc)
				Doc = mg.Doc;
			SelectOutline(.Member, m);
			FocusNameField();
			return true;
		}

		/// The next Name row Properties draws takes the keyboard (F2).
		bool mFocusNameRow;
		/// How many times a Name row took the keyboard (the self test reads it).
		public int NameRowsFocused;

		void FocusNameField()
		{
			mFocusNameRow = true;
			Panels.Focus(Panels.PropertiesId);
		}

		/// Disable / Enable Node (node menu): the selected nodes are kept in the file and skipped when
		/// compiling, or compiled again. Any enabled one selected: all get disabled. One undo step.
		public bool ToggleDisabled(GraphTab tab)
		{
			let mg = CurrentMethod;
			if (tab == null || mg == null || !CheckWritable())
				return false;
			ExpandGroupsInSelection(tab, mg.Graph);
			List<Node> nodes = scope .();
			bool anyOn = false;
			for (let id in tab.SelectedNodes)
			{
				let n = mg.Graph.FindNode(id);
				if (n == null || n == mg.Graph.Entry)
					continue;
				nodes.Add(n);
				anyOn |= !n.Disabled;
			}
			if (nodes.IsEmpty)
				return false;
			BeginEdit();
			for (let n in nodes)
				n.Disabled = anyOn;
			mg.Graph.Version++;
			CommitCurrent();
			SetStatus(anyOn ? scope $"Disabled {nodes.Count} node(s): kept in the file, skipped when compiling" : scope $"Enabled {nodes.Count} node(s)", .Info, false);
			return true;
		}

		/// Remove Pin: that arm (the arms after it move up with their wires) or that case.
		public bool RemoveExecPin(Pin pin)
		{
			let mg = CurrentMethod;
			if (mg == null || !IsRemovableExecPin(pin) || mg.Graph.FindPin(pin.Id) != pin || !CheckWritable())
				return false;
			let node = pin.Owner;
			BeginEdit();
			if (node.Kind == .Switch)
				NodeFactory.RemoveCase(mg.Graph, node, pin);
			else
				FlowMacros.RemoveArmAt(mg.Graph, node, pin);
			CommitCurrent();
			return true;
		}
	}
}
