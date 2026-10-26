// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;
using Treadle.Language;
using ImGui;

namespace Treadle.Editor
{
	/// The `editor` self test's second wave of node-graph habits (docs/UX-Audit.md): a variadic C call's
	/// "+ arg", the Ctrl+Tab list, reordering inputs, variable categories, Extract to Function, split
	/// struct pins and collapsed node groups. One phase per frame, a commit between them.
	extension EditorApp
	{
		/// How many frames the second wave takes (SelfTest.bf runs them before the save step).
		public const int cUX2Phases = 26;

		int32 mUX2Node;
		/// Extract to Function: the Demo function's nodes (record ids, in the order UX2Extract makes them).
		String mUX2Keys = new .() ~ delete _;

		void SelfTestUX2(int phase)
		{
			if (CurrentMethod == null || CurrentTab == null)
			{
				SelfTestCheck(false, "editor: a Sheet for the second wave of node habits");
				return;
			}
			switch (phase)
			{
			case 0: UX2Variadic(0);
			case 1: UX2Variadic(1);
			case 2, 3, 4, 5: UX2Switcher(phase - 2);
			case 6: UX2Reorder();
			case 7, 8: UX2Categories(phase - 7);
			case 9, 10, 11, 12: UX2Extract(phase - 9);
			case 13, 14, 15, 16: UX2Split(phase - 13);
			case 17, 18, 19: UX2Groups(phase - 17);
			case 20, 21, 22: UX2NodeHeader(phase - 20);
			case 23, 24, 25: UX2UnsafeStripe(phase - 23);
			default:
			}
		}

		/// The node of the Sheet in front whose record id is the `index`th word of mUX2Keys.
		Node UX2Key(int index)
		{
			int i = 0;
			for (let w in mUX2Keys.Split(' '))
				if (i++ == index)
					return CurrentMethod?.Graph.FindNodeByKey(w);
			return null;
		}

		/// The Function the last Extract to Function made, or null.
		MemberDecl UX2Extracted()
		{
			for (let mm in Doc.Members)
				if (mm.Serial == mLastExtracted)
					return mm;
			return null;
		}

		/// The Call of `fn` in the Sheet in front, or null.
		Node UX2CallOf(MemberDecl fn)
		{
			if (fn == null)
				return null;
			for (let n in CurrentMethod.Graph.Nodes)
				if (n.Kind == .Call && n.Text.StartsWith(scope $"this.{fn.Name}("))
					return n;
			return null;
		}

		/// Extract to Function on a demo function `Demo(int amount)` with the locals `flag` (bool) and
		/// `bonus` (int): Entry -> Set mHealth -= amount -> Set Armor = mHealth + bonus -> Branch on flag ->
		/// two Returns. Phase 0 builds it; phase 1 extracts the two Sets, the + and the Get of mHealth (one
		/// flow in, one out; amount and the local bonus become inputs, the Get of bonus stays here), checks
		/// both Sheets, then undoes; phase 2 extracts the + and its Gets (a Pure function returning int)
		/// and undoes; phase 3: the refusals (a Set of a local, a Branch with two flow exits, a Return).
		void UX2Extract(int phase)
		{
			let doc = Doc;
			let tab = CurrentTab;
			switch (phase)
			{
			case 0:
				let m = AddFunctionMember("Demo");
				if (m == null)
				{
					SelfTestCheck(false, "editor: a Demo function for Extract to Function");
					return;
				}
				AddParam(m, false);
				let s = doc.FindSheetByName("Demo");
				OpenTab(s);
				let g = s.Graph;
				let ep = g.Entry.FindOutput(m.Params[0].Name);
				ep?.Name.Set("amount");
				ep?.Label.Set("amount");
				m.Params[0].Name.Set("amount");
				NodeFactory.AddLocal(g, "flag", "bool");
				NodeFactory.AddLocal(g, "bonus", "int");
				let s1 = NodeFactory.Set(g, "mHealth", "int", "-=");
				let s2 = NodeFactory.Set(g, "Armor", "int");
				let add = NodeFactory.Operator(g, "+");
				let get = NodeFactory.Get(g, "mHealth", "int");
				let br = NodeFactory.Branch(g);
				let flag = NodeFactory.Get(g, "flag", "bool");
				let r1 = NodeFactory.Return(g, "void");
				let r2 = NodeFactory.Return(g, "void");
				let bonus = NodeFactory.Get(g, "bonus", "int");
				float x = 0;
				for (let n in Node[?](s1, s2, add, get, br, flag, r1, r2, bonus))
				{
					n.X = (x += 260);
					n.Y = (n == add || n == get || n == flag || n == bonus) ? 220 : 0;
					n.HasPos = true;
				}
				g.Connect(g.Entry.Then, s1.ExecIn);
				g.Connect(g.Entry.FindOutput("amount"), s1.FindInput("value"));
				g.Connect(s1.Then, s2.ExecIn);
				g.Connect(get.Result, add.FindInput("a"));
				g.Connect(bonus.Result, add.FindInput("b"));
				g.Connect(add.Result, s2.FindInput("value"));
				g.Connect(s2.Then, br.ExecIn);
				g.Connect(flag.Result, br.FindInput("condition"));
				g.Connect(br.FindOutput("true"), r1.ExecIn);
				g.Connect(br.FindOutput("false"), r2.ExecIn);
				// The places above stay (no first-draw arrange of the new Sheet).
				g.AutoLaidOut = false;
				KeyAssigner.Assign(g);
				mUX2Keys.Clear();
				for (let n in Node[?](s1, s2, add, get, br, flag, r1, r2, bonus))
					mUX2Keys.AppendF("{}{}", mUX2Keys.IsEmpty ? "" : " ", n.Key);
				doc.Commit(s);
				SelfTestCheck(g.Nodes.Count == 10 && g.Links.Count == 10, scope $"editor: the Demo function for Extract to Function ({g.Nodes.Count} nodes, {g.Links.Count} wires)");
			case 1:
				let g = CurrentMethod.Graph;
				let s1 = UX2Key(0);
				let bonus = UX2Key(8);
				if (s1 == null || bonus == null)
				{
					SelfTestCheck(false, "editor: the Demo nodes to extract");
					return;
				}
				String k1 = scope .(s1.Key);
				int members = doc.Members.Count;
				tab.ClearSelection();
				for (int i in int[?](0, 1, 2, 3, 8))
					tab.AddToSelection(UX2Key(i).Id);
				bool ok = ExtractToFunction(tab);
				let fn = UX2Extracted();
				let fs = (fn != null) ? doc.FindSheet(fn.Id) : null;
				let call = UX2CallOf(fn);
				SelfTestCheck(ok && fn != null && doc.Members.Count == members + 1 && fn.Params.Count == 2 && fn.Params[0].Name == "amount" && fn.Params[1].Name == "bonus" &&
					!fn.Pure && fn.Returns == null && doc.Members.IndexOf(fn) == doc.Members.IndexOf(doc.FindMember("Demo")) + 1,
					scope $"editor: Extract to Function makes {(fn != null) ? fn.Name : "nothing"}(int amount, int bonus) after Demo from two Sets, a + and a Get {ExtractRefusal}");
				SelfTestCheck(call != null && g.IsLinked(call.ExecIn) && g.ExecTarget(call.Then)?.Kind == .Branch &&
					g.DataSource(call.FindInput("amount")) == g.Entry && g.DataSource(call.FindInput("bonus"))?.Key == bonus.Key && g.Nodes.Count == 10 - 4 + 1,
					scope $"editor: a Call of it takes the selection's place, wired to the flow, to amount and to the local bonus's Get ({(call != null) ? call.Text : "no call"}, {g.Nodes.Count} nodes)");
				let ig = fs?.Graph;
				let moved = ig?.FindNodeByKey(k1);
				SelfTestCheck(ig != null && moved != null && ig.Nodes.Count == 5 && ig.ExecTarget(ig.Entry.Then) == moved && ig.DataSource(moved.FindInput("value")) == ig.Entry,
					scope $"editor: the nodes moved into its Sheet with their ids, the Entry wired to them ({(ig != null) ? ig.Nodes.Count : 0} nodes)");
				SelfTestCheck(OutlineSel == .Member && SelectedMember == fn, "editor: the new function's page is in front for its name");
				// The front end reads both Sheets without an error.
				Validate(true);
				String errs = scope .();
				if (mValidate != null && fs != null)
					for (let d in mValidate.Messages)
						if (d.IsError && (d.MethodKey == fs.Key || d.MethodKey == CurrentMethod.Key))
							errs.AppendF(" [{}]", d.Text);
				SelfTestCheck(mValidate != null && errs.IsEmpty, scope $"editor: Validate finds no error in Demo or the extracted function{errs}");
				doc.Undo();
				let back = CurrentMethod.Graph;
				SelfTestCheck(doc.Members.Count == members && back.FindNodeByKey(k1) != null && back.Nodes.Count == 10 && back.Links.Count == 10,
					scope $"editor: one undo puts the nodes back and removes the function ({back.Nodes.Count} nodes, {back.Links.Count} wires)");
			case 2:
				let g = CurrentMethod.Graph;
				let s2 = UX2Key(1);
				int members = doc.Members.Count;
				tab.ClearSelection();
				for (int i in int[?](2, 3, 8))
					tab.AddToSelection(UX2Key(i).Id);
				bool ok = ExtractToFunction(tab);
				let fn = UX2Extracted();
				let call = UX2CallOf(fn);
				SelfTestCheck(ok && fn != null && fn.Pure && fn.Params.Count == 1 && fn.Returns?.ToString(.. scope String()) == "int" &&
					call != null && call.IsPure && s2 != null && g.DataSource(s2.FindInput("value")) == call,
					scope $"editor: value nodes alone extract into a Pure function returning int, its Call feeding Set Armor {ExtractRefusal}");
				doc.Undo();
				SelfTestCheck(doc.Members.Count == members && CurrentMethod.Graph.Nodes.Count == 10, "editor: undo takes the Pure function back out");
			case 3:
				let g = CurrentMethod.Graph;
				int members = doc.Members.Count;
				// A Set of a local is refused with the reason.
				BeginEdit();
				let setFlag = NodeFactory.Set(g, "flag", "bool");
				setFlag.X = 300;
				setFlag.Y = 500;
				setFlag.HasPos = true;
				CommitCurrent();
				tab.SelectOnly(setFlag.Id);
				bool refused = !ExtractToFunction(tab) && ExtractRefusal.Contains("local") && doc.Members.Count == members;
				SelfTestCheck(refused, scope $"editor: Extract to Function refuses a Set of a local, with the reason ({ExtractRefusal})");
				doc.Undo();
				// A Branch with two flow exits is refused.
				let br = UX2Key(4);
				if (br != null)
					tab.SelectOnly(br.Id);
				bool refused2 = br != null && !ExtractToFunction(tab) && ExtractRefusal.Contains("more than one") && doc.Members.Count == members;
				SelfTestCheck(refused2, scope $"editor: a selection whose flow leaves at two pins is refused ({ExtractRefusal})");
				tab.ClearSelection();
				for (int i in int[?](4, 6, 7))
					tab.AddToSelection(UX2Key(i).Id);
				bool refused3 = !ExtractToFunction(tab) && ExtractRefusal.Contains("ends this function") && doc.Members.Count == members;
				SelfTestCheck(refused3, scope $"editor: a Return in the selection is refused ({ExtractRefusal})");
				tab.ClearSelection();
				// The Demo function stays for the save step (it reads back with the rest).
				let take = doc.FindSheetByName("TakeDamage");
				if (take != null)
					OpenTab(take);
			}
		}

		/// Move Up on Heal's second input: the input order, Heal's Entry pins, a Call's pins and its
		/// parameter types follow, the Call's wire stays on its pin (by name); one undo puts it all back.
		void UX2Reorder()
		{
			let heal = Doc.FindMember("Heal");
			let take = Doc.FindSheetByName("TakeDamage");
			if (heal == null || take == null || heal.Params.Count != 1)
			{
				SelfTestCheck(false, "editor: Heal with one input for the reorder check");
				return;
			}
			if (CurrentMethod != take)
				OpenTab(take);
			AddParam(heal, false);
			let second = heal.Params[1];
			delete second.Type;
			second.Type = TypeRef.Parse("float");
			SyncSheets(heal);
			// A Call of Heal(int, float) in TakeDamage with the Entry's amount wired into its first input.
			let g = take.Graph;
			BeginEdit();
			let call = NodeMenu.CallOwn(g, heal, Doc.Header.Name, true);
			call.X = 400;
			call.Y = 1800;
			call.HasPos = true;
			let firstName = scope String(heal.Params[0].Name);
			let secondName = scope String(second.Name);
			let amount = g.Entry.FindOutput("amount");
			if (amount != null && call.FindInput(firstName) != null)
				g.Connect(amount, call.FindInput(firstName));
			CommitCurrent();
			String before = scope .(call.Text);
			bool moved = MoveParam(heal, second, -1);
			let healSheet = Doc.FindSheetByName("Heal");
			let entry = healSheet?.Graph.Entry;
			int firstValue = -1;
			if (entry != null)
				for (let p in entry.Outputs)
					if (p.Kind == .Value && firstValue < 0)
						firstValue = @p.Index;
			bool entryOk = entry != null && firstValue >= 0 && entry.Outputs[firstValue].Name == secondName;
			int iSecond = -1;
			int iFirst = -1;
			for (let p in call.Inputs)
			{
				if (p.Name == secondName) iSecond = @p.Index;
				if (p.Name == firstName) iFirst = @p.Index;
			}
			bool wired = amount != null && g.FindLinkTo(call.FindInput(firstName))?.From == amount;
			SelfTestCheck(moved && heal.Params[0] == second && entryOk && call.Text == "this.Heal(float,int)" && iSecond >= 0 && iSecond < iFirst && wired,
				scope $"editor: Move Up on an input reorders Heal's inputs, its Entry pins and a Call ({before} -> {call.Text}), the Call's wire stays on {firstName}");
			Doc.Undo();
			let heal2 = Doc.FindMember("Heal");
			Node call2 = null;
			for (let n in Doc.FindSheetByName("TakeDamage").Graph.Nodes)
				if (n.Kind == .Call && n.Text.StartsWith("this.Heal(") && n.Y == 1800)
					call2 = n;
			SelfTestCheck(heal2 != null && heal2.Params.Count == 2 && heal2.Params[0].Name == firstName && call2 != null && call2.Text == before,
				scope $"editor: one undo puts the inputs and the Call back ({(call2 != null) ? call2.Text : "no call"})");
			// The Call and the second input go again (Heal keeps the one input the save step reads back).
			Doc.Undo();
			Doc.Undo();
		}

		/// Phase 0: Armor gets the Category Combat (one undo step); the Node menu lists Get Armor under
		/// Variables | Combat; the file keeps it. Phase 1: the Outline drew the Combat header.
		void UX2Categories(int phase)
		{
			if (phase == 1)
			{
				SelfTestCheck(OutlineCategoryRows == 1, scope $"editor: the Outline groups the variables by Category ({OutlineCategoryRows} header)");
				return;
			}
			let armor = Doc.FindMember("Armor");
			bool set = armor != null && SetFieldCategory(armor, "Combat");
			SelfTestCheck(set && armor.Category == "Combat", "editor: a variable's Category is set in its Properties");
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.ListFor(CurrentMethod, 0, "Armor", rows);
			bool under = false;
			for (let r in rows)
				if (r.Label == "Get Armor" && r.Category == "Variables | Combat")
					under = true;
			SelfTestCheck(under, "editor: the Node menu lists Get Armor under Variables | Combat");
			String text = scope .();
			String why = scope .();
			Doc.WriteText(text, why);
			TypeDocument back = scope .(Language);
			String err = scope .();
			bool read = back.LoadText(text, err);
			let backArmor = back.FindMember("Armor");
			SelfTestCheck(read && text.Contains("\tcategory \"Combat\"\n") && backArmor != null && backArmor.Category == "Combat",
				scope $"codec: a field's `category` line is written and read back {err}");
			SelSelectNone();
		}

		void SelSelectNone()
		{
			OutlineSel = .None;
		}

		/// Ctrl+Tab's list: phase 0 opens Heal, phase 1 TakeDamage (the list's order follows); phase 2 opens
		/// the list (held up as Ctrl would): Heal, the Sheet used before, is highlighted; phase 3: it was
		/// drawn, Tab and Shift+Tab move the highlight, releasing Ctrl opens Heal, and a quick Ctrl+Tab goes
		/// back to TakeDamage.
		void UX2Switcher(int phase)
		{
			switch (phase)
			{
			case 0:
				let heal = Doc.FindSheetByName("Heal");
				if (heal != null)
					OpenTab(heal);
			case 1:
				let take = Doc.FindSheetByName("TakeDamage");
				if (take != null)
					OpenTab(take);
			case 2:
				List<GraphTab> recent = scope .();
				SheetsByRecentUse(recent);
				SelfTestCheck(recent.Count >= 2 && recent[0].Title == "TakeDamage" && recent[1].Title == "Heal",
					scope $"editor: the open Sheets by recent use start TakeDamage, Heal ({(recent.Count >= 2) ? recent[1].Title : "?"})");
				SwitcherDrawn = 0;
				SwitcherPinned = true;
				bool opened = SheetSwitcherStep(1);
				String hi = scope .();
				SheetSwitcherHighlighted(hi);
				SelfTestCheck(opened && SheetSwitcherOpen && hi == "Heal", scope $"editor: Ctrl+Tab opens the list of open Sheets on the one used before (Heal: {hi})");
			case 3:
				SelfTestCheck(SwitcherDrawn > 0, "editor: the list of open Sheets is drawn while Ctrl is held");
				SheetSwitcherStep(1);
				String hi = scope .();
				SheetSwitcherHighlighted(hi);
				SheetSwitcherStep(-1);
				String back = scope .();
				SheetSwitcherHighlighted(back);
				bool committed = SheetSwitcherCommit();
				SelfTestCheck(hi != "Heal" && back == "Heal" && committed && !SheetSwitcherOpen && CurrentMethod?.Name == "Heal",
					scope $"editor: Tab moves the highlight ({hi}), Shift+Tab comes back, releasing Ctrl opens Heal ({CurrentMethod?.Name})");
				// The frame loop tracks Heal as most recent before the next step; done here at once.
				TrackTabMru();
				SheetSwitcherStep(1);
				SheetSwitcherCommit();
				SelfTestCheck(CurrentMethod?.Name == "TakeDamage", scope $"editor: a quick Ctrl+Tab goes back to the Sheet used before ({CurrentMethod?.Name})");
			}
		}

		/// Phase 0: a Call of the type's own function is not variadic (no "+ arg", Add Argument does
		/// nothing); the samples' catalogue marks printf variadic and puts not; a printf Call gets `va0`,
		/// `va1` and loses the last again. Phase 1: the selected own Call drew no "+ arg".
		void UX2Variadic(int phase)
		{
			let mg = CurrentMethod;
			let g = mg.Graph;
			if (phase == 1)
			{
				SelfTestCheck(mUX2Node != 0 && !mGraphPanel.ShowsArgs(mUX2Node), "editor: a selected Call of a function that is not variadic shows no \"+ arg\"");
				CurrentTab.ClearSelection();
				return;
			}
			Node call = null;
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text.StartsWith("this.") && call == null)
					call = n;
			int inputs = (call != null) ? call.Inputs.Count : -1;
			if (call != null)
				AddArgument(call);
			SelfTestCheck(call != null && !IsVariadicCall(call) && call.Inputs.Count == inputs,
				scope $"editor: a Call of {(call != null) ? call.Text : "?"} is not variadic: Add Argument adds no pin");
			mUX2Node = (call != null) ? call.Id : 0;
			if (call != null)
			{
				OutlineSel = .None;
				CurrentTab.SelectOnly(call.Id);
			}
			// The samples' catalogue: Shooter.tproj imports libc (printf has `...`, puts has not).
			String samples = scope .();
			if (!FindSamples(samples))
				return;
			LanguageContext ctx = scope .();
			ProjectIndex index = scope .();
			index.Build(samples, Treadle.Format.FormatNames.TypeExt);
			ctx.Index = index;
			List<TypeDocument> open = scope .();
			defer { ClearAndDeleteItems!(open); }
			TypeDocument program = new .(ctx);
			program.Load(scope $"{samples}/Program.treadle").IgnoreError();
			open.Add(program);
			Treadle.Compiler.FrontEndServices fe = scope .(ctx, open);
			List<Treadle.Catalog.NodeSpec> specs = scope .();
			defer { ClearAndDeleteItems!(specs); }
			fe.Catalog.Entries(specs);
			HashSet<String> variadic = scope .();
			defer { for (let s in variadic) delete s; }
			NodeMenu.VariadicNames(specs, variadic);
			Graph scratch = scope .();
			let printf = NodeFactory.StaticCall(scratch, "printf", "C.libc", true, default, default, "int");
			let puts = NodeFactory.StaticCall(scratch, "puts", "C.libc", true, default, default, "int");
			SelfTestCheck(NodeMenu.IsVariadicIn(variadic, printf) && !NodeMenu.IsVariadicIn(variadic, puts),
				scope $"editor: the catalogue marks C.libc.printf variadic and C.libc.puts not ({variadic.Count} variadic)");
			NodeFactory.AddVarArg(scratch, printf);
			NodeFactory.AddVarArg(scratch, printf);
			bool two = printf.FindInput("va0") != null && printf.FindInput("va1") != null && NodeFactory.VarArgCount(printf) == 2 && printf.ArgCount == 0;
			NodeFactory.RemoveLastVarArg(scratch, printf);
			SelfTestCheck(two && printf.FindInput("va1") == null && NodeFactory.VarArgCount(printf) == 1,
				"editor: \"+ arg\" on a printf Call adds va0 and va1 (the names the front end reads); \"- arg\" removes va1");
		}

		/// Capture helpers for the pixel pass of the second wave (TREADLE_SELFTEST steps):
		/// `ux2.open:<Sheet>` (a Sheet in front, its tab opened), `ux2.switcher` (the Ctrl+Tab list held up),
		/// `ux2.switcherclose`. False when `test` is none of them.
		bool SelfTestUX2Capture(StringView test)
		{
			if (!test.StartsWith("ux2."))
				return false;
			let colon = test.IndexOf(':');
			let verb = (colon > 0) ? test.Substring(4, colon - 4) : test.Substring(4);
			let arg = (colon > 0) ? test.Substring(colon + 1) : "";
			switch (verb)
			{
			case "open":
				let s = Doc?.FindSheetByName(arg);
				if (s != null)
					OpenTab(s);
			case "switcher":
				SwitcherPinned = true;
				if (!SheetSwitcherOpen)
					SheetSwitcherStep(1);
				mSwitcherSince = 0;
			case "switcherclose":
				SheetSwitcherCancel();
			case "addinput":
				// An input of the function `arg` (its page shows the Move Up / Down arrows with two).
				let m = Doc?.FindMember(arg);
				if (m != null)
					AddParam(m, false);
			case "category":
				// `ux2.category:<field>=<Category>`
				let eq = arg.IndexOf('=');
				let m = (eq > 0) ? Doc?.FindMember(arg.Substring(0, eq)) : null;
				if (m != null)
					SetFieldCategory(m, arg.Substring(eq + 1));
			case "notoasts":
				// The test steps' toasts out of the capture.
				Notify.DismissToasts();
			case "framegroup":
				// The first group of the Sheet in front in the middle of the canvas at 1:1.
				let tab = CurrentTab;
				let g = CurrentMethod?.Graph;
				if (tab != null && g != null && !g.Groups.IsEmpty)
				{
					let gr = g.Groups[0];
					tab.ZoomLevel = Canvas.DefaultZoomLevel;
					tab.CenterOn(gr.X + 120, gr.Y + 60);
				}
			case "extract":
				// Extract to Function on Demo's two Sets, + and Get mHealth (the Get of bonus stays).
				let tab = CurrentTab;
				if (tab != null)
				{
					tab.ClearSelection();
					for (int i in int[?](0, 1, 2, 3, 8))
						if (UX2Key(i) != null)
							tab.AddToSelection(UX2Key(i).Id);
					ExtractToFunction(tab);
				}
			case "pairmenu", "pairpinmenu":
				// SplitDemo's Get mPair recombined; the Node menu dragged from its output (Break Pair<int,float>),
				// or its pin menu (Split Struct Pin).
				let tab = CurrentTab;
				let n = SplitKey(1);
				var pin = n?.FindOutput("value");
				if (pin != null && SplitPins.IsSplit(pin))
					RecombineStructPin(CurrentMethod, pin);
				pin = n?.FindOutput("value");
				if (tab != null && pin != null && mGraphPanel.PinScreenPos(tab, pin.Id, let at))
				{
					if (verb == "pairmenu")
					{
						mNodeMenu.SelfTestPos = at + ImVec2(30, -20);
						OpenNodeMenu(tab, .(n.X + 260, n.Y), pin.Id);
					}
					else
					{
						mGraphPanel.SelfTestPopupPos = at + ImVec2(14, -8);
						mGraphPanel.SelfTestPinMenu = pin.Id;
					}
				}
			case "zoom":
				// `ux2.zoom:<level>` (0 = 1:1, negative zooms out), around the middle of the canvas.
				if (CurrentTab != null && int32.Parse(arg) case .Ok(let lv))
					CurrentTab.SetZoomLevel(Canvas.DefaultZoomLevel + lv, CurrentTab.CanvasOrigin + CurrentTab.CanvasSize * 0.5f);
			case "fold", "unfold":
				// Every node group of the Sheet in front folded / opened.
				let tab = CurrentTab;
				let g = CurrentMethod?.Graph;
				if (tab != null && g != null)
					for (let gr in g.Groups)
						mGraphPanel.SetGroupCollapsed(tab, g, gr, verb == "fold");
				tab?.ClearSelection();
			case "groupmenu":
				// The group menu of the first group, beside it.
				let tab = CurrentTab;
				let g = CurrentMethod?.Graph;
				if (tab != null && g != null && !g.Groups.IsEmpty)
				{
					let gr = g.Groups[0];
					mGraphPanel.SelfTestPopupPos = tab.GridToScreen(gr.X, gr.Y) + ImVec2(60, 40);
					mGraphPanel.SelfTestGroupMenu = gr.Id;
				}
			case "extractmenu":
				// The node menu of a selection of Demo's Sets (Extract to Function, Collapse Nodes).
				let tab = CurrentTab;
				let a = UX2Key(1);
				let b = UX2Key(2);
				if (tab != null && a != null)
				{
					tab.SelectOnly(a.Id);
					if (b != null)
						tab.AddToSelection(b.Id);
					mGraphPanel.SelfTestPopupPos = tab.GridToScreen(a.X, a.Y) + ImVec2(40, 30);
					OpenNodeContext(a.Id);
				}
			case "splitmenu":
				// The pin menu of SplitDemo's Get mPair value.First (Recombine Struct Pin).
				let tab = CurrentTab;
				let n = SplitKey(1);
				let pin = n?.FindOutput("value.First");
				if (tab != null && pin != null && mGraphPanel.PinScreenPos(tab, pin.Id, let at))
				{
					mGraphPanel.SelfTestPopupPos = at + ImVec2(14, -8);
					mGraphPanel.SelfTestPinMenu = pin.Id;
				}
			default:
				SelfTestCheck(false, scope $"capture: unknown step {test}");
			}
			return true;
		}

		/// A node's header against the node's rectangle, at zoom +2 and -3 (the seam showed at fractional
		/// zooms): phase 0 centres the Entry node at +2 and records its header, phases 1 and 2 check it
		/// (phase 1 then zooms to -3). The header must be one mesh whose transparent outer edge runs only along
		/// its outline: a header pieced from rects has an edge inside it, drawn as a vertical line.
		void UX2NodeHeader(int phase)
		{
			let tab = CurrentTab;
			let entry = CurrentMethod.Graph.Entry;
			if (entry == null)
			{
				SelfTestCheck(false, "editor: node header: the Sheet in front has an Entry node");
				return;
			}
			if (phase == 1 || phase == 2)
				UX2CheckHeader((phase == 1) ? "zoom +2" : "zoom -3");
			if (phase == 2)
			{
				mGraphPanel.SelfTestHeaderNode = 0;
				tab.ZoomLevel = Canvas.DefaultZoomLevel;
				return;
			}
			mGraphPanel.SelfTestHeaderNode = entry.Id;
			mGraphPanel.SelfTestHeader.Clear();
			tab.ZoomLevel = Canvas.DefaultZoomLevel + ((phase == 0) ? 2 : -3);
			tab.CenterOn(entry.X + 60, entry.Y + 30);
		}

		void UX2CheckHeader(StringView zoomText)
		{
			let gp = mGraphPanel;
			let f = gp.SelfTestHeader;
			SelfTestCheck(f.Count >= 8, scope $"editor: node header at {zoomText}: drawn as one mesh ({f.Count} edge vertices)");
			if (f.Count < 8)
				return;
			let a = gp.SelfTestNodeMin;
			let b = gp.SelfTestHeaderMax;
			float r = gp.SelfTestHeaderR;
			SelfTestCheck(Math.Abs(b.x - gp.SelfTestNodeMax.x) < 0.01f && b.y > a.y && b.y < gp.SelfTestNodeMax.y,
				scope $"editor: node header at {zoomText}: spans the node's rectangle ({a.x:F1},{a.y:F1})-({b.x:F1},{b.y:F1}) in ({gp.SelfTestNodeMax.x:F1},{gp.SelfTestNodeMax.y:F1})");
			float worst = 0;
			ImVec2 lo = f[0];
			ImVec2 hi = f[0];
			for (let v in f)
			{
				worst = Math.Max(worst, HeaderOutlineDistance(v, a, b, r));
				lo = .(Math.Min(lo.x, v.x), Math.Min(lo.y, v.y));
				hi = .(Math.Max(hi.x, v.x), Math.Max(hi.y, v.y));
			}
			SelfTestCheck(worst <= 1.0f, scope $"editor: node header at {zoomText}: its soft edge stays on the outline, no line inside it (worst {worst:F2} px)");
			SelfTestCheck(Math.Abs(lo.x - (a.x - 0.5f)) < 0.6f && Math.Abs(hi.x - (b.x + 0.5f)) < 0.6f && Math.Abs(lo.y - (a.y - 0.5f)) < 0.6f && Math.Abs(hi.y - (b.y + 0.5f)) < 0.6f,
				scope $"editor: node header at {zoomText}: its edge covers the whole header ({lo.x:F1},{lo.y:F1})-({hi.x:F1},{hi.y:F1})");
		}

		/// The Branch UX2UnsafeStripe places (its node id).
		int32 mUX2Stripe;

		/// The Unsafe hatch against the node's rounded header, at zoom +2 and -3: phase 0 places a Branch marked
		/// `unsafe` below the Entry node and centres it at +2, phases 1 and 2 check it (phase 1 then zooms to -3),
		/// phase 2 removes the node. Every vertex of the clipped strips lies on the band's outline (the top
		/// edge, the rounded corners, the sides, the band's bottom), and the hatch reaches into both rounded
		/// corners: a hatch cut by a straight clip at the corners' inner ends stops short of the outline there.
		void UX2UnsafeStripe(int phase)
		{
			let tab = CurrentTab;
			let g = CurrentMethod.Graph;
			let gp = mGraphPanel;
			if (phase == 0)
			{
				let entry = g.Entry;
				if (entry == null)
				{
					SelfTestCheck(false, "editor: unsafe stripe: the Sheet in front has an Entry node");
					return;
				}
				let n = NodeFactory.Branch(g);
				n.Unsafe = true;
				n.X = entry.X;
				n.Y = entry.Y + 480;
				n.HasPos = true;
				mUX2Stripe = n.Id;
				gp.SelfTestStripeNode = n.Id;
				gp.SelfTestStripe.Clear();
				tab.ZoomLevel = Canvas.DefaultZoomLevel + 2;
				tab.CenterOn(n.X + 60, n.Y + 30);
				return;
			}
			UX2CheckStripe((phase == 1) ? "zoom +2" : "zoom -3");
			Node n = null;
			for (let m in g.Nodes)
				if (m.Id == mUX2Stripe)
					n = m;
			if (phase == 1 && n != null)
			{
				gp.SelfTestStripe.Clear();
				tab.ZoomLevel = Canvas.DefaultZoomLevel - 3;
				tab.CenterOn(n.X + 60, n.Y + 30);
				return;
			}
			gp.SelfTestStripeNode = 0;
			if (n != null)
				g.RemoveNode(n);
			tab.ZoomLevel = Canvas.DefaultZoomLevel;
		}

		void UX2CheckStripe(StringView zoomText)
		{
			let gp = mGraphPanel;
			let f = gp.SelfTestStripe;
			SelfTestCheck(f.Count >= 3, scope $"editor: unsafe stripe at {zoomText}: drawn ({f.Count} vertices)");
			if (f.Count < 3)
				return;
			let a = gp.SelfTestStripeMin;
			let b = gp.SelfTestStripeMax;
			float r = gp.SelfTestStripeR;
			float worst = 0;
			ImVec2 lo = f[0];
			ImVec2 hi = f[0];
			float top = f[0].y;
			float bottom = f[0].y;
			for (let v in f)
			{
				worst = Math.Max(worst, HeaderOutlineDistance(v, a, b, r));
				if (v.x < lo.x)
					lo = v;
				if (v.x > hi.x)
					hi = v;
				top = Math.Min(top, v.y);
				bottom = Math.Max(bottom, v.y);
			}
			SelfTestCheck(worst <= 1.0f, scope $"editor: unsafe stripe at {zoomText}: clipped to the header's rounded outline (worst {worst:F2} px)");
			float loOff = HeaderOutlineDistance(lo, a, b, r);
			float hiOff = HeaderOutlineDistance(hi, a, b, r);
			SelfTestCheck(lo.x < a.x + r && loOff <= 1.0f && hi.x > b.x - r && hiOff <= 1.0f,
				scope $"editor: unsafe stripe at {zoomText}: runs into both rounded corners (left {lo.x - a.x:F1} px in, {loOff:F2} px off the outline; right {b.x - hi.x:F1} px in, {hiOff:F2} px off; radius {r:F1})");
			SelfTestCheck(Math.Abs(top - a.y) <= 1.0f && Math.Abs(bottom - b.y) <= 1.0f,
				scope $"editor: unsafe stripe at {zoomText}: spans the band's height ({top:F1}-{bottom:F1} in {a.y:F1}-{b.y:F1})");
		}

		/// How far `v` is from the outline of a header from `a` to `b`: top corners rounded by `r`, bottom square.
		static float HeaderOutlineDistance(ImVec2 v, ImVec2 a, ImVec2 b, float r)
		{
			if (v.y < a.y + r && (v.x < a.x + r || v.x > b.x - r))
			{
				let c = ImVec2((v.x < a.x + r) ? a.x + r : b.x - r, a.y + r);
				float dx = v.x - c.x;
				float dy = v.y - c.y;
				return Math.Abs(Math.Sqrt(dx * dx + dy * dy) - r);
			}
			return Math.Min(Math.Min(Math.Abs(v.x - a.x), Math.Abs(b.x - v.x)), Math.Min(Math.Abs(v.y - a.y), Math.Abs(b.y - v.y)));
		}
	}
}
#endif
