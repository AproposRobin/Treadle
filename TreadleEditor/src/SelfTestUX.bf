// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;
using ImGui;

namespace Treadle.Editor
{
	/// The `editor` self test's node-graph habits (docs/UX-Audit.md, NodeHabits.bf), one phase per frame
	/// with a commit between them: Make variable from a pin, a pin's hover text and its wires, Add pin /
	/// Remove Pin, Break into Fields / Make from Fields, Disable Node, F2, Ctrl+Tab and the breadcrumbs.
	extension EditorApp
	{
		int32 mUXSetNode;
		int mUXFields;
		int32 mUXHoverPin;
		int32 mUXHoverLink;

		void SelfTestUX(int phase)
		{
			if (CurrentMethod == null || CurrentTab == null)
			{
				SelfTestCheck(false, "editor: a Sheet for the node habit checks");
				return;
			}
			switch (phase)
			{
			case 0:
				UXMakeVariable(0);
			case 1:
				UXMakeVariable(1);
			case 2:
				UXHover(0);
			case 3:
				UXHover(1);
			case 4:
				UXHover(2);
			case 5:
				UXExecPins();
				UXStructPins();
				UXDisable();
				UXDrawnText(0);
			case 6:
				UXDrawnText(1);
				UXRename(0);
			case 7:
				UXRename(1);
				UXSheetTabs();
			case 8:
				UXCrumbs(0);
			case 9:
				UXCrumbs(1);
			case 10:
				UXNewName(0);
			case 11:
				UXNewName(1);
			default:
			}
		}

		/// Make variable from an int output: a new field and a Set fed by the pin; one undo takes both.
		void UXMakeVariable(int phase)
		{
			let mg = CurrentMethod;
			let g = mg.Graph;
			if (phase == 0)
			{
				let lit = FindNode(g, .Literal);
				let outPin = lit?.Result ?? ((lit != null && !lit.Outputs.IsEmpty) ? lit.Outputs[0] : null);
				mUXFields = 0;
				for (let m in mg.Doc.Members)
					if (m.Kind == .Field)
						mUXFields++;
				int nodes = g.Nodes.Count;
				if (outPin != null)
					mGraphPanel.MakeVariableFromPin(CurrentTab, mg, outPin, true);
				let set = (g.Nodes.Count == nodes + 1) ? g.Nodes.Back : null;
				mUXSetNode = (set != null) ? set.Id : 0;
				SelfTestCheck(outPin != null && set != null && set.Kind == .Set && g.IsLinked(set.FindInput("value")),
					scope $"editor: Make variable on a Literal's output places a Set fed by the pin ({(set != null) ? set.Text : "nothing"})");
				return;
			}
			int fields = 0;
			MemberDecl made = null;
			for (let m in mg.Doc.Members)
				if (m.Kind == .Field)
				{
					fields++;
					made = m;
				}
			let set = g.FindNode(mUXSetNode);
			SelfTestCheck(fields == mUXFields + 1 && made != null && made.Type?.ToString(.. scope String()) == "int" && set != null && set.Text == scope $"this.{made.Name}",
				scope $"editor: Make variable adds the int field {(made != null) ? made.Name : "?"} to the type and the Set writes it");
			String setText = scope .((set != null) ? set.Text : "");
			mg.Doc.Undo();
			int after = 0;
			for (let m in CurrentMethod.Doc.Members)
				if (m.Kind == .Field)
					after++;
			bool setGone = true;
			for (let n in CurrentMethod.Graph.Nodes)
				if (n.Kind == .Set && !setText.IsEmpty && n.Text == setText)
					setGone = false;
			SelfTestCheck(after == mUXFields && setGone, "editor: one undo removes the field and its Set");
			CurrentMethod.Doc.Redo();
		}

		/// Phase 0: a wired value input is framed; phase 1: the pointer is held on it; phase 2: that pin is
		/// hovered and its wire is drawn hot, and an unwired input's hover text has its type and value.
		void UXHover(int phase)
		{
			let g = CurrentMethod.Graph;
			if (phase == 0)
			{
				mUXHoverPin = 0;
				mUXHoverLink = 0;
				for (let l in g.Links)
					if (l.From.Kind == .Value && l.To.Owner != g.Entry)
					{
						mUXHoverPin = l.To.Id;
						mUXHoverLink = l.Id;
						CurrentTab.SelectOnly(l.To.Owner.Id);
						mGraphPanel.FrameNodes(CurrentTab, g, true);
						CurrentTab.ClearSelection();
						break;
					}
				SelfTestCheck(mUXHoverPin != 0, "editor: a wired value input to hover");
				return;
			}
			if (phase == 1)
			{
				if (mGraphPanel.PinScreenPos(CurrentTab, mUXHoverPin, let at))
				{
					mGraphPanel.SelfTestMouse = at;
					GraphProf.ForceHover = true;
				}
				return;
			}
			let link = g.FindLink(mUXHoverLink);
			SelfTestCheck(mGraphPanel.HoverPinId == mUXHoverPin && link != null && mGraphPanel.HoverPinWire(link), scope $"editor: hovering a pin highlights its wire (hover {mGraphPanel.HoverPinId}, pin {mUXHoverPin})");
			mGraphPanel.SelfTestMouse = .(-3e38f, -3e38f);
			GraphProf.ForceHover = false;
			Pin cond = null;
			for (let n in g.Nodes)
				for (let p in n.Inputs)
					if (cond == null && p.Kind == .Value && p.TypeName == "bool" && !g.IsLinked(p))
						cond = p;
			String tip = scope .();
			if (cond != null)
				mGraphPanel.PinTooltip(g, cond, tip);
			String tipLine = scope .(tip);
			tipLine.Replace('\n', '|');
			SelfTestCheck(tip.Contains("bool") && tip.Contains("Value: "), scope $"editor: a pin's hover text has its type and value ({tipLine})");
		}

		/// Add pin / Remove Pin: a Sequence gets a third Then, removing the first moves the second's wire
		/// up (undo brings it back); a Switch gets a case and loses it again.
		void UXExecPins()
		{
			let mg = CurrentMethod;
			let g = mg.Graph;
			let seq = FindNode(g, .Sequence);
			let branch = FindNode(g, .Branch);
			int arms = (seq != null) ? FlowMacros.ArmCount(seq) : 0;
			bool added = seq != null && AddExecPin(seq);
			SelfTestCheck(added && FlowMacros.ArmCount(seq) == arms + 1, scope $"editor: Add pin gives a Sequence another output ({arms} -> {(seq != null) ? FlowMacros.ArmCount(seq) : 0})");
			if (seq != null && branch != null && branch.ExecIn != null)
			{
				List<Pin> armPins = scope .();
				for (let p in seq.Outputs)
					if (p.Kind == .Flow && p.Name != "done")
						armPins.Add(p);
				BeginEdit();
				for (int li = g.Links.Count - 1; li >= 0; li--)
					if (g.Links[li].To == branch.ExecIn)
						g.Disconnect(g.Links[li]);
				g.Connect(armPins[1], branch.ExecIn);
				CommitCurrent();
				bool removed = RemoveExecPin(armPins[0]);
				Pin first = null;
				for (let p in seq.Outputs)
					if (p.Kind == .Flow && p.Name != "done")
					{
						first = p;
						break;
					}
				SelfTestCheck(removed && FlowMacros.ArmCount(seq) == arms && first != null && g.ExecTarget(first) == branch,
					"editor: Remove Pin on the first Then moves the second Then's wire up");
				mg.Doc.Undo();
				let seq2 = FindNode(CurrentMethod.Graph, .Sequence);
				SelfTestCheck(seq2 != null && FlowMacros.ArmCount(seq2) == arms + 1, "editor: undo brings the removed pin back");
			}
			let sw = FindNode(CurrentMethod.Graph, .Switch);
			int cases = 0;
			if (sw != null)
				for (let p in sw.Outputs)
					if (p.Name.StartsWith("case:"))
						cases++;
			bool swAdded = sw != null && AddExecPin(sw);
			Pin lastCase = null;
			int casesAfter = 0;
			if (sw != null)
				for (let p in sw.Outputs)
					if (p.Name.StartsWith("case:"))
					{
						casesAfter++;
						lastCase = p;
					}
			SelfTestCheck(swAdded && casesAfter == cases + 1 && IsRemovableExecPin(lastCase), scope $"editor: Add pin gives a Switch a case ({cases} -> {casesAfter})");
			bool swRemoved = lastCase != null && RemoveExecPin(lastCase);
			int casesBack = 0;
			if (sw != null)
				for (let p in sw.Outputs)
					if (p.Name.StartsWith("case:"))
						casesBack++;
			SelfTestCheck(swRemoved && casesBack == cases, "editor: Remove Case takes the case out");
			UXMathField();
			mSelfTestWait = 2;
		}

		int32 mUXMathNode;
		int32 mUXPlusNode;
		int mUXDrawnBefore;

		/// What nodes read from a file draw (phase 0 adds them, phase 1 reads the frame between): a
		/// Math Expression whose text is only in `set expr` (no title text, as the codec reads it) is as
		/// wide as its expression, not as the field's hint; a + Operator draws its symbol as strokes of a
		/// size that fills the node (the font's + was a small mark). Undo takes both away.
		void UXDrawnText(int phase)
		{
			let mg = CurrentMethod;
			let g = mg.Graph;
			let expr = "Sqrt(v.X * v.X + v.Y * v.Y) + count * 2";
			if (phase == 0)
			{
				mUXDrawnBefore = g.Nodes.Count;
				float x = 0, y = 0;
				if (!g.Nodes.IsEmpty)
				{
					x = g.Nodes[0].X;
					y = g.Nodes[0].Y + 200;
				}
				BeginEdit();
				let m = g.AddNode(.Math);
				m.SetSetting("expr", scope $"\"{expr}\"");
				mGraphPanel.SyncMathPins(g, m, expr);
				m.X = x;
				m.Y = y;
				let plus = NodeFactory.Operator(g, "+");
				plus.X = x;
				plus.Y = y + 120;
				mUXMathNode = m.Id;
				mUXPlusNode = plus.Id;
				return;
			}
			let m = g.FindNode(mUXMathNode);
			let w = mGraphPanel.LaidOutWidth(mUXMathNode);
			let need = mGraphPanel.MathTextWidth(expr);
			let hint = mGraphPanel.MathTextWidth("a * b + 1");
			SelfTestCheck(m != null && m.Text.IsEmpty && w >= need + 16 && w > hint + 32,
				scope $"editor: a Math Expression with its text only in set expr is laid out {w:0} wide for its expression ({need:0}), not the hint ({hint:0})");
			let arm = mGraphPanel.SymbolArm(mUXPlusNode);
			let pw = mGraphPanel.LaidOutWidth(mUXPlusNode);
			SelfTestCheck(arm >= 6 && pw > 0 && arm * 2 < pw, scope $"editor: the + Operator draws its symbol as strokes {arm * 2:0.0} long on a node {pw:0} wide");
			mg.Doc.Undo();
			SelfTestCheck(CurrentMethod.Graph.Nodes.Count == mUXDrawnBefore, scope $"editor: undo takes the Math Expression and the + away ({CurrentMethod.Graph.Nodes.Count} nodes, {mUXDrawnBefore} before)");
		}

		/// The Math Expression field: typing adds and drops inputs by name (a wired name keeps its

		/// wire), Enter stores the text in `set expr`, a text that does not parse is refused and
		/// the inputs go back; undo takes it all away.
		void UXMathField()
		{
			let mg = CurrentMethod;
			let g = mg.Graph;
			int before = g.Nodes.Count;
			BeginEdit();
			let m = NodeFactory.MathExpression(g, "a * b");
			mGraphPanel.SyncMathPins(g, m, "a * b");
			let lit = NodeFactory.Literal(g, "int", "3");
			Pin litOut = null;
			for (let p in lit.Outputs)
				if (p.Kind == .Value)
					litOut = p;
			if (litOut != null && m.FindInput("a") != null)
				g.Connect(litOut, m.FindInput("a"));
			String names = scope .();
			void Names()
			{
				names.Clear();
				for (let p in m.Inputs)
					if (p.Kind == .Value)
						names.AppendF("{}{}", names.IsEmpty ? "" : ",", p.Name);
			}
			Names();
			SelfTestCheck(names == "a,b", scope $"editor: a Math Expression's inputs follow its text: a * b gives {names}");
			mGraphPanel.ApplyMathText(g, m, "a + c * 2", false);
			Names();
			let aIn = m.FindInput("a");
			SelfTestCheck(names == "a,c" && aIn != null && g.IsLinked(aIn), scope $"editor: typing a + c * 2 gives inputs {names}, a keeps its wire");
			mGraphPanel.ApplyMathText(g, m, "a + c * 2", true);
			SelfTestCheck(m.GetSetting("expr") == "\"a + c * 2\"" && m.Text != "a + c * 2", scope $"editor: Enter stores the expression in set expr ({m.GetSetting("expr")})");
			mGraphPanel.ApplyMathText(g, m, "a + (", false);
			let refused = !mGraphPanel.ApplyMathText(g, m, "a + (", true);
			Names();
			SelfTestCheck(refused && names == "a,c" && m.GetSetting("expr") == "\"a + c * 2\"", scope $"editor: a + ( is refused, the inputs stay {names}");
			mg.Doc.Undo();
			mg.Doc.Undo();
			SelfTestCheck(CurrentMethod.Graph.Nodes.Count == before, scope $"editor: undo takes the Math Expression away ({CurrentMethod.Graph.Nodes.Count} nodes, {before} before)");
		}

		/// Break into Fields on Make Pair's output places a Break Pair wired to it; a Pair input offers
		/// Make from Fields.
		void UXStructPins()
		{
			let mg = CurrentMethod;
			let make = FindNode(mg.Graph, .Make);
			Pin structOut = null;
			if (make != null)
				for (let p in make.Outputs)
					if (p.Kind == .Value)
						structOut = p;
			String key = scope .();
			String label = scope .();
			bool hasBreak = StructRowForPin(mg, structOut, key, label);
			let placed = hasBreak ? PlaceRowFromPin(CurrentTab, mg, structOut, key) : null;
			SelfTestCheck(hasBreak && label.StartsWith("Break Pair") && placed != null && placed.Kind == .BreakStruct && mg.Graph.IsLinked(structOut),
				scope $"editor: Break into Fields on a Pair output places {label} wired to it");
			Pin structIn = null;
			if (placed != null)
				for (let p in placed.Inputs)
					if (p.Kind == .Value)
						structIn = p;
			bool hasMake = StructRowForPin(mg, structIn, key, label);
			SelfTestCheck(hasMake && label.StartsWith("Make Pair"), scope $"editor: a Pair input offers Make from Fields ({label})");
			mSelfTestWait = 2;
		}

		/// Disable Node marks the node in one undo step (the Branch stays disabled for the captures).
		void UXDisable()
		{
			let br = FindNode(CurrentMethod.Graph, .Branch);
			if (br == null)
			{
				SelfTestCheck(false, "editor: a Branch to disable");
				return;
			}
			CurrentTab.SelectOnly(br.Id);
			bool off = ToggleDisabled(CurrentTab) && br.Disabled;
			CurrentMethod.Doc.Undo();
			let br2 = FindNode(CurrentMethod.Graph, .Branch);
			SelfTestCheck(off && br2 != null && !br2.Disabled, "editor: Disable Node marks the node; undo enables it");
			CurrentMethod.Doc.Redo();
			mSelfTestWait = 2;
		}

		/// Phase 0: F2 on a Get of a field opens its page, F2 on a comment box edits its title; phase 1:
		/// the page's Name row took the keyboard.
		void UXRename(int phase)
		{
			if (phase == 1)
			{
				SelfTestCheck(NameRowsFocused > 0, scope $"editor: F2 on a Get puts the variable's Name field in edit ({NameRowsFocused})");
				return;
			}
			let mg = CurrentMethod;
			let tab = CurrentTab;
			let g = mg.Graph;
			Node get = null;
			for (let n in g.Nodes)
				if (n.Kind == .Get && n.Text == "this.mHealth")
					get = n;
			if (get != null)
				tab.SelectOnly(get.Id);
			bool ok = get != null && RenameSelection(tab);
			let m = Doc.FindMember("mHealth");
			SelfTestCheck(ok && OutlineSel == .Member && m != null && mSelMemberSerial == m.Serial, "editor: F2 on Get mHealth opens mHealth's page");
			tab.ClearSelection();
			if (get != null)
				tab.SelectOnly(get.Id);
			mGraphPanel.CreateComment(tab, g);
			int32 cid = tab.SelectedComments.IsEmpty ? 0 : tab.SelectedComments[0];
			tab.EditingComment = 0;
			bool okC = cid != 0 && RenameSelection(tab) && tab.EditingComment == cid;
			SelfTestCheck(okC, "editor: F2 on a comment box edits its title");
			tab.EditingComment = 0;
			tab.ClearSelection();
			// The member page in front for the Name row check (the canvas selection does not change before it).
			NameRowsFocused = 0;
			if (m != null)
			{
				SelectOutline(.Member, m);
				FocusNameField();
			}
		}

		/// Ctrl+Page Down goes to the next Sheet tab in the bar (Heal was opened earlier), Ctrl+Page Up comes back.
		void UXSheetTabs()
		{
			let heal = Doc.FindSheetByName("Heal");
			if (heal != null)
				OpenTab(heal);
			let take = Doc.FindSheetByName("TakeDamage");
			if (take != null)
				OpenTab(take);
			let before = CurrentMethod?.Name;
			bool next = CycleSheetTab(1);
			let moved = CurrentMethod?.Name;
			bool prev = CycleSheetTab(-1);
			SelfTestCheck(next && prev && moved != before && CurrentMethod?.Name == before, scope $"editor: Ctrl+Page Down goes to the next Sheet tab in the bar ({moved}) and Ctrl+Page Up comes back ({CurrentMethod?.Name})");
		}

		/// Phase 0: the breadcrumbs name the type and the Sheet, then the Lambda's Sheet opens; phase 1: its
		/// breadcrumbs go through the Sheet holding the Lambda node.
		void UXCrumbs(int phase)
		{
			if (phase == 0)
			{
				SelfTestCheck(mGraphPanel.CrumbsText == "Player : Actor > TakeDamage", scope $"editor: the breadcrumbs name the type (with its base) and the Sheet ({mGraphPanel.CrumbsText})");
				let lambda = FindNode(CurrentMethod.Graph, .Lambda);
				if (lambda != null)
					OpenLambdaSheet(lambda);
				return;
			}
			let crumbs = scope String(mGraphPanel.CrumbsText);
			let lambdaSheet = CurrentMethod;
			SelfTestCheck(lambdaSheet != null && lambdaSheet.Role == .Lambda && crumbs.StartsWith("Player : Actor > TakeDamage > Lambda "), scope $"editor: a Lambda Sheet's breadcrumbs go through the Sheet holding its node ({crumbs})");
			let take = Doc.FindSheetByName("TakeDamage");
			if (take != null)
				OpenTab(take);
		}

		/// Phase 0: L adds a local and selects it; phase 1: its Name row took the keyboard (then undo).
		void UXNewName(int phase)
		{
			if (phase == 0)
			{
				int locals = CurrentMethod.Graph.Locals.Count;
				NameRowsFocused = 0;
				AddLocalFromKey(CurrentTab, CurrentMethod);
				SelfTestCheck(CurrentMethod.Graph.Locals.Count == locals + 1 && OutlineSel == .Local, "editor: L adds a local and selects it");
				return;
			}
			SelfTestCheck(NameRowsFocused > 0, scope $"editor: a new local's Name field is in edit ({NameRowsFocused})");
			CurrentMethod.Doc.Undo();
		}

		/// Captures: moves ImGui's pointer (the host's input queue), so a tooltip is drawn where a step holds it.
		[CLink] static extern void ImGuiIO_AddMousePosEvent(ImGuiIOHead* io, float x, float y);

		/// The first node of the Sheet in front whose kind word or record id is `word` (captures).
		Node UXNode(StringView word)
		{
			let mg = CurrentMethod;
			if (mg == null)
				return null;
			for (let n in mg.Graph.Nodes)
				if (n.Key == word || StringView(NodeKinds.Word(n.Kind)) == word)
					return n;
			return null;
		}

		/// Capture helpers for the pixel pass of the node habits (TREADLE_SELFTEST steps): `ux.select:<node>`,
		/// `ux.pinmenu:<node>.<pin>` and `ux.nodemenu:<node>` (the menus a right-click opens, put beside the
		/// node), `ux.hover:<node>.<pin>` (the pointer held on the pin) and `ux.hoverclear`, `ux.disable:<node>`,
		/// `ux.frame:<node>` (it in view), `ux.expand:<node>` (all its pins shown), `ux.f2:<node>` (F2 with it
		/// selected), `ux.find` (the find bar).
		/// <node> is a kind word (Sequence, Switch, Get...) or a record id. False when `test` is none of them.
		bool SelfTestUXCapture(StringView test)
		{
			if (!test.StartsWith("ux."))
				return false;
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return true;
			let colon = test.IndexOf(':');
			let verb = (colon > 0) ? test.Substring(3, colon - 3) : test.Substring(3);
			let arg = (colon > 0) ? test.Substring(colon + 1) : "";
			let dot = arg.IndexOf('.');
			let n = UXNode((dot > 0) ? arg.Substring(0, dot) : arg);
			var pin = (n != null && dot > 0) ? (n.FindInput(arg.Substring(dot + 1)) ?? n.FindOutput(arg.Substring(dot + 1))) : null;
			// `out` / `in`: the node's first value output / input.
			if (n != null && pin == null && dot > 0)
				for (let p in (arg.Substring(dot + 1) == "in") ? n.Inputs : n.Outputs)
					if (pin == null && p.Kind == .Value)
						pin = p;
			switch (verb)
			{
			case "select":
				if (n != null)
				{
					OutlineSel = .None;
					tab.SelectOnly(n.Id);
				}
			case "pinmenu":
				if (pin != null && mGraphPanel.PinScreenPos(tab, pin.Id, let at))
				{
					mGraphPanel.SelfTestPopupPos = at + ImVec2(14, -8);
					mGraphPanel.SelfTestPinMenu = pin.Id;
				}
			case "nodemenu":
				if (n != null)
				{
					tab.SelectOnly(n.Id);
					mGraphPanel.SelfTestPopupPos = tab.GridToScreen(n.X, n.Y) + ImVec2(40, 30);
					OpenNodeContext(n.Id);
				}
			case "hover":
				if (pin != null && mGraphPanel.PinScreenPos(tab, pin.Id, let at))
				{
					// The canvas reads the held point; ImGui's own pointer goes there too, so the
					// tooltip is drawn beside the pin.
					mGraphPanel.SelfTestMouse = at;
					GraphProf.ForceHover = true;
					ImGuiIO_AddMousePosEvent(Gui.igGetIO_Nil(), at.x, at.y);
				}
			case "hoverclear":
				mGraphPanel.SelfTestMouse = .(-3e38f, -3e38f);
				mGraphPanel.SelfTestPopupPos = .(-3e38f, -3e38f);
				GraphProf.ForceHover = false;
				ImGuiIO_AddMousePosEvent(Gui.igGetIO_Nil(), -float.MaxValue, -float.MaxValue);
			case "frame":
				if (n != null)
				{
					tab.SelectOnly(n.Id);
					mGraphPanel.FrameNodes(tab, mg.Graph, true);
					tab.ClearSelection();
				}
			case "disable":
				if (n != null)
				{
					tab.SelectOnly(n.Id);
					ToggleDisabled(tab);
					tab.ClearSelection();
				}
			case "expand":
				if (n != null)
					mGraphPanel.SetCollapsed(tab, n, false);
			case "f2":
				if (n != null)
					tab.SelectOnly(n.Id);
				RenameSelection(tab);
			case "find":
				tab.FindOpen = true;
			default:
				SelfTestCheck(false, scope $"capture: unknown step {test}");
			}
			return true;
		}
	}
}
#endif
